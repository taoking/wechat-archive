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
    @State private var progress: MediaScanProgress?
    @State private var isWorking = false
    @State private var cancellation: MessageDiscoveryCancellation?
    @State private var status = "Choose the Phase 1 plain SQLite directory. Its Phase 2 schema report will be loaded automatically."

    private var canDiscover: Bool {
        exportRoot != nil && mediaRoot != nil && selectedCandidate != nil && !isWorking
    }

    var body: some View {
        Form {
            Section("Message Discovery") {
                LabeledContent("Plain SQLite Directory") {
                    selectedDirectoryLabel(exportRoot)
                }
                HStack {
                    Button("Choose Folder", action: chooseExportRoot)
                    TextField("Paste absolute export path", text: $exportRootPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useEnteredExportRoot)
                    Button("Use Path", action: useEnteredExportRoot)
                }
                .disabled(isWorking)

                LabeledContent("Phase 2 Schema Report") {
                    if let schemaReportURL {
                        Label(displayPath(schemaReportURL), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("Not found — run Schema Discovery first").foregroundStyle(.secondary)
                    }
                }
                Text("选择普通 SQLite 根目录后，应用只读取 `SchemaReports/schema-summary.json` 来列出消息表候选，不会重新读取聊天记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Reload Phase 2 Report", action: loadDefaultSchemaReport)
                    .disabled(exportRoot == nil || isWorking)

                LabeledContent("Original WeChat Data Root") {
                    selectedDirectoryLabel(mediaRoot)
                }
                HStack {
                    Button("Choose Folder", action: chooseMediaRoot)
                    TextField("Paste absolute original WeChat data path", text: $mediaRootPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useEnteredMediaRoot)
                    Button("Use Path", action: useEnteredMediaRoot)
                }
                .disabled(isWorking)
                Text("仅选择你本人有权访问的原始微信数据目录。扫描只读取文件头和必要的已缩小候选文件，不会复制、移动或修改媒体文件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Candidate & Sample") {
                Picker("Message Table", selection: $selectedCandidate) {
                    Text("Select a discovered message table").tag(MessageTableCandidate?.none)
                    ForEach(candidates) { candidate in
                        Text("\(redactedRelativePath(candidate.databaseRelativePath)) · \(candidate.tableName) · \(candidate.rowCount ?? 0) rows · score \(candidate.score)")
                            .tag(Optional(candidate))
                    }
                }
                .disabled(candidates.isEmpty || isWorking)
                Picker("Sample Limit", selection: $sampleLimit) {
                    Text("100 rows").tag(100)
                    Text("250 rows").tag(250)
                    Text("500 rows").tag(500)
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
                    Button(isWorking ? "Discovering…" : "Discover Message & Media", action: discover)
                        .disabled(!canDiscover)
                    if isWorking {
                        Button("Cancel") { cancellation?.cancel() }
                    }
                }
                if let progress, isWorking {
                    Label(
                        "Scanned \(progress.scannedFileCount) files · \(progress.discoveredMediaCount) candidates · \(redactedRelativePath(progress.currentRelativePath))",
                        systemImage: "photo.stack"
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }

            if let discoveryResult {
                discoveryResults(discoveryResult)
            }

            Section("Status") {
                Text(status).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Message Discovery")
    }

    @ViewBuilder
    private func discoveryResults(_ result: MessageMediaDiscoveryResult) -> some View {
        Section("Limited Local Verification") {
            HStack(spacing: 18) {
                MessageDiscoverySummaryValue(label: "Sampled", value: result.messageAnalysis.records.count)
                MessageDiscoverySummaryValue(label: "Text-shaped", value: result.messageAnalysis.textCandidates.count)
                MessageDiscoverySummaryValue(label: "Media refs", value: result.messageAnalysis.mediaReferences.count)
                MessageDiscoverySummaryValue(label: "Resolved", value: result.links.filter { $0.resolvedFile != nil }.count)
            }
            if let reportDirectory {
                Button("Open Local Analysis Report") { NSWorkspace.shared.open(reportDirectory) }
            }
            Text("报告权限为目录 0700、文件 0600；它保留结构性发现和验证结果，不含本机预览内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Confirmed Field Mapping") {
            ForEach(fieldMappingRows(result.messageAnalysis.fieldMapping), id: \.label) { row in
                LabeledContent(row.label, value: row.column ?? "Not detected")
            }
            if let timestamp = result.messageAnalysis.timestampInference {
                Text("Timestamp: \(timestamp.unit.rawValue), confidence \(String(format: "%.2f", timestamp.confidence)), valid \(timestamp.validSampleCount)/\(timestamp.sampleCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Raw Type Observations") {
            if result.messageAnalysis.typeObservations.isEmpty {
                Text("No integer raw type column was detected.").foregroundStyle(.secondary)
            } else {
                ForEach(result.messageAnalysis.typeObservations, id: \.rawType) { observation in
                    Text("Raw type \(observation.rawType): \(observation.count) sampled rows")
                }
            }
            ForEach(result.observedTypeMappings, id: \.rawType) { mapping in
                Label(
                    "Raw type \(mapping.rawType) → \(mapping.observedType.rawValue) (\(mapping.count) resolved local file(s), \(mapping.confidence.rawValue))",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
            }
        }

        Section("Local Sample Preview") {
            Text("Only this local window may show a shortened preview. It is neither written to the report nor sent over the network.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(result.messageAnalysis.records.prefix(10), id: \.identity) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(redactedRelativePath(record.identity.databaseRelativePath)) · \(record.identity.tableName) · row \(record.identity.rowIdentifier)")
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

        Section("Media File Resolution") {
            if result.links.isEmpty {
                Text("No structural media reference was found in the selected sample.").foregroundStyle(.secondary)
            } else {
                ForEach(result.links, id: \.reference.sourceMessageIdentity) { link in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("row \(link.reference.sourceMessageIdentity.rowIdentifier) · \(link.reference.mediaTypeHint?.rawValue ?? "unknown") · \(link.confidence.rawValue)")
                        Text(link.reason).font(.caption).foregroundStyle(.secondary)
                        if let file = link.resolvedFile {
                            Text("Local file: \(redactedRelativePath(file.relativePath)) · \(file.format.rawValue) · \(file.fileSize) bytes\(file.imageDimensions.map { " · \($0.width) × \($0.height)" } ?? "")")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
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
                ? "Phase 2 report loaded, but it has no selectable message table candidates."
                : "Phase 2 report loaded. Choose a source media root and run a limited discovery."
        } catch {
            schemaReportURL = nil
            candidates = []
            selectedCandidate = nil
            status = "Plain SQLite directory selected. Phase 2 report not found; run Schema Discovery first."
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
            ? "Original data root selected. Load the Phase 2 schema report by selecting the plain SQLite directory."
            : "Original data root selected. Ready for a limited message and media discovery."
    }

    private func resetDiscovery() {
        discoveryResult = nil
        reportDirectory = nil
        progress = nil
    }

    private func discover() {
        guard let exportRoot, let mediaRoot, let candidate = selectedCandidate else { return }
        resetDiscovery()
        let cancellation = MessageDiscoveryCancellation()
        self.cancellation = cancellation
        isWorking = true
        status = "Reading up to \(sampleLimit) rows and scanning selected local media…"
        var continuation: AsyncStream<MediaScanProgress>.Continuation?
        let stream = AsyncStream<MediaScanProgress>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        guard let continuation else {
            isWorking = false
            status = "Could not start local discovery."
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

    private func selectedDirectoryLabel(_ url: URL?) -> some View {
        Group {
            if let url {
                Label(displayPath(url), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text("Not selected").foregroundStyle(.secondary)
            }
        }
    }

    private func fieldMappingRows(_ mapping: MessageFieldMapping) -> [(label: String, column: String?)] {
        [
            ("Local message ID", mapping.messageIDColumn),
            ("Server message ID", mapping.serverMessageIDColumn),
            ("Timestamp", mapping.timestampColumn),
            ("Raw type", mapping.rawTypeColumn),
            ("Sender", mapping.senderColumn),
            ("Conversation", mapping.conversationColumn),
            ("Content", mapping.contentColumn),
            ("Payload", mapping.payloadColumn)
        ]
    }

    private func sampleMetadata(_ record: SourceMessageRecord, analysis: MessageSampleAnalysis) -> String {
        let timestamp = analysis.fieldMapping.timestampColumn
            .flatMap { record.values[$0]?.integerValue }
            .flatMap { analysis.timestampInference?.date(for: $0) }
            .map { $0.formatted(date: .abbreviated, time: .standard) } ?? "timestamp unavailable"
        let rawType = analysis.fieldMapping.rawTypeColumn
            .flatMap { record.values[$0]?.integerValue }
            .map(String.init) ?? "unavailable"
        let kind = analysis.payloadInspections[record.identity]?.kind.rawValue ?? "unclassified"
        return "time: \(timestamp) · raw type: \(rawType) · content kind: \(kind)"
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
            status = "Limited discovery complete. \(result.messageAnalysis.records.count) rows sampled; \(result.links.filter { $0.resolvedFile != nil }.count) media link(s) resolved."
        } catch is CancellationError {
            result = nil
            reportDirectory = nil
            status = "Message and media discovery cancelled."
        } catch {
            result = nil
            reportDirectory = nil
            status = "Local discovery could not complete. Confirm the selected plain SQLite and original WeChat directories are accessible."
        }
    }
}
#endif
