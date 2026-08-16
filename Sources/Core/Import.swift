import Foundation

/// A provider is only responsible for reading an explicitly user-selected source
/// and producing normalized messages. It never owns archive persistence.
public protocol ChatImportProvider: Sendable {
    var source: ImportSource { get }
    func preview(at url: URL) async throws -> ImportPreview
    func messages(at url: URL) async throws -> [Message]
}

public struct ImportPreview: Equatable, Sendable {
    public let contacts: Int
    public let conversations: Int
    public let messages: Int
    public let images: Int
    public let videos: Int
    public let files: Int

    public init(contacts: Int, conversations: Int, messages: Int, images: Int, videos: Int, files: Int) {
        self.contacts = contacts
        self.conversations = conversations
        self.messages = messages
        self.images = images
        self.videos = videos
        self.files = files
    }
}

public struct JSONImportProvider: ChatImportProvider {
    public let source: ImportSource = .jsonFile

    public init() {}

    public func preview(at url: URL) async throws -> ImportPreview {
        let records = try await messages(at: url)
        return preview(messages: records)
    }

    public func messages(at url: URL) async throws -> [Message] {
        do {
            return try JSONDecoder.archiveDecoder.decode([Message].self, from: Data(contentsOf: url))
        } catch {
            throw ArchiveError.invalidArchive
        }
    }
}

public struct NDJSONImportProvider: ChatImportProvider {
    public let source: ImportSource = .ndjsonFile

    public init() {}

    public func preview(at url: URL) async throws -> ImportPreview {
        let records = try await messages(at: url)
        return preview(messages: records)
    }

    public func messages(at url: URL) async throws -> [Message] {
        do {
            return try NDJSONReader().read(from: url)
        } catch {
            throw ArchiveError.invalidArchive
        }
    }
}

/// These provider contracts intentionally exist before their parsers. They make
/// format support additive and prevent Archive/SQLite from depending on one
/// source layout. They fail closed until an adapter can preserve source data.
public struct CSVImportProvider: ChatImportProvider {
    public let source: ImportSource = .csvFile
    public init() {}
    public func preview(at url: URL) async throws -> ImportPreview { throw ArchiveError.unsupportedImportFormat }
    public func messages(at url: URL) async throws -> [Message] { throw ArchiveError.unsupportedImportFormat }
}

public struct TXTImportProvider: ChatImportProvider {
    public let source: ImportSource = .textFile
    public init() {}
    public func preview(at url: URL) async throws -> ImportPreview { throw ArchiveError.unsupportedImportFormat }
    public func messages(at url: URL) async throws -> [Message] { throw ArchiveError.unsupportedImportFormat }
}

public struct HTMLImportProvider: ChatImportProvider {
    public let source: ImportSource = .htmlFile
    public init() {}
    public func preview(at url: URL) async throws -> ImportPreview { throw ArchiveError.unsupportedImportFormat }
    public func messages(at url: URL) async throws -> [Message] { throw ArchiveError.unsupportedImportFormat }
}

public struct WeChatDatabaseImportProvider: ChatImportProvider {
    public let source: ImportSource = .weChatDatabase
    public init() {}
    public func preview(at url: URL) async throws -> ImportPreview { throw ArchiveError.unsupportedImportFormat }
    public func messages(at url: URL) async throws -> [Message] { throw ArchiveError.unsupportedImportFormat }
}

/// The coordinator records completed batches atomically in the query index.
/// A caller may cancel between batches without corrupting completed batches.
public final class ImportCoordinator: @unchecked Sendable {
    private let index: SQLiteArchiveIndex

    public init(index: SQLiteArchiveIndex) {
        self.index = index
    }

    public func importMessages(
        _ messages: [Message],
        source: ImportSource,
        sourceHash: String,
        batchSize: Int = 1_000
    ) throws -> ImportSession {
        guard !sourceHash.isEmpty, batchSize > 0 else { throw ArchiveError.invalidInput }
        let startedAt = Date()
        var inserted = 0
        for batchStart in stride(from: 0, to: messages.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, messages.count)
            inserted += try index.upsert(messages: Array(messages[batchStart..<batchEnd]))
        }
        let session = ImportSession(
            source: source,
            sourceHash: sourceHash,
            startedAt: startedAt,
            finishedAt: Date(),
            status: .completed,
            messagesRead: messages.count,
            messagesInserted: inserted,
            messagesSkipped: messages.count - inserted
        )
        try index.record(session: session)
        return session
    }
}

private extension ChatImportProvider {
    func preview(messages: [Message]) -> ImportPreview {
        ImportPreview(
            contacts: Set(messages.map { $0.sender.id }).count,
            conversations: Set(messages.map(\.conversationID)).count,
            messages: messages.count,
            images: messages.filter { $0.type == .image }.count,
            videos: messages.filter { $0.type == .video }.count,
            files: messages.filter { $0.type == .file }.count
        )
    }
}
