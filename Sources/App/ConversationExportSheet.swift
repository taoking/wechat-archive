#if canImport(SwiftUI)
import AppKit
import SwiftUI
import WeChatArchiveCore

struct ConversationExportSheet: View {
    let viewer: WeChatArchiveViewerDatabase
    let conversation: ArchiveViewerConversation
    let workspace: ArchiveWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var format: ConversationExportFormat
    @State private var includeImages = true
    @State private var includeVoice = true
    @State private var includeVideo = true
    @State private var includeAvatars = true
    @State private var includeTechnicalMetadata = false
    @State private var destination: URL?
    @State private var isExporting = false
    @State private var cancellation: ConversationExportCancellation?
    @State private var progress: ConversationExportProgress?
    @State private var completed: ConversationExportResult?
    @State private var status = "选择导出位置后，将从当前归档生成独立的聊天记录。"

    init(viewer: WeChatArchiveViewerDatabase, conversation: ArchiveViewerConversation, workspace: ArchiveWorkspace) {
        self.viewer = viewer
        self.conversation = conversation
        self.workspace = workspace
        _format = State(initialValue: workspace.preferences.lastConversationExportFormat)
        _destination = State(initialValue: workspace.preferences.lastConversationExportDirectory)
    }

    var body: some View {
        ZStack {
            ArchiveCanvas()
            VStack(alignment: .leading, spacing: 18) {
                ArchiveSectionTitle(
                    title: "导出聊天记录",
                    subtitle: "生成一个可独立保存与离线阅读的会话副本。",
                    symbol: "square.and.arrow.up"
                )
                Text(conversation.title).font(.headline).lineLimit(1)
                Form {
                Picker("格式", selection: $format) {
                    Text("HTML（离线查看）").tag(ConversationExportFormat.html)
                    Text("JSON").tag(ConversationExportFormat.json)
                    Text("Markdown").tag(ConversationExportFormat.markdown)
                }
                Section("包含内容") {
                    Toggle("图片", isOn: $includeImages)
                    Toggle("语音（WAV）", isOn: $includeVoice)
                    Toggle("视频", isOn: $includeVideo)
                    Toggle("头像", isOn: $includeAvatars)
                    Toggle("包含技术信息", isOn: $includeTechnicalMetadata)
                }
                Section("导出位置") {
                    HStack {
                        Text(destination?.lastPathComponent ?? "未选择")
                            .foregroundStyle(destination == nil ? .secondary : .primary)
                        Spacer()
                        Button("选择文件夹", action: chooseDestination)
                    }
                    Text("导出会创建一个新的私有文件夹，不会修改当前归档。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                }
                .scrollContentBackground(.hidden)
            if let progress, isExporting {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(progress.messagesExported), total: Double(max(progress.totalMessages, 1)))
                    Text("消息：\(progress.messagesExported) / \(progress.totalMessages) · 图片 \(progress.imagesCopied) · 语音 \(progress.voiceCopied) · 视频 \(progress.videoCopied) · 已复制 \(ByteCountFormatter.string(fromByteCount: progress.bytesCopied, countStyle: .file))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text(status).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                if let completed {
                    if format == .html {
                        Button("打开 HTML") { NSWorkspace.shared.open(completed.primaryFileURL) }
                    }
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([completed.outputRoot]) }
                }
                Spacer()
                Button("关闭", action: dismiss.callAsFunction).disabled(isExporting)
                if isExporting {
                    Button("取消") { cancellation?.cancel() }
                } else if completed == nil {
                    Button("开始导出", action: export).disabled(destination == nil)
                        .keyboardShortcut(.defaultAction)
                }
                }
            }
            .padding(24)
            .frame(width: 560)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择聊天记录导出的父文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.standardizedFileURL
            workspace.preferences.lastConversationExportDirectory = destination
        }
    }

    private func export() {
        guard let destination else { return }
        let token = ConversationExportCancellation()
        cancellation = token
        isExporting = true
        completed = nil
        progress = nil
        status = "正在从归档导出聊天记录…"
        workspace.preferences.lastConversationExportFormat = format
        let options = ConversationExportOptions(
            includeImages: includeImages,
            includeVoice: includeVoice,
            includeVideo: includeVideo,
            includeAvatars: includeAvatars,
            includeTechnicalMetadata: includeTechnicalMetadata
        )
        var continuation: AsyncStream<ConversationExportProgress>.Continuation?
        let stream = AsyncStream<ConversationExportProgress>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        guard let continuation else {
            finish(.failure(ConversationExportError.ioFailure))
            return
        }
        let archiveRoot = viewer.archiveRoot
        let conversationID = conversation.id
        let selectedFormat = format
        let worker = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return Result {
                try WeChatArchiveConversationExporter().export(
                    archiveRoot: archiveRoot,
                    conversationID: conversationID,
                    destinationRoot: destination,
                    format: selectedFormat,
                    options: options,
                    shouldCancel: { token.isCancelled },
                    progress: { continuation.yield($0) }
                )
            }
        }
        Task { @MainActor in
            for await update in stream { progress = update }
        }
        Task { @MainActor in finish(await worker.value) }
    }

    private func finish(_ result: Result<ConversationExportResult, Error>) {
        isExporting = false
        cancellation = nil
        switch result {
        case let .success(value):
            completed = value
            status = "导出完成。结果已完全脱离 WeChatArchive。"
        case let .failure(error as ConversationExportError) where error == .cancelled:
            status = "导出已取消，未完成的临时目录已清理。"
        case .failure:
            status = "导出失败。请确认选择的是可写的本机文件夹，且不位于归档内。"
        }
    }
}

private final class ConversationExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
#endif
