import CryptoKit
import Foundation

public struct SQLiteSchemaReportLocations: Equatable, Sendable {
    public let directoryURL: URL
    public let summaryJSONURL: URL
    public let summaryMarkdownURL: URL
    public let databaseReportURLs: [URL]

    public init(directoryURL: URL, summaryJSONURL: URL, summaryMarkdownURL: URL, databaseReportURLs: [URL]) {
        self.directoryURL = directoryURL
        self.summaryJSONURL = summaryJSONURL
        self.summaryMarkdownURL = summaryMarkdownURL
        self.databaseReportURLs = databaseReportURLs
    }
}

/// Writes structural reports only. The writer intentionally receives an
/// already-complete discovery result and never opens a source database.
public struct SQLiteSchemaReportWriter: Sendable {
    public init() {}

    @discardableResult
    public func write(_ report: SQLiteSchemaDiscoveryReport, to directory: URL) throws -> SQLiteSchemaReportLocations {
        let root = try prepareDirectory(directory.standardizedFileURL)
        let databasesDirectory = try prepareDirectory(root.appending(path: "databases"))
        let safeReport = report.sanitizedForReport()
        let jsonURL = root.appending(path: "schema-summary.json")
        let markdownURL = root.appending(path: "schema-summary.md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeData(try encoder.encode(safeReport), to: jsonURL)
        try writeData(Data(summaryMarkdown(for: safeReport).utf8), to: markdownURL)

        var databaseReportURLs = [URL]()
        for database in safeReport.databases {
            let url = databasesDirectory.appending(path: reportFilename(for: database.relativePath))
            try writeData(Data(databaseMarkdown(for: database, candidates: safeReport.tableCandidates).utf8), to: url)
            databaseReportURLs.append(url)
        }
        return SQLiteSchemaReportLocations(
            directoryURL: root,
            summaryJSONURL: jsonURL,
            summaryMarkdownURL: markdownURL,
            databaseReportURLs: databaseReportURLs
        )
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

    private func reportFilename(for relativePath: String) -> String {
        let readable = relativePath.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-" ? Character(String(scalar)) : "_"
        }
        .map(String.init)
        .joined()
        let digest = SHA256.hash(data: Data(relativePath.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(readable)-\(digest).md"
    }

    private func summaryMarkdown(for report: SQLiteSchemaDiscoveryReport) -> String {
        var lines = [
            "# WeChat Database Schema Report",
            "",
            "Databases analyzed: \(report.summary.databaseCount)",
            "Tables: \(report.summary.tableCount)",
            "Rows: \(report.summary.rowCount)",
            "Schema groups: \(report.schemaGroups.count)"
        ]
        if report.summary.failedDatabaseCount > 0 {
            lines.append("Databases not inspected: \(report.summary.failedDatabaseCount)")
        }
        lines.append("")
        appendDatabaseSection(.message, title: "Message Databases", report: report, lines: &lines)
        appendDatabaseSection(.contact, title: "Contact Databases", report: report, lines: &lines)
        appendDatabaseSection(.conversation, title: "Conversation Databases", report: report, lines: &lines)
        appendDatabaseSection(.media, title: "Media Databases", report: report, lines: &lines)

        lines.append("## Top Message Table Candidates")
        appendCandidates(report.candidates(for: .message), to: &lines)
        lines.append("")
        lines.append("## Top Contact Table Candidates")
        appendCandidates(report.candidates(for: .contact), to: &lines)
        lines.append("")
        lines.append("## Top Conversation Table Candidates")
        appendCandidates(report.candidates(for: .conversation), to: &lines)
        lines.append("")
        lines.append("## Schema Groups")
        for group in report.schemaGroups {
            lines.append("### \(group.fingerprint.prefix(12))")
            lines.append("Category: \(group.classification.displayName)")
            lines.append("Representative: `\(group.representativePath)`")
            lines.append("Databases: \(group.relativePaths.count)")
            for path in group.relativePaths { lines.append("- `\(path)`") }
            lines.append("")
        }
        if !report.failures.isEmpty {
            lines.append("## Databases Not Inspected")
            for failure in report.failures {
                lines.append("- `\(failure.relativePath)`: \(failure.message)")
            }
            lines.append("")
        }
        lines.append("This report contains only schema names, declared types, constraints, indexes, foreign keys, aggregate row counts, and heuristic scores. It does not include database values or text samples.")
        return lines.joined(separator: "\n") + "\n"
    }

    private func appendDatabaseSection(
        _ category: WeChatDatabaseCategory,
        title: String,
        report: SQLiteSchemaDiscoveryReport,
        lines: inout [String]
    ) {
        lines.append("## \(title)")
        let databases = report.databases.filter { $0.classification.category == category }
        if databases.isEmpty {
            lines.append("None detected.")
        } else {
            for database in databases {
                lines.append("- `\(database.relativePath)` — \(database.classification.displayName), \(database.rowCount) rows")
            }
        }
        lines.append("")
    }

    private func appendCandidates(_ candidates: [SQLiteSchemaTableCandidate], to lines: inout [String]) {
        if candidates.isEmpty {
            lines.append("None detected.")
        } else {
            for (index, candidate) in candidates.prefix(20).enumerated() {
                lines.append("\(index + 1). `\(candidate.databaseRelativePath)` :: `\(candidate.tableName)` — score \(candidate.score)")
            }
        }
    }

    private func databaseMarkdown(for database: SQLiteDatabaseInfo, candidates: [SQLiteSchemaTableCandidate]) -> String {
        var lines = [
            "# SQLite Schema Report",
            "",
            "Database: `\(database.relativePath)`",
            "Category: \(database.classification.displayName)",
            "Confidence: \(String(format: "%.2f", database.classification.confidence))",
            "Size: \(database.fileSize) bytes",
            "SQLite version: \(database.sqliteVersion)",
            "Pages: \(database.pageCount) × \(database.pageSize) bytes",
            "Tables: \(database.tableCount)",
            "Indexes: \(database.indexCount)",
            "Views: \(database.viewCount)",
            "Triggers: \(database.triggerCount)",
            "Schema fingerprint: `\(database.schemaFingerprint)`",
            ""
        ]
        for table in database.tables {
            lines.append("## \(table.name)")
            if table.isFTSShadowTable {
                lines.append("Role: FTS shadow table (not treated as a business table)")
            } else if table.isVirtual {
                lines.append("Role: Virtual table")
            } else if let score = candidates.first(where: {
                $0.databaseRelativePath == database.relativePath && $0.tableName == table.name
            }) {
                lines.append("Candidate role: \(score.category.displayName), score \(score.score)")
            }
            if let rowCount = table.rowCount { lines.append("Rows: \(rowCount)") }
            lines.append("")
            lines.append("| Column | Declared Type | PK | Nullable | Default |")
            lines.append("| --- | --- | --- | --- | --- |")
            for column in table.columns {
                lines.append("| \(markdownCell(column.name)) | \(markdownCell(column.declaredType)) | \(column.isPrimaryKey ? "Yes" : "No") | \(column.isNullable ? "Yes" : "No") | \(column.hasDefaultValue ? "Present" : "No") |")
            }
            if !table.indexes.isEmpty {
                lines.append("")
                lines.append("Indexes:")
                for index in table.indexes {
                    lines.append("- `\(index.name)` (\(index.isUnique ? "unique" : "non-unique")): \(index.columns.map { "`\($0)`" }.joined(separator: ", "))")
                }
            }
            if !table.foreignKeys.isEmpty {
                lines.append("")
                lines.append("Foreign keys:")
                for foreignKey in table.foreignKeys {
                    lines.append("- \(foreignKey.columns.map { "`\($0)`" }.joined(separator: ", ")) → `\(foreignKey.referencedTable)` (\(foreignKey.referencedColumns.map { "`\($0)`" }.joined(separator: ", ")); update \(foreignKey.onUpdate), delete \(foreignKey.onDelete))")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func markdownCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

private extension SQLiteSchemaDiscoveryReport {
    func sanitizedForReport() -> SQLiteSchemaDiscoveryReport {
        let databases = databases.map { database in
            SQLiteDatabaseInfo(
                relativePath: redactedReportPath(database.relativePath),
                fileSize: database.fileSize,
                sqliteVersion: database.sqliteVersion,
                pageCount: database.pageCount,
                pageSize: database.pageSize,
                tableCount: database.tableCount,
                indexCount: database.indexCount,
                viewCount: database.viewCount,
                triggerCount: database.triggerCount,
                tables: database.tables,
                classification: database.classification,
                schemaFingerprint: database.schemaFingerprint
            )
        }
        let failures = failures.map { SQLiteSchemaInspectionFailure(relativePath: redactedReportPath($0.relativePath), message: $0.message) }
        let groups = schemaGroups.map {
            SQLiteSchemaGroup(
                fingerprint: $0.fingerprint,
                representativePath: redactedReportPath($0.representativePath),
                relativePaths: $0.relativePaths.map(redactedReportPath),
                classification: $0.classification
            )
        }
        let candidates = tableCandidates.map {
            SQLiteSchemaTableCandidate(
                databaseRelativePath: redactedReportPath($0.databaseRelativePath),
                tableName: $0.tableName,
                category: $0.category,
                score: $0.score
            )
        }
        return SQLiteSchemaDiscoveryReport(
            discoveredDatabaseCount: discoveredDatabaseCount,
            databases: databases,
            failures: failures,
            schemaGroups: groups,
            tableCandidates: candidates
        )
    }
}

/// A report retains relative paths for useful schema grouping, but a wxid-like
/// path component is an identifier and must not leave the local UI in a report.
private func redactedReportPath(_ relativePath: String) -> String {
    relativePath
        .split(separator: "/", omittingEmptySubsequences: false)
        .map { component in
            let value = String(component)
            let lower = value.lowercased()
            return lower.hasPrefix("wxid_") || lower.hasPrefix("wxid-") ? "<redacted>" : value
        }
        .joined(separator: "/")
}
