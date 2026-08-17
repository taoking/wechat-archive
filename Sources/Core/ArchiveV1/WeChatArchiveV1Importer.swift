import Foundation

struct ArchiveV1Manifest: Codable {
    let format: String
    let version: Int
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    let conversationCount: Int
    let mediaAssetCount: Int
    let textCount: Int
    let imageCount: Int
    let videoCount: Int
    let voiceCount: Int
    let unknownCount: Int
    let imageMediaCount: Int
    let videoMediaCount: Int
    let voiceMediaCount: Int
}

private struct ArchiveV1ImportReport: Codable {
    let archiveSchemaVersion: Int
    let status: ArchiveV1ImportStatus
    let messageDatabaseCount: Int
    let messagesRead: Int
    let messagesImported: Int
    let messagesSkipped: Int
    let textCount: Int
    let imageCount: Int
    let videoCount: Int
    let voiceCount: Int
    let unknownCount: Int
    let imageRawFound: Int
    let imageDecoded: Int
    let imageMissing: Int
    let videoRawFound: Int
    let videoThumbnailsFound: Int
    let voiceRawFound: Int
    let voiceDecoded: Int
    let errorsByCategory: [String: Int]
}

public struct ArchiveV1ImportProgress: Equatable, Sendable {
    public let messagesRead: Int
    public let messagesImported: Int
    public let imagesResolved: Int
    public let imagesDecoded: Int
    public let imagesRawOnly: Int
    public let imagesMissing: Int
    public let textCount: Int
    public let imageCount: Int
    public let videoCount: Int
    public let voiceCount: Int
    public let unknownCount: Int
    public let mediaBytesCopied: Int64

    init(messagesRead: Int, messagesImported: Int, imagesResolved: Int, imagesDecoded: Int, imagesRawOnly: Int, imagesMissing: Int, textCount: Int, imageCount: Int, videoCount: Int, voiceCount: Int, unknownCount: Int, mediaBytesCopied: Int64) {
        self.messagesRead = messagesRead
        self.messagesImported = messagesImported
        self.imagesResolved = imagesResolved
        self.imagesDecoded = imagesDecoded
        self.imagesRawOnly = imagesRawOnly
        self.imagesMissing = imagesMissing
        self.textCount = textCount
        self.imageCount = imageCount
        self.videoCount = videoCount
        self.voiceCount = voiceCount
        self.unknownCount = unknownCount
        self.mediaBytesCopied = mediaBytesCopied
    }
}

/// Imports all message rows from a plaintext export. It streams source rows,
/// saves every SQLite value, and treats media problems as media diagnostics
/// rather than permission to discard a source message.
public struct WeChatArchiveV1Importer: Sendable {
    private let sourceReader: WeChatArchiveV1SourceReader
    private let imageKeyProvider: any WeChatImageKeyProvider

    public init(
        sourceReader: WeChatArchiveV1SourceReader = .init(),
        imageKeyProvider: any WeChatImageKeyProvider
    ) {
        self.sourceReader = sourceReader
        self.imageKeyProvider = imageKeyProvider
    }

    public func analyze(plainSQLiteRoot: URL) throws -> ArchiveV1ImportAnalysis {
        try sourceReader.analyze(exportRoot: plainSQLiteRoot)
    }

    public func importArchive(
        plainSQLiteRoot: URL,
        accountRoot: URL,
        destinationRoot: URL,
        options: ArchiveV1ImportOptions = .developmentDefault,
        shouldCancel: @Sendable () -> Bool = { false },
        progress: (@Sendable (ArchiveV1ImportProgress) -> Void)? = nil
    ) throws -> ArchiveV1ImportSummary {
        let destination = try prepareArchiveRoot(destinationRoot)
        let mediaStore = try WeChatArchiveV1MediaStore(root: destination)
        let database = try WeChatArchiveV1Database(url: destination.appending(path: "archive.sqlite"))
        defer { database.close() }

        let runID = try database.createImportRun()
        var state = ImportState(runID: runID)
        var sourceDatabaseCount = 0
        do {
            sourceDatabaseCount = try sourceReader.stream(exportRoot: plainSQLiteRoot, limit: options.limit) { message in
                guard !shouldCancel() else {
                    state.status = .cancelled
                    return false
                }
                try process(
                    message: message,
                    database: database,
                    mediaStore: mediaStore,
                    plainSQLiteRoot: plainSQLiteRoot,
                    accountRoot: accountRoot,
                    state: &state
                )
                progress?(.init(
                    messagesRead: state.messagesRead,
                    messagesImported: state.messagesImported,
                    imagesResolved: state.imageVariantsResolved,
                    imagesDecoded: state.decodedImages,
                    imagesRawOnly: state.rawOnlyImages,
                    imagesMissing: state.missingLocalMedia,
                    textCount: state.textCount,
                    imageCount: state.imageCount,
                    videoCount: state.videoCount,
                    voiceCount: state.voiceCount,
                    unknownCount: state.unknownCount,
                    mediaBytesCopied: state.archivedMediaBytes
                ))
                return true
            }
            if state.status == .running { state.status = .completed }
            let summary = try makeSummary(state: state, database: database)
            try database.finishImportRun(runID, status: summary.status, sourceDatabaseCount: sourceDatabaseCount, summary: summary)
            try writeMetadata(destination: destination, summary: summary, sourceDatabaseCount: sourceDatabaseCount, database: database)
            return summary
        } catch {
            state.status = .failed
            let summary = try? makeSummary(state: state, database: database)
            if let summary {
                try? database.finishImportRun(runID, status: .failed, sourceDatabaseCount: sourceDatabaseCount, summary: summary)
                try? writeMetadata(destination: destination, summary: summary, sourceDatabaseCount: sourceDatabaseCount, database: database)
            }
            throw error
        }
    }

    private func process(
        message: ArchiveV1SourceMessage,
        database: WeChatArchiveV1Database,
        mediaStore: WeChatArchiveV1MediaStore,
        plainSQLiteRoot: URL,
        accountRoot: URL,
        state: inout ImportState
    ) throws {
        let rawType = message.values.integer(named: ["local_type", "msg_type", "message_type", "type"])
        let normalizedType: ArchiveV1NormalizedType
        let textContent: String?
        if let content = WeChatTextMessageAdapter().textContent(from: message.values) {
            normalizedType = .text
            textContent = content
        } else if rawTypeLow32(rawType) == 3 {
            normalizedType = .image
            textContent = nil
        // 34 and 43 are enabled only after the bounded local validation in
        // Phase 3C confirmed their exact resource/media chains.
        } else if rawTypeLow32(rawType) == 43 {
            normalizedType = .video
            textContent = nil
        } else if rawTypeLow32(rawType) == 34 {
            normalizedType = .voice
            textContent = nil
        } else {
            normalizedType = .unknown
            textContent = nil
        }

        let timestamp = message.values.integer(named: ["create_time", "createTime", "timestamp", "time"]) ?? 0
        let conversationID = try database.upsertConversation(sourceIdentity: message.sourceTable, createdAt: timestamp == 0 ? nil : timestamp)
        let inserted = try database.insertMessage(
            conversationID: conversationID,
            sourceDatabase: message.sourceDatabase,
            sourceTable: message.sourceTable,
            sourceSQLiteRowID: message.sourceSQLiteRowID,
            sourceLocalID: message.values.integer(named: ["local_id", "message_id", "msg_id"]),
            sourceServerID: message.values.integer(named: ["server_id", "svr_id", "msg_svr_id"]),
            timestamp: timestamp,
            senderSourceID: message.values.text(named: ["real_sender_id", "sender_id", "from_user"]),
            receiverSourceID: message.values.text(named: ["receiver_id", "to_user"]),
            rawLocalType: rawType,
            normalizedType: normalizedType,
            textContent: textContent,
            replySourceID: message.values.text(named: ["reply_source_id", "reply_msg_id"]),
            sourceSequence: message.sourceSequence,
            sourceValues: message.values
        )
        state.messagesRead += 1
        guard inserted.inserted else {
            state.messagesSkipped += 1
            return
        }
        state.messagesImported += 1
        switch normalizedType {
        case .text: state.textCount += 1
        case .image: state.imageCount += 1
        case .video: state.videoCount += 1
        case .voice: state.voiceCount += 1
        case .unknown: state.unknownCount += 1
        }

        let inputs: [ArchiveV1MediaInput]
        switch normalizedType {
        case .image:
            do {
                inputs = try WeChatImageMessageAdapter(keyProvider: imageKeyProvider).variants(message: message, exportRoot: plainSQLiteRoot, accountRoot: accountRoot)
            } catch {
                inputs = ArchiveV1MediaVariant.imageVariants.map { .init(variant: $0, status: .missing, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil) }
            }
        case .video:
            do {
                inputs = try WeChatVideoMessageAdapter().variants(message: message, exportRoot: plainSQLiteRoot, accountRoot: accountRoot)
            } catch {
                inputs = ArchiveV1MediaVariant.videoVariants.map { .init(mediaType: .video, variant: $0, status: .missing, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil) }
            }
        case .voice:
            do {
                inputs = try WeChatVoiceMessageAdapter().variants(message: message, exportRoot: plainSQLiteRoot)
            } catch {
                inputs = [.init(mediaType: .voice, variant: .raw, status: .missing, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil)]
            }
        case .text, .unknown:
            inputs = []
        }
        for input in inputs {
            try archiveMedia(input, messageID: inserted.id, mediaStore: mediaStore, database: database, state: &state)
        }
    }

    private func archiveMedia(
        _ input: ArchiveV1MediaInput,
        messageID: String,
        mediaStore: WeChatArchiveV1MediaStore,
        database: WeChatArchiveV1Database,
        state: inout ImportState
    ) throws {
        let assetID = UUID().uuidString.lowercased()
        let raw: ArchiveV1StoredMedia?
        if let data = input.rawData {
            raw = try mediaStore.storeRawData(data, mediaType: input.mediaType, variant: input.variant, sourceFormat: input.sourceFormat, assetID: assetID)
        } else if let fileURL = input.rawFileURL {
            raw = try mediaStore.storeRawFile(fileURL, mediaType: input.mediaType, variant: input.variant, sourceFormat: input.sourceFormat, assetID: assetID)
        } else {
            raw = nil
        }
        let decoded = try input.decodedData.map { try mediaStore.storeDecodedData($0, mediaType: input.mediaType, format: input.decodedFormat, assetID: assetID) }
        _ = try database.insertMediaAsset(
            messageID: messageID,
            assetID: assetID,
            mediaType: input.mediaType,
            variant: input.variant,
            status: input.status,
            sourceFormat: input.sourceFormat,
            decodedFormat: input.decodedFormat,
            rawArchivePath: raw?.relativePath,
            decodedArchivePath: decoded?.relativePath,
            rawSize: raw?.size,
            decodedSize: decoded?.size,
            width: input.width,
            height: input.height,
            duration: input.duration,
            rawSHA256: raw?.sha256,
            decodedSHA256: decoded?.sha256,
            sourceFileBase: input.sourceFileBase
        )
        state.archivedMediaBytes += (raw?.size ?? 0) + (decoded?.size ?? 0)
        if input.status == .missing { state.missingLocalMedia += 1 }
        switch input.mediaType {
        case .image:
            if raw != nil { state.rawDATArchived += 1; state.imageVariantsResolved += 1 }
            if input.status == .decoded { state.decodedImages += 1 }
            if raw != nil && input.status != .decoded && input.status != .missing { state.rawOnlyImages += 1; state.decodeFailures += 1 }
        case .video:
            if raw != nil && input.variant == .thumbnail { state.videoThumbnailsArchived += 1 }
            if raw != nil && input.variant != .thumbnail { state.rawVideoArchived += 1 }
        case .voice:
            if raw != nil { state.rawVoiceArchived += 1 }
            if decoded != nil { state.decodedVoiceArchived += 1 }
        }
    }

    private func makeSummary(state: ImportState, database: WeChatArchiveV1Database) throws -> ArchiveV1ImportSummary {
        ArchiveV1ImportSummary(
            importRunID: state.runID,
            status: state.status == .running ? .completed : state.status,
            messagesRead: state.messagesRead,
            messagesImported: state.messagesImported,
            messagesSkipped: state.messagesSkipped,
            textCount: state.textCount,
            imageCount: state.imageCount,
            videoCount: state.videoCount,
            voiceCount: state.voiceCount,
            unknownCount: state.unknownCount,
            conversationCount: try database.conversationCount(),
            rawDATArchived: state.rawDATArchived,
            decodedImages: state.decodedImages,
            rawVideoArchived: state.rawVideoArchived,
            videoThumbnailsArchived: state.videoThumbnailsArchived,
            rawVoiceArchived: state.rawVoiceArchived,
            decodedVoiceArchived: state.decodedVoiceArchived,
            archivedMediaBytes: state.archivedMediaBytes,
            missingLocalMedia: state.missingLocalMedia,
            decodeFailures: state.decodeFailures
        )
    }

    private func writeMetadata(destination: URL, summary: ArchiveV1ImportSummary, sourceDatabaseCount: Int, database: WeChatArchiveV1Database) throws {
        let manifest = ArchiveV1Manifest(
            format: "WeChatArchive",
            version: WeChatArchiveV1Database.schemaVersion,
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: try database.messageCount(),
            conversationCount: try database.conversationCount(),
            mediaAssetCount: try database.mediaAssetCount(),
            textCount: summary.textCount,
            imageCount: summary.imageCount,
            videoCount: summary.videoCount,
            voiceCount: summary.voiceCount,
            unknownCount: summary.unknownCount,
            imageMediaCount: summary.rawDATArchived,
            videoMediaCount: summary.rawVideoArchived + summary.videoThumbnailsArchived,
            voiceMediaCount: summary.rawVoiceArchived + summary.decodedVoiceArchived
        )
        let errors = summary.decodeFailures == 0 ? [:] : ["mediaDecode": summary.decodeFailures]
        let report = ArchiveV1ImportReport(
            archiveSchemaVersion: WeChatArchiveV1Database.schemaVersion,
            status: summary.status,
            messageDatabaseCount: sourceDatabaseCount,
            messagesRead: summary.messagesRead,
            messagesImported: summary.messagesImported,
            messagesSkipped: summary.messagesSkipped,
            textCount: summary.textCount,
            imageCount: summary.imageCount,
            videoCount: summary.videoCount,
            voiceCount: summary.voiceCount,
            unknownCount: summary.unknownCount,
            imageRawFound: summary.rawDATArchived,
            imageDecoded: summary.decodedImages,
            imageMissing: summary.missingLocalMedia,
            videoRawFound: summary.rawVideoArchived,
            videoThumbnailsFound: summary.videoThumbnailsArchived,
            voiceRawFound: summary.rawVoiceArchived,
            voiceDecoded: summary.decodedVoiceArchived,
            errorsByCategory: errors
        )
        try writePrivateJSON(manifest, to: destination.appending(path: "archive-manifest.json"))
        let metadata = destination.appending(path: "metadata")
        try createProtectedDirectory(metadata, below: destination)
        try writePrivateJSON(report, to: metadata.appending(path: "import-report.json"))
    }

    private func prepareArchiveRoot(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path()) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
            guard try manager.contentsOfDirectory(atPath: root.path()).isEmpty else { throw ArchiveError.invalidArchive }
        } else {
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path())
        return root.resolvingSymlinksInPath().standardizedFileURL
    }
}

private struct ImportState {
    let runID: String
    var status: ArchiveV1ImportStatus = .running
    var messagesRead = 0
    var messagesImported = 0
    var messagesSkipped = 0
    var textCount = 0
    var imageCount = 0
    var videoCount = 0
    var voiceCount = 0
    var unknownCount = 0
    var rawDATArchived = 0
    var decodedImages = 0
    var rawVideoArchived = 0
    var videoThumbnailsArchived = 0
    var rawVoiceArchived = 0
    var decodedVoiceArchived = 0
    var archivedMediaBytes: Int64 = 0
    var missingLocalMedia = 0
    var decodeFailures = 0
    var imageVariantsResolved = 0
    var rawOnlyImages = 0
}

private extension Dictionary where Key == String, Value == ArchivedSQLiteValue {
    func value(named names: [String]) -> ArchivedSQLiteValue? {
        for name in names {
            if let match = first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) { return match.value }
        }
        return nil
    }

    func integer(named names: [String]) -> Int64? {
        guard case let .integer(value)? = value(named: names) else { return nil }
        return value
    }

    func text(named names: [String]) -> String? {
        guard case let .text(value)? = value(named: names) else { return nil }
        return value
    }
}

private func createProtectedDirectory(_ url: URL, below root: URL? = nil) throws {
    let manager = FileManager.default
    if let root {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard archiveV1IsDescendant(parent, of: root) else { throw ArchiveError.invalidInput }
    }
    if manager.fileExists(atPath: url.path()) {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
    } else {
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path())
    if let root, !archiveV1IsDescendant(url, of: root) { throw ArchiveError.invalidInput }
}

private func archiveV1IsDescendant(_ url: URL, of root: URL) -> Bool {
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path()
    let valuePath = url.resolvingSymlinksInPath().standardizedFileURL.path()
    return valuePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
}

private func writePrivateJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    let directory = url.deletingLastPathComponent()
    let temporary = directory.appending(path: ".\(UUID().uuidString.lowercased()).staging")
    do {
        FileManager.default.createFile(atPath: temporary.path(), contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporary, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path())
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}

private func readManifest(at url: URL) throws -> ArchiveV1Manifest? {
    guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
    return try JSONDecoder().decode(ArchiveV1Manifest.self, from: Data(contentsOf: url, options: .mappedIfSafe))
}
