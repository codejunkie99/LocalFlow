import Foundation
import LocalFlowCore
import SQLite3

public actor TranscriptHistoryStore {
    public enum StoreError: Error, Sendable, Equatable {
        case sqlite(status: Int32, message: String)
        case migrationFailed
        case backupFailed
        case invalidResult
    }

    private nonisolated(unsafe) let database: OpaquePointer
    private nonisolated(unsafe) var isClosed = false
    private let databaseURL: URL

    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Self.applyDirectoryMode(to: directory)

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let handle else {
            throw StoreError.sqlite(status: status, message: Self.lastMessage(handle))
        }
        database = handle

        do {
            try Self.prepareDatabase(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        try Self.applyPrivateModes(to: databaseURL)
    }

    public static func liveDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("LocalFlow", isDirectory: true)
        return directory.appendingPathComponent("history.sqlite3")
    }

    public func insert(_ result: DictationResult) throws {
        defer { try? Self.applyPrivateModes(to: databaseURL) }
        let statement = try prepare("""
            INSERT INTO transcripts (
                id, created_at, raw_text, cleaned_text, final_text, source,
                latency_timestamp, speech_ms, rewrite_ms, paste_ms, total_ms,
                used_raw_fallback, target_pid, did_paste
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                created_at = excluded.created_at,
                raw_text = excluded.raw_text,
                cleaned_text = excluded.cleaned_text,
                final_text = excluded.final_text,
                source = excluded.source,
                latency_timestamp = excluded.latency_timestamp,
                speech_ms = excluded.speech_ms,
                rewrite_ms = excluded.rewrite_ms,
                paste_ms = excluded.paste_ms,
                total_ms = excluded.total_ms,
                used_raw_fallback = excluded.used_raw_fallback,
                target_pid = excluded.target_pid,
                did_paste = excluded.did_paste
            """)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, result.id.uuidString, -1, Self.transientDestructor)
        sqlite3_bind_double(statement, 2, result.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, result.rawText, -1, Self.transientDestructor)
        sqlite3_bind_text(statement, 4, result.cleanedText, -1, Self.transientDestructor)
        sqlite3_bind_text(statement, 5, result.finalText, -1, Self.transientDestructor)
        sqlite3_bind_text(
            statement,
            6,
            result.cleanedText == nil ? "raw" : "cleaned",
            -1,
            Self.transientDestructor
        )
        sqlite3_bind_double(statement, 7, result.latency.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, result.latency.speechFinalizationMilliseconds)
        sqlite3_bind_double(statement, 9, result.latency.rewriteMilliseconds)
        sqlite3_bind_double(statement, 10, result.latency.pasteMilliseconds)
        sqlite3_bind_double(statement, 11, result.latency.totalMilliseconds)
        sqlite3_bind_int(statement, 12, result.latency.usedRawFallback ? 1 : 0)
        if let processIdentifier = result.target?.processIdentifier {
            sqlite3_bind_int64(statement, 13, Int64(processIdentifier))
        } else {
            sqlite3_bind_null(statement, 13)
        }
        sqlite3_bind_int(statement, 14, result.didPaste ? 1 : 0)
        try step(statement)
    }

    public func snapshot(
        search: String,
        source: TranscriptSourceFilter
    ) throws -> TranscriptHistorySnapshot {
        let normalized = Self.normalizedSearch(search)
        let searchExpression: String
        switch source {
        case .all:
            searchExpression = normalized
        case .raw:
            searchExpression = normalized.isEmpty ? "" : "raw_text : (\(normalized))"
        case .cleaned:
            searchExpression = normalized.isEmpty ? "" : "cleaned_text : (\(normalized))"
        }
        let totalCount = try count()
        let sourcePredicate = source == .cleaned ? "WHERE cleaned_text IS NOT NULL" : ""

        let filtered: [TranscriptSelection]
        if normalized.isEmpty {
            filtered = try querySelections(
                sql: """
                    SELECT id, created_at, raw_text, cleaned_text, final_text, source,
                           latency_timestamp, speech_ms, rewrite_ms, paste_ms, total_ms,
                           used_raw_fallback, target_pid, did_paste
                    FROM transcripts
                    \(sourcePredicate)
                    ORDER BY created_at DESC
                    LIMIT ?
                    """,
                bindings: { statement in
                    sqlite3_bind_int(statement, 1, 5)
                },
                source: source
            )
        } else {
            filtered = try querySelections(
                sql: """
                    SELECT t.id, t.created_at, t.raw_text, t.cleaned_text, t.final_text, t.source,
                           t.latency_timestamp, t.speech_ms, t.rewrite_ms, t.paste_ms, t.total_ms,
                           t.used_raw_fallback, t.target_pid, t.did_paste
                    FROM transcripts_fts f
                    JOIN transcripts t ON t.rowid = f.rowid
                    WHERE transcripts_fts MATCH ?
                    \(source == .cleaned ? "AND t.cleaned_text IS NOT NULL" : "")
                    ORDER BY t.created_at DESC
                    LIMIT ?
                    """,
                bindings: { statement in
                    sqlite3_bind_text(statement, 1, searchExpression, -1, Self.transientDestructor)
                    sqlite3_bind_int(statement, 2, 5)
                },
                source: source
            )
        }

        let recent = try querySelections(
            sql: """
                SELECT id, created_at, raw_text, cleaned_text, final_text, source,
                       latency_timestamp, speech_ms, rewrite_ms, paste_ms, total_ms,
                       used_raw_fallback, target_pid, did_paste
                FROM transcripts
                ORDER BY created_at DESC
                LIMIT ?
                """,
            bindings: { statement in
                sqlite3_bind_int(statement, 1, 10)
            },
            source: .all,
            useFinalSelection: true
        )

        return TranscriptHistorySnapshot(
            filtered: filtered,
            recent: recent,
            totalCount: totalCount
        )
    }

    public func recent(limit: Int) throws -> [DictationResult] {
        try querySelections(
            sql: """
                SELECT id, created_at, raw_text, cleaned_text, final_text, source,
                       latency_timestamp, speech_ms, rewrite_ms, paste_ms, total_ms,
                       used_raw_fallback, target_pid, did_paste
                FROM transcripts
                ORDER BY created_at DESC
                LIMIT ?
                """,
            bindings: { statement in
                sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
            },
            source: .all,
            useFinalSelection: true
        ).map(\.record)
    }

    public func count() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM transcripts")
        defer { sqlite3_finalize(statement) }
        try step(statement)
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func clear() throws {
        defer { try? Self.applyPrivateModes(to: databaseURL) }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM transcripts")
            try execute("INSERT INTO transcripts_fts(transcripts_fts) VALUES('rebuild')")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func checkpointAndBackup(to backupURL: URL) throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")

        let temporary = backupURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(backupURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let parent = temporary.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var destination: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            temporary.path,
            &destination,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let destination else {
            throw StoreError.backupFailed
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else {
            throw StoreError.backupFailed
        }
        let status = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE else {
            throw StoreError.backupFailed
        }
        try Self.applyPrivateMode(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()

        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        try FileManager.default.moveItem(at: temporary, to: backupURL)
        try Self.applyPrivateMode(to: backupURL)
    }

    public func close() throws {
        guard !isClosed else { return }
        let status = sqlite3_close(database)
        guard status == SQLITE_OK else {
            throw StoreError.sqlite(status: status, message: Self.lastMessage(database))
        }
        isClosed = true
    }

    deinit {
        if !isClosed {
            sqlite3_close(database)
        }
    }

    private static func prepareDatabase(_ database: OpaquePointer) throws {
        try execute(database, "PRAGMA journal_mode=WAL")
        try execute(database, "PRAGMA foreign_keys=ON")

        let statement = try prepare(database, "PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        try step(statement)
        let version = Int(sqlite3_column_int64(statement, 0))
        guard version < 1 else { return }

        try execute(database, "BEGIN IMMEDIATE")
        do {
            try execute(database, """
                CREATE TABLE IF NOT EXISTS transcripts (
                  id TEXT PRIMARY KEY NOT NULL,
                  created_at REAL NOT NULL,
                  raw_text TEXT NOT NULL,
                  cleaned_text TEXT,
                  final_text TEXT NOT NULL,
                  source TEXT NOT NULL CHECK(source IN ('raw','cleaned')),
                  latency_timestamp REAL NOT NULL,
                  speech_ms REAL NOT NULL,
                  rewrite_ms REAL NOT NULL,
                  paste_ms REAL NOT NULL,
                  total_ms REAL NOT NULL,
                  used_raw_fallback INTEGER NOT NULL CHECK(used_raw_fallback IN (0,1)),
                  target_pid INTEGER,
                  did_paste INTEGER NOT NULL CHECK(did_paste IN (0,1))
                )
                """)
            try execute(database, """
                CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
                  raw_text, cleaned_text, final_text,
                  content='transcripts', content_rowid='rowid'
                )
                """)
            try execute(database, """
                CREATE TRIGGER IF NOT EXISTS transcripts_ai AFTER INSERT ON transcripts BEGIN
                  INSERT INTO transcripts_fts(rowid, raw_text, cleaned_text, final_text)
                  VALUES (new.rowid, new.raw_text, new.cleaned_text, new.final_text);
                END
                """)
            try execute(database, """
                CREATE TRIGGER IF NOT EXISTS transcripts_ad AFTER DELETE ON transcripts BEGIN
                  INSERT INTO transcripts_fts(transcripts_fts, rowid, raw_text, cleaned_text, final_text)
                  VALUES ('delete', old.rowid, old.raw_text, old.cleaned_text, old.final_text);
                END
                """)
            try execute(database, """
                CREATE TRIGGER IF NOT EXISTS transcripts_au AFTER UPDATE ON transcripts BEGIN
                  INSERT INTO transcripts_fts(transcripts_fts, rowid, raw_text, cleaned_text, final_text)
                  VALUES ('delete', old.rowid, old.raw_text, old.cleaned_text, old.final_text);
                  INSERT INTO transcripts_fts(rowid, raw_text, cleaned_text, final_text)
                  VALUES (new.rowid, new.raw_text, new.cleaned_text, new.final_text);
                END
                """)
            try execute(database, "PRAGMA user_version = 1")
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw StoreError.migrationFailed
        }
    }

    private static func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw StoreError.sqlite(status: status, message: Self.lastMessage(database))
        }
        return statement
    }

    private static func step(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw StoreError.sqlite(
                status: status,
                message: Self.lastMessage(sqlite3_db_handle(statement))
            )
        }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        try step(statement)
    }

    private func querySelections(
        sql: String,
        bindings: (OpaquePointer) -> Void,
        source: TranscriptSourceFilter,
        useFinalSelection: Bool = false
    ) throws -> [TranscriptSelection] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindings(statement)

        var selections: [TranscriptSelection] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw StoreError.sqlite(status: status, message: Self.lastMessage(database))
            }
            let result = try decodeResult(statement)
            let selection: TranscriptSelection
            if useFinalSelection {
                selection = TranscriptSelection(
                    record: result,
                    text: result.finalText,
                    source: result.cleanedText == nil ? .raw : .cleaned
                )
            } else {
                let selectedSource: TranscriptSourceFilter
                let selectedText: String
                switch source {
                case .all:
                    selectedSource = result.cleanedText == nil ? .raw : .cleaned
                    selectedText = result.finalText
                case .raw:
                    selectedSource = .raw
                    selectedText = result.rawText
                case .cleaned:
                    guard let cleanedText = result.cleanedText else { continue }
                    selectedSource = .cleaned
                    selectedText = cleanedText
                }
                selection = TranscriptSelection(
                    record: result,
                    text: selectedText,
                    source: selectedSource
                )
            }
            selections.append(selection)
        }
        return selections
    }

    private func decodeResult(_ statement: OpaquePointer) throws -> DictationResult {
        guard let idString = Self.text(statement, 0).flatMap(UUID.init(uuidString:)),
              let createdAt = Self.date(statement, 1),
              let rawText = Self.text(statement, 2),
              let finalText = Self.text(statement, 4)
        else {
            throw StoreError.invalidResult
        }
        let cleanedText = Self.text(statement, 3)
        let latencyTimestamp = Self.date(statement, 6) ?? createdAt
        let targetPID = Self.int(statement, 12).flatMap { Int32(clamping: $0) }
        return DictationResult(
            id: idString,
            createdAt: createdAt,
            rawText: rawText,
            cleanedText: cleanedText,
            finalText: finalText,
            latency: LatencySample(
                timestamp: latencyTimestamp,
                speechFinalizationMilliseconds: Self.number(statement, 7),
                rewriteMilliseconds: Self.number(statement, 8),
                pasteMilliseconds: Self.number(statement, 9),
                totalMilliseconds: Self.number(statement, 10),
                usedRawFallback: Self.integerFlag(statement, 11)
            ),
            target: targetPID.map {
                PasteTarget(processIdentifier: $0)
            },
            didPaste: Self.integerFlag(statement, 13)
        )
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw StoreError.sqlite(status: status, message: Self.lastMessage(database))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw StoreError.sqlite(status: status, message: Self.lastMessage(database))
        }
    }

    private func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try step(statement)
    }

    private static func applyPrivateMode(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func applyPrivateModes(to databaseURL: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try Self.applyPrivateMode(to: url)
        }
    }

    private static func applyDirectoryMode(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func lastMessage(_ database: OpaquePointer?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    private static func date(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func number(_ statement: OpaquePointer, _ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    private static func int(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    private static func integerFlag(_ statement: OpaquePointer, _ column: Int32) -> Bool {
        sqlite3_column_int(statement, column) != 0
    }

    private static func normalizedSearch(_ search: String) -> String {
        let tokens = search
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        return tokens.joined(separator: " AND ")
    }
}
