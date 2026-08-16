import Foundation

public struct DatabaseSchemaInfo: Equatable, Sendable {
    public let tables: Set<String>
    public let columnsByTable: [String: Set<String>]
    public let metadata: [String: String]

    public init(tables: Set<String>, columnsByTable: [String: Set<String>], metadata: [String: String] = [:]) {
        self.tables = tables
        self.columnsByTable = columnsByTable
        self.metadata = metadata
    }
}

public protocol WeChatDatabaseAdapter: Sendable {
    var identifier: String { get }
    func canHandle(schema: DatabaseSchemaInfo) -> Bool
}

public struct WeChatMacV3Adapter: WeChatDatabaseAdapter {
    public let identifier = "wechat-mac-v3"
    public init() {}

    public func canHandle(schema: DatabaseSchemaInfo) -> Bool {
        schema.tables.contains("Message") && schema.columnsByTable["Message", default: []].isSuperset(of: ["MsgSvrID", "CreateTime", "StrContent"])
    }
}

public struct WeChatMacV4Adapter: WeChatDatabaseAdapter {
    public let identifier = "wechat-mac-v4"
    public init() {}

    public func canHandle(schema: DatabaseSchemaInfo) -> Bool {
        schema.tables.contains("message") && schema.columnsByTable["message", default: []].isSuperset(of: ["local_id", "timestamp", "payload"])
    }
}

public struct WeChatDatabaseDetector: Sendable {
    private let adapters: [any WeChatDatabaseAdapter]

    public init(adapters: [any WeChatDatabaseAdapter] = [WeChatMacV4Adapter(), WeChatMacV3Adapter()]) {
        self.adapters = adapters
    }

    public func detect(schema: DatabaseSchemaInfo) throws -> any WeChatDatabaseAdapter {
        guard let adapter = adapters.first(where: { $0.canHandle(schema: schema) }) else {
            throw ArchiveError.unsupportedDatabaseVersion
        }
        return adapter
    }
}

/// Canonical SQLite companion-file names. SQLite appends these suffixes to the
/// database filename; they are not filename extensions.
enum SQLiteSidecar {
    static func wal(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: databaseURL.path() + "-wal")
    }

    static func shm(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: databaseURL.path() + "-shm")
    }

    static func journal(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: databaseURL.path() + "-journal")
    }

    static func snapshotFiles(for databaseURL: URL) -> [URL] {
        [databaseURL, wal(for: databaseURL), shm(for: databaseURL)]
    }

    static func allArtifacts(for databaseURL: URL) -> [URL] {
        [databaseURL, wal(for: databaseURL), shm(for: databaseURL), journal(for: databaseURL)]
    }
}

/// Removes a database and every SQLite sidecar that could contain matching data.
/// Call this only for files created in an application-owned working directory,
/// never for the user-selected source database.
func removeSQLiteArtifacts(for databaseURL: URL, using manager: FileManager = .default) {
    for artifact in SQLiteSidecar.allArtifacts(for: databaseURL) {
        try? manager.removeItem(at: artifact)
    }
}

/// Creates a protected, best-effort stable file snapshot in a new
/// caller-controlled working directory. It copies the database plus WAL/SHM
/// sidecars and compares the source set and attributes before and after
/// copying. This detects changes but is not a transaction-consistent SQLite
/// backup, so callers must ask users to quit WeChat before archival import.
public struct DatabaseSnapshotter: Sendable {
    private let copyFile: @Sendable (URL, URL) throws -> Void

    public init() {
        copyFile = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    init(copyFile: @escaping @Sendable (URL, URL) throws -> Void) {
        self.copyFile = copyFile
    }

    public func snapshot(databaseURL: URL, into workingDirectory: URL) throws -> URL {
        let manager = FileManager.default
        let sourceValues = try databaseURL.resourceValues(forKeys: [.isRegularFileKey])
        guard sourceValues.isRegularFile == true else { throw ArchiveError.invalidInput }
        guard !manager.fileExists(atPath: workingDirectory.path()) else { throw ArchiveError.invalidInput }

        let sourceFiles = existingSnapshotFiles(for: databaseURL, using: manager)
        let before = try attributes(for: sourceFiles)
        do {
            try manager.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workingDirectory.path())
            for source in sourceFiles {
                let destination = workingDirectory.appending(path: source.lastPathComponent)
                try copyFile(source, destination)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path())
            }

            let afterFiles = existingSnapshotFiles(for: databaseURL, using: manager)
            let after = try attributes(for: afterFiles)
            guard sourceFiles == afterFiles, before == after else {
                throw ArchiveError.databaseInUse
            }
            return workingDirectory.appending(path: databaseURL.lastPathComponent)
        } catch {
            try? manager.removeItem(at: workingDirectory)
            if let archiveError = error as? ArchiveError { throw archiveError }
            throw ArchiveError.ioFailure
        }
    }

    private func existingSnapshotFiles(for databaseURL: URL, using manager: FileManager) -> [URL] {
        SQLiteSidecar.snapshotFiles(for: databaseURL)
            .filter { manager.fileExists(atPath: $0.path()) }
    }

    private func attributes(for urls: [URL]) throws -> [String: DatabaseFileAttributes] {
        try Dictionary(uniqueKeysWithValues: urls.map { url in
            let values = try FileManager.default.attributesOfItem(atPath: url.path())
            guard let size = values[.size] as? NSNumber,
                  let modified = values[.modificationDate] as? Date else {
                throw ArchiveError.ioFailure
            }
            return (url.path(), DatabaseFileAttributes(size: size.intValue, modified: modified))
        })
    }
}

private struct DatabaseFileAttributes: Equatable {
    let size: Int
    let modified: Date
}
