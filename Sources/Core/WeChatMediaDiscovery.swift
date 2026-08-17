import CryptoKit
import Foundation
import SQLite3
#if canImport(ImageIO)
import ImageIO
#endif

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum LocalMediaFormat: String, Codable, Equatable, Sendable {
    case jpeg
    case png
    case gif
    case webp
    case heic
    case mp4
    case mov
    case pdf
    case zip
    case unknown

    public var isImage: Bool {
        switch self {
        case .jpeg, .png, .gif, .webp, .heic: true
        default: false
        }
    }
}

public struct MediaImageDimensions: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A local media file location. `sourceURL` is local-only and deliberately
/// excluded from discovery reports.
public struct DiscoveredMediaFile: Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let sourceURL: URL
    public let relativePath: String
    public let fileSize: Int64
    public let fileExtension: String
    public let format: LocalMediaFormat
    public let imageDimensions: MediaImageDimensions?
    /// A reversible header-only XOR marker when a native image magic value is
    /// recovered. The original file is never changed.
    public let headerXORKey: UInt8?
    /// Nil until a resolver narrows candidates enough to justify hashing.
    public let sha256: String?

    public init(
        sourceURL: URL,
        relativePath: String,
        fileSize: Int64,
        fileExtension: String,
        format: LocalMediaFormat,
        imageDimensions: MediaImageDimensions?,
        headerXORKey: UInt8? = nil,
        sha256: String?
    ) {
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.fileExtension = fileExtension
        self.format = format
        self.imageDimensions = imageDimensions
        self.headerXORKey = headerXORKey
        self.sha256 = sha256
    }
}

public struct MediaScanProgress: Equatable, Sendable {
    public let scannedFileCount: Int
    public let discoveredMediaCount: Int
    public let currentRelativePath: String

    public init(scannedFileCount: Int, discoveredMediaCount: Int, currentRelativePath: String) {
        self.scannedFileCount = scannedFileCount
        self.discoveredMediaCount = discoveredMediaCount
        self.currentRelativePath = currentRelativePath
    }
}

public struct MediaScanResult: Equatable, Sendable {
    public let files: [DiscoveredMediaFile]
    public let scannedFileCount: Int
    public let isTruncated: Bool

    public init(files: [DiscoveredMediaFile], scannedFileCount: Int, isTruncated: Bool) {
        self.files = files
        self.scannedFileCount = scannedFileCount
        self.isTruncated = isTruncated
    }
}

public enum LinkConfidence: String, Codable, Equatable, Sendable {
    case exact
    case high
    case medium
    case low
    case unresolved
}

public struct MessageMediaLink: Equatable, Sendable {
    public let reference: MediaReference
    public let resolvedFile: DiscoveredMediaFile?
    public let confidence: LinkConfidence
    public let reason: String

    public init(reference: MediaReference, resolvedFile: DiscoveredMediaFile?, confidence: LinkConfidence, reason: String) {
        self.reference = reference
        self.resolvedFile = resolvedFile
        self.confidence = confidence
        self.reason = reason
    }
}

public struct ObservedMessageTypeMapping: Codable, Equatable, Sendable {
    public let rawType: Int64
    public let observedType: MessageMediaTypeHint
    public let count: Int
    public let confidence: LinkConfidence
    public let evidence: [String]

    public init(rawType: Int64, observedType: MessageMediaTypeHint, count: Int, confidence: LinkConfidence, evidence: [String]) {
        self.rawType = rawType
        self.observedType = observedType
        self.count = count
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct MessageMediaDiscoveryResult: Equatable, Sendable {
    public let messageAnalysis: MessageSampleAnalysis
    public let mediaScan: MediaScanResult?
    public let links: [MessageMediaLink]
    public let observedTypeMappings: [ObservedMessageTypeMapping]

    public init(
        messageAnalysis: MessageSampleAnalysis,
        mediaScan: MediaScanResult?,
        links: [MessageMediaLink],
        observedTypeMappings: [ObservedMessageTypeMapping]
    ) {
        self.messageAnalysis = messageAnalysis
        self.mediaScan = mediaScan
        self.links = links
        self.observedTypeMappings = observedTypeMappings
    }
}

/// Streaming, bounded local media discovery. It reads only a small header per
/// candidate and does not copy, rename, hash, or mutate every media file.
public struct WeChatMediaScanner: Sendable {
    public init() {}

    public func scan(
        mediaRoot: URL,
        maximumResults: Int = 20_000,
        progress: (@Sendable (MediaScanProgress) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> MediaScanResult {
        let root = try resolvedMediaRoot(mediaRoot)
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw ArchiveError.ioFailure
        }
        var files = [DiscoveredMediaFile]()
        var scanned = 0
        var truncated = false
        for case let candidate as URL in enumerator {
            if shouldCancel?() == true { throw CancellationError() }
            let values = try? candidate.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(resolved, of: root), let relativePath = relativePath(of: resolved, below: root) else { continue }
            scanned += 1
            let header = try readHeader(at: resolved)
            let directFormat = MediaMagicDetector.detect(header)
            let xorDetection = directFormat == .unknown ? MediaMagicDetector.detectXORObfuscatedImage(header) : nil
            let format = xorDetection?.format ?? directFormat
            guard format != .unknown || isMediaRelatedPath(relativePath) else {
                progress?(MediaScanProgress(scannedFileCount: scanned, discoveredMediaCount: files.count, currentRelativePath: relativePath))
                continue
            }
            guard files.count < maximumResults else {
                truncated = true
                break
            }
            files.append(DiscoveredMediaFile(
                sourceURL: resolved,
                relativePath: relativePath,
                fileSize: Int64(values?.fileSize ?? 0),
                fileExtension: resolved.pathExtension.lowercased(),
                format: format,
                imageDimensions: format.isImage ? imageDimensions(at: resolved, xorKey: xorDetection?.key) : nil,
                headerXORKey: xorDetection?.key,
                sha256: nil
            ))
            progress?(MediaScanProgress(scannedFileCount: scanned, discoveredMediaCount: files.count, currentRelativePath: relativePath))
        }
        return MediaScanResult(files: files.sorted { $0.relativePath < $1.relativePath }, scannedFileCount: scanned, isTruncated: truncated)
    }

    private func resolvedMediaRoot(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func readHeader(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 64) ?? Data()
    }

    private func imageDimensions(at url: URL, xorKey: UInt8?) -> MediaImageDimensions? {
        #if canImport(ImageIO)
        let source: CGImageSource?
        if let xorKey {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  (values.fileSize ?? 0) <= 32 * 1_024 * 1_024,
                  let encoded = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return nil
            }
            source = CGImageSourceCreateWithData(Data(encoded.map { $0 ^ xorKey }) as CFData, nil)
        } else {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return MediaImageDimensions(width: width.intValue, height: height.intValue)
        #else
        return nil
        #endif
    }

    private func isMediaRelatedPath(_ relativePath: String) -> Bool {
        let terms = ["image", "images", "video", "voice", "file", "attachment", "media", "msg"]
        return relativePath.lowercased().split(separator: "/").contains { component in
            terms.contains(where: { component.contains($0) })
        }
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        return url.path().hasPrefix(rootPath)
    }

    private func relativePath(of url: URL, below root: URL) -> String? {
        let rootPath = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        guard url.path().hasPrefix(rootPath) else { return nil }
        let path = String(url.path().dropFirst(rootPath.count))
        return normalizedReferencePath(path)
    }
}

public struct MediaMagicDetector: Sendable {
    public init() {}

    public static func detect(_ header: Data) -> LocalMediaFormat {
        let bytes = [UInt8](header)
        func starts(_ prefix: [UInt8]) -> Bool { bytes.starts(with: prefix) }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0x47, 0x49, 0x46, 0x38]) { return .gif }
        if starts([0x25, 0x50, 0x44, 0x46, 0x2D]) { return .pdf }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) { return .zip }
        guard bytes.count >= 12 else { return .unknown }
        let fourCC = String(decoding: bytes[4..<8], as: UTF8.self)
        if fourCC == "ftyp" {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self).lowercased()
            if brand.contains("heic") || brand.contains("heif") || brand.contains("mif1") { return .heic }
            if brand == "qt  " { return .mov }
            return .mp4
        }
        if String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF", String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" {
            return .webp
        }
        return .unknown
    }

    /// Detects image magic after applying one uniform XOR byte to the header.
    /// This recognises a small local storage wrapper; it does not decrypt or
    /// transform the source file on disk.
    public static func detectXORObfuscatedImage(_ header: Data) -> (format: LocalMediaFormat, key: UInt8)? {
        let bytes = [UInt8](header)
        let signatures: [(LocalMediaFormat, [UInt8])] = [
            (.jpeg, [0xFF, 0xD8, 0xFF]),
            (.png, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            (.gif, [0x47, 0x49, 0x46, 0x38])
        ]
        for (format, signature) in signatures where bytes.count >= signature.count {
            let key = bytes[0] ^ signature[0]
            guard key != 0 else { continue }
            if zip(bytes.prefix(signature.count), signature).allSatisfy({ ($0.0 ^ key) == $0.1 }) {
                return (format, key)
            }
        }
        return nil
    }
}

/// Resolver deliberately leaves filename-only references unresolved. MD5 is
/// calculated only after path/name narrowing (or when a scan has <=24 files),
/// never across the entire media root.
public struct MessageMediaResolver: Sendable {
    public init() {}

    public func resolve(reference: MediaReference, mediaFiles: [DiscoveredMediaFile]) throws -> MessageMediaLink {
        if let hint = reference.relativePathHint,
           let file = mediaFiles.first(where: { $0.relativePath == hint }) {
            return MessageMediaLink(reference: reference, resolvedFile: file, confidence: .exact, reason: "Exact relative path match")
        }
        if let mediaID = reference.mediaID, mediaID.count >= 8 {
            let matches = mediaFiles.filter { $0.relativePath.range(of: mediaID, options: .caseInsensitive) != nil }
            if matches.count == 1, let match = matches.first {
                return MessageMediaLink(reference: reference, resolvedFile: match, confidence: .high, reason: "Exact media ID path match")
            }
        }
        if let expectedMD5 = reference.md5 {
            let namedCandidates = mediaFiles.filter {
                $0.relativePath.range(of: expectedMD5, options: .caseInsensitive) != nil
            }
            let candidates = namedCandidates.isEmpty && mediaFiles.count <= 24 ? mediaFiles : namedCandidates
            for candidate in candidates.prefix(24) {
                if try md5(of: candidate.sourceURL, xorKey: candidate.headerXORKey) == expectedMD5.lowercased() {
                    return MessageMediaLink(reference: reference, resolvedFile: candidate, confidence: .exact, reason: "Exact MD5 match")
                }
            }
        }
        return MessageMediaLink(reference: reference, resolvedFile: nil, confidence: .unresolved, reason: "No safe media match")
    }

    private func md5(of url: URL, xorKey: UInt8?) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            hasher.update(data: xorKey.map { key in Data(chunk.map { $0 ^ key }) } ?? chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Looks up a message MD5 in the exported, plain local hardlink database and
/// resolves it only when that exact mapping identifies one local media file.
/// The mapping values remain in memory and never enter a discovery report.
public struct WeChatMediaDatabaseMapper: Sendable {
    public init() {}

    public func resolve(
        reference: MediaReference,
        exportRoot: URL,
        mediaFiles: [DiscoveredMediaFile]
    ) throws -> MessageMediaLink? {
        try resolveAll(references: [reference], exportRoot: exportRoot, mediaFiles: mediaFiles)[reference.sourceMessageIdentity]
    }

    /// Opens the exported mapping database once for a bounded batch of
    /// unresolved references, avoiding a database open per sampled message.
    public func resolveAll(
        references: [MediaReference],
        exportRoot: URL,
        mediaFiles: [DiscoveredMediaFile]
    ) throws -> [SourceMessageIdentity: MessageMediaLink] {
        let databaseURL = try hardlinkDatabaseURL(below: exportRoot)
        let database = try SQLiteMediaMappingDatabase(url: databaseURL)
        var links = [SourceMessageIdentity: MessageMediaLink]()
        for reference in references {
            guard let md5 = reference.md5,
                  md5.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil else {
                continue
            }
            let mappings = try database.mappings(for: md5)
            guard !mappings.isEmpty else { continue }
            if let link = link(reference: reference, mappings: mappings, mediaFiles: mediaFiles) {
                links[reference.sourceMessageIdentity] = link
            }
        }
        return links
    }

    private func link(
        reference: MediaReference,
        mappings: [MediaDatabaseMapping],
        mediaFiles: [DiscoveredMediaFile]
    ) -> MessageMediaLink? {
        let mappedPaths = Set(mappings.compactMap(\.relativePath))
        let exactPathMatches = mediaFiles.filter { mappedPaths.contains($0.relativePath) }
        if exactPathMatches.count == 1, let file = exactPathMatches.first {
            return MessageMediaLink(
                reference: reference,
                resolvedFile: file,
                confidence: .high,
                reason: "Exact MD5 media database mapping"
            )
        }

        // A filename is safe only because it was first fetched through an
        // exact MD5 lookup and then narrowed to exactly one actual file.
        let mappedNames = Set(mappings.compactMap(\.fileName))
        let filenameMatches = mediaFiles.filter { file in
            mappedNames.contains(file.relativePath.split(separator: "/").last.map(String.init) ?? "")
        }
        guard filenameMatches.count == 1, let file = filenameMatches.first else { return nil }
        return MessageMediaLink(
            reference: reference,
            resolvedFile: file,
            confidence: .high,
            reason: "Exact MD5 media database mapping"
        )
    }

    private func hardlinkDatabaseURL(below exportRoot: URL) throws -> URL {
        let root = exportRoot.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let database = root.appending(path: "hardlink/hardlink.db").resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path().hasSuffix("/") ? resolvedRoot.path() : resolvedRoot.path() + "/"
        guard database.path().hasPrefix(rootPath), database.pathExtension.lowercased() == "db" else { throw ArchiveError.invalidInput }
        let values = try database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        return database
    }
}

private struct MediaDatabaseMapping: Hashable, Sendable {
    let fileName: String?
    let dir1: String?
    let dir2: String?

    var relativePath: String? {
        let components = [dir1, dir2, fileName].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return normalizedReferencePath(value)
        }
        guard !components.isEmpty else { return nil }
        return normalizedReferencePath(components.joined(separator: "/"))
    }
}

private final class SQLiteMediaMappingDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path(), &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveError.databaseFailure
        }
        handle = database
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func mappings(for md5: String) throws -> [MediaDatabaseMapping] {
        let tables = ["image_hardlink_info_v4", "video_hardlink_info_v4", "file_hardlink_info_v4"]
        return Array(Set(tables.flatMap { (try? mappings(in: $0, md5: md5)) ?? [] }))
    }

    private func mappings(in table: String, md5: String) throws -> [MediaDatabaseMapping] {
        let sql = """
        SELECT \"file_name\", \"dir1\", \"dir2\"
        FROM \"\(table)\"
        WHERE lower(CAST(\"md5\" AS TEXT)) = lower(?)
           OR lower(CAST(\"md5_hash\" AS TEXT)) = lower(?)
        LIMIT 4
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArchiveError.databaseFailure
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, md5, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, md5, -1, sqliteTransient) == SQLITE_OK else {
            throw ArchiveError.databaseFailure
        }
        var results = [MediaDatabaseMapping]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return results }
            guard status == SQLITE_ROW else { throw ArchiveError.databaseFailure }
            results.append(MediaDatabaseMapping(
                fileName: text(statement, index: 0),
                dir1: text(statement, index: 1),
                dir2: text(statement, index: 2)
            ))
        }
    }

    private func requireHandle() -> OpaquePointer {
        precondition(handle != nil)
        return handle!
    }

    private func text(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }
}

public struct MessageMediaDiscoveryCoordinator: Sendable {
    public init() {}

    public func discover(
        exportRoot: URL,
        candidate: MessageTableCandidate,
        mediaRoot: URL?,
        sampleLimit: Int = 100,
        now: Date = Date(),
        mediaProgress: (@Sendable (MediaScanProgress) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> MessageMediaDiscoveryResult {
        let analysis = try WeChatMessageDiscovery().inspect(
            exportRoot: exportRoot,
            candidate: candidate,
            sampleLimit: sampleLimit,
            now: now
        )
        guard let mediaRoot else {
            let links = analysis.mediaReferences.map {
                MessageMediaLink(reference: $0, resolvedFile: nil, confidence: .unresolved, reason: "Media root not selected")
            }
            return MessageMediaDiscoveryResult(messageAnalysis: analysis, mediaScan: nil, links: links, observedTypeMappings: [])
        }
        let scan = try WeChatMediaScanner().scan(mediaRoot: mediaRoot, progress: mediaProgress, shouldCancel: shouldCancel)
        let resolver = MessageMediaResolver()
        let databaseMapper = WeChatMediaDatabaseMapper()
        let directLinks = analysis.mediaReferences.map { reference in
            (try? resolver.resolve(reference: reference, mediaFiles: scan.files))
                ?? MessageMediaLink(reference: reference, resolvedFile: nil, confidence: .unresolved, reason: "Media resolution failed")
        }
        let unresolvedReferences = directLinks
            .filter { $0.confidence == .unresolved }
            .map(\.reference)
        let mappedLinks = (try? databaseMapper.resolveAll(
            references: unresolvedReferences,
            exportRoot: exportRoot,
            mediaFiles: scan.files
        )) ?? [:]
        let links = directLinks.map { mappedLinks[$0.reference.sourceMessageIdentity] ?? $0 }
        return MessageMediaDiscoveryResult(
            messageAnalysis: analysis,
            mediaScan: scan,
            links: links,
            observedTypeMappings: observedTypeMappings(analysis: analysis, links: links)
        )
    }

    private func observedTypeMappings(
        analysis: MessageSampleAnalysis,
        links: [MessageMediaLink]
    ) -> [ObservedMessageTypeMapping] {
        guard let typeColumn = analysis.fieldMapping.rawTypeColumn else { return [] }
        let typesByIdentity = Dictionary(uniqueKeysWithValues: analysis.records.compactMap { record in
            record.values[typeColumn]?.integerValue.map { (record.identity, $0) }
        })
        var grouped = [Int64: [MessageMediaLink]]()
        for link in links where link.resolvedFile?.format.isImage == true {
            guard let rawType = typesByIdentity[link.reference.sourceMessageIdentity] else { continue }
            grouped[rawType, default: []].append(link)
        }
        return grouped.map { rawType, matches in
            let confidence = matches.contains(where: { $0.confidence == .exact }) ? LinkConfidence.exact : .high
            return ObservedMessageTypeMapping(
                rawType: rawType,
                observedType: .image,
                count: matches.count,
                confidence: confidence,
                evidence: ["image media file resolved"]
            )
        }
        .sorted { $0.rawType < $1.rawType }
    }
}

private func normalizedReferencePath(_ value: String) -> String? {
    let normalized = value.replacingOccurrences(of: "\\", with: "/")
    guard !normalized.isEmpty, !normalized.hasPrefix("/"), normalized.count <= 1_024 else { return nil }
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
    return components.joined(separator: "/")
}
