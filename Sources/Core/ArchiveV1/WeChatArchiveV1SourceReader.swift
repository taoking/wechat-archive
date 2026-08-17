import Foundation
import SQLite3

struct ArchiveV1SourceMessage: Sendable {
    let sourceDatabase: String
    let sourceTable: String
    let sourceSQLiteRowID: Int64
    let sourceSequence: Int64
    let values: [String: ArchivedSQLiteValue]
}

struct ArchiveV1SourceTable: Sendable {
    let databaseURL: URL
    let databaseRelativePath: String
    let tableName: String
    let rowCount: Int
}

/// Opens only exported plaintext SQLite databases in read-only mode. Source
/// rows are delivered one at a time so archive imports never materialize an
/// entire chat database in memory.
public struct WeChatArchiveV1SourceReader: Sendable {
    public init() {}

    public func analyze(exportRoot: URL) throws -> ArchiveV1ImportAnalysis {
        let tables = try messageTables(exportRoot: exportRoot)
        return ArchiveV1ImportAnalysis(
            messageDatabaseCount: Set(tables.map(\.databaseRelativePath)).count,
            messageTableCount: tables.count,
            estimatedMessageCount: tables.reduce(0) { $0 + $1.rowCount }
        )
    }

    func stream(
        exportRoot: URL,
        limit: Int?,
        handler: (ArchiveV1SourceMessage) throws -> Bool
    ) throws -> Int {
        let tables = try messageTables(exportRoot: exportRoot)
        var delivered = 0
        for table in tables {
            let database = try ReadOnlyArchiveV1SourceDatabase(url: table.databaseURL)
            let shouldContinue = try database.stream(tableName: table.tableName) { rowid, values in
                guard limit.map({ delivered < $0 }) ?? true else { return false }
                let record = ArchiveV1SourceMessage(
                    sourceDatabase: table.databaseRelativePath,
                    sourceTable: table.tableName,
                    sourceSQLiteRowID: rowid,
                    sourceSequence: rowid,
                    values: values
                )
                delivered += 1
                return try handler(record)
            }
            if !shouldContinue || limit.map({ delivered >= $0 }) == true { break }
        }
        return Set(tables.map(\.databaseRelativePath)).count
    }

    private func messageTables(exportRoot: URL) throws -> [ArchiveV1SourceTable] {
        let root = try validatedDirectory(exportRoot)
        let messageRoot = root.appending(path: "message")
        guard isSafeDirectory(messageRoot), isDescendant(messageRoot, of: root) else { throw ArchiveError.invalidInput }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: messageRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { throw ArchiveError.ioFailure }
        var tables = [ArchiveV1SourceTable]()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "db" else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(resolved, of: root) else { continue }
            let relativePath = relativePath(of: resolved, below: root)
            let database = try ReadOnlyArchiveV1SourceDatabase(url: resolved)
            for tableName in try database.messageTableNames() {
                tables.append(ArchiveV1SourceTable(
                    databaseURL: resolved,
                    databaseRelativePath: relativePath,
                    tableName: tableName,
                    rowCount: try database.rowCount(tableName: tableName)
                ))
            }
        }
        return tables.sorted { ($0.databaseRelativePath, $0.tableName) < ($1.databaseRelativePath, $1.tableName) }
    }

    private func validatedDirectory(_ url: URL) throws -> URL {
        let requested = url.standardizedFileURL
        guard isSafeDirectory(requested) else { throw ArchiveError.invalidInput }
        return requested.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path()
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path()
        return resolved.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func relativePath(of url: URL, below root: URL) -> String {
        let rootPath = root.path()
        let absolutePath = url.path()
        guard absolutePath.hasPrefix(rootPath) else { return "" }
        let suffix = String(absolutePath.dropFirst(rootPath.count))
        return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
    }
}

private final class ReadOnlyArchiveV1SourceDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path(), &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveError.databaseFailure
        }
        handle = database
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func messageTableNames() throws -> [String] {
        let statement = try prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        defer { sqlite3_finalize(statement) }
        var names = [String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = columnText(statement, 0) else { throw ArchiveError.databaseFailure }
            if WeChatConversationTableIdentity(tableName: name) != nil { names.append(name) }
        }
        return names
    }

    func rowCount(tableName: String) throws -> Int {
        guard WeChatConversationTableIdentity(tableName: tableName) != nil else { throw ArchiveError.invalidInput }
        let statement = try prepare("SELECT COUNT(*) FROM \(quotedIdentifier(tableName))")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func stream(tableName: String, handler: (Int64, [String: ArchivedSQLiteValue]) throws -> Bool) throws -> Bool {
        guard WeChatConversationTableIdentity(tableName: tableName) != nil else { throw ArchiveError.invalidInput }
        let columns = try columnNames(tableName: tableName)
        let statement = try prepare("SELECT rowid, * FROM \(quotedIdentifier(tableName)) ORDER BY rowid ASC")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            var values = [String: ArchivedSQLiteValue]()
            for (offset, column) in columns.enumerated() { values[column] = columnValue(statement, index: Int32(offset + 1)) }
            if try !handler(sqlite3_column_int64(statement, 0), values) { return false }
        }
        guard sqlite3_errcode(requireHandle()) == SQLITE_OK || sqlite3_errcode(requireHandle()) == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return true
    }

    private func columnNames(tableName: String) throws -> [String] {
        let statement = try prepare("PRAGMA table_info(\(quotedIdentifier(tableName)))")
        defer { sqlite3_finalize(statement) }
        var names = [String]()
        while sqlite3_step(statement) == SQLITE_ROW { guard let name = columnText(statement, 1) else { throw ArchiveError.databaseFailure }; names.append(name) }
        guard !names.isEmpty else { throw ArchiveError.databaseFailure }
        return names
    }

    private func columnValue(_ statement: OpaquePointer?, index: Int32) -> ArchivedSQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: return .text(columnText(statement, index) ?? "")
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
        default: return .null
        }
    }

    private func quotedIdentifier(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    private func prepare(_ sql: String) throws -> OpaquePointer? { var statement: OpaquePointer?; guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure }; return statement }
    private func requireHandle() -> OpaquePointer { guard let handle else { preconditionFailure("Source database is closed") }; return handle }
    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? { guard let value = sqlite3_column_text(statement, index) else { return nil }; return String(cString: value) }
}

private extension Dictionary where Key == String, Value == ArchivedSQLiteValue {
    func value(named names: [String]) -> ArchivedSQLiteValue? {
        for name in names {
            if let match = first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
                return match.value
            }
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
