import Foundation
import CryptoKit
import LocalFlowCore
import LocalFlowPlatform

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

private struct FakeTransport: UpdateTransport {
    var releaseData: Data
    var manifestOverride: Data?
    var sourceData: Data = fixtureArchive
    var downloadError: (any Error)?

    func data(from url: URL) async throws -> Data {
        if url.absoluteString.contains("/releases/latest") {
            return releaseData
        }
        return manifestOverride ?? Data()
    }

    func download(from url: URL, to destination: URL) async throws {
        if let downloadError { throw downloadError }
        try sourceData.write(to: destination)
    }
}

private struct FakeRunner: CommandRunning {
    var results: [String: CommandResult] = [:]

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> CommandResult {
        if executable.lastPathComponent == "security" {
            return CommandResult(
                status: 0,
                standardOutput: "  1) ABCD \"Fixture Identity\"\n",
                standardError: ""
            )
        }
        if executable.lastPathComponent == "tar" || executable.lastPathComponent == "codesign" {
            return try await ProcessRunner().run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory
            )
        }
        let key = executable.lastPathComponent + " " + arguments.joined(separator: " ")
        return results[key] ?? CommandResult(status: 0, standardOutput: "", standardError: "")
    }
}

private let fixtureArchive = Data(
    base64Encoded: """
    H4sIAIZle2oAA+2Yy27TQBSG3UoIka5hiQaxRJ3M3emiEikXNVIKvYGKhBRNXUMinMTYbpOHYMmCPQ/GqzCmQaEO09TUNlJ8vmTk2PJlbOc/89m41x17OngZjCebBDNMnOIhhLhSol9TdTk1/J4SwgRHVDKulGKKKESokEQ5qIy+LHAeJzoyXdHRSF+c6di23qTv+8E1+7l6Uqj4jpbEnQd3nXXH2dMeen2ETtCMdJlzzzRm2mfT0vnvN9tl+/j4cPYz3eKbaRuZVdbmy+974yHWYRj4OIzGF/5IjzzfWVt3vv748vQheS8LOEnAxr6e7vr6zI+a5dWBpfmnJJN/xbhw0LTAPlipef45QcNkMPS3qdtSwqUtKrCkxHy53GpIF3U7O+3DZ7udty/wVCdJhP8W1+32QacdvHqyd7AjJifP3zTEFjoyG3XfXbfRHxlv/O/rUFcyqW+WcYxl+U9nMuM/Fyb/lVT+muc/e/9xL/aiQZhYr8M/kN//FHUl+F8lgP/Vmmz+5z5YXB3I73+uyzj4XxVY/I9TJgQF/1t5svmfpb5QD8zvf4pwDv5XBYv+t6+9T/qjj+PJ4ENSyDHM9VBC5PE/13zA/yoB/K/W2P2vuDqwNP9Z/2PEFADwvyqwvf9zjf9x8L+VZzH/RY/+y/NPOMv6nysJjP9VcOV+ozDQnt8fB6b+QyJrge35D/fCy3/GpinbOO7f5hi5/d+M/1JA/isB/L/W2PI/fw64fR3I7/9MEgb+XwUW/xekRUkL/H/lseW/uNH/Bv5PRXb8l+n7Xxj/y+fxo+bpYNQ81XEfMggAAFAjfgKucxuCADAAAA==
    """
)!

private func manifest(version: String = "0.2.0", sourceData: Data = fixtureArchive) throws -> LocalFlowReleaseManifest {
    var hasher = SHA256()
    hasher.update(data: sourceData)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return try LocalFlowReleaseManifest(
        version: LocalFlowVersion(version),
        commit: String(repeating: "a", count: 40),
        sourceURL: URL(
            string: "https://github.com/codejunkie99/LocalFlow/releases/download/v\(version)/LocalFlow-\(version)-source.tar.gz"
        )!,
        sourceSHA256: digest
    )
}

private func makeService(
    transport: UpdateTransport,
    runner: CommandRunning,
    installedVersion: LocalFlowVersion = try! LocalFlowVersion("0.1.0")
) throws -> UpdateService {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let app = root.appendingPathComponent("LocalFlow.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let configuration = UpdateService.Configuration(
        repositoryOwner: "codejunkie99",
        repositoryName: "LocalFlow",
        installedAppURL: app,
        installedVersion: installedVersion,
        storedSigningIdentity: "Fixture Identity",
        signingFingerprint: "ABCD"
    )
    return UpdateService(
        configuration: configuration,
        transport: transport,
        runner: runner
    )
}

func testEqualVersionDoesNotUpdate() async throws {
    let sameVersion = try manifest(version: "0.1.0")
    let payload = """
        {"assets":[{"name":"localflow-release.json","browser_download_url":"https://example.com/localflow-release.json"}]}
        """
    let releaseData = Data(payload.utf8)
    var transport = FakeTransport(
        releaseData: releaseData,
        sourceData: Data()
    )
    transport.manifestOverride = try JSONEncoder().encode(sameVersion)
    let service = try makeService(
        transport: transport,
        runner: FakeRunner(),
        installedVersion: try! LocalFlowVersion("0.1.0")
    )
    let state = await service.check(currentVersion: try! LocalFlowVersion("0.1.0"))
    assert(state == .current, "equal version reports current without update")
}

func testNewerManifestBecomesReady() async throws {
    let payload = """
        {"assets":[{"name":"localflow-release.json","browser_download_url":"https://example.com/localflow-release.json"}]}
        """
    var transport = FakeTransport(releaseData: Data(payload.utf8))
    transport.manifestOverride = try JSONEncoder().encode(manifest())
    let service = try makeService(transport: transport, runner: FakeRunner())
    let state = await service.check(currentVersion: try! LocalFlowVersion("0.1.0"))
    assert(state == .ready(version: try! LocalFlowVersion("0.2.0")), "newer manifest becomes ready")
}

func testManifestSourceMustMatchRepositoryRelease() async throws {
    let payload = """
        {"assets":[{"name":"localflow-release.json","browser_download_url":"https://github.com/codejunkie99/LocalFlow/releases/download/v0.2.0/localflow-release.json"}]}
        """
    var transport = FakeTransport(releaseData: Data(payload.utf8))
    let invalidSource = try LocalFlowReleaseManifest(
        version: try LocalFlowVersion("0.2.0"),
        commit: String(repeating: "a", count: 40),
        sourceURL: URL(string: "https://example.com/untrusted-source.tar.gz")!,
        sourceSHA256: String(repeating: "b", count: 64)
    )
    transport.manifestOverride = try JSONEncoder().encode(invalidSource)
    let service = try makeService(transport: transport, runner: FakeRunner())
    let state = await service.check(currentVersion: try LocalFlowVersion("0.1.0"))
    assert(state == .failed(.invalidManifest), "source archive must belong to the configured GitHub release")
}

func testChecksumMismatchNeverExtracts() async throws {
    var transport = FakeTransport(
        releaseData: Data(),
        sourceData: Data("tampered archive".utf8)
    )
    transport.manifestOverride = try JSONEncoder().encode(manifest())
    let service = try makeService(transport: transport, runner: FakeRunner())
    let state = await service.install(try manifest())
    assert(state == .failed(.checksumMismatch), "checksum mismatch reports failure")
}

func testSigningIdentityMissingStopsInstall() async throws {
    let sourceData = fixtureArchive
    var transport = FakeTransport(
        releaseData: Data(),
        sourceData: sourceData
    )
    transport.manifestOverride = try JSONEncoder().encode(manifest(sourceData: sourceData))
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let app = root.appendingPathComponent("LocalFlow.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let service = UpdateService(
        configuration: UpdateService.Configuration(
            repositoryOwner: "codejunkie99",
            repositoryName: "LocalFlow",
            installedAppURL: app,
            installedVersion: try! LocalFlowVersion("0.1.0"),
            storedSigningIdentity: nil,
            signingFingerprint: nil
        ),
        transport: transport,
        runner: FakeRunner()
    )
    let state = await service.install(try manifest())
    assert(state == .failed(.signingIdentityMissing), "missing stored identity stops install")
}

func testBuildFailureNeverStartsReplacement() async throws {
    var runner = FakeRunner()
    runner.results["package-app.sh "] = CommandResult(
        status: 1,
        standardOutput: "",
        standardError: "build failed"
    )
    let sourceData = fixtureArchive
    var transport = FakeTransport(
        releaseData: Data(),
        sourceData: sourceData
    )
    transport.manifestOverride = try JSONEncoder().encode(manifest(sourceData: sourceData))
    let service = try makeService(transport: transport, runner: runner)
    let state = await service.install(try manifest())
    assert(state == .failed(.buildFailed), "build failure reports buildFailed")
}

func testArchiveEntriesRejectTraversalAndForeignFiles() {
    let safe = "LocalFlow-0.2.0/\nLocalFlow-0.2.0/Package.swift\n"
    assert(
        UpdateService.archiveEntriesAreSafe(safe, topLevelPrefix: "LocalFlow-0.2.0"),
        "valid archive entries pass validation"
    )
    let traversal = "LocalFlow-0.2.0/../../evil\n"
    assert(
        !UpdateService.archiveEntriesAreSafe(traversal, topLevelPrefix: "LocalFlow-0.2.0"),
        "path traversal entry is rejected"
    )
    let absolute = "/LocalFlow-0.2.0/evil\n"
    assert(
        !UpdateService.archiveEntriesAreSafe(absolute, topLevelPrefix: "LocalFlow-0.2.0"),
        "absolute entry is rejected"
    )
    let foreign = "OtherProject/File.swift\n"
    assert(
        !UpdateService.archiveEntriesAreSafe(foreign, topLevelPrefix: "LocalFlow-0.2.0"),
        "entry outside the source prefix is rejected"
    )
}

func testInvalidManifestReportsFailure() async throws {
    var transport = FakeTransport(releaseData: Data("not json".utf8))
    transport.manifestOverride = Data("not json".utf8)
    let service = try makeService(transport: transport, runner: FakeRunner())
    let state = await service.check(currentVersion: try! LocalFlowVersion("0.1.0"))
    assert(state == .failed(.invalidManifest), "invalid manifest reports failure")
}

try await {
    try await testEqualVersionDoesNotUpdate()
    try await testNewerManifestBecomesReady()
    try await testManifestSourceMustMatchRepositoryRelease()
    try await testChecksumMismatchNeverExtracts()
    try await testSigningIdentityMissingStopsInstall()
    try await testBuildFailureNeverStartsReplacement()
    try await testInvalidManifestReportsFailure()
    testArchiveEntriesRejectTraversalAndForeignFiles()
}()

print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
