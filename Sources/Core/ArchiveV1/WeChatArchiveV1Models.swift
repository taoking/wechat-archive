import Foundation

public enum ArchivedSQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var sqliteType: String {
        switch self {
        case .null: "null"
        case .integer: "integer"
        case .real: "real"
        case .text: "text"
        case .blob: "blob"
        }
    }
}

public enum ArchiveV1NormalizedType: String, Codable, Equatable, Sendable {
    case text
    case image
    case unknown
}

public enum ArchiveV1MediaVariant: String, Codable, CaseIterable, Equatable, Sendable {
    case main
    case hd
    case thumbnail
}

public enum ArchiveV1MediaStatus: String, Codable, Equatable, Sendable {
    case missing
    case rawArchived
    case decoded
    case decodeUnsupported
    case imageKeyUnavailable
    case imageKeyRejected
    case invalidDATLayout
    case invalidPadding
    case decodeFailed
    case decodedUnknownFormat
    case unsupportedVersion
}

public enum ArchiveV1ImportStatus: String, Codable, Equatable, Sendable {
    case running
    case completed
    case cancelled
    case failed
}

public struct ArchiveV1ImportOptions: Equatable, Sendable {
    public let limit: Int?
    public let batchSize: Int

    public init(limit: Int? = 100, batchSize: Int = 500) {
        self.limit = limit.map { max(1, $0) }
        self.batchSize = min(max(batchSize, 1), 1_000)
    }

    public static let developmentDefault = ArchiveV1ImportOptions()
    public static let all = ArchiveV1ImportOptions(limit: nil)
}

public struct ArchiveV1ImportAnalysis: Equatable, Sendable {
    public let messageDatabaseCount: Int
    public let messageTableCount: Int
    public let estimatedMessageCount: Int

    public init(messageDatabaseCount: Int, messageTableCount: Int, estimatedMessageCount: Int) {
        self.messageDatabaseCount = messageDatabaseCount
        self.messageTableCount = messageTableCount
        self.estimatedMessageCount = estimatedMessageCount
    }
}

public struct ArchiveV1ImportSummary: Equatable, Sendable {
    public let importRunID: String
    public let status: ArchiveV1ImportStatus
    public let messagesRead: Int
    public let messagesImported: Int
    public let messagesSkipped: Int
    public let textCount: Int
    public let imageCount: Int
    public let unknownCount: Int
    public let conversationCount: Int
    public let rawDATArchived: Int
    public let decodedImages: Int
    public let missingLocalMedia: Int
    public let decodeFailures: Int

    public init(
        importRunID: String,
        status: ArchiveV1ImportStatus,
        messagesRead: Int,
        messagesImported: Int,
        messagesSkipped: Int,
        textCount: Int,
        imageCount: Int,
        unknownCount: Int,
        conversationCount: Int,
        rawDATArchived: Int,
        decodedImages: Int,
        missingLocalMedia: Int,
        decodeFailures: Int
    ) {
        self.importRunID = importRunID
        self.status = status
        self.messagesRead = messagesRead
        self.messagesImported = messagesImported
        self.messagesSkipped = messagesSkipped
        self.textCount = textCount
        self.imageCount = imageCount
        self.unknownCount = unknownCount
        self.conversationCount = conversationCount
        self.rawDATArchived = rawDATArchived
        self.decodedImages = decodedImages
        self.missingLocalMedia = missingLocalMedia
        self.decodeFailures = decodeFailures
    }
}

public struct ArchiveV1ReconstructedMessage: Equatable, Sendable {
    public let normalizedType: ArchiveV1NormalizedType
    public let textContent: String?
    public let timestamp: Int64
    public let sourceSequence: Int64
    public let mediaStatuses: [ArchiveV1MediaStatus]

    public init(normalizedType: ArchiveV1NormalizedType, textContent: String?, timestamp: Int64, sourceSequence: Int64, mediaStatuses: [ArchiveV1MediaStatus]) {
        self.normalizedType = normalizedType
        self.textContent = textContent
        self.timestamp = timestamp
        self.sourceSequence = sourceSequence
        self.mediaStatuses = mediaStatuses
    }
}

public struct ArchiveV1ValidationReport: Equatable, Sendable {
    public let sqliteIntegrityPassed: Bool
    public let foreignKeysPassed: Bool
    public let manifestPassed: Bool
    public let mediaHashesPassed: Bool
    public let messageCount: Int
    public let mediaAssetCount: Int

    public init(sqliteIntegrityPassed: Bool, foreignKeysPassed: Bool, manifestPassed: Bool, mediaHashesPassed: Bool, messageCount: Int, mediaAssetCount: Int) {
        self.sqliteIntegrityPassed = sqliteIntegrityPassed
        self.foreignKeysPassed = foreignKeysPassed
        self.manifestPassed = manifestPassed
        self.mediaHashesPassed = mediaHashesPassed
        self.messageCount = messageCount
        self.mediaAssetCount = mediaAssetCount
    }

    public var passed: Bool {
        sqliteIntegrityPassed && foreignKeysPassed && manifestPassed && mediaHashesPassed
    }
}
