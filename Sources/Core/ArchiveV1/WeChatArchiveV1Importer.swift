import Foundation
import Darwin
import SQLite3

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
    let contactCount: Int
    let groupCount: Int
    let groupMemberCount: Int
    let imageMediaCount: Int
    let videoMediaCount: Int
    let voiceMediaCount: Int
    let avatarAssetCount: Int?
    let emoticonMediaCount: Int?
    let fileCount: Int?
    let fileMediaCount: Int?
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
    let contactCount: Int
    let groupCount: Int
    let groupMemberCount: Int
    let imageRawFound: Int
    let imageDecoded: Int
    let imageMissing: Int
    let videoRawFound: Int
    let videoThumbnailsFound: Int
    let voiceRawFound: Int
    let voiceDecoded: Int
    let avatarAssetCount: Int
    let errorsByCategory: [String: Int]
    let fileCount: Int
    let fileRawFound: Int
    let mediaStatusCounts: [String: Int]
    let emoticonRawFound: Int
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
    public let fileCount: Int
    public let unknownCount: Int
    public let mediaBytesCopied: Int64

    init(messagesRead: Int, messagesImported: Int, imagesResolved: Int, imagesDecoded: Int, imagesRawOnly: Int, imagesMissing: Int, textCount: Int, imageCount: Int, videoCount: Int, voiceCount: Int, fileCount: Int = 0, unknownCount: Int, mediaBytesCopied: Int64) {
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
        self.fileCount = fileCount
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
    private let mediaStoreFactory: @Sendable (URL) throws -> any ArchiveV1MediaStoring

    public init(
        sourceReader: WeChatArchiveV1SourceReader = .init(),
        imageKeyProvider: any WeChatImageKeyProvider
    ) {
        self.sourceReader = sourceReader
        self.imageKeyProvider = imageKeyProvider
        self.mediaStoreFactory = { try WeChatArchiveV1MediaStore(root: $0) }
    }

    init(
        sourceReader: WeChatArchiveV1SourceReader = .init(),
        imageKeyProvider: any WeChatImageKeyProvider,
        mediaStoreFactory: @escaping @Sendable (URL) throws -> any ArchiveV1MediaStoring
    ) {
        self.sourceReader = sourceReader
        self.imageKeyProvider = imageKeyProvider
        self.mediaStoreFactory = mediaStoreFactory
    }

    public func analyze(plainSQLiteRoot: URL) throws -> ArchiveV1ImportAnalysis {
        try sourceReader.analyze(exportRoot: plainSQLiteRoot)
    }

    public func importArchive(
        plainSQLiteRoot: URL,
        accountRoot: URL,
        destinationRoot: URL,
        options: ArchiveV1ImportOptions = .developmentDefault,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (ArchiveV1ImportProgress) -> Void)? = nil
    ) throws -> ArchiveV1ImportSummary {
        guard !options.resumeIncomplete || options.limit == nil else { throw ArchiveError.invalidInput }
        try validateImportRoots(
            plainSQLiteRoot: plainSQLiteRoot,
            accountRoot: accountRoot,
            destinationRoot: destinationRoot
        )
        let destination = try prepareArchiveRoot(destinationRoot, resume: options.resumeIncomplete)
        let importLock = try ArchiveV1ImportLock(root: destination)
        defer { withExtendedLifetime(importLock) {} }
        let mediaStore = try mediaStoreFactory(destination)
        let resourceResolver = WeChatMessageResourceFileBaseResolver()
        let cachedKeys = ArchiveImageKeyCache(provider: imageKeyProvider)
        let emoticons = try? WeChatLocalEmoticonIndex(plainRoot: plainSQLiteRoot, accountRoot: accountRoot)
        let database = try WeChatArchiveV1Database(url: destination.appending(path: "archive.sqlite"))
        defer { database.close() }

        if options.resumeIncomplete {
            try verifyResumeSource(database: database, plainRoot: plainSQLiteRoot, accountRoot: accountRoot, destination: destination)
            try removeInterruptedMedia(database: database, destination: destination)
        } else { try writeResumeBinding(accountRoot: accountRoot, destination: destination) }

        let runID = try database.createImportRun()
        var state = ImportState(runID: runID)
        if options.resumeIncomplete { try restoreCommittedState(database: database, destination: destination, state: &state) }
        var sourceDatabaseCount = 0
        do {
            let contactImport = try WeChatContactAdapter().read(plainSQLiteRoot: plainSQLiteRoot, accountRoot: accountRoot)
            let archivedContacts = try archiveContacts(contactImport, database: database)
            try archiveAvatars(
                contactImport,
                archivedContacts: archivedContacts,
                plainSQLiteRoot: plainSQLiteRoot,
                mediaStore: mediaStore,
                database: database,
                state: &state
            )
            try database.beginImportBatch()
            sourceDatabaseCount = try sourceReader.stream(exportRoot: plainSQLiteRoot, limit: options.limit) { message in
                guard !shouldCancel() else {
                    state.status = .cancelled
                    return false
                }
                try autoreleasepool { try process(
                    message: message,
                    database: database,
                    mediaStore: mediaStore,
                    plainSQLiteRoot: plainSQLiteRoot,
                    accountRoot: accountRoot,
                    identities: archivedContacts.identities,
                    resourceResolver: resourceResolver,
                    cachedKeys: cachedKeys,
                    emoticons: emoticons,
                    shouldCancel: shouldCancel,
                    state: &state
                ) }
                if state.messagesRead.isMultiple(of: options.batchSize) {
                    try database.finishImportBatch()
                    try database.beginImportBatch()
                }
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
                    fileCount: state.fileCount,
                    unknownCount: state.unknownCount,
                    mediaBytesCopied: state.archivedMediaBytes
                ))
                return true
            }
            try database.finishImportBatch()
            if state.status == .running { state.status = .completed }
            let summary = try makeSummary(state: state, database: database)
            try database.finishImportRun(runID, status: summary.status, sourceDatabaseCount: sourceDatabaseCount, summary: summary)
            try writeMetadata(destination: destination, summary: summary, sourceDatabaseCount: sourceDatabaseCount, database: database, state: state)
            return summary
        } catch is CancellationError {
            try database.finishImportBatch()
            state.status = .cancelled
            let summary = try makeSummary(state: state, database: database)
            try database.finishImportRun(runID, status: .cancelled, sourceDatabaseCount: sourceDatabaseCount, summary: summary)
            try writeMetadata(destination: destination, summary: summary, sourceDatabaseCount: sourceDatabaseCount, database: database, state: state)
            return summary
        } catch {
            try? database.finishImportBatch()
            state.status = .failed
            let summary = try? makeSummary(state: state, database: database)
            if let summary {
                try? database.finishImportRun(runID, status: .failed, sourceDatabaseCount: sourceDatabaseCount, summary: summary)
                try? writeMetadata(destination: destination, summary: summary, sourceDatabaseCount: sourceDatabaseCount, database: database, state: state)
            }
            throw error
        }
    }

    private func process(
        message: ArchiveV1SourceMessage,
        database: WeChatArchiveV1Database,
        mediaStore: any ArchiveV1MediaStoring,
        plainSQLiteRoot: URL,
        accountRoot: URL,
        identities: ArchiveV1IdentityIndex,
        resourceResolver: WeChatMessageResourceFileBaseResolver,
        cachedKeys: ArchiveImageKeyCache,
        emoticons: WeChatLocalEmoticonIndex?,
        shouldCancel: @escaping @Sendable () -> Bool,
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
        } else if rawTypeLow32(rawType) == 49, WeChatFileMessageAdapter.isFileMessage(message.values) {
            normalizedType = .file
            textContent = WeChatCompressedTextMessageAdapter().textContent(from: message.values, rawType: rawType)
        } else if let content = WeChatCompressedTextMessageAdapter().textContent(from: message.values, rawType: rawType) {
            // Covers message categories WeChat stores as a zstd-compressed
            // BLOB rather than a TEXT column: group-chat text, revoke
            // notices, location shares, and app messages (link/mini
            // program/quote-reply/red packet/transfer/...). See
            // WeChatCompressedTextMessageAdapter for what is and is not
            // recognized; anything it cannot parse still falls through to
            // `.unknown` below exactly as before.
            normalizedType = .text
            textContent = content
        } else {
            normalizedType = .unknown
            textContent = nil
        }

        let timestamp = message.values.integer(named: ["create_time", "createTime", "timestamp", "time"]) ?? 0
        let conversationSourceIdentity = message.conversationSourceIdentity ?? message.sourceTable
        let conversation = identities.conversation(for: conversationSourceIdentity)
        let conversationID = try database.upsertConversation(
            sourceIdentity: conversationSourceIdentity,
            type: conversation.type,
            displayName: conversation.displayName,
            contactID: conversation.contactID,
            createdAt: timestamp == 0 ? nil : timestamp
        )
        let senderSourceID = message.senderSourceIdentity
        let sender = identities.sender(for: senderSourceID, in: conversationSourceIdentity)
        let direction: ArchiveV1MessageDirection
        if rawTypeLow32(rawType) == 10_000 {
            // Verified locally as WeChat's system-notification raw type. Its
            // presentation direction is always `.system`, independent of
            // whether WeChatCompressedTextMessageAdapter recognized this
            // particular sysmsg subtype (only revoke notices are so far);
            // an unrecognized subtype still normalizes as `.unknown`.
            direction = .system
        } else if let owner = identities.ownerSourceIdentity, senderSourceID == owner {
            direction = .outgoing
        } else if senderSourceID != nil {
            direction = .incoming
        } else {
            direction = .unknown
        }
        let inserted = try database.insertMessage(
            conversationID: conversationID,
            sourceDatabase: message.sourceDatabase,
            sourceTable: message.sourceTable,
            sourceSQLiteRowID: message.sourceSQLiteRowID,
            sourceLocalID: message.values.integer(named: ["local_id", "message_id", "msg_id"]),
            sourceServerID: message.values.integer(named: ["server_id", "svr_id", "msg_svr_id"]),
            timestamp: timestamp,
            senderSourceID: senderSourceID,
            receiverSourceID: message.values.text(named: ["receiver_id", "to_user"]),
            rawLocalType: rawType,
            normalizedType: normalizedType,
            textContent: textContent,
            replySourceID: message.values.text(named: ["reply_source_id", "reply_msg_id"]),
            sourceSequence: message.sourceSequence,
            sourceValues: message.values,
            senderContactID: sender.contactID,
            senderDisplayName: sender.displayName,
            direction: direction
        )
        state.messagesRead += 1
        guard inserted.inserted else {
            state.messagesSkipped += 1
            if rawTypeLow32(rawType) == 47, normalizedType == .text {
                let former = try database.refreshEmoticonPresentation(messageID: inserted.id)
                if former != .text {
                    if former == .unknown { state.unknownCount -= 1 }
                    state.textCount += 1
                }
                for input in emoticons?.variants(values: message.values) ?? [] {
                    if try !database.hasMedia(messageID: inserted.id, type: input.mediaType, variant: input.variant) {
                        try archiveMedia(input, messageID: inserted.id, mediaStore: mediaStore, database: database, state: &state)
                    }
                }
            }
            return
        }
        state.messagesImported += 1
        switch normalizedType {
        case .text: state.textCount += 1
        case .image: state.imageCount += 1
        case .video: state.videoCount += 1
        case .voice: state.voiceCount += 1
        case .file: state.fileCount += 1
        case .unknown: state.unknownCount += 1
        }

        let inputs: [ArchiveV1MediaInput]
        switch normalizedType {
        case .image:
            do {
                inputs = try WeChatImageMessageAdapter(keyProvider: cachedKeys, resourceResolver: resourceResolver).variants(message: message, exportRoot: plainSQLiteRoot, accountRoot: accountRoot)
            } catch {
                inputs = ArchiveV1MediaVariant.imageVariants.map { .init(variant: $0, status: .resolutionFailed, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil) }
                state.mediaErrors["imageResolution", default: 0] += 1
            }
        case .video:
            do {
                inputs = try WeChatVideoMessageAdapter(resourceResolver: resourceResolver).variants(message: message, exportRoot: plainSQLiteRoot, accountRoot: accountRoot)
            } catch {
                inputs = ArchiveV1MediaVariant.videoVariants.map { .init(mediaType: .video, variant: $0, status: .resolutionFailed, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil) }
                state.mediaErrors["videoResolution", default: 0] += 1
            }
        case .voice:
            do {
                inputs = try WeChatVoiceMessageAdapter().variants(
                    message: message,
                    exportRoot: plainSQLiteRoot,
                    shouldCancel: shouldCancel
                )
            } catch VoiceDecoderError.cancelled {
                throw CancellationError()
            } catch {
                inputs = [.init(mediaType: .voice, variant: .raw, status: .resolutionFailed, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil)]
                state.mediaErrors["voiceResolution", default: 0] += 1
            }
        case .file:
            do { inputs = [try WeChatFileMessageAdapter().attachment(values: message.values, accountRoot: accountRoot)] }
            catch {
                inputs = [.init(mediaType: .file, variant: .raw, status: .resolutionFailed, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil)]
                state.mediaErrors["fileResolution", default: 0] += 1
            }
        case .text where rawTypeLow32(rawType) == 47:
            inputs = emoticons?.variants(values: message.values) ?? []
        case .text, .unknown:
            inputs = []
        }
        for input in inputs {
            try archiveMedia(input, messageID: inserted.id, mediaStore: mediaStore, database: database, state: &state)
        }
    }

    private func archiveContacts(_ contactImport: ArchiveV1ContactImport, database: WeChatArchiveV1Database) throws -> ArchiveV1ArchivedContacts {
        var contacts = [String: ArchiveV1ArchivedContact]()
        for contact in contactImport.contacts {
            let id = try database.upsertContact(
                sourceIdentity: contact.sourceIdentity,
                alias: contact.alias,
                remark: contact.remark,
                nickname: contact.nickname,
                displayName: contact.displayName,
                contactType: contact.contactType,
                avatarSmallURL: contact.avatarSmallURL,
                avatarLargeURL: contact.avatarLargeURL
            )
            contacts[contact.sourceIdentity] = .init(id: id, displayName: contact.displayName, isGroup: contact.isGroup)
        }
        if let owner = contactImport.ownerSourceIdentity, let contact = contacts[owner] {
            try database.setAccount(sourceIdentity: owner, displayName: contact.displayName)
        }
        var groupConversationIDs = [String: String]()
        for contact in contactImport.groupContacts {
            guard let archived = contacts[contact.sourceIdentity] else { continue }
            groupConversationIDs[contact.sourceIdentity] = try database.upsertConversation(
                sourceIdentity: contact.sourceIdentity,
                type: .group,
                displayName: archived.displayName,
                contactID: archived.id
            )
        }
        var groupMemberDisplays = [ArchiveV1GroupMemberIdentity: String]()
        for member in contactImport.groupMembers {
            guard let conversationID = groupConversationIDs[member.groupSourceIdentity] else { continue }
            let contactID = contacts[member.memberSourceIdentity]?.id
            try database.upsertGroupMember(
                conversationID: conversationID,
                contactID: contactID,
                memberSourceID: member.memberSourceIdentity,
                groupNickname: member.groupNickname,
                displayName: member.displayName
            )
            groupMemberDisplays[.init(groupSourceIdentity: member.groupSourceIdentity, memberSourceIdentity: member.memberSourceIdentity)] = member.displayName
        }
        return .init(
            identities: .init(
                contacts: contacts,
                groupMemberDisplays: groupMemberDisplays,
                ownerSourceIdentity: contactImport.ownerSourceIdentity
            ),
            groupConversationIDs: groupConversationIDs
        )
    }

    private func archiveAvatars(
        _ contactImport: ArchiveV1ContactImport,
        archivedContacts: ArchiveV1ArchivedContacts,
        plainSQLiteRoot: URL,
        mediaStore: any ArchiveV1MediaStoring,
        database: WeChatArchiveV1Database,
        state: inout ImportState
    ) throws {
        let candidates = try WeChatAvatarAdapter().read(plainSQLiteRoot: plainSQLiteRoot, contacts: contactImport.contacts)
        for contact in contactImport.contacts {
            guard let archived = archivedContacts.identities.contacts[contact.sourceIdentity],
                  let candidate = candidates[contact.sourceIdentity] else { continue }
            let primaryOwner: ArchiveV1AvatarOwnerType
            if contact.sourceIdentity == archivedContacts.identities.ownerSourceIdentity {
                primaryOwner = .account
            } else if contact.isGroup {
                primaryOwner = .group
            } else {
                primaryOwner = .contact
            }
            let assetID: String
            if let data = candidate.localData, let format = candidate.format {
                var stored: ArchiveV1StoredMedia?
                do {
                    let copied = try mediaStore.storeAvatarData(data, ownerType: primaryOwner, format: format, assetID: UUID().uuidString.lowercased())
                    stored = copied
                    assetID = try database.upsertAvatarAsset(
                        sourceKey: candidate.sourceIdentity,
                        sourceFormat: format,
                        archivePath: copied.relativePath,
                        width: candidate.width,
                        height: candidate.height,
                        size: copied.size,
                        sha256: copied.sha256,
                        sourceURL: candidate.sourceURL,
                        status: .archived
                    )
                    state.avatarAssetsArchived += 1
                    state.archivedMediaBytes += copied.reused ? 0 : copied.size
                } catch {
                    if let stored { mediaStore.removeStoredMedia(stored) }
                    assetID = try database.upsertAvatarAsset(
                        sourceKey: candidate.sourceIdentity,
                        sourceFormat: candidate.format,
                        archivePath: nil,
                        width: candidate.width,
                        height: candidate.height,
                        size: nil,
                        sha256: nil,
                        sourceURL: candidate.sourceURL,
                        status: candidate.sourceURL == nil ? .missing : .remoteAvailable
                    )
                }
            } else {
                assetID = try database.upsertAvatarAsset(
                    sourceKey: candidate.sourceIdentity,
                    sourceFormat: nil,
                    archivePath: nil,
                    width: nil,
                    height: nil,
                    size: nil,
                    sha256: nil,
                    sourceURL: candidate.sourceURL,
                    status: candidate.status
                )
            }
            try database.linkAvatar(assetID: assetID, ownerType: .contact, ownerID: archived.id)
            if contact.sourceIdentity == archivedContacts.identities.ownerSourceIdentity {
                try database.linkAvatar(assetID: assetID, ownerType: .account, ownerID: "1")
            }
            if let groupID = archivedContacts.groupConversationIDs[contact.sourceIdentity] {
                try database.linkAvatar(assetID: assetID, ownerType: .group, ownerID: groupID)
            }
        }
    }

    private func archiveMedia(
        _ input: ArchiveV1MediaInput,
        messageID: String,
        mediaStore: any ArchiveV1MediaStoring,
        database: WeChatArchiveV1Database,
        state: inout ImportState
    ) throws {
        let assetID = UUID().uuidString.lowercased()
        let raw: ArchiveV1StoredMedia?
        do {
            if let data = input.rawData {
                raw = try mediaStore.storeRawData(data, mediaType: input.mediaType, variant: input.variant, sourceFormat: input.sourceFormat, assetID: assetID)
            } else if let fileURL = input.rawFileURL {
                raw = try mediaStore.storeRawFile(fileURL, mediaType: input.mediaType, variant: input.variant, sourceFormat: input.sourceFormat, assetID: assetID)
            } else {
                raw = nil
            }
        } catch {
            try recordMedia(
                input,
                messageID: messageID,
                assetID: assetID,
                status: .rawCopyFailed,
                raw: nil,
                decoded: nil,
                database: database
            )
            state.decodeFailures += 1
            state.mediaErrors["\(input.mediaType.rawValue)RawCopy", default: 0] += 1
            state.mediaStatusCounts["\(input.mediaType.rawValue):rawCopyFailed", default: 0] += 1
            return
        }
        let decoded: ArchiveV1StoredMedia?
        do {
            decoded = try input.decodedData.map { try mediaStore.storeDecodedData($0, mediaType: input.mediaType, format: input.decodedFormat, assetID: assetID) }
        } catch {
            do {
                try recordMedia(
                    input,
                    messageID: messageID,
                    assetID: assetID,
                    status: .decodedCopyFailed,
                    raw: raw,
                    decoded: nil,
                    database: database
                )
            } catch {
                if let raw { mediaStore.removeStoredMedia(raw) }
                throw error
            }
            state.mediaErrors["\(input.mediaType.rawValue)DecodedCopy", default: 0] += 1
            state.archivedMediaBytes += raw?.reused == false ? (raw?.size ?? 0) : 0
            recordState(for: input, raw: raw, decoded: nil, effectiveStatus: .decodedCopyFailed, state: &state)
            return
        }
        do {
            try recordMedia(
                input,
                messageID: messageID,
                assetID: assetID,
                status: input.status,
                raw: raw,
                decoded: decoded,
                database: database
            )
        } catch {
            if let decoded { mediaStore.removeStoredMedia(decoded) }
            if let raw { mediaStore.removeStoredMedia(raw) }
            throw error
        }
        state.archivedMediaBytes += (raw?.reused == false ? (raw?.size ?? 0) : 0) + (decoded?.reused == false ? (decoded?.size ?? 0) : 0)
        recordState(for: input, raw: raw, decoded: decoded, state: &state)
    }

    private func recordMedia(
        _ input: ArchiveV1MediaInput,
        messageID: String,
        assetID: String,
        status: ArchiveV1MediaStatus,
        raw: ArchiveV1StoredMedia?,
        decoded: ArchiveV1StoredMedia?,
        database: WeChatArchiveV1Database
    ) throws {
        _ = try database.insertMediaAsset(
            messageID: messageID,
            assetID: assetID,
            mediaType: input.mediaType,
            variant: input.variant,
            status: status,
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
    }

    private func recordState(
        for input: ArchiveV1MediaInput,
        raw: ArchiveV1StoredMedia?,
        decoded: ArchiveV1StoredMedia?,
        effectiveStatus: ArchiveV1MediaStatus? = nil,
        state: inout ImportState
    ) {
        let status = effectiveStatus ?? input.status
        state.mediaStatusCounts["\(input.mediaType.rawValue):\(status.rawValue)", default: 0] += 1
        if status == .missing { state.missingLocalMedia += 1 }
        switch input.mediaType {
        case .image:
            if raw != nil { state.rawDATArchived += 1; state.imageVariantsResolved += 1 }
            if decoded != nil && status == .decoded { state.decodedImages += 1 }
            if raw != nil && decoded == nil && status != .missing {
                state.rawOnlyImages += 1
                state.decodeFailures += 1
            }
        case .video:
            if raw != nil && input.variant == .thumbnail { state.videoThumbnailsArchived += 1 }
            if raw != nil && input.variant != .thumbnail { state.rawVideoArchived += 1 }
        case .voice:
            if raw != nil { state.rawVoiceArchived += 1 }
            if decoded != nil { state.decodedVoiceArchived += 1 }
        case .file:
            if raw != nil {
                if input.sourceFormat?.hasPrefix("emoticon-cipher-") == true { state.rawEmoticonArchived += 1 }
                else { state.rawFileArchived += 1 }
            }
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
            fileCount: state.fileCount,
            unknownCount: state.unknownCount,
            conversationCount: try database.conversationCount(),
            contactCount: try database.contactCount(),
            groupCount: try database.groupCount(),
            groupMemberCount: try database.groupMemberCount(),
            avatarAssetCount: try database.avatarAssetCount(),
            rawDATArchived: state.rawDATArchived,
            decodedImages: state.decodedImages,
            rawVideoArchived: state.rawVideoArchived,
            videoThumbnailsArchived: state.videoThumbnailsArchived,
            rawVoiceArchived: state.rawVoiceArchived,
            rawFileArchived: state.rawFileArchived,
            decodedVoiceArchived: state.decodedVoiceArchived,
            archivedMediaBytes: state.archivedMediaBytes,
            missingLocalMedia: state.missingLocalMedia,
            decodeFailures: state.decodeFailures
        )
    }

    private func writeMetadata(destination: URL, summary: ArchiveV1ImportSummary, sourceDatabaseCount: Int, database: WeChatArchiveV1Database, state: ImportState) throws {
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
            contactCount: summary.contactCount,
            groupCount: summary.groupCount,
            groupMemberCount: summary.groupMemberCount,
            imageMediaCount: summary.rawDATArchived,
            videoMediaCount: summary.rawVideoArchived + summary.videoThumbnailsArchived,
            voiceMediaCount: summary.rawVoiceArchived + summary.decodedVoiceArchived,
            avatarAssetCount: summary.avatarAssetCount,
            emoticonMediaCount: state.rawEmoticonArchived,
            fileCount: summary.fileCount,
            fileMediaCount: summary.rawFileArchived
        )
        var errors = state.mediaErrors
        let copyFailures = state.mediaErrors.filter { $0.key.hasSuffix("RawCopy") || $0.key.hasSuffix("DecodedCopy") }.values.reduce(0, +)
        if summary.decodeFailures > copyFailures { errors["mediaDecode"] = summary.decodeFailures - copyFailures }
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
            contactCount: summary.contactCount,
            groupCount: summary.groupCount,
            groupMemberCount: summary.groupMemberCount,
            imageRawFound: summary.rawDATArchived,
            imageDecoded: summary.decodedImages,
            imageMissing: state.mediaStatusCounts["image:missing", default: 0],
            videoRawFound: summary.rawVideoArchived,
            videoThumbnailsFound: summary.videoThumbnailsArchived,
            voiceRawFound: summary.rawVoiceArchived,
            voiceDecoded: summary.decodedVoiceArchived,
            avatarAssetCount: summary.avatarAssetCount,
            errorsByCategory: errors,
            fileCount: summary.fileCount,
            fileRawFound: summary.rawFileArchived,
            mediaStatusCounts: state.mediaStatusCounts,
            emoticonRawFound: state.rawEmoticonArchived
        )
        try writePrivateJSON(manifest, to: destination.appending(path: "archive-manifest.json"))
        let metadata = destination.appending(path: "metadata")
        try createProtectedDirectory(metadata, below: destination)
        try writePrivateJSON(report, to: metadata.appending(path: "import-report.json"))
    }

    private struct ResumeBinding: Codable { let accountFingerprint: String }

    private func writeResumeBinding(accountRoot: URL, destination: URL) throws {
        let folder = destination.appending(path: "metadata")
        try createProtectedDirectory(folder, below: destination)
        let hash = ArchiveCryptography.sha256(Data(accountRoot.resolvingSymlinksInPath().path().utf8))
        try writePrivateJSON(ResumeBinding(accountFingerprint: hash), to: folder.appending(path: "resume-binding.json"))
    }

    private func verifyResumeSource(database: WeChatArchiveV1Database, plainRoot: URL, accountRoot: URL, destination: URL) throws {
        let binding = destination.appending(path: "metadata/resume-binding.json")
        if FileManager.default.fileExists(atPath: binding.path()) {
            let info = try binding.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
            let value = try JSONDecoder().decode(ResumeBinding.self, from: Data(contentsOf: binding))
            guard value.accountFingerprint == ArchiveCryptography.sha256(Data(accountRoot.resolvingSymlinksInPath().path().utf8)) else { throw ArchiveError.invalidArchive }
        }
        let rows = try database.importedRowsByTable()
        let expected = try database.messageCount()
        var verified = 0
        _ = try sourceReader.stream(exportRoot: plainRoot, limit: nil) { message in
            guard rows[message.sourceDatabase]?[message.sourceTable]?.contains(message.sourceSQLiteRowID) == true else { return true }
            return try autoreleasepool {
                let saved = try database.sourceValues(sourceDatabase: message.sourceDatabase, sourceTable: message.sourceTable, sourceSQLiteRowID: message.sourceSQLiteRowID)
                guard saved == message.values else { throw ArchiveError.invalidArchive }
                verified += 1
                return true
            }
        }
        guard verified == expected else { throw ArchiveError.invalidArchive }
        try writeResumeBinding(accountRoot: accountRoot, destination: destination)
    }

    private func removeInterruptedMedia(database: WeChatArchiveV1Database, destination: URL) throws {
        let registered = try database.registeredMediaPaths()
        let root = destination.appending(path: "media")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw ArchiveError.invalidArchive }
        let prefix = destination.path().hasSuffix("/") ? destination.path() : destination.path() + "/"
        for case let url as URL in files {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
            guard info.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path()
            guard path.hasPrefix(prefix) else { throw ArchiveError.invalidArchive }
            guard !registered.contains(String(path.dropFirst(prefix.count))) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let managed = stem.utf8.count == 64 && stem.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            let name = url.lastPathComponent
            let staging = name.hasPrefix(".") && name.hasSuffix(".staging") && UUID(uuidString: String(name.dropFirst().dropLast(".staging".count))) != nil
            guard managed || staging else { throw ArchiveError.invalidArchive }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func restoreCommittedState(database: WeChatArchiveV1Database, destination: URL, state: inout ImportState) throws {
        state.messagesImported = try database.messageCount()
        let types = try database.recoveryTypeCounts()
        state.textCount = types["text", default: 0]; state.imageCount = types["image", default: 0]
        state.videoCount = types["video", default: 0]; state.voiceCount = types["voice", default: 0]
        state.fileCount = types["file", default: 0]; state.unknownCount = types["unknown", default: 0]
        for row in try database.recoveryMediaGroups() {
            state.mediaStatusCounts[row.type + ":" + row.status, default: 0] += row.count
            if row.status == "missing" { state.missingLocalMedia += row.count }
            if row.status == "rawCopyFailed" { state.decodeFailures += row.count; state.mediaErrors[row.type + "RawCopy", default: 0] += row.count }
            if row.status == "decodedCopyFailed" { state.mediaErrors[row.type + "DecodedCopy", default: 0] += row.count }
            if row.status == "resolutionFailed" { state.mediaErrors[row.type + "Resolution", default: 0] += row.count }
            switch row.type {
            case "image":
                if row.raw { state.rawDATArchived += row.count; state.imageVariantsResolved += row.count }
                if row.decoded && row.status == "decoded" { state.decodedImages += row.count }
                if row.raw && !row.decoded && row.status != "missing" { state.rawOnlyImages += row.count; state.decodeFailures += row.count }
            case "video":
                if row.raw && row.variant == "thumbnail" { state.videoThumbnailsArchived += row.count }
                else if row.raw { state.rawVideoArchived += row.count }
            case "voice":
                if row.raw { state.rawVoiceArchived += row.count }
                if row.decoded { state.decodedVoiceArchived += row.count }
            case "file":
                if row.raw && row.format?.hasPrefix("emoticon-cipher-") == true { state.rawEmoticonArchived += row.count }
                else if row.raw { state.rawFileArchived += row.count }
            default: throw ArchiveError.invalidArchive
            }
        }
        for path in try database.registeredMediaPaths() {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw ArchiveError.invalidArchive }
            let info = try destination.appending(path: path).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
            state.archivedMediaBytes += Int64(info.fileSize ?? 0)
        }
    }

    private func prepareArchiveRoot(_ url: URL, resume: Bool) throws -> URL {
        let root = url.standardizedFileURL
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path()) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
            if resume {
                let handle = try ArchiveReadOnlySQLite.open(root.appending(path: "archive.sqlite"))
                defer { sqlite3_close(handle) }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "SELECT status FROM import_runs ORDER BY started_at DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw ArchiveError.invalidArchive }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW, let status = sqlite3_column_text(statement, 0), String(cString: status) != "completed" else { throw ArchiveError.invalidArchive }
                var version: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK else { throw ArchiveError.invalidArchive }
                defer { sqlite3_finalize(version) }
                guard sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int(version, 0) == WeChatArchiveV1Database.schemaVersion else { throw ArchiveError.invalidArchive }
            } else { guard try manager.contentsOfDirectory(atPath: root.path()).isEmpty else { throw ArchiveError.invalidArchive } }
        } else {
            guard !resume else { throw ArchiveError.invalidArchive }
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path())
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func validateImportRoots(plainSQLiteRoot: URL, accountRoot: URL, destinationRoot: URL) throws {
        let plain = try canonicalDirectory(plainSQLiteRoot, mustExist: true)
        let account = try canonicalDirectory(accountRoot, mustExist: true)
        let destination = try canonicalDirectory(destinationRoot, mustExist: false)
        let roots = [plain, account, destination]
        for left in roots.indices {
            for right in roots.indices where left < right {
                guard !pathsOverlap(roots[left], roots[right]) else { throw ArchiveError.invalidInput }
            }
        }
    }

    private func canonicalDirectory(_ url: URL, mustExist: Bool) throws -> URL {
        let requested = url.standardizedFileURL
        let manager = FileManager.default
        if mustExist {
            let values = try requested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
            return requested.resolvingSymlinksInPath().standardizedFileURL
        }
        if manager.fileExists(atPath: requested.path()) {
            let values = try requested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
            return requested.resolvingSymlinksInPath().standardizedFileURL
        }
        let parent = requested.deletingLastPathComponent()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              requested.lastPathComponent != ".", requested.lastPathComponent != ".." else { throw ArchiveError.invalidInput }
        return parent.resolvingSymlinksInPath().appending(path: requested.lastPathComponent).standardizedFileURL
    }

    private func pathsOverlap(_ left: URL, _ right: URL) -> Bool {
        isSameOrDescendant(left, of: right) || isSameOrDescendant(right, of: left)
    }

    private func isSameOrDescendant(_ value: URL, of parent: URL) -> Bool {
        let parentPath = parent.path().hasSuffix("/") ? parent.path() : parent.path() + "/"
        return value.path() == parent.path() || value.path().hasPrefix(parentPath)
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
    var fileCount = 0
    var unknownCount = 0
    var rawDATArchived = 0
    var decodedImages = 0
    var rawVideoArchived = 0
    var videoThumbnailsArchived = 0
    var rawVoiceArchived = 0
    var rawFileArchived = 0
    var rawEmoticonArchived = 0
    var mediaErrors = [String: Int]()
    var mediaStatusCounts = [String: Int]()
    var decodedVoiceArchived = 0
    var avatarAssetsArchived = 0
    var archivedMediaBytes: Int64 = 0
    var missingLocalMedia = 0
    var decodeFailures = 0
    var imageVariantsResolved = 0
    var rawOnlyImages = 0
}

private struct ArchiveV1ArchivedContact: Sendable {
    let id: String
    let displayName: String
    let isGroup: Bool
}

private struct ArchiveV1GroupMemberIdentity: Hashable, Sendable {
    let groupSourceIdentity: String
    let memberSourceIdentity: String
}

private struct ArchiveV1ConversationIdentity: Sendable {
    let type: ArchiveV1ConversationType
    let displayName: String?
    let contactID: String?
}

private struct ArchiveV1SenderIdentity: Sendable {
    let contactID: String?
    let displayName: String?
}

private struct ArchiveV1IdentityIndex: Sendable {
    let contacts: [String: ArchiveV1ArchivedContact]
    let groupMemberDisplays: [ArchiveV1GroupMemberIdentity: String]
    let ownerSourceIdentity: String?

    func conversation(for sourceIdentity: String) -> ArchiveV1ConversationIdentity {
        if sourceIdentity.lowercased().hasSuffix("@chatroom") {
            let contact = contacts[sourceIdentity]
            return .init(type: .group, displayName: contact?.displayName ?? "群聊", contactID: contact?.id)
        }
        if let contact = contacts[sourceIdentity] {
            return .init(type: .private, displayName: contact.displayName, contactID: contact.id)
        }
        return .init(type: .unknown, displayName: nil, contactID: nil)
    }

    func sender(for sourceIdentity: String?, in conversationSourceIdentity: String) -> ArchiveV1SenderIdentity {
        guard let sourceIdentity else { return .init(contactID: nil, displayName: nil) }
        let groupKey = ArchiveV1GroupMemberIdentity(groupSourceIdentity: conversationSourceIdentity, memberSourceIdentity: sourceIdentity)
        if let groupDisplay = groupMemberDisplays[groupKey] {
            return .init(contactID: contacts[sourceIdentity]?.id, displayName: groupDisplay)
        }
        return .init(contactID: contacts[sourceIdentity]?.id, displayName: contacts[sourceIdentity]?.displayName)
    }
}

private struct ArchiveV1ArchivedContacts: Sendable {
    let identities: ArchiveV1IdentityIndex
    let groupConversationIDs: [String: String]
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

/// Per-import cache only: key bytes never enter preferences, logs or archives.
private final class ArchiveImageKeyCache: WeChatImageKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let provider: any WeChatImageKeyProvider
    private var values: [URL: [WeChatImageKeyMaterial]] = [:]
    init(provider: any WeChatImageKeyProvider) { self.provider = provider }
    func keyCandidates(accountRoot: URL) throws -> [WeChatImageKeyMaterial] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = values[accountRoot] { return cached }
        let keys = (try? provider.keyCandidates(accountRoot: accountRoot)) ?? []
        values[accountRoot] = keys
        return keys
    }
}

private final class ArchiveV1ImportLock {
    private let descriptor: Int32
    init(root: URL) throws {
        let fd = open(root.appending(path: ".import.lock").path(), O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ArchiveError.ioFailure }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ArchiveError.invalidArchive }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
