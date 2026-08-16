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
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .databaseExport: "cylinder.split.1x2"
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
                Text("第一阶段：将已匹配密钥的本地 SQLCipher 数据库导出为普通 SQLite。")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    StatisticCard(value: "1", label: "Export phase", symbol: "cylinder.split.1x2")
                    StatisticCard(value: "Local", label: "Processing", symbol: "macbook")
                    StatisticCard(value: "0", label: "Network uploads", symbol: "network.slash")
                    StatisticCard(value: "—", label: "Message parsing", symbol: "text.badge.xmark")
                }
                GroupBox("Current Scope") {
                    HStack {
                        Image(systemName: "checkmark.shield").foregroundStyle(.green)
                        Text("选择数据库目录和 wx-cli key map，逐个验证后导出普通 SQLite；不解析聊天消息或媒体。")
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
    @State private var databaseRoot: URL?
    @State private var databaseRootPath = ""
    @State private var keyMapURL: URL?
    @State private var exportRoot: URL?
    @State private var databases: [ScannedWeChatDatabase] = []
    @State private var isWorking = false
    @State private var status = "完全退出微信后，选择数据库根目录和 all_keys.json。"

    private var summary: WeChatDatabaseExportSummary {
        WeChatDatabaseExportSummary(databases: databases)
    }

    var body: some View {
        Form {
            Section("WeChat Database Export") {
                LabeledContent("Database Directory") {
                    Text(databaseRoot?.lastPathComponent ?? "Not selected").foregroundStyle(.secondary)
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
                    Text(keyMapURL?.lastPathComponent ?? "Not selected").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Use ~/.wx-cli/all_keys.json", action: useDefaultKeyMap)
                    Button("Choose File", action: chooseKeyMap)
                }
                .disabled(isWorking)
                Text("导出前请完全退出微信，避免遗漏尚未 checkpoint 的 WAL 数据。all_keys.json 仅在内存读取，不会复制到导出目录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(isWorking ? "Working…" : "Scan", action: scan)
                    .disabled(databaseRoot == nil || keyMapURL == nil || isWorking)
            }

            Section("Scan Results") {
                HStack(spacing: 18) {
                    SummaryValue(label: "Databases", value: summary.detected)
                    SummaryValue(label: "Matched Keys", value: summary.matched)
                    SummaryValue(label: "Missing Keys", value: summary.missingKeys)
                }
                if !databases.isEmpty {
                    List(databases) { database in
                        DatabaseResultRow(database: database)
                    }
                    .frame(minHeight: 150, maxHeight: 280)
                }
                Button(isWorking ? "Working…" : "Validate All", action: validateAll)
                    .disabled(!databases.contains(where: \.hasAvailableKey) || isWorking)
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
                    .disabled(exportRoot == nil || !databases.contains(where: {
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
        databaseRoot = url
        databaseRootPath = url.path()
        databases = []
        status = "数据库目录已选择；选择 key map 后点击 Scan。"
    }

    private func useDefaultKeyMap() {
        let candidate = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".wx-cli/all_keys.json")
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            status = "未找到默认 all_keys.json；请选择你本人保存的 key map 文件。"
            return
        }
        keyMapURL = candidate
        databases = []
        status = "已选择默认 key map；点击 Scan。"
    }

    private func chooseKeyMap() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "选择 wx-cli 生成的 all_keys.json"
        if panel.runModal() == .OK {
            keyMapURL = panel.url
            databases = []
            status = "key map 已选择；点击 Scan。"
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
        guard let databaseRoot, let keyMapURL else { return }
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
        guard !databases.isEmpty else { return }
        let input = databases
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
        let input = databases
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
            self.databases = databases
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

private struct SummaryValue: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.headline.monospacedDigit())
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
