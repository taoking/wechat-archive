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
    @State private var timelineScrollToken = UUID()
    @State private var expandedVideoID: String?
    @StateObject private var voicePlayback = VoicePlaybackController()

    private var selectedConversation: ArchiveViewerConversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewer == nil {
                Form {
                    Section("打开 WeChatArchive") {
                        HStack {
                            Button("选择文件夹", action: chooseArchive)
                            TextField("粘贴归档文件夹路径", text: $archivePath)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(openArchive)
                            Button("只读打开", action: openArchive)
                        }
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("开始完整导出") { workspace.section = .archiveImport }
                    }
                    if !workspace.preferences.recentArchiveRoots.isEmpty {
                        Section("最近归档") {
                            ForEach(workspace.preferences.recentArchiveRoots, id: \.path) { recent in
                                Button(recent.lastPathComponent) {
                                    archivePath = recent.path()
                                    openArchive()
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxHeight: 136)
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
                Divider()
            }

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
                        Divider()
                    }
                    ScrollViewReader { proxy in
                    ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if selectedConversationID != nil, messageHasMore {
                            Button("加载更早的消息", action: loadMore)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            ArchiveTimelineMessageRow(
                                message: message,
                                showTimestamp: shouldShowTimestamp(at: index),
                                viewer: viewer,
                                expandedVideoID: $expandedVideoID,
                                voicePlayback: voicePlayback,
                                showSenderName: selectedConversation?.type == .group
                            )
                        }
                        Color.clear.frame(height: 1).id("timeline-bottom")
                    }
                    .padding()
                    }
                        .onChange(of: timelineScrollToken) { _, _ in
                            DispatchQueue.main.async { proxy.scrollTo("timeline-bottom", anchor: .bottom) }
                        }
                        .onAppear {
                            DispatchQueue.main.async { proxy.scrollTo("timeline-bottom", anchor: .bottom) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .center) {
                        if viewer != nil && selectedConversationID == nil { ContentUnavailableView("请选择会话", systemImage: "message") }
                    }
                }
            }
        }
        .onChange(of: selectedConversationID) { _, id in
            if viewer != nil { workspace.preferences.lastSelectedConversationID = id }
            loadMessages()
        }
        .onChange(of: searchText) { _, _ in loadConversations() }
        .navigationTitle("归档查看器")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("切换归档", action: chooseArchive)
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
        .onAppear(perform: restoreLastArchive)
        .onDisappear { voicePlayback.stop() }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 WeChatArchive 文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            archivePath = url.path()
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
            expandedVideoID = nil
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
            status = "无法打开有效的 WeChatArchive 文件夹。"
        }
    }

    private func loadMessages() {
        guard let viewer, let conversationID = selectedConversationID else { return }
        do {
            let page = try viewer.recentMessagePage(conversationID: conversationID, limit: 100)
            messages = page.items
            messageHasMore = page.hasMore
            expandedVideoID = nil
            voicePlayback.stop()
            timelineScrollToken = UUID()
        } catch {
            messages = []
            status = "无法读取所选归档会话时间线。"
        }
    }

    private func loadMore() {
        guard let viewer, let conversationID = selectedConversationID else { return }
        do {
            let page = try viewer.recentMessagePage(conversationID: conversationID, offset: messages.count, limit: 100)
            messages.insert(contentsOf: page.items, at: 0)
            messageHasMore = page.hasMore
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

    private func restoreLastArchive() {
        guard viewer == nil, workspace.preferences.reopenLastArchiveOnLaunch else { return }
        guard let root = try? workspace.preferences.validLastOpenedArchive() else { return }
        archivePath = root.path()
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
                        Text(Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .omitted, time: .shortened))
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
    }
}

private struct ArchiveTimelineMessageRow: View {
    let message: ArchiveViewerMessage
    let showTimestamp: Bool
    let viewer: WeChatArchiveViewerDatabase?
    @Binding var expandedVideoID: String?
    @ObservedObject var voicePlayback: VoicePlaybackController
    let showSenderName: Bool
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
                    .frame(maxWidth: 560, alignment: .leading)
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
    }

    private var bubbleColor: Color {
        switch message.direction {
        case .outgoing: .green.opacity(0.20)
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
           let image = NSImage(contentsOf: url) {
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
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 220, alignment: .leading)
        }
        if let video = preferredVideo, let viewer, let url = viewer.mediaURL(for: video, preferDecoded: false) {
            Button(expandedVideoID == video.id ? "隐藏视频" : "播放视频 \(durationLabel(video.duration))") {
                expandedVideoID = expandedVideoID == video.id ? nil : video.id
            }
            if expandedVideoID == video.id {
                VideoPlayer(player: AVPlayer(url: url)).frame(maxWidth: 560, minHeight: 260, maxHeight: 360)
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
            if let image = NSImage(contentsOf: url) {
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
#endif
