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

/// A privacy-safe result of one local media-resolution attempt. It deliberately
/// contains no media identifier, filename, or absolute path.
public enum MessageMediaDiagnostic: String, Codable, Equatable, Sendable {
    case hardlinkDatabaseMissing
    case hardlinkSchemaUnsupported
    case hardlinkQueryFailed
    case hardlinkNoMapping
    case hardlinkMultipleMappings
    case mappedFileMissing
    case mappedFileAmbiguous
    case mediaScanTruncated
    case mediaDecodeUnsupported
    case noMediaRoot
    case noSafeFallbackMatch
    case resolved
}

/// A fixed, non-sensitive rule used to join one hardlink mapping to the
/// user-selected account root. Mapping values themselves are never reported.
public enum MediaPathMappingRule: String, Codable, Equatable, Sendable {
    case accountRootRelative = "<mapping>"
    case msgPrefixed = "msg/<mapping>"
    case resourcePrefixed = "resource/<mapping>"
    case cachePrefixed = "cache/<mapping>"
}

public struct MessageMediaLink: Equatable, Sendable {
    public let reference: MediaReference
    public let resolvedFile: DiscoveredMediaFile?
    public let confidence: LinkConfidence
    public let diagnostic: MessageMediaDiagnostic
    public let mappingRule: MediaPathMappingRule?
    public let reason: String

    public init(
        reference: MediaReference,
        resolvedFile: DiscoveredMediaFile?,
        confidence: LinkConfidence,
        diagnostic: MessageMediaDiagnostic,
        mappingRule: MediaPathMappingRule? = nil,
        reason: String
    ) {
        self.reference = reference
        self.resolvedFile = resolvedFile
        self.confidence = confidence
        self.diagnostic = diagnostic
        self.mappingRule = mappingRule
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
    public let diagnostics: [MessageMediaDiagnostic]

    public init(
        messageAnalysis: MessageSampleAnalysis,
        mediaScan: MediaScanResult?,
        links: [MessageMediaLink],
        observedTypeMappings: [ObservedMessageTypeMapping],
        diagnostics: [MessageMediaDiagnostic] = []
    ) {
        self.messageAnalysis = messageAnalysis
        self.mediaScan = mediaScan
        self.links = links
        self.observedTypeMappings = observedTypeMappings
        self.diagnostics = diagnostics
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

    /// Inspects exactly one already-narrowed local file. This is used by the
    /// hardlink path resolver and does not enumerate or hash the media root.
    public func inspect(mediaFileURL: URL, below mediaRoot: URL) throws -> DiscoveredMediaFile {
        let root = try resolvedMediaRoot(mediaRoot)
        let requested = mediaFileURL.standardizedFileURL
        let requestedValues = try requested.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard requestedValues.isRegularFile == true,
              requestedValues.isSymbolicLink != true else {
            throw ArchiveError.invalidInput
        }
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              isDescendant(resolved, of: root),
              let relativePath = relativePath(of: resolved, below: root) else {
            throw ArchiveError.invalidInput
        }
        let header = try readHeader(at: resolved)
        let directFormat = MediaMagicDetector.detect(header)
        let xorDetection = directFormat == .unknown ? MediaMagicDetector.detectXORObfuscatedImage(header) : nil
        let format = xorDetection?.format ?? directFormat
        return DiscoveredMediaFile(
            sourceURL: resolved,
            relativePath: relativePath,
            fileSize: Int64(values.fileSize ?? 0),
            fileExtension: resolved.pathExtension.lowercased(),
            format: format,
            imageDimensions: format.isImage ? imageDimensions(at: resolved, xorKey: xorDetection?.key) : nil,
            headerXORKey: xorDetection?.key,
            sha256: nil
        )
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
            return MessageMediaLink(reference: reference, resolvedFile: file, confidence: .exact, diagnostic: .resolved, reason: "Exact relative path match")
        }
        if let mediaID = reference.mediaID, mediaID.count >= 8 {
            let matches = mediaFiles.filter { $0.relativePath.range(of: mediaID, options: .caseInsensitive) != nil }
            if matches.count == 1, let match = matches.first {
                return MessageMediaLink(reference: reference, resolvedFile: match, confidence: .high, diagnostic: .resolved, reason: "Exact media ID path match")
            }
        }
        if let expectedMD5 = reference.md5 {
            let namedCandidates = mediaFiles.filter {
                $0.relativePath.range(of: expectedMD5, options: .caseInsensitive) != nil
            }
            let candidates = namedCandidates.isEmpty && mediaFiles.count <= 24 ? mediaFiles : namedCandidates
            for candidate in candidates.prefix(24) {
                if try md5(of: candidate.sourceURL, xorKey: candidate.headerXORKey) == expectedMD5.lowercased() {
                    return MessageMediaLink(reference: reference, resolvedFile: candidate, confidence: .exact, diagnostic: .resolved, reason: "Exact MD5 match")
                }
            }
        }
        return MessageMediaLink(reference: reference, resolvedFile: nil, confidence: .unresolved, diagnostic: .noSafeFallbackMatch, reason: "No safe fallback media match")
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
/// resolves it before attempting a broad media scan. The mapping values remain
/// in memory and never enter a discovery report.
public struct WeChatMediaDatabaseMapper: Sendable {
    public init() {}

    public func resolve(
        reference: MediaReference,
        exportRoot: URL,
        mediaRoot: URL
    ) -> MessageMediaLink {
        resolveAll(references: [reference], exportRoot: exportRoot, mediaRoot: mediaRoot)[reference.sourceMessageIdentity]
            ?? unresolvedLink(for: reference, diagnostic: .hardlinkQueryFailed, reason: "Hardlink lookup did not return a diagnostic")
    }

    /// Opens the exported mapping database once for a bounded batch. Each
    /// input gets a diagnostic result so a schema or query failure is never
    /// silently presented as an ordinary unresolved media reference.
    public func resolveAll(
        references: [MediaReference],
        exportRoot: URL,
        mediaRoot: URL
    ) -> [SourceMessageIdentity: MessageMediaLink] {
        var links = [SourceMessageIdentity: MessageMediaLink]()
        let md5References = references.filter { validMD5($0.md5) }
        for reference in references where !validMD5(reference.md5) {
            links[reference.sourceMessageIdentity] = unresolvedLink(
                for: reference,
                diagnostic: .noSafeFallbackMatch,
                reason: "No structural MD5 available for hardlink lookup"
            )
        }
        guard !md5References.isEmpty else { return links }

        guard let databaseURL = hardlinkDatabaseURL(below: exportRoot) else {
            for reference in md5References {
                links[reference.sourceMessageIdentity] = unresolvedLink(
                    for: reference,
                    diagnostic: .hardlinkDatabaseMissing,
                    reason: "Exported hardlink database is unavailable"
                )
            }
            return links
        }

        let database: SQLiteMediaMappingDatabase
        do {
            database = try SQLiteMediaMappingDatabase(url: databaseURL)
        } catch {
            return linksFor(md5References, diagnostic: .hardlinkQueryFailed, reason: "Hardlink database could not be opened", existing: links)
        }
        let schemas: [HardlinkTableSchema]
        do {
            schemas = try database.supportedSchemas()
        } catch {
            return linksFor(md5References, diagnostic: .hardlinkQueryFailed, reason: "Hardlink schema query failed", existing: links)
        }
        guard !schemas.isEmpty else {
            return linksFor(md5References, diagnostic: .hardlinkSchemaUnsupported, reason: "Hardlink schema does not expose required mapping fields", existing: links)
        }

        for reference in md5References {
            guard let md5 = reference.md5 else { continue }
            let mappings: [MediaDatabaseMapping]
            do {
                mappings = try database.mappings(for: md5, schemas: schemas)
            } catch {
                links[reference.sourceMessageIdentity] = unresolvedLink(for: reference, diagnostic: .hardlinkQueryFailed, reason: "Hardlink mapping query failed")
                continue
            }
            switch mappings.count {
            case 0:
                links[reference.sourceMessageIdentity] = unresolvedLink(for: reference, diagnostic: .hardlinkNoMapping, reason: "No exact MD5 mapping in hardlink database")
            case 1:
                links[reference.sourceMessageIdentity] = resolveUniqueMapping(reference: reference, mapping: mappings[0], mediaRoot: mediaRoot)
            default:
                links[reference.sourceMessageIdentity] = unresolvedLink(for: reference, diagnostic: .hardlinkMultipleMappings, reason: "Multiple exact MD5 mappings in hardlink database")
            }
        }
        return links
    }

    private func resolveUniqueMapping(
        reference: MediaReference,
        mapping: MediaDatabaseMapping,
        mediaRoot: URL
    ) -> MessageMediaLink {
        let candidates: [MappedLocalCandidate]
        do {
            candidates = try localCandidates(for: mapping, below: mediaRoot)
        } catch {
            return unresolvedLink(for: reference, diagnostic: .mappedFileMissing, reason: "Mapped local file is unavailable")
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return unresolvedLink(
                for: reference,
                diagnostic: candidates.isEmpty ? .mappedFileMissing : .mappedFileAmbiguous,
                reason: candidates.isEmpty ? "Mapped local file is unavailable" : "Mapped local path is ambiguous"
            )
        }
        do {
            let file = try WeChatMediaScanner().inspect(mediaFileURL: candidate.url, below: mediaRoot)
            guard file.format != .unknown else {
                return unresolvedLink(for: reference, diagnostic: .mediaDecodeUnsupported, reason: "Mapped file format is not supported")
            }
            return MessageMediaLink(reference: reference, resolvedFile: file, confidence: .exact, diagnostic: .resolved, mappingRule: candidate.rule, reason: "Exact MD5 hardlink mapping")
        } catch {
            return unresolvedLink(for: reference, diagnostic: .mediaDecodeUnsupported, reason: "Mapped file could not be inspected")
        }
    }

    private func linksFor(
        _ references: [MediaReference],
        diagnostic: MessageMediaDiagnostic,
        reason: String,
        existing: [SourceMessageIdentity: MessageMediaLink]
    ) -> [SourceMessageIdentity: MessageMediaLink] {
        var links = existing
        for reference in references {
            links[reference.sourceMessageIdentity] = unresolvedLink(for: reference, diagnostic: diagnostic, reason: reason)
        }
        return links
    }

    private func unresolvedLink(
        for reference: MediaReference,
        diagnostic: MessageMediaDiagnostic,
        reason: String
    ) -> MessageMediaLink {
        MessageMediaLink(reference: reference, resolvedFile: nil, confidence: .unresolved, diagnostic: diagnostic, reason: reason)
    }

    private func validMD5(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil
    }

    private func hardlinkDatabaseURL(below exportRoot: URL) -> URL? {
        let root = exportRoot.standardizedFileURL
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else { return nil }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let requestedDatabase = root.appending(path: "hardlink/hardlink.db").standardizedFileURL
        guard let requestedValues = try? requestedDatabase.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              requestedValues.isRegularFile == true,
              requestedValues.isSymbolicLink != true else { return nil }
        let database = requestedDatabase.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path().hasSuffix("/") ? resolvedRoot.path() : resolvedRoot.path() + "/"
        guard database.path().hasPrefix(rootPath), database.pathExtension.lowercased() == "db",
              let values = try? database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return database
    }

    /// The hardlink values are not assumed to be account-root-relative. We
    /// test only the minimal fixed container prefixes observed in account data.
    private func localCandidates(for mapping: MediaDatabaseMapping, below mediaRoot: URL) throws -> [MappedLocalCandidate] {
        let requestedRoot = mediaRoot.standardizedFileURL
        let requestedRootValues = try requestedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard requestedRootValues.isDirectory == true, requestedRootValues.isSymbolicLink != true else {
            throw ArchiveError.invalidInput
        }
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let components = mapping.pathComponents else { return [] }
        let prefixes: [(components: [String], rule: MediaPathMappingRule)] = [
            ([], .accountRootRelative),
            (["msg"], .msgPrefixed),
            (["resource"], .resourcePrefixed),
            (["cache"], .cachePrefixed)
        ]
        var candidates = [URL: MediaPathMappingRule]()
        for prefix in prefixes {
            let requestedCandidate = (prefix.components + components).reduce(root) { $0.appending(path: $1) }
                .standardizedFileURL
            guard let requestedValues = try? requestedCandidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  requestedValues.isRegularFile == true,
                  requestedValues.isSymbolicLink != true else { continue }
            let candidate = requestedCandidate
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard isDescendant(candidate, of: root),
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            candidates[candidate] = candidates[candidate] ?? prefix.rule
        }
        return candidates
            .map { MappedLocalCandidate(url: $0.key, rule: $0.value) }
            .sorted { $0.url.path() < $1.url.path() }
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        return url.path().hasPrefix(rootPath)
    }
}

private struct MediaDatabaseMapping: Hashable, Sendable {
    let fileName: String?
    let dir1: String?
    let dir2: String?

    var pathComponents: [String]? {
        let values = [dir1, dir2, fileName].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return normalizedReferencePath(value)
        }
        let components = values.flatMap { $0.split(separator: "/").map(String.init) }
        return components.isEmpty ? nil : components
    }
}

private struct MappedLocalCandidate: Sendable {
    let url: URL
    let rule: MediaPathMappingRule
}

private struct HardlinkTableSchema: Sendable {
    let tableName: String
    let hasMD5Hash: Bool
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

    func supportedSchemas() throws -> [HardlinkTableSchema] {
        let expectedTables = Set(["image_hardlink_info_v4", "video_hardlink_info_v4", "file_hardlink_info_v4"])
        let tables = try tableNames().filter { expectedTables.contains($0) }
        return try tables.compactMap { table in
            let fields = try columnNames(in: table)
            guard Set(["md5", "file_name", "dir1", "dir2"]).isSubset(of: fields) else { return nil }
            return HardlinkTableSchema(tableName: table, hasMD5Hash: fields.contains("md5_hash"))
        }
    }

    func mappings(for md5: String, schemas: [HardlinkTableSchema]) throws -> [MediaDatabaseMapping] {
        var collectedMappings = Set<MediaDatabaseMapping>()
        for schema in schemas {
            for mapping in try mappings(in: schema, md5: md5) {
                collectedMappings.insert(mapping)
            }
        }
        return collectedMappings.sorted { ($0.pathComponents ?? []).joined(separator: "/") < ($1.pathComponents ?? []).joined(separator: "/") }
    }

    private func tableNames() throws -> [String] {
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArchiveError.databaseFailure
        }
        defer { sqlite3_finalize(statement) }
        var names = [String]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return names }
            guard status == SQLITE_ROW, let name = text(statement, index: 0) else { throw ArchiveError.databaseFailure }
            names.append(name)
        }
    }

    private func columnNames(in table: String) throws -> Set<String> {
        guard ["image_hardlink_info_v4", "video_hardlink_info_v4", "file_hardlink_info_v4"].contains(table) else {
            throw ArchiveError.databaseFailure
        }
        let sql = "PRAGMA table_info(\"\(table)\")"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArchiveError.databaseFailure
        }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return names }
            guard status == SQLITE_ROW, let name = text(statement, index: 1) else { throw ArchiveError.databaseFailure }
            names.insert(name.lowercased())
        }
    }

    private func mappings(in schema: HardlinkTableSchema, md5: String) throws -> [MediaDatabaseMapping] {
        let predicate = schema.hasMD5Hash
            ? "lower(CAST(\"md5\" AS TEXT)) = lower(?) OR lower(CAST(\"md5_hash\" AS TEXT)) = lower(?)"
            : "lower(CAST(\"md5\" AS TEXT)) = lower(?)"
        let sql = """
        SELECT \"file_name\", \"dir1\", \"dir2\"
        FROM \"\(schema.tableName)\"
        WHERE \(predicate)
        LIMIT 5
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArchiveError.databaseFailure
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, md5, -1, sqliteTransient) == SQLITE_OK else {
            throw ArchiveError.databaseFailure
        }
        if schema.hasMD5Hash,
           sqlite3_bind_text(statement, 2, md5, -1, sqliteTransient) != SQLITE_OK {
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
        mediaScanMaximumResults: Int = 20_000,
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
                MessageMediaLink(reference: $0, resolvedFile: nil, confidence: .unresolved, diagnostic: .noMediaRoot, reason: "Media root not selected")
            }
            return MessageMediaDiscoveryResult(messageAnalysis: analysis, mediaScan: nil, links: links, observedTypeMappings: [])
        }
        let databaseMapper = WeChatMediaDatabaseMapper()
        let mappedLinks = databaseMapper.resolveAll(
            references: analysis.mediaReferences,
            exportRoot: exportRoot,
            mediaRoot: mediaRoot
        )
        let initialLinks = analysis.mediaReferences.map { reference in
            mappedLinks[reference.sourceMessageIdentity]
                ?? MessageMediaLink(reference: reference, resolvedFile: nil, confidence: .unresolved, diagnostic: .hardlinkQueryFailed, reason: "Hardlink lookup did not return a diagnostic")
        }
        let unresolvedReferences = initialLinks
            .filter { $0.confidence == .unresolved }
            .map(\.reference)
        guard !unresolvedReferences.isEmpty else {
            return MessageMediaDiscoveryResult(
                messageAnalysis: analysis,
                mediaScan: nil,
                links: initialLinks,
                observedTypeMappings: observedTypeMappings(analysis: analysis, links: initialLinks)
            )
        }
        let scan = try WeChatMediaScanner().scan(
            mediaRoot: mediaRoot,
            maximumResults: mediaScanMaximumResults,
            progress: mediaProgress,
            shouldCancel: shouldCancel
        )
        let resolver = MessageMediaResolver()
        let fallbackLinks = Dictionary(uniqueKeysWithValues: unresolvedReferences.map { reference in
            let link: MessageMediaLink
            do {
                link = try resolver.resolve(reference: reference, mediaFiles: scan.files)
            } catch {
                link = MessageMediaLink(reference: reference, resolvedFile: nil, confidence: .unresolved, diagnostic: .noSafeFallbackMatch, reason: "Fallback media resolution failed")
            }
            return (reference.sourceMessageIdentity, link)
        })
        let links = initialLinks.map { hardlinkLink in
            guard let fallback = fallbackLinks[hardlinkLink.reference.sourceMessageIdentity],
                  fallback.confidence != .unresolved else { return hardlinkLink }
            return fallback
        }
        let diagnostics = scan.isTruncated ? [MessageMediaDiagnostic.mediaScanTruncated] : []
        return MessageMediaDiscoveryResult(
            messageAnalysis: analysis,
            mediaScan: scan,
            links: links,
            observedTypeMappings: observedTypeMappings(analysis: analysis, links: links),
            diagnostics: diagnostics
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
