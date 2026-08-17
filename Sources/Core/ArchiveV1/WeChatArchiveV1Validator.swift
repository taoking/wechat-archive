import Foundation
import SQLite3

/// Read-only archive verification. Validation does not alter imported data or
/// source databases; it checks only archive structure and media copies.
public struct WeChatArchiveV1Validator: Sendable {
    public init() {}

    public func validate(at archiveRoot: URL) throws -> ArchiveV1ValidationReport {
        let root = try validatedRoot(archiveRoot)
        let databaseURL = root.appending(path: "archive.sqlite")
        let manifestURL = root.appending(path: "archive-manifest.json")
        let database = try ArchiveV1ValidationDatabase(url: databaseURL)
        let manifest = try readManifest(manifestURL)
        let messageCount = try database.messageCount()
        let conversationCount = try database.conversationCount()
        let schemaVersion = try database.schemaVersion()
        let media = try database.mediaRows()
        let mediaHashesPassed = try media.allSatisfy { row in
            try verify(path: row.rawPath, hash: row.rawHash, below: root) &&
            verify(path: row.decodedPath, hash: row.decodedHash, below: root)
        }
        let manifestPassed = manifest.format == "WeChatArchive" &&
            manifest.version == WeChatArchiveV1Database.schemaVersion &&
            schemaVersion == WeChatArchiveV1Database.schemaVersion &&
            manifest.messageCount == messageCount &&
            manifest.mediaAssetCount == media.count &&
            manifest.conversationCount == conversationCount
        return ArchiveV1ValidationReport(
            sqliteIntegrityPassed: try database.integrityCheck(),
            foreignKeysPassed: try database.foreignKeyCheck(),
            manifestPassed: manifestPassed,
            mediaHashesPassed: mediaHashesPassed,
            messageCount: messageCount,
            mediaAssetCount: media.count
        )
    }

    private func validatedRoot(_ root: URL) throws -> URL {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func readManifest(_ url: URL) throws -> ArchiveV1Manifest {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
        return try JSONDecoder().decode(ArchiveV1Manifest.self, from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func verify(path: String?, hash: String?, below root: URL) throws -> Bool {
        switch (path, hash) {
        case (nil, nil): return true
        case let (.some(relative), .some(expected)):
            let components = relative.split(separator: "/").map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
            let url = components.reduce(root) { $0.appending(path: $1) }.standardizedFileURL
            guard isDescendant(url, of: root) else { return false }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
            return try ArchiveCryptography.sha256(fileAt: url) == expected
        default: return false
        }
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path()
        let valuePath = url.resolvingSymlinksInPath().standardizedFileURL.path()
        return valuePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

private final class ArchiveV1ValidationDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidArchive }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path(), &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveError.databaseFailure
        }
        handle = database
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func schemaVersion() throws -> Int { Int(try scalarInt("PRAGMA user_version")) }
    func messageCount() throws -> Int { Int(try scalarInt("SELECT COUNT(*) FROM messages")) }
    func conversationCount() throws -> Int { Int(try scalarInt("SELECT COUNT(*) FROM conversations")) }
    func integrityCheck() throws -> Bool { try scalarString("PRAGMA integrity_check") == "ok" }

    func foreignKeyCheck() throws -> Bool {
        let statement = try prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    func mediaRows() throws -> [(rawPath: String?, decodedPath: String?, rawHash: String?, decodedHash: String?)] {
        let statement = try prepare("SELECT raw_archive_path, decoded_archive_path, sha256_raw, sha256_decoded FROM media_assets")
        defer { sqlite3_finalize(statement) }
        var rows = [(String?, String?, String?, String?)]()
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((text(statement, 0), text(statement, 1), text(statement, 2), text(statement, 3)))
        }
        return rows
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarString(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return result == SQLITE_ROW ? text(statement, 0) : nil
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        return statement
    }

    private func requireHandle() -> OpaquePointer {
        guard let handle else { preconditionFailure("Validation database is closed") }
        return handle
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }
}
