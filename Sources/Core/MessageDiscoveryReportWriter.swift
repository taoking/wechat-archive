import Foundation

public struct MessageDiscoveryReportLocations: Equatable, Sendable {
    public let directoryURL: URL
    public let jsonURL: URL
    public let markdownURL: URL

    public init(directoryURL: URL, jsonURL: URL, markdownURL: URL) {
        self.directoryURL = directoryURL
        self.jsonURL = jsonURL
        self.markdownURL = markdownURL
    }
}

/// Writes a deliberately redacted local analysis report. It never receives a
/// raw source value and therefore cannot serialize message text, BLOB bytes,
/// media identifiers, or absolute filesystem locations.
public struct MessageDiscoveryReportWriter: Sendable {
    public init() {}

    @discardableResult
    public func write(_ result: MessageMediaDiscoveryResult, to directory: URL) throws -> MessageDiscoveryReportLocations {
        let root = try prepareDirectory(directory.standardizedFileURL)
        let jsonURL = root.appending(path: "message-discovery.json")
        let markdownURL = root.appending(path: "message-discovery.md")
        let report = SafeMessageDiscoveryReport(result: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeData(try encoder.encode(report), to: jsonURL)
        try writeData(Data(markdown(for: report).utf8), to: markdownURL)
        return MessageDiscoveryReportLocations(directoryURL: root, jsonURL: jsonURL, markdownURL: markdownURL)
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
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path()) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        }
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path())
    }

    private func markdown(for report: SafeMessageDiscoveryReport) -> String {
        var lines = [
            "# Local Message & Media Discovery",
            "",
            "This report is structural: it excludes message text, BLOB bytes, media IDs, hashes, filenames, and absolute paths.",
            "",
            "## Message Table",
            "",
            "Database: `\(report.candidate.databaseRelativePath)`",
            "Table: `\(report.candidate.tableName)`",
            "Sample rows inspected: \(report.sampleRowCount)",
            "Candidate score: \(report.candidate.score)",
            "",
            "## Confirmed Field Mapping",
            ""
        ]
        for item in report.fieldMappingItems {
            lines.append("- \(item.label): \(item.column.map { "`\($0)`" } ?? "not detected")")
        }
        lines += ["", "## Timestamp Inference", ""]
        if let timestamp = report.timestampInference {
            lines.append("- Unit: \(timestamp.unit.rawValue)")
            lines.append("- Confidence: \(String(format: "%.2f", timestamp.confidence))")
            lines.append("- Valid samples: \(timestamp.validSampleCount)/\(timestamp.sampleCount)")
        } else {
            lines.append("No timestamp column was detected.")
        }
        lines += ["", "## Raw Type Observations", ""]
        if report.rawTypeObservations.isEmpty {
            lines.append("No integer raw type values were observed.")
        } else {
            for observation in report.rawTypeObservations {
                lines.append("- \(observation.rawType): \(observation.count) sampled rows")
            }
        }
        lines += ["", "## Payload & Media Evidence", ""]
        lines.append("- Text-shaped records: \(report.textCandidateCount)")
        lines.append("- Structural media references: \(report.mediaReferences.count)")
        lines.append("- Resolved media links: \(report.mediaLinks.filter { $0.resolvedFormat != nil }.count)")
        if let mediaScan = report.mediaScan {
            lines.append("- Media files scanned: \(mediaScan.scannedFileCount); candidates: \(mediaScan.discoveredMediaCount)\(mediaScan.isTruncated ? " (bounded scan reached its cap)" : "")")
        } else {
            lines.append("- No original media root was selected.")
        }
        if !report.diagnostics.isEmpty {
            lines.append("- Diagnostics: \(report.diagnostics.map(\.rawValue).joined(separator: ", "))")
        }
        lines += ["", "## Observed Type Mappings", ""]
        if report.observedTypeMappings.isEmpty {
            lines.append("No type-to-media mapping was confirmed by a resolved local media file.")
        } else {
            for mapping in report.observedTypeMappings {
                lines.append("- \(mapping.rawType) → \(mapping.observedType.rawValue), \(mapping.count) evidence row(s), \(mapping.confidence.rawValue) confidence")
            }
        }
        lines += ["", "## Privacy", "", "Only local, user-selected sources were opened read-only. No source data was changed or copied."]
        return lines.joined(separator: "\n") + "\n"
    }
}

private struct SafeMessageDiscoveryReport: Codable {
    struct Candidate: Codable {
        let databaseRelativePath: String
        let tableName: String
        let rowCount: Int64?
        let score: Int
        let columns: [String]
    }

    struct FieldMappingItem: Codable {
        let label: String
        let column: String?
    }

    struct SafePayloadInspection: Codable {
        let source: SourceMessageIdentity
        let kind: MessagePayloadKind
        let elementNames: [String]
        let attributeNames: [String]
        let jsonKeys: [String]
        let metadataFieldNames: [String]
        let mediaTypeHint: MessageMediaTypeHint?
        let blobLength: Int?
    }

    struct SafeMediaReference: Codable {
        let source: SourceMessageIdentity
        let mediaTypeHint: MessageMediaTypeHint?
        let metadataFieldNames: [String]
        let hasMD5: Bool
        let hasMediaID: Bool
        let hasRelativePathHint: Bool
        let candidateIdentifierCount: Int
    }

    struct SafeMediaLink: Codable {
        let source: SourceMessageIdentity
        let confidence: LinkConfidence
        let diagnostic: MessageMediaDiagnostic
        let mappingRule: MediaPathMappingRule?
        let reason: String
        let resolvedFormat: LocalMediaFormat?
        let resolvedFileSize: Int64?
        let imageDimensions: MediaImageDimensions?
    }

    struct SafeMediaScan: Codable {
        let scannedFileCount: Int
        let discoveredMediaCount: Int
        let isTruncated: Bool
    }

    let reportVersion: Int
    let candidate: Candidate
    let sampleRowCount: Int
    let fieldMappingItems: [FieldMappingItem]
    let timestampInference: TimestampInference?
    let rawTypeObservations: [MessageTypeObservation]
    let textCandidateCount: Int
    let payloadInspections: [SafePayloadInspection]
    let mediaReferences: [SafeMediaReference]
    let mediaLinks: [SafeMediaLink]
    let mediaScan: SafeMediaScan?
    let observedTypeMappings: [ObservedMessageTypeMapping]
    let diagnostics: [MessageMediaDiagnostic]

    init(result: MessageMediaDiscoveryResult) {
        let analysis = result.messageAnalysis
        reportVersion = 1
        candidate = Candidate(
            databaseRelativePath: redactedMessageReportPath(analysis.candidate.databaseRelativePath),
            tableName: analysis.candidate.tableName,
            rowCount: analysis.candidate.rowCount,
            score: analysis.candidate.score,
            columns: analysis.candidate.columns
        )
        sampleRowCount = analysis.records.count
        fieldMappingItems = [
            .init(label: "Local message ID", column: analysis.fieldMapping.messageIDColumn),
            .init(label: "Server message ID", column: analysis.fieldMapping.serverMessageIDColumn),
            .init(label: "Timestamp", column: analysis.fieldMapping.timestampColumn),
            .init(label: "Raw type", column: analysis.fieldMapping.rawTypeColumn),
            .init(label: "Sender", column: analysis.fieldMapping.senderColumn),
            .init(label: "Conversation", column: analysis.fieldMapping.conversationColumn),
            .init(label: "Content", column: analysis.fieldMapping.contentColumn),
            .init(label: "Payload", column: analysis.fieldMapping.payloadColumn)
        ]
        timestampInference = analysis.timestampInference
        rawTypeObservations = analysis.typeObservations
        textCandidateCount = analysis.textCandidates.count
        payloadInspections = analysis.payloadInspections.map { identity, inspection in
            SafePayloadInspection(
                source: redactedMessageIdentity(identity),
                kind: inspection.kind,
                elementNames: inspection.elementNames,
                attributeNames: inspection.attributeNames,
                jsonKeys: inspection.jsonKeys,
                metadataFieldNames: inspection.metadataFieldNames,
                mediaTypeHint: inspection.mediaTypeHint,
                blobLength: inspection.blobLength
            )
        }
        .sorted { $0.source.rowIdentifier < $1.source.rowIdentifier }
        mediaReferences = analysis.mediaReferences.map { reference in
            SafeMediaReference(
                source: redactedMessageIdentity(reference.sourceMessageIdentity),
                mediaTypeHint: reference.mediaTypeHint,
                metadataFieldNames: reference.metadataFieldNames,
                hasMD5: reference.md5 != nil,
                hasMediaID: reference.mediaID != nil,
                hasRelativePathHint: reference.relativePathHint != nil,
                candidateIdentifierCount: reference.candidateIdentifiers.count
            )
        }
        mediaLinks = result.links.map { link in
            SafeMediaLink(
                source: redactedMessageIdentity(link.reference.sourceMessageIdentity),
                confidence: link.confidence,
                diagnostic: link.diagnostic,
                mappingRule: link.mappingRule,
                reason: link.reason,
                resolvedFormat: link.resolvedFile?.format,
                resolvedFileSize: link.resolvedFile?.fileSize,
                imageDimensions: link.resolvedFile?.imageDimensions
            )
        }
        if let scan = result.mediaScan {
            mediaScan = SafeMediaScan(scannedFileCount: scan.scannedFileCount, discoveredMediaCount: scan.files.count, isTruncated: scan.isTruncated)
        } else {
            mediaScan = nil
        }
        observedTypeMappings = result.observedTypeMappings
        diagnostics = result.diagnostics
    }
}

private func redactedMessageIdentity(_ identity: SourceMessageIdentity) -> SourceMessageIdentity {
    SourceMessageIdentity(
        databaseRelativePath: redactedMessageReportPath(identity.databaseRelativePath),
        tableName: identity.tableName,
        rowIdentifier: identity.rowIdentifier
    )
}

private func redactedMessageReportPath(_ relativePath: String) -> String {
    relativePath
        .split(separator: "/", omittingEmptySubsequences: false)
        .map { component in
            let value = String(component)
            let lower = value.lowercased()
            return lower.hasPrefix("wxid_") || lower.hasPrefix("wxid-") ? "<redacted>" : value
        }
        .joined(separator: "/")
}
