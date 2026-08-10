# Stable Setup and One-Click Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install one canonically located LocalFlow app per Mac and update it from tagged GitHub source releases without losing its signing identity, permissions, settings, or persistent history.

**Architecture:** A first-run shell setup selects or creates one stable per-Mac signing identity and installs to `~/Applications/LocalFlow.app`. The app's `UpdateService` downloads and verifies a tagged source release, builds and signs a staged bundle, then launches a minimal helper outside the bundle to checkpoint history, swap apps with rollback, and relaunch.

**Tech Stack:** Swift 6.2, SwiftUI, Foundation `URLSession`/`Process`, Security/code-sign tools, POSIX shell, GitHub Releases, macOS code signing.

---

## File structure

- Create `SETUP.md`: one source of truth for first installation and second-Mac setup.
- Create `scripts/setup-localflow.sh`: prerequisites, local signer, build, canonical install, verification, and launch.
- Create `scripts/lib/localflow-signing.sh`: pure identity selection helpers plus keychain identity creation.
- Create `Tests/ScriptTests/setup-localflow-tests.sh`: non-mutating shell tests with fixture identity output.
- Create `Sources/LocalFlowCore/UpdateModels.swift`: manifest, version, state, and replacement plan values.
- Create `Tests/LocalFlowCoreTests/UpdateModelsTests.swift`: version/manifest/plan tests.
- Create `Sources/LocalFlowPlatform/UpdateService.swift`: release lookup, download, checksum, extraction, build, signing, and helper launch.
- Create `Tests/LocalFlowPlatformTests/UpdateServiceTests.swift`: fake transport/process/filesystem orchestration tests.
- Create `Sources/LocalFlowUpdater/main.swift`: verified replacement, rollback, launch receipt.
- Create `Tests/UpdaterTests/run-updater-tests.sh`: helper integration tests in temporary app directories.
- Modify `Package.swift`: add `LocalFlowUpdater` executable.
- Modify `scripts/package-app.sh`: package both executables and signing metadata.
- Create `scripts/publish-source-release.sh`: manual, no-CI source release and manifest generation.
- Modify `Sources/LocalFlowApp/AppModel.swift` and `MenuContentView.swift`: update UI and progress.
- Modify `Resources/Info.plist`, `README.md`, `docs/INSTALL.md`, `docs/ARCHITECTURE.md`, and `scripts/run-tests.sh`.

### Task 1: Model releases, versions, and updater states

**Files:**
- Create: `Sources/LocalFlowCore/UpdateModels.swift`
- Create: `Tests/LocalFlowCoreTests/UpdateModelsTests.swift`

- [ ] **Step 1: Write failing version and manifest tests**

```swift
let current = try! LocalFlowVersion("0.1.0")
let newer = try! LocalFlowVersion("0.2.0")
assert(newer > current, "semantic versions order numerically")
assert((try? LocalFlowVersion("0.1")) == nil, "invalid version is rejected")

let data = #"{"version":"0.2.0","commit":"0123456789abcdef0123456789abcdef01234567","source_url":"https://github.com/codejunkie99/LocalFlow/releases/download/v0.2.0/LocalFlow-0.2.0-source.tar.gz","source_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}"#.data(using: .utf8)!
let manifest = try! JSONDecoder().decode(LocalFlowReleaseManifest.self, from: data)
assert(manifest.version == newer, "manifest decodes version")
assert(manifest.sourceSHA256.count == 64, "manifest requires a SHA-256 digest")
```

Add state assertions for `.idle`, `.checking`, `.downloading(progress:)`, `.building`, `.installing`, `.current`, `.ready(version:)`, and `.failed(UpdateFailure)`.

- [ ] **Step 2: Run tests to verify missing-type failure**

Run: `./scripts/run-tests.sh`

Expected: compilation fails for missing update models.

- [ ] **Step 3: Implement strict values**

Create:

```swift
public struct LocalFlowVersion: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    public let rawValue: String
    public init(_ rawValue: String) throws
    public init(rawValue: String) { self = try! LocalFlowVersion(rawValue) }
}

public struct LocalFlowReleaseManifest: Codable, Sendable, Equatable {
    public let version: LocalFlowVersion
    public let commit: String
    public let sourceURL: URL
    public let sourceSHA256: String
}

public enum UpdateState: Sendable, Equatable {
    case idle
    case checking
    case downloading(progress: Double)
    case building
    case installing
    case current
    case ready(version: LocalFlowVersion)
    case failed(UpdateFailure)
}
public enum UpdateFailure: String, Error, Sendable, Equatable {
    case network, invalidManifest, checksumMismatch, unsafeArchive
    case buildFailed, signingIdentityMissing, signatureMismatch
    case databaseBackupFailed, replacementFailed, relaunchFailed
}
```

Encode manifest keys with `CodingKeys` for `source_url` and `source_sha256`. Accept exactly three nonnegative numeric version components. Compare component tuples, not strings. Validate a 40- or 64-character lowercase hexadecimal commit and a 64-character lowercase hexadecimal SHA-256.

- [ ] **Step 4: Run tests and commit**

Run: `./scripts/run-tests.sh`

Expected: new model tests and all existing tests pass.

```bash
git add Sources/LocalFlowCore/UpdateModels.swift Tests/LocalFlowCoreTests/UpdateModelsTests.swift
git commit -m "feat: model LocalFlow updates"
```

### Task 2: Build non-mutating signing selection helpers

**Files:**
- Create: `scripts/lib/localflow-signing.sh`
- Create: `Tests/ScriptTests/setup-localflow-tests.sh`
- Modify: `scripts/run-tests.sh`

- [ ] **Step 1: Write failing shell tests with identity fixtures**

The test will source only the library and pass fixture text into `select_localflow_identity`:

```bash
developer_id='  1) AAA "Developer ID Application: Example (TEAMID)"'
apple_dev='  1) BBB "Apple Development: Example (TEAMID)"'
both="$apple_dev
$developer_id"

assert_eq "Developer ID Application: Example (TEAMID)" "$(select_localflow_identity "$both")"
assert_eq "Apple Development: Example (TEAMID)" "$(select_localflow_identity "$apple_dev")"
assert_eq "" "$(select_localflow_identity '0 valid identities found')"
```

Add tests for `identity_label`, `identity_fingerprint`, and rejection of identities whose label is not exactly Developer ID Application, Apple Development, or `LocalFlow Local Signing`.

- [ ] **Step 2: Run the shell test to verify failure**

Run: `bash Tests/ScriptTests/setup-localflow-tests.sh`

Expected: failure because the library does not exist.

- [ ] **Step 3: Implement pure parsers before keychain mutation**

Implement POSIX-compatible functions using `awk` and fixed-string matching. Selection order is Developer ID Application, Apple Development, then LocalFlow Local Signing. Functions must accept identity-list text as an argument; they must not execute `security` internally.

- [ ] **Step 4: Add shell tests to the project test script**

Append:

```bash
for test_file in Tests/ScriptTests/*.sh; do
    echo "=== Running $(basename "$test_file") ==="
    bash "$test_file"
done
```

- [ ] **Step 5: Run and commit**

Run: `./scripts/run-tests.sh`

Expected: all Swift and shell tests pass.

```bash
git add scripts/lib/localflow-signing.sh Tests/ScriptTests/setup-localflow-tests.sh scripts/run-tests.sh
git commit -m "test: define stable signing selection"
```

### Task 3: Implement one-time setup and local signing

**Files:**
- Create: `scripts/setup-localflow.sh`
- Modify: `scripts/lib/localflow-signing.sh`
- Create: `SETUP.md`
- Modify: `docs/INSTALL.md`

- [ ] **Step 1: Add dry-run setup tests**

Extend the shell test to invoke:

```bash
LOCALFLOW_SETUP_DRY_RUN=1 \
LOCALFLOW_IDENTITY_FIXTURE="$apple_dev" \
bash scripts/setup-localflow.sh --install-root "$tmp_root"
```

Assert output contains the prerequisite checks, selected identity, canonical destination, package command, codesign verification, and launch command, while no app or keychain item is created.

- [ ] **Step 2: Run the dry-run test to verify failure**

Run: `./scripts/run-tests.sh`

Expected: failure because `setup-localflow.sh` is absent.

- [ ] **Step 3: Implement prerequisite and resume flow**

The script must use `set -euo pipefail`, resolve its repository root, refuse non-arm64 or macOS below 26, and check `xcode-select -p`, `swift --version`, `git --version`, and writable `~/Applications`. If Command Line Tools are absent, run `xcode-select --install`, print the exact same setup command, and exit without changing the app.

- [ ] **Step 4: Implement the LocalFlow-only self-signed identity**

When no acceptable identity exists, generate a temporary RSA key and certificate with subject `CN=LocalFlow Local Signing`, Key Usage `digitalSignature`, and Extended Key Usage `codeSigning`; export to a password-protected PKCS#12 in a `mktemp -d` directory; import into the login keychain with `/usr/bin/security import`; authorize `/usr/bin/codesign`; verify it appears in `security find-identity -v -p codesigning`; then remove the temporary directory through a trap. Never print the generated password or private key.

- [ ] **Step 5: Package and install canonically**

Call:

```bash
LOCALFLOW_SIGNING_IDENTITY="$identity" ./scripts/package-app.sh
```

Verify `CFBundleIdentifier` equals `dev.localflow.app`; use `ditto` into `~/Applications/.LocalFlow.staged.app`; verify with `codesign --verify --deep --strict`; move an existing canonical app to `.LocalFlow.previous.app`; rename staged to `LocalFlow.app`; and restore previous on failure. Store the identity label and SHA-256 certificate fingerprint with:

```bash
defaults write dev.localflow.app LocalFlowSigningIdentity "$identity"
defaults write dev.localflow.app LocalFlowSigningFingerprint "$fingerprint"
```

- [ ] **Step 6: Write SETUP.md as the first-run front door**

Include: clone command, `cd LocalFlow`, setup command, Command Line Tools resume behavior, stable signing explanation, canonical path, exact permission steps, first TextEdit test, update behavior, and warning not to delete the `LocalFlow Local Signing` identity. Put Developer ID/Apple Development reuse before local identity creation.

- [ ] **Step 7: Run safe checks and commit**

Run:

```bash
./scripts/run-tests.sh
LOCALFLOW_SETUP_DRY_RUN=1 bash scripts/setup-localflow.sh
if command -v shellcheck >/dev/null; then
    shellcheck scripts/setup-localflow.sh scripts/lib/localflow-signing.sh
fi
git diff --check
```

Expected: tests and dry-run pass; no keychain or installed-app mutation occurs during automated verification.

```bash
git add SETUP.md docs/INSTALL.md scripts/setup-localflow.sh scripts/lib/localflow-signing.sh Tests/ScriptTests/setup-localflow-tests.sh
git commit -m "feat: add stable first-time setup"
```

### Task 4: Package a minimal updater helper

**Files:**
- Modify: `Package.swift`
- Create: `Sources/LocalFlowUpdater/main.swift`
- Create: `Tests/UpdaterTests/run-updater-tests.sh`
- Modify: `scripts/run-tests.sh`
- Modify: `scripts/package-app.sh`

- [ ] **Step 1: Write failing helper integration tests**

Build temporary `current.app`, `staged.app`, `previous.app`, and database/backup fixtures containing marker files. Invoke the helper with `--dry-run` and with `--skip-launch` in the temporary root. Assert successful replacement moves current to previous and staged to current; an invalid staged bundle leaves current untouched; and a simulated launch-receipt timeout restores both prior app and prior database.

- [ ] **Step 2: Run the helper test to verify failure**

Run: `bash Tests/UpdaterTests/run-updater-tests.sh`

Expected: failure because the helper product is missing.

- [ ] **Step 3: Add the executable target and exact argument contract**

Add `.executable(name: "LocalFlowUpdater", targets: ["LocalFlowUpdater"])` and an executable target depending on `LocalFlowCore`. Define arguments:

```text
--parent-pid <pid>
--current <absolute-app-path>
--staged <absolute-app-path>
--previous <absolute-app-path>
--database <absolute-db-path>
--database-backup <absolute-backup-path>
--receipt <absolute-receipt-path>
--expected-bundle-id dev.localflow.app
--expected-requirement <codesign requirement text>
--skip-launch
```

Reject missing, relative, root, home-directory, or non-`.app` replacement paths. Wait for the parent PID to exit with bounded polling. Reverify staged bundle ID and designated requirement before rename.

- [ ] **Step 4: Implement replacement and rollback**

Use `FileManager.moveItem` only within the validated canonical parent. Never recursively delete an unresolved path. Move current to previous, staged to current, launch with `NSWorkspace.shared.openApplication`, and wait up to 15 seconds for the new app to write the expected receipt. On timeout or launch error, move failed current aside, restore previous, restore the database backup, and relaunch the old app. Keep only one previous bundle after success.

- [ ] **Step 5: Package the helper**

Build both release products. Copy `LocalFlowUpdater` to `Contents/Helpers/LocalFlowUpdater`, sign nested helper first, then sign the app. Verify helper and app with strict codesign. Do not place source archives or signing secrets inside the bundle.

- [ ] **Step 6: Run tests and commit**

Run: `./scripts/run-tests.sh && ./scripts/package-app.sh && codesign --verify --deep --strict --verbose=2 dist/LocalFlow.app`

Expected: helper integration tests pass and the nested helper satisfies the app signature.

```bash
git add Package.swift Sources/LocalFlowUpdater Tests/UpdaterTests scripts/run-tests.sh scripts/package-app.sh
git commit -m "feat: add rollback-safe updater helper"
```

### Task 5: Implement release lookup, archive verification, and local build

**Files:**
- Create: `Sources/LocalFlowPlatform/UpdateService.swift`
- Create: `Tests/LocalFlowPlatformTests/UpdateServiceTests.swift`

- [ ] **Step 1: Write failing orchestration tests with injected dependencies**

Define fakes for HTTP download, hashing, command execution, and filesystem operations. Assert: no update for equal version; ready state for newer manifest; checksum mismatch never extracts; traversal entry such as `../../evil` is rejected; build failure never starts helper; missing stored identity reports `.signingIdentityMissing`; mismatched designated requirement reports `.signatureMismatch`.

- [ ] **Step 2: Run tests to verify missing service failure**

Run: `./scripts/run-tests.sh`

Expected: missing `UpdateService` compile failure.

- [ ] **Step 3: Implement dependency-injected service**

Expose:

```swift
public actor UpdateService {
    public init(configuration: Configuration, transport: UpdateTransport, runner: CommandRunning)
    public func check(currentVersion: LocalFlowVersion) async -> UpdateState
    public func install(_ manifest: LocalFlowReleaseManifest) async -> UpdateState
}

public protocol UpdateTransport: Sendable {
    func data(from url: URL) async throws -> Data
    func download(from url: URL, to destination: URL) async throws
}

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String
}

public protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> CommandResult
}
```

Use the public GitHub latest-release endpoint for `codejunkie99/LocalFlow`, locate `localflow-release.json`, decode strictly, then download its source asset. Stream SHA-256 with CryptoKit. Before extraction, list archive members with `/usr/bin/tar -tzf`; reject absolute paths, `..` path components, symlinks, and entries outside one top-level source directory. Extract only after validation.

- [ ] **Step 4: Build and verify the staged app**

Run the downloaded checkout's repository-owned `scripts/package-app.sh` with a clean environment containing only `PATH`, `HOME`, `TMPDIR`, and `LOCALFLOW_SIGNING_IDENTITY`. Compare stored fingerprint to current keychain identity, then compare `codesign -d -r-` output for staged and installed apps. Checkpoint/backup history through `TranscriptHistoryStore`, copy the helper to a temporary directory, and launch it with absolute validated arguments.

- [ ] **Step 5: Run tests and commit**

Run: `./scripts/run-tests.sh && swift build --disable-sandbox`

Expected: all fake transport/runner tests pass and actor isolation compiles cleanly.

```bash
git add Sources/LocalFlowPlatform/UpdateService.swift Tests/LocalFlowPlatformTests/UpdateServiceTests.swift
git commit -m "feat: build verified LocalFlow updates"
```

### Task 6: Add update UI, progress, and launch receipt

**Files:**
- Modify: `Sources/LocalFlowApp/AppModel.swift`
- Modify: `Sources/LocalFlowApp/MenuContentView.swift`
- Modify: `Sources/LocalFlowApp/LocalFlowApp.swift`
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Connect AppModel state**

Add `@Published private(set) var updateState: UpdateState = .idle`, `checkForUpdates()`, and `installUpdate()`. Disable update while dictation is busy. Keep the available manifest privately after check. Map errors to concise copy without URLs, shell output, signing fingerprints, database paths, or transcripts.

- [ ] **Step 2: Add the UI**

Add an **Update LocalFlow** section below latency with current version and state. The button first checks; when `.ready(version:)`, its label becomes **Install vX.Y.Z**. Show a determinate download progress, indeterminate build/install progress, and actionable errors such as `Signing identity missing — run setup again`. Give controls 44-point hit targets and accessible labels/values.

- [ ] **Step 3: Write the launch receipt**

On app start, if environment variable `LOCALFLOW_UPDATE_RECEIPT` contains an absolute path inside the updater's temporary directory, atomically write JSON containing bundle version, executable SHA-256, and `launched_at`. Do not include settings, permissions, database paths, or transcript data.

- [ ] **Step 4: Update bundle versions from build inputs**

Modify packaging to accept `LOCALFLOW_VERSION` and `LOCALFLOW_BUILD_NUMBER`, validate them, and write them into the staged plist with `PlistBuddy` before signing. Defaults remain the checked-in plist values for ordinary local builds.

- [ ] **Step 5: Run tests, build, and commit**

Run: `./scripts/run-tests.sh && ./scripts/package-app.sh && plutil -lint dist/LocalFlow.app/Contents/Info.plist && git diff --check`

Expected: tests/build/package pass and setup UI exposes update state without changing permission requests.

```bash
git add Sources/LocalFlowApp Resources/Info.plist scripts/package-app.sh
git commit -m "feat: add one-click LocalFlow updates"
```

### Task 7: Add manual source-release publishing and complete docs

**Files:**
- Create: `scripts/publish-source-release.sh`
- Modify: `README.md`
- Modify: `SETUP.md`
- Modify: `docs/INSTALL.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `SECURITY.md`

- [ ] **Step 1: Implement a no-CI release script**

Accept exactly one semantic version argument. Require a clean tracked worktree, authenticated `gh`, and `HEAD == origin/main`. Create an archive with `git archive --format=tar.gz --prefix="LocalFlow-$version/"`, calculate SHA-256, write `localflow-release.json` with version/commit/source URL/digest, validate it with `plutil`-independent JSON parsing, create tag `v$version`, and publish both assets with `gh release create`. Refuse to overwrite an existing tag or release.

- [ ] **Step 2: Document the complete owner/friend flow**

`SETUP.md` must start with the exact three commands a new Mac runs. Add sections for Command Line Tools, local signing, permissions, testing, Update LocalFlow, signing-identity recovery, history location/backup, and uninstall. README links to SETUP first. Architecture documents helper trust boundaries. SECURITY documents source-release trust, local signing, private history, and responsible disclosure.

- [ ] **Step 3: Verify docs and script dry run**

Provide `LOCALFLOW_RELEASE_DRY_RUN=1`; run:

```bash
LOCALFLOW_RELEASE_DRY_RUN=1 ./scripts/publish-source-release.sh 0.2.0
rg -n "T[B]D|T[O]DO|Developer ID required" SETUP.md README.md docs SECURITY.md
git diff --check
```

Expected: dry run prints archive/manifest/tag/release commands without creating a tag, release, or asset; placeholder scan is empty except intentional historical text.

- [ ] **Step 4: Commit**

```bash
git add scripts/publish-source-release.sh SETUP.md README.md docs/INSTALL.md docs/ARCHITECTURE.md SECURITY.md
git commit -m "docs: publish stable LocalFlow setup and releases"
```

### Task 8: End-to-end update and permission acceptance

**Files:**
- Modify only files required by discovered defects; do not broaden scope.

- [ ] **Step 1: Fresh static verification**

Run:

```bash
./scripts/run-tests.sh
swift build --disable-sandbox
./scripts/package-app.sh
plutil -lint dist/LocalFlow.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/LocalFlow.app
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 2: First-install acceptance on a disposable macOS user**

Run setup from a clean checkout. Confirm canonical `~/Applications/LocalFlow.app`, stable designated requirement, one-time permission prompts, working TextEdit auto-paste, and persisted signing preferences. Do not inspect or edit TCC directly.

- [ ] **Step 3: Publish a controlled test release**

Use the manual release script with a version higher than the installed test version. Confirm manifest and archive assets, then use **Update LocalFlow** from the installed app.

- [ ] **Step 4: Verify update preservation and rollback**

Before update, create settings and at least 12 history records. After update, confirm same designated requirement, permissions still granted, settings unchanged, all history searchable, and one previous app retained. Repeat with a deliberately broken staged launch and confirm the prior app/database are restored.

- [ ] **Step 5: Second-Mac acceptance**

Follow only `SETUP.md` on the second MacBook Air. Confirm Command Line Tools resume instructions, stable local identity, first dictation, in-app update, and permission/history preservation.

- [ ] **Step 6: Final review, commit fixes, and push**

Run a fresh code review, rerun the full static commands after any correction, commit only intentional files, and push source/docs to `main`. Do not upload a DMG or binary until Developer ID distribution is separately approved.
