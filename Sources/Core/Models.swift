import Foundation

public struct Account: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct Contact: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var displayName: String
    public var historicalNames: [String]
    public var weChatID: String?

    public init(id: String, displayName: String, historicalNames: [String] = [], weChatID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.historicalNames = historicalNames
        self.weChatID = weChatID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case historicalNames = "historical_names"
        case weChatID = "wechat_id"
    }
}

public struct Conversation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var displayName: String
    public var isGroup: Bool
    public var participantIDs: [String]

    public init(id: String, displayName: String, isGroup: Bool, participantIDs: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.isGroup = isGroup
        self.participantIDs = participantIDs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case isGroup = "is_group"
        case participantIDs = "participant_ids"
    }
}

public struct Participant: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let conversationID: String
    public let contactID: String
    public let role: String?

    public init(id: String, conversationID: String, contactID: String, role: String? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.contactID = contactID
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case id, role
        case conversationID = "conversation_id"
        case contactID = "contact_id"
    }
}

public enum MessageType: String, Codable, CaseIterable, Sendable {
    case text, image, video, voice, file, sticker, link, location, contact, system, reply, unknown
}

public struct MessageSender: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

public enum MediaCategory: String, Codable, CaseIterable, Sendable {
    case images, videos, voice, files, stickers, thumbnails
}

public struct MediaAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let relativePath: String
    public let sha256: String
    public let mimeType: String?
    public let size: Int64
    public let category: MediaCategory

    public init(
        id: String,
        relativePath: String,
        sha256: String,
        mimeType: String? = nil,
        size: Int64,
        category: MediaCategory
    ) {
        self.id = id
        self.relativePath = relativePath
        self.sha256 = sha256
        self.mimeType = mimeType
        self.size = size
        self.category = category
    }

    enum CodingKeys: String, CodingKey {
        case id, sha256, size, category
        case relativePath = "path"
        case mimeType = "mime"
    }
}

/// The normalized, portable representation of one source message.
/// `raw` is deliberately retained for unsupported source types so a future adapter
/// can reinterpret it without needing the original database again.
public struct Message: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceMessageID: String?
    public let conversationID: String
    public let timestamp: Date
    public let sourceTimeZone: String
    public let sender: MessageSender
    public let type: MessageType
    public let content: String?
    public let replyTo: String?
    public let media: [MediaAsset]
    public let raw: [String: String]?

    public init(
        id: String,
        sourceMessageID: String?,
        conversationID: String,
        timestamp: Date,
        sourceTimeZone: String,
        sender: MessageSender,
        type: MessageType,
        content: String?,
        replyTo: String?,
        media: [MediaAsset],
        raw: [String: String]?
    ) {
        self.id = id
        self.sourceMessageID = sourceMessageID
        self.conversationID = conversationID
        self.timestamp = timestamp
        self.sourceTimeZone = sourceTimeZone
        self.sender = sender
        self.type = type
        self.content = content
        self.replyTo = replyTo
        self.media = media
        self.raw = raw
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, sender, type, content, media, raw
        case sourceMessageID = "source_message_id"
        case conversationID = "conversation_id"
        case sourceTimeZone = "source_timezone"
        case replyTo = "reply_to"
    }
}

public enum ImportSource: String, Codable, CaseIterable, Sendable {
    case weChatDatabase = "wechat_database"
    case jsonFile = "json"
    case ndjsonFile = "ndjson"
    case csvFile = "csv"
    case textFile = "txt"
    case htmlFile = "html"
}

public enum ImportStatus: String, Codable, Sendable {
    case running, completed, failed, cancelled
}

public struct ImportSession: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: ImportSource
    public let sourceHash: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: ImportStatus
    public let messagesRead: Int
    public let messagesInserted: Int
    public let messagesSkipped: Int
    public let errors: Int

    public init(
        id: String = UUID().uuidString,
        source: ImportSource,
        sourceHash: String,
        startedAt: Date,
        finishedAt: Date?,
        status: ImportStatus,
        messagesRead: Int,
        messagesInserted: Int,
        messagesSkipped: Int,
        errors: Int = 0
    ) {
        self.id = id
        self.source = source
        self.sourceHash = sourceHash
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.messagesRead = messagesRead
        self.messagesInserted = messagesInserted
        self.messagesSkipped = messagesSkipped
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey {
        case id, source, status, errors
        case sourceHash = "source_hash"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case messagesRead = "messages_read"
        case messagesInserted = "messages_inserted"
        case messagesSkipped = "messages_skipped"
    }
}

public struct ArchiveManifest: Codable, Equatable, Sendable {
    public static let formatName = "WeChatArchive"
    public static let currentVersion = 1

    public let format: String
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int
    public let conversationCount: Int
    public let mediaCount: Int

    public init(
        format: String = ArchiveManifest.formatName,
        version: Int = ArchiveManifest.currentVersion,
        createdAt: Date,
        updatedAt: Date,
        messageCount: Int,
        conversationCount: Int,
        mediaCount: Int
    ) {
        self.format = format
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.conversationCount = conversationCount
        self.mediaCount = mediaCount
    }

    enum CodingKeys: String, CodingKey {
        case format, version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messageCount = "message_count"
        case conversationCount = "conversation_count"
        case mediaCount = "media_count"
    }
}

public struct ArchiveMetadata: Codable, Equatable, Sendable {
    public let archiveVersion: Int
    public let migratedAt: Date?

    public init(archiveVersion: Int, migratedAt: Date? = nil) {
        self.archiveVersion = archiveVersion
        self.migratedAt = migratedAt
    }
}

public struct SearchQuery: Sendable {
    public var query: String
    public var conversationID: String?
    public var senderID: String?
    public var types: Set<MessageType>
    public var from: Date?
    public var to: Date?
    public var limit: Int

    public init(
        query: String,
        conversationID: String? = nil,
        senderID: String? = nil,
        types: Set<MessageType> = [],
        from: Date? = nil,
        to: Date? = nil,
        limit: Int = 100
    ) {
        self.query = query
        self.conversationID = conversationID
        self.senderID = senderID
        self.types = types
        self.from = from
        self.to = to
        self.limit = min(max(limit, 1), 500)
    }
}

public enum ArchiveError: LocalizedError, Equatable {
    case invalidInput
    case keyUnavailable
    case keyInvalid
    case databaseDecryptionFailed
    case unsupportedDatabaseVersion
    case databaseInUse
    case unsupportedImportFormat
    case invalidArchive
    case ioFailure
    case databaseFailure

    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "Invalid input"
        case .keyUnavailable: return "Key unavailable"
        case .keyInvalid: return "Key invalid"
        case .databaseDecryptionFailed: return "Database decryption failed"
        case .unsupportedDatabaseVersion: return "Unsupported WeChat database version"
        case .databaseInUse: return "Database is in use; close WeChat and try again"
        case .unsupportedImportFormat: return "This import format needs an adapter"
        case .invalidArchive: return "Archive format is invalid"
        case .ioFailure: return "Local file operation failed"
        case .databaseFailure: return "Archive database operation failed"
        }
    }
}
