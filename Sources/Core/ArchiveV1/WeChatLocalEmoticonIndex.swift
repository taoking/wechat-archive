import Foundation
import SQLite3

/// Preserves opaque cache bytes only through message XML MD5 → plaintext
/// emoticon database identity → same-account cache index. No keys are read.
struct WeChatLocalEmoticonIndex: Sendable {
    private let locations: [String: [ArchiveV1MediaVariant: URL]]
    private let accountRoot: URL

    static func messageMD5(_ values: [String: ArchivedSQLiteValue]) -> String? {
        guard let payload = WeChatMessagePayloadDecoder.decodedPayload(from: values),
              let doc = WeChatMessageXMLDocument(xml: payload),
              let value = doc.attributes(atPath: ["msg", "emoji"])?["md5"]?.lowercased(), isMD5(value) else { return nil }
        return value
    }

    init(plainRoot: URL, accountRoot: URL) throws {
        self.accountRoot = accountRoot.resolvingSymlinksInPath().standardizedFileURL
        let database = plainRoot.appending(path: "emoticon/emoticon.db")
        let business = accountRoot.appending(path: "business"), root = business.appending(path: "emoticon")
        guard Self.safeDirectory(business, below: accountRoot), Self.safeDirectory(root, below: business),
              Self.safeFile(database, below: plainRoot) else { locations = [:]; return }
        let identities = try Self.readIdentities(database)
        var result = [String: [ArchiveV1MediaVariant: URL]]()
        var conflicts = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw ArchiveError.ioFailure }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            guard visited <= 100_000 else { throw ArchiveError.invalidInput }
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if info.isDirectory == true { continue }
            guard Self.safeFile(url, below: root) else { continue }
            let md5 = url.deletingPathExtension().lastPathComponent.lowercased()
            guard Self.isMD5(md5), identities.contains(md5) else { continue }
            let variant: ArchiveV1MediaVariant
            switch url.pathExtension { case "": variant = .main; case "thumb": variant = .thumbnail; case "icon": variant = .raw; default: continue }
            let key = md5 + ":" + variant.rawValue
            guard !conflicts.contains(key) else { continue }
            if result[md5]?[variant] != nil { result[md5]?[variant] = nil; conflicts.insert(key) }
            else { result[md5, default: [:]][variant] = url }
        }
        locations = result
    }

    func variants(values: [String: ArchivedSQLiteValue]) -> [ArchiveV1MediaInput] {
        guard let md5 = Self.messageMD5(values), let urls = locations[md5] else { return [] }
        return urls.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { variant in
            guard let url = urls[variant], Self.safeFile(url, below: accountRoot) else { return nil }
            return .init(mediaType: .file, variant: variant, status: .decodeUnsupported,
                sourceFormat: "emoticon-cipher-" + variant.rawValue, decodedFormat: nil,
                rawData: nil, rawFileURL: url, decodedData: nil, width: nil, height: nil, sourceFileBase: md5)
        }
    }

    private static func readIdentities(_ url: URL) throws -> Set<String> {
        let handle = try ArchiveReadOnlySQLite.open(url)
        defer { sqlite3_close(handle) }
        var result = Set<String>()
        for (table, column) in [("kNonStoreEmoticonTable", "md5"), ("kStoreEmoticonFilesTable", "md5_")] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT \(column) FROM \(table)", -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) {
                    let value = String(cString: text).lowercased()
                    if isMD5(value) { result.insert(value) }
                }
                guard result.count <= 100_000 else { throw ArchiveError.invalidInput }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        }
        return result
    }

    private static func isMD5(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func safeDirectory(_ url: URL, below root: URL) -> Bool {
        guard let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), info.isDirectory == true, info.isSymbolicLink != true else { return false }
        return descendant(url, of: root)
    }
    private static func safeFile(_ url: URL, below root: URL) -> Bool {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), info.isRegularFile == true, info.isSymbolicLink != true else { return false }
        return descendant(url, of: root)
    }
    private static func descendant(_ url: URL, of root: URL) -> Bool {
        let prefix = root.resolvingSymlinksInPath().path()
        return url.resolvingSymlinksInPath().path().hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }
}
