import AppKit
import CryptoKit
import Foundation
import LocalFlowCore

struct UpdaterArguments {
    var parentPID: pid_t?
    var current: URL?
    var staged: URL?
    var previous: URL?
    var database: URL?
    var databaseBackup: URL?
    var receipt: URL?
    var expectedBundleID = "dev.localflow.app"
    var expectedRequirement: String?
    var cleanupRoot: URL?
    var skipLaunch = false
    var dryRun = false
    var testMode = false
    var simulateLaunchTimeout = false
}

func parseArguments(_ arguments: [String]) throws -> UpdaterArguments {
    var parsed = UpdaterArguments()
    var index = 1
    while index < arguments.count {
        let flag = arguments[index]
        func nextValue() throws -> String {
            index += 1
            guard index < arguments.count else {
                throw ArgumentError.missingValue(flag)
            }
            return arguments[index]
        }
        switch flag {
        case "--parent-pid":
            parsed.parentPID = pid_t(try nextValue()) ?? -1
        case "--current":
            parsed.current = URL(fileURLWithPath: try nextValue())
        case "--staged":
            parsed.staged = URL(fileURLWithPath: try nextValue())
        case "--previous":
            parsed.previous = URL(fileURLWithPath: try nextValue())
        case "--database":
            parsed.database = URL(fileURLWithPath: try nextValue())
        case "--database-backup":
            parsed.databaseBackup = URL(fileURLWithPath: try nextValue())
        case "--receipt":
            parsed.receipt = URL(fileURLWithPath: try nextValue())
        case "--expected-bundle-id":
            parsed.expectedBundleID = try nextValue()
        case "--expected-requirement":
            parsed.expectedRequirement = try nextValue()
        case "--cleanup-root":
            parsed.cleanupRoot = URL(fileURLWithPath: try nextValue())
        case "--skip-launch":
            parsed.skipLaunch = true
        case "--dry-run":
            parsed.dryRun = true
        case "--test-mode":
            parsed.testMode = true
        case "--simulate-launch-timeout":
            parsed.simulateLaunchTimeout = true
        default:
            throw ArgumentError.unknown(flag)
        }
        index += 1
    }
    guard let current = parsed.current,
          let staged = parsed.staged,
          let previous = parsed.previous
    else {
        throw ArgumentError.missingRequired
    }
    guard current.pathExtension == "app",
          staged.pathExtension == "app",
          previous.pathExtension == "app"
    else {
        throw ArgumentError.nonAppPath
    }
    let root = "/"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for url in [current, staged, previous] {
        let path = url.path
        let isDirectHomeChild = path.hasPrefix(home + "/")
            && path.dropFirst(home.count + 1).firstIndex(of: "/") == nil
        let isUnsafe = !path.hasPrefix(root)
            || path == root
            || path.hasPrefix("/tmp/")
            || isDirectHomeChild
        guard !isUnsafe else {
            throw ArgumentError.unsafePath
        }
    }
    guard current.deletingLastPathComponent() == previous.deletingLastPathComponent(),
          previous.lastPathComponent == ".LocalFlow.previous.app"
    else {
        throw ArgumentError.unsafePath
    }
    if let cleanupRoot = parsed.cleanupRoot {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard cleanupRoot.standardizedFileURL.path.hasPrefix(temporaryRoot + "/LocalFlowUpdate-") else {
            throw ArgumentError.unsafePath
        }
    }
    return parsed
}

enum ArgumentError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknown(String)
    case missingRequired
    case nonAppPath
    case unsafePath

    var description: String {
        switch self {
        case .missingValue(let flag): "missing value for \(flag)"
        case .unknown(let flag): "unknown argument \(flag)"
        case .missingRequired: "missing required replacement paths"
        case .nonAppPath: "replacement paths must end in .app"
        case .unsafePath: "replacement paths must be absolute and outside home or tmp"
        }
    }
}

func waitForParentExit(pid: pid_t, timeoutSeconds: Int, testMode: Bool) async throws {
    guard !testMode else { return }
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        if kill(pid, 0) != 0 {
            return
        }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw UpdaterFailure.parentStillRunning
}

func verifyStagedBundle(
    staged: URL,
    expectedBundleID: String,
    expectedRequirement: String?,
    testMode: Bool
) throws {
    let bundleID = try plistString(path: staged.appendingPathComponent("Contents/Info.plist"), key: "CFBundleIdentifier")
    guard bundleID == expectedBundleID else {
        throw UpdaterFailure.bundleIDMismatch
    }

    guard !testMode, let expectedRequirement else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-d", "-r-", staged.path]
    let pipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let requirement = String(data: data, encoding: .utf8)?
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { $0.hasPrefix("designated =>") }
    guard requirement == expectedRequirement else {
        throw UpdaterFailure.signatureMismatch
    }
}

func plistString(path: URL, key: String) throws -> String {
    let data = try Data(contentsOf: path)
    guard let plist = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    ) as? [String: Any],
    let value = plist[key] as? String
    else {
        throw UpdaterFailure.invalidStagedBundle
    }
    return value
}

func backupDatabase(database: URL?, to backup: URL?) throws {
    guard let database, let backup else { return }
    try FileManager.default.createDirectory(
        at: backup.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: backup.path),
       FileManager.default.fileExists(atPath: database.path) {
        try FileManager.default.copyItem(at: database, to: backup)
    }
}

func restoreDatabase(backup: URL?, to database: URL?) {
    guard let backup, let database else { return }
    try? FileManager.default.removeItem(at: database)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
    if FileManager.default.fileExists(atPath: backup.path) {
        try? FileManager.default.copyItem(at: backup, to: database)
    }
}

func moveItem(_ source: URL, to destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: source, to: destination)
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    var hasher = SHA256()
    while try autoreleasepool(invoking: {
        guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
        hasher.update(data: chunk)
        return true
    }) {}
    try handle.close()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private struct LaunchReceipt: Codable {
    let version: String
    let executableSHA256: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executableSHA256 = "executable_sha256"
    }
}

func waitForLaunchReceipt(
    at receipt: URL,
    expectedVersion: String,
    expectedDigest: String,
    timeoutSeconds: Int,
    simulateTimeout: Bool
) async throws {
    if simulateTimeout { throw UpdaterFailure.launchFailed }
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        if let data = try? Data(contentsOf: receipt),
           let decoded = try? JSONDecoder().decode(LaunchReceipt.self, from: data),
           decoded.version == expectedVersion,
           decoded.executableSHA256 == expectedDigest {
            return
        }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw UpdaterFailure.launchFailed
}

func launchApplication(at url: URL, receipt: URL?) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    if let receipt {
        configuration.environment = ["LOCALFLOW_UPDATE_RECEIPT": receipt.path]
    }
    let launchResult: Result<Void, any Error> = await withCheckedContinuation { continuation in
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            continuation.resume(returning: error.map(Result.failure) ?? .success(()))
        }
    }
    if case .failure = launchResult {
        throw UpdaterFailure.launchFailed
    }
}

enum UpdaterFailure: Error, CustomStringConvertible {
    case parentStillRunning
    case invalidStagedBundle
    case bundleIDMismatch
    case signatureMismatch
    case replacementFailed
    case launchFailed

    var description: String {
        switch self {
        case .parentStillRunning: "parent app did not quit in time"
        case .invalidStagedBundle: "staged bundle is invalid"
        case .bundleIDMismatch: "staged bundle identifier does not match dev.localflow.app"
        case .signatureMismatch: "staged code requirement does not match"
        case .replacementFailed: "app replacement failed"
        case .launchFailed: "new app did not launch or write its receipt"
        }
    }
}

struct ResultWriter: TextOutputStream {
    func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

let arguments = try parseArguments(CommandLine.arguments)
guard let current = arguments.current,
      let staged = arguments.staged,
      let previous = arguments.previous
else {
    throw ArgumentError.missingRequired
}

var errorOutput = ResultWriter()

defer {
    if let cleanupRoot = arguments.cleanupRoot {
        try? FileManager.default.removeItem(at: cleanupRoot)
    }
}

do {
    try await waitForParentExit(
        pid: arguments.parentPID ?? -1,
        timeoutSeconds: 20,
        testMode: arguments.testMode
    )
    try verifyStagedBundle(
        staged: staged,
        expectedBundleID: arguments.expectedBundleID,
        expectedRequirement: arguments.expectedRequirement,
        testMode: arguments.testMode
    )
    try backupDatabase(database: arguments.database, to: arguments.databaseBackup)

    if arguments.dryRun {
        print("dry-run: verified staged bundle; would replace \(current.path)")
        exit(0)
    }

    try moveItem(current, to: previous)
    do {
        try moveItem(staged, to: current)
    } catch {
        try? moveItem(previous, to: current)
        throw UpdaterFailure.replacementFailed
    }

    let version = try plistString(
        path: current.appendingPathComponent("Contents/Info.plist"),
        key: "CFBundleShortVersionString"
    )
    let executable = current.appendingPathComponent("Contents/MacOS/LocalFlowApp")
    let digest = try sha256(of: executable)

    if arguments.skipLaunch {
        if let receipt = arguments.receipt {
            let encoded = try JSONEncoder().encode(
                LaunchReceipt(version: version, executableSHA256: digest)
            )
            try encoded.write(to: receipt, options: .atomic)
        }
    } else {
        do {
            if let receipt = arguments.receipt {
                try? FileManager.default.removeItem(at: receipt)
            }
            if !arguments.testMode {
                try await launchApplication(at: current, receipt: arguments.receipt)
            }
            guard let receipt = arguments.receipt else {
                throw UpdaterFailure.launchFailed
            }
            try await waitForLaunchReceipt(
                at: receipt,
                expectedVersion: version,
                expectedDigest: digest,
                timeoutSeconds: 15,
                simulateTimeout: arguments.simulateLaunchTimeout
            )
        } catch {
            try? moveItem(current, to: current.deletingLastPathComponent()
                .appendingPathComponent(".LocalFlow.failed.app"))
            try? moveItem(previous, to: current)
            restoreDatabase(backup: arguments.databaseBackup, to: arguments.database)
            if !arguments.testMode {
                try? await launchApplication(at: current, receipt: nil)
            }
            throw UpdaterFailure.launchFailed
        }
    }

    print("update complete: \(current.path)")
} catch {
    print("LocalFlowUpdater failed: \(error)", to: &errorOutput)
    exit(1)
}
