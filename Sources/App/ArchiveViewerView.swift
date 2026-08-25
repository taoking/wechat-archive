#if canImport(SwiftUI)
import AppKit
import AVFoundation
import AVKit
import SwiftUI
import WeChatArchiveCore

struct ArchiveViewerView: View {
    let workspace: ArchiveWorkspace
    @State private var archivePath = ""
    @State private var viewer: WeChatArchiveViewerDatabase?
    @State private var conversations = [ArchiveViewerConversation]()
    @State private var conversationLoadedOffset = 0
    @State private var conversationHasMore = false
    @State private var selectedConversationID: String?
    @State private var messages = [ArchiveViewerMessage]()
    @State private var messageHasMore = false
    @State private var status = "请选择 WeChatArchive 文件夹。查看器仅以只读方式打开 archive.sqlite。"
    @State private var searchText = ""
    @State private var showingExport = false
    @State private var timelinePaging = TimelinePagingState()
    @State private var timelineScrollInstruction: TimelineScrollInstruction = .none
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebouncer = SearchDebouncer()
    @State private var showingMessageSearch = false
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
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                Divider()
            HStack(spacing: 0) {
                List(selection: $selectedConversationID) {
                    ForEach(conversations) { conversation in
                        ConversationSidebarRow(conversation: conversation, viewer: viewer)
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
                        } else if selectedConversationID != nil, messageHasMore {
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
                    Button("恢复统计", systemImage: "chart.bar.doc.horizontal") { presentCoverageReport() }
                }
                if selectedConversation != nil {
                    if isShowingJumpedContext {
                        Button("回到最新", action: loadMessages)
                    } else {
                        Button("回到最新") { timelineScrollInstruction = .scrollToBottom }
                    }
                }
                if selectedConversation != nil {
                    Button("导出聊天记录…") { showingExport = true }
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
                MessageSearchSheet(viewer: viewer, onSelect: openSearchResult)
            }
        }
        .sheet(isPresented: $showingCoverageReport) {
            CoverageReportSheet(summary: coverageSummary)
        }
        .onAppear(perform: restoreLastArchive)
        .onDisappear {
            searchTask?.cancel()
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
    /// "加载更早的消息" is unavailable until the caller returns to the recent
    /// tail via "回到最新", since the offset here is no longer tail-relative.
    private func jumpToMessage(_ messageID: String, in conversationID: String) {
        guard let viewer else { return }
        do {
            guard let position = try viewer.messageOffset(conversationID: conversationID, messageID: messageID) else {
                status = "未找到该消息，归档内容可能已发生变化。"
                return
            }
            let windowSize = 100
            let offset = max(0, position - windowSize / 2)
            let page = try viewer.messagePage(conversationID: conversationID, offset: offset, limit: windowSize)
            messages = page.items
            messageHasMore = false
            isShowingJumpedContext = true
            videoPlayback.stop()
            voicePlayback.stop()
            let instruction = timelinePaging.replaceCentered(page.items.map(\.id), focus: messageID)
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
        guard let viewer, let conversationID = selectedConversationID else { return }
        do {
            let page = try viewer.recentMessagePage(conversationID: conversationID, offset: messages.count, limit: 100)
            let instruction = timelinePaging.prependOlder(page.items.map(\.id), hasMore: page.hasMore)
            messages.insert(contentsOf: page.items, at: 0)
            messageHasMore = page.hasMore
            requestTimelineScroll(instruction)
        } catch {
            status = "无法加载更多归档消息。"
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
        guard message.timestamp > 0 else { return "未知时间" }
        return Date(timeIntervalSince1970: TimeInterval(message.timestamp)).formatted(date: .abbreviated, time: .shortened)
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
    let onSelect: (ArchiveViewerMessageSearchResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results = [ArchiveViewerMessageSearchResult]()
    @State private var status = "输入关键词以搜索所有会话中的文本消息。"
    @State private var searchTask: Task<Void, Never>?
    @State private var debouncer = SearchDebouncer()

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
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(result.conversationTitle).font(.subheadline.bold())
                            Spacer()
                            Text(Date(timeIntervalSince1970: TimeInterval(result.timestamp)).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(result.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            status = "输入关键词以搜索所有会话中的文本消息。"
            return
        }
        let ticket = debouncer.schedule()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, debouncer.shouldRun(ticket: ticket) else { return }
            do {
                let page = try viewer.searchMessagePage(query: trimmed, limit: 100)
                results = page.items
                status = results.isEmpty ? "未找到匹配的文本消息。" : "找到 \(results.count) 条匹配消息\(page.hasMore ? "（仅显示前 100 条）" : "")。"
            } catch {
                results = []
                status = "搜索失败，请重试。"
            }
        }
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
