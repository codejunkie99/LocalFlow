import CryptoKit
import Foundation
import LocalFlowCore

public protocol UpdateTransport: Sendable {
    func data(from url: URL) async throws -> Data
    func download(from url: URL, to destination: URL) async throws
}

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> CommandResult

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws
}

public extension CommandRunning {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws {
        let result = try await run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory
        )
        guard result.status == 0 else { throw UpdateLaunchError.failed }
    }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> CommandResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            if let currentDirectory {
                process.currentDirectoryURL = currentDirectory
            }
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let error = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return CommandResult(
                status: process.terminationStatus,
                standardOutput: output,
                standardError: error
            )
        }.value
    }

    public func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

}

private enum UpdateLaunchError: Error {
    case failed
}

public actor UpdateService {
    public struct Configuration: Sendable {
        public let repositoryOwner: String
        public let repositoryName: String
        public let installedAppURL: URL
        public let installedVersion: LocalFlowVersion
        public let storedSigningIdentity: String?
        public let signingFingerprint: String?

        public init(
            repositoryOwner: String,
            repositoryName: String,
            installedAppURL: URL,
            installedVersion: LocalFlowVersion,
            storedSigningIdentity: String?,
            signingFingerprint: String?
        ) {
            self.repositoryOwner = repositoryOwner
            self.repositoryName = repositoryName
            self.installedAppURL = installedAppURL
            self.installedVersion = installedVersion
            self.storedSigningIdentity = storedSigningIdentity
            self.signingFingerprint = signingFingerprint
        }
    }

    private let configuration: Configuration
    private let transport: any UpdateTransport
    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(
        configuration: Configuration,
        transport: any UpdateTransport,
        runner: any CommandRunning,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.transport = transport
        self.runner = runner
        self.fileManager = fileManager
    }

    public func check(currentVersion: LocalFlowVersion) async -> UpdateState {
        do {
            return try await checkWithManifest(currentVersion: currentVersion).state
        } catch {
            return .failed(.network)
        }
    }

    public func checkWithManifest(
        currentVersion: LocalFlowVersion
    ) async throws -> (state: UpdateState, manifest: LocalFlowReleaseManifest?) {
        do {
            let releaseURL = latestReleaseURL()
            let data = try await transport.data(from: releaseURL)
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = payload["assets"] as? [[String: Any]],
                  let manifestURL = assets.compactMap({ asset -> URL? in
                      guard let name = asset["name"] as? String,
                            name == "localflow-release.json",
                            let urlString = asset["browser_download_url"] as? String
                      else { return nil }
                      return URL(string: urlString)
                  }).first
            else {
                return (.failed(.invalidManifest), nil)
            }
            let manifestData = try await transport.data(from: manifestURL)
            let manifest = try JSONDecoder().decode(
                LocalFlowReleaseManifest.self,
                from: manifestData
            )
            guard sourceURLMatchesConfiguredRelease(manifest.sourceURL, version: manifest.version) else {
                return (.failed(.invalidManifest), nil)
            }
            guard manifest.version > currentVersion else {
                return (.current, manifest)
            }
            return (.ready(version: manifest.version), manifest)
        } catch {
            throw error
        }
    }

    public func install(_ manifest: LocalFlowReleaseManifest) async -> UpdateState {
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalFlowUpdate-\(UUID().uuidString)", isDirectory: true)
        var helperOwnsWorkingDirectory = false
        do {
            try fileManager.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
            defer {
                if !helperOwnsWorkingDirectory {
                    try? fileManager.removeItem(at: workingDirectory)
                }
            }

            let archiveURL = workingDirectory.appendingPathComponent("source.tar.gz")
            try await transport.download(from: manifest.sourceURL, to: archiveURL)
            let digest = try sha256(of: archiveURL)
            guard digest == manifest.sourceSHA256 else {
                return .failed(.checksumMismatch)
            }

            let listing = try await runTar(listing: archiveURL)
            guard Self.archiveEntriesAreSafe(listing, topLevelPrefix: "LocalFlow-\(manifest.version.rawValue)") else {
                return .failed(.unsafeArchive)
            }

            let extracted = workingDirectory.appendingPathComponent("source")
            try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
            try await runTar(extract: archiveURL, into: extracted)

            let checkout = extracted.appendingPathComponent(
                "LocalFlow-\(manifest.version.rawValue)",
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: checkout.appendingPathComponent("Package.swift").path),
                  fileManager.fileExists(atPath: checkout.appendingPathComponent("scripts/package-app.sh").path)
            else {
                return .failed(.invalidManifest)
            }

            guard let identity = configuration.storedSigningIdentity else {
                return .failed(.signingIdentityMissing)
            }

            guard let expectedFingerprint = configuration.signingFingerprint,
                  try await signingIdentityFingerprint(label: identity) == expectedFingerprint
            else {
                return .failed(.signingIdentityMissing)
            }

            let cleanEnvironment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": fileManager.homeDirectoryForCurrentUser.path,
                "TMPDIR": fileManager.temporaryDirectory.path,
                "LOCALFLOW_SIGNING_IDENTITY": identity,
                "LOCALFLOW_VERSION": manifest.version.rawValue,
            ]
            let packageResult = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["scripts/package-app.sh"],
                environment: cleanEnvironment,
                currentDirectory: checkout
            )
            guard packageResult.status == 0 else {
                return .failed(.buildFailed)
            }

            let stagedApp = checkout.appendingPathComponent("dist/LocalFlow.app")
            guard fileManager.fileExists(atPath: stagedApp.path) else {
                return .failed(.buildFailed)
            }
            guard try bundleIdentifier(of: stagedApp) == "dev.localflow.app" else {
                return .failed(.signatureMismatch)
            }
            guard let installedRequirement = try await codeRequirement(of: configuration.installedAppURL),
                  let stagedRequirement = try await codeRequirement(of: stagedApp),
                  stagedRequirement == installedRequirement
            else {
                return .failed(.signatureMismatch)
            }

            let databaseURL = try TranscriptHistoryStore.liveDatabaseURL()
            let backupURL = workingDirectory.appendingPathComponent("history-backup.sqlite3")
            let store = try TranscriptHistoryStore(databaseURL: databaseURL)
            do {
                try await store.checkpointAndBackup(to: backupURL)
            } catch {
                return .failed(.databaseBackupFailed)
            }
            try await store.close()

            let receiptURL = workingDirectory.appendingPathComponent("receipt.json")
            let helperSource = configuration.installedAppURL
                .appendingPathComponent("Contents/Helpers/LocalFlowUpdater")
            let helperDestination = workingDirectory.appendingPathComponent("LocalFlowUpdater")
            try fileManager.copyItem(at: helperSource, to: helperDestination)

            let parent = configuration.installedAppURL.deletingLastPathComponent()
            let previous = parent.appendingPathComponent(".LocalFlow.previous.app")
            try await runner.launch(
                executable: helperDestination,
                arguments: [
                    "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
                    "--current", configuration.installedAppURL.path,
                    "--staged", stagedApp.path,
                    "--previous", previous.path,
                    "--database", databaseURL.path,
                    "--database-backup", backupURL.path,
                    "--receipt", receiptURL.path,
                    "--expected-bundle-id", "dev.localflow.app",
                    "--expected-requirement", installedRequirement,
                    "--cleanup-root", workingDirectory.path,
                ],
                environment: cleanEnvironment,
                currentDirectory: nil
            )
            helperOwnsWorkingDirectory = true
            return .installing
        } catch {
            return .failed(.network)
        }
    }

    private func latestReleaseURL() -> URL {
        URL(
            string: "https://api.github.com/repos/\(configuration.repositoryOwner)/\(configuration.repositoryName)/releases/latest"
        )!
    }

    private func sourceURLMatchesConfiguredRelease(
        _ url: URL,
        version: LocalFlowVersion
    ) -> Bool {
        guard url.scheme == "https", url.host == "github.com" else { return false }
        let expectedPath = "/\(configuration.repositoryOwner)/\(configuration.repositoryName)"
            + "/releases/download/v\(version.rawValue)"
            + "/LocalFlow-\(version.rawValue)-source.tar.gz"
        return url.path == expectedPath && url.query == nil && url.fragment == nil
    }

    private func runTar(listing archiveURL: URL) async throws -> String {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tzf", archiveURL.path],
            environment: [:],
            currentDirectory: nil
        )
        guard result.status == 0 else { throw UpdateServiceError.tarFailed }
        return result.standardOutput
    }

    private func runTar(extract archiveURL: URL, into directory: URL) async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archiveURL.path, "-C", directory.path],
            environment: [:],
            currentDirectory: nil
        )
        guard result.status == 0 else { throw UpdateServiceError.tarFailed }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        try handle.close()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func bundleIdentifier(of app: URL) throws -> String {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let identifier = plist["CFBundleIdentifier"] as? String
        else {
            throw UpdateServiceError.signatureCheckFailed
        }
        return identifier
    }

    private func codeRequirement(of app: URL) async throws -> String? {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "-r-", app.path],
            environment: [:],
            currentDirectory: nil
        )
        guard result.status == 0 else { return nil }
        let output = result.standardOutput + "\n" + result.standardError
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("designated =>") }
    }

    private func signingIdentityFingerprint(label: String) async throws -> String? {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            environment: [:],
            currentDirectory: nil
        )
        guard result.status == 0 else { return nil }
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.contains("\"\(label)\"") else { continue }
            let prefix = text.split(separator: ")", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1).first
            return prefix.map(String.init)
        }
        return nil
    }

    public static func archiveEntriesAreSafe(_ listing: String, topLevelPrefix: String) -> Bool {
        let prefix = topLevelPrefix + "/"
        let lines = listing.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return false }
        for line in lines {
            let entry = String(line)
            guard entry.hasPrefix(prefix) else { return false }
            let remainder = String(entry.dropFirst(prefix.count))
            guard !remainder.contains(".."),
                  !entry.hasPrefix("/"),
                  !entry.contains("\\"),
                  remainder.split(separator: "/").allSatisfy({ !$0.isEmpty })
            else {
                return false
            }
        }
        return true
    }

    private enum UpdateServiceError: Error {
        case tarFailed
        case signatureCheckFailed
    }
}
