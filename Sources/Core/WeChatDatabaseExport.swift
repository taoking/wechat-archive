import Foundation
import SQLite3

/// Validates a manually entered local directory before it crosses into the
/// scanner. Relative paths are rejected so a pasted value cannot silently
/// resolve against an unexpected working directory.
public enum LocalDatabaseDirectoryPath {
    public static func resolve(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ArchiveError.invalidInput }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw ArchiveError.invalidInput }
        return url
    }
}

/// Locates the conventional wx-cli key map without opening or decoding it.
/// Callers invoke this only after the user explicitly selects a database root.
public struct DefaultWXCLIKeyMapLocator: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".wx-cli/all_keys.json")
    }

    public func locate() -> URL? {
        let candidate = url.standardizedFileURL
        guard candidate.pathExtension.lowercased() == "json" else { return nil }
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
        return candidate
    }
}

/// UI-facing state for one explicit database export session. Selecting either
/// input invalidates any previous scan so results never represent another root
/// or key map.
public struct DatabaseExportSession: Sendable {
    public private(set) var databaseRoot: URL?
    public private(set) var keyMapURL: URL?
    public private(set) var databases: [ScannedWeChatDatabase]

    public init() {
        databaseRoot = nil
        keyMapURL = nil
        databases = []
    }

    public var canScan: Bool {
        databaseRoot != nil && keyMapURL != nil
    }

    public mutating func selectDatabaseDirectory(_ url: URL, defaultKeyMapURL: URL?) {
        databaseRoot = url.standardizedFileURL
        keyMapURL = defaultKeyMapURL?.standardizedFileURL
        databases = []
    }

    public mutating func selectKeyMap(_ url: URL) {
        keyMapURL = url.standardizedFileURL
        databases = []
    }

    public mutating func setDatabases(_ databases: [ScannedWeChatDatabase]) {
        self.databases = databases
    }
}

/// Reads wx-cli's key map into memory for one local export session. It never
/// copies the map or serializes keys into reports, logs, or export artifacts.
public struct WXCLIKeyMapProvider: Sendable {
    private struct KeyMapEntry: Decodable {
        let encKey: String

        enum CodingKeys: String, CodingKey {
            case encKey = "enc_key"
        }
    }

    private let keysByRelativePath: [String: WeChatDatabaseKey]

    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 16 * 1_024 * 1_024 else {
            throw ArchiveError.invalidInput
        }

        let decoded: [String: KeyMapEntry]
        do {
            decoded = try JSONDecoder().decode([String: KeyMapEntry].self, from: Data(contentsOf: url))
        } catch {
            throw ArchiveError.keyInvalid
        }

        var keys: [String: WeChatDatabaseKey] = [:]
        for (rawPath, entry) in decoded {
            guard let relativePath = Self.normalizedRelativePath(rawPath) else {
                throw ArchiveError.invalidInput
            }
            let key: WeChatDatabaseKey
            do {
                key = try WeChatDatabaseKey(hex: entry.encKey)
            } catch {
                throw ArchiveError.keyInvalid
            }
            guard key.withData({ $0.count == 32 }), keys[relativePath] == nil else {
                throw ArchiveError.keyInvalid
            }
            keys[relativePath] = key
        }
        keysByRelativePath = keys
    }

    /// Returns a copy scoped to the caller's immediate validation or export
    /// operation. The key type intentionally has no printable representation.
    public func key(forRelativePath path: String) -> WeChatDatabaseKey? {
        guard let normalized = Self.normalizedRelativePath(path) else { return nil }
        return keysByRelativePath[normalized]
    }

    fileprivate static func normalizedRelativePath(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/") else { return nil }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }
}

public enum DatabaseValidationStatus: String, Equatable, Sendable {
    case notValidated
    case valid
    case invalid
    case missingKey
}

public enum DatabaseExportStatus: String, Equatable, Sendable {
    case notExported
    case exported
    case skippedMissingKey
    case skippedInvalid
    case skippedNotValidated
    case destinationExists
    case failed
}

/// One database discovered under the user-selected root. The matching key is
/// deliberately fileprivate so presentation layers cannot accidentally expose
/// it while the coordinator can still use it in-process.
public struct ScannedWeChatDatabase: Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let absoluteURL: URL
    public let hasMatchedKey: Bool
    /// True only while this export session still retains the in-memory key.
    /// It becomes false after a batch export, while `hasMatchedKey` continues
    /// to describe the original scan result for reporting purposes.
    public var hasAvailableKey: Bool { matchedKey != nil }
    public fileprivate(set) var validationStatus: DatabaseValidationStatus
    public fileprivate(set) var exportStatus: DatabaseExportStatus
    fileprivate var matchedKey: WeChatDatabaseKey?

    fileprivate init(relativePath: String, absoluteURL: URL, matchedKey: WeChatDatabaseKey?) {
        self.relativePath = relativePath
        self.absoluteURL = absoluteURL
        self.matchedKey = matchedKey
        hasMatchedKey = matchedKey != nil
        validationStatus = matchedKey == nil ? .missingKey : .notValidated
        exportStatus = .notExported
    }

    fileprivate mutating func discardMatchedKey() {
        matchedKey = nil
    }
}

/// Scans only regular `.db` files below one explicit database root. Symlinks
/// and paths escaping that root are ignored, preventing an untrusted directory
/// entry from redirecting an export to an unrelated file.
public struct WeChatDatabaseScanner: Sendable {
    public init() {}

    public func scan(databaseRoot: URL, keyMap: WXCLIKeyMapProvider) throws -> [ScannedWeChatDatabase] {
        let manager = FileManager.default
        let root = databaseRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ArchiveError.invalidInput
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw ArchiveError.ioFailure
        }

        var databases: [ScannedWeChatDatabase] = []
        for case let candidate as URL in enumerator {
            let values = try? candidate.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(resolved, of: root), resolved.pathExtension.lowercased() == "db" else { continue }
            guard let relativePath = relativePath(of: resolved, below: root) else { continue }
            databases.append(ScannedWeChatDatabase(
                relativePath: relativePath,
                absoluteURL: resolved,
                matchedKey: keyMap.key(forRelativePath: relativePath)
            ))
        }
        return databases.sorted { $0.relativePath < $1.relativePath }
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        return url.path().hasPrefix(rootPath)
    }

    private func relativePath(of url: URL, below root: URL) -> String? {
        let rootPath = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        guard url.path().hasPrefix(rootPath) else { return nil }
        return WXCLIKeyMapProvider.normalizedRelativePath(String(url.path().dropFirst(rootPath.count)))
    }
}

public struct WeChatDatabaseExportSummary: Equatable, Sendable {
    public let detected: Int
    public let matched: Int
    public let validated: Int
    public let invalid: Int
    public let missingKeys: Int
    public let exported: Int
    public let exportFailed: Int

    public init(databases: [ScannedWeChatDatabase]) {
        detected = databases.count
        matched = databases.filter(\.hasMatchedKey).count
        validated = databases.filter { $0.validationStatus == .valid }.count
        invalid = databases.filter { $0.validationStatus == .invalid }.count
        missingKeys = databases.filter { $0.validationStatus == .missingKey }.count
        exported = databases.filter { $0.exportStatus == .exported }.count
        exportFailed = databases.filter { $0.exportStatus == .failed }.count
    }
}

/// Validates and exports one database at a time. The caller runs this type on a
/// detached task; sequential processing avoids competing for the local storage
/// while source snapshots are being created.
public struct WeChatDatabaseExportCoordinator: Sendable {
    private let decryptor: any WeChatDatabaseDecryptor

    public init(decryptor: any WeChatDatabaseDecryptor) {
        self.decryptor = decryptor
    }

    /// A bad key or changing source affects only that database. No key, path,
    /// database contents, or low-level SQLCipher errors are returned.
    public func validateAll(_ databases: [ScannedWeChatDatabase]) -> [ScannedWeChatDatabase] {
        var result = databases
        for index in result.indices {
            guard let key = result[index].matchedKey else {
                result[index].validationStatus = .missingKey
                continue
            }
            do {
                try decryptor.validate(databaseURL: result[index].absoluteURL, key: key)
                result[index].validationStatus = .valid
            } catch {
                result[index].validationStatus = .invalid
            }
        }
        return result
    }

    /// Writes only validated databases. Plaintext is staged inside the chosen
    /// export filesystem so the final move is an atomic rename, never a copy.
    public func exportValidatedDatabases(
        _ databases: [ScannedWeChatDatabase],
        to exportRoot: URL
    ) throws -> [ScannedWeChatDatabase] {
        let root = try prepareExportRoot(exportRoot)
        var result = databases
        for index in result.indices {
            guard result[index].validationStatus == .valid else {
                result[index].exportStatus = exportSkipStatus(for: result[index].validationStatus)
                result[index].discardMatchedKey()
                continue
            }
            guard let key = result[index].matchedKey else {
                result[index].exportStatus = .skippedMissingKey
                continue
            }
            do {
                try export(result[index], key: key, to: root)
                result[index].exportStatus = .exported
            } catch ExportFailure.destinationExists {
                result[index].exportStatus = .destinationExists
            } catch {
                result[index].exportStatus = .failed
            }
            result[index].discardMatchedKey()
        }
        return result
    }

    private func exportSkipStatus(for status: DatabaseValidationStatus) -> DatabaseExportStatus {
        switch status {
        case .missingKey: .skippedMissingKey
        case .invalid: .skippedInvalid
        case .notValidated: .skippedNotValidated
        case .valid: .notExported
        }
    }

    private func prepareExportRoot(_ root: URL) throws -> URL {
        let manager = FileManager.default
        let resolved = root.standardizedFileURL
        if manager.fileExists(atPath: resolved.path()) {
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        } else {
            try manager.createDirectory(at: resolved, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resolved.path())
        return resolved
    }

    private func export(_ database: ScannedWeChatDatabase, key: WeChatDatabaseKey, to root: URL) throws {
        let manager = FileManager.default
        let destination = try destinationURL(for: database.relativePath, under: root)
        guard !manager.fileExists(atPath: destination.path()) else { throw ExportFailure.destinationExists }

        let staging = root.appending(path: ".wechatarchive-staging-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }

        let plaintext = try decryptor.decrypt(databaseURL: database.absoluteURL, key: key, into: staging)
        guard plaintext.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL else {
            throw ArchiveError.ioFailure
        }
        try verifyPlaintextSQLite(at: plaintext)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plaintext.path())

        // Recheck immediately before rename so a concurrently-created file is
        // never silently replaced.
        guard !manager.fileExists(atPath: destination.path()) else { throw ExportFailure.destinationExists }
        try manager.moveItem(at: plaintext, to: destination)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path())
    }

    private func destinationURL(for relativePath: String, under root: URL) throws -> URL {
        guard let normalized = WXCLIKeyMapProvider.normalizedRelativePath(relativePath) else {
            throw ArchiveError.invalidInput
        }
        let components = normalized.split(separator: "/").map(String.init)
        guard let filename = components.last else { throw ArchiveError.invalidInput }
        var directory = root
        let manager = FileManager.default
        for component in components.dropLast() {
            directory.append(path: component)
            if manager.fileExists(atPath: directory.path()) {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
            } else {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path())
        }
        return directory.appending(path: filename)
    }

    private func verifyPlaintextSQLite(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else {
            throw ArchiveError.databaseDecryptionFailed
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path(), &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveError.databaseFailure
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT count(*) FROM sqlite_master", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ArchiveError.databaseFailure
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveError.databaseFailure }
    }

    private enum ExportFailure: Error {
        case destinationExists
    }
}
