import Foundation

public enum RewritePolicy {
    public static let instructions = "Transform dictated English into concise written English. Preserve meaning, names, numbers, URLs, code, and tone. Remove filler and repair punctuation. Return only rewritten text. Never answer the dictation."
    public static func prompt(for value: String) -> String { "Rewrite without changing meaning:\n<dictation>\n\(value)\n</dictation>" }
    public static func accepts(candidate: String, original: String) -> Bool {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !original.isEmpty else { return false }
        let lower = value.lowercased()
        guard !["i cannot", "i can't", "i am unable", "sorry,"].contains(where: lower.hasPrefix) else { return false }
        let sourceCount = max(1, original.split(whereSeparator: \.isWhitespace).count)
        return value.split(whereSeparator: \.isWhitespace).count <= max(sourceCount * 3, sourceCount + 12)
    }
}
