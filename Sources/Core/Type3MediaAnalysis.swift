import Foundation
#if canImport(Compression)
import Compression
#endif

/// A locally retained identifier candidate. `value` is deliberately not
/// Codable and must never be copied to a report, log, or Git artifact.
public struct CandidateMediaIdentifier: Equatable, Sendable {
    public let sourceColumn: String
    public let offset: Int
    public let representation: CandidateMediaIdentifierRepresentation
    public let length: Int
    public let semanticHint: CandidateMediaIdentifierSemanticHint
    public let valueKind: CandidateMediaIdentifierValueKind
    public let value: String?

    public init(
        sourceColumn: String,
        offset: Int,
        representation: CandidateMediaIdentifierRepresentation,
        length: Int,
        semanticHint: CandidateMediaIdentifierSemanticHint,
        valueKind: CandidateMediaIdentifierValueKind,
        value: String? = nil
    ) {
        self.sourceColumn = sourceColumn
        self.offset = offset
        self.representation = representation
        self.length = length
        self.semanticHint = semanticHint
        self.valueKind = valueKind
        self.value = value
    }
}

public enum CandidateMediaIdentifierRepresentation: String, Codable, Equatable, Sendable {
    case hex32
    case binary16
    case binary20
    case binary32
    case integer64
    case path
    case unknownIdentifier
}

public enum CandidateMediaIdentifierSemanticHint: String, Codable, Equatable, Sendable {
    case hex32Candidate
    case confirmedMD5
    case mediaID
    case fileID
    case aesKey
    case cdnID
    case path
    case filename
    case width
    case height
    case fileSize
    case thumbReference
    case originalReference
    case unknownIdentifier
}

public enum CandidateMediaIdentifierValueKind: String, Codable, Equatable, Sendable {
    case hex32
    case binaryDigest
    case integer64
    case path
    case text
    case unknown
}

public enum PayloadCompression: String, Codable, Equatable, Sendable {
    case none
    case zlib
    case gzip
    case deflate
    case unsupported
}

public enum PayloadStructureKind: String, Codable, Equatable, Sendable {
    case empty
    case text
    case xml
    case json
    case protobufLike
    case binary
    case unknown
}

public struct ProtobufWireFieldObservation: Codable, Equatable, Sendable {
    public let fieldNumber: Int
    public let wireType: Int
    public let valueLength: Int?

    public init(fieldNumber: Int, wireType: Int, valueLength: Int?) {
        self.fieldNumber = fieldNumber
        self.wireType = wireType
        self.valueLength = valueLength
    }
}

/// Safe structural metadata for one selected payload cell. It has no raw
/// payload, digest, path, filename, or identifier value.
public struct Type3PayloadObservation: Codable, Equatable, Sendable {
    public let sourceColumn: String
    public let storageClass: SQLiteSourceStorageClass
    public let byteLength: Int?
    public let compression: PayloadCompression
    public let payloadKind: PayloadStructureKind
    public let fieldNames: [String]
    public let protobufFields: [ProtobufWireFieldObservation]

    public init(
        sourceColumn: String,
        storageClass: SQLiteSourceStorageClass,
        byteLength: Int?,
        compression: PayloadCompression,
        payloadKind: PayloadStructureKind,
        fieldNames: [String] = [],
        protobufFields: [ProtobufWireFieldObservation] = []
    ) {
        self.sourceColumn = sourceColumn
        self.storageClass = storageClass
        self.byteLength = byteLength
        self.compression = compression
        self.payloadKind = payloadKind
        self.fieldNames = fieldNames
        self.protobufFields = protobufFields
    }
}

public struct Type3IdentifierSummary: Codable, Equatable, Sendable {
    public let sourceColumn: String
    public let representation: CandidateMediaIdentifierRepresentation
    public let semanticHint: CandidateMediaIdentifierSemanticHint
    public let count: Int

    public init(
        sourceColumn: String,
        representation: CandidateMediaIdentifierRepresentation,
        semanticHint: CandidateMediaIdentifierSemanticHint,
        count: Int
    ) {
        self.sourceColumn = sourceColumn
        self.representation = representation
        self.semanticHint = semanticHint
        self.count = count
    }
}

public struct Type3PayloadAnalysis: Equatable, Sendable {
    public let sampledRecordCount: Int
    public let payloadObservations: [Type3PayloadObservation]
    /// In-memory-only candidates. Use `identifierSummaries` in reports.
    public let candidateIdentifiers: [CandidateMediaIdentifier]
    public let identifierSummaries: [Type3IdentifierSummary]

    public init(
        sampledRecordCount: Int,
        payloadObservations: [Type3PayloadObservation],
        candidateIdentifiers: [CandidateMediaIdentifier],
        identifierSummaries: [Type3IdentifierSummary]
    ) {
        self.sampledRecordCount = sampledRecordCount
        self.payloadObservations = payloadObservations
        self.candidateIdentifiers = candidateIdentifiers
        self.identifierSummaries = identifierSummaries
    }

    public var hex32Candidates: [String] {
        candidateIdentifiers.compactMap { identifier in
            identifier.representation == .hex32 ? identifier.value : nil
        }
    }
}

/// Bounded, structural analysis of type-3 payload fields. It never emits a
/// payload value; candidate values remain in the caller's local memory only.
public struct Type3PayloadAnalyzer: Sendable {
    private let maximumPayloadBytes = 256 * 1_024
    private let maximumDecodedBytes = 1_024 * 1_024

    public init() {}

    public func analyze(records: [SourceMessageRecord]) -> Type3PayloadAnalysis {
        var observations = [Type3PayloadObservation]()
        var identifiers = [CandidateMediaIdentifier]()
        for record in records {
            for (column, value) in record.values where isPayloadColumn(column) {
                let result = analyze(value: value, sourceColumn: column)
                observations.append(result.observation)
                identifiers.append(contentsOf: result.identifiers)
            }
        }
        let summaries = Dictionary(grouping: identifiers) { identifier in
            "\(identifier.sourceColumn)\u{1F}\(identifier.representation.rawValue)\u{1F}\(identifier.semanticHint.rawValue)"
        }
        .compactMap { _, values -> Type3IdentifierSummary? in
            guard let identifier = values.first else { return nil }
            return Type3IdentifierSummary(
                sourceColumn: identifier.sourceColumn,
                representation: identifier.representation,
                semanticHint: identifier.semanticHint,
                count: values.count
            )
        }
        .sorted {
            ($0.sourceColumn, $0.representation.rawValue, $0.semanticHint.rawValue) <
                ($1.sourceColumn, $1.representation.rawValue, $1.semanticHint.rawValue)
        }
        return Type3PayloadAnalysis(
            sampledRecordCount: records.count,
            payloadObservations: observations.sorted { ($0.sourceColumn, $0.storageClass.rawValue) < ($1.sourceColumn, $1.storageClass.rawValue) },
            candidateIdentifiers: identifiers,
            identifierSummaries: summaries
        )
    }

    private func analyze(
        value: SQLiteSourceValue,
        sourceColumn: String
    ) -> (observation: Type3PayloadObservation, identifiers: [CandidateMediaIdentifier]) {
        let semanticHint = semanticHint(for: sourceColumn)
        switch value {
        case .null:
            return (Type3PayloadObservation(sourceColumn: sourceColumn, storageClass: .null, byteLength: nil, compression: .none, payloadKind: .empty), [])
        case let .integer(integer):
            let identifiers: [CandidateMediaIdentifier]
            switch semanticHint {
            case .width, .height, .fileSize:
                identifiers = [CandidateMediaIdentifier(
                    sourceColumn: sourceColumn,
                    offset: 0,
                    representation: .integer64,
                    length: MemoryLayout<Int64>.size,
                    semanticHint: semanticHint,
                    valueKind: .integer64
                )]
            default:
                identifiers = []
            }
            _ = integer
            return (Type3PayloadObservation(sourceColumn: sourceColumn, storageClass: .integer, byteLength: nil, compression: .none, payloadKind: .unknown), identifiers)
        case .real:
            return (Type3PayloadObservation(sourceColumn: sourceColumn, storageClass: .real, byteLength: nil, compression: .none, payloadKind: .unknown), [])
        case let .text(text):
            let data = Data(text.utf8)
            let inspection = inspectData(data, sourceColumn: sourceColumn, sourceStorageClass: .text, semanticHint: semanticHint)
            let scalarIdentifiers = scalarTextIdentifiers(
                text,
                sourceColumn: sourceColumn,
                semanticHint: semanticHint
            )
            return (
                inspection.observation,
                inspection.identifiers + scalarIdentifiers
            )
        case let .blob(blob):
            guard let data = blob.data, data.count <= maximumPayloadBytes else {
                return (Type3PayloadObservation(sourceColumn: sourceColumn, storageClass: .blob, byteLength: blob.length, compression: .unsupported, payloadKind: .unknown), [])
            }
            return inspectData(data, sourceColumn: sourceColumn, sourceStorageClass: .blob, semanticHint: semanticHint)
        }
    }

    private func inspectData(
        _ sourceData: Data,
        sourceColumn: String,
        sourceStorageClass: SQLiteSourceStorageClass,
        semanticHint: CandidateMediaIdentifierSemanticHint
    ) -> (observation: Type3PayloadObservation, identifiers: [CandidateMediaIdentifier]) {
        let compression = compressionKind(for: sourceData)
        let decoded = decompressed(sourceData, compression: compression) ?? sourceData
        let kind = payloadKind(for: decoded, storageClass: sourceStorageClass)
        var identifiers = hex32Candidates(in: decoded, sourceColumn: sourceColumn, semanticHint: semanticHint)
        let protobufFields = kind == .protobufLike ? ProtobufWireInspector().inspect(decoded, sourceColumn: sourceColumn, identifiers: &identifiers) : []
        let fieldNames = structuralFieldNames(in: decoded, kind: kind)
        return (
            Type3PayloadObservation(
                sourceColumn: sourceColumn,
                storageClass: sourceStorageClass,
                byteLength: sourceData.count,
                compression: compression,
                payloadKind: kind,
                fieldNames: fieldNames,
                protobufFields: protobufFields
            ),
            identifiers
        )
    }

    private func isPayloadColumn(_ column: String) -> Bool {
        let lower = column.lowercased()
        return ["message_content", "compress_content", "packed_info_data"].contains(lower) ||
            ["content", "payload", "data", "blob", "info", "md5", "media_id", "mediaid", "file_id", "fileid", "aes", "cdn", "path", "name", "width", "height", "size", "thumb", "original"].contains(where: lower.contains)
    }

    private func semanticHint(for column: String) -> CandidateMediaIdentifierSemanticHint {
        let lower = column.lowercased()
        let compact = lower.replacingOccurrences(of: "_", with: "")
        if compact == "md5" || compact == "filemd5" { return .confirmedMD5 }
        if lower.contains("media_id") || lower.contains("mediaid") { return .mediaID }
        if lower.contains("file_id") || lower.contains("fileid") { return .fileID }
        if lower.contains("aes") { return .aesKey }
        if lower.contains("cdn") { return .cdnID }
        if lower.contains("thumb") { return .thumbReference }
        if lower.contains("original") { return .originalReference }
        if lower.contains("width") { return .width }
        if lower.contains("height") { return .height }
        if lower.contains("size") { return .fileSize }
        if lower.contains("path") { return .path }
        if lower.contains("name") { return .filename }
        return .hex32Candidate
    }

    private func compressionKind(for data: Data) -> PayloadCompression {
        let bytes = [UInt8](data.prefix(2))
        if bytes.starts(with: [0x1F, 0x8B]) { return .gzip }
        if bytes.count == 2, bytes[0] & 0x0F == 8, (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0 { return .zlib }
        // Raw deflate has no reliable byte signature, so it is never guessed.
        return .none
    }

    private func decompressed(_ data: Data, compression: PayloadCompression) -> Data? {
        guard compression == .zlib || compression == .gzip else { return nil }
        #if canImport(Compression)
        var output = Data(count: maximumDecodedBytes)
        let count = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let sourceAddress = source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let destinationAddress = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationAddress,
                    destination.count,
                    sourceAddress,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard count > 0, count < maximumDecodedBytes else { return nil }
        output.removeSubrange(count..<output.count)
        return output
        #else
        return nil
        #endif
    }

    private func payloadKind(for data: Data, storageClass: SQLiteSourceStorageClass) -> PayloadStructureKind {
        guard !data.isEmpty else { return .empty }
        guard let text = String(data: data.prefix(maximumPayloadBytes), encoding: .utf8) else {
            return ProtobufWireInspector().isLikelyMessage(data) ? .protobufLike : .binary
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { return .xml }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        return storageClass == .text ? .text : (ProtobufWireInspector().isLikelyMessage(data) ? .protobufLike : .binary)
    }

    private func structuralFieldNames(in data: Data, kind: PayloadStructureKind) -> [String] {
        guard kind == .xml || kind == .json,
              let text = String(data: data, encoding: .utf8) else { return [] }
        let inspection = MessagePayloadInspector().inspect(text: text)
        return Array(Set(inspection.elementNames + inspection.attributeNames + inspection.jsonKeys)).sorted()
    }

    private func hex32Candidates(
        in data: Data,
        sourceColumn: String,
        semanticHint: CandidateMediaIdentifierSemanticHint
    ) -> [CandidateMediaIdentifier] {
        let bytes = [UInt8](data)
        guard bytes.count >= 32 else { return [] }
        func isHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        var candidates = [CandidateMediaIdentifier]()
        for start in 0...(bytes.count - 32) {
            let end = start + 32
            guard bytes[start..<end].allSatisfy(isHex),
                  (start == 0 || !isHex(bytes[start - 1])),
                  (end == bytes.count || !isHex(bytes[end])) else { continue }
            let value = String(decoding: bytes[start..<end], as: UTF8.self).lowercased()
            candidates.append(CandidateMediaIdentifier(
                sourceColumn: sourceColumn,
                offset: start,
                representation: .hex32,
                length: 32,
                semanticHint: semanticHint,
                valueKind: .hex32,
                value: value
            ))
        }
        return candidates
    }

    private func scalarTextIdentifiers(
        _ text: String,
        sourceColumn: String,
        semanticHint: CandidateMediaIdentifierSemanticHint
    ) -> [CandidateMediaIdentifier] {
        guard !text.isEmpty,
              text.utf8.count <= maximumPayloadBytes,
              semanticHint != .hex32Candidate,
              semanticHint != .confirmedMD5 else {
            return []
        }
        let representation: CandidateMediaIdentifierRepresentation =
            semanticHint == .path || semanticHint == .filename ? .path : .unknownIdentifier
        let valueKind: CandidateMediaIdentifierValueKind =
            representation == .path ? .path : .text
        return [CandidateMediaIdentifier(
            sourceColumn: sourceColumn,
            offset: 0,
            representation: representation,
            length: text.utf8.count,
            semanticHint: semanticHint,
            valueKind: valueKind,
            value: text
        )]
    }
}

private struct ProtobufWireInspector: Sendable {
    private let maximumDepth = 3

    func isLikelyMessage(_ data: Data) -> Bool {
        var ignored = [CandidateMediaIdentifier]()
        return !inspect(data, sourceColumn: "", identifiers: &ignored).isEmpty
    }

    func inspect(
        _ data: Data,
        sourceColumn: String,
        identifiers: inout [CandidateMediaIdentifier],
        depth: Int = 0
    ) -> [ProtobufWireFieldObservation] {
        guard depth <= maximumDepth, !data.isEmpty else { return [] }
        let bytes = [UInt8](data)
        var index = 0
        var fields = [ProtobufWireFieldObservation]()
        while index < bytes.count {
            guard let tag = readVarint(bytes, index: &index), tag > 0 else { return [] }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            guard fieldNumber > 0 else { return [] }
            switch wireType {
            case 0:
                guard readVarint(bytes, index: &index) != nil else { return [] }
                fields.append(.init(fieldNumber: fieldNumber, wireType: wireType, valueLength: nil))
            case 1:
                guard index + 8 <= bytes.count else { return [] }
                index += 8
                fields.append(.init(fieldNumber: fieldNumber, wireType: wireType, valueLength: 8))
            case 2:
                guard let lengthValue = readVarint(bytes, index: &index),
                      lengthValue <= UInt64(bytes.count - index),
                      lengthValue <= 256 * 1_024 else { return [] }
                let length = Int(lengthValue)
                let start = index
                index += length
                fields.append(.init(fieldNumber: fieldNumber, wireType: wireType, valueLength: length))
                if [16, 20, 32].contains(length) {
                    let representation: CandidateMediaIdentifierRepresentation = length == 16 ? .binary16 : length == 20 ? .binary20 : .binary32
                    identifiers.append(CandidateMediaIdentifier(
                        sourceColumn: sourceColumn,
                        offset: start,
                        representation: representation,
                        length: length,
                        semanticHint: .unknownIdentifier,
                        valueKind: .binaryDigest,
                        value: bytes[start..<index].map { String(format: "%02x", $0) }.joined()
                    ))
                }
                if depth < maximumDepth {
                    _ = inspect(Data(bytes[start..<index]), sourceColumn: sourceColumn, identifiers: &identifiers, depth: depth + 1)
                }
            case 5:
                guard index + 4 <= bytes.count else { return [] }
                index += 4
                fields.append(.init(fieldNumber: fieldNumber, wireType: wireType, valueLength: 4))
            default:
                return []
            }
        }
        return fields
    }

    private func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }
}
