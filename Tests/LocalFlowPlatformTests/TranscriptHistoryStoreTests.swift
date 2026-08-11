import Foundation
import LocalFlowCore
import LocalFlowPlatform

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

func makeResult(index: Int, cleaned: Bool = true) -> DictationResult {
    let raw = "raw transcript \(index)"
    let clean = cleaned ? "cleaned \(index)" : nil
    return DictationResult(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: Double(index)),
        rawText: raw,
        cleanedText: clean,
        finalText: clean ?? raw,
        latency: LatencySample(
            timestamp: Date(timeIntervalSince1970: Double(index)),
            speechFinalizationMilliseconds: Double(index) + 1,
            rewriteMilliseconds: Double(index) + 2,
            pasteMilliseconds: Double(index) + 3,
            totalMilliseconds: Double(index) + 6,
            usedRawFallback: cleaned == false
        ),
        target: PasteTarget(
            processIdentifier: Int32(index + 10),
            cursorAnchor: CursorAnchor(location: index, length: 1)
        ),
        didPaste: index.isMultiple(of: 3)
    )
}

func testStorePersistsAcrossReopen() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = root.appendingPathComponent("history.sqlite3")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try TranscriptHistoryStore(databaseURL: databaseURL)
    try await first.insert(makeResult(index: 1, cleaned: true))
    for suffix in ["", "-wal", "-shm"] {
        let path = databaseURL.path + suffix
        guard FileManager.default.fileExists(atPath: path) else { continue }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        assert(mode == 0o600, "SQLite \(suffix.isEmpty ? "database" : suffix) file is mode 0600")
    }
    try await first.close()

    let reopened = try TranscriptHistoryStore(databaseURL: databaseURL)
    let recent = try await reopened.recent(limit: 10)
    assert(recent.count == 1, "reopen retains transcript")
    assert(recent.first?.finalText == "cleaned 1", "reopen retains final text")
    assert(recent.first?.latency.totalMilliseconds == 7, "reopen retains latency receipt")
    assert(recent.first?.target?.processIdentifier == 11, "reopen retains paste target")
    assert(recent.first?.didPaste == false, "reopen retains paste outcome")
    try await reopened.close()

    let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    assert(mode == 0o600, "database file is user-private mode 0600 (got \(String(format: "%o", mode)))")
}

func testLiveDatabaseURLUsesApplicationSupport() throws {
    let fileManager = FileManager.default
    let url = try TranscriptHistoryStore.liveDatabaseURL(fileManager: fileManager)
    assert(url.path.hasSuffix("Library/Application Support/LocalFlow/history.sqlite3"), "live database lives in Application Support")
    assert(url.path.hasPrefix(fileManager.homeDirectoryForCurrentUser.path), "live database lives under the current user home")
}

func testIndexedSearchSourceFilterDedupeAndLimits() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = root.appendingPathComponent("history.sqlite3")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try TranscriptHistoryStore(databaseURL: databaseURL)
    for index in 0..<29 {
        let rawText: String
        let cleanedText: String?
        switch index % 3 {
        case 0:
            rawText = "alpha raw \(index)"
            cleanedText = "polished \(index)"
        case 1:
            rawText = "plain raw \(index)"
            cleanedText = nil
        default:
            rawText = "beta raw \(index)"
            cleanedText = "polished beta \(index)"
        }
        try await store.insert(DictationResult(
            createdAt: Date(timeIntervalSince1970: Double(index)),
            rawText: rawText,
            cleanedText: cleanedText,
            finalText: cleanedText ?? rawText,
            latency: .zero,
            target: nil,
            didPaste: false
        ))
    }

    let duplicateID = UUID()
    try await store.insert(DictationResult(
        id: duplicateID,
        rawText: "alpha duplicate first",
        cleanedText: "polished duplicate first",
        finalText: "polished duplicate first",
        latency: .zero,
        target: nil,
        didPaste: false
    ))
    try await store.insert(DictationResult(
        id: duplicateID,
        rawText: "alpha duplicate second",
        cleanedText: "polished duplicate second",
        finalText: "polished duplicate second",
        latency: .zero,
        target: nil,
        didPaste: false
    ))

    let all = try await store.snapshot(search: "", source: .all)
    assert(all.totalCount == 30, "deduped store keeps 30 records (got \(all.totalCount))")
    assert(all.filtered.count == 5, "filtered snapshot is capped at five")
    assert(all.recent.count == 10, "recent snapshot is capped at ten")

    let raw = try await store.snapshot(search: "alpha", source: .raw)
    assert(!raw.filtered.isEmpty, "raw search finds alpha records")
    assert(raw.filtered.allSatisfy { $0.source == .raw }, "raw filter returns raw selections")
    assert(raw.filtered.allSatisfy { $0.text.localizedCaseInsensitiveContains("alpha") }, "search matches raw text")
    assert(raw.totalCount >= 10, "unbounded total count is returned for raw search")

    let cleaned = try await store.snapshot(search: "polished", source: .cleaned)
    assert(!cleaned.filtered.isEmpty, "cleaned search finds polished records")
    assert(cleaned.filtered.allSatisfy { $0.source == .cleaned }, "cleaned filter returns cleaned selections")
    assert(cleaned.filtered.allSatisfy { $0.text.localizedCaseInsensitiveContains("polished") }, "search matches cleaned text")
    assert(cleaned.filtered.allSatisfy { $0.record.cleanedText != nil }, "cleaned filter excludes nil cleaned text")

    let byID = try await store.snapshot(search: "duplicate", source: .all)
    assert(byID.totalCount == 30, "snapshot total remains the global persistent row count")
    assert(byID.filtered.first?.record.id == duplicateID, "upsert keeps the latest text")
    assert(byID.filtered.first?.record.rawText.contains("second") == true, "upsert replaces prior text")

    let filterStoreURL = root.appendingPathComponent("filter-limit.sqlite3")
    let filterStore = try TranscriptHistoryStore(databaseURL: filterStoreURL)
    for index in 0..<10 {
        try await filterStore.insert(makeResult(index: 100 + index, cleaned: false))
    }
    for index in 0..<5 {
        try await filterStore.insert(makeResult(index: index, cleaned: true))
    }
    let cleanedBeyondUnfilteredLimit = try await filterStore.snapshot(search: "", source: .cleaned)
    assert(
        cleanedBeyondUnfilteredLimit.filtered.count == 5,
        "source filtering happens before the five-row SQL limit"
    )
    assert(
        cleanedBeyondUnfilteredLimit.recent.count == 10,
        "the sideways recent list remains the newest ten across all sources"
    )
    try await filterStore.close()

    try await store.close()
}

func testCheckpointBackupAndClear() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = root.appendingPathComponent("history.sqlite3")
    let backupURL = root.appendingPathComponent("history-backup.sqlite3")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try TranscriptHistoryStore(databaseURL: databaseURL)
    for index in 0..<12 {
        try await store.insert(makeResult(index: index, cleaned: index.isMultiple(of: 2)))
    }
    try await store.checkpointAndBackup(to: backupURL)
    try await store.clear()
    assert(try await store.count() == 0, "clear empties the live store")

    let backupStore = try TranscriptHistoryStore(databaseURL: backupURL)
    let backupRecent = try await backupStore.recent(limit: 20)
    assert(backupRecent.count == 12, "backup retains every row (got \(backupRecent.count))")
    assert(backupRecent.contains(where: { $0.rawText == "raw transcript 11" }), "backup retains newest row")
    assert(backupRecent.contains(where: { $0.rawText == "raw transcript 0" }), "backup retains oldest row")
    try await backupStore.close()

    let attributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    assert(mode == 0o600, "backup file is user-private mode 0600 (got \(String(format: "%o", mode)))")

    try await store.close()
}

func testUnwritableBackupLeavesLiveStoreUntouched() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = root.appendingPathComponent("history.sqlite3")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try TranscriptHistoryStore(databaseURL: databaseURL)
    try await store.insert(makeResult(index: 1, cleaned: true))

    let blockedParent = root.appendingPathComponent("readonly")
    try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500],
        ofItemAtPath: blockedParent.path
    )
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: blockedParent.path
        )
    }

    do {
        try await store.checkpointAndBackup(
            to: blockedParent.appendingPathComponent("backup.sqlite3")
        )
        assert(false, "unwritable backup parent must fail")
    } catch {
        assert(true, "unwritable backup parent reports failure")
    }

    assert(try await store.count() == 1, "failed backup leaves live store unchanged")
    let recent = try await store.recent(limit: 10)
    assert(recent.first?.finalText == "cleaned 1", "failed backup keeps live rows readable")
    try await store.close()
}

try await testStorePersistsAcrossReopen()
try testLiveDatabaseURLUsesApplicationSupport()
try await testIndexedSearchSourceFilterDedupeAndLimits()
try await testCheckpointBackupAndClear()
try await testUnwritableBackupLeavesLiveStoreUntouched()

print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
