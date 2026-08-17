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
    @State private var selectedConversationID: String?
    @State private var messages = [ArchiveViewerMessage]()
    @State private var status = "Choose a WeChatArchive folder. The viewer opens only archive.sqlite in read-only mode."
    @State private var expandedVideoID: String?

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
                List(conversations, selection: $selectedConversationID) { conversation in
                    Text(conversation.title).tag(conversation.id)
                }
                .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
                .overlay(alignment: .center) {
                    if viewer != nil && conversations.isEmpty { ContentUnavailableView("No conversations", systemImage: "bubble.left") }
                }

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            ArchiveTimelineMessageRow(message: message, viewer: viewer, expandedVideoID: $expandedVideoID)
                        }
                        if selectedConversationID != nil, messages.count >= 100 {
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
            let loadedConversations = try database.listConversations()
            viewer = database
            conversations = loadedConversations
            selectedConversationID = loadedConversations.first?.id
            messages = []
            expandedVideoID = nil
            status = "Archive opened read-only. The viewer uses only this archive folder."
            loadMessages()
        } catch {
            viewer = nil
            conversations = []
            selectedConversationID = nil
            messages = []
            status = "Could not open a valid WeChatArchive folder."
        }
    }

    private func loadMessages() {
        guard let viewer, let conversationID = selectedConversationID else { return }
        do {
            messages = try viewer.messages(conversationID: conversationID, limit: 100)
            expandedVideoID = nil
        } catch {
            messages = []
            status = "Could not read the selected archive timeline."
        }
    }

    private func loadMore() {
        guard let viewer, let conversationID = selectedConversationID else { return }
        do {
            let page = try viewer.messages(conversationID: conversationID, offset: messages.count, limit: 100)
            messages.append(contentsOf: page)
        } catch {
            status = "Could not load more archived messages."
        }
    }
}

private struct ArchiveTimelineMessageRow: View {
    let message: ArchiveViewerMessage
    let viewer: WeChatArchiveViewerDatabase?
    @Binding var expandedVideoID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(timestampLabel)
                Spacer()
                Text(message.hasSender ? "Message" : "System message")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            switch message.normalizedType {
            case .text:
                Text(message.textContent ?? "")
                    .textSelection(.enabled)
            case .image:
                imageContent
            case .video:
                videoContent
            case .voice:
                voiceContent
            case .unknown:
                Text("[Unsupported message type \(message.rawLocalType.map(String.init) ?? "unknown")]")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var imageContent: some View {
        if let media = preferredImage,
           let viewer,
           let url = viewer.mediaURL(for: media, preferDecoded: true),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 420, maxHeight: 360, alignment: .leading)
        } else {
            Label("Image unavailable — raw media archived", systemImage: "photo")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        if let thumbnail = preferredVideoThumbnail,
           let viewer,
           let url = viewer.mediaURL(for: thumbnail, preferDecoded: false),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 420, maxHeight: 220, alignment: .leading)
        }
        if let video = preferredVideo, let viewer, let url = viewer.mediaURL(for: video, preferDecoded: false) {
            Button(expandedVideoID == video.id ? "Hide Video" : "Play Video") {
                expandedVideoID = expandedVideoID == video.id ? nil : video.id
            }
            if expandedVideoID == video.id {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: 560, minHeight: 260, maxHeight: 360)
            }
        } else {
            Label("Video unavailable — archive retains any available media", systemImage: "video")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var voiceContent: some View {
        if let voice = message.media.first(where: { $0.mediaType == .voice }),
           let viewer,
           let url = viewer.mediaURL(for: voice, preferDecoded: true),
           url.pathExtension.lowercased() == "wav" {
            VideoPlayer(player: AVPlayer(url: url))
                .frame(maxWidth: 380, minHeight: 42, maxHeight: 56)
        } else if message.media.contains(where: { $0.mediaType == .voice && $0.status == .rawArchived }) {
            Label("Raw Silk voice archived — playback conversion is unavailable", systemImage: "waveform")
                .foregroundStyle(.secondary)
        } else {
            Label("Voice media unavailable", systemImage: "waveform.slash")
                .foregroundStyle(.secondary)
        }
    }

    private var timestampLabel: String {
        guard message.timestamp > 0 else { return "Unknown time" }
        return Date(timeIntervalSince1970: TimeInterval(message.timestamp)).formatted(date: .abbreviated, time: .shortened)
    }

    private var preferredImage: ArchiveViewerMedia? {
        firstMedia(type: .image, variants: [.main, .hd, .thumbnail], preferDecoded: true)
    }

    private var preferredVideo: ArchiveViewerMedia? {
        firstMedia(type: .video, variants: [.play, .raw], preferDecoded: false)
    }

    private var preferredVideoThumbnail: ArchiveViewerMedia? {
        firstMedia(type: .video, variants: [.thumbnail], preferDecoded: false)
    }

    private func firstMedia(type: ArchiveV1MediaType, variants: [ArchiveV1MediaVariant], preferDecoded: Bool) -> ArchiveViewerMedia? {
        for variant in variants {
            if let media = message.media.first(where: { $0.mediaType == type && $0.variant == variant && (preferDecoded ? $0.decodedRelativePath != nil || $0.rawRelativePath != nil : $0.rawRelativePath != nil || $0.decodedRelativePath != nil) }) {
                return media
            }
        }
        return nil
    }
}
#endif
