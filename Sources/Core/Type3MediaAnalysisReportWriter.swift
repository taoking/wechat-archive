import Foundation

public struct Type3MediaAnalysisReportLocations: Equatable, Sendable {
    public let directoryURL: URL
    public let jsonURL: URL
    public let markdownURL: URL

    public init(directoryURL: URL, jsonURL: URL, markdownURL: URL) {
        self.directoryURL = directoryURL
        self.jsonURL = jsonURL
        self.markdownURL = markdownURL
    }
}

/// Writes an aggregate-only local Type 3 investigation. The DTO intentionally
/// has no candidate value, raw message field, BLOB, filename, or path member.
public struct Type3MediaAnalysisReportWriter: Sendable {
    public init() {}

    @discardableResult
    public func write(
        _ result: Type3MediaLinkDiscoveryResult,
        attachInspection: AttachDirectoryInspection?,
        to directory: URL
    ) throws -> Type3MediaAnalysisReportLocations {
        let root = try prepareDirectory(directory.standardizedFileURL)
        let report = SafeType3MediaAnalysisReport(result: result, attachInspection: attachInspection)
        let jsonURL = root.appending(path: "type3-media-analysis.json")
        let markdownURL = root.appending(path: "type3-media-analysis.md")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeData(try encoder.encode(report), to: jsonURL)
        try writeData(Data(markdown(for: report).utf8), to: markdownURL)
        return Type3MediaAnalysisReportLocations(directoryURL: root, jsonURL: jsonURL, markdownURL: markdownURL)
    }

    private func prepareDirectory(_ url: URL) throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path()) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path())
        return url
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path())
    }

    private func markdown(for report: SafeType3MediaAnalysisReport) -> String {
        var lines = [
            "# Local Type 3 Media Analysis",
            "",
            "This report contains only aggregate structure. It excludes message text, identifiers, hashes, filenames, paths, and BLOB bytes.",
            "",
            "## Bounded Sample",
            "",
            "- Type 3 rows sampled: \(report.sampledRecordCount)",
            "- Hex32 candidates: \(report.hardlinkCrossValidation.candidateCount)",
            "- Unique hex32 candidates: \(report.hardlinkCrossValidation.uniqueCandidateCount)",
            "",
            "## Hardlink Cross Validation",
            "",
            "- Image hits: \(report.hardlinkCrossValidation.imageHits)",
            "- Video hits: \(report.hardlinkCrossValidation.videoHits)",
            "- File hits: \(report.hardlinkCrossValidation.fileHits)",
            "- No-hit candidates: \(report.hardlinkCrossValidation.noHitCount)",
            "",
            "## Diagnostics",
            "",
            report.diagnostics.isEmpty ? "No structural diagnostic was produced." : report.diagnostics.map { "- \($0.rawValue)" }.joined(separator: "\n"),
            "",
            "## Privacy",
            "",
            "Only local, user-selected sources were opened read-only. No source data was changed or copied."
        ]
        if let attach = report.attachInspection {
            lines += [
                "",
                "## Attach Directory",
                "",
                "- Files: \(attach.fileCount)",
                "- Header samples: \(attach.sampledHeaderCount)",
                "- Plain images: \(attach.plainImageCount)",
                "- XOR images: \(attach.xorImageCount)",
                "- Unknown headers: \(attach.unknownHeaderCount)"
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private struct SafeType3MediaAnalysisReport: Codable {
    struct PayloadAggregate: Codable {
        let sourceColumn: String
        let storageClass: SQLiteSourceStorageClass
        let compression: PayloadCompression
        let payloadKind: PayloadStructureKind
        let count: Int
    }

    /// Structural protobuf evidence, aggregated without retaining the
    /// corresponding bytes or field values.
    struct ProtobufFieldAggregate: Codable {
        let sourceColumn: String
        let fieldNumber: Int
        let wireType: Int
        let valueLength: Int?
        let count: Int
    }

    let reportVersion: Int
    let sampledRecordCount: Int
    let payloadAggregates: [PayloadAggregate]
    let protobufFieldAggregates: [ProtobufFieldAggregate]
    let identifierSummaries: [Type3IdentifierSummary]
    let hardlinkCrossValidation: HardlinkCandidateCrossValidation
    let hardlinkDatabase: HardlinkDatabaseInspection
    let hardlinkTimeCorrelation: HardlinkTimeCorrelation?
    let mediaMetadataSchema: MediaMetadataSchemaSummary?
    let diagnostics: [Type3MediaDiscoveryDiagnostic]
    let attachInspection: AttachDirectoryInspection?

    init(result: Type3MediaLinkDiscoveryResult, attachInspection: AttachDirectoryInspection?) {
        reportVersion = 1
        sampledRecordCount = result.payloadAnalysis.sampledRecordCount
        payloadAggregates = Dictionary(grouping: result.payloadAnalysis.payloadObservations) { observation in
            "\(observation.sourceColumn)\u{1F}\(observation.storageClass.rawValue)\u{1F}\(observation.compression.rawValue)\u{1F}\(observation.payloadKind.rawValue)"
        }
        .compactMap { _, observations -> PayloadAggregate? in
            guard let observation = observations.first else { return nil }
            return PayloadAggregate(
                sourceColumn: observation.sourceColumn,
                storageClass: observation.storageClass,
                compression: observation.compression,
                payloadKind: observation.payloadKind,
                count: observations.count
            )
        }
        .sorted {
            ($0.sourceColumn, $0.storageClass.rawValue, $0.compression.rawValue, $0.payloadKind.rawValue) <
                ($1.sourceColumn, $1.storageClass.rawValue, $1.compression.rawValue, $1.payloadKind.rawValue)
        }
        protobufFieldAggregates = Dictionary(grouping: result.payloadAnalysis.payloadObservations.flatMap { observation in
            observation.protobufFields.map { field in (sourceColumn: observation.sourceColumn, field: field) }
        }) { item in
            "\(item.sourceColumn)\u{1F}\(item.field.fieldNumber)\u{1F}\(item.field.wireType)\u{1F}\(item.field.valueLength.map(String.init) ?? "nil")"
        }
        .compactMap { _, values -> ProtobufFieldAggregate? in
            guard let first = values.first else { return nil }
            return ProtobufFieldAggregate(
                sourceColumn: first.sourceColumn,
                fieldNumber: first.field.fieldNumber,
                wireType: first.field.wireType,
                valueLength: first.field.valueLength,
                count: values.count
            )
        }
        .sorted {
            ($0.sourceColumn, $0.fieldNumber, $0.wireType, $0.valueLength ?? -1) <
                ($1.sourceColumn, $1.fieldNumber, $1.wireType, $1.valueLength ?? -1)
        }
        identifierSummaries = result.payloadAnalysis.identifierSummaries
        hardlinkCrossValidation = result.hardlinkCrossValidation
        hardlinkDatabase = result.hardlinkDatabase
        hardlinkTimeCorrelation = result.hardlinkTimeCorrelation
        mediaMetadataSchema = result.mediaMetadataSchema
        diagnostics = result.diagnostics
        self.attachInspection = attachInspection
    }
}
