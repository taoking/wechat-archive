import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
#if canImport(ImageIO)
import ImageIO
#endif

/// Identifies the deterministic conversation directory component from a
/// message table name. The component stays in memory and is never written to
/// a discovery report.
public struct WeChatConversationTableIdentity: Equatable, Sendable {
    public let chatDirectoryComponent: String

    public init?(tableName: String) {
        guard tableName.hasPrefix("Msg_") else { return nil }
        let component = String(tableName.dropFirst(4)).lowercased()
        guard Self.isHex32(component) else { return nil }
        chatDirectoryComponent = component
    }

    fileprivate static func isHex32(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum MessageResourceFileBaseSource: String, Codable, Equatable, Sendable {
    case messagePackedInfoData
    case messageResourcePackedInfo
    case both
}

public enum MessageResourceFileBaseConfidence: String, Codable, Equatable, Sendable {
    case structured
    case heuristic
}

/// The value is local-only and deliberately not Codable. It is a file-base
/// candidate, not a statement that its bytes have MD5 semantics.
public struct MessageResourceFileBase: Equatable, Sendable {
    public let value: String
    public let source: MessageResourceFileBaseSource
    public let confidence: MessageResourceFileBaseConfidence

    public init(value: String, source: MessageResourceFileBaseSource, confidence: MessageResourceFileBaseConfidence) {
        self.value = value
        self.source = source
        self.confidence = confidence
    }
}

/// Parses the small `packed_info` envelope used by the local resource index.
/// Only a bounded 32-byte hexadecimal file-base candidate is retained.
public struct MessageResourcePackedInfoParser: Sendable {
    private let maximumBytes = 256 * 1_024
    private let marker: [UInt8] = [0x12, 0x22, 0x0A, 0x20]

    public init() {}

    public func parse(_ data: Data) -> MessageResourceFileBase? {
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        let bytes = [UInt8](data)
        if let offset = markerOffset(in: bytes) {
            let start = offset + marker.count
            if let value = hex32(at: start, in: bytes) {
                return MessageResourceFileBase(
                    value: value,
                    source: .messageResourcePackedInfo,
                    confidence: .structured
                )
            }
        }
        for start in 0...max(0, bytes.count - 32) {
            if let value = hex32(at: start, in: bytes) {
                return MessageResourceFileBase(
                    value: value,
                    source: .messageResourcePackedInfo,
                    confidence: .heuristic
                )
            }
        }
        return nil
    }

    private func markerOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= marker.count else { return nil }
        return bytes.indices.dropLast(marker.count - 1).first { offset in
            Array(bytes[offset..<(offset + marker.count)]) == marker
        }
    }

    private func hex32(at start: Int, in bytes: [UInt8]) -> String? {
        guard start >= 0, start + 32 <= bytes.count else { return nil }
        let candidate = bytes[start..<(start + 32)]
        guard candidate.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return String(decoding: candidate, as: UTF8.self).lowercased()
    }
}

/// Local-only attachment locations. The URLs are not Codable and must not be
/// surfaced in a normal report.
public struct WeChatImageAssetSet: Equatable, Sendable {
    public let mainURL: URL?
    public let hdURL: URL?
    public let thumbnailURL: URL?
    public let chatDirectoryFound: Bool
    public let monthDirectoryFound: Bool
    public let usedMonthFallback: Bool

    public init(
        mainURL: URL? = nil,
        hdURL: URL? = nil,
        thumbnailURL: URL? = nil,
        chatDirectoryFound: Bool = false,
        monthDirectoryFound: Bool = false,
        usedMonthFallback: Bool = false
    ) {
        self.mainURL = mainURL
        self.hdURL = hdURL
        self.thumbnailURL = thumbnailURL
        self.chatDirectoryFound = chatDirectoryFound
        self.monthDirectoryFound = monthDirectoryFound
        self.usedMonthFallback = usedMonthFallback
    }
}

/// Checks only deterministic candidate paths below one selected account root.
/// It never scans the complete attachment tree, hashes files, or mutates them.
public struct WeChatImageAttachmentLocator: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func locate(
        accountRoot: URL,
        chatDirectoryComponent: String,
        fileBase: String,
        createTime: Int64
    ) throws -> WeChatImageAssetSet {
        guard WeChatConversationTableIdentity.isHex32(chatDirectoryComponent),
              WeChatConversationTableIdentity.isHex32(fileBase) else {
            throw ArchiveError.invalidInput
        }
        let root = try validatedDirectory(accountRoot)
        let attachRoot = root.appending(path: "msg/attach")
        guard isSafeDirectory(attachRoot), isDescendant(attachRoot, of: root) else {
            return WeChatImageAssetSet()
        }
        let chatDirectory = attachRoot.appending(path: chatDirectoryComponent)
        guard isSafeDirectory(chatDirectory), isDescendant(chatDirectory, of: attachRoot) else {
            return WeChatImageAssetSet()
        }

        let primaryMonths = monthCandidates(for: createTime)
        var inspectedMonths = Set<String>()
        var mainURL: URL?
        var hdURL: URL?
        var thumbnailURL: URL?
        var monthDirectoryFound = false
        var usedMonthFallback = false

        func inspect(monthURL: URL, monthName: String, fallback: Bool) {
            guard !inspectedMonths.contains(monthName) else { return }
            inspectedMonths.insert(monthName)
            let imageDirectory = monthURL.appending(path: "Img")
            guard isSafeDirectory(imageDirectory), isDescendant(imageDirectory, of: chatDirectory) else { return }
            monthDirectoryFound = true
            usedMonthFallback = usedMonthFallback || fallback
            if mainURL == nil { mainURL = safeFile(named: "\(fileBase).dat", below: imageDirectory) }
            if hdURL == nil { hdURL = safeFile(named: "\(fileBase)_h.dat", below: imageDirectory) }
            if thumbnailURL == nil { thumbnailURL = safeFile(named: "\(fileBase)_t.dat", below: imageDirectory) }
        }

        for (index, month) in primaryMonths.enumerated() {
            inspect(monthURL: chatDirectory.appending(path: month), monthName: month, fallback: index != 1)
        }
        if mainURL == nil && hdURL == nil && thumbnailURL == nil {
            for monthURL in try safeMonthDirectories(below: chatDirectory) {
                inspect(monthURL: monthURL, monthName: monthURL.lastPathComponent, fallback: true)
                if mainURL != nil || hdURL != nil || thumbnailURL != nil { break }
            }
        }
        return WeChatImageAssetSet(
            mainURL: mainURL,
            hdURL: hdURL,
            thumbnailURL: thumbnailURL,
            chatDirectoryFound: true,
            monthDirectoryFound: monthDirectoryFound,
            usedMonthFallback: usedMonthFallback
        )
    }

    private func monthCandidates(for timestamp: Int64) -> [String] {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let dates = [
            calendar.date(byAdding: .month, value: -1, to: date),
            date,
            calendar.date(byAdding: .month, value: 1, to: date)
        ].compactMap { $0 }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"
        return Array(NSOrderedSet(array: dates.map(formatter.string))) as? [String] ?? []
    }

    private func safeMonthDirectories(below chatDirectory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: chatDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            isSafeDirectory(url) && isMonthName(url.lastPathComponent) && isDescendant(url, of: chatDirectory)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isMonthName(_ value: String) -> Bool {
        value.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil
    }

    private func safeFile(named name: String, below directory: URL) -> URL? {
        let candidate = directory.appending(path: name).standardizedFileURL
        guard isSafeRegularFile(candidate), isDescendant(candidate, of: directory) else { return nil }
        return candidate
    }

    private func validatedDirectory(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        guard isSafeDirectory(candidate) else { throw ArchiveError.invalidInput }
        return candidate.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path().hasSuffix("/") ? resolvedRoot.path() : resolvedRoot.path() + "/"
        return resolvedURL.path().hasPrefix(rootPath)
    }
}

public enum WeChatImageDATVersion: String, Codable, Equatable, Sendable {
    case v1
    case v2
    case legacy
    case unknown
}

public enum WeChatDecodedImageFormat: String, Codable, Equatable, Sendable {
    case jpeg
    case png
    case gif
    case webp
    case heic
    case wxgf
    case unknown
}

public struct WeChatImageKeyMaterial: Equatable, Sendable {
    /// Kept in memory only. This type deliberately has no Codable conformance.
    public let aesKey: Data
    public let xorKey: UInt8

    public init(aesKey: Data, xorKey: UInt8) {
        self.aesKey = aesKey
        self.xorKey = xorKey
    }
}

public struct WeChatImageDATHeader: Equatable, Sendable {
    public let version: WeChatImageDATVersion
    public let aesSize: Int
    public let xorSize: Int
    public let flag: UInt8
}

public struct WeChatDecodedImage: Equatable, Sendable {
    /// Decoded bytes remain in memory. The decoder never writes an image file.
    public let data: Data
    public let version: WeChatImageDATVersion
    public let format: WeChatDecodedImageFormat
    public let dimensions: MediaImageDimensions?
}

public enum WeChatImageDATError: Error, Equatable, Sendable {
    case inputTooShort
    case unsupportedFormat
    case imageKeyUnavailable
    case invalidKeyMaterial
    case invalidLayout
    case cryptographicFailure
    case invalidPadding
    case unrecognizedDecodedImage
}

/// Clean-room DAT decoder guided by the publicly documented V2 layout. It
/// opens no files itself and never writes decoded bytes to disk.
public struct WeChatImageDatDecoder: Sendable {
    private let v2Magic = Data([0x07, 0x08, 0x56, 0x32, 0x08, 0x07])
    private let v1Magic = Data([0x07, 0x08, 0x56, 0x31, 0x08, 0x07])
    private let headerSize = 15

    public init() {}

    public func version(for header: Data) -> WeChatImageDATVersion {
        guard header.count >= 4 else { return .unknown }
        if header.count >= 6, header.prefix(6) == v2Magic { return .v2 }
        if header.count >= 6, header.prefix(6) == v1Magic { return .v1 }
        return legacyXORKey(for: header) == nil ? .unknown : .legacy
    }

    public func header(from data: Data) throws -> WeChatImageDATHeader {
        guard data.count >= headerSize else { throw WeChatImageDATError.inputTooShort }
        let version = version(for: data)
        guard version == .v1 || version == .v2 else { throw WeChatImageDATError.unsupportedFormat }
        let aesSize = Int(UInt32(littleEndianBytes: data[6..<10]))
        let xorSize = Int(UInt32(littleEndianBytes: data[10..<14]))
        return WeChatImageDATHeader(version: version, aesSize: aesSize, xorSize: xorSize, flag: data[14])
    }

    public func decode(_ data: Data, keyMaterial: WeChatImageKeyMaterial?) throws -> WeChatDecodedImage {
        switch version(for: data) {
        case .v2:
            guard let keyMaterial else { throw WeChatImageDATError.imageKeyUnavailable }
            return try decodeV2(data, header: try header(from: data), keyMaterial: keyMaterial)
        case .v1:
            let key = WeChatImageKeyMaterial(aesKey: Data("cfcd208495d565ef".utf8), xorKey: keyMaterial?.xorKey ?? 0x88)
            return try decodeV2(data, header: try header(from: data), keyMaterial: key)
        case .legacy:
            return try decodeLegacyXOR(data)
        case .unknown:
            throw WeChatImageDATError.inputTooShort
        }
    }

    private func decodeV2(_ data: Data, header: WeChatImageDATHeader, keyMaterial: WeChatImageKeyMaterial) throws -> WeChatDecodedImage {
        guard keyMaterial.aesKey.count == 16 else { throw WeChatImageDATError.invalidKeyMaterial }
        let paddedAESSize = header.aesSize + (16 - (header.aesSize % 16))
        let aesEnd = try checkedAdd(headerSize, paddedAESSize)
        let rawEnd = data.count - header.xorSize
        guard rawEnd >= headerSize, aesEnd <= rawEnd else { throw WeChatImageDATError.invalidLayout }
        let decryptedAES = try decryptECBPKCS7(Data(data[headerSize..<aesEnd]), key: keyMaterial.aesKey)
        guard decryptedAES.count == header.aesSize else { throw WeChatImageDATError.invalidPadding }
        let raw = data[aesEnd..<rawEnd]
        let xorTail = data[rawEnd..<data.count].map { $0 ^ keyMaterial.xorKey }
        let output = decryptedAES + Data(raw) + Data(xorTail)
        let format = detectFormat(output)
        guard format != .unknown else { throw WeChatImageDATError.unrecognizedDecodedImage }
        return WeChatDecodedImage(data: output, version: header.version, format: format, dimensions: dimensions(of: output))
    }

    private func decodeLegacyXOR(_ data: Data) throws -> WeChatDecodedImage {
        guard !data.isEmpty else { throw WeChatImageDATError.inputTooShort }
        guard let key = legacyXORKey(for: data) else {
            throw WeChatImageDATError.unsupportedFormat
        }
        let output = Data(data.map { $0 ^ key })
        let format = detectFormat(output)
        guard format != .unknown else { throw WeChatImageDATError.unrecognizedDecodedImage }
        return WeChatDecodedImage(data: output, version: .legacy, format: format, dimensions: dimensions(of: output))
    }

    private func legacyXORKey(for data: Data) -> UInt8? {
        let signatures: [[UInt8]] = [
            [0xFF, 0xD8, 0xFF], [0x89, 0x50, 0x4E, 0x47], [0x47, 0x49, 0x46], [0x52, 0x49, 0x46, 0x46]
        ]
        return signatures.compactMap { signature -> UInt8? in
            guard data.count >= signature.count else { return nil }
            let candidate = data[0] ^ signature[0]
            return zip(data.prefix(signature.count), signature).allSatisfy { $0.0 ^ candidate == $0.1 } ? candidate : nil
        }.first
    }

    private func decryptECBPKCS7(_ cipher: Data, key: Data) throws -> Data {
        guard !cipher.isEmpty, cipher.count.isMultiple(of: 16) else { throw WeChatImageDATError.invalidLayout }
        var output = [UInt8](repeating: 0, count: cipher.count)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            cipher.withUnsafeBytes { cipherBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    cipherBytes.baseAddress,
                    cipher.count,
                    &output,
                    output.count,
                    &moved
                )
            }
        }
        guard status == kCCSuccess, moved == output.count else { throw WeChatImageDATError.cryptographicFailure }
        guard let padding = output.last.map(Int.init), padding > 0, padding <= 16, padding <= output.count,
              output.suffix(padding).allSatisfy({ Int($0) == padding }) else {
            throw WeChatImageDATError.invalidPadding
        }
        return Data(output.dropLast(padding))
    }

    private func checkedAdd(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw WeChatImageDATError.invalidLayout }
        return value
    }

    private func detectFormat(_ data: Data) -> WeChatDecodedImageFormat {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if data.starts(with: Data("GIF".utf8)) { return .gif }
        if data.count >= 12, data.starts(with: Data("RIFF".utf8)), data[8..<12] == Data("WEBP".utf8) { return .webp }
        if data.starts(with: Data("wxgf".utf8)) { return .wxgf }
        if data.count >= 12,
           data[4..<8] == Data("ftyp".utf8),
           String(data: data[8..<12], encoding: .ascii)?.lowercased().hasPrefix("hei") == true {
            return .heic
        }
        return .unknown
    }

    private func dimensions(of data: Data) -> MediaImageDimensions? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = values[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return MediaImageDimensions(width: width.intValue, height: height.intValue)
        #else
        return nil
        #endif
    }
}

public enum WeChatImageResourceMatch: String, Codable, Equatable, Sendable {
    case exact
    case localIDFallback
    case notFound
}

public enum WeChatImageResolutionDiagnostic: String, Codable, Equatable, Sendable {
    case resourceDatabaseMissing
    case resourceSchemaUnsupported
    case conversationTableUnsupported
    case conversationIdentityNotFound
    case messageResourceNotFound
    case packedInfoMissing
    case fileBaseNotFound
    case chatDirectoryMissing
    case monthDirectoryMissing
    case datFileMissing
    case datFormatUnknown
    case imageKeyUnavailable
    case imageKeyRejected
    case datDecodeFailed
    case decodedImageUnknown
    case decodedImageVerified
}

/// Resolution evidence for one message. It intentionally has no Codable
/// conformance, ensuring message identifiers and local URLs cannot enter a
/// report accidentally.
public struct WeChatImageMessageResolution: Equatable, Sendable {
    public let resourceDatabaseFound: Bool
    public let resourceMatch: WeChatImageResourceMatch
    public let resourceDetailsFound: Bool
    public let fileBase: MessageResourceFileBase?
    public let assets: WeChatImageAssetSet
    public let datVersion: WeChatImageDATVersion
    public let diagnostics: [WeChatImageResolutionDiagnostic]
}

/// Resolves one already-selected Type 3 message through `message_resource.db`
/// and bounded deterministic attachment paths. No broad attachment scan is
/// performed here.
public struct WeChatImageMessageResolver: Sendable {
    public init() {}

    public func resolve(
        message: SourceMessageRecord,
        candidate: MessageTableCandidate,
        exportRoot: URL,
        accountRoot: URL,
        calendar: Calendar = .current
    ) throws -> WeChatImageMessageResolution {
        guard let conversation = WeChatConversationTableIdentity(tableName: candidate.tableName) else {
            return unresolved(.conversationTableUnsupported)
        }
        guard let messageFields = ImageMessageFields(record: message, candidate: candidate) else {
            return unresolved(.messageResourceNotFound)
        }
        guard let resourceURL = try resourceDatabaseURL(below: exportRoot) else {
            return unresolved(.resourceDatabaseMissing)
        }
        let database = try MessageResourceDatabase(url: resourceURL)
        guard database.isSupportedSchema else { return unresolved(.resourceSchemaUnsupported) }
        guard let chatID = try database.chatID(matchingConversationDigest: conversation.chatDirectoryComponent) else {
            return unresolved(.conversationIdentityNotFound)
        }
        guard let resource = try database.resource(
            chatID: chatID,
            localID: messageFields.localID,
            serverID: messageFields.serverID,
            localType: messageFields.localType,
            createTime: messageFields.createTime
        ) else {
            return unresolved(.messageResourceNotFound)
        }
        let parser = MessageResourcePackedInfoParser()
        let resourceBase = resource.packedInfo.flatMap(parser.parse)
        let messageBase = messageFields.packedInfo.flatMap(parser.parse)
        guard let fileBase = selectFileBase(message: messageBase, resource: resourceBase) else {
            var diagnostics: [WeChatImageResolutionDiagnostic] = []
            if resource.packedInfo == nil && messageFields.packedInfo == nil { diagnostics.append(.packedInfoMissing) }
            diagnostics.append(.fileBaseNotFound)
            return WeChatImageMessageResolution(
                resourceDatabaseFound: true,
                resourceMatch: resource.match,
                resourceDetailsFound: try database.hasDetails(messageID: resource.messageID),
                fileBase: nil,
                assets: WeChatImageAssetSet(),
                datVersion: .unknown,
                diagnostics: diagnostics
            )
        }
        let assets = try WeChatImageAttachmentLocator(calendar: calendar).locate(
            accountRoot: accountRoot,
            chatDirectoryComponent: conversation.chatDirectoryComponent,
            fileBase: fileBase.value,
            createTime: messageFields.createTime
        )
        var diagnostics = [WeChatImageResolutionDiagnostic]()
        if !assets.chatDirectoryFound { diagnostics.append(.chatDirectoryMissing) }
        if assets.chatDirectoryFound && !assets.monthDirectoryFound { diagnostics.append(.monthDirectoryMissing) }
        if assets.mainURL == nil && assets.hdURL == nil && assets.thumbnailURL == nil { diagnostics.append(.datFileMissing) }
        let version = try assets.preferredURL.map { try datVersion(at: $0) } ?? .unknown
        if assets.preferredURL != nil && version == .unknown { diagnostics.append(.datFormatUnknown) }
        return WeChatImageMessageResolution(
            resourceDatabaseFound: true,
            resourceMatch: resource.match,
            resourceDetailsFound: try database.hasDetails(messageID: resource.messageID),
            fileBase: fileBase,
            assets: assets,
            datVersion: version,
            diagnostics: diagnostics
        )
    }

    private func selectFileBase(
        message: MessageResourceFileBase?,
        resource: MessageResourceFileBase?
    ) -> MessageResourceFileBase? {
        switch (message, resource) {
        case let (.some(message), .some(resource)) where message.value == resource.value:
            return MessageResourceFileBase(
                value: resource.value,
                source: .both,
                confidence: message.confidence == .structured || resource.confidence == .structured ? .structured : .heuristic
            )
        case let (_, .some(resource)):
            return resource
        case let (.some(message), nil):
            return MessageResourceFileBase(value: message.value, source: .messagePackedInfoData, confidence: message.confidence)
        case (nil, nil):
            return nil
        }
    }

    private func datVersion(at url: URL) throws -> WeChatImageDATVersion {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return WeChatImageDatDecoder().version(for: try handle.read(upToCount: 64) ?? Data())
    }

    private func unresolved(_ diagnostic: WeChatImageResolutionDiagnostic) -> WeChatImageMessageResolution {
        WeChatImageMessageResolution(
            resourceDatabaseFound: diagnostic != .resourceDatabaseMissing,
            resourceMatch: .notFound,
            resourceDetailsFound: false,
            fileBase: nil,
            assets: WeChatImageAssetSet(),
            datVersion: .unknown,
            diagnostics: [diagnostic]
        )
    }

    private func resourceDatabaseURL(below exportRoot: URL) throws -> URL? {
        let root = exportRoot.standardizedFileURL
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        for relativePath in ["message/message_resource.db", "message_resource.db"] {
            if let url = safeDatabaseURL(relativePath: relativePath, below: root) { return url }
        }
        let reportURL = root.appending(path: "SchemaReports/schema-summary.json")
        guard let reportValues = try? reportURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              reportValues.isRegularFile == true,
              reportValues.isSymbolicLink != true,
              let report = try? JSONDecoder().decode(SQLiteSchemaDiscoveryReport.self, from: Data(contentsOf: reportURL, options: .mappedIfSafe)) else {
            return nil
        }
        return report.databases
            .map(\.relativePath)
            .filter { $0.lowercased().contains("message_resource") }
            .compactMap { safeDatabaseURL(relativePath: $0, below: root) }
            .first
    }

    private func safeDatabaseURL(relativePath: String, below root: URL) -> URL? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let requested = components.reduce(root) { $0.appending(path: $1) }.standardizedFileURL
        guard let values = try? requested.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path().hasSuffix("/") ? resolvedRoot.path() : resolvedRoot.path() + "/"
        guard resolved.path().hasPrefix(rootPath), resolved.pathExtension.lowercased() == "db" else { return nil }
        return resolved
    }
}

extension WeChatImageAssetSet {
    var preferredURL: URL? { thumbnailURL ?? mainURL ?? hdURL }
}

private struct ImageMessageFields: Sendable {
    let localID: Int64
    let serverID: Int64?
    let localType: Int64
    let createTime: Int64
    let packedInfo: Data?

    init?(record: SourceMessageRecord, candidate: MessageTableCandidate) {
        func first(_ names: [String]) -> String? {
            candidate.columns.first { names.contains($0.lowercased()) }
        }
        guard let localColumn = first(["local_id", "message_id", "msg_id"]),
              let typeColumn = first(["local_type", "msg_type", "message_type", "type"]),
              let timeColumn = first(["create_time", "timestamp", "createtime"]),
              let localID = record.values[localColumn]?.integerValue,
              let localType = record.values[typeColumn]?.integerValue,
              let createTime = record.values[timeColumn]?.integerValue else { return nil }
        let serverColumn = first(["server_id", "msgsvrid", "server_msg_id"])
        let packedColumn = candidate.columns.first { $0.lowercased() == "packed_info_data" } ?? candidate.columns.first { $0.lowercased().contains("packed") }
        let packedInfo: Data?
        if case let .blob(blob)? = packedColumn.flatMap({ record.values[$0] }) {
            packedInfo = blob.data
        } else {
            packedInfo = nil
        }
        self.localID = localID
        self.serverID = serverColumn.flatMap { record.values[$0]?.integerValue }
        self.localType = localType
        self.createTime = createTime
        self.packedInfo = packedInfo
    }
}

private struct ResourceRecord: Sendable {
    let messageID: Int64
    let packedInfo: Data?
    let match: WeChatImageResourceMatch
}

private final class MessageResourceDatabase {
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

    var isSupportedSchema: Bool {
        guard let tables = try? tableNames() else { return false }
        return Set(["ChatName2Id", "MessageResourceInfo"]).isSubset(of: Set(tables))
    }

    func chatID(matchingConversationDigest digest: String) throws -> Int64? {
        let sql = "SELECT rowid, user_name FROM \"ChatName2Id\" LIMIT 10000"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ArchiveError.databaseFailure }
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let userName = text(statement, index: 1) else { throw ArchiveError.databaseFailure }
            if md5Hex(userName) == digest { return sqlite3_column_int64(statement, 0) }
        }
    }

    func resource(chatID: Int64, localID: Int64, serverID: Int64?, localType: Int64, createTime: Int64) throws -> ResourceRecord? {
        let low32 = localType & 0xffff_ffff
        if let serverID,
           let exact = try queryResource(
               predicate: "chat_id = ? AND message_local_id = ? AND message_svr_id = ? AND (message_local_type = ? OR (message_local_type & 4294967295) = ?) AND message_create_time = ?",
               bindings: [chatID, localID, serverID, localType, low32, createTime],
               match: .exact
           ) {
            return exact
        }
        if let exact = try queryResource(
            predicate: "chat_id = ? AND message_local_id = ? AND (message_local_type = ? OR (message_local_type & 4294967295) = ?) AND message_create_time = ?",
            bindings: [chatID, localID, localType, low32, createTime],
            match: .exact
        ) {
            return exact
        }
        return try queryResource(
            predicate: "chat_id = ? AND message_local_id = ? AND (message_local_type = ? OR (message_local_type & 4294967295) = ?)",
            bindings: [chatID, localID, localType, low32],
            match: .localIDFallback
        )
    }

    func hasDetails(messageID: Int64) throws -> Bool {
        guard try tableNames().contains("MessageResourceDetail") else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), "SELECT 1 FROM \"MessageResourceDetail\" WHERE message_id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK, let statement else { throw ArchiveError.databaseFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, messageID) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return status == SQLITE_ROW
    }

    private func queryResource(predicate: String, bindings: [Int64], match: WeChatImageResourceMatch) throws -> ResourceRecord? {
        let sql = "SELECT message_id, packed_info FROM \"MessageResourceInfo\" WHERE \(predicate) ORDER BY message_create_time DESC, rowid DESC LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ArchiveError.databaseFailure }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_int64(statement, Int32(index + 1), value) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ArchiveError.databaseFailure }
        let packedInfo: Data?
        if sqlite3_column_type(statement, 1) == SQLITE_BLOB,
           let bytes = sqlite3_column_blob(statement, 1) {
            let count = Int(sqlite3_column_bytes(statement, 1))
            packedInfo = count <= 256 * 1_024 ? Data(bytes: bytes, count: count) : nil
        } else {
            packedInfo = nil
        }
        return ResourceRecord(messageID: sqlite3_column_int64(statement, 0), packedInfo: packedInfo, match: match)
    }

    private func tableNames() throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK, let statement else { throw ArchiveError.databaseFailure }
        defer { sqlite3_finalize(statement) }
        var names = [String]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return names }
            guard status == SQLITE_ROW, let name = text(statement, index: 0) else { throw ArchiveError.databaseFailure }
            names.append(name)
        }
    }

    private func requireHandle() -> OpaquePointer {
        precondition(handle != nil)
        return handle!
    }

    private func text(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension UInt32 {
    init(littleEndianBytes bytes: Data.SubSequence) {
        precondition(bytes.count == 4)
        self = bytes.enumerated().reduce(0) { value, item in
            value | UInt32(item.element) << UInt32(item.offset * 8)
        }
    }
}

/// Supplies only key candidates derived from locally discovered kvcomm metadata.
/// Implementations must never persist or log key material.
public protocol WeChatImageKeyProvider: Sendable {
    func keyCandidates(accountRoot: URL) throws -> [WeChatImageKeyMaterial]
}

/// Clean-room macOS derivation for image DAT V2 candidates. It only uses
/// codes present in `key_<number>_*.statistic` filenames and account-directory
/// identifiers; it never searches an arbitrary key space.
public struct WeChatKVCommImageKeyProvider: WeChatImageKeyProvider, Sendable {
    public init() {}

    public func keyCandidates(accountRoot: URL) throws -> [WeChatImageKeyMaterial] {
        let root = try validatedAccountRoot(accountRoot)
        let accountIDs = accountIdentifierCandidates(from: root.lastPathComponent)
        guard !accountIDs.isEmpty else { return [] }
        let directCodes = try kvcommDirectories(for: root).flatMap { try keyCodes(in: $0) }
        let codes = directCodes.isEmpty ? try boundedMetadataCodes(below: root) : directCodes
        guard !codes.isEmpty else { return [] }

        var result = [WeChatImageKeyMaterial]()
        for code in Set(codes).sorted() {
            for accountID in accountIDs {
                let candidate = derive(code: code, accountIdentifier: accountID)
                if !result.contains(candidate) { result.append(candidate) }
            }
        }
        return result
    }

    /// Pure derivation, exposed for deterministic synthetic fixture tests.
    public func derive(code: UInt32, accountIdentifier: String) -> WeChatImageKeyMaterial {
        let digest = Insecure.MD5.hash(data: Data("\(code)\(accountIdentifier)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return WeChatImageKeyMaterial(
            aesKey: Data(digest.prefix(16).utf8),
            xorKey: UInt8(truncatingIfNeeded: code)
        )
    }

    private func validatedAccountRoot(_ url: URL) throws -> URL {
        let requested = url.standardizedFileURL
        let values = try requested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        return requested.resolvingSymlinksInPath().standardizedFileURL
    }

    private func accountIdentifierCandidates(from raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        var candidates = [raw]
        let pieces = raw.split(separator: "_", omittingEmptySubsequences: false)
        if pieces.count >= 3,
           let last = pieces.last,
           last.count == 4,
           last.first == "c",
           last.dropFirst().allSatisfy({ $0.isHexDigit }) {
            let normalized = pieces.dropLast().joined(separator: "_")
            if !normalized.isEmpty { candidates.append(normalized) }
        }
        return candidates
    }

    private func kvcommDirectories(for accountRoot: URL) throws -> [URL] {
        guard let documentsRoot = documentsRoot(for: accountRoot) else { return [] }
        let relativeCandidates = [
            "app_data/net/kvcomm",
            "xwechat_files/app_data/net/kvcomm",
            "xwechat_files/app_data/kvcomm"
        ]
        var found = [URL]()
        for relative in relativeCandidates {
            let url = relative.split(separator: "/").reduce(documentsRoot) { $0.appending(path: String($1)) }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            if !found.contains(resolved) { found.append(resolved) }
        }
        return found
    }

    /// Some macOS installs put kvcomm files below a global configuration
    /// directory. This bounded metadata-only fallback deliberately prunes all
    /// account media/database trees and reads filenames, never file contents.
    private func boundedMetadataCodes(below accountRoot: URL) throws -> [UInt32] {
        guard let documentsRoot = documentsRoot(for: accountRoot) else { return [] }
        let protectedTreeNames: Set<String> = ["msg", "resource", "cache", "temp", "db_storage", "attach", "media"]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: documentsRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var codes = [UInt32]()
        var inspectedEntries = 0
        while inspectedEntries < 10_000, let url = enumerator.nextObject() as? URL {
            inspectedEntries += 1
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if protectedTreeNames.contains(url.lastPathComponent.lowercased()) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let code = keyCode(from: url.lastPathComponent) else { continue }
            if !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    private func documentsRoot(for accountRoot: URL) -> URL? {
        var current = accountRoot
        for _ in 0..<8 {
            if current.lastPathComponent == "Documents" { return current }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private func keyCodes(in directory: URL) throws -> [UInt32] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> UInt32? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return keyCode(from: url.lastPathComponent)
        }
    }

    private func keyCode(from filename: String) -> UInt32? {
        guard filename.hasPrefix("key_"), filename.hasSuffix(".statistic") else { return nil }
        let body = filename.dropFirst(4).dropLast(".statistic".count)
        guard let separator = body.firstIndex(of: "_"), separator != body.startIndex else { return nil }
        return UInt32(body[..<separator])
    }
}
