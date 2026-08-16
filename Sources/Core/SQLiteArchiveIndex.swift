import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite is a rebuildable query index. NDJSON plus media remains the archive's
/// portable source of truth; this store is optimized for pagination and FTS.
public final class SQLiteArchiveIndex: @unchecked Sendable {
    private var database: OpaquePointer?

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path(), &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw ArchiveError.databaseFailure
        }
        database = handle
        do {
            try migrate()
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func upsert(messages: [Message]) throws -> Int {
        try inTransaction {
            var inserted = 0
            for message in messages where try insert(message) {
                inserted += 1
            }
            return inserted
        }
    }

    public func messageCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM messages")
    }

    public func importSessions() throws -> [ImportSession] {
        let statement = try prepare("""
            SELECT id, source, source_hash, started_at, finished_at, status,
                   messages_read, messages_inserted, messages_skipped, errors
            FROM imports ORDER BY started_at ASC
            """)
        defer { sqlite3_finalize(statement) }
        var sessions: [ImportSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = columnString(statement, 0),
                let sourceValue = columnString(statement, 1),
                let source = ImportSource(rawValue: sourceValue),
                let sourceHash = columnString(statement, 2),
                let statusValue = columnString(statement, 5),
                let status = ImportStatus(rawValue: statusValue)
            else { throw ArchiveError.databaseFailure }
            let finishedAt = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            sessions.append(ImportSession(
                id: id,
                source: source,
                sourceHash: sourceHash,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                finishedAt: finishedAt,
                status: status,
                messagesRead: Int(sqlite3_column_int64(statement, 6)),
                messagesInserted: Int(sqlite3_column_int64(statement, 7)),
                messagesSkipped: Int(sqlite3_column_int64(statement, 8)),
                errors: Int(sqlite3_column_int64(statement, 9))
            ))
        }
        guard sqlite3_errcode(requireDatabase()) == SQLITE_OK || sqlite3_errcode(requireDatabase()) == SQLITE_DONE else {
            throw ArchiveError.databaseFailure
        }
        return sessions
    }

    public func record(session: ImportSession) throws {
        let statement = try prepare("""
            INSERT INTO imports (
                id, source, source_hash, started_at, finished_at, status,
                messages_read, messages_inserted, messages_skipped, errors
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        try bind(session.id, at: 1, to: statement)
        try bind(session.source.rawValue, at: 2, to: statement)
        try bind(session.sourceHash, at: 3, to: statement)
        try bind(session.startedAt.timeIntervalSince1970, at: 4, to: statement)
        try bind(session.finishedAt?.timeIntervalSince1970, at: 5, to: statement)
        try bind(session.status.rawValue, at: 6, to: statement)
        try bind(session.messagesRead, at: 7, to: statement)
        try bind(session.messagesInserted, at: 8, to: statement)
        try bind(session.messagesSkipped, at: 9, to: statement)
        try bind(session.errors, at: 10, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
    }

    public func search(_ query: SearchQuery) throws -> [Message] {
        let ftsQuery = normalizedFTSQuery(query.query)
        var sql = """
            SELECT DISTINCT m.id, m.source_message_id, m.conversation_id, m.timestamp,
                m.source_timezone, m.sender_id, m.sender_name, m.type, m.content,
                m.reply_to, m.raw_json
            FROM messages AS m
            WHERE (m.id IN (SELECT message_id FROM message_search WHERE message_search MATCH ?)
                   OR m.content LIKE '%' || ? || '%')
            """
        var bindings: [SQLiteValue] = [.text(ftsQuery), .text(query.query)]
        if let conversationID = query.conversationID {
            sql += " AND m.conversation_id = ?"
            bindings.append(.text(conversationID))
        }
        if let senderID = query.senderID {
            sql += " AND m.sender_id = ?"
            bindings.append(.text(senderID))
        }
        if let from = query.from {
            sql += " AND m.timestamp >= ?"
            bindings.append(.double(from.timeIntervalSince1970))
        }
        if let to = query.to {
            sql += " AND m.timestamp <= ?"
            bindings.append(.double(to.timeIntervalSince1970))
        }
        if !query.types.isEmpty {
            sql += " AND m.type IN (\(Array(repeating: "?", count: query.types.count).joined(separator: ",")))"
            bindings.append(contentsOf: query.types.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) })
        }
        sql += " ORDER BY m.timestamp ASC LIMIT ?"
        bindings.append(.integer(query.limit))

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            try bind(value, at: Int32(offset + 1), to: statement)
        }
        var messages: [Message] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            messages.append(try message(from: statement))
        }
        let code = sqlite3_errcode(requireDatabase())
        guard code == SQLITE_OK || code == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return messages
    }

    private func migrate() throws {
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            )
            """)
        if try scalarInt("SELECT COUNT(*) FROM schema_migrations WHERE version = 1") == 0 {
            try inTransaction {
                try execute("""
                    CREATE TABLE messages (
                        id TEXT PRIMARY KEY NOT NULL,
                        source_message_id TEXT UNIQUE,
                        fallback_fingerprint TEXT NOT NULL,
                        conversation_id TEXT NOT NULL,
                        timestamp REAL NOT NULL,
                        source_timezone TEXT NOT NULL,
                        sender_id TEXT NOT NULL,
                        sender_name TEXT NOT NULL,
                        type TEXT NOT NULL,
                        content TEXT,
                        reply_to TEXT,
                        raw_json TEXT
                    )
                    """)
                try execute("CREATE UNIQUE INDEX messages_fallback_dedup ON messages(fallback_fingerprint) WHERE source_message_id IS NULL")
                try execute("CREATE INDEX messages_conversation_timestamp ON messages(conversation_id, timestamp)")
                try execute("CREATE INDEX messages_sender_timestamp ON messages(sender_id, timestamp)")
                try execute("CREATE INDEX messages_type_timestamp ON messages(type, timestamp)")
                try execute("CREATE VIRTUAL TABLE message_search USING fts5(message_id UNINDEXED, content)")
                try execute("""
                    CREATE TABLE media_assets (
                        id TEXT PRIMARY KEY NOT NULL, sha256 TEXT UNIQUE NOT NULL,
                        relative_path TEXT NOT NULL, mime_type TEXT, size INTEGER NOT NULL, category TEXT NOT NULL
                    )
                    """)
                try execute("CREATE TABLE message_media (message_id TEXT NOT NULL REFERENCES messages(id), media_id TEXT NOT NULL REFERENCES media_assets(id), PRIMARY KEY(message_id, media_id))")
                try execute("CREATE TABLE contacts (id TEXT PRIMARY KEY NOT NULL, display_name TEXT NOT NULL, historical_names_json TEXT NOT NULL, wechat_id TEXT)")
                try execute("CREATE TABLE conversations (id TEXT PRIMARY KEY NOT NULL, display_name TEXT NOT NULL, is_group INTEGER NOT NULL)")
                try execute("CREATE TABLE participants (id TEXT PRIMARY KEY NOT NULL, conversation_id TEXT NOT NULL REFERENCES conversations(id), contact_id TEXT NOT NULL REFERENCES contacts(id), role TEXT)")
                try execute("""
                    CREATE TABLE imports (
                        id TEXT PRIMARY KEY NOT NULL, source TEXT NOT NULL, source_hash TEXT NOT NULL,
                        started_at REAL NOT NULL, finished_at REAL, status TEXT NOT NULL,
                        messages_read INTEGER NOT NULL, messages_inserted INTEGER NOT NULL,
                        messages_skipped INTEGER NOT NULL, errors INTEGER NOT NULL
                    )
                    """)
                try execute("CREATE TABLE archive_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
                try execute("INSERT INTO schema_migrations(version, applied_at) VALUES (1, \(Date().timeIntervalSince1970))")
            }
        }
    }

    private func insert(_ message: Message) throws -> Bool {
        if let sourceMessageID = message.sourceMessageID, try exists("SELECT 1 FROM messages WHERE source_message_id = ?", value: sourceMessageID) {
            return false
        }
        if message.sourceMessageID == nil, try exists("SELECT 1 FROM messages WHERE fallback_fingerprint = ? AND source_message_id IS NULL", value: message.fallbackFingerprint) {
            return false
        }
        let statement = try prepare("""
            INSERT INTO messages (
                id, source_message_id, fallback_fingerprint, conversation_id, timestamp,
                source_timezone, sender_id, sender_name, type, content, reply_to, raw_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        try bind(message.id, at: 1, to: statement)
        try bind(message.sourceMessageID, at: 2, to: statement)
        try bind(message.fallbackFingerprint, at: 3, to: statement)
        try bind(message.conversationID, at: 4, to: statement)
        try bind(message.timestamp.timeIntervalSince1970, at: 5, to: statement)
        try bind(message.sourceTimeZone, at: 6, to: statement)
        try bind(message.sender.id, at: 7, to: statement)
        try bind(message.sender.displayName, at: 8, to: statement)
        try bind(message.type.rawValue, at: 9, to: statement)
        try bind(message.content, at: 10, to: statement)
        try bind(message.replyTo, at: 11, to: statement)
        try bind(message.raw.map { try JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }, at: 12, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        try insertSearchEntry(message)
        try insertMedia(message)
        return true
    }

    private func insertSearchEntry(_ message: Message) throws {
        let statement = try prepare("INSERT INTO message_search(message_id, content) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(message.id, at: 1, to: statement)
        try bind(message.content ?? "", at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
    }

    private func insertMedia(_ message: Message) throws {
        for media in message.media {
            let mediaStatement = try prepare("INSERT OR IGNORE INTO media_assets(id, sha256, relative_path, mime_type, size, category) VALUES (?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(mediaStatement) }
            try bind(media.id, at: 1, to: mediaStatement)
            try bind(media.sha256, at: 2, to: mediaStatement)
            try bind(media.relativePath, at: 3, to: mediaStatement)
            try bind(media.mimeType, at: 4, to: mediaStatement)
            try bind(media.size, at: 5, to: mediaStatement)
            try bind(media.category.rawValue, at: 6, to: mediaStatement)
            guard sqlite3_step(mediaStatement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }

            let linkStatement = try prepare("INSERT OR IGNORE INTO message_media(message_id, media_id) VALUES (?, ?)")
            defer { sqlite3_finalize(linkStatement) }
            try bind(message.id, at: 1, to: linkStatement)
            try bind(media.id, at: 2, to: linkStatement)
            guard sqlite3_step(linkStatement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        }
    }

    private func message(from statement: OpaquePointer?) throws -> Message {
        guard
            let id = columnString(statement, 0),
            let conversationID = columnString(statement, 2),
            let timeZone = columnString(statement, 4),
            let senderID = columnString(statement, 5),
            let senderName = columnString(statement, 6),
            let typeValue = columnString(statement, 7),
            let type = MessageType(rawValue: typeValue)
        else { throw ArchiveError.databaseFailure }
        let raw: [String: String]?
        if let rawJSON = columnString(statement, 10), let rawData = rawJSON.data(using: .utf8) {
            raw = try? JSONDecoder().decode([String: String].self, from: rawData)
        } else {
            raw = nil
        }
        return Message(
            id: id,
            sourceMessageID: columnString(statement, 1),
            conversationID: conversationID,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            sourceTimeZone: timeZone,
            sender: MessageSender(id: senderID, displayName: senderName),
            type: type,
            content: columnString(statement, 8),
            replyTo: columnString(statement, 9),
            media: try media(for: id),
            raw: raw
        )
    }

    private func media(for messageID: String) throws -> [MediaAsset] {
        let statement = try prepare("""
            SELECT a.id, a.relative_path, a.sha256, a.mime_type, a.size, a.category
            FROM media_assets a JOIN message_media m ON a.id = m.media_id WHERE m.message_id = ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(messageID, at: 1, to: statement)
        var results: [MediaAsset] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = columnString(statement, 0),
                let path = columnString(statement, 1),
                let hash = columnString(statement, 2),
                let categoryValue = columnString(statement, 5),
                let category = MediaCategory(rawValue: categoryValue)
            else { throw ArchiveError.databaseFailure }
            results.append(MediaAsset(id: id, relativePath: path, sha256: hash, mimeType: columnString(statement, 3), size: sqlite3_column_int64(statement, 4), category: category))
        }
        return results
    }

    private func normalizedFTSQuery(_ raw: String) -> String {
        let terms = raw
            .replacingOccurrences(of: "\"", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0)\"" }
        return terms.isEmpty ? "\"\"" : terms.joined(separator: " AND ")
    }

    private func exists(_ sql: String, value: String) throws -> Bool {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(value, at: 1, to: statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW || code == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return code == SQLITE_ROW
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func inTransaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(requireDatabase(), sql, nil, nil, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireDatabase(), sql, -1, &statement, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        return statement
    }

    private func bind(_ value: SQLiteValue, at position: Int32, to statement: OpaquePointer?) throws {
        let result: Int32
        switch value {
        case let .text(value): result = sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
        case let .integer(value): result = sqlite3_bind_int64(statement, position, sqlite3_int64(value))
        case let .double(value): result = sqlite3_bind_double(statement, position, value)
        case .null: result = sqlite3_bind_null(statement, position)
        }
        guard result == SQLITE_OK else { throw ArchiveError.databaseFailure }
    }

    private func bind(_ value: String?, at position: Int32, to statement: OpaquePointer?) throws {
        try bind(value.map(SQLiteValue.text) ?? .null, at: position, to: statement)
    }

    private func bind(_ value: String, at position: Int32, to statement: OpaquePointer?) throws {
        try bind(.text(value), at: position, to: statement)
    }

    private func bind(_ value: Double?, at position: Int32, to statement: OpaquePointer?) throws {
        try bind(value.map(SQLiteValue.double) ?? .null, at: position, to: statement)
    }

    private func bind(_ value: Double, at position: Int32, to statement: OpaquePointer?) throws {
        try bind(.double(value), at: position, to: statement)
    }

    private func bind(_ value: Int, at position: Int32, to statement: OpaquePointer?) throws {
        try bind(.integer(value), at: position, to: statement)
    }

    private func bind(_ value: Int64, at position: Int32, to statement: OpaquePointer?) throws {
        try bind(.integer(Int(value)), at: position, to: statement)
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func requireDatabase() -> OpaquePointer? {
        database
    }
}

private enum SQLiteValue {
    case text(String), integer(Int), double(Double), null
}
