import Foundation
import CryptoKit
import CommonCrypto
import SQLite3
import XCTest
@testable import WeChatArchiveCore

final class ArchiveCoreTests: XCTestCase {

    func testArchiveV1DatabaseCreatesVersionedLosslessSchema() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appending(path: "WeChatArchive/archive.sqlite")

        let database = try WeChatArchiveV1Database(url: archiveURL)

        try expectEqual(try database.schemaVersion(), 4)
        try expectEqual(try database.requiredTables(), Set([
            "import_runs", "account", "contacts", "conversations", "group_members", "messages", "message_source_values", "media_assets", "message_media_links", "avatar_assets", "avatar_owner_links"
        ]))
        try expectEqual(try permissionBits(at: archiveURL.deletingLastPathComponent()), 0o700)
        try expectEqual(try permissionBits(at: archiveURL), 0o600)
    }

    func testArchiveV1MediaStoreRejectsSymlinkedDestinationSubtree() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveRoot = directory.appending(path: "WeChatArchive")
        let outsideRoot = directory.appending(path: "Outside")
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: archiveRoot.appending(path: "media"), withDestinationURL: outsideRoot)

        var rejected = false
        do {
            _ = try WeChatArchiveV1MediaStore(root: archiveRoot)
        } catch {
            rejected = true
        }

        try expectTrue(rejected)
        try expectFalse(FileManager.default.fileExists(atPath: outsideRoot.appending(path: "images").path()))
    }

    func testArchiveImportRejectsAnySourceAndDestinationPathOverlap() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let accountRoot = directory.appending(path: "Account")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        let importer = WeChatArchiveV1Importer(imageKeyProvider: FixtureImageKeyProvider(materials: []))

        try expectThrows(ArchiveError.invalidInput) {
            _ = try importer.importArchive(
                plainSQLiteRoot: exportRoot,
                accountRoot: accountRoot,
                destinationRoot: exportRoot.appending(path: "WeChatArchive"),
                options: .all
            )
        }
        try expectThrows(ArchiveError.invalidInput) {
            _ = try importer.importArchive(
                plainSQLiteRoot: exportRoot,
                accountRoot: accountRoot,
                destinationRoot: accountRoot.appending(path: "WeChatArchive"),
                options: .all
            )
        }
    }

    func testArchiveV1ImporterUsesSQLiteRowIDWhenLocalIDsRepeat() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let accountRoot = directory.appending(path: "Account")
        let tableName = "Msg_0123456789abcdef0123456789abcdef"
        let messageDatabase = exportRoot.appending(path: "message/message_0.db")
        try FileManager.default.createDirectory(at: messageDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: messageDatabase, sql: """
            CREATE TABLE \(tableName) (local_id INTEGER, local_type INTEGER, create_time INTEGER, message_content TEXT);
            INSERT INTO \(tableName) VALUES (10, 1, 100, 'synthetic first');
            INSERT INTO \(tableName) VALUES (10, 1, 101, 'synthetic second');
            """)
        let destination = directory.appending(path: "WeChatArchive")
        let importer = WeChatArchiveV1Importer(imageKeyProvider: FixtureImageKeyProvider(materials: []))

        let summary = try importer.importArchive(
            plainSQLiteRoot: exportRoot,
            accountRoot: accountRoot,
            destinationRoot: destination,
            options: .all
        )
        let database = try WeChatArchiveV1Database(url: destination.appending(path: "archive.sqlite"))

        try expectEqual(summary.messagesImported, 2)
        try expectEqual(try database.messageCount(), 2)
    }

    func testContactAdapterUsesRemarkThenGroupNicknameAndValidatesAccountIdentity() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let contactDB = exportRoot.appending(path: "contact/contact.db")
        let ftsDB = exportRoot.appending(path: "contact/contact_fts.db")
        let accountRoot = directory.appending(path: "wxid_fixtureowner_c14c")
        try FileManager.default.createDirectory(at: contactDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: contactDB, sql: """
            CREATE TABLE contact (id INTEGER, username TEXT, local_type INTEGER, alias TEXT, remark TEXT, nick_name TEXT);
            INSERT INTO contact VALUES (1, 'wxid_fixtureowner', 1, NULL, NULL, 'Owner');
            INSERT INTO contact VALUES (2, 'fixture-contact', 1, 'Alias', 'Remark', 'Nickname');
            INSERT INTO contact VALUES (3, 'fixture-group@chatroom', 1, NULL, NULL, 'Group title');
            CREATE TABLE chatroom_member (room_id INTEGER, member_id INTEGER);
            INSERT INTO chatroom_member VALUES (3, 2);
            """)
        try createPlainSQLiteDatabase(at: ftsDB, sql: """
            CREATE VIRTUAL TABLE chatroom_member_fts_v3 USING fts4(a_group_remark, room_id, member_id);
            INSERT INTO chatroom_member_fts_v3 VALUES ('Group nickname', 3, 2);
            """)

        let result = try WeChatContactAdapter().read(plainSQLiteRoot: exportRoot, accountRoot: accountRoot)
        let contact = try XCTUnwrap(result.contacts.first { $0.sourceIdentity == "fixture-contact" })
        let member = try XCTUnwrap(result.groupMembers.first)

        try expectEqual(result.ownerSourceIdentity, "wxid_fixtureowner")
        try expectEqual(contact.displayName, "Remark")
        try expectEqual(member.displayName, "Group nickname")
        try expectEqual(member.groupNickname, "Group nickname")
    }

    func testSourceReaderResolvesConversationAndIntegerSenderIdentities() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let conversation = "fixture-contact"
        let tableName = "Msg_\(fixtureMD5Hex(conversation))"
        let database = exportRoot.appending(path: "message/message_0.db")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: database, sql: """
            CREATE TABLE Name2Id (user_name TEXT);
            INSERT INTO Name2Id (rowid, user_name) VALUES (7, '\(conversation)');
            INSERT INTO Name2Id (rowid, user_name) VALUES (8, 'wxid_fixtureowner');
            CREATE TABLE \(tableName) (local_id INTEGER, local_type INTEGER, create_time INTEGER, real_sender_id INTEGER, message_content TEXT);
            INSERT INTO \(tableName) VALUES (1, 1, 100, 8, 'synthetic');
            """)
        var record: ArchiveV1SourceMessage?

        _ = try WeChatArchiveV1SourceReader().stream(exportRoot: exportRoot, limit: nil) { row in record = row; return true }

        try expectEqual(record?.conversationSourceIdentity, conversation)
        try expectEqual(record?.senderSourceIdentity, "wxid_fixtureowner")
    }

    func testArchiveViewerPaginatesMoreThanOneHundredConversationsByRecentMessage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "WeChatArchive")
        let database = try WeChatArchiveV1Database(url: root.appending(path: "archive.sqlite"))
        for index in 0..<150 {
            let conversation = try database.upsertConversation(sourceIdentity: "fixture-conversation-\(index)", type: .private, displayName: "Conversation \(index)")
            _ = try database.insertMessage(
                conversationID: conversation, sourceDatabase: "message/message_0.db", sourceTable: "fixture", sourceSQLiteRowID: Int64(index + 1), sourceLocalID: nil, sourceServerID: nil, timestamp: Int64(index), senderSourceID: nil, receiverSourceID: nil, rawLocalType: 1, normalizedType: .text, textContent: "synthetic", replySourceID: nil, sourceSequence: Int64(index), sourceValues: [:]
            )
        }
        database.close()
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: root)

        let first = try viewer.conversationPage(limit: 100)
        let second = try viewer.conversationPage(offset: first.items.count, limit: 100)

        try expectEqual(first.items.count, 100)
        try expectTrue(first.hasMore)
        try expectEqual(second.items.count, 50)
        try expectFalse(second.hasMore)
        try expectEqual(first.items.first?.title, "Conversation 149")
    }

    func testArchiveViewerStopsShowingLoadMoreAtExactlyOneHundredMessages() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "WeChatArchive")
        let database = try WeChatArchiveV1Database(url: root.appending(path: "archive.sqlite"))
        let conversation = try database.upsertConversation(sourceIdentity: "fixture-conversation")
        for index in 0..<100 {
            _ = try database.insertMessage(
                conversationID: conversation, sourceDatabase: "message/message_0.db", sourceTable: "fixture", sourceSQLiteRowID: Int64(index + 1), sourceLocalID: nil, sourceServerID: nil, timestamp: Int64(index), senderSourceID: nil, receiverSourceID: nil, rawLocalType: 1, normalizedType: .text, textContent: "synthetic", replySourceID: nil, sourceSequence: Int64(index), sourceValues: [:]
            )
        }
        database.close()
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: root)

        let page = try viewer.messagePage(conversationID: conversation, limit: 100)

        try expectEqual(page.items.count, 100)
        try expectFalse(page.hasMore)
    }

    func testArchiveViewerLoadsRecentMessagesFirstButReturnsEachPageInTimelineOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "WeChatArchive")
        let database = try WeChatArchiveV1Database(url: root.appending(path: "archive.sqlite"))
        let conversation = try database.upsertConversation(sourceIdentity: "fixture-conversation", type: .private, displayName: "Fixture")
        for index in 0..<150 {
            _ = try database.insertMessage(
                conversationID: conversation, sourceDatabase: "message/message_0.db", sourceTable: "fixture", sourceSQLiteRowID: Int64(index + 1), sourceLocalID: nil, sourceServerID: nil, timestamp: Int64(index), senderSourceID: nil, receiverSourceID: nil, rawLocalType: 1, normalizedType: .text, textContent: "message \(index)", replySourceID: nil, sourceSequence: Int64(index), sourceValues: [:]
            )
        }
        database.close()
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: root)

        let latest = try viewer.recentMessagePage(conversationID: conversation, limit: 100)
        let older = try viewer.recentMessagePage(conversationID: conversation, offset: 100, limit: 100)

        try expectEqual(latest.items.count, 100)
        try expectTrue(latest.hasMore)
        try expectEqual(latest.items.first?.textContent, "message 50")
        try expectEqual(latest.items.last?.textContent, "message 149")
        try expectEqual(older.items.count, 50)
        try expectFalse(older.hasMore)
        try expectEqual(older.items.first?.textContent, "message 0")
        try expectEqual(older.items.last?.textContent, "message 49")
    }

    func testArchiveViewerProvidesPrivateLastMessageSummaryFromArchiveOnly() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "WeChatArchive")
        let database = try WeChatArchiveV1Database(url: root.appending(path: "archive.sqlite"))
        let conversation = try database.upsertConversation(sourceIdentity: "fixture-conversation", type: .private, displayName: "Fixture")
        _ = try database.insertMessage(
            conversationID: conversation, sourceDatabase: "message/message_0.db", sourceTable: "fixture", sourceSQLiteRowID: 1, sourceLocalID: nil, sourceServerID: nil, timestamp: 1, senderSourceID: nil, receiverSourceID: nil, rawLocalType: 1, normalizedType: .text, textContent: "first\nsecond", replySourceID: nil, sourceSequence: 1, sourceValues: [:]
        )
        database.close()

        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: root)
        let item = try XCTUnwrap(try viewer.listConversations().first)

        try expectEqual(item.lastMessagePreview, "first second")
    }

    func testArchiveImportPersistsGroupSenderAndMessageDirection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let accountRoot = directory.appending(path: "wxid_fixtureowner_c14c")
        let messageDB = exportRoot.appending(path: "message/message_0.db")
        let contactDB = exportRoot.appending(path: "contact/contact.db")
        let ftsDB = exportRoot.appending(path: "contact/contact_fts.db")
        try FileManager.default.createDirectory(at: messageDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contactDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        let group = "fixture-group@chatroom"
        let groupTable = "Msg_\(fixtureMD5Hex(group))"
        try createPlainSQLiteDatabase(at: messageDB, sql: """
            CREATE TABLE Name2Id (user_name TEXT);
            INSERT INTO Name2Id (rowid, user_name) VALUES (1, '\(group)');
            INSERT INTO Name2Id (rowid, user_name) VALUES (2, 'wxid_fixtureowner');
            INSERT INTO Name2Id (rowid, user_name) VALUES (3, 'fixture-member');
            CREATE TABLE \(groupTable) (local_id INTEGER, local_type INTEGER, create_time INTEGER, real_sender_id INTEGER, message_content TEXT);
            INSERT INTO \(groupTable) VALUES (1, 1, 100, 2, 'outgoing synthetic');
            INSERT INTO \(groupTable) VALUES (2, 1, 101, 3, 'incoming synthetic');
            """)
        try createPlainSQLiteDatabase(at: contactDB, sql: """
            CREATE TABLE contact (id INTEGER, username TEXT, local_type INTEGER, alias TEXT, remark TEXT, nick_name TEXT);
            INSERT INTO contact VALUES (1, 'wxid_fixtureowner', 1, NULL, NULL, 'Owner');
            INSERT INTO contact VALUES (2, 'fixture-member', 1, NULL, NULL, 'Member');
            INSERT INTO contact VALUES (3, '\(group)', 1, NULL, NULL, 'Group title');
            CREATE TABLE chatroom_member (room_id INTEGER, member_id INTEGER);
            INSERT INTO chatroom_member VALUES (3, 2);
            """)
        try createPlainSQLiteDatabase(at: ftsDB, sql: """
            CREATE VIRTUAL TABLE chatroom_member_fts_v3 USING fts4(a_group_remark, room_id, member_id);
            INSERT INTO chatroom_member_fts_v3 VALUES ('Group nickname', 3, 2);
            """)
        let destination = directory.appending(path: "WeChatArchive")
        _ = try WeChatArchiveV1Importer(imageKeyProvider: FixtureImageKeyProvider(materials: [])).importArchive(plainSQLiteRoot: exportRoot, accountRoot: accountRoot, destinationRoot: destination, options: .all)
        try FileManager.default.removeItem(at: exportRoot)
        try FileManager.default.removeItem(at: accountRoot)
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: destination)
        let conversation = try XCTUnwrap(try viewer.listConversations().first)
        let messages = try viewer.messages(conversationID: conversation.id)

        try expectEqual(conversation.type, .group)
        try expectEqual(conversation.title, "Group title")
        try expectEqual(messages.map(\.direction), [.outgoing, .incoming])
        try expectEqual(messages.last?.senderDisplayName, "Group nickname")
    }

    func testArchiveImportUsesObservedSystemTypeWithoutTreatingUnknownAsSystem() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let accountRoot = directory.appending(path: "Account")
        let databaseURL = exportRoot.appending(path: "message/message_0.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        let tableName = "Msg_0123456789abcdef0123456789abcdef"
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE \(tableName) (local_id INTEGER, local_type INTEGER, create_time INTEGER, message_content TEXT);
            INSERT INTO \(tableName) VALUES (1, 10000, 100, 'synthetic system');
            INSERT INTO \(tableName) VALUES (2, 49, 101, 'synthetic unknown');
            """)
        let destination = directory.appending(path: "WeChatArchive")
        _ = try WeChatArchiveV1Importer(imageKeyProvider: FixtureImageKeyProvider(materials: [])).importArchive(
            plainSQLiteRoot: exportRoot, accountRoot: accountRoot, destinationRoot: destination, options: .all
        )
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: destination)
        let conversation = try XCTUnwrap(try viewer.listConversations().first)
        let messages = try viewer.messages(conversationID: conversation.id)

        try expectEqual(messages.map(\.direction), [.system, .unknown])
        try expectEqual(messages.map(\.normalizedType), [.unknown, .unknown])
    }

    func testArchiveMediaCopyFailurePreservesMessagesAndContinuesImport() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        let destination = directory.appending(path: "WeChatArchive")
        let importer = WeChatArchiveV1Importer(
            imageKeyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: fixture.imageKey, xorKey: 0x88)]),
            mediaStoreFactory: { _ in FailingArchiveV1MediaStore() }
        )

        let summary = try importer.importArchive(
            plainSQLiteRoot: fixture.exportRoot, accountRoot: fixture.accountRoot, destinationRoot: destination, options: .all
        )
        let reconstruction = try WeChatArchiveV1Database(url: destination.appending(path: "archive.sqlite")).reconstruction()

        try expectEqual(summary.messagesImported, 5)
        try expectTrue(reconstruction.contains(where: { $0.mediaStatuses.contains(.rawCopyFailed) }))
    }

    func testArchiveIndexesRawMediaWhenDecodedCopyFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        let destination = directory.appending(path: "WeChatArchive")
        let importer = WeChatArchiveV1Importer(
            imageKeyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: fixture.imageKey, xorKey: 0x88)]),
            mediaStoreFactory: { _ in RawOnlyArchiveV1MediaStore() }
        )

        _ = try importer.importArchive(
            plainSQLiteRoot: fixture.exportRoot, accountRoot: fixture.accountRoot, destinationRoot: destination, options: .all
        )
        let database = try WeChatArchiveV1Database(url: destination.appending(path: "archive.sqlite"))
        let reconstruction = try database.reconstruction()
        let mediaRows = try database.mediaRows()

        try expectTrue(reconstruction.contains(where: { $0.mediaStatuses.contains(.decodedCopyFailed) }))
        try expectTrue(mediaRows.contains(where: { $0.rawPath != nil && $0.rawHash != nil && $0.rawPath?.hasPrefix("media/") == true }))
    }

    func testArchiveImportsVerifiedLocalAvatarsForPrivateGroupAndOutgoingMessages() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let accountRoot = directory.appending(path: "wxid_fixtureowner_c14c")
        let messageDB = exportRoot.appending(path: "message/message_0.db")
        let contactDB = exportRoot.appending(path: "contact/contact.db")
        let groupFTSDB = exportRoot.appending(path: "contact/contact_fts.db")
        let avatarDB = exportRoot.appending(path: "head_image/head_image.db")
        try FileManager.default.createDirectory(at: messageDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contactDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: avatarDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        let privateIdentity = "fixture-contact"
        let groupIdentity = "fixture-group@chatroom"
        let privateTable = "Msg_\(fixtureMD5Hex(privateIdentity))"
        let groupTable = "Msg_\(fixtureMD5Hex(groupIdentity))"
        try createPlainSQLiteDatabase(at: messageDB, sql: """
            CREATE TABLE Name2Id (user_name TEXT);
            INSERT INTO Name2Id (rowid, user_name) VALUES (1, '\(privateIdentity)');
            INSERT INTO Name2Id (rowid, user_name) VALUES (2, 'wxid_fixtureowner');
            INSERT INTO Name2Id (rowid, user_name) VALUES (3, '\(groupIdentity)');
            CREATE TABLE \(privateTable) (local_id INTEGER, local_type INTEGER, create_time INTEGER, real_sender_id INTEGER, message_content TEXT);
            INSERT INTO \(privateTable) VALUES (1, 1, 100, 1, 'private synthetic');
            CREATE TABLE \(groupTable) (local_id INTEGER, local_type INTEGER, create_time INTEGER, real_sender_id INTEGER, message_content TEXT);
            INSERT INTO \(groupTable) VALUES (1, 1, 101, 1, 'group incoming');
            INSERT INTO \(groupTable) VALUES (2, 1, 102, 2, 'group outgoing');
            """)
        try createPlainSQLiteDatabase(at: contactDB, sql: """
            CREATE TABLE contact (id INTEGER, username TEXT, local_type INTEGER, alias TEXT, remark TEXT, nick_name TEXT, big_head_url TEXT, small_head_url TEXT);
            INSERT INTO contact VALUES (1, 'wxid_fixtureowner', 1, NULL, NULL, 'Owner', 'https://fixture.invalid/owner-big', 'https://fixture.invalid/owner-small');
            INSERT INTO contact VALUES (2, '\(privateIdentity)', 1, NULL, NULL, 'Contact', 'https://fixture.invalid/contact-big', 'https://fixture.invalid/contact-small');
            INSERT INTO contact VALUES (3, '\(groupIdentity)', 1, NULL, NULL, 'Group', NULL, 'https://fixture.invalid/group-small');
            CREATE TABLE chatroom_member (room_id INTEGER, member_id INTEGER);
            INSERT INTO chatroom_member VALUES (3, 2);
            """)
        try createPlainSQLiteDatabase(at: groupFTSDB, sql: """
            CREATE VIRTUAL TABLE chatroom_member_fts_v3 USING fts4(a_group_remark, room_id, member_id);
            INSERT INTO chatroom_member_fts_v3 VALUES ('Group member', 3, 2);
            """)
        let avatarHex = syntheticPNGData().map { String(format: "%02x", $0) }.joined()
        try createPlainSQLiteDatabase(at: avatarDB, sql: """
            CREATE TABLE head_image (username TEXT PRIMARY KEY, md5 TEXT, image_buffer BLOB, update_time INTEGER);
            INSERT INTO head_image VALUES ('wxid_fixtureowner', NULL, X'\(avatarHex)', 1);
            INSERT INTO head_image VALUES ('\(privateIdentity)', NULL, X'\(avatarHex)', 1);
            INSERT INTO head_image VALUES ('\(groupIdentity)', NULL, X'\(avatarHex)', 1);
            """)

        let destination = directory.appending(path: "WeChatArchive")
        _ = try WeChatArchiveV1Importer(imageKeyProvider: FixtureImageKeyProvider(materials: [])).importArchive(
            plainSQLiteRoot: exportRoot, accountRoot: accountRoot, destinationRoot: destination, options: .all
        )
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: destination)
        let conversations = try viewer.listConversations()
        let privateConversation = try XCTUnwrap(conversations.first { $0.title == "Contact" })
        let groupConversation = try XCTUnwrap(conversations.first { $0.title == "Group" })
        let privateMessage = try XCTUnwrap(try viewer.messages(conversationID: privateConversation.id).first)
        let groupMessages = try viewer.messages(conversationID: groupConversation.id)

        try expectTrue(privateConversation.avatar != nil)
        try expectTrue(groupConversation.avatar != nil)
        try expectEqual(privateConversation.lastMessagePreview, "private synthetic")
        try expectTrue(privateMessage.avatar != nil)
        try expectTrue(groupMessages.first?.avatar != nil)
        try expectTrue(groupMessages.last?.avatar != nil)
        let validation = try WeChatArchiveV1Validator().validate(at: destination)
        try expectTrue(validation.avatarHashesPassed)
        try expectTrue(validation.orphanFilesPassed)
        try expectEqual(validation.avatarAssetCount, 3)

        let orphan = destination.appending(path: "media/avatars/contacts/orphan.bin")
        try Data([0x00]).write(to: orphan)
        let validationWithOrphan = try WeChatArchiveV1Validator().validate(at: destination)
        try expectFalse(validationWithOrphan.orphanFilesPassed)
    }

    func testSilkProcessDecoderTimesOutAndCancellationStopsTheProcess() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "looping-decoder")
        try Data("#!/bin/sh\nwhile :; do :; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path())
        let silk = Data("#!SILK_V3\u{0}".utf8)

        try expectThrows(VoiceDecoderError.timeout) {
            _ = try SilkProcessVoiceDecoder(executableURL: executable, timeout: 0.02).decode(silk)
        }
        try expectThrows(VoiceDecoderError.cancelled) {
            _ = try SilkProcessVoiceDecoder(executableURL: executable, timeout: 1).decode(silk, shouldCancel: { true })
        }
    }

    func testCompressedTextMessageAdapterDecodesRevokeLocationAndQuoteReplyFromZstdXML() throws {
        let revokeXML = "<sysmsg type=\"revokemsg\"><revokemsg><session>fixture</session><oldmsgid>1</oldmsgid><msgid>2</msgid><content>\"Fixture User\" 撤回了一条消息</content><revoketime>1700000000</revoketime></revokemsg></sysmsg>"
        let revokeText = WeChatCompressedTextMessageAdapter().textContent(
            from: ["message_content": .blob(try zstdCompress(revokeXML))],
            rawType: 10_000
        )
        XCTAssertEqual(revokeText, "\"Fixture User\" 撤回了一条消息")

        let locationXML = "<msg><location x=\"1.0\" y=\"2.0\" label=\"Fixture Address\" poiname=\"Fixture POI\"/></msg>"
        let locationText = WeChatCompressedTextMessageAdapter().textContent(
            from: ["message_content": .blob(try zstdCompress(locationXML))],
            rawType: 48
        )
        XCTAssertEqual(locationText, "[位置] Fixture POI")

        let quoteXML = "<msg><appmsg appid=\"\" sdkver=\"0\"><title>Fixture reply text</title><type>57</type><refermsg><type>1</type><svrid>1</svrid><fromusr>fixture</fromusr><chatusr>fixture</chatusr><displayname>Fixture Sender</displayname><content>Fixture quoted content</content></refermsg></appmsg></msg>"
        let quoteRawType = Int64(bitPattern: (UInt64(57) << 32) | 49)
        let quoteText = WeChatCompressedTextMessageAdapter().textContent(
            from: ["message_content": .blob(try zstdCompress("fixture_wxid:\n" + quoteXML))],
            rawType: quoteRawType
        )
        XCTAssertEqual(quoteText, "引用「Fixture Sender」：Fixture quoted content\nFixture reply text")

        let linkXML = "<msg><appmsg appid=\"\" sdkver=\"0\"><title>Fixture Link Title</title><type>5</type></appmsg></msg>"
        let linkRawType = Int64(bitPattern: (UInt64(5) << 32) | 49)
        let linkText = WeChatCompressedTextMessageAdapter().textContent(
            from: ["message_content": .blob(try zstdCompress(linkXML))],
            rawType: linkRawType
        )
        XCTAssertEqual(linkText, "[链接] Fixture Link Title")
    }

    func testCompressedTextMessageAdapterReplacesQuotedImageXMLWithReadableSummary() throws {
        let quoteXML = "<msg><appmsg><title>Fixture reply text</title><refermsg><type>3</type><displayname>Fixture Sender</displayname><content>&lt;?xml version=\"1.0\"?&gt;&lt;msg&gt;&lt;img aeskey=\"fixture\" md5=\"fixture\"/&gt;&lt;/msg&gt;</content></refermsg></appmsg></msg>"
        let quoteRawType = Int64(bitPattern: (UInt64(57) << 32) | 49)

        let quoteText = WeChatCompressedTextMessageAdapter().textContent(
            from: ["message_content": .blob(try zstdCompress(quoteXML))],
            rawType: quoteRawType
        )

        XCTAssertEqual(quoteText, "引用「Fixture Sender」：[图片]\nFixture reply text")
        XCTAssertFalse(quoteText?.contains("<?xml") ?? true)
        XCTAssertFalse(quoteText?.contains("aeskey") ?? true)
    }

    func testQuotedMessagePresentationFormatsLegacyXMLAndPlainTextReplies() {
        let imageQuote = "引用「Fixture Sender」：<?xml version=\"1.0\"?><msg><img aeskey=\"fixture\" md5=\"fixture\"/></msg>\nFixture reply text"
        let imagePresentation = ArchiveMessagePresentationFormatter.quotedPresentation(for: imageQuote)

        XCTAssertEqual(imagePresentation?.quotedSender, "Fixture Sender")
        XCTAssertEqual(imagePresentation?.quotedSummary, "[图片]")
        XCTAssertEqual(imagePresentation?.replyText, "Fixture reply text")
        XCTAssertFalse(imagePresentation?.displayText.contains("<?xml") ?? true)
        XCTAssertFalse(imagePresentation?.displayText.contains("aeskey") ?? true)

        let nestedXMLQuote = "引用「Fixture Sender」：<?xml version=\"1.0\"?><msg><appmsg><title>Fixture share</title></appmsg></msg>\nFixture reply text"
        let nestedXMLPresentation = ArchiveMessagePresentationFormatter.quotedPresentation(for: nestedXMLQuote)
        XCTAssertEqual(nestedXMLPresentation?.quotedSummary, "[分享] Fixture share")
        XCTAssertEqual(nestedXMLPresentation?.replyText, "Fixture reply text")

        let malformedXMLQuote = "引用「Fixture Sender」：<?xml version=\"1.0\"?><msg><img aeskey=\"fixture\">\nFixture reply text"
        let malformedXMLPresentation = ArchiveMessagePresentationFormatter.quotedPresentation(for: malformedXMLQuote)
        XCTAssertEqual(malformedXMLPresentation?.quotedSummary, "[图片]")
        XCTAssertTrue(malformedXMLPresentation?.replyText.isEmpty ?? false)
        XCTAssertFalse(malformedXMLPresentation?.displayText.contains("aeskey") ?? true)

        let plainQuote = "引用「Fixture Sender」：Fixture quoted text\nFixture reply body"
        let plainPresentation = ArchiveMessagePresentationFormatter.quotedPresentation(for: plainQuote)
        XCTAssertEqual(plainPresentation?.quotedSummary, "Fixture quoted text")
        XCTAssertEqual(plainPresentation?.replyText, "Fixture reply body")

        // The reply body itself may contain the same closing-tag substring as
        // the quoted XML's root element (e.g. a technical discussion). The
        // document boundary must end at the FIRST matching close tag, not the
        // last, or the reply gets truncated at its own embedded substring.
        let replyContainingCloseTagQuote = "引用「Fixture Sender」：<msg><img aeskey=\"fixture\"/></msg>\ncheck out this </msg> tag"
        let replyContainingCloseTagPresentation = ArchiveMessagePresentationFormatter.quotedPresentation(for: replyContainingCloseTagQuote)
        XCTAssertEqual(replyContainingCloseTagPresentation?.quotedSummary, "[图片]")
        XCTAssertEqual(replyContainingCloseTagPresentation?.replyText, "check out this </msg> tag")
    }

    func testQuotedMessageSummaryRecognizesReferenceTypesAndSafeXMLFallbacks() {
        XCTAssertEqual(ArchiveMessagePresentationFormatter.quotedMessageSummary(referType: "1", quotedContent: "  Fixture\nquoted\ttext  "), "Fixture quoted text")
        XCTAssertEqual(ArchiveMessagePresentationFormatter.quotedMessageSummary(referType: "3", quotedContent: "ignored"), "[图片]")
        XCTAssertEqual(ArchiveMessagePresentationFormatter.quotedMessageSummary(referType: "34", quotedContent: "ignored"), "[语音]")
        XCTAssertEqual(ArchiveMessagePresentationFormatter.quotedMessageSummary(referType: "43", quotedContent: "ignored"), "[视频]")
        XCTAssertEqual(ArchiveMessagePresentationFormatter.quotedMessageSummary(referType: "47", quotedContent: "ignored"), "[表情]")
        XCTAssertEqual(ArchiveMessagePresentationFormatter.quotedMessageSummary(referType: "49", quotedContent: "ignored"), "[分享]")
        XCTAssertEqual(ArchiveMessagePresentationFormatter.quotedMessageSummary(referType: nil, quotedContent: "<msg><location label=\"fixture\"/></msg>"), "[位置]")
        XCTAssertEqual(ArchiveMessagePresentationFormatter.quotedMessageSummary(referType: nil, quotedContent: "<msg><appmsg><title>Fixture share</title></appmsg></msg>"), "[分享] Fixture share")
        XCTAssertEqual(ArchiveMessagePresentationFormatter.quotedMessageSummary(referType: nil, quotedContent: "<msg><unknown secret=\"fixture\"/></msg>"), "[引用消息]")
    }

    func testCompressedTextMessageAdapterRecoversGroupTextAndFallsThroughOnUnrecognizedTypes() throws {
        let text = WeChatCompressedTextMessageAdapter().textContent(
            from: ["message_content": .blob(try zstdCompress("fixture_wxid:\nFixture plain text message"))],
            rawType: 1
        )
        XCTAssertEqual(text, "Fixture plain text message")

        // An unrecognized sysmsg subtype (not revokemsg) must fall through
        // to nil so the caller leaves the message `.unknown`, never guessed.
        let otherSysmsgText = WeChatCompressedTextMessageAdapter().textContent(
            from: ["message_content": .blob(try zstdCompress("<sysmsg type=\"other\"><other><content>fixture</content></other></sysmsg>"))],
            rawType: 10_000
        )
        XCTAssertNil(otherSysmsgText)

        // Stickers (local_type 47) are not yet parsed by this adapter and
        // must stay nil so the message remains `.unknown`.
        let stickerText = WeChatCompressedTextMessageAdapter().textContent(
            from: ["message_content": .blob(try zstdCompress("<msg><emoji md5=\"fixture\" cdnurl=\"fixture\"/></msg>"))],
            rawType: 47
        )
        XCTAssertNil(stickerText)

        XCTAssertNil(WeChatCompressedTextMessageAdapter().textContent(from: [:], rawType: 1))
    }

    func testZstdPayloadDecompressorRejectsNonZstdAndOversizedInput() {
        XCTAssertNil(ZstdPayloadDecompressor.decompress(Data("not zstd".utf8)))
        XCTAssertNil(ZstdPayloadDecompressor.decompress(Data()))
    }

    func testVideoAndVoiceAdaptersUseValidatedBoundedMappings() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        var video: ArchiveV1SourceMessage?
        var voice: ArchiveV1SourceMessage?
        _ = try WeChatArchiveV1SourceReader().stream(exportRoot: fixture.exportRoot, limit: nil) { row in
            switch row.values["local_type"] {
            case .integer(43): video = row
            case .integer(34): voice = row
            default: break
            }
            return true
        }

        let videoInputs = try WeChatVideoMessageAdapter().variants(
            message: try XCTUnwrap(video), exportRoot: fixture.exportRoot, accountRoot: fixture.accountRoot
        )
        let voiceInputs = try WeChatVoiceMessageAdapter().variants(message: try XCTUnwrap(voice), exportRoot: fixture.exportRoot)

        if case let .integer(videoType)? = video?.values["local_type"] { try expectEqual(rawTypeLow32(videoType), 43) } else { throw TestFailure(description: "Synthetic video type missing") }
        if case let .integer(voiceType)? = voice?.values["local_type"] { try expectEqual(rawTypeLow32(voiceType), 34) } else { throw TestFailure(description: "Synthetic voice type missing") }
        try expectTrue(videoInputs.contains { $0.variant == .play && $0.rawFileURL != nil && $0.status == .rawArchived })
        try expectTrue(videoInputs.contains { $0.variant == .raw && $0.status == .missing })
        try expectEqual(voiceInputs.first?.sourceFormat, "silk")
        try expectEqual(voiceInputs.first?.rawData, Data([0x02, 0x23, 0x21, 0x53, 0x49, 0x4C, 0x4B, 0x5F, 0x56, 0x33, 0x30, 0x00, 0x00]))
        try expectEqual(VoiceFormatDetector().detect(voiceInputs.first?.rawData ?? Data()), .silk)
    }

    func testSilkDecoderOutputIsStoredAsWAVWithDuration() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        var voice: ArchiveV1SourceMessage?
        _ = try WeChatArchiveV1SourceReader().stream(exportRoot: fixture.exportRoot, limit: nil) { row in
            if case .integer(34)? = row.values["local_type"] { voice = row }
            return true
        }
        let pcm = Data(repeating: 0, count: 960)
        let inputs = try WeChatVoiceMessageAdapter(decoder: FixtureVoiceDecoder(pcm: pcm, sampleRate: 24_000)).variants(
            message: try XCTUnwrap(voice), exportRoot: fixture.exportRoot
        )
        let voiceInput = try XCTUnwrap(inputs.first)

        try expectEqual(voiceInput.status, .decoded)
        try expectEqual(voiceInput.decodedFormat, "wav")
        try expectEqual(voiceInput.duration, 0.02)
        try expectEqual(voiceInput.decodedData?.prefix(4), Data("RIFF".utf8))
        try expectEqual(voiceInput.decodedData?[8..<12], Data("WAVE".utf8))
    }

    func testUnavailableSilkDecoderPreservesRawVoice() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        var voice: ArchiveV1SourceMessage?
        _ = try WeChatArchiveV1SourceReader().stream(exportRoot: fixture.exportRoot, limit: nil) { row in
            if case .integer(34)? = row.values["local_type"] { voice = row }
            return true
        }

        let inputs = try WeChatVoiceMessageAdapter(decoder: UnavailableVoiceDecoder()).variants(message: try XCTUnwrap(voice), exportRoot: fixture.exportRoot)

        try expectEqual(inputs.first?.status, .decodeUnsupported)
        try expectTrue(inputs.first?.rawData != nil)
        try expectEqual(inputs.first?.decodedData, nil)
    }

    func testArchiveViewerRejectsSymlinkedMediaEvenWhenPathStaysWithinArchive() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveRoot = directory.appending(path: "WeChatArchive")
        let database = try WeChatArchiveV1Database(url: archiveRoot.appending(path: "archive.sqlite"))
        let conversation = try database.upsertConversation(sourceIdentity: "Msg_0123456789abcdef0123456789abcdef")
        let message = try database.insertMessage(
            conversationID: conversation, sourceDatabase: "message/message_0.db", sourceTable: "Msg_0123456789abcdef0123456789abcdef", sourceSQLiteRowID: 1, sourceLocalID: 1, sourceServerID: nil, timestamp: 1, senderSourceID: nil, receiverSourceID: nil, rawLocalType: 43, normalizedType: .video, textContent: nil, replySourceID: nil, sourceSequence: 1, sourceValues: [:]
        )
        _ = try database.insertMediaAsset(
            messageID: message.id, mediaType: .video, variant: .play, status: .rawArchived, sourceFormat: "mp4", decodedFormat: nil, rawArchivePath: "media/video/play/item.mp4", decodedArchivePath: nil, rawSize: 1, decodedSize: nil, width: nil, height: nil, rawSHA256: nil, decodedSHA256: nil, sourceFileBase: nil
        )
        database.close()
        let outside = directory.appending(path: "outside.mp4")
        try Data([0x00]).write(to: outside)
        let mediaDirectory = archiveRoot.appending(path: "media/video/play")
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: mediaDirectory.appending(path: "item.mp4"), withDestinationURL: outside)

        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: archiveRoot)
        let timeline = try viewer.messages(conversationID: conversation)
        let media = try XCTUnwrap(timeline.first?.media.first)

        try expectEqual(viewer.mediaURL(for: media, preferDecoded: false), nil)
    }

    func testVideoLocatorChecksCurrentMonthBeforeAdjacentFallback() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountRoot = directory.appending(path: "Account")
        let fileBase = "0123456789abcdef0123456789abcdef"
        let timestamp: Int64 = 1_738_368_000
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"
        let current = formatter.string(from: date)
        let previous = formatter.string(from: try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: date)))
        let currentDirectory = accountRoot.appending(path: "msg/video/\(current)")
        let previousDirectory = accountRoot.appending(path: "msg/video/\(previous)")
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previousDirectory, withIntermediateDirectories: true)
        let currentFile = currentDirectory.appending(path: "\(fileBase).mp4")
        try Data([0x00]).write(to: currentFile)
        try Data([0x01]).write(to: previousDirectory.appending(path: "\(fileBase).mp4"))

        let assets = try WeChatVideoAttachmentLocator().locate(accountRoot: accountRoot, fileBase: fileBase, createTime: timestamp)

        try expectEqual(assets.playURL, currentFile)
    }

    func testVideoLocatorUsesPreviousMonthAsBoundedFallback() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountRoot = directory.appending(path: "Account")
        let fileBase = "0123456789abcdef0123456789abcdef"
        let timestamp: Int64 = 1_738_368_000
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"
        let previous = formatter.string(from: try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: date)))
        let previousDirectory = accountRoot.appending(path: "msg/video/\(previous)")
        try FileManager.default.createDirectory(at: previousDirectory, withIntermediateDirectories: true)
        let previousFile = previousDirectory.appending(path: "\(fileBase).mp4")
        try Data([0x01]).write(to: previousFile)

        let assets = try WeChatVideoAttachmentLocator().locate(accountRoot: accountRoot, fileBase: fileBase, createTime: timestamp)

        try expectEqual(assets.playURL, previousFile)
    }

    func testVideoAndVoiceMissingMediaPreserveMessageImports() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        let videoDirectory = fixture.accountRoot.appending(path: "msg/video/2025-02")
        try FileManager.default.removeItem(at: videoDirectory)
        try FileManager.default.removeItem(at: fixture.exportRoot.appending(path: "message/media_0.db"))
        let destination = directory.appending(path: "WeChatArchive")
        let importer = WeChatArchiveV1Importer(imageKeyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: fixture.imageKey, xorKey: 0x88)]))

        let summary = try importer.importArchive(plainSQLiteRoot: fixture.exportRoot, accountRoot: fixture.accountRoot, destinationRoot: destination, options: .all)
        let reconstructed = try WeChatArchiveV1Database(url: destination.appending(path: "archive.sqlite")).reconstruction()

        try expectEqual(summary.messagesImported, 5)
        try expectTrue(reconstructed.contains { $0.normalizedType == .video && $0.mediaStatuses.allSatisfy { $0 == .missing } })
        try expectTrue(reconstructed.contains { $0.normalizedType == .voice && $0.mediaStatuses == [.missing] })
    }

    func testArchiveViewerReadsPagedTimelineWithoutWeChatSources() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        let destination = directory.appending(path: "WeChatArchive")
        let importer = WeChatArchiveV1Importer(imageKeyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: fixture.imageKey, xorKey: 0x88)]))
        _ = try importer.importArchive(plainSQLiteRoot: fixture.exportRoot, accountRoot: fixture.accountRoot, destinationRoot: destination, options: .all)
        try FileManager.default.removeItem(at: fixture.exportRoot)
        try FileManager.default.removeItem(at: fixture.accountRoot)

        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: destination)
        let conversations = try viewer.listConversations()
        let timeline = try viewer.messages(conversationID: try XCTUnwrap(conversations.first?.id), limit: 100)
        let image = try XCTUnwrap(timeline.first { $0.normalizedType == .image }?.media.first { $0.decodedRelativePath != nil })
        let video = try XCTUnwrap(timeline.first { $0.normalizedType == .video }?.media.first { $0.variant == .play })
        let voice = try XCTUnwrap(timeline.first { $0.normalizedType == .voice }?.media.first)

        try expectEqual(conversations.count, 1)
        try expectEqual(timeline.map(\.normalizedType), [.text, .image, .voice, .video, .unknown])
        try expectTrue(viewer.mediaURL(for: image, preferDecoded: true) != nil)
        try expectTrue(viewer.mediaURL(for: video, preferDecoded: false) != nil)
        try expectTrue(viewer.mediaURL(for: voice, preferDecoded: false) != nil)
    }

    func testArchiveV1ImporterPreservesRowsAndArchivesSupportedMediaInNewDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        let destination = directory.appending(path: "WeChatArchive")
        let importer = WeChatArchiveV1Importer(
            imageKeyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: fixture.imageKey, xorKey: 0x88)])
        )

        let first = try importer.importArchive(
            plainSQLiteRoot: fixture.exportRoot,
            accountRoot: fixture.accountRoot,
            destinationRoot: destination,
            options: .init(limit: 100)
        )
        var importedSourceRow: ArchiveV1SourceMessage?
        _ = try WeChatArchiveV1SourceReader().stream(exportRoot: fixture.exportRoot, limit: 1) { row in
            importedSourceRow = row
            return true
        }
        let sourceRow = try XCTUnwrap(importedSourceRow)
        try expectEqual(sourceRow.sourceDatabase, "message/message_0.db")
        try expectEqual(sourceRow.sourceTable, fixture.tableName)
        try expectEqual(sourceRow.sourceSQLiteRowID, 1)
        let database = try WeChatArchiveV1Database(url: destination.appending(path: "archive.sqlite"))
        let sourceValues = try database.sourceValues(
            sourceDatabase: sourceRow.sourceDatabase,
            sourceTable: sourceRow.sourceTable,
            sourceSQLiteRowID: sourceRow.sourceSQLiteRowID
        )
        let reconstruction = try database.reconstruction()
        let validation = try WeChatArchiveV1Validator().validate(at: destination)

        try expectEqual(first.messagesImported, 5)
        try expectEqual(first.textCount, 1)
        try expectEqual(first.imageCount, 1)
        try expectEqual(first.videoCount, 1)
        try expectEqual(first.voiceCount, 1)
        try expectEqual(first.unknownCount, 1)
        try expectEqual(first.rawDATArchived, 1)
        try expectEqual(first.decodedImages, 1)
        try expectEqual(first.rawVideoArchived, 1)
        try expectEqual(first.videoThumbnailsArchived, 1)
        try expectEqual(first.rawVoiceArchived, 1)
        try expectEqual(sourceValues.count, 13)
        try expectEqual(sourceValues["null_value"], .null)
        try expectEqual(sourceValues["integer_value"], .integer(42))
        try expectEqual(sourceValues["real_value"], .real(3.5))
        try expectEqual(sourceValues["message_content"], .text("synthetic text"))
        try expectEqual(sourceValues["compress_content"], .blob(fixture.textBlob))
        try expectEqual(reconstruction.map(\.normalizedType), [.text, .image, .voice, .video, .unknown])
        try expectEqual(reconstruction.first?.textContent, "synthetic text")
        try expectTrue(validation.passed)
        try expectEqual(try database.messageCount(), 5)
        try expectEqual(try database.mediaAssetCount(), 7)
    }

    func testArchiveV1SourceReaderPreservesAllSQLiteValueKinds() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        var sourceRow: ArchiveV1SourceMessage?

        _ = try WeChatArchiveV1SourceReader().stream(exportRoot: fixture.exportRoot, limit: 1) { row in
            sourceRow = row
            return true
        }

        let values = try XCTUnwrap(sourceRow?.values)
        try expectEqual(values["null_value"], ArchivedSQLiteValue.null)
        try expectEqual(values["integer_value"], .integer(42))
        try expectEqual(values["real_value"], .real(3.5))
        try expectEqual(values["message_content"], .text("synthetic text"))
        try expectEqual(values["compress_content"], .blob(fixture.textBlob))
    }

    func testArchiveV1ImporterRejectsNonEmptyDestinationForOneTimeExport() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        let destination = directory.appending(path: "WeChatArchive")
        let importer = WeChatArchiveV1Importer(
            imageKeyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: fixture.imageKey, xorKey: 0x88)])
        )

        let initial = try importer.importArchive(
            plainSQLiteRoot: fixture.exportRoot,
            accountRoot: fixture.accountRoot,
            destinationRoot: destination,
            options: .init(limit: 1)
        )
        try expectThrows(ArchiveError.invalidArchive) {
            _ = try importer.importArchive(
                plainSQLiteRoot: fixture.exportRoot,
                accountRoot: fixture.accountRoot,
                destinationRoot: destination,
                options: .all
            )
        }

        try expectEqual(initial.messagesImported, 1)
    }

    func testArchiveV1ImporterCancellationLeavesValidCommittedMessages() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        let destination = directory.appending(path: "WeChatArchive")
        let cancellation = TestCancellation(afterChecks: 1)
        let importer = WeChatArchiveV1Importer(
            imageKeyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: fixture.imageKey, xorKey: 0x88)])
        )

        let summary = try importer.importArchive(
            plainSQLiteRoot: fixture.exportRoot,
            accountRoot: fixture.accountRoot,
            destinationRoot: destination,
            options: .all,
            shouldCancel: { cancellation.shouldCancel() }
        )
        let database = try WeChatArchiveV1Database(url: destination.appending(path: "archive.sqlite"))
        let validation = try WeChatArchiveV1Validator().validate(at: destination)

        try expectEqual(summary.status, .cancelled)
        try expectEqual(summary.messagesImported, 1)
        try expectEqual(try database.messageCount(), 1)
        try expectTrue(validation.passed)
    }

    func testArchiveV1ImageDecodeFailureStillPreservesImageMessageAndRawDAT() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeArchiveV1SourceFixture(in: directory)
        var invalidDAT = try Data(contentsOf: fixture.thumbnailDATURL)
        invalidDAT[invalidDAT.index(before: invalidDAT.endIndex)] ^= 0x01
        try invalidDAT.write(to: fixture.thumbnailDATURL)
        let destination = directory.appending(path: "WeChatArchive")
        let importer = WeChatArchiveV1Importer(
            imageKeyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: fixture.imageKey, xorKey: 0x88)])
        )

        let summary = try importer.importArchive(
            plainSQLiteRoot: fixture.exportRoot,
            accountRoot: fixture.accountRoot,
            destinationRoot: destination,
            options: .all
        )
        let reconstruction = try WeChatArchiveV1Database(url: destination.appending(path: "archive.sqlite")).reconstruction()

        try expectEqual(summary.messagesImported, 5)
        try expectEqual(summary.rawDATArchived, 1)
        try expectEqual(summary.decodedImages, 0)
        try expectEqual(summary.decodeFailures, 1)
        try expectTrue(reconstruction.contains { $0.normalizedType == .image && $0.mediaStatuses.contains(.invalidPadding) })
    }

    func testArchiveV1ReconstructionUsesStableTimestampAndSourceSequenceOrdering() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WeChatArchiveV1Database(url: directory.appending(path: "WeChatArchive/archive.sqlite"))
        let conversationID = try database.upsertConversation(sourceIdentity: "Msg_0123456789abcdef0123456789abcdef")
        let textA = try database.insertMessage(
            conversationID: conversationID, sourceDatabase: "message/message_0.db", sourceTable: "Msg_0123456789abcdef0123456789abcdef", sourceSQLiteRowID: 1, sourceLocalID: 1, sourceServerID: nil, timestamp: 100, senderSourceID: nil, receiverSourceID: nil, rawLocalType: 1, normalizedType: .text, textContent: "A", replySourceID: nil, sourceSequence: 1, sourceValues: [:]
        )
        let imageB = try database.insertMessage(
            conversationID: conversationID, sourceDatabase: "message/message_0.db", sourceTable: "Msg_0123456789abcdef0123456789abcdef", sourceSQLiteRowID: 2, sourceLocalID: 2, sourceServerID: nil, timestamp: 100, senderSourceID: nil, receiverSourceID: nil, rawLocalType: 3, normalizedType: .image, textContent: nil, replySourceID: nil, sourceSequence: 2, sourceValues: [:]
        )
        _ = try database.insertMediaAsset(
            messageID: imageB.id, variant: .thumbnail, status: .missing, sourceFormat: nil, decodedFormat: nil, rawArchivePath: nil, decodedArchivePath: nil, rawSize: nil, decodedSize: nil, width: nil, height: nil, rawSHA256: nil, decodedSHA256: nil, sourceFileBase: nil
        )
        _ = try database.insertMessage(
            conversationID: conversationID, sourceDatabase: "message/message_0.db", sourceTable: "Msg_0123456789abcdef0123456789abcdef", sourceSQLiteRowID: 3, sourceLocalID: 3, sourceServerID: nil, timestamp: 100, senderSourceID: nil, receiverSourceID: nil, rawLocalType: 1, normalizedType: .text, textContent: "C", replySourceID: nil, sourceSequence: 3, sourceValues: [:]
        )
        _ = textA

        let reconstructed = try database.reconstruction()

        try expectEqual(reconstructed.map(\.normalizedType), [.text, .image, .text])
        try expectEqual(reconstructed.map(\.textContent), ["A", nil, "C"])
        try expectEqual(reconstructed[1].mediaStatuses, [.missing])
    }

    func testArchiveWriterPartitionsMessagesByConversationAndYearAndPreservesUnknownPayload() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeMessage(
            id: "m-2024",
            timestamp: date("2024-12-31T23:30:00+08:00"),
            type: .text,
            content: "跨年消息"
        )
        let unknown = makeMessage(
            id: "m-2025",
            timestamp: date("2025-01-01T00:30:00+08:00"),
            type: .unknown,
            content: nil,
            raw: ["legacy_type": "0xDEAD", "payload": "kept"]
        )
        let archive = ArchiveWriter(rootURL: directory)

        try archive.write(messages: [first, unknown], account: Account(id: "me", displayName: "我"))

        let messages2024 = try NDJSONReader().read(from: directory.appending(path: "messages/chat-1/2024.ndjson"))
        let messages2025 = try NDJSONReader().read(from: directory.appending(path: "messages/chat-1/2025.ndjson"))
        let manifest = try ArchiveReader().manifest(from: directory)

        try expectEqual(messages2024.map(\.id), ["m-2024"])
        try expectEqual(messages2025.first?.raw?["legacy_type"], "0xDEAD")
        try expectEqual(manifest.messageCount, 2)
        try expectEqual(manifest.format, ArchiveManifest.formatName)
    }

    func testMediaStoreDeduplicatesContentUsingSHA256InsteadOfFilename() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaStore(rootURL: directory)

        let first = try store.store(data: Data("same bytes".utf8), suggestedFilename: "summer-photo.jpg", category: .images)
        let second = try store.store(data: Data("same bytes".utf8), suggestedFilename: "renamed.png", category: .images)

        try expectEqual(first.sha256, second.sha256)
        try expectEqual(first.relativePath, second.relativePath)
        try expectEqual(first.size, 10)
        try expectTrue(FileManager.default.fileExists(atPath: directory.appending(path: first.relativePath).path()))
    }

    func testImportCoordinatorSkipsStableAndFallbackDuplicatesAndRecordsSessionCounts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try SQLiteArchiveIndex(url: directory.appending(path: "archive.sqlite"))
        let coordinator = ImportCoordinator(index: index)
        let original = makeMessage(id: "source-1", timestamp: date("2025-02-03T04:05:06+08:00"), type: .text, content: "hello")
        let noSourceID = makeMessage(id: "generated-a", timestamp: original.timestamp, type: .text, content: "hello", sourceMessageID: nil)
        let sameFallback = makeMessage(id: "generated-b", timestamp: original.timestamp, type: .text, content: "hello", sourceMessageID: nil)

        let first = try coordinator.importMessages([original, noSourceID], source: .jsonFile, sourceHash: "hash-1")
        let second = try coordinator.importMessages([original, sameFallback], source: .jsonFile, sourceHash: "hash-2")

        try expectEqual(first.messagesInserted, 2)
        try expectEqual(second.messagesInserted, 0)
        try expectEqual(second.messagesSkipped, 2)
        try expectEqual(try index.messageCount(), 2)
        try expectEqual(try index.importSessions().count, 2)
    }

    func testSQLiteIndexFindsMessagesWithFTSAndAppliesFilters() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try SQLiteArchiveIndex(url: directory.appending(path: "archive.sqlite"))
        let waterfall = makeMessage(id: "search-1", timestamp: date("2025-04-01T10:00:00+08:00"), type: .text, content: "黄果树瀑布真美")
        let unrelated = makeMessage(id: "search-2", timestamp: date("2025-04-02T10:00:00+08:00"), type: .image, content: "照片")

        _ = try index.upsert(messages: [waterfall, unrelated])
        let result = try index.search(.init(query: "黄果树", conversationID: "chat-1", types: [.text], limit: 20))

        try expectEqual(result.map(\.id), ["search-1"])
    }

    func testExportersEscapeContentAndRemainOffline() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = makeMessage(id: "html-1", timestamp: date("2025-05-06T10:00:00+08:00"), type: .text, content: "<script>alert(1)</script>,\"ok\"")

        let htmlURL = try HTMLExporter().export(messages: [message], conversationName: "测试", to: directory)
        let csvURL = try CSVExporter().export(messages: [message], conversationName: "测试", to: directory)
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let csv = try String(contentsOf: csvURL, encoding: .utf8)

        try expectFalse(html.contains("<script>alert"))
        try expectTrue(html.contains("&lt;script&gt;"))
        try expectFalse(html.contains("https://"))
        try expectTrue(csv.contains("\"\"ok\"\""))
    }

    func testVerifierReportsChecksumMismatchWithoutExposingMessageContent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ArchiveWriter(rootURL: directory)
        try archive.write(messages: [makeMessage(id: "verify-1", timestamp: date("2025-06-01T10:00:00+08:00"), type: .text, content: "private text")], account: Account(id: "me", displayName: "我"))
        let ndjson = directory.appending(path: "messages/chat-1/2025.ndjson")
        try Data("tampered".utf8).write(to: ndjson)

        let report = try ArchiveVerifier().verify(at: directory)

        try expectFalse(report.isHealthy)
        try expectEqual(report.corruptedFiles, 1)
        try expectFalse(report.issues.joined(separator: " ").contains("private text"))
    }

    func testStatisticsCountsMessageTypesAndPreservesDateRange() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeMessage(id: "stats-1", timestamp: date("2021-01-01T10:00:00+08:00"), type: .text, content: "first")
        let image = makeMessage(id: "stats-2", timestamp: date("2022-01-01T10:00:00+08:00"), type: .image, content: nil)
        let video = makeMessage(id: "stats-3", timestamp: date("2023-01-01T10:00:00+08:00"), type: .video, content: nil)
        let file = makeMessage(id: "stats-4", timestamp: date("2024-01-01T10:00:00+08:00"), type: .file, content: nil)
        let conversations = [
            Conversation(id: "chat-1", displayName: "群聊", isGroup: true),
            Conversation(id: "chat-2", displayName: "联系人", isGroup: false)
        ]

        let stats = try ArchiveStatisticsCalculator().calculate(
            messages: [video, file, first, image],
            conversations: conversations,
            archiveRoot: directory
        )

        try expectEqual(stats.messageCount, 4)
        try expectEqual(stats.contactCount, 1)
        try expectEqual(stats.groupCount, 1)
        try expectEqual(stats.imageCount, 1)
        try expectEqual(stats.videoCount, 1)
        try expectEqual(stats.fileCount, 1)
        try expectEqual(stats.earliestMessageAt, first.timestamp)
        try expectEqual(stats.latestMessageAt, file.timestamp)
    }

    func testImportProviderContractsCoverEverySupportedSourceKind() throws {
        let providers: [any ChatImportProvider] = [
            JSONImportProvider(), NDJSONImportProvider(), CSVImportProvider(),
            TXTImportProvider(), HTMLImportProvider(), WeChatDatabaseImportProvider()
        ]

        try expectEqual(Set(providers.map(\.source)), Set(ImportSource.allCases))
    }

    func testSQLCipherDecryptorValidatesCorrectKeyAndRejectsWrongKey() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encryptedDatabase = directory.appending(path: "synthetic-encrypted.db")
        let keyHex = randomKeyHex()
        try makeEncryptedTestDatabase(at: encryptedDatabase, keyHex: keyHex)
        let decryptor = try SQLCipherDatabaseDecryptor()
        let key = try WeChatDatabaseKey(hex: keyHex)

        try decryptor.validate(databaseURL: encryptedDatabase, key: key)
        let wrongKey = try WeChatDatabaseKey(hex: randomKeyHex())
        try expectThrows(ArchiveError.databaseDecryptionFailed) {
            try decryptor.validate(databaseURL: encryptedDatabase, key: wrongKey)
        }
    }

    func testSQLCipherRuntimeLocatorPrefersBundledRuntimeOverFallbacks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundled = directory.appending(path: "Frameworks/libsqlcipher.dylib")
        let fallback = directory.appending(path: "Homebrew/libsqlcipher.dylib")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bundled fixture".utf8).write(to: bundled, options: .atomic)
        try Data("fallback fixture".utf8).write(to: fallback, options: .atomic)

        try expectEqual(
            SQLCipherRuntimeLocator.firstReadableLibraryURL(
                bundledLibraryURL: bundled,
                fallbackURLs: [fallback]
            ),
            bundled
        )
    }

    func testSQLCipherDecryptorExportsPlaintextToProtectedWorkingDirectoryWithoutChangingSource() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encryptedDatabase = directory.appending(path: "synthetic-encrypted.db")
        let keyHex = randomKeyHex()
        try makeEncryptedTestDatabase(at: encryptedDatabase, keyHex: keyHex)
        let originalHash = SHA256.hash(data: try Data(contentsOf: encryptedDatabase)).map { String(format: "%02x", $0) }.joined()
        let workingDirectory = directory.appending(path: "working")
        let plaintextDatabase = try SQLCipherDatabaseDecryptor().decrypt(
            databaseURL: encryptedDatabase,
            key: try WeChatDatabaseKey(hex: keyHex),
            into: workingDirectory
        )

        try expectTrue(plaintextDatabase.path().hasPrefix(workingDirectory.path()))
        try expectEqual(Data(try Data(contentsOf: plaintextDatabase).prefix(16)), Data("SQLite format 3\0".utf8))
        try expectEqual(try readPlaintextFixtureBody(from: plaintextDatabase), "synthetic fixture only")
        try expectEqual(originalHash, SHA256.hash(data: try Data(contentsOf: encryptedDatabase)).map { String(format: "%02x", $0) }.joined())
        let permissions = try FileManager.default.attributesOfItem(atPath: plaintextDatabase.path())[.posixPermissions] as? Int
        try expectTrue((permissions ?? 0o777) & 0o077 == 0)
    }

    func testSQLCipherDecryptorRejectsNonRawKeyLengthsBeforeOpeningDatabase() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encryptedDatabase = directory.appending(path: "synthetic-encrypted.db")
        try makeEncryptedTestDatabase(at: encryptedDatabase, keyHex: randomKeyHex())
        let shortKey = try WeChatDatabaseKey(hex: String(repeating: "ab", count: 16))

        try expectThrows(ArchiveError.keyInvalid) {
            try SQLCipherDatabaseDecryptor().validate(databaseURL: encryptedDatabase, key: shortKey)
        }
    }

    func testSQLCipherDecryptorRejectsNonPowerOfTwoPageSizesBeforeOpeningDatabase() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encryptedDatabase = directory.appending(path: "synthetic-encrypted.db")
        let keyHex = randomKeyHex()
        try makeEncryptedTestDatabase(at: encryptedDatabase, keyHex: keyHex)
        let decryptor = try SQLCipherDatabaseDecryptor(configuration: .init(pageSize: 1_536))

        try expectThrows(ArchiveError.invalidInput) {
            try decryptor.validate(databaseURL: encryptedDatabase, key: try WeChatDatabaseKey(hex: keyHex))
        }
    }

    func testDatabaseSnapshotterCopiesOnlyDatabaseWhenNoSidecarsExist() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "messages.db")
        let snapshotDirectory = directory.appending(path: "snapshot")
        try Data("database".utf8).write(to: database)

        let snapshot = try DatabaseSnapshotter().snapshot(databaseURL: database, into: snapshotDirectory)

        try expectTrue(FileManager.default.fileExists(atPath: snapshot.path()))
        try expectFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: database.path() + "-wal").path()))
        try expectFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: database.path() + "-shm").path()))
    }

    func testDatabaseSnapshotterCopiesDashNamedSQLiteSidecarsAndIgnoresDotExtensionLookalikes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "messages.db")
        let wal = URL(fileURLWithPath: database.path() + "-wal")
        let shm = URL(fileURLWithPath: database.path() + "-shm")
        let incorrectWAL = database.appendingPathExtension("wal")
        let incorrectSHM = database.appendingPathExtension("shm")
        let snapshotDirectory = directory.appending(path: "snapshot")
        try Data("database".utf8).write(to: database)
        try Data("wal".utf8).write(to: wal)
        try Data("shm".utf8).write(to: shm)
        try Data("incorrect wal".utf8).write(to: incorrectWAL)
        try Data("incorrect shm".utf8).write(to: incorrectSHM)
        let databaseHash = try sha256Hex(of: database)
        let walHash = try sha256Hex(of: wal)
        let shmHash = try sha256Hex(of: shm)

        _ = try DatabaseSnapshotter().snapshot(databaseURL: database, into: snapshotDirectory)

        try expectTrue(FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent("messages.db").path()))
        try expectTrue(FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent("messages.db-wal").path()))
        try expectTrue(FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent("messages.db-shm").path()))
        try expectFalse(FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent("messages.db.wal").path()))
        try expectFalse(FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent("messages.db.shm").path()))
        try expectEqual(try sha256Hex(of: database), databaseHash)
        try expectEqual(try sha256Hex(of: wal), walHash)
        try expectEqual(try sha256Hex(of: shm), shmHash)
    }

    func testDatabaseSnapshotterRejectsSourceMutationAndRemovesOnlyItsWorkingDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "messages.db")
        let wal = URL(fileURLWithPath: database.path() + "-wal")
        let snapshotDirectory = directory.appending(path: "snapshot")
        try Data("database".utf8).write(to: database)
        try Data("wal".utf8).write(to: wal)

        let snapshotter = DatabaseSnapshotter(copyFile: { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
            if source == database {
                let handle = try FileHandle(forWritingTo: database)
                defer { try? handle.close() }
                try handle.seekToEnd()
                handle.write(Data("!".utf8))
            }
        })

        try expectThrows(ArchiveError.databaseInUse) {
            _ = try snapshotter.snapshot(databaseURL: database, into: snapshotDirectory)
        }
        try expectFalse(FileManager.default.fileExists(atPath: snapshotDirectory.path()))
        try expectTrue(FileManager.default.fileExists(atPath: database.path()))
        try expectTrue(FileManager.default.fileExists(atPath: wal.path()))
    }

    func testDatabaseSnapshotterSetsProtectedDirectoryAndFilePermissions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "messages.db")
        let wal = URL(fileURLWithPath: database.path() + "-wal")
        let snapshotDirectory = directory.appending(path: "snapshot")
        try Data("database".utf8).write(to: database)
        try Data("wal".utf8).write(to: wal)

        _ = try DatabaseSnapshotter().snapshot(databaseURL: database, into: snapshotDirectory)

        try expectEqual(try permissionBits(at: snapshotDirectory), 0o700)
        try expectEqual(try permissionBits(at: snapshotDirectory.appendingPathComponent("messages.db")), 0o600)
        try expectEqual(try permissionBits(at: snapshotDirectory.appendingPathComponent("messages.db-wal")), 0o600)
    }

    func testRemoveSQLiteArtifactsRemovesDatabaseAndAllSQLiteSidecars() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plaintext = directory.appending(path: "plaintext.sqlite")
        let artifacts = [
            plaintext,
            URL(fileURLWithPath: plaintext.path() + "-wal"),
            URL(fileURLWithPath: plaintext.path() + "-shm"),
            URL(fileURLWithPath: plaintext.path() + "-journal")
        ]
        for artifact in artifacts {
            try Data("sensitive plaintext".utf8).write(to: artifact)
        }

        removeSQLiteArtifacts(for: plaintext)

        for artifact in artifacts {
            try expectFalse(FileManager.default.fileExists(atPath: artifact.path()))
        }
    }

    func testSQLCipherDecryptorRemovesPlaintextArtifactsWhenPostExportVerificationFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encryptedDatabase = directory.appending(path: "synthetic-encrypted.db")
        let keyHex = randomKeyHex()
        try makeEncryptedTestDatabase(at: encryptedDatabase, keyHex: keyHex)
        let recorder = PlaintextDestinationRecorder()
        let decryptor = try SQLCipherDatabaseDecryptor(plaintextHeaderValidator: { destination in
            recorder.destination = destination
            for artifact in [
                URL(fileURLWithPath: destination.path() + "-wal"),
                URL(fileURLWithPath: destination.path() + "-shm"),
                URL(fileURLWithPath: destination.path() + "-journal")
            ] {
                try Data("sensitive plaintext".utf8).write(to: artifact)
            }
            throw TestFailure(description: "force cleanup after export")
        })

        try expectThrows(ArchiveError.databaseDecryptionFailed) {
            _ = try decryptor.decrypt(
                databaseURL: encryptedDatabase,
                key: try WeChatDatabaseKey(hex: keyHex),
                into: directory.appending(path: "working")
            )
        }
        guard let destination = recorder.destination else {
            throw TestFailure(description: "The test must reach plaintext verification")
        }
        for artifact in [
            destination,
            URL(fileURLWithPath: destination.path() + "-wal"),
            URL(fileURLWithPath: destination.path() + "-shm"),
            URL(fileURLWithPath: destination.path() + "-journal")
        ] {
            try expectFalse(FileManager.default.fileExists(atPath: artifact.path()))
        }
    }

    func testSQLCipherConfigurationRejectsOutOfRangeValues() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encryptedDatabase = directory.appending(path: "synthetic-encrypted.db")
        let keyHex = randomKeyHex()
        try makeEncryptedTestDatabase(at: encryptedDatabase, keyHex: keyHex)
        let key = try WeChatDatabaseKey(hex: keyHex)
        let invalidConfigurations: [SQLCipherConfiguration] = [
            .init(pageSize: 256),
            .init(pageSize: 131_072),
            .init(kdfIterations: 999),
            .init(kdfIterations: 10_000_001)
        ]

        for configuration in invalidConfigurations {
            try expectThrows(ArchiveError.invalidInput) {
                try SQLCipherDatabaseDecryptor(configuration: configuration).validate(databaseURL: encryptedDatabase, key: key)
            }
        }
    }

    func testSQLCipherDecryptorReportsUnavailableRuntime() throws {
        try expectThrows(ArchiveError.decryptionRuntimeUnavailable) {
            _ = try SQLCipherDatabaseDecryptor(libraryURL: URL(fileURLWithPath: "/nonexistent/sqlcipher.dylib"))
        }
    }

    func testUnavailableSQLCipherDecryptorReportsUnavailableRuntime() throws {
        let key = try WeChatDatabaseKey(hex: randomKeyHex())
        try expectThrows(ArchiveError.decryptionRuntimeUnavailable) {
            try UnavailableSQLCipherDecryptor().validate(
                databaseURL: URL(fileURLWithPath: "/synthetic/database.db"),
                key: key
            )
        }
    }

    func testWXCLIKeyMapProviderMatchesOnlyNormalizedRelativePathsAndRejectsInvalidKeys() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let validKey = randomKeyHex()
        let mapURL = directory.appending(path: "all_keys.json")
        try Data("""
        {
          "contact/contact.db": { "enc_key": "\(validKey)" },
          "message/message_0.db": { "enc_key": "\(randomKeyHex())" }
        }
        """.utf8).write(to: mapURL)

        let provider = try WXCLIKeyMapProvider(url: mapURL)

        try expectTrue(provider.key(forRelativePath: "contact/contact.db") != nil)
        try expectTrue(provider.key(forRelativePath: "contact\\contact.db") != nil)
        try expectTrue(provider.key(forRelativePath: "contact.db") == nil)
        try expectTrue(provider.key(forRelativePath: "../contact/contact.db") == nil)

        let invalidMapURL = directory.appending(path: "invalid-all_keys.json")
        try Data("""
        { "contact/contact.db": { "enc_key": "not-a-key" } }
        """.utf8).write(to: invalidMapURL)
        try expectThrows(ArchiveError.keyInvalid) {
            _ = try WXCLIKeyMapProvider(url: invalidMapURL)
        }
    }

    func testLocalDatabaseDirectoryPathAcceptsExistingAbsoluteDirectoryAndRejectsRelativeOrFilePaths() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "not-a-directory.db")
        try Data("fixture".utf8).write(to: file)

        let resolved = try LocalDatabaseDirectoryPath.resolve(directory.path())

        try expectEqual(resolved, directory.standardizedFileURL)
        try expectThrows(ArchiveError.invalidInput) {
            _ = try LocalDatabaseDirectoryPath.resolve("relative/db_storage")
        }
        try expectThrows(ArchiveError.invalidInput) {
            _ = try LocalDatabaseDirectoryPath.resolve(file.path())
        }
    }

    func testDefaultWXCLIKeyMapLocatorAcceptsOnlyRegularJSONFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = directory.appending(path: "all_keys.json")
        let nonJSON = directory.appending(path: "all_keys.txt")
        try Data("{}".utf8).write(to: json)
        try Data("{}".utf8).write(to: nonJSON)

        try expectEqual(DefaultWXCLIKeyMapLocator(url: json).locate(), json.standardizedFileURL)
        try expectTrue(DefaultWXCLIKeyMapLocator(url: nonJSON).locate() == nil)
        try expectTrue(DefaultWXCLIKeyMapLocator(url: directory.appending(path: "missing.json")).locate() == nil)
    }

    func testDatabaseExportSessionAutoSelectsExistingDefaultKeyMapAndClearsPreviousScanResultsWhenDirectoryChanges() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRoot = directory.appending(path: "first-db_storage")
        let secondRoot = directory.appending(path: "second-db_storage")
        let contactDirectory = firstRoot.appending(path: "contact")
        try FileManager.default.createDirectory(at: contactDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: contactDirectory.appending(path: "contact.db"))
        let keyMap = directory.appending(path: "all_keys.json")
        try Data("{ \"contact/contact.db\": { \"enc_key\": \"\(randomKeyHex())\" } }".utf8).write(to: keyMap)
        let scanned = try WeChatDatabaseScanner().scan(databaseRoot: firstRoot, keyMap: try WXCLIKeyMapProvider(url: keyMap))
        var session = DatabaseExportSession()

        session.selectDatabaseDirectory(try LocalDatabaseDirectoryPath.resolve(firstRoot.path()), defaultKeyMapURL: DefaultWXCLIKeyMapLocator(url: keyMap).locate())
        try expectEqual(session.databaseRoot, firstRoot.standardizedFileURL)
        try expectEqual(session.keyMapURL, keyMap.standardizedFileURL)
        try expectTrue(session.canScan)
        session.setDatabases(scanned)
        try expectEqual(session.databases.count, 1)

        session.selectDatabaseDirectory(try LocalDatabaseDirectoryPath.resolve(secondRoot.path()), defaultKeyMapURL: nil)
        try expectEqual(session.databaseRoot, secondRoot.standardizedFileURL)
        try expectTrue(session.keyMapURL == nil)
        try expectFalse(session.canScan)
        try expectTrue(session.databases.isEmpty)
    }

    func testDatabaseExportSessionEnablesScanAfterManualKeyMapSelection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "db_storage")
        let keyMap = directory.appending(path: "all_keys.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: keyMap)
        var session = DatabaseExportSession()

        session.selectDatabaseDirectory(try LocalDatabaseDirectoryPath.resolve(root.path()), defaultKeyMapURL: nil)
        try expectFalse(session.canScan)
        session.selectKeyMap(keyMap)

        try expectEqual(session.keyMapURL, keyMap.standardizedFileURL)
        try expectTrue(session.canScan)
    }

    func testSQLiteSchemaScannerCollectsMetadataIndexesForeignKeysAndRowCountsReadOnly() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let databaseURL = exportRoot.appending(path: "message/message_0.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE conversation (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL
            );
            CREATE TABLE message (
                local_id INTEGER PRIMARY KEY,
                conversation_id INTEGER NOT NULL,
                create_time INTEGER,
                sender TEXT NOT NULL,
                payload BLOB DEFAULT X'00',
                FOREIGN KEY(conversation_id) REFERENCES conversation(id)
            );
            CREATE INDEX message_sender_index ON message(sender);
            INSERT INTO conversation(title) VALUES ('synthetic fixture');
            INSERT INTO message(conversation_id, create_time, sender, payload) VALUES (1, 1, 'fixture', X'01');
            INSERT INTO message(conversation_id, create_time, sender, payload) VALUES (1, 2, 'fixture', X'02');
            """)
        let hashBefore = try sha256Hex(of: databaseURL)

        let report = try SQLiteSchemaScanner().scan(exportRoot: exportRoot)

        try expectEqual(report.databases.count, 1)
        let database = try unwrap(report.databases.first)
        try expectEqual(database.relativePath, "message/message_0.db")
        try expectTrue(database.fileSize > 0)
        try expectTrue(!database.sqliteVersion.isEmpty)
        try expectTrue(database.pageCount > 0)
        try expectTrue(database.pageSize > 0)
        try expectEqual(database.tableCount, 2)
        try expectEqual(database.indexCount, 1)
        try expectEqual(database.viewCount, 0)
        try expectEqual(database.triggerCount, 0)
        try expectEqual(database.classification.category, .message)
        try expectEqual(database.classification.certainty, .detected)

        let message = try unwrap(database.tables.first(where: { $0.name == "message" }))
        try expectEqual(message.rowCount, 2)
        let localID = try unwrap(message.columns.first(where: { $0.name == "local_id" }))
        try expectEqual(localID.declaredType, "INTEGER")
        try expectTrue(localID.isPrimaryKey)
        try expectFalse(localID.isNullable)
        let payload = try unwrap(message.columns.first(where: { $0.name == "payload" }))
        try expectTrue(payload.hasDefaultValue)
        try expectEqual(message.indexes.first?.name, "message_sender_index")
        try expectEqual(message.indexes.first?.columns, ["sender"])
        try expectEqual(message.foreignKeys.first?.referencedTable, "conversation")
        try expectEqual(message.foreignKeys.first?.columns, ["conversation_id"])
        try expectEqual(message.foreignKeys.first?.referencedColumns, ["id"])
        try expectEqual(try sha256Hex(of: databaseURL), hashBefore)
    }

    func testSQLiteSchemaScannerRecognizesVirtualAndFTSShadowTablesAndGroupsIdenticalSchemas() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let first = exportRoot.appending(path: "message/message_0.db")
        let second = exportRoot.appending(path: "message/message_1.db")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = """
            CREATE TABLE message (local_id INTEGER PRIMARY KEY, create_time INTEGER, sender TEXT, payload BLOB);
            CREATE VIRTUAL TABLE message_search USING fts5(content);
            """
        try createPlainSQLiteDatabase(at: first, sql: schema + "INSERT INTO message(create_time, sender, payload) VALUES (1, 'fixture', X'01');")
        try createPlainSQLiteDatabase(at: second, sql: schema + "INSERT INTO message(create_time, sender, payload) VALUES (2, 'fixture', X'02');")

        let report = try SQLiteSchemaScanner().scan(exportRoot: exportRoot)
        let database = try unwrap(report.databases.first(where: { $0.relativePath == "message/message_0.db" }))
        let virtualTable = try unwrap(database.tables.first(where: { $0.name == "message_search" }))
        try expectTrue(virtualTable.isVirtual)
        try expectTrue(database.tables.contains(where: { $0.isFTSShadowTable }))
        try expectTrue(database.tables.filter(\.isFTSShadowTable).allSatisfy { $0.rowCount == nil })
        try expectEqual(report.schemaGroups.count, 1)
        try expectEqual(report.schemaGroups.first?.relativePaths, ["message/message_0.db", "message/message_1.db"])
    }

    func testSQLiteSchemaScannerSafelyQuotesSchemaProvidedIdentifiers() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let databaseURL = exportRoot.appending(path: "misc/quoted.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE "odd""table" (id INTEGER PRIMARY KEY, value TEXT);
            INSERT INTO "odd""table"(value) VALUES ('synthetic fixture');
            """)

        let report = try SQLiteSchemaScanner().scan(exportRoot: exportRoot)
        let table = try unwrap(report.databases.first?.tables.first(where: { $0.name == "odd\"table" }))

        try expectEqual(table.rowCount, 1)
        try expectEqual(table.columns.map(\.name), ["id", "value"])
    }

    func testMessageDiscoveryFindsCandidateInfersFieldsAndPreservesBlobMetadata() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let databaseURL = exportRoot.appending(path: "message/message_0.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE message (
                local_id INTEGER PRIMARY KEY,
                server_id INTEGER,
                local_type INTEGER,
                create_time INTEGER,
                real_sender_id INTEGER,
                source TEXT,
                message_content TEXT,
                packed_info_data BLOB
            );
            INSERT INTO message VALUES (1, 101, 1, 1723800123, 9, 'fixture-chat', 'synthetic plain text', X'010203');
            INSERT INTO message VALUES (2, 102, 3, 1723800124, 9, 'fixture-chat', '<msg><img md5="d41d8cd98f00b204e9800998ecf8427e" mediaid="fixture-media" /></msg>', X'040506');
            """)
        let schemaReport = try SQLiteSchemaScanner().scan(exportRoot: exportRoot)
        let candidate = try unwrap(WeChatMessageTableDiscovery().candidates(from: schemaReport).first)

        let analysis = try WeChatMessageDiscovery().inspect(
            exportRoot: exportRoot,
            candidate: candidate,
            sampleLimit: 100,
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )

        try expectEqual(candidate.tableName, "message")
        try expectEqual(analysis.records.count, 2)
        try expectEqual(analysis.fieldMapping.messageIDColumn, "local_id")
        try expectEqual(analysis.fieldMapping.timestampColumn, "create_time")
        try expectEqual(analysis.fieldMapping.rawTypeColumn, "local_type")
        try expectEqual(analysis.fieldMapping.contentColumn, "message_content")
        try expectEqual(analysis.fieldMapping.payloadColumn, "packed_info_data")
        try expectEqual(analysis.timestampInference?.unit, .seconds)
        try expectEqual(analysis.typeObservations.map(\.rawType), [1, 3])
        try expectEqual(analysis.typeObservations.map(\.count), [1, 1])
        try expectEqual(analysis.textCandidates.count, 1)
        try expectEqual(analysis.mediaReferences.first?.md5, "d41d8cd98f00b204e9800998ecf8427e")
        let record = try unwrap(analysis.records.first(where: { $0.identity.rowIdentifier == "1" }))
        guard case let .blob(blob)? = record.values["packed_info_data"] else {
            throw TestFailure(description: "Expected synthetic BLOB metadata")
        }
        try expectEqual(blob.length, 3)
        try expectTrue(blob.sha256.count == 64)
        try expectEqual(blob.data, Data([1, 2, 3]))
    }

    func testMessagePayloadInspectorExtractsOnlyStructuralXMLMediaMetadata() throws {
        let inspection = MessagePayloadInspector().inspect(text: """
            <msg><img md5="d41d8cd98f00b204e9800998ecf8427e" mediaid="fixture-media" aeskey="must-not-export" /></msg>
            """)

        try expectEqual(inspection.kind, .xml)
        try expectTrue(inspection.elementNames.contains("img"))
        try expectTrue(inspection.attributeNames.contains("md5"))
        try expectEqual(inspection.mediaTypeHint, .image)
        try expectEqual(inspection.md5, "d41d8cd98f00b204e9800998ecf8427e")
        try expectEqual(inspection.mediaID, "fixture-media")
        try expectFalse(inspection.metadataFieldNames.contains("aeskey"))
    }

    func testMessageDiscoveryInspectsBLOBPayloadWhenContentIsNull() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let databaseURL = exportRoot.appending(path: "message/message_0.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE message (local_id INTEGER PRIMARY KEY, local_type INTEGER, create_time INTEGER, message_content TEXT, packed_info_data BLOB);
            INSERT INTO message VALUES (1, 3, 1723800123, NULL, X'010203');
            """)
        let candidate = try unwrap(WeChatMessageTableDiscovery().candidates(from: try SQLiteSchemaScanner().scan(exportRoot: exportRoot)).first)

        let analysis = try WeChatMessageDiscovery().inspect(exportRoot: exportRoot, candidate: candidate)

        try expectEqual(analysis.payloadInspections.values.first?.kind, .blob)
        try expectEqual(analysis.payloadInspections.values.first?.blobLength, 3)
    }

    func testMessageSampleReaderKeepsLargeBLOBMetadataWithoutRetainingBytes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let databaseURL = exportRoot.appending(path: "message/message_0.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE message (local_id INTEGER PRIMARY KEY, create_time INTEGER, packed_info_data BLOB);
            INSERT INTO message VALUES (1, 1723800123, zeroblob(262145));
            """)
        let candidate = try unwrap(WeChatMessageTableDiscovery().candidates(from: try SQLiteSchemaScanner().scan(exportRoot: exportRoot)).first)

        let record = try unwrap(try WeChatMessageSampleReader().read(exportRoot: exportRoot, candidate: candidate).first)
        guard case let .blob(blob)? = record.values["packed_info_data"] else {
            throw TestFailure(description: "Expected a synthetic large BLOB")
        }

        try expectEqual(blob.length, 262145)
        try expectTrue(blob.sha256.count == 64)
        try expectTrue(blob.data == nil)
    }

    func testMessagePayloadInspectorExtractsBoundedHex32CandidateFromBLOB() throws {
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        let data = Data(repeating: 0, count: 64 * 1_024) + Data([0x01, 0x02]) + Data(md5.utf8) + Data([0x00, 0x03])
        let blob = SQLiteBlobSourceValue(
            length: data.count,
            sha256: String(repeating: "a", count: 64),
            data: data
        )

        let inspection = MessagePayloadInspector().inspect(value: .blob(blob))

        try expectEqual(inspection.kind, .blob)
        try expectTrue(inspection.confirmedMD5 == nil)
        try expectEqual(inspection.candidateIdentifiers.first?.value, md5)
        try expectEqual(inspection.candidateIdentifiers.first?.sourceColumn, "")
        try expectTrue(inspection.metadataFieldNames.contains("hex32_candidate"))
    }

    func testMessagePayloadInspectorTreatsUnkeyedHex32AsCandidateInsteadOfConfirmedMD5() throws {
        let hex32 = "d41d8cd98f00b204e9800998ecf8427e"
        let blob = SQLiteBlobSourceValue(
            length: 40,
            sha256: "fixture-digest",
            data: Data([0x01, 0x02]) + Data(hex32.utf8) + Data([0x03, 0x04])
        )

        let inspection = MessagePayloadInspector().inspect(value: .blob(blob))

        try expectTrue(inspection.confirmedMD5 == nil)
        try expectEqual(inspection.candidateIdentifiers.first?.representation, .hex32)
        try expectEqual(inspection.candidateIdentifiers.first?.semanticHint, .hex32Candidate)
    }

    func testMessagePayloadInspectionCodableOutputExcludesIdentifierValues() throws {
        let privateIdentifier = "d41d8cd98f00b204e9800998ecf8427e"
        let inspection = MessagePayloadInspection(
            kind: .blob,
            confirmedMD5: privateIdentifier,
            candidateIdentifiers: [.init(sourceColumn: "packed_info_data", offset: 0, representation: .hex32, length: 32, semanticHint: .hex32Candidate, valueKind: .hex32, value: privateIdentifier)],
            blobSHA256: privateIdentifier
        )

        let encoded = try JSONEncoder().encode(inspection)
        let text = String(decoding: encoded, as: UTF8.self)

        try expectFalse(text.contains(privateIdentifier))
    }

    func testType3SampleReaderUsesBoundedIntegerPredicate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let databaseURL = exportRoot.appending(path: "message/message_0.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE message (local_id INTEGER PRIMARY KEY, local_type INTEGER, packed_info_data BLOB);
            INSERT INTO message VALUES (1, 1, X'00');
            INSERT INTO message VALUES (2, 3, X'01');
            INSERT INTO message VALUES (3, 3, X'02');
            """)
        let candidate = MessageTableCandidate(
            databaseRelativePath: "message/message_0.db",
            tableName: "message",
            rowCount: 3,
            score: 100,
            columns: ["local_id", "local_type", "packed_info_data"]
        )

        let records = try WeChatMessageSampleReader().read(
            exportRoot: exportRoot,
            candidate: candidate,
            whereIntegerColumn: "local_type",
            equals: 3,
            sampleLimit: 100
        )

        try expectEqual(records.count, 2)
        try expectTrue(records.allSatisfy { $0.values["local_type"]?.integerValue == 3 })
    }

    func testType3PayloadAnalyzerClassifiesProtobufBinaryDigestAndZlibHeader() throws {
        let digestBytes = Data(repeating: 0xAB, count: 16)
        let protobuf = Data([0x0A, 0x10]) + digestBytes
        let records = [
            SourceMessageRecord(
                identity: .init(databaseRelativePath: "message/message_0.db", tableName: "message", rowIdentifier: "1"),
                values: [
                    "local_type": .integer(3),
                    "compress_content": .blob(.init(length: 2, sha256: "zlib", data: Data([0x78, 0x9C]))),
                    "packed_info_data": .blob(.init(length: protobuf.count, sha256: "proto", data: protobuf))
                ]
            )
        ]

        let analysis = Type3PayloadAnalyzer().analyze(records: records)

        try expectEqual(analysis.sampledRecordCount, 1)
        try expectTrue(analysis.payloadObservations.contains { $0.compression == .zlib })
        try expectTrue(analysis.candidateIdentifiers.contains { $0.representation == .binary16 && $0.semanticHint == .unknownIdentifier })
        try expectTrue(analysis.candidateIdentifiers.contains { $0.representation == .binary16 && $0.value?.count == 32 })
        try expectTrue(analysis.payloadObservations.contains { $0.payloadKind == .protobufLike })
    }

    func testType3PayloadAnalyzerRetainsOnlyInMemoryIdentifiersFromNamedColumns() throws {
        let hex32 = "d41d8cd98f00b204e9800998ecf8427e"
        let record = SourceMessageRecord(
            identity: .init(databaseRelativePath: "message/message_0.db", tableName: "message", rowIdentifier: "1"),
            values: [
                "media_id": .text("opaque-media-reference"),
                "file_md5": .text(hex32)
            ]
        )

        let analysis = Type3PayloadAnalyzer().analyze(records: [record])

        try expectTrue(analysis.candidateIdentifiers.contains { $0.sourceColumn == "media_id" && $0.semanticHint == .mediaID && $0.value == "opaque-media-reference" })
        try expectTrue(analysis.candidateIdentifiers.contains { $0.sourceColumn == "file_md5" && $0.semanticHint == .confirmedMD5 && $0.value == hex32 })
    }

    func testConversationTableIdentityAcceptsOnlyMsgTableWithHexDigest() throws {
        let digest = String(repeating: "a", count: 32)

        let identity = WeChatConversationTableIdentity(tableName: "Msg_\(digest)")

        try expectEqual(identity?.chatDirectoryComponent, digest)
        try expectTrue(WeChatConversationTableIdentity(tableName: "message") == nil)
        try expectTrue(WeChatConversationTableIdentity(tableName: "Msg_not-a-digest") == nil)
    }

    func testMessageResourceResolverUsesExactLow32TypeAndLocatesAllImageVariants() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let resourceDB = exportRoot.appending(path: "message/message_resource.db")
        try FileManager.default.createDirectory(at: resourceDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        let conversation = "synthetic-conversation"
        let conversationDigest = fixtureMD5Hex(conversation)
        let fileBase = "0123456789abcdef0123456789abcdef"
        let timestamp: Int64 = 1_738_355_200 // 2025-02-01 00:00:00 UTC
        let resourcePackedInfo = Data([0x12, 0x22, 0x0A, 0x20]) + Data(fileBase.utf8)
        let highBitsType = Int64(3) + (Int64(7) << 32)
        try createPlainSQLiteDatabase(at: resourceDB, sql: """
            CREATE TABLE ChatName2Id (user_name TEXT, update_time INTEGER);
            INSERT INTO ChatName2Id (rowid, user_name, update_time) VALUES (7, '\(conversation)', 0);
            CREATE TABLE MessageResourceInfo (
                message_id INTEGER, chat_id INTEGER, sender_id INTEGER,
                message_local_type INTEGER, message_create_time INTEGER,
                message_local_id INTEGER, message_svr_id INTEGER,
                message_origin_source INTEGER, packed_info BLOB
            );
            INSERT INTO MessageResourceInfo VALUES (99, 7, 0, \(highBitsType), \(timestamp), 42, 77, 0, X'\(resourcePackedInfo.map { String(format: "%02x", $0) }.joined())');
            CREATE TABLE MessageResourceDetail (
                resource_id INTEGER, message_id INTEGER, type INTEGER, size INTEGER,
                create_time INTEGER, access_time INTEGER, status INTEGER,
                data_index TEXT, packed_info BLOB
            );
            INSERT INTO MessageResourceDetail VALUES (1, 99, 1, 1, \(timestamp), \(timestamp), 0, 'fixture', X'00');
            """)
        let accountRoot = directory.appending(path: "Account")
        let imageDirectory = accountRoot.appending(path: "msg/attach/\(conversationDigest)/2025-02/Img")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        for suffix in ["", "_h", "_t"] {
            try Data([0x07, 0x08, 0x56, 0x32, 0x08, 0x07]).write(to: imageDirectory.appending(path: "\(fileBase)\(suffix).dat"))
        }
        let messagePackedInfo = SQLiteBlobSourceValue(length: resourcePackedInfo.count, sha256: "fixture", data: resourcePackedInfo)
        let record = SourceMessageRecord(
            identity: .init(databaseRelativePath: "message/message_0.db", tableName: "Msg_\(conversationDigest)", rowIdentifier: "42"),
            values: [
                "local_id": .integer(42),
                "server_id": .integer(77),
                "local_type": .integer(3),
                "create_time": .integer(timestamp),
                "packed_info_data": .blob(messagePackedInfo)
            ]
        )
        let candidate = MessageTableCandidate(
            databaseRelativePath: "message/message_0.db",
            tableName: "Msg_\(conversationDigest)",
            rowCount: 1,
            score: 100,
            columns: ["local_id", "server_id", "local_type", "create_time", "packed_info_data"]
        )

        let result = try WeChatImageMessageResolver().resolve(
            message: record,
            candidate: candidate,
            exportRoot: exportRoot,
            accountRoot: accountRoot,
            calendar: fixtureCalendar
        )

        try expectEqual(result.resourceMatch, .exact)
        try expectEqual(result.fileBase?.source, .both)
        try expectEqual(result.fileBase?.confidence, .structured)
        try expectTrue(result.resourceDetailsFound)
        try expectTrue(result.assets.mainURL != nil)
        try expectTrue(result.assets.hdURL != nil)
        try expectTrue(result.assets.thumbnailURL != nil)
        try expectEqual(result.datVersion, .v2)
    }

    func testFileBaseConflictNeverBindsMedia() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let resourceDB = exportRoot.appending(path: "message/message_resource.db")
        try FileManager.default.createDirectory(at: resourceDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        let conversation = "fixture conversation conflict"
        let digest = fixtureMD5Hex(conversation)
        let messageBase = "0123456789abcdef0123456789abcdef"
        let resourceBase = "fedcba9876543210fedcba9876543210"
        let timestamp: Int64 = 1_738_368_000
        let messagePacked = Data([0x12, 0x22, 0x0A, 0x20]) + Data(messageBase.utf8)
        let resourcePacked = Data([0x12, 0x22, 0x0A, 0x20]) + Data(resourceBase.utf8)
        try createPlainSQLiteDatabase(at: resourceDB, sql: """
            CREATE TABLE ChatName2Id (user_name TEXT);
            INSERT INTO ChatName2Id (rowid, user_name) VALUES (1, '\(conversation)');
            CREATE TABLE MessageResourceInfo (message_id INTEGER, chat_id INTEGER, message_local_type INTEGER, message_create_time INTEGER, message_local_id INTEGER, message_svr_id INTEGER, packed_info BLOB);
            INSERT INTO MessageResourceInfo VALUES (1, 1, 3, \(timestamp), 9, 99, X'\(resourcePacked.map { String(format: "%02x", $0) }.joined())');
            """)
        let record = SourceMessageRecord(
            identity: .init(databaseRelativePath: "message/message_0.db", tableName: "Msg_\(digest)", rowIdentifier: "1"),
            values: [
                "local_id": .integer(9), "server_id": .integer(99), "local_type": .integer(3), "create_time": .integer(timestamp),
                "packed_info_data": .blob(.init(length: messagePacked.count, sha256: "fixture", data: messagePacked))
            ]
        )
        let candidate = MessageTableCandidate(databaseRelativePath: "message/message_0.db", tableName: "Msg_\(digest)", rowCount: 1, score: 1, columns: ["local_id", "server_id", "local_type", "create_time", "packed_info_data"])

        let resolution = try WeChatMessageResourceFileBaseResolver().resolve(message: record, candidate: candidate, exportRoot: exportRoot)

        try expectEqual(resolution.fileBaseEvidence, .conflict)
        try expectEqual(resolution.fileBase, nil)
        try expectTrue(resolution.diagnostics.contains(.fileBaseConflict))
    }

    func testExactResourceMatchWinsOverSameLocalIDFallbackCandidate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let resourceDB = exportRoot.appending(path: "message/message_resource.db")
        try FileManager.default.createDirectory(at: resourceDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        let conversation = "fixture exact resource"
        let digest = fixtureMD5Hex(conversation)
        let expected = "0123456789abcdef0123456789abcdef"
        let fallback = "fedcba9876543210fedcba9876543210"
        let timestamp: Int64 = 1_738_368_000
        let expectedPacked = Data([0x12, 0x22, 0x0A, 0x20]) + Data(expected.utf8)
        let fallbackPacked = Data([0x12, 0x22, 0x0A, 0x20]) + Data(fallback.utf8)
        try createPlainSQLiteDatabase(at: resourceDB, sql: """
            CREATE TABLE ChatName2Id (user_name TEXT);
            INSERT INTO ChatName2Id (rowid, user_name) VALUES (1, '\(conversation)');
            CREATE TABLE MessageResourceInfo (message_id INTEGER, chat_id INTEGER, message_local_type INTEGER, message_create_time INTEGER, message_local_id INTEGER, message_svr_id INTEGER, packed_info BLOB);
            INSERT INTO MessageResourceInfo VALUES (1, 1, 3, \(timestamp - 1), 9, 1, X'\(fallbackPacked.map { String(format: "%02x", $0) }.joined())');
            INSERT INTO MessageResourceInfo VALUES (2, 1, 3, \(timestamp), 9, 2, X'\(expectedPacked.map { String(format: "%02x", $0) }.joined())');
            """)
        let record = SourceMessageRecord(
            identity: .init(databaseRelativePath: "message/message_0.db", tableName: "Msg_\(digest)", rowIdentifier: "1"),
            values: ["local_id": .integer(9), "server_id": .integer(2), "local_type": .integer(3), "create_time": .integer(timestamp)]
        )
        let candidate = MessageTableCandidate(databaseRelativePath: "message/message_0.db", tableName: "Msg_\(digest)", rowCount: 1, score: 1, columns: ["local_id", "server_id", "local_type", "create_time"])

        let resolution = try WeChatMessageResourceFileBaseResolver().resolve(message: record, candidate: candidate, exportRoot: exportRoot)

        try expectEqual(resolution.resourceMatch, .exact)
        try expectEqual(resolution.fileBaseEvidence, .resourceExact)
        try expectEqual(resolution.fileBase?.value, expected)
    }

    func testPackedInfoParserDistinguishesStructuredMarkerFromFallback() throws {
        let fileBase = "0123456789abcdef0123456789abcdef"
        let parser = MessageResourcePackedInfoParser()

        let structured = parser.parse(Data([0x12, 0x22, 0x0A, 0x20]) + Data(fileBase.utf8))
        let fallback = parser.parse(Data([0xFF]) + Data(fileBase.utf8) + Data([0x00]))

        try expectEqual(structured?.confidence, .structured)
        try expectEqual(fallback?.confidence, .heuristic)
        try expectEqual(structured?.value, fileBase)
        try expectEqual(fallback?.value, fileBase)
    }

    func testImageAttachmentLocatorUsesPreviousMonthFallbackAndFindsVariants() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = String(repeating: "b", count: 32)
        let fileBase = "0123456789abcdef0123456789abcdef"
        let imageDirectory = directory.appending(path: "msg/attach/\(chat)/2025-01/Img")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try Data([0]).write(to: imageDirectory.appending(path: "\(fileBase)_t.dat"))

        let assets = try WeChatImageAttachmentLocator(calendar: fixtureCalendar).locate(
            accountRoot: directory,
            chatDirectoryComponent: chat,
            fileBase: fileBase,
            // 2025-02-01 00:00:00 UTC, so the fixture in 2025-01 is a true previous-month fallback.
            createTime: 1_738_368_000
        )

        try expectTrue(assets.mainURL == nil)
        try expectTrue(assets.hdURL == nil)
        try expectTrue(assets.thumbnailURL != nil)
        try expectTrue(assets.usedMonthFallback)
    }

    func testImageAttachmentLocatorPrefersCurrentMonthOverPreviousMonth() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = String(repeating: "b", count: 32)
        let fileBase = "0123456789abcdef0123456789abcdef"
        let previous = directory.appending(path: "msg/attach/\(chat)/2025-01/Img")
        let current = directory.appending(path: "msg/attach/\(chat)/2025-02/Img")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data([1]).write(to: previous.appending(path: "\(fileBase)_t.dat"))
        try Data([2]).write(to: current.appending(path: "\(fileBase)_t.dat"))

        let assets = try WeChatImageAttachmentLocator(calendar: fixtureCalendar).locate(
            accountRoot: directory,
            chatDirectoryComponent: chat,
            fileBase: fileBase,
            createTime: 1_738_368_000
        )

        try expectEqual(try Data(contentsOf: try XCTUnwrap(assets.thumbnailURL)), Data([2]))
        try expectFalse(assets.usedMonthFallback)
    }

    func testImageAttachmentLocatorRejectsMediaTreeSymlinkOutsideAccountRoot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountRoot = directory.appending(path: "Account")
        let outsideRoot = directory.appending(path: "Outside")
        let chat = String(repeating: "b", count: 32)
        let fileBase = "0123456789abcdef0123456789abcdef"
        let outsideImageDirectory = outsideRoot.appending(path: "attach/\(chat)/2025-02/Img")
        try FileManager.default.createDirectory(at: outsideImageDirectory, withIntermediateDirectories: true)
        try Data([0]).write(to: outsideImageDirectory.appending(path: "\(fileBase)_t.dat"))
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: accountRoot.appending(path: "msg"),
            withDestinationURL: outsideRoot
        )

        let assets = try WeChatImageAttachmentLocator(calendar: fixtureCalendar).locate(
            accountRoot: accountRoot,
            chatDirectoryComponent: chat,
            fileBase: fileBase,
            createTime: 1_738_368_000
        )

        try expectTrue(assets.thumbnailURL == nil)
        try expectFalse(assets.chatDirectoryFound)
    }

    func testImageDATV2DecoderRestoresSyntheticPNGAndRejectsWrongKey() throws {
        let image = syntheticPNGData()
        let key = Data("0123456789abcdef".utf8)
        let dat = try makeSyntheticV2DAT(plaintext: image, key: key, xorTail: Data([0xAA, 0xBB]))
        let material = WeChatImageKeyMaterial(aesKey: key, xorKey: 0x88)

        let decoded = try WeChatImageDatDecoder().decode(dat, keyMaterial: material)

        try expectEqual(decoded.version, .v2)
        try expectEqual(decoded.format, .png)
        try expectEqual(decoded.data, image + Data([0xAA, 0xBB]))
        try expectThrows(WeChatImageDATError.invalidPadding) {
            _ = try WeChatImageDatDecoder().decode(dat, keyMaterial: .init(aesKey: Data("fedcba9876543210".utf8), xorKey: 0x88))
        }
    }

    func testImageDATVersionDoesNotClassifyArbitraryBytesAsLegacyXOR() throws {
        let decoder = WeChatImageDatDecoder()
        let legacyPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D]).map { $0 ^ 0x88 }

        try expectEqual(decoder.version(for: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])), .unknown)
        try expectEqual(decoder.version(for: Data(legacyPNG)), .legacy)
    }

    func testKVCommImageKeyProviderDerivesCandidatesFromKnownFilenameAndAccountIDs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = directory.appending(path: "Documents")
        let accountRoot = documents.appending(path: "xwechat_files/wxid_fixture_c14c")
        let kvcomm = documents.appending(path: "app_data/net/kvcomm")
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kvcomm, withIntermediateDirectories: true)
        try Data().write(to: kvcomm.appending(path: "key_42_fixture.statistic"))

        let materials = try WeChatKVCommImageKeyProvider().keyCandidates(accountRoot: accountRoot)
        let expectedDigest = Insecure.MD5.hash(data: Data("42wxid_fixture_c14c".utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        try expectTrue(materials.contains {
            $0.aesKey == Data(expectedDigest.prefix(16).utf8) && $0.xorKey == 42
        })
    }

    func testKVCommImageKeyProviderUsesBoundedMetadataFallbackAndSkipsMediaTrees() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = directory.appending(path: "Documents")
        let accountRoot = documents.appending(path: "xwechat_files/wxid_fixture_c14c")
        let metadataDirectory = documents.appending(path: "global/config")
        let mediaDirectory = accountRoot.appending(path: "msg/attach")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try Data().write(to: metadataDirectory.appending(path: "key_42_fixture.statistic"))
        try Data().write(to: mediaDirectory.appending(path: "key_99_fixture.statistic"))

        let materials = try WeChatKVCommImageKeyProvider().keyCandidates(accountRoot: accountRoot)
        let expected42 = WeChatKVCommImageKeyProvider().derive(code: 42, accountIdentifier: "wxid_fixture_c14c")
        let excluded99 = WeChatKVCommImageKeyProvider().derive(code: 99, accountIdentifier: "wxid_fixture_c14c")

        try expectTrue(materials.contains(expected42))
        try expectFalse(materials.contains(excluded99))
    }

    func testImageResolutionCoordinatorStopsAtFirstVerifiedType3Image() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let accountRoot = directory.appending(path: "Account")
        let conversationDigest = fixtureMD5Hex("fixture conversation")
        let fileBase = "0123456789abcdef0123456789abcdef"
        let timestamp: Int64 = 1_738_368_000
        let packed = Data([0x12, 0x22, 0x0A, 0x20]) + Data(fileBase.utf8)
        let hex = packed.map { String(format: "%02x", $0) }.joined()
        let messageDatabase = exportRoot.appending(path: "message/message_0.db")
        let resourceDatabase = exportRoot.appending(path: "message/message_resource.db")
        try FileManager.default.createDirectory(at: messageDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: messageDatabase, sql: """
            CREATE TABLE Msg_\(conversationDigest) (local_id INTEGER, server_id INTEGER, local_type INTEGER, create_time INTEGER, packed_info_data BLOB);
            INSERT INTO Msg_\(conversationDigest) VALUES (42, 77, 3, \(timestamp), X'\(hex)');
            """)
        try createPlainSQLiteDatabase(at: resourceDatabase, sql: """
            CREATE TABLE ChatName2Id (user_name TEXT, update_time INTEGER);
            INSERT INTO ChatName2Id VALUES ('fixture conversation', 0);
            CREATE TABLE MessageResourceInfo (message_id INTEGER, chat_id INTEGER, sender_id INTEGER, message_local_type INTEGER, message_create_time INTEGER, message_local_id INTEGER, message_svr_id INTEGER, message_origin_source INTEGER, packed_info BLOB);
            INSERT INTO MessageResourceInfo VALUES (99, 1, 0, 3, \(timestamp), 42, 77, 0, X'\(hex)');
            """)
        let imageDirectory = accountRoot.appending(path: "msg/attach/\(conversationDigest)/2025-01/Img")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let key = Data("0123456789abcdef".utf8)
        let dat = try makeSyntheticV2DAT(plaintext: syntheticPNGData(), key: key, xorTail: Data())
        try dat.write(to: imageDirectory.appending(path: "\(fileBase)_t.dat"))
        let candidate = MessageTableCandidate(
            databaseRelativePath: "message/message_0.db",
            tableName: "Msg_\(conversationDigest)",
            rowCount: 1,
            score: 100,
            columns: ["local_id", "server_id", "local_type", "create_time", "packed_info_data"]
        )

        let result = try WeChatImageResolutionCoordinator().resolveFirstImage(
            exportRoot: exportRoot,
            candidate: candidate,
            accountRoot: accountRoot,
            keyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: key, xorKey: 0x88)]),
            calendar: fixtureCalendar
        )

        try expectEqual(result.sampledRecordCount, 1)
        try expectEqual(result.resolution?.resourceMatch, .exact)
        try expectFalse(result.resolution?.resourceDetailsFound ?? true)
        try expectTrue(result.keyDerivationAvailable)
        try expectTrue(result.keyVerificationPassed)
        try expectTrue(result.thumbnail.decoded)
        try expectEqual(result.thumbnail.format, .png)

        let locations = try WeChatImageResolutionReportWriter().write(result, to: directory.appending(path: ".local-analysis"))
        let report = try String(contentsOf: locations.jsonURL, encoding: .utf8)
        try expectEqual(try permissionBits(at: locations.directoryURL), 0o700)
        try expectEqual(try permissionBits(at: locations.jsonURL), 0o600)
        try expectFalse(report.contains(fileBase))
        try expectFalse(report.contains(accountRoot.path()))

        let unavailable = try WeChatImageResolutionCoordinator().resolveFirstImage(
            exportRoot: exportRoot,
            candidate: candidate,
            accountRoot: accountRoot,
            keyProvider: FixtureImageKeyProvider(materials: []),
            calendar: fixtureCalendar
        )
        try expectFalse(unavailable.keyDerivationAvailable)
        try expectTrue(unavailable.diagnostics.contains(.imageKeyUnavailable))

        let rejected = try WeChatImageResolutionCoordinator().resolveFirstImage(
            exportRoot: exportRoot,
            candidate: candidate,
            accountRoot: accountRoot,
            keyProvider: FixtureImageKeyProvider(materials: [.init(aesKey: Data("fedcba9876543210".utf8), xorKey: 0x88)]),
            calendar: fixtureCalendar
        )
        try expectTrue(rejected.keyDerivationAvailable)
        try expectFalse(rejected.keyVerificationPassed)
        try expectTrue(rejected.diagnostics.contains(.imageKeyRejected))
    }

    func testHardlinkCandidateCrossValidationQueriesOnlyMD5TextColumns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let mappingDatabase = exportRoot.appending(path: "hardlink/hardlink.db")
        try FileManager.default.createDirectory(at: mappingDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let candidate = "d41d8cd98f00b204e9800998ecf8427e"
        try createPlainSQLiteDatabase(at: mappingDatabase, sql: """
            CREATE TABLE image_hardlink_info_v4 (md5_hash INTEGER, md5 TEXT, file_name TEXT, dir1 INTEGER, dir2 INTEGER);
            CREATE TABLE video_hardlink_info_v4 (md5_hash INTEGER, md5 TEXT, file_name TEXT, dir1 INTEGER, dir2 INTEGER);
            CREATE TABLE file_hardlink_info_v4 (md5_hash INTEGER, md5 TEXT, file_name TEXT, dir1 INTEGER, dir2 INTEGER);
            INSERT INTO image_hardlink_info_v4 VALUES (123, '\(candidate)', 'fixture', 1, 2);
            INSERT INTO video_hardlink_info_v4 VALUES (456, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'fixture', 1, 2);
            """)

        let result = try WeChatMediaDatabaseMapper().crossValidate(hex32Candidates: [candidate], exportRoot: exportRoot)

        try expectEqual(result.candidateCount, 1)
        try expectEqual(result.uniqueCandidateCount, 1)
        try expectEqual(result.imageHits, 1)
        try expectEqual(result.videoHits, 0)
        try expectEqual(result.fileHits, 0)
        try expectEqual(result.noHitCount, 0)
    }

    func testHardlinkInspectorReportsFullSchemaIndexesAndHashRelationWithoutValues() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let mappingDatabase = exportRoot.appending(path: "hardlink/hardlink.db")
        try FileManager.default.createDirectory(at: mappingDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: mappingDatabase, sql: """
            CREATE TABLE image_hardlink_info_v4 (
                md5_hash INTEGER, md5 TEXT, type INTEGER, file_name TEXT,
                file_size INTEGER, modify_time INTEGER, dir1 INTEGER, dir2 INTEGER,
                extra_buffer BLOB
            );
            CREATE INDEX image_md5_hash_index ON image_hardlink_info_v4(md5_hash);
            INSERT INTO image_hardlink_info_v4 VALUES (1, 'd41d8cd98f00b204e9800998ecf8427e', 1, 'fixture', 4, 5, 6, 7, X'01');
            """)

        let inspection = try WeChatMediaDatabaseMapper().inspectHardlinkDatabase(exportRoot: exportRoot)
        let image = try unwrap(inspection.tables.first { $0.tableName == "image_hardlink_info_v4" })

        try expectEqual(image.rowCount, 1)
        try expectTrue(image.columns.contains { $0.name == "file_size" && $0.declaredType == "INTEGER" })
        try expectTrue(image.indexes.contains { $0.columns == ["md5_hash"] })
        try expectTrue(image.md5HashRelation?.isOneToOneWithMD5 == true)
    }

    func testAttachDirectoryInspectorCountsHeadersWithoutReturningFilenames() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountRoot = directory.appending(path: "Account")
        let attach = accountRoot.appending(path: "msg/attach")
        try FileManager.default.createDirectory(at: attach, withIntermediateDirectories: true)
        try syntheticPNGData().write(to: attach.appending(path: "first.dat"))
        let xorKey: UInt8 = 0x5A
        try Data(syntheticPNGData().map { $0 ^ xorKey }).write(to: attach.appending(path: "second.dat"))
        try Data("opaque".utf8).write(to: attach.appending(path: "third.dat"))

        let inspection = try WeChatAttachDirectoryInspector().inspect(accountRoot: accountRoot, maximumHeaderSamples: 100)

        try expectEqual(inspection.fileCount, 3)
        try expectEqual(inspection.extensionDistribution["dat"], 3)
        try expectEqual(inspection.plainImageCount, 1)
        try expectEqual(inspection.xorImageCount, 1)
        try expectEqual(inspection.unknownHeaderCount, 1)
    }

    func testType3ReportExcludesCandidateValuesAndWritesOnlyAggregates() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateCandidate = "d41d8cd98f00b204e9800998ecf8427e"
        let payloadAnalysis = Type3PayloadAnalysis(
            sampledRecordCount: 1,
            payloadObservations: [.init(
                sourceColumn: "packed_info_data",
                storageClass: .blob,
                byteLength: 32,
                compression: .none,
                payloadKind: .protobufLike,
                protobufFields: [.init(fieldNumber: 1, wireType: 2, valueLength: 16)]
            )],
            candidateIdentifiers: [.init(sourceColumn: "packed_info_data", offset: 0, representation: .hex32, length: 32, semanticHint: .hex32Candidate, valueKind: .hex32, value: privateCandidate)],
            identifierSummaries: [.init(sourceColumn: "packed_info_data", representation: .hex32, semanticHint: .hex32Candidate, count: 1)]
        )
        let result = Type3MediaLinkDiscoveryResult(
            payloadAnalysis: payloadAnalysis,
            hardlinkCrossValidation: .init(candidateCount: 1, uniqueCandidateCount: 1, imageHits: 0, videoHits: 0, fileHits: 0, noHitCount: 1),
            hardlinkDatabase: .init(tables: []),
            mediaMetadataSchema: nil,
            diagnostics: [.candidateIdentifierFound, .candidateIdentifierNotConfirmed]
        )

        let locations = try Type3MediaAnalysisReportWriter().write(result, attachInspection: nil, to: directory.appending(path: ".local-analysis"))
        let text = try String(contentsOf: locations.jsonURL, encoding: .utf8)

        try expectFalse(text.contains(privateCandidate))
        try expectTrue(text.contains("hex32Candidate"))
        try expectTrue(text.contains("protobufFieldAggregates"))
        try expectTrue(text.contains("fieldNumber"))
        try expectEqual(try permissionBits(at: locations.directoryURL), 0o700)
        try expectEqual(try permissionBits(at: locations.jsonURL), 0o600)
    }

    func testHardlinkTimeCorrelationReturnsOnlyUnitsAndOverlap() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let mappingDatabase = exportRoot.appending(path: "hardlink/hardlink.db")
        try FileManager.default.createDirectory(at: mappingDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: mappingDatabase, sql: """
            CREATE TABLE image_hardlink_info_v4 (md5 TEXT, file_name TEXT, dir1 INTEGER, dir2 INTEGER, modify_time INTEGER);
            INSERT INTO image_hardlink_info_v4 VALUES ('d41d8cd98f00b204e9800998ecf8427e', 'fixture', 1, 2, 150);
            """)

        let correlation = try unwrap(try WeChatMediaDatabaseMapper().correlateMessageTimes([100, 200], exportRoot: exportRoot))

        try expectEqual(correlation.messageTimeUnit, .seconds)
        try expectEqual(correlation.hardlinkModifyTimeUnit, .seconds)
        try expectTrue(correlation.rangesOverlap)
    }

    func testHardlinkTimeCorrelationReturnsNilWhenModifyTimeIsUnavailable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let mappingDatabase = exportRoot.appending(path: "hardlink/hardlink.db")
        try FileManager.default.createDirectory(at: mappingDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: mappingDatabase, sql: """
            CREATE TABLE image_hardlink_info_v4 (md5 TEXT, file_name TEXT, dir1 INTEGER, dir2 INTEGER);
            """)

        let correlation = try WeChatMediaDatabaseMapper().correlateMessageTimes([100, 200], exportRoot: exportRoot)

        try expectTrue(correlation == nil)
    }

    func testMessageDiscoveryPrefersCompressedPayloadForEmbeddedMediaReference() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let databaseURL = exportRoot.appending(path: "message/message_0.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE message (local_id INTEGER PRIMARY KEY, local_type INTEGER, create_time INTEGER, message_content TEXT, compress_content BLOB, packed_info_data BLOB);
            INSERT INTO message VALUES (1, 3, 1723800123, NULL, X'0102', CAST('prefix\(md5)suffix' AS BLOB));
            """)
        let candidate = try unwrap(WeChatMessageTableDiscovery().candidates(from: try SQLiteSchemaScanner().scan(exportRoot: exportRoot)).first)

        let analysis = try WeChatMessageDiscovery().inspect(exportRoot: exportRoot, candidate: candidate)

        try expectEqual(analysis.fieldMapping.payloadColumn, "compress_content")
        try expectTrue(analysis.mediaReferences.first?.confirmedMD5 == nil)
        try expectEqual(analysis.mediaReferences.first?.candidateIdentifiers.first?.value, md5)
    }

    func testMediaScannerDetectsPNGMagicAndResolverConfirmsExactMD5Match() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaRoot = directory.appending(path: "WeChatData")
        let imageURL = mediaRoot.appending(path: "msg/image/fixture-no-extension.dat")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let imageData = syntheticPNGData()
        try imageData.write(to: imageURL)
        let md5 = Insecure.MD5.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
        let reference = MediaReference(
            sourceMessageIdentity: .init(databaseRelativePath: "message/message_0.db", tableName: "message", rowIdentifier: "2"),
            mediaTypeHint: .image,
            md5: md5,
            mediaID: nil,
            relativePathHint: nil,
            metadataFieldNames: ["md5"]
        )

        let scan = try WeChatMediaScanner().scan(mediaRoot: mediaRoot)
        let file = try unwrap(scan.files.first)
        let link = try MessageMediaResolver().resolve(reference: reference, mediaFiles: scan.files)

        try expectEqual(file.format, .png)
        try expectEqual(file.imageDimensions?.width, 1)
        try expectEqual(file.imageDimensions?.height, 1)
        try expectTrue(file.sha256 == nil)
        try expectEqual(link.confidence, .exact)
        try expectEqual(link.resolvedFile?.relativePath, "msg/image/fixture-no-extension.dat")
        try expectEqual(link.reason, "Exact MD5 match")
    }

    func testMediaScannerDetectsXORObfuscatedPNGHeaderWithoutChangingFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaRoot = directory.appending(path: "WeChatData")
        let imageURL = mediaRoot.appending(path: "msg/image/fixture.dat")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let xorKey: UInt8 = 0x5A
        let original = syntheticPNGData()
        let encoded = Data(original.map { $0 ^ xorKey })
        try encoded.write(to: imageURL)

        let file = try unwrap(try WeChatMediaScanner().scan(mediaRoot: mediaRoot).files.first)
        let reference = MediaReference(
            sourceMessageIdentity: .init(databaseRelativePath: "message/message_0.db", tableName: "message", rowIdentifier: "2"),
            mediaTypeHint: .image,
            md5: Insecure.MD5.hash(data: original).map { String(format: "%02x", $0) }.joined(),
            mediaID: nil,
            relativePathHint: nil,
            metadataFieldNames: ["embedded_md5"]
        )
        let link = try MessageMediaResolver().resolve(reference: reference, mediaFiles: [file])

        try expectEqual(file.format, .png)
        try expectEqual(file.headerXORKey, xorKey)
        try expectEqual(file.imageDimensions?.width, 1)
        try expectEqual(file.imageDimensions?.height, 1)
        try expectEqual(link.confidence, .exact)
        try expectEqual(try Data(contentsOf: imageURL), encoded)
    }

    func testMessageMediaResolverLeavesFilenameOnlyReferenceUnresolved() throws {
        let reference = MediaReference(
            sourceMessageIdentity: .init(databaseRelativePath: "message/message_0.db", tableName: "message", rowIdentifier: "3"),
            mediaTypeHint: .image,
            md5: nil,
            mediaID: nil,
            relativePathHint: nil,
            metadataFieldNames: ["filename"]
        )
        let file = DiscoveredMediaFile(
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.png"),
            relativePath: "msg/image/fixture.png",
            fileSize: 1,
            fileExtension: "png",
            format: .png,
            imageDimensions: .init(width: 1, height: 1),
            sha256: nil
        )

        let link = try MessageMediaResolver().resolve(reference: reference, mediaFiles: [file])

        try expectEqual(link.confidence, .unresolved)
        try expectTrue(link.resolvedFile == nil)
    }

    func testMediaDatabaseMappingResolvesOnlyAUniqueFileBackedByExactMD5() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let mappingDatabase = exportRoot.appending(path: "hardlink/hardlink.db")
        let mediaRoot = directory.appending(path: "WeChatData")
        let imageURL = mediaRoot.appending(path: "msg/image/fixture.png")
        try FileManager.default.createDirectory(at: mappingDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try syntheticPNGData().write(to: imageURL)
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        try createPlainSQLiteDatabase(at: mappingDatabase, sql: """
            CREATE TABLE image_hardlink_info_v4 (md5 TEXT, md5_hash TEXT, file_name TEXT, dir1 TEXT, dir2 TEXT);
            INSERT INTO image_hardlink_info_v4 VALUES ('\(md5)', NULL, 'fixture.png', 'msg', 'image');
            """)
        let reference = MediaReference(
            sourceMessageIdentity: .init(databaseRelativePath: "message/message_0.db", tableName: "message", rowIdentifier: "2"),
            mediaTypeHint: .image,
            md5: md5,
            mediaID: nil,
            relativePathHint: nil,
            metadataFieldNames: ["embedded_md5"]
        )
        let link = WeChatMediaDatabaseMapper().resolve(
            reference: reference,
            exportRoot: exportRoot,
            mediaRoot: mediaRoot
        )

        try expectEqual(link.confidence, .exact)
        try expectEqual(link.diagnostic, .resolved)
        try expectEqual(link.mappingRule, .accountRootRelative)
        try expectEqual(link.resolvedFile?.relativePath, "msg/image/fixture.png")
        try expectEqual(link.reason, "Exact MD5 hardlink mapping")
    }

    func testMediaDatabaseMapperPreservesHardlinkDiagnosticsInsteadOfUnresolved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let mediaRoot = directory.appending(path: "WeChatData")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let reference = MediaReference(
            sourceMessageIdentity: .init(databaseRelativePath: "message/message_0.db", tableName: "message", rowIdentifier: "2"),
            mediaTypeHint: .image,
            md5: "d41d8cd98f00b204e9800998ecf8427e",
            mediaID: nil,
            relativePathHint: nil,
            metadataFieldNames: ["embedded_md5"]
        )

        let missing = WeChatMediaDatabaseMapper().resolve(reference: reference, exportRoot: exportRoot, mediaRoot: mediaRoot)
        try expectEqual(missing.diagnostic, .hardlinkDatabaseMissing)
        try expectEqual(missing.confidence, .unresolved)

        let mappingDatabase = exportRoot.appending(path: "hardlink/hardlink.db")
        try FileManager.default.createDirectory(at: mappingDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: mappingDatabase, sql: "CREATE TABLE unsupported (value TEXT);")
        let unsupported = WeChatMediaDatabaseMapper().resolve(reference: reference, exportRoot: exportRoot, mediaRoot: mediaRoot)
        try expectEqual(unsupported.diagnostic, .hardlinkSchemaUnsupported)

        try FileManager.default.removeItem(at: mappingDatabase)
        try Data("not a SQLite database".utf8).write(to: mappingDatabase)
        let queryFailure = WeChatMediaDatabaseMapper().resolve(reference: reference, exportRoot: exportRoot, mediaRoot: mediaRoot)
        try expectEqual(queryFailure.diagnostic, .hardlinkQueryFailed)
    }

    func testMediaDatabaseMapperDistinguishesNoMultipleAndMissingFileMappings() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let mappingDatabase = exportRoot.appending(path: "hardlink/hardlink.db")
        let mediaRoot = directory.appending(path: "WeChatData")
        try FileManager.default.createDirectory(at: mappingDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        try createPlainSQLiteDatabase(at: mappingDatabase, sql: """
            CREATE TABLE image_hardlink_info_v4 (md5 TEXT, md5_hash TEXT, file_name TEXT, dir1 TEXT, dir2 TEXT);
            INSERT INTO image_hardlink_info_v4 VALUES ('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', NULL, 'none.png', 'msg', 'image');
            """)
        let reference = MediaReference(
            sourceMessageIdentity: .init(databaseRelativePath: "message/message_0.db", tableName: "message", rowIdentifier: "2"),
            mediaTypeHint: .image,
            md5: md5,
            mediaID: nil,
            relativePathHint: nil,
            metadataFieldNames: ["embedded_md5"]
        )

        let noMapping = WeChatMediaDatabaseMapper().resolve(reference: reference, exportRoot: exportRoot, mediaRoot: mediaRoot)
        try expectEqual(noMapping.diagnostic, .hardlinkNoMapping)

        try createPlainSQLiteDatabase(at: mappingDatabase, sql: """
            INSERT INTO image_hardlink_info_v4 VALUES ('\(md5)', NULL, 'first.png', 'msg', 'image');
            INSERT INTO image_hardlink_info_v4 VALUES ('\(md5)', NULL, 'second.png', 'msg', 'image');
            """)
        let multiple = WeChatMediaDatabaseMapper().resolve(reference: reference, exportRoot: exportRoot, mediaRoot: mediaRoot)
        try expectEqual(multiple.diagnostic, .hardlinkMultipleMappings)

        try createPlainSQLiteDatabase(at: mappingDatabase, sql: "DELETE FROM image_hardlink_info_v4 WHERE md5 = '\(md5)'; INSERT INTO image_hardlink_info_v4 VALUES ('\(md5)', NULL, 'missing.png', 'msg', 'image');")
        let missingFile = WeChatMediaDatabaseMapper().resolve(reference: reference, exportRoot: exportRoot, mediaRoot: mediaRoot)
        try expectEqual(missingFile.diagnostic, .mappedFileMissing)
    }

    func testMediaDatabaseMapperReportsUnsupportedMappedMediaWithoutScanningTheRoot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let mappingDatabase = exportRoot.appending(path: "hardlink/hardlink.db")
        let mediaRoot = directory.appending(path: "WeChatData")
        let fileURL = mediaRoot.appending(path: "msg/image/opaque.dat")
        try FileManager.default.createDirectory(at: mappingDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a supported media format".utf8).write(to: fileURL)
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        try createPlainSQLiteDatabase(at: mappingDatabase, sql: """
            CREATE TABLE image_hardlink_info_v4 (md5 TEXT, md5_hash TEXT, file_name TEXT, dir1 TEXT, dir2 TEXT);
            INSERT INTO image_hardlink_info_v4 VALUES ('\(md5)', NULL, 'opaque.dat', 'msg', 'image');
            """)
        let reference = MediaReference(
            sourceMessageIdentity: .init(databaseRelativePath: "message/message_0.db", tableName: "message", rowIdentifier: "2"),
            mediaTypeHint: .image,
            md5: md5,
            mediaID: nil,
            relativePathHint: nil,
            metadataFieldNames: ["embedded_md5"]
        )

        let result = WeChatMediaDatabaseMapper().resolve(reference: reference, exportRoot: exportRoot, mediaRoot: mediaRoot)

        try expectEqual(result.diagnostic, .mediaDecodeUnsupported)
        try expectTrue(result.resolvedFile == nil)
    }

    func testCoordinatorReportsWhenFallbackMediaScanReachesItsBound() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let databaseURL = exportRoot.appending(path: "message/message_0.db")
        let mediaRoot = directory.appending(path: "WeChatData")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaRoot.appending(path: "msg/opaque"), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: mediaRoot.appending(path: "msg/opaque/one.dat"))
        try Data("second".utf8).write(to: mediaRoot.appending(path: "msg/opaque/two.dat"))
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE message (local_id INTEGER PRIMARY KEY, local_type INTEGER, create_time INTEGER, packed_info_data BLOB);
            INSERT INTO message VALUES (1, 3, 1723800123, CAST('d41d8cd98f00b204e9800998ecf8427e' AS BLOB));
            """)
        let candidate = try unwrap(WeChatMessageTableDiscovery().candidates(from: try SQLiteSchemaScanner().scan(exportRoot: exportRoot)).first)

        let result = try MessageMediaDiscoveryCoordinator().discover(
            exportRoot: exportRoot,
            candidate: candidate,
            mediaRoot: mediaRoot,
            mediaScanMaximumResults: 1
        )

        try expectTrue(result.mediaScan?.isTruncated == true)
        try expectTrue(result.diagnostics.contains(.mediaScanTruncated))
        // An unkeyed hex32 payload is an identifier candidate, not a confirmed
        // MD5. The fallback scan still reports truncation, but it must not
        // claim that the absent hardlink database was queried for this value.
        try expectEqual(result.links.first?.diagnostic, .noSafeFallbackMatch)
    }

    func testSingleFileInspectionRejectsSymbolicLinksBeforeResolvingThem() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaRoot = directory.appending(path: "WeChatData")
        let target = directory.appending(path: "outside.png")
        let link = mediaRoot.appending(path: "msg/image/link.dat")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try syntheticPNGData().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try expectThrows(ArchiveError.invalidInput) {
            _ = try WeChatMediaScanner().inspect(mediaFileURL: link, below: mediaRoot)
        }
    }

    func testMessageDiscoveryReportExcludesSampleTextAndAbsoluteMediaPaths() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let mediaRoot = directory.appending(path: "WeChatData")
        let databaseURL = exportRoot.appending(path: "message/message_0.db")
        let imageURL = mediaRoot.appending(path: "msg/image/fixture.png")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let imageData = syntheticPNGData()
        try imageData.write(to: imageURL)
        let md5 = Insecure.MD5.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE message (local_id INTEGER PRIMARY KEY, local_type INTEGER, create_time INTEGER, message_content TEXT, packed_info_data BLOB);
            INSERT INTO message VALUES (1, 3, 1723800123, '<msg><img md5="\(md5)" /></msg>', X'01');
            INSERT INTO message VALUES (2, 9, 1723800124, NULL, X'01');
            """)
        let candidate = try unwrap(WeChatMessageTableDiscovery().candidates(from: try SQLiteSchemaScanner().scan(exportRoot: exportRoot)).first)
        let result = try MessageMediaDiscoveryCoordinator().discover(
            exportRoot: exportRoot,
            candidate: candidate,
            mediaRoot: mediaRoot,
            sampleLimit: 100
        )
        let reportDirectory = directory.appending(path: ".local-analysis")

        let locations = try MessageDiscoveryReportWriter().write(result, to: reportDirectory)
        let reportText = try String(contentsOf: locations.markdownURL, encoding: .utf8)
        let reportJSON = try String(contentsOf: locations.jsonURL, encoding: .utf8)

        try expectEqual(try permissionBits(at: reportDirectory), 0o700)
        try expectEqual(try permissionBits(at: locations.markdownURL), 0o600)
        try expectFalse(reportText.contains("<msg><img"))
        try expectFalse(reportJSON.contains("<msg><img"))
        try expectFalse(reportText.contains(directory.path()))
        try expectFalse(reportJSON.contains(directory.path()))
        let blobDigest = SHA256.hash(data: Data([1])).map { String(format: "%02x", $0) }.joined()
        try expectFalse(reportText.contains(blobDigest))
        try expectFalse(reportJSON.contains(blobDigest))
    }

    func testSQLiteSchemaClassifierUsesSchemaSignalsInsteadOfPathAlone() throws {
        let messageTable = SQLiteTableInfo(
            name: "records",
            rowCount: 3,
            columns: [
                .init(name: "local_id", declaredType: "INTEGER", isNullable: false, primaryKeyPosition: 1, hasDefaultValue: false),
                .init(name: "create_time", declaredType: "INTEGER", isNullable: false, primaryKeyPosition: 0, hasDefaultValue: false),
                .init(name: "sender", declaredType: "TEXT", isNullable: false, primaryKeyPosition: 0, hasDefaultValue: false),
                .init(name: "payload", declaredType: "BLOB", isNullable: true, primaryKeyPosition: 0, hasDefaultValue: false)
            ],
            indexes: [],
            foreignKeys: [],
            isVirtual: false,
            isFTSShadowTable: false
        )

        let pathOnly = WeChatDatabaseClassifier().classify(relativePath: "message/opaque.db", tables: [])
        let schemaBacked = WeChatDatabaseClassifier().classify(relativePath: "misc/opaque.db", tables: [messageTable])

        try expectEqual(pathOnly.category, .message)
        try expectEqual(pathOnly.certainty, .likely)
        try expectEqual(schemaBacked.category, .message)
        try expectEqual(schemaBacked.certainty, .detected)
        try expectTrue(schemaBacked.confidence > pathOnly.confidence)
    }

    func testSchemaReportWriterCreatesPrivateReportsWithoutAbsolutePathsOrValues() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportRoot = directory.appending(path: "Export")
        let databaseURL = exportRoot.appending(path: "contact/contact.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: databaseURL, sql: """
            CREATE TABLE contact (id INTEGER PRIMARY KEY, username TEXT, nickname TEXT, avatar BLOB);
            INSERT INTO contact(username, nickname, avatar) VALUES ('private-wxid', 'private-name', X'01');
            """)
        let report = try SQLiteSchemaScanner().scan(exportRoot: exportRoot)
        let reportDirectory = directory.appending(path: "SchemaReports")

        let locations = try SQLiteSchemaReportWriter().write(report, to: reportDirectory)
        let markdown = try String(contentsOf: locations.summaryMarkdownURL, encoding: .utf8)
        let json = try String(contentsOf: locations.summaryJSONURL, encoding: .utf8)

        try expectTrue(FileManager.default.fileExists(atPath: locations.databaseReportURLs.first?.path() ?? ""))
        try expectEqual(try permissionBits(at: reportDirectory), 0o700)
        try expectEqual(try permissionBits(at: locations.summaryMarkdownURL), 0o600)
        try expectEqual(try permissionBits(at: locations.summaryJSONURL), 0o600)
        try expectFalse(markdown.contains(directory.path()))
        try expectFalse(json.contains(directory.path()))
        try expectFalse(markdown.contains("private-wxid"))
        try expectFalse(markdown.contains("private-name"))
        try expectFalse(json.contains("private-wxid"))
        try expectFalse(json.contains("private-name"))
    }

    func testDatabaseScannerAndBatchExporterMatchRelativePathsExportPlainSQLiteAndPreserveSource() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceRoot = directory.appending(path: "db_storage")
        let contactDirectory = sourceRoot.appending(path: "contact")
        let messageDirectory = sourceRoot.appending(path: "message")
        try FileManager.default.createDirectory(at: contactDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: messageDirectory, withIntermediateDirectories: true)
        let contactDatabase = contactDirectory.appending(path: "contact.db")
        let messageDatabase = messageDirectory.appending(path: "contact.db")
        let contactKey = randomKeyHex()
        try makeEncryptedTestDatabase(at: contactDatabase, keyHex: contactKey)
        try makeEncryptedTestDatabase(at: messageDatabase, keyHex: randomKeyHex())
        let sourceHash = try sha256Hex(of: contactDatabase)

        let mapURL = directory.appending(path: "all_keys.json")
        try Data("""
        {
          "contact/contact.db": { "enc_key": "\(contactKey)" },
          "message/contact.db": { "enc_key": "\(randomKeyHex())" }
        }
        """.utf8).write(to: mapURL)

        let scanned = try WeChatDatabaseScanner().scan(
            databaseRoot: sourceRoot,
            keyMap: try WXCLIKeyMapProvider(url: mapURL)
        )
        try expectEqual(scanned.map(\.relativePath), ["contact/contact.db", "message/contact.db"])
        try expectTrue(scanned.allSatisfy(\.hasMatchedKey))

        let coordinator = try WeChatDatabaseExportCoordinator(decryptor: SQLCipherDatabaseDecryptor())
        let validated = coordinator.validateAll(scanned)
        try expectEqual(validated[0].validationStatus, .valid)
        try expectEqual(validated[1].validationStatus, .invalid)

        let exportRoot = directory.appending(path: "Export")
        let exported = try coordinator.exportValidatedDatabases(validated, to: exportRoot)
        let output = exportRoot.appending(path: "contact/contact.db")
        try expectEqual(exported[0].exportStatus, .exported)
        try expectEqual(exported[1].exportStatus, .skippedInvalid)
        try expectFalse(exported[0].hasAvailableKey)
        try expectFalse(exported[1].hasAvailableKey)
        try expectTrue(FileManager.default.fileExists(atPath: output.path()))
        try expectEqual(Data(try Data(contentsOf: output).prefix(16)), Data("SQLite format 3\0".utf8))
        try expectEqual(try readPlaintextFixtureBody(from: output), "synthetic fixture only")
        try expectEqual(try sha256Hex(of: contactDatabase), sourceHash)
        try expectEqual(try permissionBits(at: exportRoot), 0o700)
        try expectEqual(try permissionBits(at: output.deletingLastPathComponent()), 0o700)
        try expectEqual(try permissionBits(at: output), 0o600)
    }

    func testBatchExporterSkipsExistingDestinationsWithoutOverwritingThem() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceRoot = directory.appending(path: "db_storage")
        let sourceDirectory = sourceRoot.appending(path: "contact")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceDatabase = sourceDirectory.appending(path: "contact.db")
        let key = randomKeyHex()
        try makeEncryptedTestDatabase(at: sourceDatabase, keyHex: key)
        let mapURL = directory.appending(path: "all_keys.json")
        try Data("{ \"contact/contact.db\": { \"enc_key\": \"\(key)\" } }".utf8).write(to: mapURL)
        let scanned = try WeChatDatabaseScanner().scan(databaseRoot: sourceRoot, keyMap: try WXCLIKeyMapProvider(url: mapURL))
        let coordinator = try WeChatDatabaseExportCoordinator(decryptor: SQLCipherDatabaseDecryptor())
        let validated = coordinator.validateAll(scanned)

        let exportRoot = directory.appending(path: "Export")
        let existing = exportRoot.appending(path: "contact/contact.db")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("do not overwrite".utf8).write(to: existing)

        let exported = try coordinator.exportValidatedDatabases(validated, to: exportRoot)

        try expectEqual(exported.first?.exportStatus, .destinationExists)
        try expectEqual(try String(contentsOf: existing, encoding: .utf8), "do not overwrite")
        try expectFalse(FileManager.default.contentsOfDirectory(atPath: exportRoot.path()).contains { $0.hasPrefix(".wechatarchive-staging-") })
    }

    func testBatchExporterCleansProtectedStagingWhenPlaintextVerificationFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceRoot = directory.appending(path: "db_storage")
        let sourceDirectory = sourceRoot.appending(path: "contact")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data("synthetic encrypted source".utf8).write(to: sourceDirectory.appending(path: "contact.db"))
        let mapURL = directory.appending(path: "all_keys.json")
        try Data("{ \"contact/contact.db\": { \"enc_key\": \"\(randomKeyHex())\" } }".utf8).write(to: mapURL)
        let scanned = try WeChatDatabaseScanner().scan(databaseRoot: sourceRoot, keyMap: try WXCLIKeyMapProvider(url: mapURL))
        let coordinator = WeChatDatabaseExportCoordinator(decryptor: InvalidPlaintextDecryptor())
        let validated = coordinator.validateAll(scanned)
        try expectEqual(validated.first?.validationStatus, .valid)

        let exportRoot = directory.appending(path: "Export")
        let exported = try coordinator.exportValidatedDatabases(validated, to: exportRoot)

        try expectEqual(exported.first?.exportStatus, .failed)
        try expectFalse(FileManager.default.fileExists(atPath: exportRoot.appending(path: "contact/contact.db").path()))
        try expectFalse(FileManager.default.contentsOfDirectory(atPath: exportRoot.path()).contains { $0.hasPrefix(".wechatarchive-staging-") })
    }

    private func makeMessage(
        id: String,
        timestamp: Date,
        type: MessageType,
        content: String?,
        raw: [String: String]? = nil,
        sourceMessageID: String? = "source-id",
        conversationID: String = "chat-1"
    ) -> Message {
        Message(
            id: id,
            sourceMessageID: sourceMessageID,
            conversationID: conversationID,
            timestamp: timestamp,
            sourceTimeZone: "Asia/Shanghai",
            sender: MessageSender(id: "wxid_friend", displayName: "朋友"),
            type: type,
            content: content,
            replyTo: nil,
            media: [],
            raw: raw
        )
    }

    /// Opt-in local acceptance coverage. Measures how many currently-
    /// `unknown` messages `WeChatCompressedTextMessageAdapter` recovers
    /// against a real archive, broken down only by `raw_local_type`'s low
    /// 32 bits. It never inspects or prints recovered message text, only
    /// aggregate counts, mirroring ConversationExportTests's real-archive
    /// acceptance test.
    func testOptionalCompressedTextMessageAdapterCoverageAgainstRealArchive() throws {
        guard let rootPath = ProcessInfo.processInfo.environment["WECHAT_ARCHIVE_REAL_ROOT"], !rootPath.isEmpty else {
            throw XCTSkip("Set WECHAT_ARCHIVE_REAL_ROOT for local archive acceptance coverage.")
        }
        let databaseURL = URL(fileURLWithPath: rootPath).appending(path: "archive.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path(), &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw TestFailure(description: "Could not open the real archive read-only.")
        }
        defer { sqlite3_close(handle) }

        var idStatement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT id, raw_local_type FROM messages WHERE normalized_type = 'unknown'", -1, &idStatement, nil), SQLITE_OK)
        defer { sqlite3_finalize(idStatement) }

        var totalUnknown = 0
        var totalRecovered = 0
        var recoveredByLow32 = [UInt64: Int]()

        while sqlite3_step(idStatement) == SQLITE_ROW {
            totalUnknown += 1
            guard let idText = sqlite3_column_text(idStatement, 0) else { continue }
            let messageID = String(cString: idText)
            let rawType: Int64? = sqlite3_column_type(idStatement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(idStatement, 1)

            var valueStatement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT column_name, sqlite_type, integer_value, real_value, text_value, blob_value FROM message_source_values WHERE message_id = ?", -1, &valueStatement, nil), SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(valueStatement, 1, messageID, -1, transient)
            var values = [String: ArchivedSQLiteValue]()
            while sqlite3_step(valueStatement) == SQLITE_ROW {
                guard let nameText = sqlite3_column_text(valueStatement, 0), let typeText = sqlite3_column_text(valueStatement, 1) else { continue }
                let name = String(cString: nameText)
                switch String(cString: typeText) {
                case "integer": values[name] = .integer(sqlite3_column_int64(valueStatement, 2))
                case "real": values[name] = .real(sqlite3_column_double(valueStatement, 3))
                case "text":
                    if let text = sqlite3_column_text(valueStatement, 4) { values[name] = .text(String(cString: text)) }
                case "blob":
                    if let bytes = sqlite3_column_blob(valueStatement, 5) {
                        values[name] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(valueStatement, 5))))
                    }
                default: break
                }
            }
            sqlite3_finalize(valueStatement)

            if WeChatCompressedTextMessageAdapter().textContent(from: values, rawType: rawType) != nil {
                totalRecovered += 1
                recoveredByLow32[rawTypeLow32(rawType) ?? 0, default: 0] += 1
            }
        }

        // Aggregate counts only: never print message content or identifiers.
        let breakdown = recoveredByLow32.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        print("Compressed-text adapter coverage: unknown=\(totalUnknown) recovered=\(totalRecovered) byLow32=[\(breakdown)]")
        XCTAssertGreaterThan(totalRecovered, 0)
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)!
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WeChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a real zstd-compressed fixture via the local `zstd` CLI (the
    /// same external tool `ZstdPayloadDecompressor` depends on), so these
    /// tests exercise the actual decode path rather than a hand-rolled
    /// stand-in for the compressed format.
    private func zstdCompress(_ text: String) throws -> Data {
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("zstd CLI not available locally; install via `brew bundle`.")
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appending(path: "fixture.txt")
        let outputURL = directory.appending(path: "fixture.zst")
        try Data(text.utf8).write(to: inputURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-q", "-f", "-o", outputURL.path(), inputURL.path()]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestFailure(description: "zstd compression failed") }
        return try Data(contentsOf: outputURL)
    }

    private func permissionBits(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path())
        guard let permissions = attributes[.posixPermissions] as? Int else {
            throw TestFailure(description: "Missing permissions for test artifact")
        }
        return permissions & 0o777
    }

    private func randomKeyHex() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max)) }.joined()
    }

    private func sha256Hex(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func makeEncryptedTestDatabase(at url: URL, keyHex: String) throws {
        let script = """
            .bail on
            PRAGMA key = "x'\(keyHex)'";
            CREATE TABLE test_messages (id INTEGER PRIMARY KEY, body TEXT NOT NULL);
            INSERT INTO test_messages(body) VALUES ('synthetic fixture only');
            """
        try runSQLCipher(databaseURL: url, script: script)
    }

    private func createPlainSQLiteDatabase(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path(), &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw TestFailure(description: "Could not create synthetic SQLite fixture")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestFailure(description: "Could not populate synthetic SQLite fixture")
        }
    }

    private func makeArchiveV1SourceFixture(in directory: URL) throws -> ArchiveV1Fixture {
        let exportRoot = directory.appending(path: "Export")
        let accountRoot = directory.appending(path: "Account")
        let conversationName = "archive fixture conversation"
        let conversationDigest = fixtureMD5Hex(conversationName)
        let tableName = "Msg_\(conversationDigest)"
        let fileBase = "0123456789abcdef0123456789abcdef"
        let packedInfo = Data([0x12, 0x22, 0x0A, 0x20]) + Data(fileBase.utf8)
        let packedHex = packedInfo.map { String(format: "%02x", $0) }.joined()
        let textBlob = Data([0x00, 0x01, 0x02, 0xFF])
        let textBlobHex = textBlob.map { String(format: "%02x", $0) }.joined()
        let timestamp: Int64 = 1_738_368_000
        let messageDatabase = exportRoot.appending(path: "message/message_0.db")
        let resourceDatabase = exportRoot.appending(path: "message/message_resource.db")
        try FileManager.default.createDirectory(at: messageDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createPlainSQLiteDatabase(at: messageDatabase, sql: """
            CREATE TABLE \(tableName) (
                local_id INTEGER, server_id INTEGER, local_type INTEGER, real_sender_id TEXT,
                receiver_id TEXT, create_time INTEGER, source TEXT, message_content TEXT,
                compress_content BLOB, packed_info_data BLOB, integer_value INTEGER,
                real_value REAL, null_value TEXT
            );
            INSERT INTO \(tableName) VALUES (1, 101, 1, 'sender-a', 'receiver-a', \(timestamp), 'conversation-a', 'synthetic text', X'\(textBlobHex)', X'00', 42, 3.5, NULL);
            INSERT INTO \(tableName) VALUES (2, 102, 3, 'sender-b', 'receiver-b', \(timestamp + 1), 'conversation-a', NULL, X'ABCD', X'\(packedHex)', 43, 4.5, NULL);
            INSERT INTO \(tableName) VALUES (3, 103, 34, 'sender-c', 'receiver-c', \(timestamp + 2), 'conversation-a', NULL, X'01020304', X'00', 44, 5.5, NULL);
            INSERT INTO \(tableName) VALUES (4, 104, 43, 'sender-d', 'receiver-d', \(timestamp + 3), 'conversation-a', NULL, X'01020304', X'\(packedHex)', 45, 6.5, NULL);
            INSERT INTO \(tableName) VALUES (5, 105, 49, 'sender-e', 'receiver-e', \(timestamp + 4), 'conversation-a', NULL, X'01020304', X'00', 46, 7.5, NULL);
            """)
        try createPlainSQLiteDatabase(at: resourceDatabase, sql: """
            CREATE TABLE ChatName2Id (user_name TEXT, update_time INTEGER);
            INSERT INTO ChatName2Id VALUES ('\(conversationName)', 0);
            CREATE TABLE MessageResourceInfo (message_id INTEGER, chat_id INTEGER, sender_id INTEGER, message_local_type INTEGER, message_create_time INTEGER, message_local_id INTEGER, message_svr_id INTEGER, message_origin_source INTEGER, packed_info BLOB);
            INSERT INTO MessageResourceInfo VALUES (99, 1, 0, 3, \(timestamp + 1), 2, 102, 0, X'\(packedHex)');
            INSERT INTO MessageResourceInfo VALUES (100, 1, 0, 43, \(timestamp + 3), 4, 104, 0, X'\(packedHex)');
            CREATE TABLE MessageResourceDetail (resource_id INTEGER, message_id INTEGER, type INTEGER, size INTEGER, create_time INTEGER, access_time INTEGER, status INTEGER, data_index TEXT, packed_info BLOB);
            INSERT INTO MessageResourceDetail VALUES (1, 99, 1, 1, \(timestamp), \(timestamp), 0, 'fixture', X'00');
            """)
        let imageKey = Data("0123456789abcdef".utf8)
        let dat = try makeSyntheticV2DAT(plaintext: syntheticPNGData(), key: imageKey, xorTail: Data())
        let imageDirectory = accountRoot.appending(path: "msg/attach/\(conversationDigest)/2025-02/Img")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let thumbnailDATURL = imageDirectory.appending(path: "\(fileBase)_t.dat")
        try dat.write(to: thumbnailDATURL)
        let videoDirectory = accountRoot.appending(path: "msg/video/2025-02")
        try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]).write(to: videoDirectory.appending(path: "\(fileBase).mp4"))
        try syntheticPNGData().write(to: videoDirectory.appending(path: "\(fileBase)_thumb.jpg"))
        let voiceDatabase = exportRoot.appending(path: "message/media_0.db")
        try createPlainSQLiteDatabase(at: voiceDatabase, sql: """
            CREATE TABLE VoiceInfo (chat_name_id INTEGER, create_time INTEGER, local_id INTEGER, svr_id INTEGER, voice_data BLOB, data_index TEXT);
            INSERT INTO VoiceInfo VALUES (1, \(timestamp + 2), 3, 103, X'02232153494C4B5F5633300000', '0');
            """)
        return ArchiveV1Fixture(
            exportRoot: exportRoot,
            accountRoot: accountRoot,
            tableName: tableName,
            imageKey: imageKey,
            textBlob: textBlob,
            thumbnailDATURL: thumbnailDATURL
        )
    }

    private func syntheticPNGData() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAH/iZk9HQAAAABJRU5ErkJggg==")!
    }

    private func runSQLCipher(databaseURL: URL, script: String) throws {
        guard let executable = sqlcipherExecutableURL() else {
            throw TestFailure(description: "SQLCipher runtime is not installed")
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["-batch", databaseURL.path()]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestFailure(description: "Synthetic SQLCipher fixture creation failed") }
    }

    private func readPlaintextFixtureBody(from databaseURL: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path(), "SELECT body FROM test_messages"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestFailure(description: "Plaintext export cannot be queried by SQLite") }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sqlcipherExecutableURL() -> URL? {
        ["/opt/homebrew/bin/sqlcipher", "/usr/local/bin/sqlcipher"]
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path()) })
    }
}

private final class PlaintextDestinationRecorder: @unchecked Sendable {
    var destination: URL?
}

private struct InvalidPlaintextDecryptor: WeChatDatabaseDecryptor {
    func validate(databaseURL: URL, key: WeChatDatabaseKey) throws {}

    func decrypt(databaseURL: URL, key: WeChatDatabaseKey, into workingDirectory: URL) throws -> URL {
        let output = workingDirectory.appending(path: "invalid-plaintext.sqlite")
        try Data("not sqlite".utf8).write(to: output)
        try Data("temporary sidecar".utf8).write(to: URL(fileURLWithPath: output.path() + "-wal"))
        return output
    }
}

private struct FixtureImageKeyProvider: WeChatImageKeyProvider {
    let materials: [WeChatImageKeyMaterial]

    func keyCandidates(accountRoot: URL) throws -> [WeChatImageKeyMaterial] {
        materials
    }
}

private struct FixtureVoiceDecoder: VoiceDecoder {
    let pcm: Data
    let sampleRate: Int

    func decode(_ data: Data) throws -> DecodedVoice {
        guard VoiceFormatDetector().detect(data) == .silk else { throw VoiceDecoderError.unsupportedFormat }
        return .init(pcmData: pcm, sampleRate: sampleRate, channels: 1)
    }
}

private struct UnavailableVoiceDecoder: VoiceDecoder {
    func decode(_ data: Data) throws -> DecodedVoice { throw VoiceDecoderError.decoderUnavailable }
}

private struct FailingArchiveV1MediaStore: ArchiveV1MediaStoring {
    func storeRawData(_ data: Data, mediaType: ArchiveV1MediaType, variant: ArchiveV1MediaVariant, sourceFormat: String?, assetID: String) throws -> ArchiveV1StoredMedia {
        throw ArchiveError.ioFailure
    }

    func storeRawFile(_ source: URL, mediaType: ArchiveV1MediaType, variant: ArchiveV1MediaVariant, sourceFormat: String?, assetID: String) throws -> ArchiveV1StoredMedia {
        throw ArchiveError.ioFailure
    }

    func storeDecodedData(_ data: Data, mediaType: ArchiveV1MediaType, format: String?, assetID: String) throws -> ArchiveV1StoredMedia {
        throw ArchiveError.ioFailure
    }
}

private struct RawOnlyArchiveV1MediaStore: ArchiveV1MediaStoring {
    func storeRawData(_ data: Data, mediaType: ArchiveV1MediaType, variant: ArchiveV1MediaVariant, sourceFormat: String?, assetID: String) throws -> ArchiveV1StoredMedia {
        .init(relativePath: "media/test/\(assetID).bin", size: Int64(data.count), sha256: ArchiveCryptography.sha256(data))
    }

    func storeRawFile(_ source: URL, mediaType: ArchiveV1MediaType, variant: ArchiveV1MediaVariant, sourceFormat: String?, assetID: String) throws -> ArchiveV1StoredMedia {
        let data = try Data(contentsOf: source)
        return try storeRawData(data, mediaType: mediaType, variant: variant, sourceFormat: sourceFormat, assetID: assetID)
    }

    func storeDecodedData(_ data: Data, mediaType: ArchiveV1MediaType, format: String?, assetID: String) throws -> ArchiveV1StoredMedia {
        throw ArchiveError.ioFailure
    }
}

private final class TestCancellation: @unchecked Sendable {
    private let afterChecks: Int
    private var checks = 0

    init(afterChecks: Int) {
        self.afterChecks = afterChecks
    }

    func shouldCancel() -> Bool {
        checks += 1
        return checks > afterChecks
    }
}

private struct ArchiveV1Fixture {
    let exportRoot: URL
    let accountRoot: URL
    let tableName: String
    let imageKey: Data
    let textBlob: Data
    let thumbnailDATURL: URL
}

private var fixtureCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func fixtureMD5Hex(_ value: String) -> String {
    Insecure.MD5.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func makeSyntheticV2DAT(plaintext: Data, key: Data, xorTail: Data) throws -> Data {
    guard key.count == 16 else { throw TestFailure(description: "Synthetic V2 key must be 16 bytes") }
    let paddingLength = 16 - (plaintext.count % 16)
    let padded = plaintext + Data(repeating: UInt8(paddingLength), count: paddingLength)
    var cipher = [UInt8](repeating: 0, count: padded.count)
    var moved = 0
    let status = key.withUnsafeBytes { keyBytes in
        padded.withUnsafeBytes { plaintextBytes in
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                keyBytes.baseAddress,
                key.count,
                nil,
                plaintextBytes.baseAddress,
                padded.count,
                &cipher,
                cipher.count,
                &moved
            )
        }
    }
    guard status == kCCSuccess, moved == cipher.count else {
        throw TestFailure(description: "Could not encrypt synthetic V2 fixture")
    }
    var dat = Data([0x07, 0x08, 0x56, 0x32, 0x08, 0x07])
    var aesSize = UInt32(plaintext.count).littleEndian
    var xorSize = UInt32(xorTail.count).littleEndian
    withUnsafeBytes(of: &aesSize) { dat.append(contentsOf: $0) }
    withUnsafeBytes(of: &xorSize) { dat.append(contentsOf: $0) }
    dat.append(1)
    dat.append(contentsOf: cipher)
    dat.append(contentsOf: xorTail.map { $0 ^ 0x88 })
    return dat
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) throws {
    guard actual == expected else { throw TestFailure(description: "Expected \(expected), got \(actual) at \(file):\(line)") }
}

private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard value else { throw TestFailure(description: "Expected true at \(file):\(line)") }
}

private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard !value else { throw TestFailure(description: "Expected false at \(file):\(line)") }
}

private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(description: "Expected non-nil value at \(file):\(line)") }
    return value
}

private func expectThrows<T: Error & Equatable>(_ expected: T, _ work: () throws -> Void) throws {
    do {
        try work()
    } catch let error as T {
        try expectEqual(error, expected)
        return
    } catch {
        throw TestFailure(description: "Expected \(expected), got \(error)")
    }
    throw TestFailure(description: "Expected \(expected) to be thrown")
}
