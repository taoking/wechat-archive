import Foundation

public struct WeChatImageResolutionReportLocations: Equatable, Sendable {
    public let directoryURL: URL
    public let jsonURL: URL
    public let markdownURL: URL

    public init(directoryURL: URL, jsonURL: URL, markdownURL: URL) {
        self.directoryURL = directoryURL
        self.jsonURL = jsonURL
        self.markdownURL = markdownURL
    }
}

/// Writes an aggregate-only Phase 3A.2 report. Source message values, chat
/// names, file bases, key material, decoded bytes, and filesystem paths never
/// enter this DTO or either report representation.
public struct WeChatImageResolutionReportWriter: Sendable {
    public init() {}

    @discardableResult
    public func write(_ run: WeChatImageResolutionRun, to directory: URL) throws -> WeChatImageResolutionReportLocations {
        let root = try prepareDirectory(directory.standardizedFileURL)
        let report = SafeImageResolutionReport(run: run)
        let jsonURL = root.appending(path: "image-resolution.json")
        let markdownURL = root.appending(path: "image-resolution.md")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeData(try encoder.encode(report), to: jsonURL)
        try writeData(Data(markdown(for: report).utf8), to: markdownURL)
        return WeChatImageResolutionReportLocations(directoryURL: root, jsonURL: jsonURL, markdownURL: markdownURL)
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

    private func markdown(for report: SafeImageResolutionReport) -> String {
        [
            "# Local Image Resolution",
            "",
            "This report records only structural status. It excludes source messages, account identifiers, file bases, filenames, paths, key material, and image bytes.",
            "",
            "## Bounded Resolution",
            "",
            "- Type 3 rows sampled: \(report.sampledRecordCount)",
            "- Message resource database found: \(report.messageResourceDatabaseFound)",
            "- Resource match: \(report.resourceMatch ?? "notFound")",
            "- Resource detail found: \(report.resourceDetailFound)",
            "- File base source: \(report.fileBaseSource ?? "none")",
            "- Structured marker: \(report.structuredMarkerFound)",
            "- File base match between sources: \(report.fileBaseSourcesMatch)",
            "",
            "## Local DAT",
            "",
            "- Chat directory found: \(report.chatDirectoryFound)",
            "- Month directory found: \(report.monthDirectoryFound)",
            "- Main DAT found: \(report.main.present)",
            "- HD DAT found: \(report.hd.present)",
            "- Thumbnail DAT found: \(report.thumbnail.present)",
            "- DAT version: \(report.datVersion ?? "unknown")",
            "",
            "## Decode",
            "",
            "- Key derivation candidates available: \(report.keyDerivationAvailable)",
            "- Key verification passed: \(report.keyVerificationPassed)",
            "- Image confirmed: \(report.imageConfirmed)",
            "- Thumbnail: \(report.thumbnail.status)",
            "- Main: \(report.main.status)",
            "- HD: \(report.hd.status)",
            "",
            "## Diagnostics",
            "",
            report.diagnostics.isEmpty ? "No diagnostic was produced." : report.diagnostics.map { "- \($0)" }.joined(separator: "\n"),
            ""
        ].joined(separator: "\n")
    }
}

private struct SafeImageResolutionReport: Codable {
    struct Variant: Codable {
        let present: Bool
        let decoded: Bool
        let format: String?
        let dimensionsAvailable: Bool

        var status: String {
            if !present { return "missing" }
            return decoded ? "decoded" : "notDecoded"
        }

        init(_ value: WeChatImageDecodedVariant) {
            present = value.present
            decoded = value.decoded
            format = value.format?.rawValue
            dimensionsAvailable = value.dimensionsAvailable
        }
    }

    let reportVersion: Int
    let sampledRecordCount: Int
    let messageResourceDatabaseFound: Bool
    let resourceMatch: String?
    let resourceDetailFound: Bool
    let fileBaseSource: String?
    let structuredMarkerFound: Bool
    let fileBaseSourcesMatch: Bool
    let chatDirectoryFound: Bool
    let monthDirectoryFound: Bool
    let datVersion: String?
    let keyDerivationAvailable: Bool
    let keyVerificationPassed: Bool
    let imageConfirmed: Bool
    let thumbnail: Variant
    let main: Variant
    let hd: Variant
    let diagnostics: [String]

    init(run: WeChatImageResolutionRun) {
        let resolution = run.resolution
        reportVersion = 1
        sampledRecordCount = run.sampledRecordCount
        messageResourceDatabaseFound = resolution?.resourceDatabaseFound ?? false
        resourceMatch = resolution?.resourceMatch.rawValue
        resourceDetailFound = resolution?.resourceDetailsFound ?? false
        fileBaseSource = resolution?.fileBase?.source.rawValue
        structuredMarkerFound = resolution?.fileBase?.confidence == .structured
        fileBaseSourcesMatch = resolution?.fileBase?.source == .both
        chatDirectoryFound = resolution?.assets.chatDirectoryFound ?? false
        monthDirectoryFound = resolution?.assets.monthDirectoryFound ?? false
        datVersion = resolution?.datVersion.rawValue
        keyDerivationAvailable = run.keyDerivationAvailable
        keyVerificationPassed = run.keyVerificationPassed
        imageConfirmed = run.imageConfirmed
        thumbnail = Variant(run.thumbnail)
        main = Variant(run.main)
        hd = Variant(run.hd)
        diagnostics = run.diagnostics.map(\.rawValue)
    }
}
