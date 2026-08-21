import Foundation
import SQLite3

private let archiveViewerSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ArchiveViewerConversation: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let type: ArchiveV1ConversationType
    public let lastMessageTimestamp: Int64?
    public let messageCount: Int
}

public struct ArchiveViewerPage<Item: Equatable & Sendable>: Equatable, Sendable {
    public let items: [Item]
    public let hasMore: Bool

    public init(items: [Item], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}

public struct ArchiveViewerMedia: Identifiable, Equatable, Sendable {
    public let id: String
    public let mediaType: ArchiveV1MediaType
    public let variant: ArchiveV1MediaVariant
    public let status: ArchiveV1MediaStatus
    public let rawRelativePath: String?
    public let decodedRelativePath: String?
    public let width: Int?
    public let height: Int?
    public let duration: Double?
    public let rawSize: Int64?
    public let decodedSize: Int64?
}

public struct ArchiveViewerMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Int64
    public let normalizedType: ArchiveV1NormalizedType
    public let rawLocalType: Int64?
    public let textContent: String?
    public let hasSender: Bool
    public let direction: ArchiveV1MessageDirection
    public let senderDisplayName: String?
    public var media: [ArchiveViewerMedia]
}

/// A read-only, paged view over a self-contained archive. This type never
/// accepts or opens a WeChat source directory, key map, or source database.
public final class WeChatArchiveViewerDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var sourceRowIDColumn: String
    private var archiveSchemaVersion: Int
    public let archiveRoot: URL

    public init(archiveRoot: URL) throws {
        let root = archiveRoot.standardizedFileURL
        let rootMetadata = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootMetadata.isDirectory == true, rootMetadata.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
        let databaseURL = root.appending(path: "archive.sqlite")
        let databaseMetadata = try databaseURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard databaseMetadata.isRegularFile == true, databaseMetadata.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path(), &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveError.databaseFailure
        }
        handle = database
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        self.archiveRoot = resolvedRoot
        self.sourceRowIDColumn = "source_sqlite_rowid"
        self.archiveSchemaVersion = 1
        do {
            try execute("PRAGMA query_only = ON")
            let version = try schemaVersion()
            guard version == 1 || version == 2 || version == WeChatArchiveV1Database.schemaVersion else { throw ArchiveError.invalidArchive }
            archiveSchemaVersion = version
            sourceRowIDColumn = version == 1 ? "source_row_identifier" : "source_sqlite_rowid"
            _ = try requiredTables()
        } catch {
            sqlite3_close(database)
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    public func listConversations(offset: Int = 0, limit: Int = 500) throws -> [ArchiveViewerConversation] {
        try conversationPage(offset: offset, limit: limit).items
    }

    public func conversationPage(offset: Int = 0, limit: Int = 100) throws -> ArchiveViewerPage<ArchiveViewerConversation> {
        let pageSize = clamped(limit)
        let statement = try prepare("""
            SELECT c.id, c.display_name, c.conversation_type, MAX(m.timestamp), COUNT(m.id)
            FROM conversations c
            LEFT JOIN messages m ON m.conversation_id = c.id
            GROUP BY c.id, c.display_name, c.conversation_type, c.created_at
            ORDER BY COALESCE(MAX(m.timestamp), c.created_at, 0) DESC, c.id ASC
            LIMIT ? OFFSET ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(Int64(pageSize + 1), at: 1, to: statement)
        try bind(Int64(max(offset, 0)), at: 2, to: statement)
        var conversations = [ArchiveViewerConversation]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { throw ArchiveError.invalidArchive }
            let ordinal = offset + conversations.count + 1
            let type = text(statement, 2).flatMap(ArchiveV1ConversationType.init(rawValue:)) ?? .unknown
            let fallback = type == .group ? "Group Chat" : "Conversation \(ordinal)"
            let title = text(statement, 1).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            conversations.append(.init(
                id: id,
                title: title,
                type: type,
                lastMessageTimestamp: integer(statement, 3),
                messageCount: Int(sqlite3_column_int64(statement, 4))
            ))
        }
        let hasMore = conversations.count > pageSize
        if hasMore { conversations.removeLast() }
        return .init(items: conversations, hasMore: hasMore)
    }

    /// Fetches one page of messages plus their media in a single joined query,
    /// avoiding one media query per timeline item.
    public func messages(conversationID: String, offset: Int = 0, limit: Int = 100) throws -> [ArchiveViewerMessage] {
        try messagePage(conversationID: conversationID, offset: offset, limit: limit).items
    }

    public func messagePage(conversationID: String, offset: Int = 0, limit: Int = 100) throws -> ArchiveViewerPage<ArchiveViewerMessage> {
        let pageSize = clamped(limit)
        let order = "timestamp ASC, source_sequence ASC, source_database ASC, source_table ASC, \(sourceRowIDColumn) ASC"
        let directionColumns = archiveSchemaVersion >= 3 ? "sender_display_name, direction" : "NULL AS sender_display_name, 'unknown' AS direction"
        let statement = try prepare("""
            WITH page AS (
                SELECT id, timestamp, normalized_type, raw_local_type, text_content, sender_source_id, \(directionColumns), source_sequence, source_database, source_table, \(sourceRowIDColumn)
                FROM messages
                WHERE conversation_id = ?
                ORDER BY \(order)
                LIMIT ? OFFSET ?
            )
            SELECT page.id, page.timestamp, page.normalized_type, page.raw_local_type, page.text_content, page.sender_source_id, page.sender_display_name, page.direction,
                   a.id, a.media_type, a.variant, a.status, a.raw_archive_path, a.decoded_archive_path, a.width, a.height, a.duration, a.raw_size, a.decoded_size
            FROM page
            LEFT JOIN message_media_links l ON l.message_id = page.id
            LEFT JOIN media_assets a ON a.id = l.media_asset_id
            ORDER BY \(order), a.media_type ASC, a.variant ASC
            """)
        defer { sqlite3_finalize(statement) }
        try bind(conversationID, at: 1, to: statement)
        try bind(Int64(pageSize + 1), at: 2, to: statement)
        try bind(Int64(max(offset, 0)), at: 3, to: statement)

        var messages = [ArchiveViewerMessage]()
        var indexes = [String: Int]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0),
                  let typeValue = text(statement, 2),
                  let normalizedType = ArchiveV1NormalizedType(rawValue: typeValue) else { throw ArchiveError.invalidArchive }
            let messageIndex: Int
            if let existing = indexes[id] {
                messageIndex = existing
            } else {
                let rawType = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 3)
                let message = ArchiveViewerMessage(
                    id: id,
                    timestamp: sqlite3_column_int64(statement, 1),
                    normalizedType: normalizedType,
                    rawLocalType: rawType,
                    textContent: text(statement, 4),
                    hasSender: text(statement, 5) != nil,
                    direction: text(statement, 7).flatMap(ArchiveV1MessageDirection.init(rawValue:)) ?? .unknown,
                    senderDisplayName: text(statement, 6),
                    media: []
                )
                messageIndex = messages.count
                indexes[id] = messageIndex
                messages.append(message)
            }
            guard let assetID = text(statement, 8) else { continue }
            guard let mediaTypeValue = text(statement, 9), let mediaType = ArchiveV1MediaType(rawValue: mediaTypeValue),
                  let variantValue = text(statement, 10), let variant = ArchiveV1MediaVariant(rawValue: variantValue),
                  let statusValue = text(statement, 11), let status = ArchiveV1MediaStatus(rawValue: statusValue) else { throw ArchiveError.invalidArchive }
            messages[messageIndex].media.append(.init(
                id: assetID,
                mediaType: mediaType,
                variant: variant,
                status: status,
                rawRelativePath: text(statement, 12),
                decodedRelativePath: text(statement, 13),
                width: integer(statement, 14).map(Int.init),
                height: integer(statement, 15).map(Int.init),
                duration: sqlite3_column_type(statement, 16) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 16),
                rawSize: integer(statement, 17),
                decodedSize: integer(statement, 18)
            ))
        }
        let hasMore = messages.count > pageSize
        if hasMore { messages.removeLast() }
        return .init(items: messages, hasMore: hasMore)
    }

    public func mediaURL(for media: ArchiveViewerMedia, preferDecoded: Bool) -> URL? {
        let preferred = preferDecoded ? [media.decodedRelativePath, media.rawRelativePath] : [media.rawRelativePath, media.decodedRelativePath]
        return preferred.compactMap { $0 }.compactMap(validMediaURL(relativePath:)).first
    }

    private func validMediaURL(relativePath: String) -> URL? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        var requested = archiveRoot
        for component in components {
            requested = requested.appending(path: component).standardizedFileURL
            guard let metadata = try? requested.resourceValues(forKeys: [.isSymbolicLinkKey]), metadata.isSymbolicLink != true else { return nil }
        }
        let rootPath = archiveRoot.path().hasSuffix("/") ? archiveRoot.path() : archiveRoot.path() + "/"
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path().hasPrefix(rootPath),
              let metadata = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), metadata.isRegularFile == true, metadata.isSymbolicLink != true else { return nil }
        return resolved
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.invalidArchive }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func requiredTables() throws -> Set<String> {
        let statement = try prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        defer { sqlite3_finalize(statement) }
        var tables = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let value = text(statement, 0) { tables.insert(value) } }
        let expected: Set<String> = ["conversations", "messages", "media_assets", "message_media_links"]
        guard expected.isSubset(of: tables) else { throw ArchiveError.invalidArchive }
        return tables
    }

    private func clamped(_ value: Int) -> Int { min(max(value, 1), 500) }
    private func requireHandle() -> OpaquePointer { guard let handle else { preconditionFailure("Archive viewer database is closed") }; return handle }
    private func execute(_ sql: String) throws { guard sqlite3_exec(requireHandle(), sql, nil, nil, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure } }
    private func prepare(_ sql: String) throws -> OpaquePointer? { var statement: OpaquePointer?; guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure }; return statement }
    private func bind(_ value: String, at position: Int32, to statement: OpaquePointer?) throws { guard sqlite3_bind_text(statement, position, value, -1, archiveViewerSQLiteTransient) == SQLITE_OK else { throw ArchiveError.databaseFailure } }
    private func bind(_ value: Int64, at position: Int32, to statement: OpaquePointer?) throws { guard sqlite3_bind_int64(statement, position, value) == SQLITE_OK else { throw ArchiveError.databaseFailure } }
    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? { guard let value = sqlite3_column_text(statement, index) else { return nil }; return String(cString: value) }
    private func integer(_ statement: OpaquePointer?, _ index: Int32) -> Int64? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index) }
}
