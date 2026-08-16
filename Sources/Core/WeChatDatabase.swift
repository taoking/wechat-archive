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

/// Creates a copy in a caller-controlled working directory and includes SQLite
/// WAL/SHM sidecars. The before/after attributes guard against silently taking
/// an inconsistent copy while WeChat is still writing.
public struct DatabaseSnapshotter: Sendable {
    public init() {}

    public func snapshot(databaseURL: URL, into workingDirectory: URL) throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: databaseURL.path()) else { throw ArchiveError.invalidInput }
        let sourceFiles = [databaseURL, databaseURL.appendingPathExtension("wal"), databaseURL.appendingPathExtension("shm")]
            .filter { manager.fileExists(atPath: $0.path()) }
        let before = try attributes(for: sourceFiles)
        try manager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        for source in sourceFiles {
            let destination = workingDirectory.appending(path: source.lastPathComponent)
            if manager.fileExists(atPath: destination.path()) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: source, to: destination)
        }
        let after = try attributes(for: sourceFiles)
        guard before == after else {
            try? manager.removeItem(at: workingDirectory)
            throw ArchiveError.databaseInUse
        }
        return workingDirectory.appending(path: databaseURL.lastPathComponent)
    }

    private func attributes(for urls: [URL]) throws -> [String: DatabaseFileAttributes] {
        try Dictionary(uniqueKeysWithValues: urls.map { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize, let modified = values.contentModificationDate else { throw ArchiveError.ioFailure }
            return (url.path(), DatabaseFileAttributes(size: size, modified: modified))
        })
    }
}

private struct DatabaseFileAttributes: Equatable {
    let size: Int
    let modified: Date
}
