import Foundation

public struct PasteTarget: Codable, Sendable, Equatable {
    public let processIdentifier: Int32
    public let cursorAnchor: CursorAnchor?

    public init(processIdentifier: Int32, cursorAnchor: CursorAnchor? = nil) {
        self.processIdentifier = processIdentifier
        self.cursorAnchor = cursorAnchor
    }
}

public struct CursorAnchor: Codable, Sendable, Equatable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct DictationResult: Codable, Sendable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let rawText: String
    public let cleanedText: String?
    public let finalText: String
    public let latency: LatencySample
    public let target: PasteTarget?
    public let didPaste: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        rawText: String,
        cleanedText: String?,
        finalText: String,
        latency: LatencySample,
        target: PasteTarget?,
        didPaste: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.finalText = finalText
        self.latency = latency
        self.target = target
        self.didPaste = didPaste
    }
}

public enum TranscriptSourceFilter: String, CaseIterable, Sendable, Equatable {
    case all = "All"
    case raw = "Raw"
    case cleaned = "Cleaned"
}

public struct TranscriptSelection: Identifiable, Sendable, Equatable {
    public let record: DictationResult
    public let text: String
    public let source: TranscriptSourceFilter

    public init(record: DictationResult, text: String, source: TranscriptSourceFilter) {
        self.record = record
        self.text = text
        self.source = source
    }

    public var id: UUID { record.id }
}

public struct TranscriptHistory: Sendable, Equatable {
    public private(set) var entries: [DictationResult] = []

    public init() {}

    public mutating func insert(_ result: DictationResult) {
        entries.removeAll { $0.id == result.id }
        entries.insert(result, at: 0)
    }

    public func recent(limit: Int = 10) -> [DictationResult] {
        Array(entries.prefix(max(0, limit)))
    }

    public func filtered(
        search: String,
        source: TranscriptSourceFilter,
        limit: Int = 5
    ) -> [TranscriptSelection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.compactMap { record -> TranscriptSelection? in
            let selected: (String, TranscriptSourceFilter)? = switch source {
            case .all:
                (record.finalText, record.cleanedText == nil ? .raw : .cleaned)
            case .raw:
                (record.rawText, .raw)
            case .cleaned:
                record.cleanedText.map { ($0, .cleaned) }
            }

            guard let selected, query.isEmpty || selected.0.localizedCaseInsensitiveContains(query) else {
                return nil
            }
            return TranscriptSelection(record: record, text: selected.0, source: selected.1)
        }
        return Array(matches.prefix(max(0, limit)))
    }
}

public struct TranscriptHistorySnapshot: Sendable, Equatable {
    public let filtered: [TranscriptSelection]
    public let recent: [TranscriptSelection]
    public let totalCount: Int

    public init(filtered: [TranscriptSelection], recent: [TranscriptSelection], totalCount: Int) {
        self.filtered = filtered
        self.recent = recent
        self.totalCount = totalCount
    }

    public static let empty = TranscriptHistorySnapshot(filtered: [], recent: [], totalCount: 0)
}
