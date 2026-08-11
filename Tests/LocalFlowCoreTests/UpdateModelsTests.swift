import Foundation
import LocalFlowCore

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

let current = try! LocalFlowVersion("0.1.0")
let newer = try! LocalFlowVersion("0.2.0")
assert(newer > current, "semantic versions order numerically")
let v110 = try! LocalFlowVersion("1.10.0")
let v199 = try! LocalFlowVersion("1.9.9")
assert(v110 > v199, "minor components compare numerically")
assert((try? LocalFlowVersion("0.1")) == nil, "invalid version is rejected")
assert((try? LocalFlowVersion("0.1.0.0")) == nil, "four-component version is rejected")
assert((try? LocalFlowVersion("abc.1.0")) == nil, "nonnumeric component is rejected")
assert(LocalFlowVersion(rawValue: "0.1.0") == current, "rawValue initializer round-trips")

let manifestData = """
    {"version":"0.2.0","commit":"0123456789abcdef0123456789abcdef01234567","source_url":"https://github.com/codejunkie99/LocalFlow/releases/download/v0.2.0/LocalFlow-0.2.0-source.tar.gz","source_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
    """.data(using: .utf8)!
let manifest = try! JSONDecoder().decode(LocalFlowReleaseManifest.self, from: manifestData)
assert(manifest.version == newer, "manifest decodes version")
assert(manifest.sourceSHA256.count == 64, "manifest requires a SHA-256 digest")
assert(manifest.sourceURL.absoluteString.contains("v0.2.0"), "manifest decodes source URL")
assert(manifest.commit.count == 40, "manifest decodes commit")
let uppercaseCommit = String(data: manifestData, encoding: .utf8)!
    .replacingOccurrences(
        of: "0123456789abcdef0123456789abcdef01234567",
        with: "0123456789ABCDEF0123456789ABCDEF01234567"
    )
    .data(using: .utf8)!
assert(
    (try? JSONDecoder().decode(LocalFlowReleaseManifest.self, from: uppercaseCommit)) == nil,
    "manifest rejects uppercase commit hashes"
)

let encoded = try! JSONEncoder().encode(manifest)
let decoded = try! JSONDecoder().decode(LocalFlowReleaseManifest.self, from: encoded)
assert(decoded == manifest, "manifest round-trips through coding keys")

let states: [UpdateState] = [
    .idle,
    .checking,
    .downloading(progress: 0.4),
    .building,
    .installing,
    .current,
    .ready(version: newer),
    .failed(.checksumMismatch),
    .failed(.signingIdentityMissing),
]
assert(states.count == 9, "all update states exist")
assert(states.contains(.ready(version: newer)), "ready state carries version")
assert(states.contains(.failed(.signingIdentityMissing)), "failed state carries reason")
assert(UpdateFailure.buildFailed != UpdateFailure.checksumMismatch, "update failures distinguish causes")

print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
