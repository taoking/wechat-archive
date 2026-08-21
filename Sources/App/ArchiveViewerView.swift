#if canImport(SwiftUI)
import AppKit
import AVFoundation
import AVKit
import SwiftUI
import WeChatArchiveCore

struct ArchiveViewerView: View {
    @State private var archivePath = ""
    @State private var viewer: WeChatArchiveViewerDatabase?
    @State private var conversations = [ArchiveViewerConversation]()
    @State private var conversationHasMore = false
    @State private var selectedConversationID: String?
    @State private var messages = [ArchiveViewerMessage]()
    @State private var messageHasMore = false
    @State private var status = "Choose a WeChatArchive folder. The viewer opens only archive.sqlite in read-only mode."
    @State private var expandedVideoID: String?
    @StateObject private var voicePlayback = VoicePlaybackController()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("WeChatArchive Folder") {
                    HStack {
                        Button("Choose Folder", action: chooseArchive)
                        TextField("Paste archive folder path", text: $archivePath)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(openArchive)
                        Button("Open Read-Only", action: openArchive)
                    }
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 136)

            HStack(spacing: 0) {
                List(selection: $selectedConversationID) {
                    ForEach(conversations) { conversation in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.title).lineLimit(1)
                            if let timestamp = conversation.lastMessageTimestamp, timestamp > 0 {
                                Text(Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .omitted, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(conversation.id)
                    }
                    if conversationHasMore {
                        Button("Load More Conversations", action: loadMoreConversations)
                    }
                }
                .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
                .overlay(alignment: .center) {
                    if viewer != nil && conversations.isEmpty { ContentUnavailableView("No conversations", systemImage: "bubble.left") }
                }

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            ArchiveTimelineMessageRow(
                                message: message,
                                showTimestamp: shouldShowTimestamp(at: index),
                                viewer: viewer,
                                expandedVideoID: $expandedVideoID,
                                voicePlayback: voicePlayback
                            )
                        }
                        if selectedConversationID != nil, messageHasMore {
                            Button("Load More", action: loadMore)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .center) {
                    if viewer != nil && selectedConversationID == nil { ContentUnavailableView("Select a conversation", systemImage: "message") }
                }
            }
        }
        .onChange(of: selectedConversationID) { _, _ in loadMessages() }
        .navigationTitle("Archive Viewer")
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a WeChatArchive folder"
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
            let loadedConversations = page.items
            viewer = database
            conversations = loadedConversations
            conversationHasMore = page.hasMore
            selectedConversationID = loadedConversations.first?.id
            messages = []
            expandedVideoID = nil
            status = "Archive opened read-only. The viewer uses only this archive folder."
            loadMessages()
        } catch {
            viewer = nil
            conversations = []
            conversationHasMore = false
            selectedConversationID = nil
            messages = []
            status = "Could not open a valid WeChatArchive folder."
        }
    }

    private func loadMessages() {
        guard let viewer, let conversationID = selectedConversationID else { return }
        do {
            let page = try viewer.messagePage(conversationID: conversationID, limit: 100)
            messages = page.items
            messageHasMore = page.hasMore
            expandedVideoID = nil
            voicePlayback.stop()
        } catch {
            messages = []
            status = "Could not read the selected archive timeline."
        }
    }

    private func loadMore() {
        guard let viewer, let conversationID = selectedConversationID else { return }
        do {
            let page = try viewer.messagePage(conversationID: conversationID, offset: messages.count, limit: 100)
            messages.append(contentsOf: page.items)
            messageHasMore = page.hasMore
        } catch {
            status = "Could not load more archived messages."
        }
    }

    private func loadMoreConversations() {
        guard let viewer else { return }
        do {
            let page = try viewer.conversationPage(offset: conversations.count, limit: 100)
            conversations.append(contentsOf: page.items)
            conversationHasMore = page.hasMore
        } catch {
            status = "Could not load more archived conversations."
        }
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

private struct ArchiveTimelineMessageRow: View {
    let message: ArchiveViewerMessage
    let showTimestamp: Bool
    let viewer: WeChatArchiveViewerDatabase?
    @Binding var expandedVideoID: String?
    @ObservedObject var voicePlayback: VoicePlaybackController

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
                    if message.direction == .outgoing { Spacer(minLength: 64) }
                    VStack(alignment: .leading, spacing: 8) {
                        if message.direction != .outgoing, let sender = message.senderDisplayName, !sender.isEmpty {
                            Text(sender).font(.caption).foregroundStyle(.secondary)
                        }
                        content
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(12)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                    if message.direction != .outgoing { Spacer(minLength: 64) }
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
            Text("[Unsupported message type \(message.rawLocalType.map(String.init) ?? "unknown")]").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let media = preferredImage,
           let viewer,
           let url = viewer.mediaURL(for: media, preferDecoded: true),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 360, alignment: .leading)
        } else {
            Label("Image unavailable — raw media archived", systemImage: "photo").foregroundStyle(.secondary)
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
            Button(expandedVideoID == video.id ? "Hide Video" : "Play Video \(durationLabel(video.duration))") {
                expandedVideoID = expandedVideoID == video.id ? nil : video.id
            }
            if expandedVideoID == video.id {
                VideoPlayer(player: AVPlayer(url: url)).frame(maxWidth: 560, minHeight: 260, maxHeight: 360)
            }
        } else {
            Label("Video unavailable — archive retains any available media", systemImage: "video").foregroundStyle(.secondary)
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
                Label(voicePlayback.playingID == voice.id ? "Pause \(durationLabel(voice.duration))" : "Play \(durationLabel(voice.duration))", systemImage: voicePlayback.playingID == voice.id ? "pause.fill" : "play.fill")
            }
        } else if message.media.contains(where: { $0.mediaType == .voice && $0.rawRelativePath != nil }) {
            Label("Raw Silk voice archived — playback conversion is unavailable", systemImage: "waveform").foregroundStyle(.secondary)
        } else {
            Label("Voice media unavailable", systemImage: "waveform.slash").foregroundStyle(.secondary)
        }
    }

    private var timestampLabel: String {
        guard message.timestamp > 0 else { return "Unknown time" }
        return Date(timeIntervalSince1970: TimeInterval(message.timestamp)).formatted(date: .abbreviated, time: .shortened)
    }

    private var preferredImage: ArchiveViewerMedia? {
        let ranks: [ArchiveV1MediaVariant: Int] = [.main: 3, .hd: 2, .thumbnail: 1]
        return message.media.filter { $0.mediaType == .image && $0.decodedRelativePath != nil }.sorted { lhs, rhs in
            let lhsArea = (lhs.width ?? 0) * (lhs.height ?? 0)
            let rhsArea = (rhs.width ?? 0) * (rhs.height ?? 0)
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            if lhs.decodedSize != rhs.decodedSize { return (lhs.decodedSize ?? 0) > (rhs.decodedSize ?? 0) }
            return (ranks[lhs.variant] ?? 0) > (ranks[rhs.variant] ?? 0)
        }.first
    }

    private var preferredVideo: ArchiveViewerMedia? { firstMedia(type: .video, variants: [.play, .raw], preferDecoded: false) }
    private var preferredVideoThumbnail: ArchiveViewerMedia? { firstMedia(type: .video, variants: [.thumbnail], preferDecoded: false) }

    private func firstMedia(type: ArchiveV1MediaType, variants: [ArchiveV1MediaVariant], preferDecoded: Bool) -> ArchiveViewerMedia? {
        for variant in variants {
            if let media = message.media.first(where: { $0.mediaType == type && $0.variant == variant && (preferDecoded ? $0.decodedRelativePath != nil || $0.rawRelativePath != nil : $0.rawRelativePath != nil || $0.decodedRelativePath != nil) }) { return media }
        }
        return nil
    }

    private func durationLabel(_ value: Double?) -> String { "\(max(0, Int((value ?? 0).rounded())))\"" }
}

@MainActor
private final class VoicePlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    private var player: AVAudioPlayer?

    func toggle(id: String, url: URL) {
        if playingID == id, let player, player.isPlaying {
            player.pause(); playingID = nil; return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else { self.player = nil; return }
        playingID = id
    }

    func stop() { player?.stop(); player = nil; playingID = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
#endif
