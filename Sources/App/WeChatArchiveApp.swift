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
    case chats = "Chats"
    case contacts = "Contacts"
    case search = "Search"
    case imports = "Imports"
    case exports = "Exports"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .chats: "bubble.left.and.bubble.right"
        case .contacts: "person.2"
        case .search: "magnifyingglass"
        case .imports: "square.and.arrow.down"
        case .exports: "square.and.arrow.up"
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
            case .chats: EmptyStateView(title: "Chats", detail: "导入聊天记录后，会话将按需分页显示。", symbol: "bubble.left.and.bubble.right")
            case .contacts: EmptyStateView(title: "Contacts", detail: "只显示导入数据中实际存在的联系人信息。", symbol: "person.2")
            case .search: SearchView()
            case .imports: ImportView()
            case .exports: ExportView()
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
                Text("本地、开放、可验证的个人聊天记录归档。")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    StatisticCard(value: "—", label: "Messages", symbol: "bubble.left")
                    StatisticCard(value: "—", label: "Conversations", symbol: "person.2")
                    StatisticCard(value: "—", label: "Photos", symbol: "photo")
                    StatisticCard(value: "—", label: "Videos", symbol: "play.rectangle")
                }
                GroupBox("Archive Health") {
                    HStack {
                        Image(systemName: "checkmark.shield").foregroundStyle(.green)
                        Text("创建或选择归档后，可在此验证 JSON、媒体与 SHA-256 校验和。")
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

private struct ImportView: View {
    @State private var databaseURL: URL?
    @State private var databaseKey = ""
    @State private var clearKeyAfterValidation = true
    @State private var isValidating = false
    @State private var status = "选择用户本人有权访问的本地数据库或导入文件。"

    var body: some View {
        Form {
            Section("WeChat Database") {
                LabeledContent("Database") {
                    Text(databaseURL?.lastPathComponent ?? "Not selected").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Database", action: chooseDatabase)
                    if databaseURL != nil { Button("Clear", role: .destructive) { databaseURL = nil } }
                }
                SecureField("Database Key（64 hexadecimal characters）", text: $databaseKey)
                    .textContentType(.password)
                    .disabled(isValidating)
                Toggle("验证后清除密钥", isOn: $clearKeyAfterValidation)
                    .disabled(isValidating)
                Text("默认开启。密钥只保留在当前输入状态中，不会写入文件、日志或归档。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("为避免遗漏尚未 checkpoint 的 WAL 数据，请完全退出微信后再验证或导入。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(isValidating ? "Validating…" : "Validate Key", action: validateKey)
                    .disabled(databaseURL == nil || databaseKey.isEmpty || isValidating)
            }
            Section("Archive / Export File") {
                Text("JSON、NDJSON 与 CSV 读取器在 Core 中独立于微信数据库适配器实现。")
                Button("Select Files", action: chooseImportFiles)
            }
            Section("Status") {
                Text(status).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Import Data")
    }

    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择您本人有权访问的微信本地数据库"
        if panel.runModal() == .OK { databaseURL = panel.url; status = "数据库已选择；请完全退出微信后再验证密钥。" }
    }

    private func chooseImportFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .commaSeparatedText, .plainText]
        if panel.runModal() == .OK { status = "已选择 \(panel.urls.count) 个文件，等待导入确认。" }
    }

    private func validateKey() {
        guard let databaseURL, !isValidating else { return }
        let enteredKey = databaseKey
        let shouldClearKey = clearKeyAfterValidation
        isValidating = true
        status = "Validating…"

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    guard enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).count == 64 else {
                        return "Expected a 64-character hexadecimal key."
                    }
                    let key = try WeChatDatabaseKey(hex: enteredKey)
                    let decryptor = try SQLCipherDatabaseDecryptor()
                    try decryptor.validate(databaseURL: databaseURL, key: key)
                    return "✓ Database key valid. 已通过受保护的本地文件快照验证。"
                } catch let error as ArchiveError {
                    switch error {
                    case .keyInvalid:
                        return "Expected a 64-character hexadecimal key."
                    case .decryptionRuntimeUnavailable:
                        return "SQLCipher runtime unavailable. Install with: brew bundle"
                    case .databaseInUse:
                        return "Database is in use. Please quit WeChat and try again."
                    default:
                        return error.localizedDescription
                    }
                } catch {
                    return ArchiveError.databaseDecryptionFailed.localizedDescription
                }
            }.value
            status = result
            isValidating = false
            if shouldClearKey { databaseKey = "" }
        }
    }
}

private struct SearchView: View {
    @State private var keyword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search Messages").font(.title.bold())
            TextField("关键词", text: $keyword)
                .textFieldStyle(.roundedBorder)
            Text("搜索使用本地 SQLite FTS5，并可组合联系人、群聊、时间、类型和发送者筛选。")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(32)
        .navigationTitle("Search")
    }
}

private struct ExportView: View {
    @State private var html = true
    @State private var json = true
    @State private var ndjson = false
    @State private var csv = false

    var body: some View {
        Form {
            Section("导出会话") {
                Toggle("HTML（完全离线）", isOn: $html)
                Toggle("JSON", isOn: $json)
                Toggle("NDJSON", isOn: $ndjson)
                Toggle("CSV", isOn: $csv)
                Text("DOCX 与 PDF 导出会按年份拆分大型会话，避免产生不可管理的单一文件。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("媒体") {
                Text("消息只引用相对媒体路径；不会把图片、视频或语音 Base64 写入 JSON。")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Exports")
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
