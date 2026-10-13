import Darwin
import Foundation
import WeChatArchiveCore

/// Uses the same in-process SQLCipher and archive implementation as the app.
/// No key literal is passed to a subprocess or included in terminal output.
@main
enum WeChatArchiveCLI {
    private struct Options {
        let action: String
        let source: URL
        let keys: URL?
        let report: URL
        let output: URL?
        let account: URL?
        let archive: URL?
        let allowedMissing: Set<String>
        let limit: Int?
        let configureViewer: Bool

        init(_ arguments: [String]) throws {
            guard let action = arguments.first, ["validate", "archive", "import-plain"].contains(action) else {
                throw ArchiveError.invalidInput
            }
            self.action = action
            var values: [String: String] = [:]
            var missing = Set<String>()
            var configure = false
            var index = 1
            while index < arguments.count {
                let name = arguments[index]
                if name == "--configure-viewer" {
                    guard !configure else { throw ArchiveError.invalidInput }
                    configure = true; index += 1; continue
                }
                guard ["--db-dir", "--keys", "--report", "--output", "--account-root", "--archive-output", "--allow-missing", "--limit"].contains(name),
                      index + 1 < arguments.count else { throw ArchiveError.invalidInput }
                let value = arguments[index + 1]
                if name == "--allow-missing" {
                    guard !value.hasPrefix("/"), value.hasSuffix(".db"), !value.contains("\\"),
                          !value.contains(where: { "*?[".contains($0) }),
                          value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                        throw ArchiveError.invalidInput
                    }
                    missing.insert(value)
                } else {
                    guard values.updateValue(value, forKey: name) == nil else { throw ArchiveError.invalidInput }
                }
                index += 2
            }
            func url(_ name: String) throws -> URL {
                guard let path = values[name], path.hasPrefix("/") else { throw ArchiveError.invalidInput }
                return URL(fileURLWithPath: path, isDirectory: ["--db-dir", "--output", "--account-root", "--archive-output"].contains(name)).standardizedFileURL
            }
            source = try LocalDatabaseDirectoryPath.resolve(url("--db-dir").path())
            if action == "import-plain" {
                guard values["--keys"] == nil, values["--output"] == nil, missing.isEmpty else { throw ArchiveError.invalidInput }
                keys = nil
            } else { keys = try url("--keys") }
            report = try url("--report")
            allowedMissing = missing
            configureViewer = configure
            if let value = values["--limit"] {
                guard let count = Int(value), count > 0 else { throw ArchiveError.invalidInput }
                limit = count
            } else { limit = nil }
            if action == "archive" || action == "import-plain" {
                output = action == "archive" ? try url("--output") : nil
                account = try LocalDatabaseDirectoryPath.resolve(url("--account-root").path())
                archive = try url("--archive-output")
            } else {
                guard values["--output"] == nil, values["--account-root"] == nil, values["--archive-output"] == nil, limit == nil, !configure else {
                    throw ArchiveError.invalidInput
                }
                output = nil; account = nil; archive = nil
            }
        }
    }

    private struct Report: Encodable {
        var status = "failed"
        var stage = "scan"
        var detected = 0
        var matched = 0
        var validated = 0
        var invalid = 0
        var missingKeys = 0
        var missingDatabases: [String] = []
        var exported = 0
        var exportFailed = 0
        var archiveCreated = false
        var messagesImported = 0
        var keyCoverageChecked = true
        var completeCoverage: Bool { keyCoverageChecked && detected > 0 && validated == detected && missingKeys == 0 && invalid == 0 }

        enum CodingKeys: String, CodingKey {
            case status, stage, detected, matched, validated, invalid, missingKeys, missingDatabases
            case exported, exportFailed, archiveCreated, messagesImported, completeCoverage
            case keyCoverageChecked
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(status, forKey: .status)
            try values.encode(stage, forKey: .stage)
            try values.encode(detected, forKey: .detected)
            try values.encode(matched, forKey: .matched)
            try values.encode(validated, forKey: .validated)
            try values.encode(invalid, forKey: .invalid)
            try values.encode(missingKeys, forKey: .missingKeys)
            try values.encode(missingDatabases, forKey: .missingDatabases)
            try values.encode(exported, forKey: .exported)
            try values.encode(exportFailed, forKey: .exportFailed)
            try values.encode(archiveCreated, forKey: .archiveCreated)
            try values.encode(messagesImported, forKey: .messagesImported)
            try values.encode(completeCoverage, forKey: .completeCoverage)
            try values.encode(keyCoverageChecked, forKey: .keyCoverageChecked)
        }
    }

    static func main() {
        guard CommandLine.arguments.count > 1, CommandLine.arguments[1] != "--help" else {
            print("WeChatArchiveCLI validate --db-dir DIR --keys FILE --report FILE [--allow-missing RELATIVE.db]")
            print("WeChatArchiveCLI archive ... --output DIR --account-root DIR --archive-output DIR [--limit N]")
            print("WeChatArchiveCLI import-plain --db-dir PLAIN_ROOT --account-root DIR --archive-output NEW_DIR --report NEW_FILE [--limit N] [--configure-viewer]")
            return
        }
        umask(0o077)
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            try run(options)
        } catch {
            let text: String
            switch error as? ArchiveError {
            case .databaseInUse: text = "请完全退出微信后重试。"
            case .keyUnavailable: text = "缺少数据库密钥。默认停止；需要跳过时请逐项指定 --allow-missing。"
            case .keyInvalid: text = "数据库密钥验证未通过，未继续导出。"
            case .decryptionRuntimeUnavailable: text = "缺少 SQLCipher 运行时，请先运行 brew bundle。"
            default: text = "本地验证／导出失败，请检查参数、读取权限及本次结果报告。"
            }
            FileHandle.standardError.write(Data((text + "\n").utf8))
            exit(1)
        }
    }

    private static func requireWeChatExited() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-u", String(getuid()), "-x", "WeChat"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 1 else { throw ArchiveError.databaseInUse }
    }

    private static func disjoint(_ first: URL, _ second: URL) -> Bool {
        let a = first.resolvingSymlinksInPath().path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let b = second.resolvingSymlinksInPath().path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return a != b && !a.hasPrefix(b + "/") && !b.hasPrefix(a + "/")
    }

    private static func run(_ options: Options) throws {
        try requireWeChatExited()
        guard disjoint(options.report, options.source),
              options.account.map({ disjoint(options.report, $0) }) ?? true else { throw ArchiveError.invalidInput }
        let fd = open(options.report.path(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ArchiveError.ioFailure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var report = Report()
        report.keyCoverageChecked = options.action != "import-plain"
        do {
            try perform(options, report: &report)
        } catch {
            try? handle.write(contentsOf: JSONEncoder().encode(report))
            throw error
        }
        try handle.write(contentsOf: JSONEncoder().encode(report))
        try handle.synchronize()
    }

    private static func perform(_ options: Options, report: inout Report) throws {
        if options.action == "import-plain" {
            guard let account = options.account, let archive = options.archive,
                  disjoint(archive, options.source), disjoint(archive, account),
                  !FileManager.default.fileExists(atPath: archive.path()) else { throw ArchiveError.invalidInput }
            report.stage = "import"
            let summary = try WeChatArchiveV1Importer(imageKeyProvider: WeChatKVCommImageKeyProvider()).importArchive(
                plainSQLiteRoot: options.source, accountRoot: account, destinationRoot: archive,
                options: options.limit.map { ArchiveV1ImportOptions(limit: $0) } ?? .all,
                progress: { value in
                    if value.messagesImported.isMultiple(of: 10_000) {
                        print("已导入 \(value.messagesImported) 条；图片原始变体 \(value.imagesResolved)；媒体写入 \(value.mediaBytesCopied) 字节。")
                        fflush(stdout)
                    }
                })
            report.messagesImported = summary.messagesImported
            report.stage = "archive_verify"
            guard summary.status == .completed, try WeChatArchiveV1Validator().validate(at: archive).passed else { throw ArchiveError.invalidArchive }
            report.archiveCreated = true
            report.status = "completed"
            report.stage = "done"
            if options.configureViewer, let defaults = UserDefaults(suiteName: "com.taoking.wechatarchive") {
                let workspace = WorkspacePreferences(defaults: defaults)
                workspace.lastPlainSQLiteRoot = options.source
                workspace.lastAccountRoot = account
                workspace.lastArchiveParentDirectory = archive.deletingLastPathComponent()
                workspace.recordOpenedArchive(archive)
            }
            return
        }
        guard let keys = options.keys else { throw ArchiveError.invalidInput }
        let coordinator = WeChatDatabaseExportCoordinator(decryptor: try SQLCipherDatabaseDecryptor())
        let scanned = try WeChatDatabaseScanner().scan(databaseRoot: options.source, keyMap: WXCLIKeyMapProvider(url: keys))
        let valid = coordinator.validateAll(scanned)
        let counts = WeChatDatabaseExportSummary(databases: valid)
        report.detected = counts.detected; report.matched = counts.matched
        report.validated = counts.validated; report.invalid = counts.invalid; report.missingKeys = counts.missingKeys
        report.missingDatabases = valid.filter { $0.validationStatus == .missingKey }.map(\.relativePath)
        report.stage = "coverage"
        try DatabaseExportCoveragePolicy(allowedMissing: options.allowedMissing).check(valid)
        if options.action == "archive" {
            guard let output = options.output, let account = options.account, let archive = options.archive,
                  disjoint(output, options.source), disjoint(output, account),
                  disjoint(archive, options.source), disjoint(archive, account), disjoint(output, archive),
                  !FileManager.default.fileExists(atPath: output.path()),
                  !FileManager.default.fileExists(atPath: archive.path()) else { throw ArchiveError.invalidInput }
            try requireWeChatExited()
            report.stage = "export"
            let exported = try coordinator.exportValidatedDatabases(valid, to: output)
            report.exported = exported.filter { $0.exportStatus == .exported }.count
            report.exportFailed = exported.filter { $0.validationStatus == .valid && $0.exportStatus != .exported }.count
            guard report.exportFailed == 0, report.exported == report.validated else { throw ArchiveError.ioFailure }
            try requireWeChatExited()
            report.stage = "import"
            let imported = try WeChatArchiveV1Importer(imageKeyProvider: WeChatKVCommImageKeyProvider()).importArchive(
                plainSQLiteRoot: output, accountRoot: account, destinationRoot: archive,
                options: options.limit.map { ArchiveV1ImportOptions(limit: $0) } ?? .all)
            report.stage = "archive_verify"
            guard imported.status == .completed, try WeChatArchiveV1Validator().validate(at: archive).passed else {
                throw ArchiveError.invalidArchive
            }
            report.archiveCreated = true
            report.messagesImported = imported.messagesImported
            if options.configureViewer, let defaults = UserDefaults(suiteName: "com.taoking.wechatarchive") {
                let workspace = WorkspacePreferences(defaults: defaults)
                workspace.lastPlainSQLiteRoot = output
                workspace.lastAccountRoot = account
                workspace.lastArchiveParentDirectory = archive.deletingLastPathComponent()
                workspace.lastDatabaseStorageRoot = options.source
                workspace.lastPlainSQLiteExportParent = output.deletingLastPathComponent()
                workspace.lastKeyMapPath = keys
                workspace.lastConversationExportDirectory = archive.deletingLastPathComponent().deletingLastPathComponent().appending(path: "exports")
                workspace.recordOpenedArchive(archive)
            }
        }
        report.status = report.completeCoverage ? "completed" : "completed_with_allowed_missing"
        report.stage = "done"
    }

}
