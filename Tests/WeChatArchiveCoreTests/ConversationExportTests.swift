import Foundation
import SQLite3
import XCTest
@testable import WeChatArchiveCore

final class ConversationExportTests: XCTestCase {
    func testConversationExporterWritesEscapedPortableHTMLWithMediaAndAvatars() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: destination,
            format: .html,
            options: .init(pageSize: 2)
        )
        let html = try String(contentsOf: result.primaryFileURL, encoding: .utf8)

        XCTAssertEqual(result.messagesExported, 5)
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("media/images/"))
        XCTAssertTrue(html.contains("media/video/"))
        XCTAssertTrue(html.contains("media/voice/"))
        XCTAssertTrue(html.contains("avatars/"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("sensitive-source.db"))
        XCTAssertFalse(html.contains("source_sqlite_rowid"))
        XCTAssertEqual(try permissionBits(at: result.outputRoot), 0o700)
        XCTAssertEqual(try permissionBits(at: result.primaryFileURL), 0o600)
    }

    func testConversationExporterWritesPrivateJSONWithoutTechnicalMetadataAndMarkdownEscapesText() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let exporter = WeChatArchiveConversationExporter()
        let json = try exporter.export(archiveRoot: fixture.root, conversationID: fixture.conversationID, destinationRoot: destination, format: .json)
        let jsonData = try Data(contentsOf: json.primaryFileURL)
        let jsonObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let messages = try XCTUnwrap(jsonObject["messages"] as? [[String: Any]])
        let markdown = try exporter.export(archiveRoot: fixture.root, conversationID: fixture.conversationID, destinationRoot: destination, format: .markdown)
        let markdownText = try String(contentsOf: markdown.primaryFileURL, encoding: .utf8)

        XCTAssertEqual(jsonObject["format"] as? String, "WeChatConversationExport")
        XCTAssertEqual(jsonObject["version"] as? Int, 1)
        XCTAssertEqual(messages.count, 5)
        XCTAssertNil(jsonObject["source_database"])
        XCTAssertFalse(String(decoding: jsonData, as: UTF8.self).contains("sensitive-source.db"))
        XCTAssertTrue(markdownText.contains("\\# \\[not a heading\\]"))
        XCTAssertTrue(markdownText.contains("[图片]"))
        XCTAssertTrue(markdownText.contains("[语音"))
        XCTAssertTrue(markdownText.contains("[视频]"))
    }

    func testConversationExporterSupportsTechnicalMetadataOnlyWhenExplicitlyEnabled() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: destination,
            format: .json,
            options: .init(includeTechnicalMetadata: true)
        )
        let text = try String(contentsOf: result.primaryFileURL, encoding: .utf8)

        XCTAssertTrue(text.contains("rawLocalType"))
        XCTAssertFalse(text.contains("sensitive-source.db"))
    }

    func testConversationExporterRejectsArchiveDestinationAndCleansCancelledStaging() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let exporter = WeChatArchiveConversationExporter()

        XCTAssertThrowsError(
            try exporter.export(archiveRoot: fixture.root, conversationID: fixture.conversationID, destinationRoot: fixture.root, format: .html)
        )
        XCTAssertThrowsError(
            try exporter.export(
                archiveRoot: fixture.root,
                conversationID: fixture.conversationID,
                destinationRoot: fixture.root.deletingLastPathComponent(),
                format: .html,
                shouldCancel: { true }
            )
        )
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.root.deletingLastPathComponent().path())
        XCTAssertFalse(siblings.contains { $0.contains(".ChatExport-") })
    }

    func testConversationExporterRejectsSymlinkDestinationAndDoesNotCopySymlinkMedia() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let parent = fixture.root.deletingLastPathComponent()
        let realDestination = parent.appending(path: "RealExports")
        let linkedDestination = parent.appending(path: "LinkedExports")
        try FileManager.default.createDirectory(at: realDestination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedDestination, withDestinationURL: realDestination)
        XCTAssertThrowsError(try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: linkedDestination,
            format: .html
        ))

        let image = fixture.root.appending(path: "media/images/decoded/image-asset.png")
        try FileManager.default.removeItem(at: image)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        let result = try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: realDestination,
            format: .html
        )
        let exportedImages = result.outputRoot.appending(path: "media/images")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: exportedImages.path())).isEmpty)
    }

    func testConversationExporterStreamsFiveThousandMessagesInPages() throws {
        let fixture = try makeFixture(messageCount: 5_000)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var progressPages = 0

        let result = try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: destination,
            format: .markdown,
            options: .init(pageSize: 250),
            progress: { progress in
                if progress.messagesExported.isMultiple(of: 250) { progressPages += 1 }
            }
        )

        XCTAssertEqual(result.messagesExported, 5_000)
        XCTAssertGreaterThanOrEqual(progressPages, 20)
    }

    func testWorkspacePreferencesPersistOnlyWorkspaceLocationsAndGracefullyRejectInvalidArchive() throws {
        let suite = "WeChatArchiveTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WorkspacePreferences(defaults: defaults)
        let root = try makeFixture().root
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        preferences.lastPlainSQLiteRoot = URL(fileURLWithPath: "/fixture/plain")
        preferences.lastAccountRoot = URL(fileURLWithPath: "/fixture/account")
        preferences.lastArchiveParentDirectory = URL(fileURLWithPath: "/fixture/archives")
        preferences.lastConversationExportDirectory = URL(fileURLWithPath: "/fixture/exports")
        preferences.lastConversationExportFormat = .markdown
        preferences.recordOpenedArchive(root)

        let restored = WorkspacePreferences(defaults: defaults)
        XCTAssertEqual(restored.lastPlainSQLiteRoot?.path, "/fixture/plain")
        XCTAssertEqual(restored.lastAccountRoot?.path, "/fixture/account")
        XCTAssertEqual(restored.lastArchiveParentDirectory?.path, "/fixture/archives")
        XCTAssertEqual(restored.lastConversationExportDirectory?.path, "/fixture/exports")
        XCTAssertEqual(restored.lastConversationExportFormat, .markdown)
        XCTAssertEqual(try restored.validLastOpenedArchive()?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertFalse(defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("workspace.") }
            .contains { $0.localizedCaseInsensitiveContains("key") || $0.localizedCaseInsensitiveContains("aes") || $0.localizedCaseInsensitiveContains("password") })

        try FileManager.default.removeItem(at: root)
        XCTAssertNil(try restored.validLastOpenedArchive())
        XCTAssertNil(restored.lastOpenedArchiveRoot)
    }

    func testViewerSearchesConversationTitlesAndV4CreatesTimelineIndex() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)
        let page = try viewer.searchConversationPage(query: "Fixture", limit: 20)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.id, fixture.conversationID)
        XCTAssertTrue(try hasTimelineIndex(in: fixture.root.appending(path: "archive.sqlite")))
    }

    /// Opt-in local acceptance coverage. It deliberately emits no private
    /// archive values and is skipped in normal CI.
    func testOptionalExistingArchiveExportsFromArchiveOnly() throws {
        guard let rootPath = ProcessInfo.processInfo.environment["WECHAT_ARCHIVE_REAL_ROOT"], !rootPath.isEmpty else {
            throw XCTSkip("Set WECHAT_ARCHIVE_REAL_ROOT for local archive acceptance coverage.")
        }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: URL(fileURLWithPath: rootPath))
        let conversations = try viewer.conversationPage(limit: 100).items
        guard let privateConversation = conversations.filter({ $0.type == .private && $0.messageCount > 0 }).min(by: { $0.messageCount < $1.messageCount }),
              let groupConversation = conversations.filter({ $0.type == .group && $0.messageCount > 0 }).min(by: { $0.messageCount < $1.messageCount }) else {
            throw XCTSkip("The local archive did not expose both non-empty private and group conversations in its first page.")
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "ConversationExportAcceptance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let exporter = WeChatArchiveConversationExporter()
        let privateHTML = try exporter.export(archiveRoot: viewer.archiveRoot, conversationID: privateConversation.id, destinationRoot: destination, format: .html)
        let groupJSON = try exporter.export(archiveRoot: viewer.archiveRoot, conversationID: groupConversation.id, destinationRoot: destination, format: .json)
        let groupMarkdown = try exporter.export(archiveRoot: viewer.archiveRoot, conversationID: groupConversation.id, destinationRoot: destination, format: .markdown)

        XCTAssertGreaterThan(privateHTML.messagesExported, 0)
        XCTAssertGreaterThan(groupJSON.messagesExported, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateHTML.primaryFileURL.path()))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: groupJSON.primaryFileURL)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: groupMarkdown.primaryFileURL.path()))
    }

    private func makeFixture(messageCount: Int = 5) throws -> ConversationExportFixture {
        let parent = FileManager.default.temporaryDirectory.appending(path: "ConversationExport-\(UUID().uuidString)")
        let root = parent.appending(path: "WeChatArchive")
        let database = try WeChatArchiveV1Database(url: root.appending(path: "archive.sqlite"))
        defer { database.close() }
        let contactID = try database.upsertContact(sourceIdentity: "fixture-contact", alias: nil, remark: nil, nickname: "Fixture sender", displayName: "Fixture sender", contactType: "contact")
        try database.setAccount(sourceIdentity: "fixture-owner", displayName: "Fixture owner")
        let conversationID = try database.upsertConversation(sourceIdentity: "fixture-conversation", type: .group, displayName: "Fixture Group 中文", contactID: contactID)
        let base = root.appending(path: "media")
        try writePrivate(Data([0x89, 0x50, 0x4E, 0x47]), to: base.appending(path: "images/decoded/image-asset.png"))
        try writePrivate(Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]), to: base.appending(path: "video/play/video-asset.mp4"))
        try writePrivate(Data("RIFF----WAVEfmt ".utf8), to: base.appending(path: "voice/decoded/voice-asset.wav"))
        try writePrivate(Data([0x89, 0x50, 0x4E, 0x47]), to: base.appending(path: "avatars/contacts/contact-avatar.png"))
        try writePrivate(Data([0x89, 0x50, 0x4E, 0x47]), to: base.appending(path: "avatars/account/account-avatar.png"))
        let contactAvatar = try database.upsertAvatarAsset(sourceKey: "fixture-contact", sourceFormat: "png", archivePath: "media/avatars/contacts/contact-avatar.png", width: 1, height: 1, size: 4, sha256: ArchiveCryptography.sha256(Data([0x89, 0x50, 0x4E, 0x47])), sourceURL: nil, status: .archived)
        let accountAvatar = try database.upsertAvatarAsset(sourceKey: "fixture-owner", sourceFormat: "png", archivePath: "media/avatars/account/account-avatar.png", width: 1, height: 1, size: 4, sha256: ArchiveCryptography.sha256(Data([0x89, 0x50, 0x4E, 0x47])), sourceURL: nil, status: .archived)
        try database.linkAvatar(assetID: contactAvatar, ownerType: .contact, ownerID: contactID)
        try database.linkAvatar(assetID: accountAvatar, ownerType: .account, ownerID: "1")

        for index in 0..<messageCount {
            let types: [ArchiveV1NormalizedType] = [.text, .image, .voice, .video, .unknown]
            let type = messageCount > 5 ? .text : types[index % types.count]
            let message = try database.insertMessage(
                conversationID: conversationID,
                sourceDatabase: "sensitive-source.db",
                sourceTable: "sensitive-table",
                sourceSQLiteRowID: Int64(index + 1),
                sourceLocalID: Int64(index + 1),
                sourceServerID: nil,
                timestamp: Int64(1_700_000_000 + index),
                senderSourceID: index.isMultiple(of: 2) ? "fixture-contact" : "fixture-owner",
                receiverSourceID: nil,
                rawLocalType: Int64(index + 1),
                normalizedType: type,
                textContent: type == .text ? "# [not a heading] <script>alert('x')</script> & \"quoted\"\nemoji 😀" : nil,
                replySourceID: nil,
                sourceSequence: Int64(index),
                sourceValues: ["private_blob": .blob(Data([0xAA]))],
                senderContactID: contactID,
                senderDisplayName: "Fixture sender",
                direction: index.isMultiple(of: 2) ? .incoming : .outgoing
            )
            switch type {
            case .image:
                _ = try database.insertMediaAsset(messageID: message.id, assetID: "image-asset", mediaType: .image, variant: .main, status: .decoded, sourceFormat: "dat", decodedFormat: "png", rawArchivePath: nil, decodedArchivePath: "media/images/decoded/image-asset.png", rawSize: nil, decodedSize: 4, width: 1, height: 1, rawSHA256: nil, decodedSHA256: ArchiveCryptography.sha256(Data([0x89, 0x50, 0x4E, 0x47])), sourceFileBase: "private")
            case .voice:
                _ = try database.insertMediaAsset(messageID: message.id, assetID: "voice-asset", mediaType: .voice, variant: .playback, status: .decoded, sourceFormat: "silk", decodedFormat: "wav", rawArchivePath: nil, decodedArchivePath: "media/voice/decoded/voice-asset.wav", rawSize: nil, decodedSize: 16, width: nil, height: nil, duration: 8, rawSHA256: nil, decodedSHA256: ArchiveCryptography.sha256(Data("RIFF----WAVEfmt ".utf8)), sourceFileBase: "private")
            case .video:
                _ = try database.insertMediaAsset(messageID: message.id, assetID: "video-asset", mediaType: .video, variant: .play, status: .rawArchived, sourceFormat: "mp4", decodedFormat: nil, rawArchivePath: "media/video/play/video-asset.mp4", decodedArchivePath: nil, rawSize: 8, decodedSize: nil, width: 2, height: 2, duration: 9, rawSHA256: ArchiveCryptography.sha256(Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])), decodedSHA256: nil, sourceFileBase: "private")
            case .text, .unknown: break
            }
        }
        return .init(root: root, conversationID: conversationID)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func permissionBits(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
    }

    private func hasTimelineIndex(in databaseURL: URL) throws -> Bool {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'messages_conversation_timeline'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

private struct ConversationExportFixture {
    let root: URL
    let conversationID: String
}
