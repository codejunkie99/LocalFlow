import Foundation

public struct TranscriptAccumulator: Sendable {
    private var finals: [String] = []
    private var volatile = ""
    public init() {}
    public mutating func accept(_ text: String, isFinal: Bool) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if isFinal { if finals.last != value { finals.append(value) }; volatile = "" }
        else { volatile = value }
    }
    public var finalText: String { finals.joined(separator: " ") }
    public var displayText: String { [finalText, volatile].filter { !$0.isEmpty }.joined(separator: " ") }
}
