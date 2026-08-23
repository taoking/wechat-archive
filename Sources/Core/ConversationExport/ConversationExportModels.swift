import Foundation

/// Portable, human-readable exports derived solely from an existing private
/// archive. They deliberately omit source database identities by default.
public enum ConversationExportFormat: String, CaseIterable, Codable, Equatable, Sendable {
    case html
    case json
    case markdown

    public var filename: String {
        switch self {
        case .html: "chat.html"
        case .json: "chat.json"
        case .markdown: "chat.md"
        }
    }
}

public struct ConversationExportOptions: Equatable, Sendable {
    public let includeImages: Bool
    public let includeVoice: Bool
    public let includeVideo: Bool
    public let includeAvatars: Bool
    public let includeTechnicalMetadata: Bool
    public let pageSize: Int

    public init(
        includeImages: Bool = true,
        includeVoice: Bool = true,
        includeVideo: Bool = true,
        includeAvatars: Bool = true,
        includeTechnicalMetadata: Bool = false,
        pageSize: Int = 500
    ) {
        self.includeImages = includeImages
        self.includeVoice = includeVoice
        self.includeVideo = includeVideo
        self.includeAvatars = includeAvatars
        self.includeTechnicalMetadata = includeTechnicalMetadata
        self.pageSize = min(max(pageSize, 1), 500)
    }

    public static let `default` = Self()
}

public struct ConversationExportProgress: Equatable, Sendable {
    public let messagesExported: Int
    public let totalMessages: Int
    public let imagesCopied: Int
    public let voiceCopied: Int
    public let videoCopied: Int
    public let bytesCopied: Int64
}

public struct ConversationExportResult: Equatable, Sendable {
    public let outputRoot: URL
    public let primaryFileURL: URL
    public let messagesExported: Int
    public let imagesCopied: Int
    public let voiceCopied: Int
    public let videoCopied: Int
    public let avatarCopied: Int
    public let bytesCopied: Int64
}

public enum ConversationExportError: Error, Equatable, Sendable {
    case invalidDestination
    case conversationNotFound
    case cancelled
    case ioFailure
}

public struct PersistedFolderLocation: Codable, Equatable, Sendable {
    public let path: String
    /// Reserved for a future sandboxed build. The current development build
    /// uses paths, but this keeps callers from coupling to that detail.
    public let securityScopedBookmark: Data?

    public init(path: String, securityScopedBookmark: Data? = nil) {
        self.path = path
        self.securityScopedBookmark = securityScopedBookmark
    }

    public init(_ url: URL) {
        self.init(path: url.standardizedFileURL.path())
    }

    public var url: URL { URL(fileURLWithPath: path).standardizedFileURL }
}

/// Stores only folder locations and small user-interface choices. It never
/// stores message content, keys, passwords, or image decryption material.
public final class WorkspacePreferences: @unchecked Sendable {
    private enum Key {
        static let plainRoot = "workspace.plainSQLiteRoot"
        static let accountRoot = "workspace.accountRoot"
        static let archiveParent = "workspace.archiveParent"
        static let lastArchive = "workspace.lastArchive"
        static let recentArchives = "workspace.recentArchives"
        static let exportDirectory = "workspace.conversationExportDirectory"
        static let exportFormat = "workspace.conversationExportFormat"
        static let selectedConversation = "workspace.selectedConversation"
        static let reopenLastArchive = "workspace.reopenLastArchive"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.reopenLastArchive) == nil {
            defaults.set(true, forKey: Key.reopenLastArchive)
        }
    }

    public var lastPlainSQLiteRoot: URL? { get { location(for: Key.plainRoot)?.url } set { set(location: newValue, for: Key.plainRoot) } }
    public var lastAccountRoot: URL? { get { location(for: Key.accountRoot)?.url } set { set(location: newValue, for: Key.accountRoot) } }
    public var lastArchiveParentDirectory: URL? { get { location(for: Key.archiveParent)?.url } set { set(location: newValue, for: Key.archiveParent) } }
    public var lastOpenedArchiveRoot: URL? { get { location(for: Key.lastArchive)?.url } set { set(location: newValue, for: Key.lastArchive) } }
    public var lastConversationExportDirectory: URL? { get { location(for: Key.exportDirectory)?.url } set { set(location: newValue, for: Key.exportDirectory) } }
    public var lastSelectedConversationID: String? { get { defaults.string(forKey: Key.selectedConversation) } set { defaults.set(newValue, forKey: Key.selectedConversation) } }
    public var reopenLastArchiveOnLaunch: Bool { get { defaults.bool(forKey: Key.reopenLastArchive) } set { defaults.set(newValue, forKey: Key.reopenLastArchive) } }

    public var lastConversationExportFormat: ConversationExportFormat {
        get { defaults.string(forKey: Key.exportFormat).flatMap(ConversationExportFormat.init(rawValue:)) ?? .html }
        set { defaults.set(newValue.rawValue, forKey: Key.exportFormat) }
    }

    public var recentArchiveRoots: [URL] {
        locations(for: Key.recentArchives).map(\.url)
    }

    public func recordOpenedArchive(_ url: URL) {
        let location = PersistedFolderLocation(url)
        lastOpenedArchiveRoot = location.url
        var locations = locations(for: Key.recentArchives).filter { $0.path != location.path }
        locations.insert(location, at: 0)
        set(locations: Array(locations.prefix(5)), for: Key.recentArchives)
    }

    public func validLastOpenedArchive() throws -> URL? {
        guard reopenLastArchiveOnLaunch, let root = lastOpenedArchiveRoot else { return nil }
        do {
            _ = try WeChatArchiveViewerDatabase(archiveRoot: root)
            return root
        } catch {
            lastOpenedArchiveRoot = nil
            set(locations: locations(for: Key.recentArchives).filter { $0.path != root.path() }, for: Key.recentArchives)
            return nil
        }
    }

    private func location(for key: String) -> PersistedFolderLocation? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedFolderLocation.self, from: data)
    }

    private func locations(for key: String) -> [PersistedFolderLocation] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PersistedFolderLocation].self, from: data)) ?? []
    }

    private func set(location: URL?, for key: String) {
        guard let location else { defaults.removeObject(forKey: key); return }
        guard let data = try? JSONEncoder().encode(PersistedFolderLocation(location)) else { return }
        defaults.set(data, forKey: key)
    }

    private func set(locations: [PersistedFolderLocation], for key: String) {
        guard let data = try? JSONEncoder().encode(locations) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum ArchiveViewerMediaSelector {
    public static func preferredImage(in media: [ArchiveViewerMedia]) -> ArchiveViewerMedia? {
        let ranks: [ArchiveV1MediaVariant: Int] = [.main: 3, .hd: 2, .thumbnail: 1]
        return media.filter { $0.mediaType == .image && $0.decodedRelativePath != nil }.sorted { lhs, rhs in
            let lhsArea = (lhs.width ?? 0) * (lhs.height ?? 0)
            let rhsArea = (rhs.width ?? 0) * (rhs.height ?? 0)
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            if lhs.decodedSize != rhs.decodedSize { return (lhs.decodedSize ?? 0) > (rhs.decodedSize ?? 0) }
            return (ranks[lhs.variant] ?? 0) > (ranks[rhs.variant] ?? 0)
        }.first
    }

    public static func playableVideo(in media: [ArchiveViewerMedia]) -> ArchiveViewerMedia? {
        first(in: media, type: .video, variants: [.play, .raw], requiresDecoded: false)
    }

    public static func playableVoice(in media: [ArchiveViewerMedia]) -> ArchiveViewerMedia? {
        media.first { $0.mediaType == .voice && $0.decodedRelativePath?.lowercased().hasSuffix(".wav") == true }
    }

    private static func first(in media: [ArchiveViewerMedia], type: ArchiveV1MediaType, variants: [ArchiveV1MediaVariant], requiresDecoded: Bool) -> ArchiveViewerMedia? {
        for variant in variants {
            if let media = media.first(where: {
                $0.mediaType == type && $0.variant == variant &&
                    (requiresDecoded ? $0.decodedRelativePath != nil : $0.rawRelativePath != nil || $0.decodedRelativePath != nil)
            }) { return media }
        }
        return nil
    }
}
