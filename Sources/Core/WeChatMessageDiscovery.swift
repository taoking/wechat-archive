import CryptoKit
import Foundation
import SQLite3

public enum SQLiteSourceStorageClass: String, Codable, Equatable, Sendable {
    case null
    case integer
    case real
    case text
    case blob
}

/// BLOB data stays local to the in-memory discovery sample. Its digest and
/// length are available even when retaining a full value would be excessive.
public struct SQLiteBlobSourceValue: Equatable, Sendable {
    public let length: Int
    public let sha256: String
    public let data: Data?

    public init(length: Int, sha256: String, data: Data?) {
        self.length = length
        self.sha256 = sha256
        self.data = data
    }
}

/// A lossless-in-kind value from a limited, local source sample. This type is
/// intentionally not Codable: raw records must never be serialized to a
/// normal report or Git artifact.
public enum SQLiteSourceValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(SQLiteBlobSourceValue)

    public var storageClass: SQLiteSourceStorageClass {
        switch self {
        case .null: .null
        case .integer: .integer
        case .real: .real
        case .text: .text
        case .blob: .blob
        }
    }

    public var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    public var textValue: String? {
        guard case let .text(value) = self else { return nil }
        return value
    }
}

public struct SourceMessageIdentity: Hashable, Equatable, Sendable, Codable {
    public let databaseRelativePath: String
    public let tableName: String
    public let rowIdentifier: String

    public init(databaseRelativePath: String, tableName: String, rowIdentifier: String) {
        self.databaseRelativePath = databaseRelativePath
        self.tableName = tableName
        self.rowIdentifier = rowIdentifier
    }
}

public struct SourceMessageRecord: Equatable, Sendable {
    public let identity: SourceMessageIdentity
    /// All selected source columns, including unknown ones. Values remain in
    /// memory only and are never written by the report writer.
    public let values: [String: SQLiteSourceValue]

    public init(identity: SourceMessageIdentity, values: [String: SQLiteSourceValue]) {
        self.identity = identity
        self.values = values
    }
}

public struct MessageTableCandidate: Hashable, Equatable, Sendable, Identifiable {
    public var id: String { "\(databaseRelativePath)::\(tableName)" }
    public let databaseRelativePath: String
    public let tableName: String
    public let rowCount: Int64?
    public let score: Int
    public let columns: [String]

    public init(
        databaseRelativePath: String,
        tableName: String,
        rowCount: Int64?,
        score: Int,
        columns: [String]
    ) {
        self.databaseRelativePath = databaseRelativePath
        self.tableName = tableName
        self.rowCount = rowCount
        self.score = score
        self.columns = columns
    }
}

/// Converts the Phase 2 structural report into selectable message-table
/// candidates without opening source database rows.
public struct WeChatMessageTableDiscovery: Sendable {
    public init() {}

    public func candidates(from report: SQLiteSchemaDiscoveryReport) -> [MessageTableCandidate] {
        report.candidates(for: .message).compactMap { sourceCandidate in
            guard let database = report.databases.first(where: { $0.relativePath == sourceCandidate.databaseRelativePath }),
                  let table = database.tables.first(where: { $0.name == sourceCandidate.tableName }),
                  !table.isVirtual,
                  !table.isFTSShadowTable else {
                return nil
            }
            return MessageTableCandidate(
                databaseRelativePath: database.relativePath,
                tableName: table.name,
                rowCount: table.rowCount,
                score: sourceCandidate.score,
                columns: table.columns.map(\.name)
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.rowCount != $1.rowCount { return ($0.rowCount ?? 0) > ($1.rowCount ?? 0) }
            return ($0.databaseRelativePath, $0.tableName) < ($1.databaseRelativePath, $1.tableName)
        }
    }
}

public enum TimestampUnit: String, Codable, Equatable, Sendable {
    case seconds
    case milliseconds
    case unknown
}

public struct TimestampInference: Codable, Equatable, Sendable {
    public let unit: TimestampUnit
    public let confidence: Double
    public let validSampleCount: Int
    public let sampleCount: Int

    public init(unit: TimestampUnit, confidence: Double, validSampleCount: Int, sampleCount: Int) {
        self.unit = unit
        self.confidence = confidence
        self.validSampleCount = validSampleCount
        self.sampleCount = sampleCount
    }

    public func date(for value: Int64) -> Date? {
        switch unit {
        case .seconds: Date(timeIntervalSince1970: TimeInterval(value))
        case .milliseconds: Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
        case .unknown: nil
        }
    }
}

public struct MessageFieldMapping: Codable, Equatable, Sendable {
    public let messageIDColumn: String?
    public let serverMessageIDColumn: String?
    public let timestampColumn: String?
    public let rawTypeColumn: String?
    public let senderColumn: String?
    public let conversationColumn: String?
    public let contentColumn: String?
    public let payloadColumn: String?

    public init(
        messageIDColumn: String?,
        serverMessageIDColumn: String?,
        timestampColumn: String?,
        rawTypeColumn: String?,
        senderColumn: String?,
        conversationColumn: String?,
        contentColumn: String?,
        payloadColumn: String?
    ) {
        self.messageIDColumn = messageIDColumn
        self.serverMessageIDColumn = serverMessageIDColumn
        self.timestampColumn = timestampColumn
        self.rawTypeColumn = rawTypeColumn
        self.senderColumn = senderColumn
        self.conversationColumn = conversationColumn
        self.contentColumn = contentColumn
        self.payloadColumn = payloadColumn
    }
}

public struct MessageTypeObservation: Codable, Equatable, Sendable {
    public let rawType: Int64
    public let count: Int

    public init(rawType: Int64, count: Int) {
        self.rawType = rawType
        self.count = count
    }
}

public enum MessagePayloadKind: String, Codable, Equatable, Sendable {
    case empty
    case text
    case xml
    case json
    case blob
    case unknown
}

public enum MessageMediaTypeHint: String, Codable, Equatable, Sendable {
    case image
    case video
    case voice
    case file
    case unknown
}

/// Structural payload observations only. Values are retained solely for
/// explicitly allowed media identifiers; arbitrary XML attributes and JSON
/// values are deliberately excluded.
public struct MessagePayloadInspection: Codable, Equatable, Sendable {
    public let kind: MessagePayloadKind
    public let elementNames: [String]
    public let attributeNames: [String]
    public let jsonKeys: [String]
    public let metadataFieldNames: [String]
    public let mediaTypeHint: MessageMediaTypeHint?
    public let md5: String?
    public let mediaID: String?
    public let relativePathHint: String?
    public let blobLength: Int?
    public let blobSHA256: String?

    public init(
        kind: MessagePayloadKind,
        elementNames: [String] = [],
        attributeNames: [String] = [],
        jsonKeys: [String] = [],
        metadataFieldNames: [String] = [],
        mediaTypeHint: MessageMediaTypeHint? = nil,
        md5: String? = nil,
        mediaID: String? = nil,
        relativePathHint: String? = nil,
        blobLength: Int? = nil,
        blobSHA256: String? = nil
    ) {
        self.kind = kind
        self.elementNames = elementNames
        self.attributeNames = attributeNames
        self.jsonKeys = jsonKeys
        self.metadataFieldNames = metadataFieldNames
        self.mediaTypeHint = mediaTypeHint
        self.md5 = md5
        self.mediaID = mediaID
        self.relativePathHint = relativePathHint
        self.blobLength = blobLength
        self.blobSHA256 = blobSHA256
    }
}

public struct MediaReference: Equatable, Sendable {
    public let sourceMessageIdentity: SourceMessageIdentity
    public let mediaTypeHint: MessageMediaTypeHint?
    public let md5: String?
    public let mediaID: String?
    public let relativePathHint: String?
    /// Structural keys only; never contains key material or raw payload text.
    public let metadataFieldNames: [String]

    public init(
        sourceMessageIdentity: SourceMessageIdentity,
        mediaTypeHint: MessageMediaTypeHint?,
        md5: String?,
        mediaID: String?,
        relativePathHint: String?,
        metadataFieldNames: [String]
    ) {
        self.sourceMessageIdentity = sourceMessageIdentity
        self.mediaTypeHint = mediaTypeHint
        self.md5 = md5
        self.mediaID = mediaID
        self.relativePathHint = relativePathHint
        self.metadataFieldNames = metadataFieldNames
    }
}

public struct MessageSampleAnalysis: Equatable, Sendable {
    public let candidate: MessageTableCandidate
    public let records: [SourceMessageRecord]
    public let fieldMapping: MessageFieldMapping
    public let timestampInference: TimestampInference?
    public let typeObservations: [MessageTypeObservation]
    public let textCandidates: [SourceMessageIdentity]
    public let payloadInspections: [SourceMessageIdentity: MessagePayloadInspection]
    public let mediaReferences: [MediaReference]

    public init(
        candidate: MessageTableCandidate,
        records: [SourceMessageRecord],
        fieldMapping: MessageFieldMapping,
        timestampInference: TimestampInference?,
        typeObservations: [MessageTypeObservation],
        textCandidates: [SourceMessageIdentity],
        payloadInspections: [SourceMessageIdentity: MessagePayloadInspection],
        mediaReferences: [MediaReference]
    ) {
        self.candidate = candidate
        self.records = records
        self.fieldMapping = fieldMapping
        self.timestampInference = timestampInference
        self.typeObservations = typeObservations
        self.textCandidates = textCandidates
        self.payloadInspections = payloadInspections
        self.mediaReferences = mediaReferences
    }
}

/// Reads at most 500 source rows from one user-selected plain SQLite export.
/// It has no write path and all source values remain in memory.
public struct WeChatMessageDiscovery: Sendable {
    public init() {}

    public func inspect(
        exportRoot: URL,
        candidate: MessageTableCandidate,
        sampleLimit: Int = 100,
        now: Date = Date()
    ) throws -> MessageSampleAnalysis {
        let records = try WeChatMessageSampleReader().read(
            exportRoot: exportRoot,
            candidate: candidate,
            sampleLimit: sampleLimit
        )
        return WeChatMessageAnalyzer().analyze(records: records, candidate: candidate, now: now)
    }
}

public struct WeChatMessageSampleReader: Sendable {
    public init() {}

    public func read(
        exportRoot: URL,
        candidate: MessageTableCandidate,
        sampleLimit: Int = 100
    ) throws -> [SourceMessageRecord] {
        let limit = min(max(sampleLimit, 1), 500)
        let databaseURL = try sourceDatabaseURL(exportRoot: exportRoot, relativePath: candidate.databaseRelativePath)
        let database = try SQLiteMessageSampleDatabase(url: databaseURL)
        return try database.readRows(candidate: candidate, limit: limit)
    }

    private func sourceDatabaseURL(exportRoot: URL, relativePath: String) throws -> URL {
        let root = exportRoot.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ArchiveError.invalidInput
        }
        let destination = components.reduce(root) { partial, component in partial.appending(path: String(component)) }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path().hasSuffix("/") ? resolvedRoot.path() : resolvedRoot.path() + "/"
        guard resolvedDestination.path().hasPrefix(rootPath), resolvedDestination.pathExtension.lowercased() == "db" else {
            throw ArchiveError.invalidInput
        }
        let values = try resolvedDestination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        return resolvedDestination
    }
}

public struct WeChatMessageAnalyzer: Sendable {
    public init() {}

    public func analyze(records: [SourceMessageRecord], candidate: MessageTableCandidate, now: Date = Date()) -> MessageSampleAnalysis {
        let mapping = fieldMapping(for: candidate.columns)
        let timestampValues = mapping.timestampColumn.map { column in
            records.compactMap { $0.values[column]?.integerValue }
        } ?? []
        let timestampInference = TimestampDetector().infer(values: timestampValues, now: now)
        let typeObservations = messageTypeObservations(records: records, column: mapping.rawTypeColumn)
        var inspections = [SourceMessageIdentity: MessagePayloadInspection]()
        var textCandidates = [SourceMessageIdentity]()
        var mediaReferences = [MediaReference]()
        let inspector = MessagePayloadInspector()

        for record in records {
            var inspection: MessagePayloadInspection?
            for column in inspectionColumns(mapping: mapping, candidateColumns: candidate.columns) {
                guard let value = record.values[column] else { continue }
                let candidateInspection = inspector.inspect(value: value)
                if inspection == nil || inspectionScore(candidateInspection) > inspectionScore(inspection!) {
                    inspection = candidateInspection
                }
            }
            guard let inspection else { continue }
            inspections[record.identity] = inspection
            if inspection.kind == .text { textCandidates.append(record.identity) }
            if inspection.mediaTypeHint != nil || inspection.md5 != nil || inspection.mediaID != nil || inspection.relativePathHint != nil {
                mediaReferences.append(MediaReference(
                    sourceMessageIdentity: record.identity,
                    mediaTypeHint: inspection.mediaTypeHint,
                    md5: inspection.md5,
                    mediaID: inspection.mediaID,
                    relativePathHint: inspection.relativePathHint,
                    metadataFieldNames: inspection.metadataFieldNames
                ))
            }
        }
        return MessageSampleAnalysis(
            candidate: candidate,
            records: records,
            fieldMapping: mapping,
            timestampInference: timestampInference,
            typeObservations: typeObservations,
            textCandidates: textCandidates,
            payloadInspections: inspections,
            mediaReferences: mediaReferences
        )
    }

    private func inspectionColumns(mapping: MessageFieldMapping, candidateColumns: [String]) -> [String] {
        let structuralColumns = candidateColumns.filter { column in
            let lower = column.lowercased()
            return lower.contains("content") || lower.contains("payload") || lower.contains("data") || lower.contains("blob") || lower.contains("xml")
        }
        var seen = Set<String>()
        return ([mapping.contentColumn, mapping.payloadColumn].compactMap { $0 } + structuralColumns)
            .filter { seen.insert($0).inserted }
    }

    private func inspectionScore(_ inspection: MessagePayloadInspection) -> Int {
        if inspection.md5 != nil || inspection.mediaID != nil || inspection.relativePathHint != nil { return 100 }
        if inspection.mediaTypeHint != nil { return 90 }
        return switch inspection.kind {
        case .xml: 80
        case .json: 70
        case .text: 60
        case .blob: 50
        case .unknown: 10
        case .empty: 0
        }
    }

    private func fieldMapping(for columns: [String]) -> MessageFieldMapping {
        func first(_ names: [String]) -> String? {
            columns.first { column in names.contains(column.lowercased()) }
        }
        func firstContaining(_ terms: [String]) -> String? {
            columns.first { column in terms.contains(where: { column.lowercased().contains($0) }) }
        }
        return MessageFieldMapping(
            messageIDColumn: first(["local_id", "message_id", "msg_id"]),
            serverMessageIDColumn: first(["server_id", "msgsvrid", "server_msg_id"]),
            timestampColumn: first(["create_time", "timestamp", "createtime"]) ?? firstContaining(["time"]),
            rawTypeColumn: first(["local_type", "msg_type", "message_type", "type"]),
            senderColumn: first(["real_sender_id", "sender_id", "sender", "from_user"]),
            conversationColumn: first(["source", "conversation", "talker", "chatroom", "session"]),
            contentColumn: first(["message_content", "content", "strcontent", "compress_content"]),
            payloadColumn: first(["compress_content", "packed_info_data", "payload", "data", "blob"])
        )
    }

    private func messageTypeObservations(records: [SourceMessageRecord], column: String?) -> [MessageTypeObservation] {
        guard let column else { return [] }
        let counts = records.reduce(into: [Int64: Int]()) { counts, record in
            if let rawType = record.values[column]?.integerValue { counts[rawType, default: 0] += 1 }
        }
        return counts.map { MessageTypeObservation(rawType: $0.key, count: $0.value) }.sorted { $0.rawType < $1.rawType }
    }
}

public struct TimestampDetector: Sendable {
    public init() {}

    public func infer(values: [Int64], now: Date = Date()) -> TimestampInference? {
        guard !values.isEmpty else { return nil }
        let earliest = Date(timeIntervalSince1970: 1_262_304_000) // 2010-01-01 UTC
        let latest = now.addingTimeInterval(366 * 24 * 60 * 60)
        func validCount(divisor: Double) -> Int {
            values.reduce(0) { count, value in
                let date = Date(timeIntervalSince1970: Double(value) / divisor)
                return count + (date >= earliest && date <= latest ? 1 : 0)
            }
        }
        let seconds = validCount(divisor: 1)
        let milliseconds = validCount(divisor: 1_000)
        let unit: TimestampUnit = seconds >= milliseconds && seconds > 0 ? .seconds : milliseconds > 0 ? .milliseconds : .unknown
        let valid = unit == .seconds ? seconds : unit == .milliseconds ? milliseconds : 0
        return TimestampInference(
            unit: unit,
            confidence: Double(valid) / Double(values.count),
            validSampleCount: valid,
            sampleCount: values.count
        )
    }
}

public struct MessagePayloadInspector: Sendable {
    public init() {}

    public func inspect(value: SQLiteSourceValue) -> MessagePayloadInspection {
        switch value {
        case .null: MessagePayloadInspection(kind: .empty)
        case .integer, .real: MessagePayloadInspection(kind: .unknown)
        case let .text(text): inspect(text: text)
        case let .blob(blob): inspect(blob: blob)
        }
    }

    public func inspect(text: String) -> MessagePayloadInspection {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return MessagePayloadInspection(kind: .empty) }
        guard trimmed.utf8.count <= 1_048_576 else { return MessagePayloadInspection(kind: .unknown) }
        if trimmed.hasPrefix("<"), let xml = inspectXML(trimmed) { return xml }
        if let json = inspectJSON(trimmed) { return json }
        return MessagePayloadInspection(kind: .text)
    }

    private func inspectXML(_ text: String) -> MessagePayloadInspection? {
        let delegate = XMLMetadataDelegate()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return MessagePayloadInspection(
            kind: .xml,
            elementNames: delegate.elementNames.sorted(),
            attributeNames: delegate.attributeNames.sorted(),
            metadataFieldNames: delegate.metadata.keys.sorted(),
            mediaTypeHint: delegate.mediaTypeHint,
            md5: delegate.metadata["md5"],
            mediaID: delegate.metadata["mediaid"],
            relativePathHint: delegate.metadata["relativepath"]
        )
    }

    private func inspectJSON(_ text: String) -> MessagePayloadInspection? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any] else {
            return nil
        }
        var keys = Set<String>()
        collectJSONKeys(object, into: &keys, remainingDepth: 8)
        let lowerKeys = keys.map { $0.lowercased() }
        let mediaType: MessageMediaTypeHint? = lowerKeys.contains(where: { $0.contains("image") || $0.contains("img") }) ? .image : nil
        return MessagePayloadInspection(kind: .json, jsonKeys: keys.sorted(), mediaTypeHint: mediaType)
    }

    /// Some native payloads retain a 32-character content MD5 inside an
    /// otherwise opaque BLOB. This is a bounded structural probe (the reader
    /// retains at most 256 KiB per BLOB), not a decoder: it never converts or
    /// emits the surrounding bytes.
    private func inspect(blob: SQLiteBlobSourceValue) -> MessagePayloadInspection {
        var inspection = MessagePayloadInspection(
            kind: .blob,
            blobLength: blob.length,
            blobSHA256: blob.sha256
        )
        guard let data = blob.data,
              let md5 = embeddedMD5(in: data) else {
            return inspection
        }
        inspection = MessagePayloadInspection(
            kind: .blob,
            metadataFieldNames: ["embedded_md5"],
            md5: md5,
            blobLength: blob.length,
            blobSHA256: blob.sha256
        )
        return inspection
    }

    private func embeddedMD5(in data: Data) -> String? {
        let bytes = Array(data)
        guard bytes.count >= 32 else { return nil }
        func isHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        for start in 0...(bytes.count - 32) {
            let end = start + 32
            guard bytes[start..<end].allSatisfy(isHex),
                  (start == 0 || !isHex(bytes[start - 1])),
                  (end == bytes.count || !isHex(bytes[end])) else {
                continue
            }
            return String(decoding: bytes[start..<end], as: UTF8.self).lowercased()
        }
        return nil
    }

    private func collectJSONKeys(_ object: Any, into keys: inout Set<String>, remainingDepth: Int) {
        guard remainingDepth > 0 else { return }
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                keys.insert(key)
                collectJSONKeys(value, into: &keys, remainingDepth: remainingDepth - 1)
            }
        } else if let array = object as? [Any] {
            for value in array.prefix(100) { collectJSONKeys(value, into: &keys, remainingDepth: remainingDepth - 1) }
        }
    }
}

private final class XMLMetadataDelegate: NSObject, XMLParserDelegate {
    var elementNames = Set<String>()
    var attributeNames = Set<String>()
    var metadata = [String: String]()
    var mediaTypeHint: MessageMediaTypeHint?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = elementName.lowercased()
        elementNames.insert(element)
        if element.contains("img") || element.contains("image") { mediaTypeHint = .image }
        if element.contains("video") { mediaTypeHint = .video }
        if element.contains("voice") || element.contains("audio") { mediaTypeHint = .voice }
        if element.contains("file") { mediaTypeHint = .file }
        for (rawName, rawValue) in attributeDict {
            let name = rawName.lowercased()
            attributeNames.insert(name)
            switch name {
            case "md5", "filemd5":
                guard rawValue.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil else { continue }
                metadata["md5"] = rawValue.lowercased()
            case "mediaid", "media_id", "fileid", "file_id":
                guard rawValue.count <= 256 else { continue }
                metadata["mediaid"] = rawValue
            case "relativepath", "relative_path":
                guard let path = safeRelativePath(rawValue) else { continue }
                metadata["relativepath"] = path
            default:
                continue
            }
        }
    }
}

private final class SQLiteMessageSampleDatabase {
    private var handle: OpaquePointer?
    private let maximumRetainedBlobBytes = 256 * 1_024

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

    func readRows(candidate: MessageTableCandidate, limit: Int) throws -> [SourceMessageRecord] {
        let withRowID = "SELECT rowid AS \"__wechatarchive_source_rowid\", * FROM \(quoteIdentifier(candidate.tableName)) ORDER BY rowid DESC LIMIT ?"
        if let rows = try? execute(candidate: candidate, sql: withRowID, limit: limit, hasRowID: true) {
            return rows
        }
        return try execute(
            candidate: candidate,
            sql: "SELECT * FROM \(quoteIdentifier(candidate.tableName)) LIMIT ?",
            limit: limit,
            hasRowID: false
        )
    }

    private func execute(candidate: MessageTableCandidate, sql: String, limit: Int, hasRowID: Bool) throws -> [SourceMessageRecord] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArchiveError.databaseFailure
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        let columnCount = sqlite3_column_count(statement)
        var records = [SourceMessageRecord]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW else { throw ArchiveError.databaseFailure }
            var values = [String: SQLiteSourceValue]()
            var fallbackIdentifier: String?
            for index in 0..<columnCount {
                let name = columnName(statement, index: index)
                let value = sourceValue(statement, index: index)
                if !hasRowID && ["local_id", "id", "message_id"].contains(name.lowercased()), let integer = value.integerValue {
                    fallbackIdentifier = String(integer)
                }
                if hasRowID && index == 0 {
                    fallbackIdentifier = value.integerValue.map(String.init)
                    continue
                }
                values[name] = value
            }
            let rowIdentifier = fallbackIdentifier ?? "sample-\(records.count + 1)"
            records.append(SourceMessageRecord(
                identity: SourceMessageIdentity(
                    databaseRelativePath: candidate.databaseRelativePath,
                    tableName: candidate.tableName,
                    rowIdentifier: rowIdentifier
                ),
                values: values
            ))
        }
    }

    private func sourceValue(_ statement: OpaquePointer?, index: Int32) -> SQLiteSourceValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard let bytes = sqlite3_column_text(statement, index), length > 0 else { return .text("") }
            return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self))
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, index))
            let data: Data
            if length == 0 {
                data = Data()
            } else if let bytes = sqlite3_column_blob(statement, index) {
                data = Data(bytes: bytes, count: length)
            } else {
                return .blob(SQLiteBlobSourceValue(length: length, sha256: sha256(Data()), data: nil))
            }
            return .blob(SQLiteBlobSourceValue(
                length: length,
                sha256: sha256(data),
                data: length <= maximumRetainedBlobBytes ? data : nil
            ))
        default: return .null
        }
    }

    private func columnName(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let name = sqlite3_column_name(statement, index) else { return "column_\(index)" }
        return String(cString: name)
    }

    private func requireHandle() -> OpaquePointer? { handle }

    private func quoteIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func safeRelativePath(_ value: String) -> String? {
    let normalized = value.replacingOccurrences(of: "\\", with: "/")
    guard !normalized.isEmpty, !normalized.hasPrefix("/"), normalized.count <= 1_024 else { return nil }
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
    return components.joined(separator: "/")
}
