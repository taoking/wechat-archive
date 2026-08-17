import Foundation
import SQLite3

private let archiveV1SQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Private Archive v1 database. It is intentionally separate from the older
/// rebuildable search index: this schema is the lossless import source of truth.
public final class WeChatArchiveV1Database: @unchecked Sendable {
    public static let schemaVersion = 2
    private var handle: OpaquePointer?
    public let url: URL

    public init(url: URL) throws {
        self.url = url.standardizedFileURL
        try Self.prepareParent(for: self.url)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(self.url.path(), &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveError.databaseFailure
        }
        handle = database
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try migrate()
            try protectArchiveFile()
        } catch {
            sqlite3_close(database)
            handle = nil
            throw error
        }
    }

    deinit { close() }

    public func close() {
        guard let handle else { return }
        _ = sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        sqlite3_close(handle)
        self.handle = nil
        try? protectArchiveFile()
    }

    public func schemaVersion() throws -> Int {
        Int(try scalarInt("PRAGMA user_version"))
    }

    public func requiredTables() throws -> Set<String> {
        let expected: Set<String> = ["import_runs", "conversations", "messages", "message_source_values", "media_assets", "message_media_links"]
        let names = try tableNames()
        guard expected.isSubset(of: names) else { throw ArchiveError.invalidArchive }
        return expected
    }

    public func createImportRun() throws -> String {
        let id = UUID().uuidString.lowercased()
        let statement = try prepare("INSERT INTO import_runs (id, started_at, app_version, archive_schema_version, source_database_count, message_count, media_count, status) VALUES (?, ?, ?, ?, 0, 0, 0, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        try bind(Date().timeIntervalSince1970, at: 2, to: statement)
        try bind("1", at: 3, to: statement)
        try bind(Int64(Self.schemaVersion), at: 4, to: statement)
        try bind(ArchiveV1ImportStatus.running.rawValue, at: 5, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return id
    }

    public func finishImportRun(_ id: String, status: ArchiveV1ImportStatus, sourceDatabaseCount: Int, summary: ArchiveV1ImportSummary) throws {
        let statement = try prepare("UPDATE import_runs SET completed_at = ?, source_database_count = ?, message_count = ?, media_count = ?, status = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(Date().timeIntervalSince1970, at: 1, to: statement)
        try bind(Int64(sourceDatabaseCount), at: 2, to: statement)
        try bind(Int64(summary.messagesImported), at: 3, to: statement)
        try bind(Int64(try mediaAssetCount()), at: 4, to: statement)
        try bind(status.rawValue, at: 5, to: statement)
        try bind(id, at: 6, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(requireHandle()) == 1 else { throw ArchiveError.databaseFailure }
    }

    public func upsertConversation(sourceIdentity: String, createdAt: Int64? = nil) throws -> String {
        if let existing = try conversationID(sourceIdentity: sourceIdentity) { return existing }
        let id = UUID().uuidString.lowercased()
        let statement = try prepare("INSERT INTO conversations (id, source_identity, conversation_type, display_name, created_at) VALUES (?, ?, 'unknown', NULL, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        try bind(sourceIdentity, at: 2, to: statement)
        try bind(createdAt, at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return id
    }

    public func insertMessage(
        conversationID: String,
        sourceDatabase: String,
        sourceTable: String,
        sourceSQLiteRowID: Int64,
        sourceLocalID: Int64?,
        sourceServerID: Int64?,
        timestamp: Int64,
        senderSourceID: String?,
        receiverSourceID: String?,
        rawLocalType: Int64?,
        normalizedType: ArchiveV1NormalizedType,
        textContent: String?,
        replySourceID: String?,
        sourceSequence: Int64,
        sourceValues: [String: ArchivedSQLiteValue]
    ) throws -> (id: String, inserted: Bool) {
        if let id = try messageID(sourceDatabase: sourceDatabase, sourceTable: sourceTable, sqliteRowID: sourceSQLiteRowID) {
            return (id, false)
        }
        let id = UUID().uuidString.lowercased()
        try inTransaction {
            let statement = try prepare("""
                INSERT INTO messages (id, conversation_id, source_database, source_table, source_sqlite_rowid, source_local_id, source_server_id, timestamp, sender_source_id, receiver_source_id, raw_local_type, normalized_type, text_content, reply_source_id, source_sequence, imported_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            try bind(id, at: 1, to: statement)
            try bind(conversationID, at: 2, to: statement)
            try bind(sourceDatabase, at: 3, to: statement)
            try bind(sourceTable, at: 4, to: statement)
            try bind(sourceSQLiteRowID, at: 5, to: statement)
            try bind(sourceLocalID, at: 6, to: statement)
            try bind(sourceServerID, at: 7, to: statement)
            try bind(timestamp, at: 8, to: statement)
            try bind(senderSourceID, at: 9, to: statement)
            try bind(receiverSourceID, at: 10, to: statement)
            try bind(rawLocalType, at: 11, to: statement)
            try bind(normalizedType.rawValue, at: 12, to: statement)
            try bind(textContent, at: 13, to: statement)
            try bind(replySourceID, at: 14, to: statement)
            try bind(sourceSequence, at: 15, to: statement)
            try bind(Date().timeIntervalSince1970, at: 16, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
            try insertSourceValues(sourceValues, for: id)
        }
        return (id, true)
    }

    public func insertMediaAsset(
        messageID: String,
        assetID requestedAssetID: String? = nil,
        mediaType: ArchiveV1MediaType = .image,
        variant: ArchiveV1MediaVariant,
        status: ArchiveV1MediaStatus,
        sourceFormat: String?,
        decodedFormat: String?,
        rawArchivePath: String?,
        decodedArchivePath: String?,
        rawSize: Int64?,
        decodedSize: Int64?,
        width: Int?,
        height: Int?,
        duration: Double? = nil,
        rawSHA256: String?,
        decodedSHA256: String?,
        sourceFileBase: String?
    ) throws -> String {
        let sourceKey = "\(messageID):\(mediaType.rawValue):\(variant.rawValue)"
        let existingID = try scalarString("SELECT id FROM media_assets WHERE source_key = ?", binding: sourceKey)
        let id = existingID ?? requestedAssetID ?? UUID().uuidString.lowercased()
        let statement = try prepare("""
            INSERT INTO media_assets (id, source_key, media_type, variant, source_format, decoded_format, status, raw_archive_path, decoded_archive_path, raw_size, decoded_size, width, height, duration, sha256_raw, sha256_decoded, source_file_base, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
              media_type = excluded.media_type, source_format = excluded.source_format, decoded_format = excluded.decoded_format, status = excluded.status,
              raw_archive_path = excluded.raw_archive_path, decoded_archive_path = excluded.decoded_archive_path,
              raw_size = excluded.raw_size, decoded_size = excluded.decoded_size, width = excluded.width, height = excluded.height, duration = excluded.duration,
              sha256_raw = excluded.sha256_raw, sha256_decoded = excluded.sha256_decoded, source_file_base = excluded.source_file_base
            """)
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        try bind(sourceKey, at: 2, to: statement)
        try bind(mediaType.rawValue, at: 3, to: statement)
        try bind(variant.rawValue, at: 4, to: statement)
        try bind(sourceFormat, at: 5, to: statement)
        try bind(decodedFormat, at: 6, to: statement)
        try bind(status.rawValue, at: 7, to: statement)
        try bind(rawArchivePath, at: 8, to: statement)
        try bind(decodedArchivePath, at: 9, to: statement)
        try bind(rawSize, at: 10, to: statement)
        try bind(decodedSize, at: 11, to: statement)
        try bind(width.map(Int64.init), at: 12, to: statement)
        try bind(height.map(Int64.init), at: 13, to: statement)
        try bind(duration, at: 14, to: statement)
        try bind(rawSHA256, at: 15, to: statement)
        try bind(decodedSHA256, at: 16, to: statement)
        try bind(sourceFileBase, at: 17, to: statement)
        try bind(Date().timeIntervalSince1970, at: 18, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        let assetID = existingID ?? id
        let link = try prepare("INSERT OR IGNORE INTO message_media_links (message_id, media_asset_id, role) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(link) }
        try bind(messageID, at: 1, to: link)
        try bind(assetID, at: 2, to: link)
        try bind(variant.rawValue, at: 3, to: link)
        guard sqlite3_step(link) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return assetID
    }

    public func messageCount() throws -> Int { Int(try scalarInt("SELECT COUNT(*) FROM messages")) }
    public func conversationCount() throws -> Int { Int(try scalarInt("SELECT COUNT(*) FROM conversations")) }
    public func mediaAssetCount() throws -> Int { Int(try scalarInt("SELECT COUNT(*) FROM media_assets")) }

    public func sourceValues(sourceDatabase: String, sourceTable: String, sourceSQLiteRowID: Int64) throws -> [String: ArchivedSQLiteValue] {
        guard let messageID = try messageID(sourceDatabase: sourceDatabase, sourceTable: sourceTable, sqliteRowID: sourceSQLiteRowID) else { return [:] }
        let statement = try prepare("SELECT column_name, sqlite_type, integer_value, real_value, text_value, blob_value FROM message_source_values WHERE message_id = ? ORDER BY column_name")
        defer { sqlite3_finalize(statement) }
        try bind(messageID, at: 1, to: statement)
        var values = [String: ArchivedSQLiteValue]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = columnText(statement, 0), let type = columnText(statement, 1) else { throw ArchiveError.databaseFailure }
            switch type {
            case "null": values[name] = ArchivedSQLiteValue.null
            case "integer": values[name] = .integer(sqlite3_column_int64(statement, 2))
            case "real": values[name] = .real(sqlite3_column_double(statement, 3))
            case "text": values[name] = .text(columnText(statement, 4) ?? "")
            case "blob": values[name] = .blob(columnData(statement, 5) ?? Data())
            default: throw ArchiveError.invalidArchive
            }
        }
        return values
    }

    public func reconstruction() throws -> [ArchiveV1ReconstructedMessage] {
        let statement = try prepare("""
            SELECT m.id, m.normalized_type, m.text_content, m.timestamp, m.source_sequence,
                   a.status
            FROM messages m
            LEFT JOIN message_media_links l ON l.message_id = m.id
            LEFT JOIN media_assets a ON a.id = l.media_asset_id
            ORDER BY m.timestamp ASC, m.source_sequence ASC, m.source_database ASC, m.source_table ASC, m.source_sqlite_rowid ASC, a.variant ASC
            """)
        defer { sqlite3_finalize(statement) }
        var grouped = [(key: String, message: ArchiveV1ReconstructedMessage)]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = columnText(statement, 0),
                  let typeValue = columnText(statement, 1),
                  let type = ArchiveV1NormalizedType(rawValue: typeValue) else { throw ArchiveError.databaseFailure }
            let timestamp = sqlite3_column_int64(statement, 3)
            let sequence = sqlite3_column_int64(statement, 4)
            let text = columnText(statement, 2)
            let status = columnText(statement, 5).flatMap(ArchiveV1MediaStatus.init(rawValue:))
            if let index = grouped.firstIndex(where: { $0.key == key }) {
                var statuses = grouped[index].message.mediaStatuses
                if let status { statuses.append(status) }
                let old = grouped[index].message
                grouped[index].message = ArchiveV1ReconstructedMessage(normalizedType: old.normalizedType, textContent: old.textContent, timestamp: old.timestamp, sourceSequence: old.sourceSequence, mediaStatuses: statuses)
            } else {
                grouped.append((key, ArchiveV1ReconstructedMessage(normalizedType: type, textContent: text, timestamp: timestamp, sourceSequence: sequence, mediaStatuses: status.map { [$0] } ?? [])))
            }
        }
        return grouped.map(\.message)
    }

    public func integrityCheck() throws -> Bool { try scalarString("PRAGMA integrity_check", binding: nil) == "ok" }

    public func foreignKeyCheck() throws -> Bool {
        let statement = try prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { return false }
        return true
    }

    public func mediaRows() throws -> [(rawPath: String?, decodedPath: String?, rawHash: String?, decodedHash: String?)] {
        let statement = try prepare("SELECT raw_archive_path, decoded_archive_path, sha256_raw, sha256_decoded FROM media_assets")
        defer { sqlite3_finalize(statement) }
        var values = [(String?, String?, String?, String?)]()
        while sqlite3_step(statement) == SQLITE_ROW { values.append((columnText(statement, 0), columnText(statement, 1), columnText(statement, 2), columnText(statement, 3))) }
        return values
    }

    private func migrate() throws {
        let version = try schemaVersion()
        guard version == 0 || version == Self.schemaVersion else { throw ArchiveError.invalidArchive }
        guard version == 0 else { return }
        try inTransaction {
            try execute("""
                CREATE TABLE import_runs (id TEXT PRIMARY KEY, started_at REAL NOT NULL, completed_at REAL, app_version TEXT NOT NULL, archive_schema_version INTEGER NOT NULL, source_database_count INTEGER NOT NULL, message_count INTEGER NOT NULL, media_count INTEGER NOT NULL, status TEXT NOT NULL)
                """)
            try execute("CREATE TABLE conversations (id TEXT PRIMARY KEY, source_identity TEXT NOT NULL UNIQUE, conversation_type TEXT NOT NULL, display_name TEXT, created_at INTEGER)")
            try execute("""
                CREATE TABLE messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id), source_database TEXT NOT NULL, source_table TEXT NOT NULL, source_sqlite_rowid INTEGER NOT NULL, source_local_id INTEGER, source_server_id INTEGER, timestamp INTEGER NOT NULL, sender_source_id TEXT, receiver_source_id TEXT, raw_local_type INTEGER, normalized_type TEXT NOT NULL, text_content TEXT, reply_source_id TEXT, source_sequence INTEGER NOT NULL, imported_at REAL NOT NULL, UNIQUE(source_database, source_table, source_sqlite_rowid))
                """)
            try execute("CREATE INDEX messages_reconstruction ON messages(timestamp, source_sequence, source_database, source_table, source_sqlite_rowid)")
            try execute("""
                CREATE TABLE message_source_values (id INTEGER PRIMARY KEY, message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE, column_name TEXT NOT NULL, sqlite_type TEXT NOT NULL, integer_value INTEGER, real_value REAL, text_value TEXT, blob_value BLOB, UNIQUE(message_id, column_name))
                """)
            try execute("""
                CREATE TABLE media_assets (id TEXT PRIMARY KEY, source_key TEXT NOT NULL UNIQUE, media_type TEXT NOT NULL, variant TEXT NOT NULL, source_format TEXT, decoded_format TEXT, status TEXT NOT NULL, raw_archive_path TEXT, decoded_archive_path TEXT, raw_size INTEGER, decoded_size INTEGER, width INTEGER, height INTEGER, duration REAL, sha256_raw TEXT, sha256_decoded TEXT, source_file_base TEXT, created_at REAL NOT NULL)
                """)
            try execute("CREATE TABLE message_media_links (message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE, media_asset_id TEXT NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE, role TEXT NOT NULL, PRIMARY KEY(message_id, media_asset_id, role))")
            try execute("PRAGMA user_version = 2")
        }
    }

    private func insertSourceValues(_ values: [String: ArchivedSQLiteValue], for messageID: String) throws {
        let statement = try prepare("INSERT INTO message_source_values (message_id, column_name, sqlite_type, integer_value, real_value, text_value, blob_value) VALUES (?, ?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        for name in values.keys.sorted() {
            guard let value = values[name] else { continue }
            try bind(messageID, at: 1, to: statement)
            try bind(name, at: 2, to: statement)
            try bind(value.sqliteType, at: 3, to: statement)
            switch value {
            case .null:
                for position in 4...7 { try bindNull(at: Int32(position), to: statement) }
            case let .integer(value):
                try bind(value, at: 4, to: statement); for position in 5...7 { try bindNull(at: Int32(position), to: statement) }
            case let .real(value):
                try bindNull(at: 4, to: statement); try bind(value, at: 5, to: statement); try bindNull(at: 6, to: statement); try bindNull(at: 7, to: statement)
            case let .text(value):
                try bindNull(at: 4, to: statement); try bindNull(at: 5, to: statement); try bind(value, at: 6, to: statement); try bindNull(at: 7, to: statement)
            case let .blob(value):
                try bindNull(at: 4, to: statement); try bindNull(at: 5, to: statement); try bindNull(at: 6, to: statement); try bind(value, at: 7, to: statement)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    private func conversationID(sourceIdentity: String) throws -> String? { try scalarString("SELECT id FROM conversations WHERE source_identity = ?", binding: sourceIdentity) }
    private func messageID(sourceDatabase: String, sourceTable: String, sqliteRowID: Int64) throws -> String? {
        let statement = try prepare("SELECT id FROM messages WHERE source_database = ? AND source_table = ? AND source_sqlite_rowid = ?")
        defer { sqlite3_finalize(statement) }
        try bind(sourceDatabase, at: 1, to: statement); try bind(sourceTable, at: 2, to: statement); try bind(sqliteRowID, at: 3, to: statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return status == SQLITE_ROW ? columnText(statement, 0) : nil
    }

    private func tableNames() throws -> Set<String> {
        let statement = try prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let value = columnText(statement, 0) { names.insert(value) } }
        return names
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarString(_ sql: String, binding: String?) throws -> String? {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        if let binding { try bind(binding, at: 1, to: statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return status == SQLITE_ROW ? columnText(statement, 0) : nil
    }

    private func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func execute(_ sql: String) throws { guard sqlite3_exec(requireHandle(), sql, nil, nil, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure } }
    private func prepare(_ sql: String) throws -> OpaquePointer? { var statement: OpaquePointer?; guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure }; return statement }
    private func requireHandle() -> OpaquePointer { guard let handle else { preconditionFailure("Archive database is closed") }; return handle }
    private func bindNull(at position: Int32, to statement: OpaquePointer?) throws { guard sqlite3_bind_null(statement, position) == SQLITE_OK else { throw ArchiveError.databaseFailure } }
    private func bind(_ value: String?, at position: Int32, to statement: OpaquePointer?) throws { if let value { try bind(value, at: position, to: statement) } else { try bindNull(at: position, to: statement) } }
    private func bind(_ value: String, at position: Int32, to statement: OpaquePointer?) throws { guard sqlite3_bind_text(statement, position, value, -1, archiveV1SQLiteTransient) == SQLITE_OK else { throw ArchiveError.databaseFailure } }
    private func bind(_ value: Int64?, at position: Int32, to statement: OpaquePointer?) throws { if let value { try bind(value, at: position, to: statement) } else { try bindNull(at: position, to: statement) } }
    private func bind(_ value: Int64, at position: Int32, to statement: OpaquePointer?) throws { guard sqlite3_bind_int64(statement, position, value) == SQLITE_OK else { throw ArchiveError.databaseFailure } }
    private func bind(_ value: Double, at position: Int32, to statement: OpaquePointer?) throws { guard sqlite3_bind_double(statement, position, value) == SQLITE_OK else { throw ArchiveError.databaseFailure } }
    private func bind(_ value: Double?, at position: Int32, to statement: OpaquePointer?) throws { if let value { try bind(value, at: position, to: statement) } else { try bindNull(at: position, to: statement) } }
    private func bind(_ value: Data, at position: Int32, to statement: OpaquePointer?) throws { let status = value.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(value.count), archiveV1SQLiteTransient) }; guard status == SQLITE_OK else { throw ArchiveError.databaseFailure } }
    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? { guard let value = sqlite3_column_text(statement, index) else { return nil }; return String(cString: value) }
    private func columnData(_ statement: OpaquePointer?, _ index: Int32) -> Data? { guard let bytes = sqlite3_column_blob(statement, index) else { return nil }; return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))) }

    private static func prepareParent(for url: URL) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let manager = FileManager.default
        if manager.fileExists(atPath: parent.path()) {
            let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        } else {
            try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path())
    }

    private func protectArchiveFile() throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path())
    }
}
