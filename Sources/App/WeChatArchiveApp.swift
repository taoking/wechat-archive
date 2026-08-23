#if canImport(SwiftUI)
import AppKit
import SwiftUI
import WeChatArchiveCore

@main
struct WeChatArchiveApp: App {
    init() {
        ArchiveApplicationIcon.install()
    }

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

enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case archive = "归档概览"
    case databaseExport = "数据库导出"
    case schemaDiscovery = "结构发现"
    case messageDiscovery = "消息发现"
    case archiveImport = "归档导出"
    case archiveViewer = "归档查看器"
    case settings = "设置"

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

@MainActor
final class ArchiveWorkspace: ObservableObject {
    let preferences: WorkspacePreferences
    @Published var section: AppSection? = .archiveViewer

    init(preferences: WorkspacePreferences = .init()) {
        self.preferences = preferences
    }

    func openArchive(_ url: URL) {
        preferences.recordOpenedArchive(url)
        section = .archiveViewer
    }
}

private struct ArchiveShellView: View {
    @StateObject private var workspace = ArchiveWorkspace()

    var body: some View {
        NavigationSplitView {
            List(selection: $workspace.section) {
                ArchiveBrandHeader(compact: true)
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                Section("主要功能") {
                    navigationRow(.archiveViewer)
                    navigationRow(.archiveImport)
                }
                Section("高级工具") {
                    navigationRow(.databaseExport)
                    navigationRow(.schemaDiscovery)
                    navigationRow(.messageDiscovery)
                    navigationRow(.archive)
                    navigationRow(.settings)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ArchiveCanvas())
            .navigationTitle("微信聊天归档")
        } detail: {
            switch workspace.section ?? .archiveViewer {
            case .archive: DashboardView()
            case .databaseExport: DatabaseExportView(workspace: workspace)
            case .schemaDiscovery: SchemaDiscoveryView()
            case .messageDiscovery: MessageDiscoveryView()
            case .archiveImport: ArchiveImportView(workspace: workspace)
            case .archiveViewer: ArchiveViewerView(workspace: workspace)
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .tint(ArchivePalette.jade)
    }

    @ViewBuilder
    private func navigationRow(_ item: AppSection) -> some View {
        Label(item.rawValue, systemImage: item.symbol).tag(item)
    }
}

private struct DashboardView: View {
    var body: some View {
        ZStack {
            ArchiveCanvas()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 16) {
                        ArchiveBrandMark(size: 68)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("把聊天记忆留在自己手里").font(.largeTitle.bold())
                            Text("一次完整导出，之后无需微信也能离线查看、播放媒体并导出单个会话。")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .archiveCard()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    StatisticCard(value: "3C", label: "当前阶段", symbol: "square.and.arrow.down.on.square")
                    StatisticCard(value: "本机", label: "处理方式", symbol: "macbook")
                    StatisticCard(value: "0", label: "网络上传", symbol: "network.slash")
                    StatisticCard(value: "无损", label: "归档方式", symbol: "archivebox")
                }
                GroupBox("当前范围") {
                    HStack {
                        Image(systemName: "checkmark.shield").foregroundStyle(.green)
                        Text("归档导出会逐行保存全部 SQLite 原始字段，支持文本、图片、视频、语音与未知消息；归档查看器可在不依赖微信源数据的情况下离线查看。")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .archiveCard()
                }
                .padding(32)
            }
        }
        .navigationTitle("归档概览")
    }
}

private struct StatisticCard: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(ArchivePalette.jade)
            Text(value).font(.title.bold())
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DatabaseExportView: View {
    let workspace: ArchiveWorkspace
    @State private var session = DatabaseExportSession()
    @State private var databaseRootPath = ""
    @State private var exportRoot: URL?
    @State private var isWorking = false
    @State private var status = "完全退出微信后，选择数据库根目录和 all_keys.json。"
    @State private var restoredPersistedInputs = false

    private var summary: WeChatDatabaseExportSummary {
        WeChatDatabaseExportSummary(databases: session.databases)
    }

    private var canScan: Bool {
        session.databaseRoot != nil && session.keyMapURL != nil && !isWorking
    }

    var body: some View {
        Form {
            Section("微信数据库导出") {
                LabeledContent("数据库目录") {
                    if let databaseRoot = session.databaseRoot {
                        Label(databaseRoot.path(), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("未选择").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("选择文件夹", action: chooseDatabaseDirectory)
                    TextField("粘贴 db_storage 的绝对路径", text: $databaseRootPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useEnteredDatabaseDirectory)
                    Button("使用此路径", action: useEnteredDatabaseDirectory)
                }
                .disabled(isWorking)
                Text("若文件选择器无法进入容器目录，可粘贴完整的绝对路径，例如 `/Users/你/.../db_storage`，然后点击“使用此路径”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("密钥映射") {
                    if let keyMapURL = session.keyMapURL {
                        Label(displayPath(keyMapURL), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("未选择").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("使用 ~/.wx-cli/all_keys.json", action: useDefaultKeyMap)
                    Button("选择文件", action: chooseKeyMap)
                }
                .disabled(isWorking)
                Text("导出前请完全退出微信，避免遗漏尚未 checkpoint 的 WAL 数据。all_keys.json 仅在内存读取，不会复制到导出目录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label(canScan ? "可以扫描" : "请选择数据库目录和密钥映射", systemImage: canScan ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(canScan ? .green : .secondary)
                Button(isWorking ? "处理中…" : "扫描", action: scan)
                    .disabled(!canScan)
            }

            Section("扫描结果") {
                HStack(spacing: 18) {
                    SummaryValue(label: "数据库", value: summary.detected)
                    SummaryValue(label: "已匹配密钥", value: summary.matched)
                    SummaryValue(label: "缺少密钥", value: summary.missingKeys)
                }
                if !session.databases.isEmpty {
                    List(session.databases) { database in
                        DatabaseResultRow(database: database)
                    }
                    .frame(minHeight: 150, maxHeight: 280)
                }
                Button(isWorking ? "处理中…" : "全部验证", action: validateAll)
                    .disabled(!session.databases.contains(where: \.hasAvailableKey) || isWorking)
            }

            Section("导出") {
                LabeledContent("导出目录") {
                    Text(exportRoot?.lastPathComponent ?? "未选择").foregroundStyle(.secondary)
                }
                Button("选择导出文件夹", action: chooseExportDirectory)
                    .disabled(isWorking)
                Text("输出目录和新建子目录权限为 0700，导出的普通 SQLite 数据库权限为 0600。已有同名文件会跳过，绝不覆盖。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(isWorking ? "处理中…" : "导出数据库", action: exportDatabases)
                    .disabled(exportRoot == nil || !session.databases.contains(where: {
                        $0.validationStatus == .valid && $0.hasAvailableKey
                    }) || isWorking)
            }

            Section("报告") {
                HStack(spacing: 18) {
                    SummaryValue(label: "验证成功", value: summary.validated)
                    SummaryValue(label: "无效", value: summary.invalid)
                    SummaryValue(label: "已导出", value: summary.exported)
                    SummaryValue(label: "导出失败", value: summary.exportFailed)
                }
                Text(status).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("微信数据库导出")
        .onAppear(perform: restorePersistedInputsIfNeeded)
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
        databaseRootPath = session.databaseRoot?.path(percentEncoded: false) ?? ""
        workspace.preferences.lastDatabaseStorageRoot = session.databaseRoot
        if let defaultKeyMapURL { workspace.preferences.lastKeyMapPath = defaultKeyMapURL }
        status = session.keyMapURL == nil
            ? "已选择数据库目录。请选择 all_keys.json。"
            : "数据库目录与 wx-cli 密钥映射已就绪。请点击“扫描”。"
    }

    private func useDefaultKeyMap() {
        guard let keyMapURL = DefaultWXCLIKeyMapLocator().locate() else {
            status = "未找到默认 all_keys.json；请选择你本人保存的 key map 文件。"
            return
        }
        session.selectKeyMap(keyMapURL)
        workspace.preferences.lastKeyMapPath = keyMapURL
        status = session.databaseRoot == nil
            ? "已选择默认 key map；请选择数据库目录。"
            : "数据库目录与 wx-cli 密钥映射已就绪。请点击“扫描”。"
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
                workspace.preferences.lastKeyMapPath = keyMapURL
                status = session.databaseRoot == nil
                    ? "密钥映射已选择；请选择数据库目录。"
                    : "数据库目录与 wx-cli 密钥映射已就绪。请点击“扫描”。"
            }
        }
    }

    private func chooseExportDirectory() {
        let panel = directoryPanel(message: "选择普通 SQLite 数据库的导出目录")
        if panel.runModal() == .OK {
            exportRoot = panel.url
            workspace.preferences.lastPlainSQLiteExportParent = exportRoot
            status = "导出目录已选择；验证完成后可导出。"
        }
    }

    private func scan() {
        guard let databaseRoot = session.databaseRoot, let keyMapURL = session.keyMapURL else { return }
        isWorking = true
        status = "正在扫描…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                BatchOperationResult { () throws in
                    let keyMap = try WXCLIKeyMapProvider(url: keyMapURL)
                    return try WeChatDatabaseScanner().scan(databaseRoot: databaseRoot, keyMap: keyMap)
                }
            }.value
            apply(result, success: "扫描完成")
        }
    }

    private func validateAll() {
        guard !session.databases.isEmpty else { return }
        let input = session.databases
        isWorking = true
        status = "正在验证…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                BatchOperationResult { () throws in
                    let decryptor = try SQLCipherDatabaseDecryptor()
                    return WeChatDatabaseExportCoordinator(decryptor: decryptor).validateAll(input)
                }
            }.value
            apply(result, success: "验证完成")
        }
    }

    private func exportDatabases() {
        guard let exportRoot else { return }
        let input = session.databases
        isWorking = true
        status = "正在导出…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                BatchOperationResult { () throws in
                    let decryptor = try SQLCipherDatabaseDecryptor()
                    return try WeChatDatabaseExportCoordinator(decryptor: decryptor)
                        .exportValidatedDatabases(input, to: exportRoot)
                }
            }.value
            apply(result, success: "导出完成")
        }
    }

    private func apply(_ result: BatchOperationResult, success: String) {
        if let databases = result.databases {
            session.setDatabases(databases)
            let summary = WeChatDatabaseExportSummary(databases: databases)
            status = "\(success)。已发现：\(summary.detected)；已匹配：\(summary.matched)；已验证：\(summary.validated)；已导出：\(summary.exported)。"
        } else {
            status = result.failureMessage ?? "本地数据库操作失败。"
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
        let path = url.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Restores locations only. In particular this never opens all_keys.json;
    /// WXCLIKeyMapProvider is constructed exclusively from the Scan action.
    private func restorePersistedInputsIfNeeded() {
        guard !restoredPersistedInputs else { return }
        restoredPersistedInputs = true

        var invalidPaths = false
        let savedKeyMap = existingJSONFile(workspace.preferences.lastKeyMapPath)
        if workspace.preferences.lastKeyMapPath != nil, savedKeyMap == nil {
            workspace.preferences.lastKeyMapPath = nil
            invalidPaths = true
        }
        let restoredKeyMap = savedKeyMap ?? DefaultWXCLIKeyMapLocator().locate()
        if let databaseRoot = existingDirectory(workspace.preferences.lastDatabaseStorageRoot) {
            session.selectDatabaseDirectory(databaseRoot, defaultKeyMapURL: restoredKeyMap)
            databaseRootPath = databaseRoot.path(percentEncoded: false)
            if let restoredKeyMap { workspace.preferences.lastKeyMapPath = restoredKeyMap }
        } else if workspace.preferences.lastDatabaseStorageRoot != nil {
            workspace.preferences.lastDatabaseStorageRoot = nil
            invalidPaths = true
        } else if let restoredKeyMap {
            session.selectKeyMap(restoredKeyMap)
            workspace.preferences.lastKeyMapPath = restoredKeyMap
        }

        if let storedExportParent = existingDirectory(workspace.preferences.lastPlainSQLiteExportParent) {
            exportRoot = storedExportParent
        } else if workspace.preferences.lastPlainSQLiteExportParent != nil {
            workspace.preferences.lastPlainSQLiteExportParent = nil
            invalidPaths = true
        }

        if invalidPaths {
            status = "部分已保存路径已失效，请重新选择。"
        } else if session.databaseRoot != nil, session.keyMapURL != nil {
            status = "已恢复数据库目录和密钥映射路径。请点击“扫描”后再读取密钥。"
        } else if session.databaseRoot != nil {
            status = "已恢复数据库目录。请选择 all_keys.json。"
        }
    }

    private func existingDirectory(_ url: URL?) -> URL? {
        guard let url,
              (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return nil }
        return url.standardizedFileURL
    }

    private func existingJSONFile(_ url: URL?) -> URL? {
        guard let url, url.pathExtension.lowercased() == "json",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url.standardizedFileURL
    }
}

private struct SchemaDiscoveryView: View {
    @State private var exportRoot: URL?
    @State private var exportRootPath = ""
    @State private var report: SQLiteSchemaDiscoveryReport?
    @State private var reportDirectory: URL?
    @State private var progress: SQLiteSchemaScanProgress?
    @State private var isWorking = false
    @State private var status = "请选择第一阶段导出的普通 SQLite 目录，无需密钥映射。"

    private var canAnalyze: Bool {
        exportRoot != nil && !isWorking
    }

    var body: some View {
        Form {
            Section("结构发现") {
                LabeledContent("普通 SQLite 目录") {
                    if let exportRoot {
                        Label(displayRelativePath(exportRoot), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("未选择").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("选择文件夹", action: chooseExportRoot)
                    TextField("粘贴导出目录的绝对路径", text: $exportRootPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useEnteredExportRoot)
                    Button("使用此路径", action: useEnteredExportRoot)
                }
                .disabled(isWorking)
                Text("选择第一阶段生成的普通 SQLite 根目录。分析只以只读方式打开 `*.db`，不需要 all_keys.json 或密钥。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(isWorking ? "正在分析…" : "分析数据库", action: analyze)
                    .disabled(!canAnalyze)
                if let progress, isWorking {
                    Label(
                        "\(progress.completedDatabaseCount) / \(progress.totalDatabaseCount) 个数据库 — \(redactedRelativePath(progress.currentRelativePath))",
                        systemImage: "cylinder.split.1x2"
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }

            if let report {
                Section("分析完成") {
                    HStack(spacing: 18) {
                        SummaryValue(label: "数据库", value: report.summary.databaseCount)
                        SummaryValue(label: "表", value: report.summary.tableCount)
                        SummaryValue(label: "结构组", value: report.schemaGroups.count)
                        SummaryValue(label: "行", value: report.summary.rowCount)
                    }
                    HStack(spacing: 18) {
                        SummaryValue(label: "消息", value: report.summary.messageDatabases)
                        SummaryValue(label: "联系人", value: report.summary.contactDatabases)
                        SummaryValue(label: "会话", value: report.summary.conversationDatabases)
                        SummaryValue(label: "媒体", value: report.summary.mediaDatabases)
                        SummaryValue(label: "未知", value: report.summary.unknownDatabases)
                    }
                    if let reportDirectory {
                        Button("打开报告文件夹") {
                            NSWorkspace.shared.open(reportDirectory)
                        }
                    }
                    Text("报告仅包含结构名称、声明类型、约束、索引、外键和聚合行数；不包含文本样本、BLOB 数据、联系人值或密钥。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("数据库列表") {
                    List(report.databases) { database in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(redactedRelativePath(database.relativePath)).textSelection(.enabled)
                            Text("\(localizedClassification(database.classification)) · \(database.rowCount) 行 · \(database.tableCount) 张表")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 180, maxHeight: 320)
                    if !report.failures.isEmpty {
                        Text("\(report.failures.count) 个数据库无法按普通 SQLite 检查；路径仅列在本机报告中。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("状态") {
                Text(status).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("结构发现")
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
        status = "已选择普通 SQLite 目录。请点击“分析数据库”。"
    }

    private func analyze() {
        guard let exportRoot else { return }
        isWorking = true
        report = nil
        reportDirectory = nil
        progress = nil
        status = "正在分析数据库结构…"
        var continuation: AsyncStream<SQLiteSchemaScanProgress>.Continuation?
        let stream = AsyncStream<SQLiteSchemaScanProgress>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        guard let continuation else {
            isWorking = false
            status = "无法开始结构分析。"
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

    private func localizedClassification(_ classification: WeChatDatabaseClassification) -> String {
        let category: String = switch classification.category {
        case .message: "消息"
        case .contact: "联系人"
        case .conversation: "会话"
        case .group: "群聊"
        case .media: "媒体"
        case .emoticon: "表情"
        case .favorite: "收藏"
        case .bizchat: "企业会话"
        case .index: "索引"
        case .configuration: "配置"
        case .unknown: "未知"
        }
        return switch classification.certainty {
        case .detected: "已检测到\(category)"
        case .likely: "可能是\(category)"
        case .unknown: "未知"
        }
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
            status = "分析完成。\(report.summary.databaseCount) 个数据库、\(report.summary.tableCount) 张表、\(report.schemaGroups.count) 个结构组。"
        } catch is CancellationError {
            report = nil
            reportDirectory = nil
            status = "结构分析已取消。"
        } catch {
            report = nil
            reportDirectory = nil
            status = "结构分析未能完成。请确认所选文件夹包含普通 SQLite 数据库。"
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
                failureMessage = "SQLCipher 运行时不可用。请运行：brew bundle"
            case .databaseInUse:
                failureMessage = "数据库正在使用中。请退出微信后重试。"
            case .keyInvalid:
                failureMessage = "密钥映射无效。"
            default:
                failureMessage = "本地数据库操作失败。"
            }
        } catch {
            databases = nil
            failureMessage = "本地数据库操作失败。"
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
        case .exported: "已导出"
        case .destinationExists: "目标已存在"
        case .failed: "导出失败"
        case .skippedMissingKey: "缺少密钥"
        case .skippedInvalid: "密钥无效"
        case .skippedNotValidated: "请先验证"
        case .notExported:
            switch database.validationStatus {
            case .valid: "有效"
            case .invalid: "密钥无效"
            case .missingKey: "缺少密钥"
            case .notValidated: database.hasMatchedKey ? "已匹配密钥" : "缺少密钥"
            }
        }
    }
}

private struct SettingsView: View {
    var body: some View {
        Form {
            Section("隐私") {
                Label("聊天记录不会发送到服务器。", systemImage: "lock.shield")
                Label("数据库密钥不会发送到服务器。", systemImage: "key.slash")
                Label("应用没有后台上传、遥测或崩溃报告上传服务。", systemImage: "network.slash")
            }
            Section("备份") {
                Text("建议采用 3-2-1：Mac 本地归档 + 外部磁盘/NAS + 一份离线备份。")
            }
            Section("外观") {
                Text("界面遵循 macOS 系统浅色、深色或自动主题，并支持键盘导航和 VoiceOver。")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("设置")
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
    static func main() { print("微信聊天归档需要 macOS SwiftUI。") }
}
#endif
