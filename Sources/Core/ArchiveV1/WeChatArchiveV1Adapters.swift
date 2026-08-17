import CryptoKit
import Foundation

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

struct ArchiveV1ImageVariantInput {
    let variant: ArchiveV1MediaVariant
    let status: ArchiveV1MediaStatus
    let sourceFormat: String?
    let decodedFormat: String?
    let rawData: Data?
    let decodedData: Data?
    let width: Int?
    let height: Int?
    let sourceFileBase: String?
}

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
            (key, sqliteSourceValue(value))
        })
        let source = SourceMessageRecord(
            identity: SourceMessageIdentity(databaseRelativePath: message.sourceDatabase, tableName: message.sourceTable, rowIdentifier: message.sourceRowIdentifier),
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

    private func sqliteSourceValue(_ value: ArchivedSQLiteValue) -> SQLiteSourceValue {
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
