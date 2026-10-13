import Foundation
import SQLite3
import XCTest
@testable import WeChatArchiveCore

final class EmoticonAttachmentTests: XCTestCase {
    func testEmoticonNeedsStructuredMessageDatabaseIdentityAndSafeLocalCache() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "EmoticonTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let plain = parent.appending(path: "Plain"), account = parent.appending(path: "Account")
        let db = plain.appending(path: "emoticon/emoticon.db")
        let cache = account.appending(path: "business/emoticon")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let md5 = "0123456789abcdef0123456789abcdef"
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path(), &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE kNonStoreEmoticonTable(md5 TEXT); INSERT INTO kNonStoreEmoticonTable VALUES ('\(md5)');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let bytes = Data("synthetic opaque emoticon ciphertext".utf8)
        try bytes.write(to: cache.appending(path: md5))
        try bytes.write(to: cache.appending(path: "\(md5).thumb"))
        let values: [String: ArchivedSQLiteValue] = ["message_content": .text("<msg><emoji md5=\"\(md5)\"/></msg>")]
        let index = try WeChatLocalEmoticonIndex(plainRoot: plain, accountRoot: account)
        let inputs = index.variants(values: values)
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs.allSatisfy { $0.status == .decodeUnsupported && $0.rawFileURL != nil })
        XCTAssertEqual(WeChatCompressedTextMessageAdapter().textContent(from: values, rawType: 47), "[表情]")
        XCTAssertTrue(index.variants(values: ["message_content": .text("<msg><emoji md5=\"ffffffffffffffffffffffffffffffff\"/></msg>")]).isEmpty)
        try FileManager.default.removeItem(at: cache.appending(path: md5))
        try FileManager.default.createSymbolicLink(at: cache.appending(path: md5), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertEqual(try WeChatLocalEmoticonIndex(plainRoot: plain, accountRoot: account).variants(values: values).count, 1)
    }
}
