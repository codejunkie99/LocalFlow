import Foundation
import LocalFlowCore

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

func makeResult(index: Int, cleaned: Bool = true) -> DictationResult {
    let raw = "raw transcript \(index)"
    let clean = cleaned ? "clean transcript \(index)" : nil
    return DictationResult(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: Double(index)),
        rawText: raw,
        cleanedText: clean,
        finalText: clean ?? raw,
        latency: .zero,
        target: PasteTarget(processIdentifier: Int32(index + 10))
    )
}

var history = TranscriptHistory()
for index in 0..<25 { history.insert(makeResult(index: index, cleaned: index.isMultiple(of: 2))) }

assert(history.entries.count == 25, "history retains every session result")
assert(history.entries.first?.finalText == "clean transcript 24", "newest item is first")
assert(history.entries.last?.rawText == "raw transcript 0", "oldest item is retained")
assert(history.recent(limit: 10).count == 10, "recent projection remains bounded")
assert(history.recent(limit: 0).isEmpty, "recent handles a nonpositive limit")
assert(history.filtered(search: "TRANSCRIPT 8", source: .all, limit: 5).count == 1, "search is case insensitive")
assert(history.filtered(search: "", source: .raw, limit: 5).allSatisfy { $0.text.hasPrefix("raw") }, "raw filter selects raw text")
assert(history.filtered(search: "", source: .cleaned, limit: 5).allSatisfy { $0.text.hasPrefix("clean") }, "cleaned filter selects cleaned text")
assert(history.filtered(search: "", source: .all, limit: 5).count == 5, "filtered projection remains bounded")
assert(history.filtered(search: "", source: .all, limit: -1).isEmpty, "filtered handles a nonpositive limit")

let snapshot = TranscriptHistorySnapshot(
    filtered: history.filtered(search: "", source: .all, limit: 5),
    recent: history.recent(limit: 10).map { finalSelection(for: $0) },
    totalCount: history.entries.count
)
assert(snapshot.totalCount == 25, "snapshot carries the persistent row count")
assert(snapshot.filtered.count == 5, "snapshot filtered projection is bounded")
assert(snapshot.recent.count == 10, "snapshot recent projection is bounded")
assert(TranscriptHistorySnapshot.empty.totalCount == 0, "empty snapshot carries zero")

func finalSelection(for record: DictationResult) -> TranscriptSelection {
    TranscriptSelection(
        record: record,
        text: record.finalText,
        source: record.cleanedText == nil ? .raw : .cleaned
    )
}

let explicitRawSelection = TranscriptSelection(
    record: history.entries[0],
    text: history.entries[0].rawText,
    source: .raw
)
assert(explicitRawSelection.source == .raw, "app can select a raw transcript variant")
assert(explicitRawSelection.text == history.entries[0].rawText, "explicit selection preserves selected text")

print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
