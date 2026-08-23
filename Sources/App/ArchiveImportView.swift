#if canImport(SwiftUI)
import AppKit
import SwiftUI
import WeChatArchiveCore

struct ArchiveImportView: View {
    @State private var plainSQLiteRoot: URL?
    @State private var plainSQLitePath = ""
    @State private var accountRoot: URL?
    @State private var accountRootPath = ""
    @State private var archiveRoot: URL?
    @State private var archiveRootPath = ""
    @State private var analysis: ArchiveV1ImportAnalysis?
    @State private var summary: ArchiveV1ImportSummary?
    @State private var progress: ArchiveV1ImportProgress?
    @State private var isWorking = false
    @State private var limit: ArchiveImportLimit = .all
    @State private var cancellation: ArchiveImportCancellation?
    @State private var status = "请选择普通 SQLite 导出目录、原始微信账号根目录，以及新的或空的归档目标目录。"

    private var canAnalyze: Bool {
        plainSQLiteRoot != nil && accountRoot != nil && archiveRoot != nil && !isWorking
    }

    private var canImport: Bool {
        canAnalyze && analysis != nil && archiveDestinationIsEmpty && !isWeChatRunning
    }

    private var isWeChatRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").isEmpty
    }

    private var archiveDestinationIsEmpty: Bool {
        guard let archiveRoot else { return false }
        guard FileManager.default.fileExists(atPath: archiveRoot.path()) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: archiveRoot.path()).isEmpty) == true
    }

    var body: some View {
        Form {
            Section("归档导出") {
                directoryInput(
                    title: "普通 SQLite 导出目录",
                    value: plainSQLiteRoot,
                    path: $plainSQLitePath,
                    choose: choosePlainSQLiteRoot,
                    usePath: usePlainSQLiteRoot
                )
                directoryInput(
                    title: "原始微信账号根目录",
                    value: accountRoot,
                    path: $accountRootPath,
                    choose: chooseAccountRoot,
                    usePath: useAccountRoot
                )
                directoryInput(
                    title: "归档目标目录",
                    value: archiveRoot,
                    path: $archiveRootPath,
                    choose: chooseArchiveRoot,
                    usePath: useArchiveRoot
                )
                Text("完整导出会以只读方式打开普通 SQLite 和原始媒体文件，不会复制密钥或修改微信数据。目标目录必须是新建或空目录；不会合并已有归档。归档目录权限为 0700，私有文件权限为 0600。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if isWeChatRunning {
                    Label("请先完全退出微信，再执行完整导出。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Label(
                    SilkProcessVoiceDecoder.isAvailable ? "语音解码器：可用" : "语音解码器：未安装（语音原始数据仍会归档）",
                    systemImage: SilkProcessVoiceDecoder.isAvailable ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(SilkProcessVoiceDecoder.isAvailable ? Color.gray : Color.orange)

                HStack {
                    Button(isWorking ? "处理中…" : "分析导出", action: analyzeImport)
                        .disabled(!canAnalyze)
                    Picker("导入数量", selection: $limit) {
                        ForEach(ArchiveImportLimit.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .frame(maxWidth: 290)
                    .disabled(isWorking)
                    Button("完整导出", action: importArchive)
                        .disabled(!canImport)
                    if isWorking {
                        Button("取消") { cancellation?.cancel() }
                    }
                }
            }

            if let analysis {
                Section("导出分析") {
                    HStack(spacing: 18) {
                        SummaryValue(label: "消息数据库", value: analysis.messageDatabaseCount)
                        SummaryValue(label: "消息表", value: analysis.messageTableCount)
                        SummaryValue(label: "预计消息数", value: analysis.estimatedMessageCount)
                    }
                    Text("导入会逐条读取记录，不会一次将整张消息表载入内存。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress, isWorking {
                Section("完整导出进度") {
                    Text("正在导出消息")
                    HStack(spacing: 18) {
                        SummaryValue(label: "已读取消息", value: progress.messagesRead)
                        SummaryValue(label: "已导入", value: progress.messagesImported)
                        SummaryValue(label: "已关联图片", value: progress.imagesResolved)
                        SummaryValue(label: "已解码", value: progress.imagesDecoded)
                        SummaryValue(label: "仅原始文件", value: progress.imagesRawOnly)
                        SummaryValue(label: "缺失", value: progress.imagesMissing)
                    }
                    HStack(spacing: 18) {
                        SummaryValue(label: "文本", value: progress.textCount)
                        SummaryValue(label: "图片", value: progress.imageCount)
                        SummaryValue(label: "视频", value: progress.videoCount)
                        SummaryValue(label: "语音", value: progress.voiceCount)
                        SummaryValue(label: "未知", value: progress.unknownCount)
                    }
                    Text("已复制媒体：\(ByteCountFormatter.string(fromByteCount: progress.mediaBytesCopied, countStyle: .file))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("数据库：消息数据库 · 数据表：消息表")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary {
                Section("完整导出结果") {
                    HStack(spacing: 18) {
                        SummaryValue(label: "消息", value: summary.messagesImported)
                        SummaryValue(label: "文本", value: summary.textCount)
                        SummaryValue(label: "图片", value: summary.imageCount)
                        SummaryValue(label: "视频", value: summary.videoCount)
                        SummaryValue(label: "语音", value: summary.voiceCount)
                        SummaryValue(label: "未知", value: summary.unknownCount)
                        SummaryValue(label: "会话", value: summary.conversationCount)
                        SummaryValue(label: "联系人", value: summary.contactCount)
                        SummaryValue(label: "群聊", value: summary.groupCount)
                        SummaryValue(label: "群成员", value: summary.groupMemberCount)
                        SummaryValue(label: "头像", value: summary.avatarAssetCount)
                    }
                    HStack(spacing: 18) {
                        SummaryValue(label: "原始 DAT", value: summary.rawDATArchived)
                        SummaryValue(label: "已解码", value: summary.decodedImages)
                        SummaryValue(label: "视频文件", value: summary.rawVideoArchived)
                        SummaryValue(label: "原始语音", value: summary.rawVoiceArchived)
                        SummaryValue(label: "缺失", value: summary.missingLocalMedia)
                        SummaryValue(label: "解码失败", value: summary.decodeFailures)
                    }
                    Text("每条已导入消息都会保留完整的原始 SQLite 行。未知类型将以未知消息归档，不会被丢弃。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("状态") {
                Text(status).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("归档导出")
    }

    @ViewBuilder
    private func directoryInput(
        title: String,
        value: URL?,
        path: Binding<String>,
        choose: @escaping () -> Void,
        usePath: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            if let value {
                Label(displayPath(value), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text("未选择").foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("选择文件夹", action: choose)
            TextField("粘贴绝对路径", text: path)
                .textFieldStyle(.roundedBorder)
                .onSubmit(usePath)
            Button("使用此路径", action: usePath)
        }
        .disabled(isWorking)
    }

    private func choosePlainSQLiteRoot() { chooseDirectory("选择第一阶段导出的普通 SQLite 目录") { setPlainSQLiteRoot($0) } }
    private func chooseAccountRoot() { chooseDirectory("选择原始微信账号根目录") { setAccountRoot($0) } }
    private func chooseArchiveRoot() { chooseDirectory("选择新的或空的 WeChatArchive 归档目标目录") { setArchiveRoot($0) } }

    private func usePlainSQLiteRoot() { useDirectoryPath(plainSQLitePath, setter: setPlainSQLiteRoot) }
    private func useAccountRoot() { useDirectoryPath(accountRootPath, setter: setAccountRoot) }
    private func useArchiveRoot() {
        do {
            let url = try ArchiveDestinationPath.resolve(archiveRootPath)
            setArchiveRoot(url)
        } catch {
            status = "归档目标必须是绝对路径，且其已有父目录必须是本机目录。"
        }
    }

    private func chooseDirectory(_ message: String, completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }

    private func useDirectoryPath(_ path: String, setter: (URL) -> Void) {
        do {
            let url = try LocalDatabaseDirectoryPath.resolve(path)
            setter(url)
        } catch {
            status = "该路径必须是已存在的本机绝对目录。"
        }
    }

    private func setPlainSQLiteRoot(_ url: URL) {
        plainSQLiteRoot = url.standardizedFileURL
        plainSQLitePath = plainSQLiteRoot?.path() ?? ""
        resetAnalysis()
    }

    private func setAccountRoot(_ url: URL) {
        accountRoot = url.standardizedFileURL
        accountRootPath = accountRoot?.path() ?? ""
        resetAnalysis()
    }

    private func setArchiveRoot(_ url: URL) {
        archiveRoot = url.standardizedFileURL
        archiveRootPath = archiveRoot?.path() ?? ""
        resetAnalysis()
        if !archiveDestinationIsEmpty {
            status = "归档已存在或目标目录不为空。请为完整导出选择新的空目录。"
        }
    }

    private func resetAnalysis() {
        analysis = nil
        summary = nil
        progress = nil
        status = "路径已选择。请先点击“分析导出”，再执行完整导出。"
    }

    private func analyzeImport() {
        guard let plainSQLiteRoot else { return }
        isWorking = true
        summary = nil
        status = "正在分析消息数据库…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try WeChatArchiveV1Importer(imageKeyProvider: WeChatKVCommImageKeyProvider()).analyze(plainSQLiteRoot: plainSQLiteRoot) }
            }.value
            switch result {
            case let .success(value):
                analysis = value
                status = "导出分析完成。请选择导入数量，然后开始完整导出。"
            case .failure:
                analysis = nil
                status = "导出分析未能完成。请确认普通 SQLite 导出目录。"
            }
            isWorking = false
        }
    }

    private func importArchive() {
        guard let plainSQLiteRoot, let accountRoot, let archiveRoot else { return }
        guard !isWeChatRunning else {
            status = "请退出微信后重试。微信运行期间无法执行完整导出。"
            return
        }
        let token = ArchiveImportCancellation()
        cancellation = token
        isWorking = true
        progress = nil
        summary = nil
        status = "正在导出私人归档…"
        let importOptions = limit.options
        var continuation: AsyncStream<ArchiveV1ImportProgress>.Continuation?
        let stream = AsyncStream<ArchiveV1ImportProgress>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        guard let continuation else {
            applyImport(.failure(ArchiveError.ioFailure))
            return
        }
        let worker = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return Result {
                try WeChatArchiveV1Importer(imageKeyProvider: WeChatKVCommImageKeyProvider()).importArchive(
                    plainSQLiteRoot: plainSQLiteRoot,
                    accountRoot: accountRoot,
                    destinationRoot: archiveRoot,
                    options: importOptions,
                    shouldCancel: { token.isCancelled },
                    progress: { continuation.yield($0) }
                )
            }
        }
        Task { @MainActor in
            for await update in stream { progress = update }
        }
        Task { @MainActor in
            applyImport(await worker.value)
        }
    }

    private func applyImport(_ result: Result<ArchiveV1ImportSummary, Error>) {
        switch result {
        case let .success(value):
            summary = value
            status = value.status == .cancelled
                ? "导出已取消。已完成的消息事务仍然有效；如需再次完整导出，请使用新的目标目录。"
                : "完整导出完成。请使用归档查看器打开归档。"
        case .failure:
            status = "归档导出未能完成。目标目录仅保留用于验证；请使用新的空目录重试。"
        }
        progress = nil
        cancellation = nil
        isWorking = false
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.path()
        let home = FileManager.default.homeDirectoryForCurrentUser.path()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private enum ArchiveImportLimit: String, CaseIterable, Identifiable {
    case oneHundred
    case oneThousand
    case all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .oneHundred: "100"
        case .oneThousand: "1,000"
        case .all: "全部"
        }
    }
    var options: ArchiveV1ImportOptions {
        switch self {
        case .oneHundred: .init(limit: 100)
        case .oneThousand: .init(limit: 1_000)
        case .all: .all
        }
    }
}

private enum ArchiveDestinationPath {
    static func resolve(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/") else { throw ArchiveError.invalidInput }
        let destination = URL(fileURLWithPath: value).standardizedFileURL
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path()) {
            let metadata = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard metadata.isDirectory == true, metadata.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        } else {
            let parent = destination.deletingLastPathComponent()
            let metadata = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard metadata.isDirectory == true, metadata.isSymbolicLink != true,
                  destination.lastPathComponent != ".", destination.lastPathComponent != ".." else { throw ArchiveError.invalidInput }
        }
        return destination
    }
}

private final class ArchiveImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
#endif
