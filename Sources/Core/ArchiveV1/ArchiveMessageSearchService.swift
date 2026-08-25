import Foundation
import SQLite3

private let archiveSearchSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum ArchiveSearchIndexState: Equatable, Sendable {
    case built
    case reused
}

public enum ArchiveSearchTokenizer: String, Equatable, Sendable {
    case trigram
    case unicode61
}

public enum ArchiveSearchIndexError: Error, Equatable, Sendable {
    case cancelled
}

public struct ArchiveSearchIndexPreparation: Equatable, Sendable {
    public let state: ArchiveSearchIndexState
    public let tokenizer: ArchiveSearchTokenizer
    public let indexedMessageCount: Int
}

/// A private, disposable search projection of one archive. It reads only
/// `archive.sqlite`; removing this cache never modifies the source archive.
public final class ArchiveMessageSearchService: @unchecked Sendable {
    /// Bumped when the safe display projection changes so a private index that
    /// once contained legacy quote XML is rebuilt from archive.sqlite.
    private static let presentationVersion = "2"
    public let archiveRoot: URL
    public let indexRoot: URL

    public init(archiveRoot: URL, indexRoot: URL? = nil) {
        self.archiveRoot = archiveRoot.resolvingSymlinksInPath().standardizedFileURL
        self.indexRoot = indexRoot ?? Self.defaultIndexRoot()
    }

    /// The private FTS cache location for this archive. Derived purely from
    /// `archiveRoot`/`indexRoot` — a stable hash of the archive path, never
    /// mutable shared state — so it is safe to read from any thread without
    /// requiring `prepareIndex()` to have run first.
    public var indexURL: URL {
        indexRoot.appendingPathComponent("\(archiveCacheKey).sqlite", isDirectory: false)
    }

    private var archiveCacheKey: String {
        ArchiveCryptography.sha256(Data(archiveRoot.path.utf8))
    }

    /// Builds or reuses the private FTS cache. The progress callback contains
    /// counts only, never message text or source identities.
    public func prepareIndex(
        shouldCancel: () -> Bool = { false },
        progress: (Int, Int) -> Void = { _, _ in }
    ) throws -> ArchiveSearchIndexPreparation {
        let sourceURL = try validatedArchiveDatabaseURL()
        let fingerprint = try sourceFingerprint(databaseURL: sourceURL)
        try prepareIndexDirectory()
        let target = indexURL

        // A corrupt or unreadable cached index (disk corruption, a truncated
        // write) must not permanently block search: treat any failure to
        // read it the same as "no reusable index" and rebuild below, instead
        // of letting the error escape before the corrupt file is removed.
        if let reusable = try? existingPreparation(at: target, fingerprint: fingerprint) {
            return reusable
        }
        try removeExistingIndex(at: target)

        let staging = indexRoot.appendingPathComponent(".\(archiveCacheKey)-\(UUID().uuidString).staging.sqlite", isDirectory: false)
        defer { try? removeExistingIndex(at: staging) }
        let preparation = try buildIndex(
            sourceURL: sourceURL,
            targetURL: staging,
            fingerprint: fingerprint,
            shouldCancel: shouldCancel,
            progress: progress
        )
        try FileManager.default.moveItem(at: staging, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return preparation
    }

    /// Searches the derived index when possible. Before it is available—or if
    /// the runtime does not provide FTS5—it safely falls back to the archive's
    /// read-only LIKE query.
    public func search(query: String, offset: Int = 0, limit: Int = 50) throws -> ArchiveViewerPage<ArchiveViewerMessageSearchResult> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .init(items: [], hasMore: false) }
        let pageSize = min(max(limit, 1), 500)
        let target = indexURL
        let preparation: ArchiveSearchIndexPreparation
        do {
            guard let existing = try existingPreparation(
                at: target,
                fingerprint: try sourceFingerprint(databaseURL: validatedArchiveDatabaseURL())
            ) else {
                return try fallbackSearch(query: trimmed, offset: offset, limit: pageSize)
            }
            preparation = existing
        } catch {
            return try fallbackSearch(query: trimmed, offset: offset, limit: pageSize)
        }

        do {
            // SQLite's trigram tokenizer does not index one- or two-character
            // terms. LIKE preserves practical Chinese searches such as “深圳”.
            if preparation.tokenizer != .trigram || trimmed.unicodeScalars.count < 3 {
                return try indexedLikeSearch(indexURL: target, query: trimmed, offset: offset, limit: pageSize)
            }
            return try ftsSearch(indexURL: target, query: trimmed, offset: offset, limit: pageSize)
        } catch {
            return try fallbackSearch(query: trimmed, offset: offset, limit: pageSize)
        }
    }

    private func buildIndex(
        sourceURL: URL,
        targetURL: URL,
        fingerprint: String,
        shouldCancel: () -> Bool,
        progress: (Int, Int) -> Void
    ) throws -> ArchiveSearchIndexPreparation {
        let source = try open(sourceURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(source) }
        let index = try open(targetURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(index) }
        try execute(index, "PRAGMA journal_mode = DELETE")
        try execute(index, "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let tokenizer = try createFTS(in: index)
        try execute(index, "BEGIN IMMEDIATE")
        do {
            try setMetadata(index, key: "fingerprint", value: fingerprint)
            try setMetadata(index, key: "tokenizer", value: tokenizer.rawValue)
            try setMetadata(index, key: "presentation_version", value: Self.presentationVersion)
            let total = try scalarInt(source, "SELECT COUNT(*) FROM messages WHERE text_content IS NOT NULL AND text_content <> ''")
            let sourceStatement = try prepare(source, """
                SELECT m.id, m.conversation_id, COALESCE(c.display_name, ''), m.timestamp, m.text_content
                FROM messages m
                JOIN conversations c ON c.id = m.conversation_id
                WHERE m.text_content IS NOT NULL AND m.text_content <> ''
                ORDER BY m.timestamp ASC, m.id ASC
                """)
            defer { sqlite3_finalize(sourceStatement) }
            let insert = try prepare(index, "INSERT INTO messages_fts(message_id, conversation_id, conversation_title, timestamp, text_content) VALUES (?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(insert) }
            var count = 0
            while sqlite3_step(sourceStatement) == SQLITE_ROW {
                if shouldCancel() { throw ArchiveSearchIndexError.cancelled }
                guard let id = columnText(sourceStatement, 0),
                      let conversationID = columnText(sourceStatement, 1),
                      let content = columnText(sourceStatement, 4) else { continue }
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                try bind(id, at: 1, to: insert)
                try bind(conversationID, at: 2, to: insert)
                try bind(columnText(sourceStatement, 2) ?? "", at: 3, to: insert)
                try bind(sqlite3_column_int64(sourceStatement, 3), at: 4, to: insert)
                try bind(ArchiveMessagePresentationFormatter.displayText(for: content) ?? "", at: 5, to: insert)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
                count += 1
                if count.isMultiple(of: 250) { progress(count, total) }
            }
            progress(count, total)
            try execute(index, "COMMIT")
            return .init(state: .built, tokenizer: tokenizer, indexedMessageCount: count)
        } catch {
            _ = try? execute(index, "ROLLBACK")
            throw error
        }
    }

    private func ftsSearch(indexURL: URL, query: String, offset: Int, limit: Int) throws -> ArchiveViewerPage<ArchiveViewerMessageSearchResult> {
        try runSearch(indexURL: indexURL, sql: """
            SELECT message_id, conversation_id, conversation_title, timestamp, text_content
            FROM messages_fts
            WHERE messages_fts MATCH ?
            ORDER BY CAST(timestamp AS INTEGER) DESC, message_id DESC
            LIMIT ? OFFSET ?
            """, query: ftsPhrase(query), snippetQuery: query, offset: offset, limit: limit)
    }

    private func indexedLikeSearch(indexURL: URL, query: String, offset: Int, limit: Int) throws -> ArchiveViewerPage<ArchiveViewerMessageSearchResult> {
        try runSearch(indexURL: indexURL, sql: """
            SELECT message_id, conversation_id, conversation_title, timestamp, text_content
            FROM messages_fts
            WHERE text_content LIKE ? ESCAPE '\\'
            ORDER BY CAST(timestamp AS INTEGER) DESC, message_id DESC
            LIMIT ? OFFSET ?
            """, query: "%\(escapedLikePattern(query))%", snippetQuery: query, offset: offset, limit: limit)
    }

    private func runSearch(indexURL: URL, sql: String, query: String, snippetQuery: String, offset: Int, limit: Int) throws -> ArchiveViewerPage<ArchiveViewerMessageSearchResult> {
        let database = try open(indexURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(database) }
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        try bind(query, at: 1, to: statement)
        try bind(Int64(limit + 1), at: 2, to: statement)
        try bind(Int64(max(0, offset)), at: 3, to: statement)
        var results = [ArchiveViewerMessageSearchResult]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, 0), let conversationID = columnText(statement, 1) else { continue }
            let title = columnText(statement, 2).flatMap { $0.isEmpty ? nil : $0 } ?? "会话"
            let content = ArchiveMessagePresentationFormatter.displayText(for: columnText(statement, 4)) ?? ""
            results.append(.init(
                id: id,
                conversationID: conversationID,
                conversationTitle: title,
                timestamp: sqlite3_column_int64(statement, 3),
                normalizedType: .text,
                snippet: ArchiveTextSnippetBuilder.snippet(for: content, query: snippetQuery)
            ))
        }
        let hasMore = results.count > limit
        if hasMore { results.removeLast() }
        return .init(items: results, hasMore: hasMore)
    }

    private func fallbackSearch(query: String, offset: Int, limit: Int) throws -> ArchiveViewerPage<ArchiveViewerMessageSearchResult> {
        try WeChatArchiveViewerDatabase(archiveRoot: archiveRoot).searchMessagePage(query: query, offset: offset, limit: limit)
    }

    private func prepareIndexDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: indexRoot.path) {
            let values = try indexRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        } else {
            try manager.createDirectory(at: indexRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: indexRoot.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = indexRoot
        try mutableRoot.setResourceValues(values)
    }

    private func existingPreparation(at url: URL, fingerprint: String) throws -> ArchiveSearchIndexPreparation? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        let database = try open(url, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(database) }
        guard try metadata(database, key: "fingerprint") == fingerprint,
              try metadata(database, key: "presentation_version") == Self.presentationVersion,
              let tokenizerValue = try metadata(database, key: "tokenizer"),
              let tokenizer = ArchiveSearchTokenizer(rawValue: tokenizerValue) else { return nil }
        return .init(state: .reused, tokenizer: tokenizer, indexedMessageCount: try scalarInt(database, "SELECT COUNT(*) FROM messages_fts"))
    }

    private func removeExistingIndex(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        try FileManager.default.removeItem(at: url)
    }

    private func validatedArchiveDatabaseURL() throws -> URL {
        let databaseURL = archiveRoot.appendingPathComponent("archive.sqlite", isDirectory: false)
        let values = try databaseURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
        return databaseURL
    }

    private func sourceFingerprint(databaseURL: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let database = try open(databaseURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(database) }
        let messageCount = try scalarInt(database, "SELECT COUNT(*) FROM messages")
        let schemaVersion = try scalarInt(database, "PRAGMA user_version")
        return "\(archiveCacheKey)|\(size)|\(modificationDate)|\(messageCount)|\(schemaVersion)"
    }

    private func createFTS(in database: OpaquePointer) throws -> ArchiveSearchTokenizer {
        do {
            try execute(database, "CREATE VIRTUAL TABLE messages_fts USING fts5(message_id UNINDEXED, conversation_id UNINDEXED, conversation_title UNINDEXED, timestamp UNINDEXED, text_content, tokenize='trigram')")
            return .trigram
        } catch {
            try execute(database, "CREATE VIRTUAL TABLE messages_fts USING fts5(message_id UNINDEXED, conversation_id UNINDEXED, conversation_title UNINDEXED, timestamp UNINDEXED, text_content, tokenize='unicode61')")
            return .unicode61
        }
    }

    private func setMetadata(_ database: OpaquePointer, key: String, value: String) throws {
        let statement = try prepare(database, "INSERT INTO metadata(key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        try bind(value, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
    }

    private func metadata(_ database: OpaquePointer, key: String) throws -> String? {
        let statement = try prepare(database, "SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? columnText(statement, 0) : nil
    }

    private func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveError.databaseFailure
        }
        return database
    }

    private func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ArchiveError.databaseFailure }
        return statement
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            sqlite3_free(error)
            throw ArchiveError.databaseFailure
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, archiveSearchSQLiteTransient) == SQLITE_OK else { throw ArchiveError.databaseFailure }
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw ArchiveError.databaseFailure }
    }

    private func scalarInt(_ database: OpaquePointer, _ sql: String) throws -> Int {
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func ftsPhrase(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func defaultIndexRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WeChat Archive", isDirectory: true)
            .appendingPathComponent("SearchIndexes", isDirectory: true)
    }
}
