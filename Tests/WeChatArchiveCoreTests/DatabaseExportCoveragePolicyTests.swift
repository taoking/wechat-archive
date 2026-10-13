import Foundation
import XCTest
@testable import WeChatArchiveCore

final class DatabaseExportCoveragePolicyTests: XCTestCase {
    func testMissingMessageShardBlocksEvenWhenMigrationIsAllowed() throws {
        let items = try fixture(paths: ["message/message_0.db", "migrate/old.db"], keyPaths: [])
        XCTAssertThrowsError(try DatabaseExportCoveragePolicy(allowedMissing: ["migrate/old.db"]).check(items)) {
            XCTAssertEqual($0 as? ArchiveError, .keyUnavailable)
        }
    }

    func testExactAllowListPermitsOnlyTheSpecifiedMissingDatabase() throws {
        let items = try fixture(paths: ["message/message_0.db", "migrate/old.db"], keyPaths: ["message/message_0.db"])
        let valid = WeChatDatabaseExportCoordinator(decryptor: PolicyDecryptor(reject: false)).validateAll(items)
        XCTAssertThrowsError(try DatabaseExportCoveragePolicy().check(valid))
        XCTAssertNoThrow(try DatabaseExportCoveragePolicy(allowedMissing: ["migrate/old.db"]).check(valid))
    }

    func testAllowListCannotBypassAnInvalidMatchedKey() throws {
        let items = try fixture(paths: ["message/message_0.db"], keyPaths: ["message/message_0.db"])
        let invalid = WeChatDatabaseExportCoordinator(decryptor: PolicyDecryptor(reject: true)).validateAll(items)
        XCTAssertThrowsError(try DatabaseExportCoveragePolicy(allowedMissing: ["message/message_0.db"]).check(invalid)) {
            XCTAssertEqual($0 as? ArchiveError, .keyInvalid)
        }
    }

    func testEmptyAndUnvalidatedScansCannotBecomeSuccess() throws {
        XCTAssertThrowsError(try DatabaseExportCoveragePolicy().check([]))
        let items = try fixture(paths: ["message/message_0.db"], keyPaths: ["message/message_0.db"])
        XCTAssertThrowsError(try DatabaseExportCoveragePolicy().check(items))
    }

    private func fixture(paths: [String], keyPaths: [String]) throws -> [ScannedWeChatDatabase] {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let databases = root.appending(path: "source")
        try FileManager.default.createDirectory(at: databases, withIntermediateDirectories: true)
        for name in paths {
            let file = databases.appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic only".utf8).write(to: file)
        }
        let map = root.appending(path: "fixture-keys.json")
        let randomKey = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let payload = Dictionary(uniqueKeysWithValues: keyPaths.map { ($0, ["enc_key": randomKey]) })
        try JSONSerialization.data(withJSONObject: payload).write(to: map)
        return try WeChatDatabaseScanner().scan(databaseRoot: databases, keyMap: WXCLIKeyMapProvider(url: map))
    }
}

private struct PolicyDecryptor: WeChatDatabaseDecryptor {
    let reject: Bool
    func validate(databaseURL: URL, key: WeChatDatabaseKey) throws {
        if reject { throw ArchiveError.keyInvalid }
    }
    func decrypt(databaseURL: URL, key: WeChatDatabaseKey, into workingDirectory: URL) throws -> URL {
        throw ArchiveError.ioFailure
    }
}
