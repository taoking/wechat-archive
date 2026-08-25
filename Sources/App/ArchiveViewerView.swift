#if canImport(SwiftUI)
import AppKit
import AVFoundation
import AVKit
import SwiftUI
import WeChatArchiveCore

private enum ArchiveViewerTimestampFormatter {
    static func timeline(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "未知时间" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        return dateFormatter.string(from: date)
    }

    static func detail(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "未知时间" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}

struct ArchiveViewerView: View {
    let workspace: ArchiveWorkspace
    @State private var archivePath = ""
    @State private var viewer: WeChatArchiveViewerDatabase?
    @State private var messageSearchService: ArchiveMessageSearchService?
    @State private var searchIndexStatus: String?
    @State private var isBuildingSearchIndex = false
    @State private var searchIndexTask: Task<Void, Never>?
    @State private var conversations = [ArchiveViewerConversation]()
    @State private var conversationLoadedOffset = 0
    @State private var conversationHasMore = false
    @State private var selectedConversationID: String?
    @State private var messages = [ArchiveViewerMessage]()
    @State private var messageHasMore = false
    @State private var messageHasNewer = false
    @State private var status = "请选择 WeChatArchive 文件夹。查看器仅以只读方式打开 archive.sqlite。"
    @State private var searchText = ""
    @State private var showingExport = false
    @State private var timelinePaging = TimelinePagingState()
    @State private var timelineScrollInstruction: TimelineScrollInstruction = .none
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebouncer = SearchDebouncer()
    @State private var showingMessageSearch = false
    @State private var showingDateNavigator = false
    @State private var pendingSearchJump: (conversationID: String, messageID: String)?
    @State private var highlightedMessageID: String?
    @State private var isShowingJumpedContext = false
    @State private var showingCoverageReport = false
    @State private var coverageSummary: ArchiveViewerCoverageSummary?
    @StateObject private var voicePlayback = VoicePlaybackController()
    @StateObject private var videoPlayback = VideoPlaybackController()

    private var selectedConversation: ArchiveViewerConversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    var body: some View {
        ZStack {
            ArchiveCanvas()
            VStack(spacing: 0) {
            if viewer == nil {
                VStack(spacing: 18) {
                    ArchiveBrandMark(size: 72)
                    Text("微信聊天归档").font(.largeTitle.bold())
                    Text("打开已有归档，随时离线回看自己的聊天记录。")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("打开归档", action: chooseArchive).buttonStyle(.borderedProminent)
                        Button("创建完整归档") { workspace.section = .archiveImport }.buttonStyle(.bordered)
                    }
                    if !workspace.preferences.recentArchiveRoots.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("最近归档").font(.headline)
                            ForEach(workspace.preferences.recentArchiveRoots, id: \.path) { recent in
                                Button(recent.lastPathComponent) {
                                    archivePath = recent.path(percentEncoded: false)
                                    openArchive()
                                }
                            }
                        }
                        .frame(maxWidth: 380, alignment: .leading)
                    }
                    DisclosureGroup("手动输入路径") {
                        HStack {
                            TextField("WeChatArchive 文件夹路径", text: $archivePath)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(openArchive)
                            Button("只读打开", action: openArchive)
                        }
                    }
                    .frame(maxWidth: 460)
                    Text(status).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                HStack {
                    Label(archivePath.isEmpty ? "已打开归档" : URL(fileURLWithPath: archivePath).lastPathComponent, systemImage: "archivebox")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(searchIndexStatus ?? status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                Divider()
            HStack(spacing: 0) {
                List(selection: $selectedConversationID) {
                    ForEach(conversations) { conversation in
                        ConversationSidebarRow(
                            conversation: conversation,
                            viewer: viewer,
                            onExport: {
                                selectedConversationID = conversation.id
                                showingExport = true
                            }
                        )
                            .tag(conversation.id)
                    }
                    if conversationHasMore {
                        Button("加载更多会话", action: loadMoreConversations)
                    }
                }
                .searchable(text: $searchText, placement: .sidebar, prompt: "搜索会话")
                .scrollContentBackground(.hidden)
                .background(.ultraThinMaterial)
                .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
                .overlay(alignment: .center) {
                    if viewer != nil && conversations.isEmpty { ContentUnavailableView("暂无会话", systemImage: "bubble.left") }
                }

                Divider()

                VStack(spacing: 0) {
                    if let selectedConversation {
                        HStack(spacing: 10) {
                            ArchiveAvatarView(viewer: viewer, avatar: selectedConversation.avatar, size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(selectedConversation.title).font(.headline)
                                if selectedConversation.type == .group {
                                    Text("\(selectedConversation.memberCount) 位成员").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(.regularMaterial)
                        Divider()
                    }
                    GeometryReader { geometry in
                    ScrollViewReader { proxy in
                    ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if isShowingJumpedContext {
                            Label("已跳转到搜索结果附近；点击“回到最新”恢复正常浏览", systemImage: "arrow.turn.up.left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        if selectedConversationID != nil, messageHasMore {
                            Button("加载更早的消息", action: loadMore)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            ArchiveTimelineMessageRow(
                                message: message,
                                showTimestamp: shouldShowTimestamp(at: index),
                                viewer: viewer,
                                videoPlayback: videoPlayback,
                                voicePlayback: voicePlayback,
                                showSenderName: selectedConversation?.type == .group,
                                bubbleMaxWidth: max(260, min(680, geometry.size.width * 0.66)),
                                isHighlighted: message.id == highlightedMessageID
                            )
                        }
                        if selectedConversationID != nil, messageHasNewer {
                            Button("加载更新的消息", action: loadNewer)
                                .frame(maxWidth: .infinity)
                        }
                        Color.clear.frame(height: 1).id("timeline-bottom")
                    }
                    .padding()
                    }
                        .onChange(of: timelineScrollInstruction) { _, instruction in
                            DispatchQueue.main.async {
                                switch instruction {
                                case .scrollToBottom:
                                    proxy.scrollTo("timeline-bottom", anchor: .bottom)
                                case let .preserveAnchor(id):
                                    proxy.scrollTo(id, anchor: .top)
                                case let .jumpTo(id):
                                    proxy.scrollTo(id, anchor: .center)
                                case .none:
                                    break
                                }
                            }
                        }
                        .onAppear {
                            DispatchQueue.main.async { proxy.scrollTo("timeline-bottom", anchor: .bottom) }
                        }
                    }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.52))
                    .overlay(alignment: .center) {
                        if viewer != nil && selectedConversationID == nil { ContentUnavailableView("请选择会话", systemImage: "message") }
                    }
                }
            }
        }
        }
        }
        .onChange(of: selectedConversationID) { _, id in
            if viewer != nil { workspace.preferences.lastSelectedConversationID = id }
            if let pending = pendingSearchJump, pending.conversationID == id {
                pendingSearchJump = nil
                jumpToMessage(pending.messageID, in: pending.conversationID)
            } else {
                loadMessages()
            }
        }
        .onChange(of: searchText) { _, _ in scheduleConversationSearch() }
        .navigationTitle("归档查看器")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("切换归档", action: chooseArchive)
                if viewer != nil {
                    Button("搜索消息内容", systemImage: "magnifyingglass") { showingMessageSearch = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .help("搜索所有消息")
                    if selectedConversation != nil {
                        Button("按日期跳转", systemImage: "calendar") { showingDateNavigator = true }
                            .help("按日期跳转")
                    }
                    Button("恢复统计", systemImage: "chart.bar.doc.horizontal") { presentCoverageReport() }
                    if isBuildingSearchIndex {
                        Button("取消建立搜索索引") { searchIndexTask?.cancel() }
                            .help("取消建立搜索索引")
                    }
                }
                if selectedConversation != nil {
                    if isShowingJumpedContext {
                        Button("回到最新", action: loadMessages)
                            .keyboardShortcut("j", modifiers: .command)
                    } else {
                        Button("回到最新") { timelineScrollInstruction = .scrollToBottom }
                            .keyboardShortcut("j", modifiers: .command)
                    }
                }
                if selectedConversation != nil {
                    Button("导出聊天记录…") { showingExport = true }
                        .keyboardShortcut("e", modifiers: .command)
                }
            }
        }
        .sheet(isPresented: $showingExport) {
            if let viewer, let conversation = selectedConversation {
                ConversationExportSheet(viewer: viewer, conversation: conversation, workspace: workspace)
            }
        }
        .sheet(isPresented: $showingMessageSearch) {
            if let viewer {
                MessageSearchSheet(viewer: viewer, searchService: messageSearchService, onSelect: openSearchResult)
            }
        }
        .sheet(isPresented: $showingDateNavigator) {
            if let viewer, let conversation = selectedConversation {
                DateNavigatorSheet(viewer: viewer, conversation: conversation, onSelect: jumpToDate)
            }
        }
        .sheet(isPresented: $showingCoverageReport) {
            CoverageReportSheet(summary: coverageSummary)
        }
        .onAppear(perform: restoreLastArchive)
        .onDisappear {
            searchTask?.cancel()
            searchIndexTask?.cancel()
            searchDebouncer.cancelAll()
            voicePlayback.stop()
            videoPlayback.stop()
        }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 WeChatArchive 文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            archivePath = url.path(percentEncoded: false)
            openArchive()
        }
    }

    private func openArchive() {
        do {
            let root = try LocalDatabaseDirectoryPath.resolve(archivePath)
            let database = try WeChatArchiveViewerDatabase(archiveRoot: root)
            let page = try database.conversationPage()
            var loadedConversations = page.items
            viewer = database
            let service = ArchiveMessageSearchService(archiveRoot: root)
            messageSearchService = service
            searchIndexStatus = "正在建立消息搜索索引…"
            isBuildingSearchIndex = true
            searchIndexTask?.cancel()
            searchIndexTask = Task.detached {
                let result = try? service.prepareIndex(
                    shouldCancel: { Task.isCancelled },
                    progress: { completed, total in
                        Task { @MainActor in
                            guard self.messageSearchService === service else { return }
                            self.searchIndexStatus = "正在建立消息搜索索引：\(completed) / \(total)"
                        }
                    }
                )
                await MainActor.run {
                    guard self.messageSearchService === service else { return }
                    self.isBuildingSearchIndex = false
                    self.searchIndexStatus = result == nil ? "消息搜索将临时使用兼容模式。" : nil
                }
            }
            let restoredID = workspace.preferences.lastSelectedConversationID
            if let restoredID,
               let restoredConversation = try database.conversation(id: restoredID),
               !loadedConversations.contains(where: { $0.id == restoredID }) {
                loadedConversations.insert(restoredConversation, at: 0)
            }
            conversations = loadedConversations
            conversationLoadedOffset = page.items.count
            conversationHasMore = page.hasMore
            selectedConversationID = loadedConversations.first(where: { $0.id == restoredID })?.id ?? loadedConversations.first?.id
            messages = []
            timelinePaging = TimelinePagingState()
            videoPlayback.stop()
            workspace.preferences.recordOpenedArchive(root)
            status = "归档已以只读方式打开。查看器仅使用此归档文件夹。"
            loadMessages()
        } catch {
            viewer = nil
            messageSearchService = nil
            searchIndexStatus = nil
            searchIndexTask?.cancel()
            isBuildingSearchIndex = false
            conversations = []
            conversationLoadedOffset = 0
            conversationHasMore = false
            selectedConversationID = nil
            messages = []
            timelinePaging = TimelinePagingState()
            videoPlayback.stop()
            status = "无法打开有效的 WeChatArchive 文件夹。"
        }
    }

    private func loadMessages() {
        guard let viewer, let conversationID = selectedConversationID else { return }
        do {
            let page = try viewer.recentMessagePage(conversationID: conversationID, limit: 100)
            messages = page.items
            messageHasMore = page.hasMore
            messageHasNewer = false
            isShowingJumpedContext = false
            let instruction = timelinePaging.replaceWithRecent(page.items.map(\.id), hasMore: page.hasMore)
            videoPlayback.stop()
            voicePlayback.stop()
            requestTimelineScroll(instruction)
        } catch {
            messages = []
            status = "无法读取所选归档会话时间线。"
        }
    }

    /// Loads a window of messages centered on `messageID` (used by search
    /// result navigation) instead of the usual tail-anchored recent page.
    /// Both older and newer paging remain available around this window.
    private func jumpToMessage(_ messageID: String, in conversationID: String) {
        guard let viewer else { return }
        do {
            guard try viewer.messageOffset(conversationID: conversationID, messageID: messageID) != nil else {
                status = "未找到该消息，归档内容可能已发生变化。"
                return
            }
            let window = try viewer.messageWindow(conversationID: conversationID, aroundMessageID: messageID, before: 50, after: 50)
            messages = window.items
            messageHasMore = window.hasOlder
            messageHasNewer = window.hasNewer
            isShowingJumpedContext = true
            videoPlayback.stop()
            voicePlayback.stop()
            let instruction = timelinePaging.replaceCentered(window.items.map(\.id), focus: messageID)
            requestTimelineScroll(instruction)
            highlightedMessageID = messageID
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if highlightedMessageID == messageID { highlightedMessageID = nil }
            }
        } catch {
            status = "无法定位到该消息。"
        }
    }

    private func openSearchResult(_ result: ArchiveViewerMessageSearchResult) {
        showingMessageSearch = false
        if selectedConversationID == result.conversationID {
            jumpToMessage(result.id, in: result.conversationID)
        } else {
            pendingSearchJump = (result.conversationID, result.id)
            ensureConversationVisible(result.conversationID)
            selectedConversationID = result.conversationID
        }
    }

    /// Inserts a conversation the sidebar hasn't paged in yet (e.g. a search
    /// hit outside the currently loaded page) so the chat header and sidebar
    /// selection resolve correctly once `selectedConversationID` changes.
    private func ensureConversationVisible(_ id: String) {
        guard let viewer, !conversations.contains(where: { $0.id == id }) else { return }
        if let conversation = try? viewer.conversation(id: id) {
            conversations.insert(conversation, at: 0)
        }
    }

    private func presentCoverageReport() {
        guard let viewer else { return }
        coverageSummary = try? viewer.coverageSummary()
        showingCoverageReport = true
    }

    private func loadMore() {
        guard let viewer,
              let conversationID = selectedConversationID,
              let firstID = messages.first?.id else { return }
        do {
            guard let cursor = try viewer.messageCursor(conversationID: conversationID, messageID: firstID) else { return }
            let page = try viewer.olderMessages(conversationID: conversationID, before: cursor, limit: 100)
            let additional = page.items.filter { candidate in !messages.contains(where: { $0.id == candidate.id }) }
            let instruction = timelinePaging.prependOlder(additional.map(\.id), hasMore: page.hasMore)
            messages.insert(contentsOf: additional, at: 0)
            messageHasMore = page.hasMore
            requestTimelineScroll(instruction)
        } catch {
            status = "无法加载更多归档消息。"
        }
    }

    private func loadNewer() {
        guard let viewer, let conversationID = selectedConversationID,
              let lastID = messages.last?.id else { return }
        do {
            guard let cursor = try viewer.messageCursor(conversationID: conversationID, messageID: lastID) else { return }
            let page = try viewer.newerMessages(conversationID: conversationID, after: cursor, limit: 100)
            let additional = page.items.filter { candidate in !messages.contains(where: { $0.id == candidate.id }) }
            messages.append(contentsOf: additional)
            messageHasNewer = page.hasMore
        } catch {
            status = "无法加载更新的归档消息。"
        }
    }

    private func jumpToDate(_ day: String) {
        guard let viewer, let conversationID = selectedConversationID else { return }
        do {
            guard let messageID = try viewer.firstMessageID(conversationID: conversationID, on: day) else {
                status = "该日期没有可定位的归档消息。"
                return
            }
            showingDateNavigator = false
            jumpToMessage(messageID, in: conversationID)
        } catch {
            status = "无法按日期定位消息。"
        }
    }

    private func loadMoreConversations() {
        guard let viewer else { return }
        do {
            let page = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try viewer.conversationPage(offset: conversationLoadedOffset, limit: 100)
                : try viewer.searchConversationPage(query: searchText, offset: conversationLoadedOffset, limit: 100)
            conversations.append(contentsOf: page.items)
            conversationLoadedOffset += page.items.count
            conversationHasMore = page.hasMore
        } catch {
            status = "无法加载更多归档会话。"
        }
    }

    private func loadConversations() {
        guard let viewer else { return }
        do {
            let page = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try viewer.conversationPage()
                : try viewer.searchConversationPage(query: searchText)
            conversations = page.items
            conversationLoadedOffset = page.items.count
            conversationHasMore = page.hasMore
            if let selectedConversationID, !conversations.contains(where: { $0.id == selectedConversationID }) {
                self.selectedConversationID = conversations.first?.id
            }
        } catch {
            status = "无法搜索归档会话。"
        }
    }

    private func scheduleConversationSearch() {
        searchTask?.cancel()
        let ticket = searchDebouncer.schedule()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, searchDebouncer.shouldRun(ticket: ticket) else { return }
            loadConversations()
        }
    }

    private func requestTimelineScroll(_ instruction: TimelineScrollInstruction) {
        timelineScrollInstruction = .none
        DispatchQueue.main.async {
            timelineScrollInstruction = instruction
        }
    }

    private func restoreLastArchive() {
        guard viewer == nil, workspace.preferences.reopenLastArchiveOnLaunch else { return }
        guard let root = try? workspace.preferences.validLastOpenedArchive() else { return }
        archivePath = root.path(percentEncoded: false)
        openArchive()
    }

    private func shouldShowTimestamp(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = messages[index - 1].timestamp
        let current = messages[index].timestamp
        guard previous > 0, current > 0 else { return true }
        return current - previous > 300 || !Calendar.current.isDate(
            Date(timeIntervalSince1970: TimeInterval(previous)),
            inSameDayAs: Date(timeIntervalSince1970: TimeInterval(current))
        )
    }
}

private struct ConversationSidebarRow: View {
    let conversation: ArchiveViewerConversation
    let viewer: WeChatArchiveViewerDatabase?
    let onExport: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ArchiveAvatarView(viewer: viewer, avatar: conversation.avatar, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(conversation.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if let timestamp = conversation.lastMessageTimestamp, timestamp > 0 {
                        Text(ConversationTimestampFormatter.string(for: Date(timeIntervalSince1970: TimeInterval(timestamp))))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(conversation.lastMessagePreview ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("打开") { }
            Button("导出聊天记录…", action: onExport)
            Divider()
            Button("复制会话名称") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(conversation.title, forType: .string)
            }
        }
    }
}

private struct ArchiveTimelineMessageRow: View {
    let message: ArchiveViewerMessage
    let showTimestamp: Bool
    let viewer: WeChatArchiveViewerDatabase?
    @ObservedObject var videoPlayback: VideoPlaybackController
    @ObservedObject var voicePlayback: VoicePlaybackController
    let showSenderName: Bool
    let bubbleMaxWidth: CGFloat
    var isHighlighted: Bool = false
    @State private var showsImagePreview = false

    var body: some View {
        VStack(spacing: 8) {
            if showTimestamp {
                Text(timestampLabel).font(.caption).foregroundStyle(.secondary)
            }
            if message.direction == .system {
                content
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(bubbleColor, in: Capsule())
            } else {
                HStack {
                    if message.direction == .outgoing { Spacer(minLength: 36) }
                    if message.direction != .outgoing {
                        ArchiveAvatarView(viewer: viewer, avatar: message.avatar, size: 34)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if showSenderName, message.direction != .outgoing, let sender = message.senderDisplayName, !sender.isEmpty {
                            Text(sender).font(.caption).foregroundStyle(.secondary)
                        }
                        content
                    }
                    .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                    .padding(12)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                    if message.direction == .outgoing {
                        ArchiveAvatarView(viewer: viewer, avatar: message.avatar, size: 34)
                    }
                    if message.direction != .outgoing { Spacer(minLength: 36) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isHighlighted ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHighlighted ? ArchivePalette.jade.opacity(0.16) : .clear)
        )
        .animation(.easeInOut(duration: 0.4), value: isHighlighted)
        .contextMenu { contextMenu }
    }

    private var bubbleColor: Color {
        switch message.direction {
        case .outgoing: ArchivePalette.jade.opacity(0.20)
        case .system: .gray.opacity(0.16)
        case .incoming, .unknown: .gray.opacity(0.12)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.normalizedType {
        case .text: Text(message.textContent ?? "").textSelection(.enabled)
        case .image: imageContent
        case .video: videoContent
        case .voice: voiceContent
        case .unknown:
            Text("[暂不支持的消息]").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let media = preferredImage,
           let viewer,
           let url = viewer.mediaURL(for: media, preferDecoded: true),
           let image = ArchiveMediaImageCache.shared.image(at: url) {
            Button {
                showsImagePreview = true
            } label: {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 360, alignment: .leading)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showsImagePreview) {
                ArchiveImagePreview(url: url)
            }
            if media.variant == .thumbnail {
                Text("仅有缩略图").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Label("图片不可用，已归档原始媒体", systemImage: "photo").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        if let thumbnail = preferredVideoThumbnail,
           let viewer,
           let url = viewer.mediaURL(for: thumbnail, preferDecoded: false),
           let image = ArchiveMediaImageCache.shared.image(at: url) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 220, alignment: .leading)
        }
        if let video = preferredVideo, let viewer, let url = viewer.mediaURL(for: video, preferDecoded: false) {
            Button(videoPlayback.expandedID == video.id ? "隐藏视频" : "播放视频 \(durationLabel(video.duration))") {
                videoPlayback.toggle(id: video.id, url: url)
            }
            if videoPlayback.expandedID == video.id, let player = videoPlayback.player {
                VideoPlayer(player: player).frame(maxWidth: 560, minHeight: 260, maxHeight: 360)
            }
        } else {
            Label("视频不可用，归档保留了可用媒体", systemImage: "video").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var voiceContent: some View {
        if let voice = message.media.first(where: { $0.mediaType == .voice }),
           let viewer,
           let url = viewer.mediaURL(for: voice, preferDecoded: true),
           url.pathExtension.lowercased() == "wav" {
            Button {
                voicePlayback.toggle(id: voice.id, url: url)
            } label: {
                Label(voicePlayback.playingID == voice.id ? "暂停 \(voicePlayback.progressLabel(fallbackDuration: voice.duration))" : "播放 \(durationLabel(voice.duration))", systemImage: voicePlayback.playingID == voice.id ? "pause.fill" : "play.fill")
            }
        } else if message.media.contains(where: { $0.mediaType == .voice && $0.rawRelativePath != nil }) {
            Label("已归档原始 Silk 语音，暂无法播放转换结果", systemImage: "waveform").foregroundStyle(.secondary)
        } else {
            Label("语音媒体不可用", systemImage: "waveform.slash").foregroundStyle(.secondary)
        }
    }

    private var timestampLabel: String {
        ArchiveViewerTimestampFormatter.timeline(message.timestamp)
    }

    private var preferredImage: ArchiveViewerMedia? { ArchiveViewerMediaSelector.preferredImage(in: message.media) }

    private var preferredVideo: ArchiveViewerMedia? { firstMedia(type: .video, variants: [.play, .raw], preferDecoded: false) }
    private var preferredVideoThumbnail: ArchiveViewerMedia? { firstMedia(type: .video, variants: [.thumbnail], preferDecoded: false) }

    private func firstMedia(type: ArchiveV1MediaType, variants: [ArchiveV1MediaVariant], preferDecoded: Bool) -> ArchiveViewerMedia? {
        for variant in variants {
            if let media = message.media.first(where: { $0.mediaType == type && $0.variant == variant && (preferDecoded ? $0.decodedRelativePath != nil || $0.rawRelativePath != nil : $0.rawRelativePath != nil || $0.decodedRelativePath != nil) }) { return media }
        }
        return nil
    }

    private func durationLabel(_ value: Double?) -> String { "\(max(0, Int((value ?? 0).rounded()))) 秒" }

    @ViewBuilder
    private var contextMenu: some View {
        if message.normalizedType == .text {
            Button("复制") { copy(ArchiveViewerMessageCopyFormatter.text(message)) }
            Button("复制文字和时间") { copy(ArchiveViewerMessageCopyFormatter.textWithTimestamp(message)) }
            if showSenderName {
                Button("复制文字、发送者和时间") { copy(ArchiveViewerMessageCopyFormatter.textWithSenderAndTimestamp(message)) }
            }
        }
        if let media = contextMedia, let viewer, let url = viewer.mediaURL(for: media, preferDecoded: message.normalizedType != .video) {
            if message.normalizedType == .image {
                Button("打开预览") { showsImagePreview = true }
                Button("复制图片") {
                    if let image = ArchiveMediaImageCache.shared.image(at: url) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                }
            }
            if message.normalizedType == .video {
                Button("播放") { videoPlayback.toggle(id: media.id, url: url) }
            }
            if message.normalizedType == .voice {
                Button(voicePlayback.playingID == media.id ? "暂停" : "播放") { voicePlayback.toggle(id: media.id, url: url) }
            }
            Button("另存为…") { save(url: url, filename: defaultMediaFilename(for: media, url: url)) }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if message.normalizedType == .unknown {
            Button("复制时间") { copy(timestampLabel) }
        }
    }

    private var contextMedia: ArchiveViewerMedia? {
        switch message.normalizedType {
        case .image: preferredImage
        case .video: preferredVideo
        case .voice: message.media.first { $0.mediaType == .voice && ($0.decodedRelativePath != nil || $0.rawRelativePath != nil) }
        case .text, .unknown: nil
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func save(url: URL, filename: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            NSSound.beep()
        }
    }

    private func defaultMediaFilename(for media: ArchiveViewerMedia, url: URL) -> String {
        let stamp = Date(timeIntervalSince1970: TimeInterval(max(0, message.timestamp))).formatted(.dateTime.year().month().day().hour().minute())
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let prefix: String
        switch media.mediaType {
        case .image: prefix = "image"
        case .video: prefix = "video"
        case .voice: prefix = "voice"
        }
        return "\(prefix)-\(stamp).\(url.pathExtension.isEmpty ? "bin" : url.pathExtension)"
    }
}

@MainActor
private final class ArchiveAvatarImageCache {
    static let shared = ArchiveAvatarImageCache()
    private let values = NSCache<NSString, NSImage>()

    func image(for key: String, load: () -> NSImage?) -> NSImage? {
        if let image = values.object(forKey: key as NSString) { return image }
        guard let image = load() else { return nil }
        values.setObject(image, forKey: key as NSString, cost: max(1, Int(image.size.width * image.size.height)))
        return image
    }
}

/// Caches decoded message images and video thumbnails by archive-relative
/// URL, avoiding a synchronous re-decode of the same file on every scroll
/// pass. Never reads outside the URLs `WeChatArchiveViewerDatabase` already
/// validated as being inside the opened archive.
@MainActor
private final class ArchiveMediaImageCache {
    static let shared = ArchiveMediaImageCache()
    private let values = NSCache<NSString, NSImage>()

    func image(at url: URL) -> NSImage? {
        let key = url.path(percentEncoded: false) as NSString
        if let cached = values.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        values.setObject(image, forKey: key, cost: max(1, Int(image.size.width * image.size.height)))
        return image
    }
}

@MainActor
private struct ArchiveAvatarView: View {
    let viewer: WeChatArchiveViewerDatabase?
    let avatar: ArchiveViewerAvatar?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").foregroundStyle(.secondary).padding(size * 0.25)
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.14), in: Circle())
        .clipShape(Circle())
    }

    private var image: NSImage? {
        guard let avatar, let viewer, let url = viewer.avatarURL(for: avatar) else { return nil }
        return ArchiveAvatarImageCache.shared.image(for: avatar.id) { NSImage(contentsOf: url) }
    }
}

private struct ArchiveImagePreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("图片预览").font(.headline)
                Spacer()
                Button("适应窗口") { scale = 1 }
                Button("100%") { scale = 1 }
                Slider(value: $scale, in: 0.25...3).frame(width: 160)
                Button("关闭", action: dismiss.callAsFunction)
            }
            .padding(.horizontal)
            if let image = ArchiveMediaImageCache.shared.image(at: url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
                        .padding()
                }
            } else {
                ContentUnavailableView("图片不可用", systemImage: "photo")
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

@MainActor
private final class VoicePlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(id: String, url: URL) {
        if playingID == id, let player, player.isPlaying {
            player.pause(); playingID = nil; timer?.invalidate(); timer = nil; return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else { self.player = nil; return }
        playingID = id
        duration = player.duration
        currentTime = player.currentTime
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    func progressLabel(fallbackDuration: Double?) -> String {
        let total = duration > 0 ? duration : (fallbackDuration ?? 0)
        return "\(seconds(currentTime)) / \(seconds(total))"
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil; playingID = nil; currentTime = 0; duration = 0
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }

    private func seconds(_ value: TimeInterval) -> String { "\(max(0, Int(value.rounded()))) 秒" }
}

@MainActor
private final class VideoPlaybackController: ObservableObject {
    @Published private(set) var expandedID: String?
    private(set) var player: AVPlayer?

    func toggle(id: String, url: URL) {
        if expandedID == id {
            stop()
            return
        }
        stop()
        let player = AVPlayer(url: url)
        self.player = player
        expandedID = id
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        expandedID = nil
    }
}

/// Searches message text across every conversation in the opened archive.
/// It never opens a source WeChat directory or database; it only queries
/// the already-imported, read-only `archive.sqlite`.
private struct MessageSearchSheet: View {
    let viewer: WeChatArchiveViewerDatabase
    let searchService: ArchiveMessageSearchService?
    let onSelect: (ArchiveViewerMessageSearchResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results = [ArchiveViewerMessageSearchResult]()
    @State private var status = "输入关键词以搜索所有会话中的文本消息。"
    @State private var searchTask: Task<Void, Never>?
    @State private var debouncer = SearchDebouncer()
    @State private var hasMore = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("搜索消息内容").font(.headline)
                Spacer()
                Button("关闭", action: dismiss.callAsFunction)
            }
            .padding()
            TextField("搜索文本消息…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .onChange(of: query) { _, _ in scheduleSearch() }
            Text(status).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 6)
            List(results) { result in
                Button {
                    onSelect(result)
                } label: {
                    HStack(spacing: 10) {
                        ArchiveAvatarView(viewer: viewer, avatar: avatar(for: result), size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(result.conversationTitle).font(.subheadline.bold())
                                Spacer()
                                Text(ArchiveViewerTimestampFormatter.detail(result.timestamp))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            highlightedSnippet(result.snippet, query: query)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            if hasMore {
                Button("加载更多结果", action: loadMore)
                    .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            hasMore = false
            status = "输入关键词以搜索所有会话中的文本消息。"
            return
        }
        let ticket = debouncer.schedule()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, debouncer.shouldRun(ticket: ticket) else { return }
            performSearch(query: trimmed, offset: 0, appending: false)
        }
    }

    private func loadMore() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSearch(query: trimmed, offset: results.count, appending: true)
    }

    private func performSearch(query: String, offset: Int, appending: Bool) {
        do {
            let page = try (searchService?.search(query: query, offset: offset, limit: 50)
                ?? viewer.searchMessagePage(query: query, offset: offset, limit: 50))
            if appending {
                results.append(contentsOf: page.items.filter { candidate in !results.contains(where: { $0.id == candidate.id }) })
            } else {
                results = page.items
            }
            hasMore = page.hasMore
            status = results.isEmpty ? "未找到匹配的文本消息。" : "已显示 \(results.count) 条匹配消息\(page.hasMore ? "，可继续加载。" : "。")"
        } catch {
            results = []
            hasMore = false
            status = "搜索失败，请重试。"
        }
    }

    private func highlightedSnippet(_ snippet: String, query: String) -> Text {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let range = snippet.range(of: trimmed, options: [.caseInsensitive]) else {
            return Text(snippet)
        }
        return Text(String(snippet[..<range.lowerBound]))
            + Text(String(snippet[range])).foregroundColor(.accentColor)
            + Text(String(snippet[range.upperBound...]))
    }

    private func avatar(for result: ArchiveViewerMessageSearchResult) -> ArchiveViewerAvatar? {
        guard let conversation = try? viewer.conversation(id: result.conversationID) else { return nil }
        return conversation.avatar
    }
}

/// A local-calendar navigator for the selected conversation. It requests
/// aggregate day buckets only; message bodies are loaded after a day is chosen.
private struct DateNavigatorSheet: View {
    let viewer: WeChatArchiveViewerDatabase
    let conversation: ArchiveViewerConversation
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var buckets = [ArchiveViewerDateBucket]()
    @State private var status = "正在读取有消息的日期…"
    @State private var selectedMonth: String?

    private var months: [String] {
        Array(Set(buckets.map { String($0.day.prefix(7)) })).sorted(by: >)
    }

    private var displayedMonth: String? { selectedMonth ?? months.first }

    private var bucketsByDay: [String: ArchiveViewerDateBucket] {
        Dictionary(uniqueKeysWithValues: buckets.map { ($0.day, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("按日期跳转", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Button("关闭", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            if buckets.isEmpty {
                ContentUnavailableView(status, systemImage: "calendar.badge.exclamationmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    HStack {
                        Button("上个月", systemImage: "chevron.left", action: showOlderMonth)
                            .disabled(!canShowOlderMonth)
                        Spacer()
                        Picker("有消息的月份", selection: $selectedMonth) {
                            ForEach(months, id: \.self) { month in
                                Text(monthLabel(month)).tag(Optional(month))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                        Spacer()
                        Button("下个月", systemImage: "chevron.right", action: showNewerMonth)
                            .disabled(!canShowNewerMonth)
                    }
                    .padding(.horizontal)

                    let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
                    LazyVGrid(columns: columns, spacing: 7) {
                        ForEach(weekdayLabels, id: \.self) { label in
                            Text(label).font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(Array(calendarCells.enumerated()), id: \.offset) { _, day in
                            if let day {
                                let key = dayKey(day)
                                let bucket = bucketsByDay[key]
                                Button {
                                    if bucket != nil { onSelect(key) }
                                } label: {
                                    VStack(spacing: 2) {
                                        Text("\(Calendar.current.component(.day, from: day))")
                                        Text(bucket.map { "\($0.messageCount)" } ?? "")
                                            .font(.system(size: 9))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .foregroundStyle(bucket == nil ? .secondary : .primary)
                                    .background(bucket == nil ? .clear : Color.accentColor.opacity(0.16), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(bucket == nil)
                                .help(bucket.map { "\($0.messageCount) 条消息" } ?? "没有消息")
                            } else {
                                Color.clear.frame(height: 34)
                            }
                        }
                    }
                    .padding(.horizontal)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 440)
        .onAppear(perform: load)
    }

    private func load() {
        do {
            buckets = try viewer.conversationDateBuckets(conversationID: conversation.id)
            selectedMonth = months.first
            status = buckets.isEmpty ? "该会话没有可用的日期索引。" : ""
        } catch {
            buckets = []
            status = "无法读取该会话的日期导航。"
        }
    }

    private func monthLabel(_ value: String) -> String {
        let components = value.split(separator: "-")
        guard components.count == 2 else { return value }
        return "\(components[0])年\(Int(components[1]) ?? 0)月"
    }

    private var weekdayLabels: [String] {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let start = Calendar.current.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private var calendarCells: [Date?] {
        guard let value = displayedMonth else { return [] }
        let components = value.split(separator: "-")
        guard components.count == 2,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let first = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = Calendar.current.range(of: .day, in: .month, for: first) else { return [] }
        let firstWeekday = Calendar.current.component(.weekday, from: first)
        let padding = (firstWeekday - Calendar.current.firstWeekday + 7) % 7
        var result = Array<Date?>(repeating: nil, count: padding)
        result += days.compactMap { Calendar.current.date(byAdding: .day, value: $0 - 1, to: first) }
        return result
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = Calendar.current.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var selectedMonthIndex: Int? {
        guard let displayedMonth else { return nil }
        return months.firstIndex(of: displayedMonth)
    }

    private var canShowOlderMonth: Bool {
        guard let selectedMonthIndex else { return false }
        return selectedMonthIndex + 1 < months.count
    }

    private var canShowNewerMonth: Bool {
        guard let selectedMonthIndex else { return false }
        return selectedMonthIndex > 0
    }

    private func showOlderMonth() {
        guard let selectedMonthIndex, canShowOlderMonth else { return }
        selectedMonth = months[selectedMonthIndex + 1]
    }

    private func showNewerMonth() {
        guard let selectedMonthIndex, canShowNewerMonth else { return }
        selectedMonth = months[selectedMonthIndex - 1]
    }
}

/// Displays how much of the archive Core could normalize into a viewable
/// type, computed on demand from `archive.sqlite` aggregates only.
private struct CoverageReportSheet: View {
    let summary: ArchiveViewerCoverageSummary?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("归档恢复统计").font(.headline)
                Spacer()
                Button("关闭", action: dismiss.callAsFunction)
            }
            .padding()
            if let summary {
                Form {
                    Section("总览") {
                        LabeledContent("会话数", value: "\(summary.totalConversations)")
                        LabeledContent("消息数", value: "\(summary.totalMessages)")
                    }
                    Section("消息类型分布") {
                        ForEach(summary.byType) { row in
                            LabeledContent(localizedType(row.normalizedType), value: countLabel(row.messageCount, of: summary.totalMessages))
                        }
                    }
                    Section("媒体恢复状态") {
                        if summary.mediaByStatus.isEmpty {
                            Text("此归档不包含媒体资产。").foregroundStyle(.secondary)
                        } else {
                            ForEach(summary.mediaByStatus) { row in
                                LabeledContent("\(localizedMediaType(row.mediaType)) · \(localizedStatus(row.status))", value: "\(row.count)")
                            }
                        }
                    }
                    Text("统计仅来自归档内已聚合的计数，不读取消息正文或媒体内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("暂无统计数据", systemImage: "chart.bar.doc.horizontal")
            }
        }
        .frame(minWidth: 420, minHeight: 460)
    }

    private func countLabel(_ count: Int, of total: Int) -> String {
        guard total > 0 else { return "\(count)" }
        let percentage = Double(count) / Double(total) * 100
        return "\(count)（\(String(format: "%.1f", percentage))%）"
    }

    private func localizedType(_ type: ArchiveV1NormalizedType) -> String {
        switch type {
        case .text: "文本"
        case .image: "图片"
        case .video: "视频"
        case .voice: "语音"
        case .unknown: "未识别"
        }
    }

    private func localizedMediaType(_ type: ArchiveV1MediaType) -> String {
        switch type {
        case .image: "图片"
        case .video: "视频"
        case .voice: "语音"
        }
    }

    private func localizedStatus(_ status: ArchiveV1MediaStatus) -> String {
        switch status {
        case .missing: "缺失"
        case .rawArchived: "已保留原始文件"
        case .decoded: "已解码"
        case .decodeUnsupported: "暂不支持解码"
        case .imageKeyUnavailable: "缺少解密密钥"
        case .imageKeyRejected: "密钥不匹配"
        case .invalidDATLayout: "文件结构异常"
        case .invalidPadding: "填充校验失败"
        case .decodeFailed: "解码失败"
        case .decodedUnknownFormat: "解码后格式未知"
        case .unsupportedVersion: "版本不支持"
        case .resolutionConflict: "定位冲突"
        case .archiveCopyFailed: "归档复制失败"
        case .rawCopyFailed: "原始文件复制失败"
        case .decodedCopyFailed: "解码文件复制失败"
        }
    }
}
#endif
