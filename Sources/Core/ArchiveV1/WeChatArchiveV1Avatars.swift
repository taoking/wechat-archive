import Foundation
import SQLite3

#if canImport(ImageIO)
import ImageIO
#endif

struct ArchiveV1AvatarCandidate: Sendable {
    let sourceIdentity: String
    let sourceURL: String?
    let localData: Data?
    let format: String?
    let width: Int?
    let height: Int?

    var status: ArchiveV1AvatarStatus {
        if localData != nil { return .archived }
        return sourceURL == nil ? .missing : .remoteAvailable
    }
}

/// Reads only the observed plaintext `head_image` cache. Its direct username
/// relation to `contact.username` is the sole local mapping accepted here.
/// Neither URLs nor cache entries are fetched, guessed, or logged.
struct WeChatAvatarAdapter: Sendable {
    private let maximumAvatarBytes = 5 * 1_024 * 1_024
    private let maximumRows = 20_000

    func read(plainSQLiteRoot: URL, contacts: [ArchiveV1ContactRecord]) throws -> [String: ArchiveV1AvatarCandidate] {
        let requested = Set(contacts.map(\.sourceIdentity))
        let cache = try localCache(plainSQLiteRoot: plainSQLiteRoot, requestedIdentities: requested)
        var candidates = [String: ArchiveV1AvatarCandidate]()
        for contact in contacts {
            let sourceURL = preferredURL(for: contact)
            let local = cache[contact.sourceIdentity]
            candidates[contact.sourceIdentity] = .init(
                sourceIdentity: contact.sourceIdentity,
                sourceURL: sourceURL,
                localData: local?.data,
                format: local?.format,
                width: local?.width,
                height: local?.height
            )
        }
        return candidates
    }

    private func preferredURL(for contact: ArchiveV1ContactRecord) -> String? {
        for candidate in [contact.avatarLargeURL, contact.avatarSmallURL] {
            guard let candidate,
                  !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return candidate
        }
        return nil
    }

    private func localCache(
        plainSQLiteRoot: URL,
        requestedIdentities: Set<String>
    ) throws -> [String: (data: Data, format: String, width: Int?, height: Int?)] {
        guard !requestedIdentities.isEmpty,
              let url = safeDatabase(relativePath: "head_image/head_image.db", below: plainSQLiteRoot) else { return [:] }
        let database = try AvatarCacheDatabase(url: url)
        guard try database.hasObservedSchema else { return [:] }
        var values = [String: (data: Data, format: String, width: Int?, height: Int?)]()
        for record in try database.records(limit: maximumRows, maximumBytes: maximumAvatarBytes) {
            guard requestedIdentities.contains(record.username),
                  let image = AvatarImageInspector.inspect(record.data) else { continue }
            values[record.username] = (record.data, image.format, image.width, image.height)
        }
        return values
    }

    private func safeDatabase(relativePath: String, below root: URL) -> URL? {
        let requestedRoot = root.standardizedFileURL
        guard let rootValues = try? requestedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else { return nil }
        let components = relativePath.split(separator: "/").map(String.init)
        let requested = components.reduce(requestedRoot) { $0.appending(path: $1) }.standardizedFileURL
        guard let values = try? requested.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        let resolvedRoot = requestedRoot.resolvingSymlinksInPath().standardizedFileURL.path()
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolved.path().hasPrefix(prefix), resolved.pathExtension.lowercased() == "db" else { return nil }
        return resolved
    }
}

private enum AvatarImageInspector {
    static func inspect(_ data: Data) -> (format: String, width: Int?, height: Int?)? {
        let format: String
        if data.starts(with: Data([0xFF, 0xD8, 0xFF])) { format = "jpeg" }
        else if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) { format = "png" }
        else if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { format = "gif" }
        else if data.starts(with: Data("RIFF".utf8)) && data.dropFirst(8).starts(with: Data("WEBP".utf8)) { format = "webp" }
        else { return nil }
        #if canImport(ImageIO)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            return (format, width.intValue, height.intValue)
        }
        #endif
        return (format, nil, nil)
    }
}

private final class AvatarCacheDatabase {
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

    var hasObservedSchema: Bool {
        get throws {
            let columns = try tableColumns(named: "head_image")
            return Set(["username", "image_buffer"]).isSubset(of: columns)
        }
    }

    func records(limit: Int, maximumBytes: Int) throws -> [(username: String, data: Data)] {
        let statement = try prepare("SELECT username, image_buffer FROM \"head_image\" WHERE username IS NOT NULL AND username <> '' AND image_buffer IS NOT NULL LIMIT ?")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, Int64(max(1, limit))) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        var records = [(String, Data)]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let username = text(statement, 0),
                  sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                  let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard count > 0, count <= maximumBytes else { continue }
            records.append((username, Data(bytes: bytes, count: count)))
        }
        return records
    }

    private func tableColumns(named table: String) throws -> Set<String> {
        guard table == "head_image" else { throw ArchiveError.invalidInput }
        let statement = try prepare("PRAGMA table_info(\"head_image\")")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { columns.insert(name.lowercased()) }
        }
        return columns
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        return statement
    }

    private func requireHandle() -> OpaquePointer {
        guard let handle else { preconditionFailure("Avatar cache database is closed") }
        return handle
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }
}
