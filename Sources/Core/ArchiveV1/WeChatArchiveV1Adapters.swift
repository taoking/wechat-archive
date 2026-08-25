import CryptoKit
import Foundation
import SQLite3
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct WeChatTextMessageAdapter: Sendable {
    public init() {}

    public func textContent(from values: [String: ArchivedSQLiteValue]) -> String? {
        guard rawTypeLow32(values.integer(named: ["local_type", "msg_type", "message_type", "type"])) == 1 else { return nil }
        return values.text(named: ["message_content", "content", "strcontent"])
    }
}

/// The low 32 bits carry the message kind while the full signed source value is
/// retained separately for future analysis of high-bit flags.
public func rawTypeLow32(_ value: Int64?) -> UInt64? {
    value.map { UInt64(bitPattern: $0) & 0xffff_ffff }
}

/// The high 32 bits carry the app-message subtype for `local_type` low32 ==
/// 49 (link share, mini program, red packet, transfer, quote-reply, ...).
public func rawTypeHigh32(_ value: Int64?) -> UInt64? {
    value.map { UInt64(bitPattern: $0) >> 32 }
}

/// Synthesizes readable `.text` content for message categories WeChat
/// stores as a zstd-compressed XML/plain-text `message_content` BLOB rather
/// than a TEXT column — observed on WeChat's newer WCDB-based local schema.
/// It only recognizes shapes verified against a real local archive
/// (`docs/decisions/` follow-up); anything it cannot confidently parse is
/// left as `.unknown` exactly as before, so this can only add coverage,
/// never mislabel a message. It never resolves external XML entities.
struct WeChatCompressedTextMessageAdapter: Sendable {
    private let maximumXMLBytes = 512 * 1_024

    func textContent(from values: [String: ArchivedSQLiteValue], rawType: Int64?) -> String? {
        guard let payload = WeChatMessagePayloadDecoder.decodedPayload(from: values) else { return nil }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let low32 = rawTypeLow32(rawType)
        guard trimmed.hasPrefix("<") else {
            // A group-chat plain-text message whose content WeChat stored as
            // a compressed blob instead of a TEXT column.
            return low32 == 1 ? trimmed : nil
        }
        guard trimmed.utf8.count <= maximumXMLBytes, let document = WeChatMessageXMLDocument(xml: trimmed) else { return nil }
        switch low32 {
        case 10_000: return systemMessageText(document)
        case 48: return locationMessageText(document)
        case 49: return appMessageText(document, subtype: rawTypeHigh32(rawType))
        default: return nil
        }
    }

    /// Verified against real `<sysmsg type="revokemsg">` payloads: only the
    /// revoke-notice subtype is recognized so far. Other `sysmsg` subtypes
    /// (group notices, pats, ...) fall through to `.unknown` unchanged.
    private func systemMessageText(_ document: WeChatMessageXMLDocument) -> String? {
        guard let content = document.text(atPath: ["sysmsg", "revokemsg", "content"]), !content.isEmpty else { return nil }
        return content
    }

    private func locationMessageText(_ document: WeChatMessageXMLDocument) -> String? {
        guard let attributes = document.attributes(atPath: ["msg", "location"]) else { return nil }
        let name = [attributes["poiname"], attributes["label"]].compactMap { $0 }.first { !$0.isEmpty }
        guard let name else { return nil }
        return "[位置] \(name)"
    }

    /// Covers every `local_type` low32 == 49 subtype generically via the
    /// `appmsg/title` and `appmsg/refermsg` elements common to WeChat's app
    /// message schema regardless of subtype (link share, mini program, red
    /// packet, transfer, quote-reply, ...). Only the quote-reply subtype's
    /// full tree and the label mapping below were verified against a real
    /// archive; unverified subtypes still degrade to a generic "[分享]"
    /// label rather than guessing subtype-specific fields.
    private func appMessageText(_ document: WeChatMessageXMLDocument, subtype: UInt64?) -> String? {
        guard let title = document.text(atPath: ["msg", "appmsg", "title"]), !title.isEmpty else { return nil }
        if let quotedFrom = document.text(atPath: ["msg", "appmsg", "refermsg", "displayname"]), !quotedFrom.isEmpty,
           let quotedContent = document.text(atPath: ["msg", "appmsg", "refermsg", "content"]), !quotedContent.isEmpty {
            return "引用「\(quotedFrom)」：\(quotedContent)\n\(title)"
        }
        return "[\(appMessageLabel(subtype: subtype))] \(title)"
    }

    private func appMessageLabel(subtype: UInt64?) -> String {
        switch subtype {
        case 5: "链接"
        case 6: "文件"
        case 8: "表情"
        case 19: "聊天记录"
        case 33, 36: "小程序"
        case 51, 62, 63: "视频号"
        case 2000: "红包"
        case 2001: "转账"
        default: "分享"
        }
    }
}

/// Decodes `message_content`/`compress_content` when the local exporter
/// stored it as a zstd-compressed BLOB instead of a TEXT column, and strips
/// the `"{senderWxid}:\n"` prefix WeChat prepends to group-chat payloads
/// before compression.
enum WeChatMessagePayloadDecoder {
    static func decodedPayload(from values: [String: ArchivedSQLiteValue]) -> String? {
        for column in ["message_content", "compress_content"] {
            guard let blob = values.blob(named: [column]),
                  let decompressed = ZstdPayloadDecompressor.decompress(blob),
                  var text = String(data: decompressed, encoding: .utf8) else { continue }
            if let newline = text.firstIndex(of: "\n") {
                let prefix = text[text.startIndex..<newline]
                if prefix.hasSuffix(":"), prefix.count <= 64, !prefix.dropLast().contains(where: { $0.isWhitespace }) {
                    text = String(text[text.index(after: newline)...])
                }
            }
            return text
        }
        return nil
    }
}

/// Decompresses WeChat's zstd-compressed message payloads via the local
/// `zstd` CLI (installed by this project's `Brewfile`, matching the same
/// external-tool boundary already established by `SilkProcessVoiceDecoder`
/// for Silk voice). Apple's system `Compression` framework does **not**
/// support Zstandard (verified against the macOS SDK's `compression.h`:
/// only LZ4/ZLIB/LZMA/LZFSE/LZBITMAP/BROTLI are defined), so unlike Silk
/// decoding this is not yet bundled into the Release `.app` by
/// `build-app.sh` — see DEVELOPMENT.md. When the CLI is unavailable,
/// `decompress` returns nil and the caller leaves the message `.unknown`
/// exactly as it already does today; this can only add coverage, never
/// regress it.
enum ZstdPayloadDecompressor {
    private static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    private static let maximumCompressedBytes = 4 * 1_024 * 1_024
    private static let maximumDecodedBytes = 8 * 1_024 * 1_024
    private static let timeout: TimeInterval = 5

    static func decompress(_ data: Data) -> Data? {
        guard data.count >= magic.count, data.count <= maximumCompressedBytes, data.starts(with: magic) else { return nil }
        guard let executableURL = defaultExecutableURL() else { return nil }
        let directory = FileManager.default.temporaryDirectory.appending(path: "WeChatArchive-Zstd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let inputURL = directory.appending(path: "payload.zst")
            let outputURL = directory.appending(path: "payload.out")
            guard FileManager.default.createFile(atPath: inputURL.path(), contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["-d", "-q", "-f", "-o", outputURL.path(), inputURL.path()]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() >= deadline {
                    process.terminate()
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard process.terminationStatus == 0 else { return nil }
            let metadata = try outputURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let size = metadata.fileSize, size > 0, size <= maximumDecodedBytes else { return nil }
            return try Data(contentsOf: outputURL, options: .mappedIfSafe)
        } catch {
            return nil
        }
    }

    private static func defaultExecutableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates: [String?] = [
            environment["WECHAT_ARCHIVE_ZSTD_DECODER"],
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd"
        ]
        return candidates.compactMap { $0 }.map(URL.init(fileURLWithPath:)).first(where: isSafeExecutable)
    }

    // Unlike the media-path validators elsewhere in Core, this only ever
    // resolves a fixed candidate string or an operator-supplied environment
    // variable — never an untrusted relative path — so following the
    // symlink here (needed since Homebrew's official formulas, including
    // zstd, always install as a Cellar symlink) carries no traversal risk.
    private static func isSafeExecutable(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { return false }
        return FileManager.default.isExecutableFile(atPath: resolved.path())
    }
}

/// A minimal, path-addressed XML reader for message payloads. It disables
/// external entity and DTD resolution and retains only element text and
/// attributes, matching the discovery pipeline's structured-payload policy
/// of never resolving external entities.
final class WeChatMessageXMLDocument: NSObject, XMLParserDelegate {
    private struct Node {
        var text = ""
        var attributes: [String: String] = [:]
        var children: [String: Node] = [:]
    }

    private var root = Node()
    private var currentPath: [String] = []

    init?(xml: String) {
        guard let data = xml.data(using: .utf8) else { return nil }
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = self
        guard parser.parse() else { return nil }
    }

    func text(atPath path: [String]) -> String? {
        node(atPath: path)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func attributes(atPath path: [String]) -> [String: String]? {
        node(atPath: path)?.attributes
    }

    private func node(atPath path: [String]) -> Node? {
        var current = root
        for key in path {
            guard let next = current.children[key] else { return nil }
            current = next
        }
        return current
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentPath.append(elementName)
        setAttributes(attributeDict, at: currentPath)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string, at: currentPath)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !currentPath.isEmpty { currentPath.removeLast() }
    }

    private func setAttributes(_ attributes: [String: String], at path: [String]) {
        modify(path: path) { node in
            if !attributes.isEmpty { node.attributes = attributes }
        }
    }

    private func appendText(_ string: String, at path: [String]) {
        guard !path.isEmpty else { return }
        modify(path: path) { node in node.text += string }
    }

    private func modify(path: [String], _ body: (inout Node) -> Void) {
        modify(&root, path: path[...], body)
    }

    private func modify(_ node: inout Node, path: ArraySlice<String>, _ body: (inout Node) -> Void) {
        guard let head = path.first else {
            body(&node)
            return
        }
        modify(&node.children[head, default: Node()], path: path.dropFirst(), body)
    }
}

struct ArchiveV1MediaInput {
    let mediaType: ArchiveV1MediaType
    let variant: ArchiveV1MediaVariant
    let status: ArchiveV1MediaStatus
    let sourceFormat: String?
    let decodedFormat: String?
    let rawData: Data?
    let rawFileURL: URL?
    let decodedData: Data?
    let width: Int?
    let height: Int?
    let duration: Double?
    let sourceFileBase: String?

    init(
        mediaType: ArchiveV1MediaType = .image,
        variant: ArchiveV1MediaVariant,
        status: ArchiveV1MediaStatus,
        sourceFormat: String?,
        decodedFormat: String?,
        rawData: Data?,
        rawFileURL: URL? = nil,
        decodedData: Data?,
        width: Int?,
        height: Int?,
        duration: Double? = nil,
        sourceFileBase: String?
    ) {
        self.mediaType = mediaType
        self.variant = variant
        self.status = status
        self.sourceFormat = sourceFormat
        self.decodedFormat = decodedFormat
        self.rawData = rawData
        self.rawFileURL = rawFileURL
        self.decodedData = decodedData
        self.width = width
        self.height = height
        self.duration = duration
        self.sourceFileBase = sourceFileBase
    }
}

typealias ArchiveV1ImageVariantInput = ArchiveV1MediaInput

/// Uses only the validated Phase 3A.2 message-resource chain. It never falls
/// back to hardlink scanning and it retains raw DAT bytes even when a decode is
/// unsupported or fails.
struct WeChatImageMessageAdapter {
    let keyProvider: any WeChatImageKeyProvider
    private let maximumDATBytes = 128 * 1_024 * 1_024

    func variants(
        message: ArchiveV1SourceMessage,
        exportRoot: URL,
        accountRoot: URL
    ) throws -> [ArchiveV1ImageVariantInput] {
        let candidate = MessageTableCandidate(
            databaseRelativePath: message.sourceDatabase,
            tableName: message.sourceTable,
            rowCount: nil,
            score: 0,
            columns: message.values.keys.sorted()
        )
        let sourceValues = Dictionary(uniqueKeysWithValues: message.values.map { key, value in
            (key, archiveSQLiteSourceValue(value))
        })
        let source = SourceMessageRecord(
            identity: SourceMessageIdentity(databaseRelativePath: message.sourceDatabase, tableName: message.sourceTable, rowIdentifier: String(message.sourceSQLiteRowID)),
            values: sourceValues
        )
        let resolved = try WeChatImageMessageResolver().resolve(
            message: source,
            candidate: candidate,
            exportRoot: exportRoot,
            accountRoot: accountRoot
        )
        let fileBase = resolved.fileBase?.value
        let locations: [(ArchiveV1MediaVariant, URL?)] = [
            (.main, resolved.assets.mainURL), (.hd, resolved.assets.hdURL), (.thumbnail, resolved.assets.thumbnailURL)
        ]
        if resolved.fileBaseEvidence == .conflict {
            return locations.map {
                .init(variant: $0.0, status: .resolutionConflict, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil)
            }
        }
        guard resolved.resourceMatch != .notFound else {
            return locations.map { ArchiveV1ImageVariantInput(variant: $0.0, status: .missing, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil) }
        }
        var results = [ArchiveV1ImageVariantInput]()
        let decoder = WeChatImageDatDecoder()
        var cachedKeys: [WeChatImageKeyMaterial]?
        for (variant, url) in locations {
            guard let url else {
                results.append(.init(variant: variant, status: .missing, sourceFormat: resolved.datVersion.rawValue, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: fileBase))
                continue
            }
            let raw = try readDAT(url)
            let version = decoder.version(for: raw)
            switch version {
            case .v2:
                if cachedKeys == nil { cachedKeys = try keyProvider.keyCandidates(accountRoot: accountRoot) }
                guard let keys = cachedKeys, !keys.isEmpty else {
                    results.append(.init(variant: variant, status: .imageKeyUnavailable, sourceFormat: version.rawValue, decodedFormat: nil, rawData: raw, decodedData: nil, width: nil, height: nil, sourceFileBase: fileBase))
                    continue
                }
                results.append(decodeV2(variant: variant, raw: raw, decoder: decoder, keys: keys, fileBase: fileBase))
            case .v1, .legacy:
                // These decoders remain experimental until a real local sample
                // verifies them; preserve the raw bytes without claiming support.
                results.append(.init(variant: variant, status: .decodeUnsupported, sourceFormat: version.rawValue, decodedFormat: nil, rawData: raw, decodedData: nil, width: nil, height: nil, sourceFileBase: fileBase))
            case .unknown:
                results.append(.init(variant: variant, status: .unsupportedVersion, sourceFormat: nil, decodedFormat: nil, rawData: raw, decodedData: nil, width: nil, height: nil, sourceFileBase: fileBase))
            }
        }
        return results
    }

    private func decodeV2(
        variant: ArchiveV1MediaVariant,
        raw: Data,
        decoder: WeChatImageDatDecoder,
        keys: [WeChatImageKeyMaterial],
        fileBase: String?
    ) -> ArchiveV1ImageVariantInput {
        var sawInvalidLayout = false
        var sawInvalidPadding = false
        var sawUnknownFormat = false
        var sawDecodeFailure = false
        for key in keys {
            do {
                let decoded = try decoder.decode(raw, keyMaterial: key)
                let width = decoded.dimensions?.width
                let height = decoded.dimensions?.height
                if decoded.format == .wxgf {
                    return .init(variant: variant, status: .decodeUnsupported, sourceFormat: "v2", decodedFormat: decoded.format.rawValue, rawData: raw, decodedData: decoded.data, width: width, height: height, sourceFileBase: fileBase)
                }
                return .init(variant: variant, status: .decoded, sourceFormat: "v2", decodedFormat: decoded.format.rawValue, rawData: raw, decodedData: decoded.data, width: width, height: height, sourceFileBase: fileBase)
            } catch let error as WeChatImageDATError {
                switch error {
                case .invalidLayout: sawInvalidLayout = true
                case .invalidPadding: sawInvalidPadding = true
                case .unrecognizedDecodedImage: sawUnknownFormat = true
                case .cryptographicFailure, .inputTooShort, .invalidKeyMaterial: sawDecodeFailure = true
                default: break
                }
            } catch { }
        }
        let status: ArchiveV1MediaStatus
        if sawInvalidLayout { status = .invalidDATLayout }
        else if sawUnknownFormat { status = .decodedUnknownFormat }
        else if keys.count == 1 && sawInvalidPadding { status = .invalidPadding }
        else if sawDecodeFailure { status = .decodeFailed }
        else { status = .imageKeyRejected }
        return .init(variant: variant, status: status, sourceFormat: "v2", decodedFormat: nil, rawData: raw, decodedData: nil, width: nil, height: nil, sourceFileBase: fileBase)
    }

    private func readDAT(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= maximumDATBytes else { throw ArchiveError.invalidInput }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

}

/// Resolves only deterministic `msg/video/<month>/<file-base>` candidates.
/// The resource index supplies the same file-base evidence used for images;
/// no recursive video scan or content hash search is performed.
struct WeChatVideoMessageAdapter {
    func variants(
        message: ArchiveV1SourceMessage,
        exportRoot: URL,
        accountRoot: URL
    ) throws -> [ArchiveV1MediaInput] {
        let candidate = MessageTableCandidate(
            databaseRelativePath: message.sourceDatabase,
            tableName: message.sourceTable,
            rowCount: nil,
            score: 0,
            columns: message.values.keys.sorted()
        )
        let resolution = try WeChatMessageResourceFileBaseResolver().resolve(
            message: archiveSourceMessageRecord(message),
            candidate: candidate,
            exportRoot: exportRoot
        )
        if resolution.fileBaseEvidence == .conflict {
            return ArchiveV1MediaVariant.videoVariants.map {
                .init(mediaType: .video, variant: $0, status: .resolutionConflict, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil)
            }
        }
        guard resolution.fileBaseEvidence.allowsMediaBinding, let fileBase = resolution.fileBase?.value else {
            return ArchiveV1MediaVariant.videoVariants.map { missingInput(variant: $0) }
        }
        let timestamp = message.values.integer(named: ["create_time", "createTime", "timestamp", "time"]) ?? 0
        let assets = try WeChatVideoAttachmentLocator().locate(accountRoot: accountRoot, fileBase: fileBase, createTime: timestamp)
        return [
            input(variant: .play, url: assets.playURL, fileBase: fileBase),
            input(variant: .raw, url: assets.rawURL, fileBase: fileBase),
            input(variant: .thumbnail, url: assets.thumbnailURL, fileBase: fileBase)
        ]
    }

    private func input(variant: ArchiveV1MediaVariant, url: URL?, fileBase: String) -> ArchiveV1MediaInput {
        guard let url else { return missingInput(variant: variant, fileBase: fileBase) }
        let metadata = ArchiveV1VideoMetadata.read(url: url)
        return .init(
            mediaType: .video,
            variant: variant,
            status: .rawArchived,
            sourceFormat: variant == .thumbnail ? "image" : "mp4",
            decodedFormat: nil,
            rawData: nil,
            rawFileURL: url,
            decodedData: nil,
            width: metadata.width,
            height: metadata.height,
            duration: metadata.duration,
            sourceFileBase: fileBase
        )
    }

    private func missingInput(variant: ArchiveV1MediaVariant, fileBase: String? = nil) -> ArchiveV1MediaInput {
        .init(mediaType: .video, variant: variant, status: .missing, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: fileBase)
    }
}

struct WeChatVideoAttachmentLocator: Sendable {
    func locate(accountRoot: URL, fileBase: String, createTime: Int64) throws -> (playURL: URL?, rawURL: URL?, thumbnailURL: URL?) {
        guard isHex32(fileBase) else { throw ArchiveError.invalidInput }
        let root = accountRoot.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        let videoRoot = root.appending(path: "msg/video")
        guard Self.safeDirectory(videoRoot, below: root) else { return (nil, nil, nil) }
        for month in monthCandidates(for: createTime) {
            let monthDirectory = videoRoot.appending(path: month)
            guard Self.safeDirectory(monthDirectory, below: videoRoot) else { continue }
            let play = Self.safeFile(monthDirectory.appending(path: "\(fileBase).mp4"), below: monthDirectory)
            let raw = Self.safeFile(monthDirectory.appending(path: "\(fileBase)_raw.mp4"), below: monthDirectory)
            let thumbnail = Self.safeFile(monthDirectory.appending(path: "\(fileBase)_thumb.jpg"), below: monthDirectory)
                ?? Self.safeFile(monthDirectory.appending(path: "\(fileBase).jpg"), below: monthDirectory)
            if play != nil || raw != nil || thumbnail != nil { return (play, raw, thumbnail) }
        }
        return (nil, nil, nil)
    }

    private func monthCandidates(for timestamp: Int64) -> [String] {
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let dates = [date, calendar.date(byAdding: .month, value: -1, to: date), calendar.date(byAdding: .month, value: 1, to: date)].compactMap { $0 }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"
        return Array(NSOrderedSet(array: dates.map(formatter.string))) as? [String] ?? []
    }

    private static func safeDirectory(_ url: URL, below parent: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { return false }
        return isDescendant(url, of: parent)
    }

    private static func safeFile(_ url: URL, below parent: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true, isDescendant(url, of: parent) else { return nil }
        return url
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path()
        let valuePath = url.resolvingSymlinksInPath().standardizedFileURL.path()
        return valuePath.hasPrefix(parentPath.hasSuffix("/") ? parentPath : parentPath + "/")
    }

    private func isHex32(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

private struct ArchiveV1VideoMetadata {
    let duration: Double?
    let width: Int?
    let height: Int?

    static func read(url: URL) -> Self {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        let duration = asset.duration.seconds
        let track = asset.tracks(withMediaType: .video).first
        let size = track.map { $0.naturalSize.applying($0.preferredTransform) }
        return .init(
            duration: duration.isFinite && duration >= 0 ? duration : nil,
            width: size.map { Int(abs($0.width).rounded()) },
            height: size.map { Int(abs($0.height).rounded()) }
        )
        #else
        _ = url
        return .init(duration: nil, width: nil, height: nil)
        #endif
    }
}

/// Finds a voice record only through the locally validated `VoiceInfo`
/// schema and exact local/server/time predicates. It does not probe arbitrary
/// BLOBs and never turns unknown bytes into a playable format.
struct WeChatVoiceMessageAdapter {
    private let maximumVoiceBytes = 64 * 1_024 * 1_024
    private let decoder: any VoiceDecoder

    init(decoder: any VoiceDecoder = SilkProcessVoiceDecoder()) {
        self.decoder = decoder
    }

    func variants(
        message: ArchiveV1SourceMessage,
        exportRoot: URL,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> [ArchiveV1MediaInput] {
        guard let localID = message.values.integer(named: ["local_id", "message_id", "msg_id"]),
              let serverID = message.values.integer(named: ["server_id", "svr_id", "msg_svr_id", "message_svr_id"]),
              let createTime = message.values.integer(named: ["create_time", "createTime", "timestamp", "time"]) else {
            return [missingInput]
        }
        for databaseURL in try mediaDatabaseURLs(below: exportRoot) {
            let database = try VoiceMediaDatabase(url: databaseURL)
            if let data = try database.voiceData(localID: localID, serverID: serverID, createTime: createTime, maximumBytes: maximumVoiceBytes) {
                let format = VoiceFormatDetector().detect(data)
                guard format == .silk else {
                    return [.init(
                        mediaType: .voice,
                        variant: .raw,
                        status: .decodeUnsupported,
                        sourceFormat: format.rawValue,
                        decodedFormat: nil,
                        rawData: data,
                        decodedData: nil,
                        width: nil,
                        height: nil,
                        sourceFileBase: nil
                    )]
                }
                do {
                    let decoded = try decoder.decode(data, shouldCancel: shouldCancel)
                    let wav = try WAVWriter().write(decoded)
                    return [.init(
                        mediaType: .voice,
                        variant: .raw,
                        status: .decoded,
                        sourceFormat: format.rawValue,
                        decodedFormat: "wav",
                        rawData: data,
                        decodedData: wav,
                        width: nil,
                        height: nil,
                        duration: decoded.duration,
                        sourceFileBase: nil
                    )]
                } catch VoiceDecoderError.decoderUnavailable {
                    return [rawOnlyInput(data: data, format: format, status: .decodeUnsupported)]
                } catch {
                    return [rawOnlyInput(data: data, format: format, status: .decodeFailed)]
                }
            }
        }
        return [missingInput]
    }

    private var missingInput: ArchiveV1MediaInput {
        .init(mediaType: .voice, variant: .raw, status: .missing, sourceFormat: nil, decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil)
    }

    private func rawOnlyInput(data: Data, format: VoiceFormat, status: ArchiveV1MediaStatus) -> ArchiveV1MediaInput {
        .init(
            mediaType: .voice,
            variant: .raw,
            status: status,
            sourceFormat: format.rawValue,
            decodedFormat: nil,
            rawData: data,
            decodedData: nil,
            width: nil,
            height: nil,
            sourceFileBase: nil
        )
    }

    private func mediaDatabaseURLs(below exportRoot: URL) throws -> [URL] {
        let root = exportRoot.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        let messageDirectory = root.appending(path: "message")
        guard let values = try? messageDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { return [] }
        return try FileManager.default.contentsOfDirectory(at: messageDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                guard name.hasPrefix("media_") && url.pathExtension.lowercased() == "db",
                      let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), metadata.isRegularFile == true, metadata.isSymbolicLink != true else { return false }
                let base = messageDirectory.resolvingSymlinksInPath().standardizedFileURL.path()
                return url.resolvingSymlinksInPath().standardizedFileURL.path().hasPrefix(base.hasSuffix("/") ? base : base + "/")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public enum VoiceFormat: String, Codable, Equatable, Sendable {
    case silk
    case unknown
}

public struct VoiceFormatDetector: Sendable {
    public init() {}

    public func detect(_ data: Data) -> VoiceFormat {
        let marker = Data("#!SILK_V3".utf8)
        return data.prefix(32).range(of: marker) == nil ? .unknown : .silk
    }
}

private final class VoiceMediaDatabase {
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

    func voiceData(localID: Int64, serverID: Int64, createTime: Int64, maximumBytes: Int) throws -> Data? {
        let sql = #"SELECT voice_data FROM "VoiceInfo" WHERE local_id = ? AND svr_id = ? AND create_time = ? LIMIT 1"#
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, serverID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, createTime) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        guard sqlite3_column_type(statement, 0) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, count <= maximumBytes else { throw ArchiveError.invalidInput }
        return Data(bytes: bytes, count: count)
    }

    private func requireHandle() -> OpaquePointer {
        guard let handle else { preconditionFailure("Voice media database is closed") }
        return handle
    }
}

private func archiveSQLiteSourceValue(_ value: ArchivedSQLiteValue) -> SQLiteSourceValue {
    switch value {
    case .null: return .null
    case let .integer(value): return .integer(value)
    case let .real(value): return .real(value)
    case let .text(value): return .text(value)
    case let .blob(value):
        let digest = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
        return .blob(SQLiteBlobSourceValue(length: value.count, sha256: digest, data: value))
    }
}

private func archiveSourceMessageRecord(_ message: ArchiveV1SourceMessage) -> SourceMessageRecord {
    SourceMessageRecord(
        identity: SourceMessageIdentity(databaseRelativePath: message.sourceDatabase, tableName: message.sourceTable, rowIdentifier: String(message.sourceSQLiteRowID)),
        values: Dictionary(uniqueKeysWithValues: message.values.map { ($0.key, archiveSQLiteSourceValue($0.value)) })
    )
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

    func blob(named names: [String]) -> Data? {
        guard case let .blob(value)? = value(named: names) else { return nil }
        return value
    }
}
