#if canImport(SwiftUI)
import AppKit
import Foundation
import SwiftUI
import WeChatArchiveCore

struct MessageDiscoveryView: View {
    @State private var exportRoot: URL?
    @State private var exportRootPath = ""
    @State private var mediaRoot: URL?
    @State private var mediaRootPath = ""
    @State private var schemaReportURL: URL?
    @State private var candidates = [MessageTableCandidate]()
    @State private var selectedCandidate: MessageTableCandidate?
    @State private var sampleLimit = 100
    @State private var discoveryResult: MessageMediaDiscoveryResult?
    @State private var reportDirectory: URL?
    @State private var imageResolutionRun: WeChatImageResolutionRun?
    @State private var imageReportDirectory: URL?
    @State private var progress: MediaScanProgress?
    @State private var isWorking = false
    @State private var cancellation: MessageDiscoveryCancellation?
    @State private var status = "请选择第一阶段导出的普通 SQLite 目录。系统会自动加载其第二阶段结构报告。"

    private var canDiscover: Bool {
        exportRoot != nil && mediaRoot != nil && selectedCandidate != nil && !isWorking
    }

    private var canResolveImage: Bool {
        exportRoot != nil && mediaRoot != nil && selectedCandidate != nil && !isWorking
    }

    var body: some View {
        Form {
            Section("消息发现") {
                LabeledContent("普通 SQLite 目录") {
                    selectedDirectoryLabel(exportRoot)
                }
                HStack {
                    Button("选择文件夹", action: chooseExportRoot)
                    TextField("粘贴导出目录的绝对路径", text: $exportRootPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useEnteredExportRoot)
                    Button("使用此路径", action: useEnteredExportRoot)
                }
                .disabled(isWorking)

                LabeledContent("第二阶段结构报告") {
                    if let schemaReportURL {
                        Label(displayPath(schemaReportURL), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("未找到，请先运行“结构发现”").foregroundStyle(.secondary)
                    }
                }
                Text("选择普通 SQLite 根目录后，应用只读取 `SchemaReports/schema-summary.json` 来列出消息表候选，不会重新读取聊天记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("重新加载第二阶段报告", action: loadDefaultSchemaReport)
                    .disabled(exportRoot == nil || isWorking)

                LabeledContent("原始微信数据根目录") {
                    selectedDirectoryLabel(mediaRoot)
                }
                HStack {
                    Button("选择文件夹", action: chooseMediaRoot)
                    TextField("粘贴原始微信数据的绝对路径", text: $mediaRootPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useEnteredMediaRoot)
                    Button("使用此路径", action: useEnteredMediaRoot)
                }
                .disabled(isWorking)
                Text("仅选择你本人有权访问的原始微信数据目录。扫描只读取文件头和必要的已缩小候选文件，不会复制、移动或修改媒体文件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("候选表与样本") {
                Picker("消息表", selection: $selectedCandidate) {
                    Text("请选择已发现的消息表").tag(MessageTableCandidate?.none)
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        Text("消息表 \(index + 1) · \(redactedRelativePath(candidate.databaseRelativePath)) · \(candidate.rowCount ?? 0) 行 · 评分 \(candidate.score)")
                            .tag(Optional(candidate))
                    }
                }
                .disabled(candidates.isEmpty || isWorking)
                Picker("样本数量", selection: $sampleLimit) {
                    Text("100 行").tag(100)
                    Text("250 行").tag(250)
                    Text("500 行").tag(500)
                }
                .pickerStyle(.segmented)
                .disabled(isWorking)
                Text("隐私提示：此次只读取所选表中最多 500 行。结果页面可在本机显示极短预览，报告不会保存任何消息正文、BLOB、媒体 ID、哈希、文件名或绝对路径。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("此阶段会在本机读取少量真实聊天记录，用于确定消息和媒体结构。任何数据都不会上传。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(isWorking ? "正在发现…" : "发现消息与媒体", action: discover)
                        .disabled(!canDiscover)
                    Button("解析图片", action: resolveImage)
                        .disabled(!canResolveImage)
                    if isWorking {
                        Button("取消") { cancellation?.cancel() }
                    }
                }
                if let progress, isWorking {
                    Label(
                        "已扫描 \(progress.scannedFileCount) 个文件 · \(progress.discoveredMediaCount) 个候选项 · \(redactedRelativePath(progress.currentRelativePath))",
                        systemImage: "photo.stack"
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }

            if let discoveryResult {
                discoveryResults(discoveryResult)
            }

            if let imageResolutionRun {
                imageResolutionResults(imageResolutionRun)
            }

            Section("状态") {
                Text(status).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("消息发现")
    }

    @ViewBuilder
    private func discoveryResults(_ result: MessageMediaDiscoveryResult) -> some View {
        Section("本机受限验证") {
            HStack(spacing: 18) {
                MessageDiscoverySummaryValue(label: "已采样", value: result.messageAnalysis.records.count)
                MessageDiscoverySummaryValue(label: "文本形态", value: result.messageAnalysis.textCandidates.count)
                MessageDiscoverySummaryValue(label: "媒体引用", value: result.messageAnalysis.mediaReferences.count)
                MessageDiscoverySummaryValue(label: "已解析", value: result.links.filter { $0.resolvedFile != nil }.count)
            }
            if let reportDirectory {
                Button("打开本机分析报告") { NSWorkspace.shared.open(reportDirectory) }
            }
            if !result.diagnostics.isEmpty {
                Label(
                    result.diagnostics.map(\.rawValue).joined(separator: " · "),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            Text("报告权限为目录 0700、文件 0600；它保留结构性发现和验证结果，不含本机预览内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("已确认字段映射") {
            ForEach(fieldMappingRows(result.messageAnalysis.fieldMapping), id: \.label) { row in
                LabeledContent(row.label, value: row.column ?? "未检测到")
            }
            if let timestamp = result.messageAnalysis.timestampInference {
                Text("时间戳：\(timestamp.unit.rawValue)，置信度 \(String(format: "%.2f", timestamp.confidence))，有效 \(timestamp.validSampleCount)/\(timestamp.sampleCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section("原始类型观察") {
            if result.messageAnalysis.typeObservations.isEmpty {
                Text("未检测到整数原始类型字段。 ").foregroundStyle(.secondary)
            } else {
                ForEach(result.messageAnalysis.typeObservations, id: \.rawType) { observation in
                    Text("原始类型 \(observation.rawType)：\(observation.count) 条采样记录")
                }
            }
            ForEach(result.observedTypeMappings, id: \.rawType) { mapping in
                Label(
                    "原始类型 \(mapping.rawType) → \(mapping.observedType.rawValue)（\(mapping.count) 个已解析本机文件，\(mapping.confidence.rawValue)）",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
            }
        }

        Section("本机样本预览") {
            Text("仅此本机窗口会显示简短预览。预览不会写入报告，也不会通过网络发送。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(result.messageAnalysis.records.prefix(10), id: \.identity) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text("本机采样记录")
                        .font(.caption.monospaced())
                    Text(sampleMetadata(record, analysis: result.messageAnalysis))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let preview = limitedPreview(record, analysis: result.messageAnalysis) {
                        Text(preview)
                            .font(.caption)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 3)
            }
        }

        Section("媒体文件解析") {
            if result.links.isEmpty {
                Text("在所选样本中未找到结构化媒体引用。 ").foregroundStyle(.secondary)
            } else {
                ForEach(result.links, id: \.reference.sourceMessageIdentity) { link in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(link.reference.mediaTypeHint?.rawValue ?? "未知") · \(link.confidence.rawValue)")
                        Text("\(link.diagnostic.rawValue)\(link.mappingRule.map { " · \($0.rawValue)" } ?? "") · \(link.reason)").font(.caption).foregroundStyle(.secondary)
                        if let file = link.resolvedFile {
                            Text("本机媒体已验证 · \(file.format.rawValue) · \(file.fileSize) 字节\(file.imageDimensions.map { " · \($0.width) × \($0.height)" } ?? "")")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private func imageResolutionResults(_ run: WeChatImageResolutionRun) -> some View {
        Section("图片解析") {
            LabeledContent("已采样类型 3 记录", value: "\(run.sampledRecordCount)（最多 100 条）")
            LabeledContent("消息资源") {
                Text(run.resolution?.resourceMatch == .notFound ? "未找到" : "已找到")
                    .foregroundStyle(run.resolution?.resourceMatch == .notFound ? .orange : .green)
            }
            LabeledContent("消息资源详情") {
                Text(run.resolution?.resourceDetailsFound == true ? "已找到" : "未找到")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("本机 DAT") {
                let assets = run.resolution?.assets
                Text("主图 \(assets?.mainURL == nil ? "缺失" : "已找到") · 高清 \(assets?.hdURL == nil ? "缺失" : "已找到") · 缩略图 \(assets?.thumbnailURL == nil ? "缺失" : "已找到")")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("DAT 格式", value: run.resolution?.datVersion.rawValue.uppercased() ?? "未知")
            LabeledContent("图片密钥") {
                Text(run.keyVerificationPassed ? "已在本机验证" : (run.keyDerivationAvailable ? "候选值已拒绝" : "不可用"))
                    .foregroundStyle(run.keyVerificationPassed ? .green : .orange)
            }
            LabeledContent("图片解码") {
                Text(imageDecodeSummary(run))
                    .foregroundStyle(run.imageConfirmed ? .green : .secondary)
            }
            if let imageReportDirectory {
                Button("打开本机图片解析报告") { NSWorkspace.shared.open(imageReportDirectory) }
            }
            if !run.diagnostics.isEmpty {
                Label(run.diagnostics.map(\.rawValue).joined(separator: " · "), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(run.imageConfirmed ? .green : .orange)
            }
            Text("仅显示结构性状态；界面和本地报告均不会展示账户标识、消息 ID、file base、文件名、密钥或解码后的图片。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseExportRoot() {
        let panel = directoryPanel(message: "选择第一阶段导出的普通 SQLite 根目录")
        if panel.runModal() == .OK, let url = panel.url { setExportRoot(url) }
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
        resetDiscovery()
        loadDefaultSchemaReport()
    }

    private func loadDefaultSchemaReport() {
        guard let exportRoot else { return }
        let reportURL = exportRoot.appending(path: "SchemaReports/schema-summary.json")
        do {
            let values = try reportURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
            let report = try JSONDecoder().decode(SQLiteSchemaDiscoveryReport.self, from: Data(contentsOf: reportURL, options: .mappedIfSafe))
            candidates = WeChatMessageTableDiscovery().candidates(from: report)
            selectedCandidate = candidates.first
            schemaReportURL = reportURL
            status = candidates.isEmpty
                ? "第二阶段报告已加载，但其中没有可选择的消息表候选项。"
                : "第二阶段报告已加载。请选择源媒体根目录并运行受限发现。"
        } catch {
            schemaReportURL = nil
            candidates = []
            selectedCandidate = nil
            status = "已选择普通 SQLite 目录。未找到第二阶段报告；请先运行“结构发现”。"
        }
    }

    private func chooseMediaRoot() {
        let panel = directoryPanel(message: "选择本人原始微信数据根目录（仅用于只读媒体定位）")
        if panel.runModal() == .OK, let url = panel.url { setMediaRoot(url) }
    }

    private func useEnteredMediaRoot() {
        do {
            try setMediaRoot(LocalDatabaseDirectoryPath.resolve(mediaRootPath))
        } catch {
            status = "路径必须是一个存在的本地绝对目录。"
        }
    }

    private func setMediaRoot(_ url: URL) {
        mediaRoot = url.standardizedFileURL
        mediaRootPath = mediaRoot?.path() ?? ""
        resetDiscovery()
        status = schemaReportURL == nil
            ? "已选择原始数据根目录。请先选择普通 SQLite 目录以加载第二阶段结构报告。"
            : "已选择原始数据根目录。可以执行受限的消息与媒体发现。"
    }

    private func resetDiscovery() {
        discoveryResult = nil
        reportDirectory = nil
        imageResolutionRun = nil
        imageReportDirectory = nil
        progress = nil
    }

    private func discover() {
        guard let exportRoot, let mediaRoot, let candidate = selectedCandidate else { return }
        resetDiscovery()
        let cancellation = MessageDiscoveryCancellation()
        self.cancellation = cancellation
        isWorking = true
        status = "正在读取最多 \(sampleLimit) 条记录并扫描所选本机媒体…"
        var continuation: AsyncStream<MediaScanProgress>.Continuation?
        let stream = AsyncStream<MediaScanProgress>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        guard let continuation else {
            isWorking = false
            status = "无法开始本机发现。"
            return
        }
        let limit = sampleLimit
        let outputDirectory = exportRoot.appending(path: ".local-analysis")
        let worker = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return MessageDiscoveryOperationResult(
                exportRoot: exportRoot,
                candidate: candidate,
                mediaRoot: mediaRoot,
                sampleLimit: limit,
                outputDirectory: outputDirectory,
                progress: { continuation.yield($0) },
                shouldCancel: { cancellation.isCancelled }
            )
        }
        Task { @MainActor in
            for await update in stream { progress = update }
        }
        Task { @MainActor in
            let operation = await worker.value
            discoveryResult = operation.result
            reportDirectory = operation.reportDirectory
            progress = nil
            status = operation.status
            isWorking = false
            self.cancellation = nil
        }
    }

    private func resolveImage() {
        guard let exportRoot, let mediaRoot, let candidate = selectedCandidate else { return }
        imageResolutionRun = nil
        imageReportDirectory = nil
        isWorking = true
        status = "正在通过 message_resource 和一个受限附件路径解析最多 100 条本机类型 3 记录…"
        let outputDirectory = exportRoot.appending(path: ".local-analysis")
        let worker = Task.detached(priority: .userInitiated) {
            ImageResolutionOperationResult(
                exportRoot: exportRoot,
                candidate: candidate,
                mediaRoot: mediaRoot,
                outputDirectory: outputDirectory
            )
        }
        Task { @MainActor in
            let operation = await worker.value
            imageResolutionRun = operation.run
            imageReportDirectory = operation.reportDirectory
            status = operation.status
            isWorking = false
        }
    }

    private func selectedDirectoryLabel(_ url: URL?) -> some View {
        Group {
            if let url {
                Label(displayPath(url), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text("未选择").foregroundStyle(.secondary)
            }
        }
    }

    private func fieldMappingRows(_ mapping: MessageFieldMapping) -> [(label: String, column: String?)] {
        [
            ("本地消息 ID", mapping.messageIDColumn),
            ("服务器消息 ID", mapping.serverMessageIDColumn),
            ("时间戳", mapping.timestampColumn),
            ("原始类型", mapping.rawTypeColumn),
            ("发送者", mapping.senderColumn),
            ("会话", mapping.conversationColumn),
            ("内容", mapping.contentColumn),
            ("载荷", mapping.payloadColumn)
        ]
    }

    private func sampleMetadata(_ record: SourceMessageRecord, analysis: MessageSampleAnalysis) -> String {
        let timestamp = analysis.fieldMapping.timestampColumn
            .flatMap { record.values[$0]?.integerValue }
            .flatMap { analysis.timestampInference?.date(for: $0) }
            .map { $0.formatted(date: .abbreviated, time: .standard) } ?? "时间戳不可用"
        let rawType = analysis.fieldMapping.rawTypeColumn
            .flatMap { record.values[$0]?.integerValue }
            .map(String.init) ?? "不可用"
        let kind = analysis.payloadInspections[record.identity]?.kind.rawValue ?? "未分类"
        return "时间：\(timestamp) · 原始类型：\(rawType) · 内容类型：\(kind)"
    }

    private func imageDecodeSummary(_ run: WeChatImageResolutionRun) -> String {
        func status(_ variant: WeChatImageDecodedVariant) -> String {
            guard variant.present else { return "缺失" }
            guard variant.decoded else { return "未解码" }
            return variant.format?.rawValue.uppercased() ?? "已解码"
        }
        return "缩略图 \(status(run.thumbnail)) · 主图 \(status(run.main)) · 高清 \(status(run.hd))"
    }

    private func limitedPreview(_ record: SourceMessageRecord, analysis: MessageSampleAnalysis) -> String? {
        guard let column = analysis.fieldMapping.contentColumn,
              case let .text(value)? = record.values[column] else { return nil }
        let compact = value.replacingOccurrences(of: "\\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(240)) + (compact.count > 240 ? "…" : "")
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

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path()
        let path = url.path()
        let display = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return redactedRelativePath(String(display))
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

private struct MessageDiscoverySummaryValue: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private final class MessageDiscoveryCancellation: @unchecked Sendable {
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

private struct MessageDiscoveryOperationResult: Sendable {
    let result: MessageMediaDiscoveryResult?
    let reportDirectory: URL?
    let status: String

    init(
        exportRoot: URL,
        candidate: MessageTableCandidate,
        mediaRoot: URL,
        sampleLimit: Int,
        outputDirectory: URL,
        progress: @escaping @Sendable (MediaScanProgress) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool
    ) {
        do {
            let result = try MessageMediaDiscoveryCoordinator().discover(
                exportRoot: exportRoot,
                candidate: candidate,
                mediaRoot: mediaRoot,
                sampleLimit: sampleLimit,
                mediaProgress: progress,
                shouldCancel: shouldCancel
            )
            let locations = try MessageDiscoveryReportWriter().write(result, to: outputDirectory)
            self.result = result
            reportDirectory = locations.directoryURL
            status = "受限发现完成。已采样 \(result.messageAnalysis.records.count) 条记录；已解析 \(result.links.filter { $0.resolvedFile != nil }.count) 个媒体关联。"
        } catch is CancellationError {
            result = nil
            reportDirectory = nil
            status = "消息与媒体发现已取消。"
        } catch {
            result = nil
            reportDirectory = nil
            status = "本机发现未能完成。请确认所选普通 SQLite 目录和原始微信目录可访问。"
        }
    }
}

private struct ImageResolutionOperationResult: Sendable {
    let run: WeChatImageResolutionRun?
    let reportDirectory: URL?
    let status: String

    init(
        exportRoot: URL,
        candidate: MessageTableCandidate,
        mediaRoot: URL,
        outputDirectory: URL
    ) {
        do {
            let run = try WeChatImageResolutionCoordinator().resolveFirstImage(
                exportRoot: exportRoot,
                candidate: candidate,
                accountRoot: mediaRoot
            )
            let locations = try WeChatImageResolutionReportWriter().write(run, to: outputDirectory)
            self.run = run
            reportDirectory = locations.directoryURL
            status = run.imageConfirmed
                ? "图片链路已在本机验证。本机报告仅包含状态。"
                : "图片解析完成，但未验证图片。请查看保护隐私的诊断信息。"
        } catch {
            run = nil
            reportDirectory = nil
            status = "图片解析未能完成。请确认所选普通 SQLite 目录和原始微信数据目录可访问。"
        }
    }
}
#endif
