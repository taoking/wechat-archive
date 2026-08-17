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
    @State private var status = "Select the plain SQLite export, original WeChat account root, and a new or empty archive destination."

    private var canAnalyze: Bool {
        plainSQLiteRoot != nil && accountRoot != nil && archiveRoot != nil && !isWorking
    }

    private var canImport: Bool {
        canAnalyze && analysis != nil && archiveDestinationIsEmpty
    }

    private var archiveDestinationIsEmpty: Bool {
        guard let archiveRoot else { return false }
        guard FileManager.default.fileExists(atPath: archiveRoot.path()) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: archiveRoot.path()).isEmpty) == true
    }

    var body: some View {
        Form {
            Section("Archive Export") {
                directoryInput(
                    title: "Plain SQLite Export Root",
                    value: plainSQLiteRoot,
                    path: $plainSQLitePath,
                    choose: choosePlainSQLiteRoot,
                    usePath: usePlainSQLiteRoot
                )
                directoryInput(
                    title: "Original WeChat Account Root",
                    value: accountRoot,
                    path: $accountRootPath,
                    choose: chooseAccountRoot,
                    usePath: useAccountRoot
                )
                directoryInput(
                    title: "Archive Destination",
                    value: archiveRoot,
                    path: $archiveRootPath,
                    choose: chooseArchiveRoot,
                    usePath: useArchiveRoot
                )
                Text("Full Export opens plaintext SQLite and original media read-only. It does not copy keys or modify WeChat data. The destination must be new or empty; an existing archive is never merged. Archive folders use 0700 and private files use 0600.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(isWorking ? "Working…" : "Analyze Export", action: analyzeImport)
                        .disabled(!canAnalyze)
                    Picker("Import Limit", selection: $limit) {
                        ForEach(ArchiveImportLimit.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .frame(maxWidth: 290)
                    .disabled(isWorking)
                    Button("Full Export", action: importArchive)
                        .disabled(!canImport)
                    if isWorking {
                        Button("Cancel") { cancellation?.cancel() }
                    }
                }
            }

            if let analysis {
                Section("Export Analysis") {
                    HStack(spacing: 18) {
                        SummaryValue(label: "Message DBs", value: analysis.messageDatabaseCount)
                        SummaryValue(label: "Message Tables", value: analysis.messageTableCount)
                        SummaryValue(label: "Estimated Messages", value: analysis.estimatedMessageCount)
                    }
                    Text("The import streams records one at a time; it does not load an entire message table into memory.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress, isWorking {
                Section("Full Export Progress") {
                    Text("Exporting messages")
                    HStack(spacing: 18) {
                        SummaryValue(label: "Messages", value: progress.messagesRead)
                        SummaryValue(label: "Imported", value: progress.messagesImported)
                        SummaryValue(label: "Images Resolved", value: progress.imagesResolved)
                        SummaryValue(label: "Decoded", value: progress.imagesDecoded)
                        SummaryValue(label: "Raw-only", value: progress.imagesRawOnly)
                        SummaryValue(label: "Missing", value: progress.imagesMissing)
                    }
                    HStack(spacing: 18) {
                        SummaryValue(label: "Text", value: progress.textCount)
                        SummaryValue(label: "Image", value: progress.imageCount)
                        SummaryValue(label: "Video", value: progress.videoCount)
                        SummaryValue(label: "Voice", value: progress.voiceCount)
                        SummaryValue(label: "Unknown", value: progress.unknownCount)
                    }
                    Text("Media copied: \(ByteCountFormatter.string(fromByteCount: progress.mediaBytesCopied, countStyle: .file))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Database: message database · Table: message table")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary {
                Section("Full Export Result") {
                    HStack(spacing: 18) {
                        SummaryValue(label: "Messages", value: summary.messagesImported)
                        SummaryValue(label: "Text", value: summary.textCount)
                        SummaryValue(label: "Images", value: summary.imageCount)
                        SummaryValue(label: "Video", value: summary.videoCount)
                        SummaryValue(label: "Voice", value: summary.voiceCount)
                        SummaryValue(label: "Unknown", value: summary.unknownCount)
                        SummaryValue(label: "Conversations", value: summary.conversationCount)
                    }
                    HStack(spacing: 18) {
                        SummaryValue(label: "Raw DAT", value: summary.rawDATArchived)
                        SummaryValue(label: "Decoded", value: summary.decodedImages)
                        SummaryValue(label: "Video Files", value: summary.rawVideoArchived)
                        SummaryValue(label: "Raw Voice", value: summary.rawVoiceArchived)
                        SummaryValue(label: "Missing", value: summary.missingLocalMedia)
                        SummaryValue(label: "Decode Failures", value: summary.decodeFailures)
                    }
                    Text("Every imported message retains its complete original SQLite row. Unknown types remain archived as unknown rather than discarded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                Text(status).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Archive Export")
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
                Text("Not selected").foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("Choose Folder", action: choose)
            TextField("Paste absolute path", text: path)
                .textFieldStyle(.roundedBorder)
                .onSubmit(usePath)
            Button("Use Path", action: usePath)
        }
        .disabled(isWorking)
    }

    private func choosePlainSQLiteRoot() { chooseDirectory("Choose the Phase 1 plaintext SQLite export") { setPlainSQLiteRoot($0) } }
    private func chooseAccountRoot() { chooseDirectory("Choose the original WeChat account root") { setAccountRoot($0) } }
    private func chooseArchiveRoot() { chooseDirectory("Choose a new or empty WeChatArchive destination folder") { setArchiveRoot($0) } }

    private func usePlainSQLiteRoot() { useDirectoryPath(plainSQLitePath, setter: setPlainSQLiteRoot) }
    private func useAccountRoot() { useDirectoryPath(accountRootPath, setter: setAccountRoot) }
    private func useArchiveRoot() {
        do {
            let url = try ArchiveDestinationPath.resolve(archiveRootPath)
            setArchiveRoot(url)
        } catch {
            status = "The archive destination must be an absolute path whose existing parent is a local directory."
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
            status = "The path must be an existing local absolute directory."
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
            status = "Archive already exists or destination is not empty. Choose a new empty folder for Full Export."
        }
    }

    private func resetAnalysis() {
        analysis = nil
        summary = nil
        progress = nil
        status = "Paths selected. Click Analyze Export before full export."
    }

    private func analyzeImport() {
        guard let plainSQLiteRoot else { return }
        isWorking = true
        summary = nil
        status = "Analyzing message databases…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try WeChatArchiveV1Importer(imageKeyProvider: WeChatKVCommImageKeyProvider()).analyze(plainSQLiteRoot: plainSQLiteRoot) }
            }.value
            switch result {
            case let .success(value):
                analysis = value
                status = "Export analysis complete. Choose a limit, then start Full Export."
            case .failure:
                analysis = nil
                status = "Export analysis could not complete. Verify the plaintext export root."
            }
            isWorking = false
        }
    }

    private func importArchive() {
        guard let plainSQLiteRoot, let accountRoot, let archiveRoot else { return }
        let token = ArchiveImportCancellation()
        cancellation = token
        isWorking = true
        progress = nil
        summary = nil
        status = "Exporting private archive…"
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
                ? "Export cancelled. Completed message transactions remain valid; use a new destination for another full export."
                : "Full Export complete. Open the archive with Archive Viewer."
        case .failure:
            status = "Archive export could not complete. The destination is kept only for validation; use a new empty destination to retry."
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
        case .all: "All"
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
