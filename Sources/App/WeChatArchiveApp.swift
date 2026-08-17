#if canImport(SwiftUI)
import AppKit
import SwiftUI
import WeChatArchiveCore

@main
struct WeChatArchiveApp: App {
    var body: some Scene {
        WindowGroup {
            ArchiveShellView()
        }
        .windowStyle(.automatic)
        Settings {
            SettingsView()
        }
    }
}

private enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case archive = "Archive"
    case databaseExport = "Database Export"
    case schemaDiscovery = "Schema Discovery"
    case messageDiscovery = "Message Discovery"
    case archiveImport = "Archive Export"
    case archiveViewer = "Archive Viewer"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .databaseExport: "cylinder.split.1x2"
        case .schemaDiscovery: "magnifyingglass.circle"
        case .messageDiscovery: "text.magnifyingglass"
        case .archiveImport: "square.and.arrow.down.on.square"
        case .archiveViewer: "rectangle.split.3x1"
        case .settings: "gearshape"
        }
    }
}

private struct ArchiveShellView: View {
    @State private var section: AppSection? = .archive

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("WeChat Archive")
        } detail: {
            switch section ?? .archive {
            case .archive: DashboardView()
            case .databaseExport: DatabaseExportView()
            case .schemaDiscovery: SchemaDiscoveryView()
            case .messageDiscovery: MessageDiscoveryView()
            case .archiveImport: ArchiveImportView()
            case .archiveViewer: ArchiveViewerView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

private struct DashboardView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("WeChat Archive").font(.largeTitle.bold())
                Text("本机导出普通 SQLite，发现数据库结构，并可一次性完整导出可离线查看的私有 Archive。")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    StatisticCard(value: "3C", label: "Current phase", symbol: "square.and.arrow.down.on.square")
                    StatisticCard(value: "Local", label: "Processing", symbol: "macbook")
                    StatisticCard(value: "0", label: "Network uploads", symbol: "network.slash")
                    StatisticCard(value: "Lossless", label: "Archive exports", symbol: "archivebox")
                }
                GroupBox("Current Scope") {
                    HStack {
                        Image(systemName: "checkmark.shield").foregroundStyle(.green)
                        Text("Archive Export 会逐行保存全部 SQLite source values，支持文本、图片、视频、语音与未知消息；Archive Viewer 可在不依赖微信源数据的情况下离线查看。")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(32)
        }
        .navigationTitle("Archive")
    }
}

private struct StatisticCard: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.title.bold())
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DatabaseExportView: View {
    @State private var session = DatabaseExportSession()
    @State private var databaseRootPath = ""
    @State private var exportRoot: URL?
    @State private var isWorking = false
    @State private var status = "完全退出微信后，选择数据库根目录和 all_keys.json。"

    private var summary: WeChatDatabaseExportSummary {
        WeChatDatabaseExportSummary(databases: session.databases)
    }

    private var canScan: Bool {
        session.databaseRoot != nil && session.keyMapURL != nil && !isWorking
    }

    var body: some View {
        Form {
            Section("WeChat Database Export") {
                LabeledContent("Database Directory") {
                    if let databaseRoot = session.databaseRoot {
                        Label(databaseRoot.path(), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("Not selected").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Choose Folder", action: chooseDatabaseDirectory)
                    TextField("Paste absolute db_storage path", text: $databaseRootPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useEnteredDatabaseDirectory)
                    Button("Use Path", action: useEnteredDatabaseDirectory)
                }
                .disabled(isWorking)
                Text("若文件选择器无法进入容器目录，可粘贴完整的绝对路径，例如 `/Users/你/.../db_storage`，然后点击 Use Path。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("Key Map") {
                    if let keyMapURL = session.keyMapURL {
                        Label(displayPath(keyMapURL), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("Not selected").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Use ~/.wx-cli/all_keys.json", action: useDefaultKeyMap)
                    Button("Choose File", action: chooseKeyMap)
                }
                .disabled(isWorking)
                Text("导出前请完全退出微信，避免遗漏尚未 checkpoint 的 WAL 数据。all_keys.json 仅在内存读取，不会复制到导出目录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label(canScan ? "Ready to scan" : "Choose a database directory and key map", systemImage: canScan ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(canScan ? .green : .secondary)
                Button(isWorking ? "Working…" : "Scan", action: scan)
                    .disabled(!canScan)
            }

            Section("Scan Results") {
                HStack(spacing: 18) {
                    SummaryValue(label: "Databases", value: summary.detected)
                    SummaryValue(label: "Matched Keys", value: summary.matched)
                    SummaryValue(label: "Missing Keys", value: summary.missingKeys)
                }
                if !session.databases.isEmpty {
                    List(session.databases) { database in
                        DatabaseResultRow(database: database)
                    }
                    .frame(minHeight: 150, maxHeight: 280)
                }
                Button(isWorking ? "Working…" : "Validate All", action: validateAll)
                    .disabled(!session.databases.contains(where: \.hasAvailableKey) || isWorking)
            }

            Section("Export") {
                LabeledContent("Export Directory") {
                    Text(exportRoot?.lastPathComponent ?? "Not selected").foregroundStyle(.secondary)
                }
                Button("Choose Export Folder", action: chooseExportDirectory)
                    .disabled(isWorking)
                Text("输出目录和新建子目录权限为 0700，导出的普通 SQLite 数据库权限为 0600。已有同名文件会跳过，绝不覆盖。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(isWorking ? "Working…" : "Export Databases", action: exportDatabases)
                    .disabled(exportRoot == nil || !session.databases.contains(where: {
                        $0.validationStatus == .valid && $0.hasAvailableKey
                    }) || isWorking)
            }

            Section("Report") {
                HStack(spacing: 18) {
                    SummaryValue(label: "Validated", value: summary.validated)
                    SummaryValue(label: "Invalid", value: summary.invalid)
                    SummaryValue(label: "Exported", value: summary.exported)
                    SummaryValue(label: "Export Failed", value: summary.exportFailed)
                }
                Text(status).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("WeChat Database Export")
    }

    private func chooseDatabaseDirectory() {
        let panel = directoryPanel(message: "选择本人有权访问的微信 db_storage 目录")
        if panel.runModal() == .OK, let url = panel.url {
            setDatabaseRoot(url)
        }
    }

    private func useEnteredDatabaseDirectory() {
        do {
            try setDatabaseRoot(LocalDatabaseDirectoryPath.resolve(databaseRootPath))
        } catch {
            status = "路径必须是一个存在的本地绝对目录。"
        }
    }

    private func setDatabaseRoot(_ url: URL) {
        let defaultKeyMapURL = DefaultWXCLIKeyMapLocator().locate()
        session.selectDatabaseDirectory(url, defaultKeyMapURL: defaultKeyMapURL)
        databaseRootPath = session.databaseRoot?.path() ?? ""
        status = session.keyMapURL == nil
            ? "Database directory selected. Please choose all_keys.json."
            : "Database directory and wx-cli key map ready. Click Scan."
    }

    private func useDefaultKeyMap() {
        guard let keyMapURL = DefaultWXCLIKeyMapLocator().locate() else {
            status = "未找到默认 all_keys.json；请选择你本人保存的 key map 文件。"
            return
        }
        session.selectKeyMap(keyMapURL)
        status = session.databaseRoot == nil
            ? "已选择默认 key map；请选择数据库目录。"
            : "Database directory and wx-cli key map ready. Click Scan."
    }

    private func chooseKeyMap() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "选择 wx-cli 生成的 all_keys.json"
        if panel.runModal() == .OK {
            if let keyMapURL = panel.url {
                session.selectKeyMap(keyMapURL)
                status = session.databaseRoot == nil
                    ? "key map 已选择；请选择数据库目录。"
                    : "Database directory and wx-cli key map ready. Click Scan."
            }
        }
    }

    private func chooseExportDirectory() {
        let panel = directoryPanel(message: "选择普通 SQLite 数据库的导出目录")
        if panel.runModal() == .OK {
            exportRoot = panel.url
            status = "导出目录已选择；验证完成后可导出。"
        }
    }

    private func scan() {
        guard let databaseRoot = session.databaseRoot, let keyMapURL = session.keyMapURL else { return }
        isWorking = true
        status = "Scanning…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                BatchOperationResult { () throws in
                    let keyMap = try WXCLIKeyMapProvider(url: keyMapURL)
                    return try WeChatDatabaseScanner().scan(databaseRoot: databaseRoot, keyMap: keyMap)
                }
            }.value
            apply(result, success: "Scan complete")
        }
    }

    private func validateAll() {
        guard !session.databases.isEmpty else { return }
        let input = session.databases
        isWorking = true
        status = "Validating…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                BatchOperationResult { () throws in
                    let decryptor = try SQLCipherDatabaseDecryptor()
                    return WeChatDatabaseExportCoordinator(decryptor: decryptor).validateAll(input)
                }
            }.value
            apply(result, success: "Validation complete")
        }
    }

    private func exportDatabases() {
        guard let exportRoot else { return }
        let input = session.databases
        isWorking = true
        status = "Exporting…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                BatchOperationResult { () throws in
                    let decryptor = try SQLCipherDatabaseDecryptor()
                    return try WeChatDatabaseExportCoordinator(decryptor: decryptor)
                        .exportValidatedDatabases(input, to: exportRoot)
                }
            }.value
            apply(result, success: "Export complete")
        }
    }

    private func apply(_ result: BatchOperationResult, success: String) {
        if let databases = result.databases {
            session.setDatabases(databases)
            let summary = WeChatDatabaseExportSummary(databases: databases)
            status = "\(success). Detected: \(summary.detected), Matched: \(summary.matched), Validated: \(summary.validated), Exported: \(summary.exported)."
        } else {
            status = result.failureMessage ?? "Local database operation failed."
        }
        isWorking = false
    }

    private func directoryPanel(message: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        return panel
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.path()
        let home = FileManager.default.homeDirectoryForCurrentUser.path()
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

private struct SchemaDiscoveryView: View {
    @State private var exportRoot: URL?
    @State private var exportRootPath = ""
    @State private var report: SQLiteSchemaDiscoveryReport?
    @State private var reportDirectory: URL?
    @State private var progress: SQLiteSchemaScanProgress?
    @State private var isWorking = false
    @State private var status = "Choose the Phase 1 plain SQLite export directory. No key map is needed."

    private var canAnalyze: Bool {
        exportRoot != nil && !isWorking
    }

    var body: some View {
        Form {
            Section("Schema Discovery") {
                LabeledContent("Plain SQLite Directory") {
                    if let exportRoot {
                        Label(displayRelativePath(exportRoot), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("Not selected").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Choose Folder", action: chooseExportRoot)
                    TextField("Paste absolute export path", text: $exportRootPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useEnteredExportRoot)
                    Button("Use Path", action: useEnteredExportRoot)
                }
                .disabled(isWorking)
                Text("选择第一阶段生成的普通 SQLite 根目录。分析只以只读方式打开 `*.db`，不需要 all_keys.json 或密钥。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(isWorking ? "Analyzing…" : "Analyze Databases", action: analyze)
                    .disabled(!canAnalyze)
                if let progress, isWorking {
                    Label(
                        "\(progress.completedDatabaseCount) / \(progress.totalDatabaseCount) databases — \(redactedRelativePath(progress.currentRelativePath))",
                        systemImage: "cylinder.split.1x2"
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }

            if let report {
                Section("Analysis Complete") {
                    HStack(spacing: 18) {
                        SummaryValue(label: "Databases", value: report.summary.databaseCount)
                        SummaryValue(label: "Tables", value: report.summary.tableCount)
                        SummaryValue(label: "Schema Groups", value: report.schemaGroups.count)
                        SummaryValue(label: "Rows", value: report.summary.rowCount)
                    }
                    HStack(spacing: 18) {
                        SummaryValue(label: "Messages", value: report.summary.messageDatabases)
                        SummaryValue(label: "Contacts", value: report.summary.contactDatabases)
                        SummaryValue(label: "Sessions", value: report.summary.conversationDatabases)
                        SummaryValue(label: "Media", value: report.summary.mediaDatabases)
                        SummaryValue(label: "Unknown", value: report.summary.unknownDatabases)
                    }
                    if let reportDirectory {
                        Button("Open Report Folder") {
                            NSWorkspace.shared.open(reportDirectory)
                        }
                    }
                    Text("Reports contain schema names, declared types, constraints, indexes, foreign keys and aggregate row counts only. They do not include text samples, BLOB data, contact values or keys.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Database List") {
                    List(report.databases) { database in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(redactedRelativePath(database.relativePath)).textSelection(.enabled)
                            Text("\(database.classification.displayName) · \(database.rowCount) rows · \(database.tableCount) tables")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 180, maxHeight: 320)
                    if !report.failures.isEmpty {
                        Text("\(report.failures.count) database(s) could not be inspected as plain SQLite. Their paths are listed only in the local report.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Status") {
                Text(status).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Schema Discovery")
    }

    private func chooseExportRoot() {
        let panel = directoryPanel(message: "选择第一阶段导出的普通 SQLite 根目录")
        if panel.runModal() == .OK, let url = panel.url {
            setExportRoot(url)
        }
    }

    private func useEnteredExportRoot() {
        do {
            try setExportRoot(LocalDatabaseDirectoryPath.resolve(exportRootPath))
        } catch {
            status = "路径必须是一个存在的本地绝对目录。"
        }
    }

    private func setExportRoot(_ url: URL) {
        exportRoot = url.standardizedFileURL
        exportRootPath = exportRoot?.path() ?? ""
        report = nil
        reportDirectory = nil
        progress = nil
        status = "Plain SQLite directory selected. Click Analyze Databases."
    }

    private func analyze() {
        guard let exportRoot else { return }
        isWorking = true
        report = nil
        reportDirectory = nil
        progress = nil
        status = "Analyzing database schemas…"
        var continuation: AsyncStream<SQLiteSchemaScanProgress>.Continuation?
        let stream = AsyncStream<SQLiteSchemaScanProgress>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        guard let continuation else {
            isWorking = false
            status = "Could not start schema analysis."
            return
        }
        let outputDirectory = exportRoot.appending(path: "SchemaReports")
        let worker = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return SchemaDiscoveryOperationResult(
                exportRoot: exportRoot,
                outputDirectory: outputDirectory,
                progress: { continuation.yield($0) },
                shouldCancel: { Task.isCancelled }
            )
        }
        Task { @MainActor in
            for await update in stream {
                progress = update
            }
        }
        Task { @MainActor in
            let result = await worker.value
            report = result.report
            reportDirectory = result.reportDirectory
            progress = nil
            status = result.status
            isWorking = false
        }
    }

    private func directoryPanel(message: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = message
        return panel
    }

    private func displayRelativePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path()
        let path = url.path()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func redactedRelativePath(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                let value = String(component)
                let lower = value.lowercased()
                return lower.hasPrefix("wxid_") || lower.hasPrefix("wxid-") ? "<redacted>" : value
            }
            .joined(separator: "/")
    }
}

private struct SchemaDiscoveryOperationResult: Sendable {
    let report: SQLiteSchemaDiscoveryReport?
    let reportDirectory: URL?
    let status: String

    init(
        exportRoot: URL,
        outputDirectory: URL,
        progress: @escaping @Sendable (SQLiteSchemaScanProgress) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool
    ) {
        do {
            let report = try SQLiteSchemaScanner().scan(
                exportRoot: exportRoot,
                progress: progress,
                shouldCancel: shouldCancel
            )
            let locations = try SQLiteSchemaReportWriter().write(report, to: outputDirectory)
            self.report = report
            reportDirectory = locations.directoryURL
            status = "Analysis complete. \(report.summary.databaseCount) databases, \(report.summary.tableCount) tables, \(report.schemaGroups.count) schema groups."
        } catch is CancellationError {
            report = nil
            reportDirectory = nil
            status = "Schema analysis cancelled."
        } catch {
            report = nil
            reportDirectory = nil
            status = "Schema analysis could not complete. Verify that the selected folder contains plain SQLite databases."
        }
    }
}

private struct BatchOperationResult: Sendable {
    let databases: [ScannedWeChatDatabase]?
    let failureMessage: String?

    init(_ operation: () throws -> [ScannedWeChatDatabase]) {
        do {
            databases = try operation()
            failureMessage = nil
        } catch let error as ArchiveError {
            databases = nil
            switch error {
            case .decryptionRuntimeUnavailable:
                failureMessage = "SQLCipher runtime unavailable. Run: brew bundle"
            case .databaseInUse:
                failureMessage = "Database is in use. Please quit WeChat and try again."
            case .keyInvalid:
                failureMessage = "Key map is invalid."
            default:
                failureMessage = "Local database operation failed."
            }
        } catch {
            databases = nil
            failureMessage = "Local database operation failed."
        }
    }
}

struct SummaryValue: View {
    let label: String
    let value: String

    init(label: String, value: Int) {
        self.label = label
        self.value = "\(value)"
    }

    init(label: String, value: Int64) {
        self.label = label
        self.value = "\(value)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DatabaseResultRow: View {
    let database: ScannedWeChatDatabase

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(database.relativePath).lineLimit(1)
            Spacer()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch database.exportStatus {
        case .exported: "checkmark.circle.fill"
        case .destinationExists: "arrow.uturn.right.circle"
        case .failed: "xmark.octagon.fill"
        case .skippedMissingKey: "key.slash"
        case .skippedInvalid: "xmark.circle"
        case .skippedNotValidated: "exclamationmark.circle"
        case .notExported:
            switch database.validationStatus {
            case .valid: "checkmark.circle"
            case .invalid: "xmark.circle"
            case .missingKey: "key.slash"
            case .notValidated: database.hasMatchedKey ? "key.fill" : "key.slash"
            }
        }
    }

    private var color: Color {
        switch database.exportStatus {
        case .exported: .green
        case .failed, .skippedInvalid: .red
        case .destinationExists, .skippedMissingKey, .skippedNotValidated: .orange
        case .notExported: database.validationStatus == .valid ? .green : .secondary
        }
    }

    private var label: String {
        switch database.exportStatus {
        case .exported: "Exported"
        case .destinationExists: "Destination exists"
        case .failed: "Export failed"
        case .skippedMissingKey: "Key missing"
        case .skippedInvalid: "Key invalid"
        case .skippedNotValidated: "Validate first"
        case .notExported:
            switch database.validationStatus {
            case .valid: "Valid"
            case .invalid: "Key invalid"
            case .missingKey: "Key missing"
            case .notValidated: database.hasMatchedKey ? "Key matched" : "Key missing"
            }
        }
    }
}

private struct SettingsView: View {
    var body: some View {
        Form {
            Section("Privacy") {
                Label("聊天记录不会发送到服务器。", systemImage: "lock.shield")
                Label("数据库密钥不会发送到服务器。", systemImage: "key.slash")
                Label("应用没有后台上传、遥测或崩溃报告上传服务。", systemImage: "network.slash")
            }
            Section("Backup") {
                Text("建议采用 3-2-1：Mac 本地归档 + 外部磁盘/NAS + 一份离线备份。")
            }
            Section("Appearance") {
                Text("界面遵循 macOS 系统浅色、深色或自动主题，并支持键盘导航和 VoiceOver。")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
    }
}

private struct EmptyStateView: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .navigationTitle(title)
    }
}
#else
import Foundation

@main
struct WeChatArchiveApp {
    static func main() { print("WeChat Archive requires macOS SwiftUI.") }
}
#endif
