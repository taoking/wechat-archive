import Foundation
import SQLite3

private let archiveViewerSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ArchiveViewerConversation: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let type: ArchiveV1ConversationType
    public let lastMessageTimestamp: Int64?
    public let messageCount: Int
    public let lastMessagePreview: String?
    public let memberCount: Int
    public let avatar: ArchiveViewerAvatar?
}

public struct ArchiveViewerAvatar: Identifiable, Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let width: Int?
    public let height: Int?
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
    public let avatar: ArchiveViewerAvatar?
    public var media: [ArchiveViewerMedia]
}

/// A stable, source-preserving position in a conversation timeline. It is
/// deliberately a value cursor rather than an OFFSET so loading around a
/// search or date jump remains correct when many messages share one second.
public struct ArchiveMessageCursor: Equatable, Sendable {
    public let timestamp: Int64
    public let sourceSequence: Int64
    public let sourceDatabase: String
    public let sourceTable: String
    public let sourceSQLiteRowID: Int64
    public let messageID: String
}

/// Pure formatting helpers for the Viewer copy actions. These deliberately
/// operate only on already-normalized display fields, never source rows.
public enum ArchiveViewerMessageCopyFormatter {
    public static func text(_ message: ArchiveViewerMessage) -> String {
        ArchiveMessagePresentationFormatter.displayText(for: message.textContent) ?? ""
    }

    public static func textWithTimestamp(_ message: ArchiveViewerMessage, timeZone: TimeZone = .current) -> String {
        "\(timestamp(message, timeZone: timeZone))\n\(text(message))"
    }

    public static func textWithSenderAndTimestamp(_ message: ArchiveViewerMessage, timeZone: TimeZone = .current) -> String {
        let sender = message.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = (sender?.isEmpty == false ? sender! : "消息") + " · " + timestamp(message, timeZone: timeZone)
        return "\(prefix)\n\(text(message))"
    }

    private static func timestamp(_ message: ArchiveViewerMessage, timeZone: TimeZone) -> String {
        guard message.timestamp > 0 else { return "未知时间" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.timestamp)))
    }
}

/// A bounded, chronologically ordered viewport around an archive message.
/// `hasOlder` and `hasNewer` let the UI continue browsing in either direction
/// after a search or date jump without exposing source-database coordinates.
public struct ArchiveViewerMessageWindow: Equatable, Sendable {
    public let items: [ArchiveViewerMessage]
    public let hasOlder: Bool
    public let hasNewer: Bool
}

/// One local-calendar day containing one or more messages in a conversation.
/// The day is an ISO-8601 calendar date in the caller-supplied timezone.
public struct ArchiveViewerDateBucket: Identifiable, Equatable, Sendable {
    public let day: String
    public let messageCount: Int
    public var id: String { day }
}

/// One text-content search hit. It carries only a display snippet, never the
/// full message body or any source database identifier.
public struct ArchiveViewerMessageSearchResult: Identifiable, Equatable, Sendable {
    public let id: String
    public let conversationID: String
    public let conversationTitle: String
    public let timestamp: Int64
    public let normalizedType: ArchiveV1NormalizedType
    public let snippet: String
}

public struct ArchiveViewerTypeCoverage: Identifiable, Equatable, Sendable {
    public var id: String { normalizedType.rawValue }
    public let normalizedType: ArchiveV1NormalizedType
    public let messageCount: Int
}

public struct ArchiveViewerMediaCoverage: Identifiable, Equatable, Sendable {
    public var id: String { "\(mediaType.rawValue)-\(status.rawValue)" }
    public let mediaType: ArchiveV1MediaType
    public let status: ArchiveV1MediaStatus
    public let count: Int
}

/// A read-only summary of how much of the archive Core could normalize into
/// a displayable type. It never includes message text or media bytes.
public struct ArchiveViewerCoverageSummary: Equatable, Sendable {
    public let totalMessages: Int
    public let totalConversations: Int
    public let byType: [ArchiveViewerTypeCoverage]
    public let mediaByStatus: [ArchiveViewerMediaCoverage]
}

/// A read-only, paged view over a self-contained archive. This type never
/// accepts or opens a WeChat source directory, key map, or source database.
public final class WeChatArchiveViewerDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var sourceRowIDColumn: String
    private var archiveSchemaVersion: Int
    private var accountAvatar: ArchiveViewerAvatar?
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
        self.accountAvatar = nil
        do {
            try execute("PRAGMA query_only = ON")
            let version = try schemaVersion()
            guard (1...WeChatArchiveV1Database.schemaVersion).contains(version) else { throw ArchiveError.invalidArchive }
            archiveSchemaVersion = version
            sourceRowIDColumn = version == 1 ? "source_row_identifier" : "source_sqlite_rowid"
            _ = try requiredTables()
            if version >= 4 {
                accountAvatar = try avatar(ownerType: .account, ownerID: "1")
            }
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
        try conversationPage(filter: .all, offset: offset, limit: limit)
    }

    /// Searches only Archive conversation titles. It never searches source
    /// SQLite values or message bodies.
    public func searchConversationPage(query: String, offset: Int = 0, limit: Int = 100) throws -> ArchiveViewerPage<ArchiveViewerConversation> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try conversationPage(filter: trimmed.isEmpty ? .all : .title(trimmed), offset: offset, limit: limit)
    }

    public func conversation(id: String) throws -> ArchiveViewerConversation? {
        try conversationPage(filter: .identifier(id), offset: 0, limit: 1).items.first
    }

    private enum ConversationFilter {
        case all
        case title(String)
        case identifier(String)
    }

    private func conversationPage(filter: ConversationFilter, offset: Int, limit: Int) throws -> ArchiveViewerPage<ArchiveViewerConversation> {
        let pageSize = clamped(limit)
        let avatarColumns = archiveSchemaVersion >= 4
            ? ", avatar.id, avatar.archive_path, avatar.width, avatar.height"
            : ", NULL, NULL, NULL, NULL"
        let avatarJoin = archiveSchemaVersion >= 4
            ? """
              LEFT JOIN avatar_owner_links avatar_link ON avatar_link.owner_type = CASE WHEN c.conversation_type = 'group' THEN 'group' ELSE 'contact' END
                AND avatar_link.owner_id = CASE WHEN c.conversation_type = 'group' THEN c.id ELSE c.contact_id END
              LEFT JOIN avatar_assets avatar ON avatar.id = avatar_link.avatar_asset_id AND avatar.archive_path IS NOT NULL
              """
            : ""
        let searchClause: String
        switch filter {
        case .all: searchClause = ""
        case .title: searchClause = "WHERE COALESCE(c.display_name, '') LIKE ? ESCAPE '\\'"
        case .identifier: searchClause = "WHERE c.id = ?"
        }
        let statement = try prepare("""
            WITH filtered_conversations AS (
                SELECT c.id, c.display_name, c.conversation_type, c.created_at, c.contact_id
                FROM conversations c
                \(searchClause)
            ), latest_messages AS (
                SELECT m.conversation_id, m.timestamp, m.normalized_type, m.text_content,
                       COUNT(*) OVER (PARTITION BY m.conversation_id) AS message_count,
                       ROW_NUMBER() OVER (
                           PARTITION BY m.conversation_id
                           ORDER BY m.timestamp DESC, m.source_sequence DESC, m.source_database DESC, m.source_table DESC, m.\(sourceRowIDColumn) DESC
                       ) AS timeline_rank
                FROM messages m
                JOIN filtered_conversations c ON c.id = m.conversation_id
            )
            SELECT c.id, c.display_name, c.conversation_type, latest.timestamp, COALESCE(latest.message_count, 0),
                   latest.normalized_type, latest.text_content,
                   \(archiveSchemaVersion >= 3 ? "(SELECT COUNT(*) FROM group_members gm WHERE gm.conversation_id = c.id)" : "0")
                   \(avatarColumns)
            FROM filtered_conversations c
            LEFT JOIN latest_messages latest ON latest.conversation_id = c.id AND latest.timeline_rank = 1
            \(avatarJoin)
            ORDER BY COALESCE(latest.timestamp, c.created_at, 0) DESC, c.id ASC
            LIMIT ? OFFSET ?
            """)
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        switch filter {
        case .all: break
        case let .title(query):
            try bind("%\(escapedLikePattern(query))%", at: bindIndex, to: statement)
            bindIndex += 1
        case let .identifier(id):
            try bind(id, at: bindIndex, to: statement)
            bindIndex += 1
        }
        try bind(Int64(pageSize + 1), at: bindIndex, to: statement)
        try bind(Int64(max(offset, 0)), at: bindIndex + 1, to: statement)
        var conversations = [ArchiveViewerConversation]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { throw ArchiveError.invalidArchive }
            let ordinal = offset + conversations.count + 1
            let type = text(statement, 2).flatMap(ArchiveV1ConversationType.init(rawValue:)) ?? .unknown
            let fallback = type == .group ? "群聊" : "会话 \(ordinal)"
            let title = text(statement, 1).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            conversations.append(.init(
                id: id,
                title: title,
                type: type,
                lastMessageTimestamp: integer(statement, 3),
                messageCount: Int(sqlite3_column_int64(statement, 4)),
                lastMessagePreview: conversationPreview(normalizedType: text(statement, 5), textContent: text(statement, 6)),
                memberCount: Int(sqlite3_column_int64(statement, 7)),
                avatar: avatar(statement, idIndex: 8, pathIndex: 9, widthIndex: 10, heightIndex: 11)
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
        try pagedMessagePage(conversationID: conversationID, offset: offset, limit: limit, newestFirst: false)
    }

    public func recentMessagePage(conversationID: String, offset: Int = 0, limit: Int = 100) throws -> ArchiveViewerPage<ArchiveViewerMessage> {
        try pagedMessagePage(conversationID: conversationID, offset: offset, limit: limit, newestFirst: true)
    }

    private func pagedMessagePage(conversationID: String, offset: Int, limit: Int, newestFirst: Bool) throws -> ArchiveViewerPage<ArchiveViewerMessage> {
        let pageSize = clamped(limit)
        let order = "timestamp ASC, source_sequence ASC, source_database ASC, source_table ASC, \(sourceRowIDColumn) ASC"
        let pageOrder = newestFirst
            ? "timestamp DESC, source_sequence DESC, source_database DESC, source_table DESC, \(sourceRowIDColumn) DESC"
            : order
        let directionColumns = archiveSchemaVersion >= 3 ? "sender_display_name, direction" : "NULL AS sender_display_name, 'unknown' AS direction"
        let senderContactColumn = archiveSchemaVersion >= 3 ? "sender_contact_id" : "NULL AS sender_contact_id"
        let avatarColumns = archiveSchemaVersion >= 4 ? "sender_avatar.id, sender_avatar.archive_path, sender_avatar.width, sender_avatar.height" : "NULL, NULL, NULL, NULL"
        let avatarJoin = archiveSchemaVersion >= 4
            ? """
              LEFT JOIN avatar_owner_links sender_avatar_link ON sender_avatar_link.owner_type = 'contact' AND sender_avatar_link.owner_id = page.sender_contact_id
              LEFT JOIN avatar_assets sender_avatar ON sender_avatar.id = sender_avatar_link.avatar_asset_id AND sender_avatar.archive_path IS NOT NULL
              """
            : ""
        let statement = try prepare("""
            WITH page AS (
                SELECT id, timestamp, normalized_type, raw_local_type, text_content, sender_source_id, \(directionColumns), \(senderContactColumn), source_sequence, source_database, source_table, \(sourceRowIDColumn)
                FROM messages
                WHERE conversation_id = ?
                ORDER BY \(pageOrder)
                LIMIT ? OFFSET ?
            )
            SELECT page.id, page.timestamp, page.normalized_type, page.raw_local_type, page.text_content, page.sender_source_id, page.sender_display_name, page.direction, page.sender_contact_id,
                   \(avatarColumns),
                   a.id, a.media_type, a.variant, a.status, a.raw_archive_path, a.decoded_archive_path, a.width, a.height, a.duration, a.raw_size, a.decoded_size
            FROM page
            LEFT JOIN message_media_links l ON l.message_id = page.id
            LEFT JOIN media_assets a ON a.id = l.media_asset_id
            \(avatarJoin)
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
                let direction = text(statement, 7).flatMap(ArchiveV1MessageDirection.init(rawValue:)) ?? .unknown
                let senderAvatar = avatar(statement, idIndex: 9, pathIndex: 10, widthIndex: 11, heightIndex: 12)
                let message = ArchiveViewerMessage(
                    id: id,
                    timestamp: sqlite3_column_int64(statement, 1),
                    normalizedType: normalizedType,
                    rawLocalType: rawType,
                    textContent: text(statement, 4),
                    hasSender: text(statement, 5) != nil,
                    direction: direction,
                    senderDisplayName: text(statement, 6),
                    avatar: direction == .outgoing ? accountAvatar : senderAvatar,
                    media: []
                )
                messageIndex = messages.count
                indexes[id] = messageIndex
                messages.append(message)
            }
            guard let assetID = text(statement, 13) else { continue }
            guard let mediaTypeValue = text(statement, 14), let mediaType = ArchiveV1MediaType(rawValue: mediaTypeValue),
                  let variantValue = text(statement, 15), let variant = ArchiveV1MediaVariant(rawValue: variantValue),
                  let statusValue = text(statement, 16), let status = ArchiveV1MediaStatus(rawValue: statusValue) else { throw ArchiveError.invalidArchive }
            messages[messageIndex].media.append(.init(
                id: assetID,
                mediaType: mediaType,
                variant: variant,
                status: status,
                rawRelativePath: text(statement, 17),
                decodedRelativePath: text(statement, 18),
                width: integer(statement, 19).map(Int.init),
                height: integer(statement, 20).map(Int.init),
                duration: sqlite3_column_type(statement, 21) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 21),
                rawSize: integer(statement, 22),
                decodedSize: integer(statement, 23)
            ))
        }
        let hasMore = messages.count > pageSize
        if hasMore {
            // The extra row is the oldest row when the CTE selected newest
            // first, but becomes the last row in ordinary forward paging.
            if newestFirst { messages.removeFirst() } else { messages.removeLast() }
        }
        return .init(items: messages, hasMore: hasMore)
    }

    /// Returns a stable cursor for a visible message. The cursor retains the
    /// full physical ordering key used by the Archive, rather than assuming
    /// timestamps are unique.
    public func messageCursor(conversationID: String, messageID: String) throws -> ArchiveMessageCursor? {
        let statement = try prepare("""
            SELECT timestamp, source_sequence, source_database, source_table, \(sourceRowIDColumn), id
            FROM messages
            WHERE conversation_id = ? AND id = ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(conversationID, at: 1, to: statement)
        try bind(messageID, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let sourceDatabase = text(statement, 2),
              let sourceTable = text(statement, 3),
              let id = text(statement, 5) else { return nil }
        return .init(
            timestamp: sqlite3_column_int64(statement, 0),
            sourceSequence: sqlite3_column_int64(statement, 1),
            sourceDatabase: sourceDatabase,
            sourceTable: sourceTable,
            sourceSQLiteRowID: sqlite3_column_int64(statement, 4),
            messageID: id
        )
    }

    /// Loads messages strictly before `cursor`, in chronological order.
    public func olderMessages(conversationID: String, before cursor: ArchiveMessageCursor, limit: Int = 100) throws -> ArchiveViewerPage<ArchiveViewerMessage> {
        try keysetMessagePage(conversationID: conversationID, cursor: cursor, relation: .before, limit: limit)
    }

    /// Loads messages strictly after `cursor`, in chronological order.
    public func newerMessages(conversationID: String, after cursor: ArchiveMessageCursor, limit: Int = 100) throws -> ArchiveViewerPage<ArchiveViewerMessage> {
        try keysetMessagePage(conversationID: conversationID, cursor: cursor, relation: .after, limit: limit)
    }

    private enum KeysetRelation { case before, after, atOrAfter }

    private func keysetMessagePage(
        conversationID: String,
        cursor: ArchiveMessageCursor,
        relation: KeysetRelation,
        limit: Int
    ) throws -> ArchiveViewerPage<ArchiveViewerMessage> {
        let pageSize = clamped(limit)
        let comparison: String
        let pageOrder: String
        let selectedDescending: Bool
        switch relation {
        case .before:
            comparison = "<"
            pageOrder = "timestamp DESC, source_sequence DESC, source_database DESC, source_table DESC, \(sourceRowIDColumn) DESC, id DESC"
            selectedDescending = true
        case .after:
            comparison = ">"
            pageOrder = "timestamp ASC, source_sequence ASC, source_database ASC, source_table ASC, \(sourceRowIDColumn) ASC, id ASC"
            selectedDescending = false
        case .atOrAfter:
            comparison = ">="
            pageOrder = "timestamp ASC, source_sequence ASC, source_database ASC, source_table ASC, \(sourceRowIDColumn) ASC, id ASC"
            selectedDescending = false
        }
        let chronologicalOrder = "page.timestamp ASC, page.source_sequence ASC, page.source_database ASC, page.source_table ASC, page.\(sourceRowIDColumn) ASC, page.id ASC"
        let directionColumns = archiveSchemaVersion >= 3 ? "sender_display_name, direction" : "NULL AS sender_display_name, 'unknown' AS direction"
        let senderContactColumn = archiveSchemaVersion >= 3 ? "sender_contact_id" : "NULL AS sender_contact_id"
        let avatarColumns = archiveSchemaVersion >= 4 ? "sender_avatar.id, sender_avatar.archive_path, sender_avatar.width, sender_avatar.height" : "NULL, NULL, NULL, NULL"
        let avatarJoin = archiveSchemaVersion >= 4
            ? """
              LEFT JOIN avatar_owner_links sender_avatar_link ON sender_avatar_link.owner_type = 'contact' AND sender_avatar_link.owner_id = page.sender_contact_id
              LEFT JOIN avatar_assets sender_avatar ON sender_avatar.id = sender_avatar_link.avatar_asset_id AND sender_avatar.archive_path IS NOT NULL
              """
            : ""
        let statement = try prepare("""
            WITH page AS (
                SELECT id, timestamp, normalized_type, raw_local_type, text_content, sender_source_id, \(directionColumns), \(senderContactColumn), source_sequence, source_database, source_table, \(sourceRowIDColumn)
                FROM messages
                WHERE conversation_id = ?
                  AND (timestamp, source_sequence, source_database, source_table, \(sourceRowIDColumn), id) \(comparison) (?, ?, ?, ?, ?, ?)
                ORDER BY \(pageOrder)
                LIMIT ?
            )
            SELECT page.id, page.timestamp, page.normalized_type, page.raw_local_type, page.text_content, page.sender_source_id, page.sender_display_name, page.direction, page.sender_contact_id,
                   \(avatarColumns),
                   a.id, a.media_type, a.variant, a.status, a.raw_archive_path, a.decoded_archive_path, a.width, a.height, a.duration, a.raw_size, a.decoded_size
            FROM page
            LEFT JOIN message_media_links l ON l.message_id = page.id
            LEFT JOIN media_assets a ON a.id = l.media_asset_id
            \(avatarJoin)
            ORDER BY \(chronologicalOrder), a.media_type ASC, a.variant ASC
            """)
        defer { sqlite3_finalize(statement) }
        try bind(conversationID, at: 1, to: statement)
        try bind(cursor.timestamp, at: 2, to: statement)
        try bind(cursor.sourceSequence, at: 3, to: statement)
        try bind(cursor.sourceDatabase, at: 4, to: statement)
        try bind(cursor.sourceTable, at: 5, to: statement)
        try bind(cursor.sourceSQLiteRowID, at: 6, to: statement)
        try bind(cursor.messageID, at: 7, to: statement)
        try bind(Int64(pageSize + 1), at: 8, to: statement)
        var messages = try collectMessageRows(statement)
        let hasMore = messages.count > pageSize
        if hasMore {
            if selectedDescending { messages.removeFirst() } else { messages.removeLast() }
        }
        return .init(items: messages, hasMore: hasMore)
    }

    private func collectMessageRows(_ statement: OpaquePointer?) throws -> [ArchiveViewerMessage] {
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
                let direction = text(statement, 7).flatMap(ArchiveV1MessageDirection.init(rawValue:)) ?? .unknown
                let senderAvatar = avatar(statement, idIndex: 9, pathIndex: 10, widthIndex: 11, heightIndex: 12)
                messageIndex = messages.count
                indexes[id] = messageIndex
                messages.append(.init(
                    id: id,
                    timestamp: sqlite3_column_int64(statement, 1),
                    normalizedType: normalizedType,
                    rawLocalType: rawType,
                    textContent: text(statement, 4),
                    hasSender: text(statement, 5) != nil,
                    direction: direction,
                    senderDisplayName: text(statement, 6),
                    avatar: direction == .outgoing ? accountAvatar : senderAvatar,
                    media: []
                ))
            }
            guard let assetID = text(statement, 13) else { continue }
            guard let mediaTypeValue = text(statement, 14), let mediaType = ArchiveV1MediaType(rawValue: mediaTypeValue),
                  let variantValue = text(statement, 15), let variant = ArchiveV1MediaVariant(rawValue: variantValue),
                  let statusValue = text(statement, 16), let status = ArchiveV1MediaStatus(rawValue: statusValue) else { throw ArchiveError.invalidArchive }
            messages[messageIndex].media.append(.init(
                id: assetID,
                mediaType: mediaType,
                variant: variant,
                status: status,
                rawRelativePath: text(statement, 17),
                decodedRelativePath: text(statement, 18),
                width: integer(statement, 19).map(Int.init),
                height: integer(statement, 20).map(Int.init),
                duration: sqlite3_column_type(statement, 21) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 21),
                rawSize: integer(statement, 22),
                decodedSize: integer(statement, 23)
            ))
        }
        return messages
    }

    /// Finds the zero-based ascending timeline position of a message inside
    /// its conversation, using the same ordering as `messagePage`. Returns
    /// nil when the id is not present (e.g. a stale search result).
    public func messageOffset(conversationID: String, messageID: String) throws -> Int? {
        let statement = try prepare("""
            WITH ordered AS (
                SELECT id, ROW_NUMBER() OVER (
                    ORDER BY timestamp ASC, source_sequence ASC, source_database ASC, source_table ASC, \(sourceRowIDColumn) ASC
                ) AS position
                FROM messages
                WHERE conversation_id = ?
            )
            SELECT position FROM ordered WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(conversationID, at: 1, to: statement)
        try bind(messageID, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0)) - 1
    }

    /// Returns a bounded chronological window centered on an existing message.
    /// The public contract intentionally exposes only message identities and
    /// directional availability; source table and row identifiers remain
    /// private to the archive database.
    public func messageWindow(
        conversationID: String,
        aroundMessageID: String,
        before: Int = 50,
        after: Int = 50
    ) throws -> ArchiveViewerMessageWindow {
        guard let cursor = try messageCursor(conversationID: conversationID, messageID: aroundMessageID) else {
            throw ArchiveError.invalidInput
        }
        let beforeCount = max(0, before)
        let afterCount = max(0, after)
        let older = try keysetMessagePage(conversationID: conversationID, cursor: cursor, relation: .before, limit: beforeCount)
        let anchoredAndNewer = try keysetMessagePage(conversationID: conversationID, cursor: cursor, relation: .atOrAfter, limit: afterCount + 1)
        return .init(
            items: older.items + anchoredAndNewer.items,
            hasOlder: older.hasMore,
            hasNewer: anchoredAndNewer.hasMore
        )
    }

    /// Groups a conversation's message timestamps by the user's local day.
    /// SQLite does the aggregation; no message body is selected.
    public func conversationDateBuckets(conversationID: String, calendar: Calendar = .current) throws -> [ArchiveViewerDateBucket] {
        let offset = calendar.timeZone.secondsFromGMT()
        let modifier = String(format: "%+03d:%02d", offset / 3_600, abs(offset / 60) % 60)
        let statement = try prepare("""
            SELECT strftime('%Y-%m-%d', timestamp, 'unixepoch', ?), COUNT(*)
            FROM messages
            WHERE conversation_id = ?
            GROUP BY 1
            ORDER BY 1 ASC
            """)
        defer { sqlite3_finalize(statement) }
        try bind(modifier, at: 1, to: statement)
        try bind(conversationID, at: 2, to: statement)
        var buckets = [ArchiveViewerDateBucket]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let day = text(statement, 0) else { continue }
            buckets.append(.init(day: day, messageCount: Int(sqlite3_column_int64(statement, 1))))
        }
        return buckets
    }

    /// Finds the first message on a local-calendar day without loading that
    /// day's text. The returned identifier can be passed to `messageWindow`.
    public func firstMessageID(
        conversationID: String,
        on day: String,
        calendar: Calendar = .current
    ) throws -> String? {
        let components = day.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let dayOfMonth = Int(components[2]),
              let start = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw ArchiveError.invalidInput
        }
        let statement = try prepare("""
            SELECT id
            FROM messages
            WHERE conversation_id = ? AND timestamp >= ? AND timestamp < ?
            ORDER BY timestamp ASC, source_sequence ASC, source_database ASC, source_table ASC, \(sourceRowIDColumn) ASC, id ASC
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        try bind(conversationID, at: 1, to: statement)
        try bind(Int64(start.timeIntervalSince1970), at: 2, to: statement)
        try bind(Int64(end.timeIntervalSince1970), at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    /// Searches `messages.text_content` across every conversation in the
    /// archive. It never searches media, sender identifiers, or source
    /// database values, and only text messages are matched.
    public func searchMessagePage(query: String, offset: Int = 0, limit: Int = 50) throws -> ArchiveViewerPage<ArchiveViewerMessageSearchResult> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .init(items: [], hasMore: false) }
        let pageSize = clamped(limit)
        let statement = try prepare("""
            SELECT m.id, m.conversation_id, c.display_name, c.conversation_type, m.timestamp, m.normalized_type, m.text_content
            FROM messages m
            JOIN conversations c ON c.id = m.conversation_id
            WHERE m.text_content LIKE ? ESCAPE '\\'
            ORDER BY m.timestamp DESC, m.source_sequence DESC, m.source_database DESC, m.source_table DESC, m.\(sourceRowIDColumn) DESC
            LIMIT ? OFFSET ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind("%\(escapedLikePattern(trimmed))%", at: 1, to: statement)
        try bind(Int64(pageSize + 1), at: 2, to: statement)
        try bind(Int64(max(offset, 0)), at: 3, to: statement)
        var results = [ArchiveViewerMessageSearchResult]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let conversationID = text(statement, 1),
                  let typeValue = text(statement, 5), let normalizedType = ArchiveV1NormalizedType(rawValue: typeValue) else { continue }
            let conversationType = text(statement, 3).flatMap(ArchiveV1ConversationType.init(rawValue:)) ?? .unknown
            let fallbackTitle = conversationType == .group ? "群聊" : "会话"
            let title = text(statement, 2).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
            let content = ArchiveMessagePresentationFormatter.displayText(for: text(statement, 6)) ?? ""
            results.append(.init(
                id: id,
                conversationID: conversationID,
                conversationTitle: title,
                timestamp: sqlite3_column_int64(statement, 4),
                normalizedType: normalizedType,
                snippet: ArchiveTextSnippetBuilder.snippet(for: content, query: trimmed)
            ))
        }
        let hasMore = results.count > pageSize
        if hasMore { results.removeLast() }
        return .init(items: results, hasMore: hasMore)
    }

    /// Aggregates message and media counts by normalized type and archive
    /// status only. It never reads message text or media bytes.
    public func coverageSummary() throws -> ArchiveViewerCoverageSummary {
        .init(
            totalMessages: try scalarInt("SELECT COUNT(*) FROM messages"),
            totalConversations: try scalarInt("SELECT COUNT(*) FROM conversations"),
            byType: try typeCoverage(),
            mediaByStatus: try mediaCoverage()
        )
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func messageCount(conversationID: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM messages WHERE conversation_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(conversationID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func typeCoverage() throws -> [ArchiveViewerTypeCoverage] {
        let statement = try prepare("SELECT normalized_type, COUNT(*) FROM messages GROUP BY normalized_type")
        defer { sqlite3_finalize(statement) }
        var results = [ArchiveViewerTypeCoverage]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = text(statement, 0), let type = ArchiveV1NormalizedType(rawValue: value) else { continue }
            results.append(.init(normalizedType: type, messageCount: Int(sqlite3_column_int64(statement, 1))))
        }
        return results.sorted { $0.messageCount > $1.messageCount }
    }

    private func mediaCoverage() throws -> [ArchiveViewerMediaCoverage] {
        let statement = try prepare("SELECT media_type, status, COUNT(*) FROM media_assets GROUP BY media_type, status")
        defer { sqlite3_finalize(statement) }
        var results = [ArchiveViewerMediaCoverage]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let typeValue = text(statement, 0), let mediaType = ArchiveV1MediaType(rawValue: typeValue),
                  let statusValue = text(statement, 1), let status = ArchiveV1MediaStatus(rawValue: statusValue) else { continue }
            results.append(.init(mediaType: mediaType, status: status, count: Int(sqlite3_column_int64(statement, 2))))
        }
        return results.sorted { $0.count > $1.count }
    }


    public func mediaURL(for media: ArchiveViewerMedia, preferDecoded: Bool) -> URL? {
        let preferred = preferDecoded ? [media.decodedRelativePath, media.rawRelativePath] : [media.rawRelativePath, media.decodedRelativePath]
        return preferred.compactMap { $0 }.compactMap(validMediaURL(relativePath:)).first
    }

    public func avatarURL(for avatar: ArchiveViewerAvatar) -> URL? {
        validMediaURL(relativePath: avatar.relativePath)
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

    private func avatar(ownerType: ArchiveV1AvatarOwnerType, ownerID: String) throws -> ArchiveViewerAvatar? {
        let statement = try prepare("""
            SELECT a.id, a.archive_path, a.width, a.height
            FROM avatar_owner_links l
            JOIN avatar_assets a ON a.id = l.avatar_asset_id
            WHERE l.owner_type = ? AND l.owner_id = ? AND a.archive_path IS NOT NULL
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        try bind(ownerType.rawValue, at: 1, to: statement)
        try bind(ownerID, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return avatar(statement, idIndex: 0, pathIndex: 1, widthIndex: 2, heightIndex: 3)
    }

    private func avatar(
        _ statement: OpaquePointer?,
        idIndex: Int32,
        pathIndex: Int32,
        widthIndex: Int32,
        heightIndex: Int32
    ) -> ArchiveViewerAvatar? {
        guard let id = text(statement, idIndex), let path = text(statement, pathIndex) else { return nil }
        return .init(id: id, relativePath: path, width: integer(statement, widthIndex).map(Int.init), height: integer(statement, heightIndex).map(Int.init))
    }

    private func conversationPreview(normalizedType: String?, textContent: String?) -> String? {
        guard let normalizedType = normalizedType.flatMap(ArchiveV1NormalizedType.init(rawValue:)) else { return nil }
        switch normalizedType {
        case .text:
            let compact = (ArchiveMessagePresentationFormatter.displayText(for: textContent) ?? "")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !compact.isEmpty else { return "[文本]" }
            return compact.count > 50 ? String(compact.prefix(50)) + "…" : compact
        case .image: return "[图片]"
        case .video: return "[视频]"
        case .voice: return "[语音]"
        case .unknown: return "[其他消息]"
        }
    }

    private func escapedLikePattern(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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
        if archiveSchemaVersion >= 4 {
            guard Set(["avatar_assets", "avatar_owner_links"]).isSubset(of: tables) else { throw ArchiveError.invalidArchive }
        }
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
