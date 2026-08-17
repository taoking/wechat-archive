import Foundation
import CryptoKit
import CommonCrypto
import SQLite3
import XCTest
@testable import WeChatArchiveCore

final class ArchiveCoreTests: XCTestCase {

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
