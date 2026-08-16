import Foundation
import CryptoKit
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
