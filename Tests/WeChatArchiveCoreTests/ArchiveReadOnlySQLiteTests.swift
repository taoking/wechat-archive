import Foundation
import SQLite3
import XCTest
@testable import WeChatArchiveCore

final class ArchiveReadOnlySQLiteTests: XCTestCase {
    func testCheckpointedFallbackReadsEscapedPathWithoutChangingArchiveOrSidecars() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "archive 中文 ?#% \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "archive.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path(percentEncoded: false), &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE conversations(id); INSERT INTO conversations VALUES(1)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        let wal = URL(fileURLWithPath: url.path(percentEncoded: false) + "-wal")
        let shm = URL(fileURLWithPath: url.path(percentEncoded: false) + "-shm")
        try Data().write(to: wal)
        let sidecarBytes = Data(repeating: 0x31, count: 32768)
        try sidecarBytes.write(to: shm)
        let before = try Data(contentsOf: url)

        // Inject the same I/O failure observed on the external filesystem.
        let reader = try ArchiveReadOnlySQLite.open(url, probe: { _ in SQLITE_IOERR })
        defer { sqlite3_close(reader) }
        XCTAssertEqual(try count(reader, sql: "SELECT COUNT(*) FROM conversations"), 1)
        XCTAssertEqual(sqlite3_exec(reader, "DELETE FROM conversations", nil, nil, nil), SQLITE_READONLY)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try Data(contentsOf: wal).count, 0)
        XCTAssertEqual(try Data(contentsOf: shm), sidecarBytes)
    }

    func testOrdinaryReaderIncludesCommittedMessagesStillInWAL() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "archive-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "archive.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path(), &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE fixture(value); INSERT INTO fixture VALUES(1)", nil, nil, nil), SQLITE_OK)
        let reader = try ArchiveReadOnlySQLite.open(url)
        defer { sqlite3_close(reader) }
        XCTAssertEqual(try count(reader, sql: "SELECT COUNT(*) FROM fixture"), 1)
        XCTAssertThrowsError(try ArchiveReadOnlySQLite.open(url, probe: { _ in SQLITE_IOERR })) {
            XCTAssertEqual($0 as? ArchiveError, .databaseInUse)
        }
    }

    func testFallbackRefusesNonemptyRollbackJournalAndDoesNotMaskOtherErrors() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "archive-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "archive.sqlite")
        let writer = try WeChatArchiveV1Database(url: url)
        writer.close()
        let journal = URL(fileURLWithPath: url.path() + "-journal")
        try Data([1]).write(to: journal)
        XCTAssertThrowsError(try ArchiveReadOnlySQLite.open(url, probe: { _ in SQLITE_READONLY })) {
            XCTAssertEqual($0 as? ArchiveError, .databaseInUse)
        }
        XCTAssertThrowsError(try ArchiveReadOnlySQLite.open(url, probe: { _ in SQLITE_CORRUPT })) {
            XCTAssertEqual($0 as? ArchiveError, .databaseFailure)
        }
        XCTAssertEqual(try Data(contentsOf: journal), Data([1]))
    }

    func testConversationPageKeepsEmptyConversationsAndLatestMessageTieOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "archive-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try WeChatArchiveV1Database(url: root.appending(path: "archive.sqlite"))
        let empty = try writer.upsertConversation(sourceIdentity: "empty", displayName: "Empty", createdAt: 200)
        let populated = try writer.upsertConversation(sourceIdentity: "populated", displayName: "Literal %_")
        for (index, source) in ["a", "z", "b"].enumerated() {
            _ = try writer.insertMessage(
                conversationID: populated, sourceDatabase: source, sourceTable: "fixture", sourceSQLiteRowID: Int64(index),
                sourceLocalID: nil, sourceServerID: nil, timestamp: 100, senderSourceID: nil, receiverSourceID: nil,
                rawLocalType: 1, normalizedType: .text, textContent: source == "z" ? "latest" : "earlier", replySourceID: nil,
                sourceSequence: 1, sourceValues: [:])
        }
        writer.close()
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: root)
        let first = try viewer.conversationPage(limit: 1)
        XCTAssertEqual(first.items.first?.id, empty)
        XCTAssertEqual(first.items.first?.messageCount, 0)
        XCTAssertNil(first.items.first?.lastMessageTimestamp)
        XCTAssertTrue(first.hasMore)
        let second = try viewer.conversationPage(offset: 1, limit: 1)
        XCTAssertEqual(second.items.first?.id, populated)
        XCTAssertEqual(second.items.first?.messageCount, 3)
        XCTAssertEqual(second.items.first?.lastMessagePreview, "latest")
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(try viewer.searchConversationPage(query: "%_").items.map(\.id), [populated])
        XCTAssertEqual(try viewer.conversation(id: populated), second.items.first)
    }

    private func count(_ database: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
