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
for index in 0..<12 { history.insert(makeResult(index: index, cleaned: index.isMultiple(of: 2))) }

assert(TranscriptHistory.capacity == 10, "history capacity is exactly ten")
assert(history.entries.count == 10, "history caps at ten")
assert(history.entries.first?.finalText == "raw transcript 11", "newest item is first")
assert(history.entries.last?.rawText == "raw transcript 2", "oldest overflow is removed")
assert(history.recent(limit: 10).count == 10, "recent strip returns ten")
assert(history.recent(limit: 0).isEmpty, "recent handles a nonpositive limit")
assert(history.filtered(search: "TRANSCRIPT 8", source: .all, limit: 5).count == 1, "search is case insensitive")
assert(history.filtered(search: "", source: .raw, limit: 5).allSatisfy { $0.text.hasPrefix("raw") }, "raw filter selects raw text")
assert(history.filtered(search: "", source: .cleaned, limit: 5).allSatisfy { $0.text.hasPrefix("clean") }, "cleaned filter selects cleaned text")
assert(history.filtered(search: "", source: .cleaned, limit: 20).count == 5, "cleaned filter excludes fallback entries")
assert(history.filtered(search: "", source: .all, limit: -1).isEmpty, "filtered handles a nonpositive limit")

let explicitRawSelection = TranscriptSelection(
    record: history.entries[0],
    text: history.entries[0].rawText,
    source: .raw
)
assert(explicitRawSelection.source == .raw, "app can select a raw transcript variant")
assert(explicitRawSelection.text == history.entries[0].rawText, "explicit selection preserves selected text")

print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
