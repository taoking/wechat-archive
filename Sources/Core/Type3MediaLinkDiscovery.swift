import Foundation

public enum Type3MediaDiscoveryDiagnostic: String, Codable, Equatable, Sendable {
    case candidateIdentifierFound
    case candidateIdentifierNotConfirmed
    case compressionDetected
    case payloadDecoded
    case mediaDatabaseHit
    case hardlinkHit
    case mediaFileVerified
}

public struct MediaMetadataSchemaSummary: Codable, Equatable, Sendable {
    public let candidateDatabaseCount: Int
    public let candidateTableCount: Int
    public let potentialMappingTableCount: Int
    public let usefulColumns: [String]
    public let usefulIndexColumns: [String]

    public init(
        candidateDatabaseCount: Int,
        candidateTableCount: Int,
        potentialMappingTableCount: Int,
        usefulColumns: [String],
        usefulIndexColumns: [String]
    ) {
        self.candidateDatabaseCount = candidateDatabaseCount
        self.candidateTableCount = candidateTableCount
        self.potentialMappingTableCount = potentialMappingTableCount
        self.usefulColumns = usefulColumns
        self.usefulIndexColumns = usefulIndexColumns
    }
}

public struct Type3MediaLinkDiscoveryResult: Equatable, Sendable {
    public let payloadAnalysis: Type3PayloadAnalysis
    public let hardlinkCrossValidation: HardlinkCandidateCrossValidation
    public let hardlinkDatabase: HardlinkDatabaseInspection
    /// Aggregate-only auxiliary evidence. It is never used as the media
    /// association itself and contains no source timestamp values.
    public let hardlinkTimeCorrelation: HardlinkTimeCorrelation?
    public let mediaMetadataSchema: MediaMetadataSchemaSummary?
    public let diagnostics: [Type3MediaDiscoveryDiagnostic]

    public init(
        payloadAnalysis: Type3PayloadAnalysis,
        hardlinkCrossValidation: HardlinkCandidateCrossValidation,
        hardlinkDatabase: HardlinkDatabaseInspection,
        hardlinkTimeCorrelation: HardlinkTimeCorrelation? = nil,
        mediaMetadataSchema: MediaMetadataSchemaSummary?,
        diagnostics: [Type3MediaDiscoveryDiagnostic]
    ) {
        self.payloadAnalysis = payloadAnalysis
        self.hardlinkCrossValidation = hardlinkCrossValidation
        self.hardlinkDatabase = hardlinkDatabase
        self.hardlinkTimeCorrelation = hardlinkTimeCorrelation
        self.mediaMetadataSchema = mediaMetadataSchema
        self.diagnostics = diagnostics
    }
}

/// Performs a bounded type-3 payload investigation. It reads at most 100
/// matching message rows and emits only structural, aggregate metadata.
public struct Type3MediaLinkDiscoveryCoordinator: Sendable {
    public init() {}

    public func discover(
        exportRoot: URL,
        candidate: MessageTableCandidate,
        sampleLimit: Int = 100
    ) throws -> Type3MediaLinkDiscoveryResult {
        guard let typeColumn = candidate.columns.first(where: {
            ["local_type", "msg_type", "message_type", "type"].contains($0.lowercased())
        }) else {
            throw ArchiveError.invalidInput
        }
        let records = try WeChatMessageSampleReader().read(
            exportRoot: exportRoot,
            candidate: candidate,
            whereIntegerColumn: typeColumn,
            equals: 3,
            sampleLimit: sampleLimit
        )
        let payloadAnalysis = Type3PayloadAnalyzer().analyze(records: records)
        let mapper = WeChatMediaDatabaseMapper()
        let hardlinkCrossValidation = try mapper.crossValidate(
            hex32Candidates: payloadAnalysis.hex32Candidates,
            exportRoot: exportRoot
        )
        let hardlinkDatabase = try mapper.inspectHardlinkDatabase(exportRoot: exportRoot)
        let timestampColumn = candidate.columns.first(where: {
            ["create_time", "timestamp", "createtime"].contains($0.lowercased()) || $0.lowercased().contains("time")
        })
        let hardlinkTimeCorrelation: HardlinkTimeCorrelation?
        if let timestampColumn {
            let messageTimes = records.compactMap { $0.values[timestampColumn]?.integerValue }
            hardlinkTimeCorrelation = messageTimes.isEmpty ? nil : try mapper.correlateMessageTimes(messageTimes, exportRoot: exportRoot)
        } else {
            hardlinkTimeCorrelation = nil
        }
        let allHardlinkHits = hardlinkCrossValidation.imageHits + hardlinkCrossValidation.videoHits + hardlinkCrossValidation.fileHits
        let mediaMetadataSchema = allHardlinkHits == 0 ? try mediaMetadataSchemaSummary(below: exportRoot) : nil
        var diagnostics = [Type3MediaDiscoveryDiagnostic]()
        if !payloadAnalysis.candidateIdentifiers.isEmpty {
            diagnostics.append(.candidateIdentifierFound)
        }
        if payloadAnalysis.candidateIdentifiers.contains(where: { $0.semanticHint != .confirmedMD5 }) {
            diagnostics.append(.candidateIdentifierNotConfirmed)
        }
        if payloadAnalysis.payloadObservations.contains(where: { $0.compression != .none && $0.compression != .unsupported }) {
            diagnostics.append(.compressionDetected)
        }
        if payloadAnalysis.payloadObservations.contains(where: { [.xml, .json, .protobufLike].contains($0.payloadKind) }) {
            diagnostics.append(.payloadDecoded)
        }
        if allHardlinkHits > 0 { diagnostics.append(.hardlinkHit) }
        return Type3MediaLinkDiscoveryResult(
            payloadAnalysis: payloadAnalysis,
            hardlinkCrossValidation: hardlinkCrossValidation,
            hardlinkDatabase: hardlinkDatabase,
            hardlinkTimeCorrelation: hardlinkTimeCorrelation,
            mediaMetadataSchema: mediaMetadataSchema,
            diagnostics: diagnostics
        )
    }

    private func mediaMetadataSchemaSummary(below exportRoot: URL) throws -> MediaMetadataSchemaSummary? {
        let root = exportRoot.standardizedFileURL
        let reportURL = root.appending(path: "SchemaReports/schema-summary.json")
        let values = try reportURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let report = try JSONDecoder().decode(
            SQLiteSchemaDiscoveryReport.self,
            from: Data(contentsOf: reportURL, options: .mappedIfSafe)
        )
        let mediaDatabases = report.databases.filter { $0.classification.category == .media }
        let tables = mediaDatabases.flatMap(\.tables)
        guard !tables.isEmpty else { return nil }
        let usefulTerms = ["md5", "message", "local_id", "media", "file", "path", "cdn", "thumb", "original", "time", "size"]
        let usefulColumns = Set(tables.flatMap { table in
            table.columns.map(\.name).filter { name in usefulTerms.contains(where: { name.lowercased().contains($0) }) }
        })
        let usefulIndexColumns = Set(tables.flatMap { table in
            table.indexes.flatMap(\.columns).filter { name in usefulTerms.contains(where: { name.lowercased().contains($0) }) }
        })
        let mappingTableCount = tables.filter { table in
            let columns = table.columns.map { $0.name.lowercased() }
            let hasMessageKey = columns.contains { ["message", "local_id", "msg_id", "source_id", "create_time"].contains(where: $0.contains) }
            let hasMediaKey = columns.contains { ["md5", "media", "file", "path", "cdn", "thumb", "original"].contains(where: $0.contains) }
            return hasMessageKey && hasMediaKey
        }.count
        return MediaMetadataSchemaSummary(
            candidateDatabaseCount: mediaDatabases.count,
            candidateTableCount: tables.count,
            potentialMappingTableCount: mappingTableCount,
            usefulColumns: usefulColumns.sorted(),
            usefulIndexColumns: usefulIndexColumns.sorted()
        )
    }
}

public struct AttachDirectoryInspection: Codable, Equatable, Sendable {
    public let fileCount: Int
    public let directoryCount: Int
    public let extensionDistribution: [String: Int]
    public let sizeDistribution: [String: Int]
    public let sampledHeaderCount: Int
    public let plainImageCount: Int
    public let xorImageCount: Int
    public let unknownHeaderCount: Int

    public init(
        fileCount: Int,
        directoryCount: Int,
        extensionDistribution: [String: Int],
        sizeDistribution: [String: Int],
        sampledHeaderCount: Int,
        plainImageCount: Int,
        xorImageCount: Int,
        unknownHeaderCount: Int
    ) {
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.extensionDistribution = extensionDistribution
        self.sizeDistribution = sizeDistribution
        self.sampledHeaderCount = sampledHeaderCount
        self.plainImageCount = plainImageCount
        self.xorImageCount = xorImageCount
        self.unknownHeaderCount = unknownHeaderCount
    }
}

/// Reads directory and header aggregates from `msg/attach` without returning
/// filenames, copying files, or hashing file contents.
public struct WeChatAttachDirectoryInspector: Sendable {
    public init() {}

    public func inspect(accountRoot: URL, maximumHeaderSamples: Int = 100) throws -> AttachDirectoryInspection {
        let requestedRoot = accountRoot.standardizedFileURL
        let rootValues = try requestedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let attach = root.appending(path: "msg/attach")
        let attachValues = try attach.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attachValues.isDirectory == true, attachValues.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: attach,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { throw ArchiveError.ioFailure }
        var directoryCount = 1
        var fileCount = 0
        var extensionDistribution = [String: Int]()
        var sizeDistribution = [String: Int]()
        var headerURLs = [URL]()
        for case let candidate as URL in enumerator {
            guard let values = try? candidate.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                directoryCount += 1
                continue
            }
            guard values.isRegularFile == true else { continue }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(resolved, of: attach) else { continue }
            fileCount += 1
            let extensionName = resolved.pathExtension.isEmpty ? "[none]" : resolved.pathExtension.lowercased()
            extensionDistribution[extensionName, default: 0] += 1
            sizeDistribution[sizeBucket(Int64(values.fileSize ?? 0)), default: 0] += 1
            if headerURLs.count < min(maximumHeaderSamples, 100) { headerURLs.append(resolved) }
        }
        var plainImageCount = 0
        var xorImageCount = 0
        var unknownHeaderCount = 0
        for url in headerURLs {
            guard let file = try? WeChatMediaScanner().inspect(mediaFileURL: url, below: attach) else {
                unknownHeaderCount += 1
                continue
            }
            if file.format.isImage {
                if file.headerXORKey == nil { plainImageCount += 1 } else { xorImageCount += 1 }
            } else {
                unknownHeaderCount += 1
            }
        }
        return AttachDirectoryInspection(
            fileCount: fileCount,
            directoryCount: directoryCount,
            extensionDistribution: extensionDistribution,
            sizeDistribution: sizeDistribution,
            sampledHeaderCount: headerURLs.count,
            plainImageCount: plainImageCount,
            xorImageCount: xorImageCount,
            unknownHeaderCount: unknownHeaderCount
        )
    }

    private func sizeBucket(_ size: Int64) -> String {
        switch size {
        case ..<1_024: "<1KiB"
        case ..<1_048_576: "1KiB-1MiB"
        case ..<10_485_760: "1MiB-10MiB"
        default: ">=10MiB"
        }
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        return url.path().hasPrefix(rootPath)
    }
}
