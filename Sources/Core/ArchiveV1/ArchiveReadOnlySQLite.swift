import Foundation
import SQLite3

/// Archive readers normally retain SQLite's locking and WAL visibility. Some
/// external filesystems fail even a read-only schema read while opening the
/// shared-memory sidecar. Only a checkpointed, sealed archive may fall back to
/// immutable mode; a nonempty WAL must never be silently ignored.
enum ArchiveReadOnlySQLite {
    static func open(
        _ url: URL,
        probe: (OpaquePointer) -> Int32 = probeSchema
    ) throws -> OpaquePointer {
        let database = try connect(url.path(percentEncoded: false), uri: false)
        let result = probe(database)
        if result == SQLITE_OK { return database }
        sqlite3_close(database)
        guard result & 0xff == SQLITE_IOERR || result & 0xff == SQLITE_READONLY else {
            throw ArchiveError.databaseFailure
        }

        try requireEmptyJournals(for: url)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ArchiveError.invalidInput
        }
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        guard let filename = components.string else { throw ArchiveError.invalidInput }
        let sealed = try connect(filename, uri: true)
        do {
            guard probeSchema(sealed) == SQLITE_OK else { throw ArchiveError.databaseFailure }
            // Check again after opening, rather than trusting a stale sidecar
            // observation. The archive must remain sealed while being viewed.
            try requireEmptyJournals(for: url)
            return sealed
        } catch {
            sqlite3_close(sealed)
            throw error
        }
    }

    private static func requireEmptyJournals(for url: URL) throws {
        for suffix in ["-wal", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path(percentEncoded: false) + suffix)
            do {
                let values = try sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink == false, values.fileSize == 0 else {
                    throw ArchiveError.databaseInUse
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            }
        }
    }

    private static func connect(_ filename: String, uri: Bool) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (uri ? SQLITE_OPEN_URI : 0)
        guard sqlite3_open_v2(filename, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveError.databaseFailure
        }
        return database
    }

    private static func probeSchema(_ database: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(database, "PRAGMA schema_version", -1, &statement, nil)
        guard prepared == SQLITE_OK else { return prepared }
        let stepped = sqlite3_step(statement)
        return stepped == SQLITE_ROW ? SQLITE_OK : stepped
    }
}
