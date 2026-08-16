import CryptoKit
import Foundation
import SQLite3

/// A category inferred from SQLite schema and filename signals. It is a
/// discovery hint, not a statement about the contents of a database.
public enum WeChatDatabaseCategory: String, Codable, CaseIterable, Sendable {
    case message
    case contact
    case conversation
    case group
    case media
    case emoticon
    case favorite
    case bizchat
    case index
    case configuration
    case unknown

    public var displayName: String {
        switch self {
        case .message: "Message"
        case .contact: "Contact"
        case .conversation: "Conversation"
        case .group: "Group"
        case .media: "Media"
        case .emoticon: "Emoticon"
        case .favorite: "Favorite"
        case .bizchat: "BizChat"
        case .index: "Index"
        case .configuration: "Configuration"
        case .unknown: "Unknown"
        }
    }
}

/// Confidence wording deliberately remains separate from the category. A path
/// name alone is only a likely classification; detected requires schema
/// evidence as well.
public enum SQLiteClassificationCertainty: String, Codable, Sendable {
    case detected
    case likely
    case unknown
}

public struct WeChatDatabaseClassification: Codable, Equatable, Sendable {
    public let category: WeChatDatabaseCategory
    public let certainty: SQLiteClassificationCertainty
    public let confidence: Double
    /// Non-sensitive structural reasons such as a field-name class. Never
    /// includes a database value, source path, username, or wxid.
    public let evidence: [String]

    public init(
        category: WeChatDatabaseCategory,
        certainty: SQLiteClassificationCertainty,
        confidence: Double,
        evidence: [String]
    ) {
        self.category = category
        self.certainty = certainty
        self.confidence = confidence
        self.evidence = evidence
    }

    public var displayName: String {
        switch certainty {
        case .detected: "Detected \(category.displayName)"
        case .likely: "Likely \(category.displayName)"
        case .unknown: "Unknown"
        }
    }
}

public struct SQLiteColumnInfo: Codable, Equatable, Sendable {
    public let name: String
    public let declaredType: String
    public let isNullable: Bool
    /// SQLite reports a position rather than a Boolean so composite primary
    /// keys retain their order. Zero means the column is not part of the key.
    public let primaryKeyPosition: Int
    public let hasDefaultValue: Bool

    public init(
        name: String,
        declaredType: String,
        isNullable: Bool,
        primaryKeyPosition: Int,
        hasDefaultValue: Bool
    ) {
        self.name = name
        self.declaredType = declaredType
        self.isNullable = isNullable
        self.primaryKeyPosition = primaryKeyPosition
        self.hasDefaultValue = hasDefaultValue
    }

    public var isPrimaryKey: Bool { primaryKeyPosition > 0 }
}

public struct SQLiteIndexInfo: Codable, Equatable, Sendable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool

    public init(name: String, columns: [String], isUnique: Bool) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
    }
}

public struct SQLiteForeignKeyInfo: Codable, Equatable, Sendable {
    public let id: Int
    public let columns: [String]
    public let referencedTable: String
    public let referencedColumns: [String]
    public let onUpdate: String
    public let onDelete: String

    public init(
        id: Int,
        columns: [String],
        referencedTable: String,
        referencedColumns: [String],
        onUpdate: String,
        onDelete: String
    ) {
        self.id = id
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

public struct SQLiteTableInfo: Codable, Equatable, Sendable {
    public let name: String
    /// Row counts are intentionally not collected for virtual tables or FTS
    /// shadow tables. They are implementation details, not business records.
    public let rowCount: Int64?
    public let columns: [SQLiteColumnInfo]
    public let indexes: [SQLiteIndexInfo]
    public let foreignKeys: [SQLiteForeignKeyInfo]
    public let isVirtual: Bool
    public let isFTSShadowTable: Bool

    public init(
        name: String,
        rowCount: Int64?,
        columns: [SQLiteColumnInfo],
        indexes: [SQLiteIndexInfo],
        foreignKeys: [SQLiteForeignKeyInfo],
        isVirtual: Bool,
        isFTSShadowTable: Bool
    ) {
        self.name = name
        self.rowCount = rowCount
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.isVirtual = isVirtual
        self.isFTSShadowTable = isFTSShadowTable
    }
}

public struct SQLiteDatabaseInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let fileSize: Int64
    public let sqliteVersion: String
    public let pageCount: Int64
    public let pageSize: Int64
    public let tableCount: Int
    public let indexCount: Int
    public let viewCount: Int
    public let triggerCount: Int
    public let tables: [SQLiteTableInfo]
    public let classification: WeChatDatabaseClassification
    public let schemaFingerprint: String

    public init(
        relativePath: String,
        fileSize: Int64,
        sqliteVersion: String,
        pageCount: Int64,
        pageSize: Int64,
        tableCount: Int,
        indexCount: Int,
        viewCount: Int,
        triggerCount: Int,
        tables: [SQLiteTableInfo],
        classification: WeChatDatabaseClassification,
        schemaFingerprint: String
    ) {
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.sqliteVersion = sqliteVersion
        self.pageCount = pageCount
        self.pageSize = pageSize
        self.tableCount = tableCount
        self.indexCount = indexCount
        self.viewCount = viewCount
        self.triggerCount = triggerCount
        self.tables = tables
        self.classification = classification
        self.schemaFingerprint = schemaFingerprint
    }

    public var rowCount: Int64 {
        tables.reduce(0) { $0 + ($1.rowCount ?? 0) }
    }
}

public struct SQLiteSchemaTableCandidate: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(databaseRelativePath)::\(tableName)::\(category.rawValue)" }
    public let databaseRelativePath: String
    public let tableName: String
    public let category: WeChatDatabaseCategory
    public let score: Int

    public init(databaseRelativePath: String, tableName: String, category: WeChatDatabaseCategory, score: Int) {
        self.databaseRelativePath = databaseRelativePath
        self.tableName = tableName
        self.category = category
        self.score = score
    }
}

public struct SQLiteSchemaGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String { fingerprint }
    public let fingerprint: String
    public let representativePath: String
    public let relativePaths: [String]
    public let classification: WeChatDatabaseClassification

    public init(
        fingerprint: String,
        representativePath: String,
        relativePaths: [String],
        classification: WeChatDatabaseClassification
    ) {
        self.fingerprint = fingerprint
        self.representativePath = representativePath
        self.relativePaths = relativePaths
        self.classification = classification
    }
}

public struct SQLiteSchemaInspectionFailure: Codable, Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    /// The deliberately generic message cannot contain SQLite diagnostics,
    /// which may reflect private database metadata.
    public let message: String

    public init(relativePath: String, message: String = "Could not inspect as a plain SQLite database.") {
        self.relativePath = relativePath
        self.message = message
    }
}

public struct SQLiteSchemaSummary: Codable, Equatable, Sendable {
    public let databaseCount: Int
    public let failedDatabaseCount: Int
    public let tableCount: Int
    public let rowCount: Int64
    public let messageDatabases: Int
    public let contactDatabases: Int
    public let conversationDatabases: Int
    public let mediaDatabases: Int
    public let unknownDatabases: Int

    public init(databases: [SQLiteDatabaseInfo], failures: [SQLiteSchemaInspectionFailure]) {
        databaseCount = databases.count
        failedDatabaseCount = failures.count
        tableCount = databases.reduce(0) { $0 + $1.tableCount }
        rowCount = databases.reduce(0) { $0 + $1.rowCount }
        messageDatabases = databases.filter { $0.classification.category == .message }.count
        contactDatabases = databases.filter { $0.classification.category == .contact }.count
        conversationDatabases = databases.filter { $0.classification.category == .conversation }.count
        mediaDatabases = databases.filter { $0.classification.category == .media }.count
        unknownDatabases = databases.filter { $0.classification.category == .unknown }.count
    }
}

public struct SQLiteSchemaDiscoveryReport: Codable, Equatable, Sendable {
    public let discoveredDatabaseCount: Int
    public let databases: [SQLiteDatabaseInfo]
    public let failures: [SQLiteSchemaInspectionFailure]
    public let schemaGroups: [SQLiteSchemaGroup]
    public let tableCandidates: [SQLiteSchemaTableCandidate]
    public let summary: SQLiteSchemaSummary

    public init(
        discoveredDatabaseCount: Int,
        databases: [SQLiteDatabaseInfo],
        failures: [SQLiteSchemaInspectionFailure],
        schemaGroups: [SQLiteSchemaGroup],
        tableCandidates: [SQLiteSchemaTableCandidate]
    ) {
        self.discoveredDatabaseCount = discoveredDatabaseCount
        self.databases = databases
        self.failures = failures
        self.schemaGroups = schemaGroups
        self.tableCandidates = tableCandidates
        summary = SQLiteSchemaSummary(databases: databases, failures: failures)
    }

    public func candidates(for category: WeChatDatabaseCategory) -> [SQLiteSchemaTableCandidate] {
        tableCandidates.filter { $0.category == category }
    }
}

public struct SQLiteSchemaScanProgress: Equatable, Sendable {
    public let completedDatabaseCount: Int
    public let totalDatabaseCount: Int
    public let currentRelativePath: String

    public init(completedDatabaseCount: Int, totalDatabaseCount: Int, currentRelativePath: String) {
        self.completedDatabaseCount = completedDatabaseCount
        self.totalDatabaseCount = totalDatabaseCount
        self.currentRelativePath = currentRelativePath
    }
}

/// Scores database roles using only names and structural metadata. It never
/// opens a database and never inspects a stored value.
public struct WeChatDatabaseClassifier: Sendable {
    public init() {}

    public func classify(relativePath: String, tables: [SQLiteTableInfo]) -> WeChatDatabaseClassification {
        let path = relativePath.lowercased()
        var scores = Dictionary(uniqueKeysWithValues: WeChatDatabaseCategory.allCases.map { ($0, 0) })
        var evidence = [String]()
        var hasSchemaEvidence = false

        for category in WeChatDatabaseCategory.allCases where category != .unknown {
            let pathScore = pathSignalScore(for: category, path: path)
            if pathScore > 0 {
                scores[category, default: 0] += pathScore
                evidence.append("path suggests \(category.rawValue)")
            }
        }

        for table in tables where !table.isVirtual && !table.isFTSShadowTable {
            let tableScores = tableSignalScores(table)
            for (category, tableScore) in tableScores where tableScore > 0 {
                scores[category, default: 0] += min(12, tableScore / 5)
                hasSchemaEvidence = true
            }
        }

        if tables.contains(where: { $0.isVirtual || $0.isFTSShadowTable }) {
            scores[.index, default: 0] += 8
            evidence.append("FTS or virtual table structure")
            hasSchemaEvidence = true
        }

        guard let winner = scores
            .filter({ $0.key != .unknown })
            .max(by: { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
            }), winner.value > 0 else {
            return WeChatDatabaseClassification(category: .unknown, certainty: .unknown, confidence: 0, evidence: [])
        }

        let certainty: SQLiteClassificationCertainty
        if hasSchemaEvidence && winner.value >= 8 {
            certainty = .detected
        } else {
            certainty = .likely
        }
        let confidence: Double
        switch certainty {
        case .detected: confidence = min(0.99, 0.65 + Double(winner.value) * 0.035)
        case .likely: confidence = min(0.85, 0.35 + Double(winner.value) * 0.05)
        case .unknown: confidence = 0
        }
        let schemaEvidence = tables
            .filter { !($0.isVirtual || $0.isFTSShadowTable) }
            .compactMap { table -> String? in
                let score = tableSignalScores(table)[winner.key, default: 0]
                return score > 0 ? "table \(table.name) has \(winner.key.rawValue) structural signals" : nil
            }
        return WeChatDatabaseClassification(
            category: winner.key,
            certainty: certainty,
            confidence: confidence,
            evidence: Array((evidence + schemaEvidence).prefix(4))
        )
    }

    public func tableCandidates(
        databaseRelativePath: String,
        tables: [SQLiteTableInfo]
    ) -> [SQLiteSchemaTableCandidate] {
        tables
            .filter { !$0.isVirtual && !$0.isFTSShadowTable }
            .flatMap { table in
                tableSignalScores(table).compactMap { category, score in
                    guard score > 0 else { return nil }
                    return SQLiteSchemaTableCandidate(
                        databaseRelativePath: databaseRelativePath,
                        tableName: table.name,
                        category: category,
                        score: min(score, 100)
                    )
                }
            }
            .sorted {
                $0.score == $1.score
                    ? ($0.databaseRelativePath, $0.tableName, $0.category.rawValue) < ($1.databaseRelativePath, $1.tableName, $1.category.rawValue)
                    : $0.score > $1.score
            }
    }

    private func pathSignalScore(for category: WeChatDatabaseCategory, path: String) -> Int {
        switch category {
        case .message: path.contains("message") ? 5 : 0
        case .contact: path.contains("contact") ? 5 : 0
        case .conversation: containsAny(path, ["session", "conversation"]) ? 5 : 0
        case .group: containsAny(path, ["chatroom", "group"]) ? 5 : 0
        case .media: containsAny(path, ["media", "image", "video", "voice", "resource", "head_image"]) ? 5 : 0
        case .emoticon: containsAny(path, ["emoticon", "sticker"]) ? 5 : 0
        case .favorite: containsAny(path, ["favorite", "favitem"]) ? 5 : 0
        case .bizchat: containsAny(path, ["bizchat", "biz_message"]) ? 5 : 0
        case .index: containsAny(path, ["fts", "index", "search"]) ? 5 : 0
        case .configuration: containsAny(path, ["general", "config", "setting", "solitaire"]) ? 5 : 0
        case .unknown: 0
        }
    }

    private func tableSignalScores(_ table: SQLiteTableInfo) -> [WeChatDatabaseCategory: Int] {
        let tableName = table.name.lowercased()
        let fields = table.columns.map { $0.name.lowercased() }
        var scores: [WeChatDatabaseCategory: Int] = [:]

        scores[.message] =
            (containsAny(tableName, ["message", "msg"]) ? 20 : 0) +
            matchingFieldScore(fields, terms: ["timestamp", "create_time", "createtime", "time"], points: 10) +
            matchingFieldScore(fields, terms: ["msgsvrid", "server_id", "local_id", "message_id", "msg_id"], points: 10) +
            matchingFieldScore(fields, terms: ["sender", "receiver", "from_user", "to_user", "talker"], points: 10) +
            matchingFieldScore(fields, terms: ["conversation", "session", "chatroom"], points: 10) +
            matchingFieldScore(fields, terms: ["type", "status"], points: 5) +
            matchingFieldScore(fields, terms: ["content", "payload", "blob"], points: 10)

        scores[.contact] =
            (containsAny(tableName, ["contact", "friend"]) ? 20 : 0) +
            matchingFieldScore(fields, terms: ["username", "wxid", "nickname", "remark", "alias", "avatar"], points: 12)

        scores[.conversation] =
            (containsAny(tableName, ["session", "conversation", "chat"]) ? 20 : 0) +
            matchingFieldScore(fields, terms: ["last_message", "unread", "peer", "conversation", "session"], points: 12) +
            matchingFieldScore(fields, terms: ["timestamp", "create_time", "time"], points: 5)

        scores[.group] =
            (containsAny(tableName, ["chatroom", "group", "member", "participant"]) ? 20 : 0) +
            matchingFieldScore(fields, terms: ["chatroom", "room", "member", "participant", "group"], points: 12)

        scores[.media] =
            (containsAny(tableName, ["media", "image", "video", "voice", "file", "thumbnail"]) ? 20 : 0) +
            matchingFieldScore(fields, terms: ["image", "video", "voice", "file", "media", "cdn", "path", "md5", "sha", "thumbnail"], points: 10)

        scores[.emoticon] = containsAny(tableName, ["emoticon", "sticker"]) ? 30 : 0
        scores[.favorite] = containsAny(tableName, ["favorite", "favitem"]) ? 30 : 0
        scores[.bizchat] = containsAny(tableName, ["bizchat", "biz_message"]) ? 30 : 0
        scores[.configuration] = containsAny(tableName, ["config", "setting", "general"]) ? 25 : 0
        return scores.filter { $0.value > 0 }
    }

    private func matchingFieldScore(_ fields: [String], terms: [String], points: Int) -> Int {
        fields.reduce(0) { total, field in total + (containsAny(field, terms) ? points : 0) }
    }

    private func containsAny(_ value: String, _ terms: [String]) -> Bool {
        terms.contains(where: value.contains)
    }
}

/// Scans plain SQLite databases from an explicitly selected export root. Every
/// database handle uses SQLITE_OPEN_READONLY; the scanner never reads rows or
/// text samples, only schema metadata and aggregate counts.
public struct SQLiteSchemaScanner: Sendable {
    public init() {}

    public func scan(
        exportRoot: URL,
        progress: (@Sendable (SQLiteSchemaScanProgress) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> SQLiteSchemaDiscoveryReport {
        let root = try resolvedExportRoot(exportRoot)
        let discovered = try discoverDatabases(below: root)
        var databases = [SQLiteDatabaseInfo]()
        var failures = [SQLiteSchemaInspectionFailure]()

        for (offset, item) in discovered.enumerated() {
            if shouldCancel?() == true { throw CancellationError() }
            progress?(SQLiteSchemaScanProgress(
                completedDatabaseCount: offset,
                totalDatabaseCount: discovered.count,
                currentRelativePath: item.relativePath
            ))
            do {
                databases.append(try inspect(item, shouldCancel: shouldCancel))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(SQLiteSchemaInspectionFailure(relativePath: item.relativePath))
            }
            progress?(SQLiteSchemaScanProgress(
                completedDatabaseCount: offset + 1,
                totalDatabaseCount: discovered.count,
                currentRelativePath: item.relativePath
            ))
        }

        let sortedDatabases = databases.sorted { $0.relativePath < $1.relativePath }
        let classifier = WeChatDatabaseClassifier()
        let candidates = sortedDatabases
            .flatMap { classifier.tableCandidates(databaseRelativePath: $0.relativePath, tables: $0.tables) }
            .sorted {
                $0.score == $1.score
                    ? ($0.databaseRelativePath, $0.tableName, $0.category.rawValue) < ($1.databaseRelativePath, $1.tableName, $1.category.rawValue)
                    : $0.score > $1.score
            }
        return SQLiteSchemaDiscoveryReport(
            discoveredDatabaseCount: discovered.count,
            databases: sortedDatabases,
            failures: failures.sorted { $0.relativePath < $1.relativePath },
            schemaGroups: schemaGroups(for: sortedDatabases),
            tableCandidates: candidates
        )
    }

    private func resolvedExportRoot(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func discoverDatabases(below root: URL) throws -> [(url: URL, relativePath: String)] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw ArchiveError.ioFailure
        }

        var results = [(url: URL, relativePath: String)]()
        for case let candidate as URL in enumerator {
            let values = try? candidate.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(resolved, of: root), resolved.pathExtension.lowercased() == "db",
                  let relativePath = relativePath(of: resolved, below: root) else {
                continue
            }
            results.append((resolved, relativePath))
        }
        return results.sorted { $0.relativePath < $1.relativePath }
    }

    private func inspect(
        _ item: (url: URL, relativePath: String),
        shouldCancel: (@Sendable () -> Bool)?
    ) throws -> SQLiteDatabaseInfo {
        let values = try item.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else { throw ArchiveError.invalidInput }
        let database = try SQLiteReadOnlyDatabase(url: item.url)
        let master = try database.masterEntries()
        let tableEntries = master.filter { $0.type == "table" }
        let ftsVirtualTableNames = Set(tableEntries
            .filter { isVirtualTableSQL($0.sql) && $0.sql.lowercased().contains("using fts") }
            .map { $0.name.lowercased() })

        var tables = [SQLiteTableInfo]()
        for entry in tableEntries.sorted(by: { $0.name < $1.name }) {
            if shouldCancel?() == true { throw CancellationError() }
            let isVirtual = isVirtualTableSQL(entry.sql)
            let isFTSShadow = isFTSShadowTable(entry.name, ftsVirtualTableNames: ftsVirtualTableNames)
            let columns = try database.columns(for: entry.name)
            let indexes = try database.indexes(for: entry.name)
            let foreignKeys = try database.foreignKeys(for: entry.name)
            let count = (isVirtual || isFTSShadow) ? nil : try database.rowCount(for: entry.name)
            tables.append(SQLiteTableInfo(
                name: entry.name,
                rowCount: count,
                columns: columns,
                indexes: indexes,
                foreignKeys: foreignKeys,
                isVirtual: isVirtual,
                isFTSShadowTable: isFTSShadow
            ))
        }

        let classification = WeChatDatabaseClassifier().classify(relativePath: item.relativePath, tables: tables)
        return SQLiteDatabaseInfo(
            relativePath: item.relativePath,
            fileSize: Int64(fileSize),
            sqliteVersion: try database.sqliteVersion(),
            pageCount: try database.pragmaInt("page_count"),
            pageSize: try database.pragmaInt("page_size"),
            tableCount: tables.count,
            indexCount: master.filter { $0.type == "index" }.count,
            viewCount: master.filter { $0.type == "view" }.count,
            triggerCount: master.filter { $0.type == "trigger" }.count,
            tables: tables,
            classification: classification,
            schemaFingerprint: try schemaFingerprint(for: tables)
        )
    }

    private func schemaGroups(for databases: [SQLiteDatabaseInfo]) -> [SQLiteSchemaGroup] {
        let grouped = Dictionary(grouping: databases, by: \.schemaFingerprint)
        return grouped.map { fingerprint, members in
            let ordered = members.sorted { $0.relativePath < $1.relativePath }
            return SQLiteSchemaGroup(
                fingerprint: fingerprint,
                representativePath: ordered[0].relativePath,
                relativePaths: ordered.map(\.relativePath),
                classification: ordered[0].classification
            )
        }
        .sorted { $0.representativePath < $1.representativePath }
    }

    private func schemaFingerprint(for tables: [SQLiteTableInfo]) throws -> String {
        struct FingerprintColumn: Codable {
            let name: String
            let type: String
            let nullable: Bool
            let primaryKeyPosition: Int
            let hasDefaultValue: Bool
        }
        struct FingerprintIndex: Codable {
            let columns: [String]
            let isUnique: Bool
        }
        struct FingerprintForeignKey: Codable {
            let columns: [String]
            let referencedTable: String
            let referencedColumns: [String]
            let onUpdate: String
            let onDelete: String
        }
        struct FingerprintTable: Codable {
            let name: String
            let columns: [FingerprintColumn]
            let indexes: [FingerprintIndex]
            let foreignKeys: [FingerprintForeignKey]
            let isVirtual: Bool
            let isFTSShadowTable: Bool
        }
        let fingerprintTables = tables.sorted { $0.name < $1.name }.map { table in
            FingerprintTable(
                name: table.name,
                columns: table.columns.map {
                    FingerprintColumn(
                        name: $0.name,
                        type: $0.declaredType,
                        nullable: $0.isNullable,
                        primaryKeyPosition: $0.primaryKeyPosition,
                        hasDefaultValue: $0.hasDefaultValue
                    )
                },
                indexes: table.indexes.sorted { $0.name < $1.name }.map {
                    FingerprintIndex(columns: $0.columns, isUnique: $0.isUnique)
                },
                foreignKeys: table.foreignKeys.sorted { $0.id < $1.id }.map {
                    FingerprintForeignKey(
                        columns: $0.columns,
                        referencedTable: $0.referencedTable,
                        referencedColumns: $0.referencedColumns,
                        onUpdate: $0.onUpdate,
                        onDelete: $0.onDelete
                    )
                },
                isVirtual: table.isVirtual,
                isFTSShadowTable: table.isFTSShadowTable
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fingerprintTables)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isVirtualTableSQL(_ sql: String) -> Bool {
        sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("create virtual table")
    }

    private func isFTSShadowTable(_ name: String, ftsVirtualTableNames: Set<String>) -> Bool {
        let lowerName = name.lowercased()
        let suffixes = ["_data", "_idx", "_content", "_docsize", "_config", "_segments", "_segdir", "_stat"]
        return ftsVirtualTableNames.contains { virtualName in
            guard lowerName.hasPrefix(virtualName + "_") else { return false }
            return suffixes.contains(where: { lowerName.hasSuffix($0) })
        }
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        return url.path().hasPrefix(rootPath)
    }

    private func relativePath(of url: URL, below root: URL) -> String? {
        let rootPath = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        guard url.path().hasPrefix(rootPath) else { return nil }
        let value = String(url.path().dropFirst(rootPath.count))
        guard !value.isEmpty, !value.hasPrefix("/"), !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        return value
    }
}

private final class SQLiteReadOnlyDatabase {
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

    func sqliteVersion() throws -> String {
        try scalarString("SELECT sqlite_version()")
    }

    func pragmaInt(_ name: String) throws -> Int64 {
        try scalarInt("PRAGMA \(name)")
    }

    func masterEntries() throws -> [SQLiteMasterEntry] {
        try rows("""
        SELECT type, name, COALESCE(sql, '')
        FROM sqlite_master
        WHERE type IN ('table', 'index', 'view', 'trigger')
          AND name NOT LIKE 'sqlite_%'
        ORDER BY type, name
        """) { statement in
            SQLiteMasterEntry(
                type: self.string(statement, at: 0) ?? "",
                name: self.string(statement, at: 1) ?? "",
                sql: self.string(statement, at: 2) ?? ""
            )
        }
    }

    func columns(for table: String) throws -> [SQLiteColumnInfo] {
        try rows("PRAGMA table_info(\(quoteIdentifier(table)))") { statement in
            let primaryKeyPosition = Int(sqlite3_column_int64(statement, 5))
            let notNull = sqlite3_column_int64(statement, 3) != 0
            return SQLiteColumnInfo(
                name: self.string(statement, at: 1) ?? "",
                declaredType: self.string(statement, at: 2) ?? "",
                isNullable: !notNull && primaryKeyPosition == 0,
                primaryKeyPosition: primaryKeyPosition,
                hasDefaultValue: sqlite3_column_type(statement, 4) != SQLITE_NULL
            )
        }
    }

    func indexes(for table: String) throws -> [SQLiteIndexInfo] {
        let entries: [(name: String, isUnique: Bool)] = try rows("PRAGMA index_list(\(quoteIdentifier(table)))") { statement in
            (self.string(statement, at: 1) ?? "", sqlite3_column_int64(statement, 2) != 0)
        }
        return try entries.map { entry in
            let columns: [String] = try rows("PRAGMA index_info(\(quoteIdentifier(entry.name)))") { statement in
                self.string(statement, at: 2) ?? ""
            }
            return SQLiteIndexInfo(name: entry.name, columns: columns, isUnique: entry.isUnique)
        }
    }

    func foreignKeys(for table: String) throws -> [SQLiteForeignKeyInfo] {
        struct ForeignKeyPart {
            let id: Int
            let sequence: Int
            let referencedTable: String
            let column: String
            let referencedColumn: String
            let onUpdate: String
            let onDelete: String
        }
        let parts: [ForeignKeyPart] = try rows("PRAGMA foreign_key_list(\(quoteIdentifier(table)))") { statement in
            ForeignKeyPart(
                id: Int(sqlite3_column_int64(statement, 0)),
                sequence: Int(sqlite3_column_int64(statement, 1)),
                referencedTable: self.string(statement, at: 2) ?? "",
                column: self.string(statement, at: 3) ?? "",
                referencedColumn: self.string(statement, at: 4) ?? "",
                onUpdate: self.string(statement, at: 5) ?? "",
                onDelete: self.string(statement, at: 6) ?? ""
            )
        }
        return Dictionary(grouping: parts, by: \.id).map { id, members in
            let ordered = members.sorted { $0.sequence < $1.sequence }
            return SQLiteForeignKeyInfo(
                id: id,
                columns: ordered.map(\.column),
                referencedTable: ordered[0].referencedTable,
                referencedColumns: ordered.map(\.referencedColumn),
                onUpdate: ordered[0].onUpdate,
                onDelete: ordered[0].onDelete
            )
        }
        .sorted { $0.id < $1.id }
    }

    func rowCount(for table: String) throws -> Int64 {
        try scalarInt("SELECT COUNT(*) FROM \(quoteIdentifier(table))")
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let values: [Int64] = try rows(sql) { sqlite3_column_int64($0, 0) }
        guard let value = values.first else { throw ArchiveError.databaseFailure }
        return value
    }

    private func scalarString(_ sql: String) throws -> String {
        let values: [String] = try rows(sql) { self.string($0, at: 0) ?? "" }
        guard let value = values.first else { throw ArchiveError.databaseFailure }
        return value
    }

    private func rows<T>(_ sql: String, map: (OpaquePointer?) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArchiveError.databaseFailure
        }
        defer { sqlite3_finalize(statement) }
        var values = [T]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                values.append(try map(statement))
            } else if status == SQLITE_DONE {
                return values
            } else {
                throw ArchiveError.databaseFailure
            }
        }
    }

    private func string(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func requireHandle() -> OpaquePointer? { handle }

    private func quoteIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private struct SQLiteMasterEntry {
    let type: String
    let name: String
    let sql: String
}
