import Foundation

/// Builds a portable, readable export from one conversation in an existing
/// archive. The archive is opened read-only and is never modified.
public final class WeChatArchiveConversationExporter: @unchecked Sendable {
    public init() {}

    @discardableResult
    public func export(
        archiveRoot: URL,
        conversationID: String,
        destinationRoot: URL,
        format: ConversationExportFormat,
        options: ConversationExportOptions = .default,
        shouldCancel: (() -> Bool)? = nil,
        progress: ((ConversationExportProgress) -> Void)? = nil
    ) throws -> ConversationExportResult {
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: archiveRoot)
        guard let conversation = try viewer.conversation(id: conversationID) else {
            throw ConversationExportError.conversationNotFound
        }

        let destination = try Self.validDestination(destinationRoot, archiveRoot: viewer.archiveRoot)
        let staging = destination.appending(path: ".ChatExport-\(UUID().uuidString).staging")
        try Self.createPrivateDirectory(staging)

        do {
            let output = try Self.uniqueOutputURL(
                in: destination,
                title: conversation.title,
                date: Date()
            )
            let context = try ExportContext(
                viewer: viewer,
                stagingRoot: staging,
                conversation: conversation,
                options: options,
                shouldCancel: shouldCancel,
                progress: progress
            )
            let primary = staging.appending(path: format.filename)
            switch format {
            case .html:
                try HTMLConversationExportWriter(context: context, fileURL: primary).write()
            case .json:
                try JSONConversationExportWriter(context: context, fileURL: primary).write()
            case .markdown:
                try MarkdownConversationExportWriter(context: context, fileURL: primary).write()
            }
            try context.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: output)
            try Self.setPrivatePermissions(at: output)
            return context.result(outputRoot: output, primaryFileURL: output.appending(path: format.filename))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if error is CancellationError || (error as? ConversationExportError) == .cancelled {
                throw ConversationExportError.cancelled
            }
            throw error
        }
    }

    private static func validDestination(_ destinationRoot: URL, archiveRoot: URL) throws -> URL {
        let original = destinationRoot.standardizedFileURL
        let originalValues = try original.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let destination = destinationRoot.resolvingSymlinksInPath().standardizedFileURL
        let archive = archiveRoot.resolvingSymlinksInPath().standardizedFileURL
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard originalValues.isDirectory == true, originalValues.isSymbolicLink != true,
              values.isDirectory == true, values.isSymbolicLink != true,
              !isDescendant(destination, of: archive) else {
            throw ConversationExportError.invalidDestination
        }
        return destination
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let prefix = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        return candidate.path() == root.path() || candidate.path().hasPrefix(prefix)
    }

    private static func uniqueOutputURL(in destination: URL, title: String, date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeTitle = safeFilename(title)
        let base = "ChatExport-\(safeTitle)-\(formatter.string(from: date))"
        var candidate = destination.appending(path: base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path()) {
            candidate = destination.appending(path: "\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    private static func safeFilename(_ text: String) -> String {
        let transformed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `URL.appending(path:)` treats percent-encoded non-ASCII components
        // differently across Foundation implementations. Keep the directory
        // component ASCII-only; the human-readable title remains in the
        // exported document itself.
        let value = transformed.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95: return String(scalar)
            default: return "-"
            }
        }.joined()
            .replacingOccurrences(of: "--", with: "-")
        let compact = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return compact.isEmpty ? "Conversation" : String(compact.prefix(64))
    }

    fileprivate static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path())
    }

    fileprivate static func createPrivateFile(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path(), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConversationExportError.ioFailure
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path())
        return try FileHandle(forWritingTo: url)
    }

    fileprivate static func setPrivatePermissions(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path())
        let children = try FileManager.default.subpathsOfDirectory(atPath: url.path())
        for child in children {
            let childURL = url.appending(path: child)
            let values = try childURL.resourceValues(forKeys: [.isDirectoryKey])
            try FileManager.default.setAttributes([.posixPermissions: values.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: childURL.path())
        }
    }
}

private final class ExportContext {
    let viewer: WeChatArchiveViewerDatabase
    let stagingRoot: URL
    let conversation: ArchiveViewerConversation
    let options: ConversationExportOptions
    let shouldCancel: (() -> Bool)?
    let progressHandler: ((ConversationExportProgress) -> Void)?
    let totalMessages: Int
    private var assetPaths = [String: String]()
    private var avatarPaths = [String: String]()
    private(set) var messagesExported = 0
    private(set) var imagesCopied = 0
    private(set) var voiceCopied = 0
    private(set) var videoCopied = 0
    private(set) var avatarsCopied = 0
    private(set) var bytesCopied: Int64 = 0

    init(
        viewer: WeChatArchiveViewerDatabase,
        stagingRoot: URL,
        conversation: ArchiveViewerConversation,
        options: ConversationExportOptions,
        shouldCancel: (() -> Bool)?,
        progress: ((ConversationExportProgress) -> Void)?
    ) throws {
        self.viewer = viewer
        self.stagingRoot = stagingRoot
        self.conversation = conversation
        self.options = options
        self.shouldCancel = shouldCancel
        self.progressHandler = progress
        self.totalMessages = conversation.messageCount
        if options.includeImages { try WeChatArchiveConversationExporter.createPrivateDirectory(stagingRoot.appending(path: "media/images")) }
        if options.includeVideo { try WeChatArchiveConversationExporter.createPrivateDirectory(stagingRoot.appending(path: "media/video")) }
        if options.includeVoice { try WeChatArchiveConversationExporter.createPrivateDirectory(stagingRoot.appending(path: "media/voice")) }
        if options.includeAvatars { try WeChatArchiveConversationExporter.createPrivateDirectory(stagingRoot.appending(path: "avatars")) }
    }

    func checkCancellation() throws {
        if shouldCancel?() == true { throw ConversationExportError.cancelled }
    }

    func page(offset: Int) throws -> ArchiveViewerPage<ArchiveViewerMessage> {
        try checkCancellation()
        return try viewer.messagePage(conversationID: conversation.id, offset: offset, limit: options.pageSize)
    }

    func prepared(_ message: ArchiveViewerMessage) throws -> ExportedMessage {
        try checkCancellation()
        let media = try exportMedia(for: message)
        let avatar = try exportAvatar(message.avatar)
        messagesExported += 1
        progressHandler?(.init(messagesExported: messagesExported, totalMessages: totalMessages, imagesCopied: imagesCopied, voiceCopied: voiceCopied, videoCopied: videoCopied, bytesCopied: bytesCopied))
        return .init(message: message, media: media, avatarPath: avatar)
    }

    func conversationAvatarPath() throws -> String? { try exportAvatar(conversation.avatar) }

    func result(outputRoot: URL, primaryFileURL: URL) -> ConversationExportResult {
        .init(outputRoot: outputRoot, primaryFileURL: primaryFileURL, messagesExported: messagesExported, imagesCopied: imagesCopied, voiceCopied: voiceCopied, videoCopied: videoCopied, avatarCopied: avatarsCopied, bytesCopied: bytesCopied)
    }

    private func exportMedia(for message: ArchiveViewerMessage) throws -> [ExportedMedia] {
        var result = [ExportedMedia]()
        if message.normalizedType == .image {
            if options.includeImages, let media = ArchiveViewerMediaSelector.preferredImage(in: message.media), let path = try copy(media: media, kind: "images", preferDecoded: true) {
                result.append(.init(type: .image, path: path, available: true, width: media.width, height: media.height, duration: nil))
            } else { result.append(.init(type: .image, path: nil, available: false, width: nil, height: nil, duration: nil)) }
        }
        if message.normalizedType == .video {
            if options.includeVideo, let media = ArchiveViewerMediaSelector.playableVideo(in: message.media), let path = try copy(media: media, kind: "video", preferDecoded: false) {
                result.append(.init(type: .video, path: path, available: true, width: media.width, height: media.height, duration: media.duration))
            } else { result.append(.init(type: .video, path: nil, available: false, width: nil, height: nil, duration: nil)) }
        }
        if message.normalizedType == .voice {
            if options.includeVoice, let media = ArchiveViewerMediaSelector.playableVoice(in: message.media), let path = try copy(media: media, kind: "voice", preferDecoded: true) {
                result.append(.init(type: .voice, path: path, available: true, width: nil, height: nil, duration: media.duration))
            } else { result.append(.init(type: .voice, path: nil, available: false, width: nil, height: nil, duration: nil)) }
        }
        return result
    }

    private func copy(media: ArchiveViewerMedia, kind: String, preferDecoded: Bool) throws -> String? {
        let key = "\(kind):\(media.id)"
        if let path = assetPaths[key] { return path }
        guard let source = viewer.mediaURL(for: media, preferDecoded: preferDecoded), try isSafeRegularFile(source) else { return nil }
        let ext = safeExtension(source.pathExtension, fallback: kind == "voice" ? "wav" : kind == "video" ? "mp4" : "img")
        let token = ArchiveCryptography.sha256(Data(key.utf8)).prefix(24)
        let relative = "media/\(kind)/\(token).\(ext)"
        let target = stagingRoot.appending(path: relative)
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path())
        bytesCopied += Int64((try target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        assetPaths[key] = relative
        switch kind {
        case "images": imagesCopied += 1
        case "video": videoCopied += 1
        case "voice": voiceCopied += 1
        default: break
        }
        return relative
    }

    private func exportAvatar(_ avatar: ArchiveViewerAvatar?) throws -> String? {
        guard options.includeAvatars, let avatar else { return nil }
        if let path = avatarPaths[avatar.id] { return path }
        guard let source = viewer.avatarURL(for: avatar), try isSafeRegularFile(source) else { return nil }
        let ext = safeExtension(source.pathExtension, fallback: "img")
        let token = ArchiveCryptography.sha256(Data(("avatar:" + avatar.id).utf8)).prefix(24)
        let relative = "avatars/\(token).\(ext)"
        let target = stagingRoot.appending(path: relative)
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path())
        bytesCopied += Int64((try target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        avatarPaths[avatar.id] = relative
        avatarsCopied += 1
        return relative
    }

    private func safeExtension(_ value: String, fallback: String) -> String {
        let normalized = value.lowercased()
        let allowed: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "wav"]
        return allowed.contains(normalized) ? normalized : fallback
    }

    private func isSafeRegularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

private struct ExportedMessage {
    let message: ArchiveViewerMessage
    let media: [ExportedMedia]
    let avatarPath: String?
}

private struct ExportedMedia: Encodable {
    let type: ArchiveV1MediaType
    let path: String?
    let available: Bool
    let width: Int?
    let height: Int?
    let duration: Double?
}

private protocol ConversationExportWriter {
    var context: ExportContext { get }
    var fileURL: URL { get }
    func write() throws
}

private struct HTMLConversationExportWriter: ConversationExportWriter {
    let context: ExportContext
    let fileURL: URL

    func write() throws {
        let handle = try WeChatArchiveConversationExporter.createPrivateFile(fileURL)
        defer { try? handle.close() }
        let avatar = try context.conversationAvatarPath()
        try handle.writeUTF8(htmlPrefix(conversation: context.conversation, avatarPath: avatar))
        var offset = 0
        var lastDay: Date?
        while true {
            let page = try context.page(offset: offset)
            for message in page.items {
                let prepared = try context.prepared(message)
                let current = date(message.timestamp)
                if needsDaySeparator(previous: lastDay, current: current) {
                    try handle.writeUTF8("<div class=\"day\">\(htmlEscape(dayLabel(current)))</div>\n")
                }
                lastDay = current
                try handle.writeUTF8(htmlMessage(prepared, conversationType: context.conversation.type))
            }
            offset += page.items.count
            if !page.hasMore { break }
        }
        try handle.writeUTF8("</main></body></html>\n")
    }

    private func htmlPrefix(conversation: ArchiveViewerConversation, avatarPath: String?) -> String {
        let avatar = avatarPath.map { "<img class=\"header-avatar\" src=\"\(htmlAttribute($0))\" alt=\"\">" } ?? "<span class=\"header-avatar placeholder\"></span>"
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(htmlEscape(conversation.title))</title>
        <style>
        :root{color-scheme:light dark} body{margin:0;background:#f3f5f7;color:#1d1d1f;font:15px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.header{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:12px;padding:16px max(20px,calc((100% - 900px)/2));background:rgba(255,255,255,.92);backdrop-filter:blur(12px);border-bottom:1px solid #ddd}.header-avatar,.avatar{width:42px;height:42px;border-radius:50%;object-fit:cover;background:#c8cdd4}.placeholder{display:inline-block}.meta{color:#6d7178;font-size:12px}main{max-width:900px;margin:auto;padding:24px 16px 48px}.day{margin:22px auto 12px;width:max-content;color:#777;background:#e4e7ea;border-radius:12px;padding:4px 10px;font-size:12px}.row{display:flex;align-items:flex-end;gap:8px;margin:9px 0}.row.outgoing{justify-content:flex-end}.row.system{justify-content:center}.bubble{max-width:66%;padding:10px 12px;border-radius:14px;background:#fff;box-shadow:0 1px 1px #0000000d;white-space:pre-wrap;overflow-wrap:anywhere}.outgoing .bubble{background:#ccefb8}.system .bubble,.unknown{color:#70757c;background:#e7e9eb;font-size:13px}.sender{margin:0 0 4px;font-size:12px;color:#747980}.message-avatar{width:34px;height:34px;border-radius:50%;object-fit:cover;background:#c8cdd4}.media-image{display:block;max-width:min(480px,100%);max-height:420px;border-radius:8px}.media-video{display:block;max-width:min(560px,100%);max-height:420px;border-radius:8px}.media-audio{max-width:320px;width:100%}.missing{color:#777;font-size:13px}@media (prefers-color-scheme:dark){body{background:#1e2023;color:#eee}.header{background:rgba(35,37,40,.92);border-color:#43464b}.bubble{background:#303338}.outgoing .bubble{background:#365d2b}.day,.system .bubble{background:#3b3e42}.meta,.sender{color:#aab0b8}}</style></head><body>
        <header class="header">\(avatar)<div><strong>\(htmlEscape(conversation.title))</strong><div class="meta">\(conversation.messageCount) 条消息 · 导出于 \(htmlEscape(exportTimestamp(Date())))</div></div></header><main>
        """
    }

    private func htmlMessage(_ prepared: ExportedMessage, conversationType: ArchiveV1ConversationType) -> String {
        let message = prepared.message
        let direction = message.direction.rawValue
        if message.direction == .system {
            return "<div class=\"row system\"><div class=\"bubble\">\(htmlContent(prepared))</div></div>\n"
        }
        let avatar: String
        if let path = prepared.avatarPath {
            avatar = "<img class=\"message-avatar\" src=\"\(htmlAttribute(path))\" alt=\"\">"
        } else {
            avatar = "<span class=\"message-avatar placeholder\"></span>"
        }
        let sender = conversationType == .group && message.direction != .outgoing && !(message.senderDisplayName ?? "").isEmpty
            ? "<div class=\"sender\">\(htmlEscape(message.senderDisplayName ?? ""))</div>" : ""
        let content = "<div>\(sender)<div class=\"bubble\">\(htmlContent(prepared))</div></div>"
        return message.direction == .outgoing
            ? "<div class=\"row \(direction)\">\(content)\(avatar)</div>\n"
            : "<div class=\"row \(direction)\">\(avatar)\(content)</div>\n"
    }

    private func htmlContent(_ prepared: ExportedMessage) -> String {
        switch prepared.message.normalizedType {
        case .text: return htmlEscape(prepared.message.textContent ?? "")
        case .unknown: return "<span class=\"unknown\">[暂不支持的消息]</span>"
        case .image:
            guard let media = prepared.media.first, media.available, let path = media.path else { return "<span class=\"missing\">[图片文件不可用]</span>" }
            return "<a href=\"\(htmlAttribute(path))\" target=\"_blank\" rel=\"noopener\"><img class=\"media-image\" src=\"\(htmlAttribute(path))\" alt=\"图片\" loading=\"lazy\"></a>"
        case .video:
            guard let media = prepared.media.first, media.available, let path = media.path else { return "<span class=\"missing\">[视频文件不可用]</span>" }
            return "<video class=\"media-video\" controls preload=\"metadata\" src=\"\(htmlAttribute(path))\"></video>"
        case .voice:
            guard let media = prepared.media.first, media.available, let path = media.path else { return "<span class=\"missing\">[语音原始数据已归档，但当前导出不可播放]</span>" }
            let duration = media.duration.map { "<div class=\"meta\">语音 \(durationLabel($0))</div>" } ?? ""
            return "\(duration)<audio class=\"media-audio\" controls preload=\"metadata\" src=\"\(htmlAttribute(path))\"></audio>"
        }
    }
}

private struct JSONConversationExportWriter: ConversationExportWriter {
    let context: ExportContext
    let fileURL: URL

    func write() throws {
        let handle = try WeChatArchiveConversationExporter.createPrivateFile(fileURL)
        defer { try? handle.close() }
        let conversationAvatar = try context.conversationAvatarPath()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let header = JSONConversation(title: context.conversation.title, type: context.conversation.type.rawValue, messageCount: context.conversation.messageCount, avatar: conversationAvatar)
        try handle.writeUTF8("{\"format\":\"WeChatConversationExport\",\"version\":1,\"exportedAt\":")
        try handle.write(encoder.encode(exportTimestamp(Date())))
        try handle.writeUTF8(",\"conversation\":")
        try handle.write(encoder.encode(header))
        try handle.writeUTF8(",\"messages\":[")
        var offset = 0
        var first = true
        while true {
            let page = try context.page(offset: offset)
            for message in page.items {
                let prepared = try context.prepared(message)
                if !first { try handle.writeUTF8(",") }
                first = false
                let record = JSONConversationMessage(prepared: prepared, technical: context.options.includeTechnicalMetadata)
                try handle.write(encoder.encode(record))
            }
            offset += page.items.count
            if !page.hasMore { break }
        }
        try handle.writeUTF8("]}")
    }
}

private struct MarkdownConversationExportWriter: ConversationExportWriter {
    let context: ExportContext
    let fileURL: URL

    func write() throws {
        let handle = try WeChatArchiveConversationExporter.createPrivateFile(fileURL)
        defer { try? handle.close() }
        try handle.writeUTF8("# \(markdownEscape(context.conversation.title))\n\n导出时间：\(exportTimestamp(Date()))  \n消息数量：\(context.conversation.messageCount)\n\n---\n")
        var offset = 0
        var lastDay: Date?
        while true {
            let page = try context.page(offset: offset)
            for message in page.items {
                let prepared = try context.prepared(message)
                let current = date(message.timestamp)
                if needsDaySeparator(previous: lastDay, current: current) {
                    try handle.writeUTF8("\n### \(dayLabel(current))\n")
                }
                lastDay = current
                try handle.writeUTF8(markdownMessage(prepared, conversationType: context.conversation.type))
            }
            offset += page.items.count
            if !page.hasMore { break }
        }
    }

    private func markdownMessage(_ prepared: ExportedMessage, conversationType: ArchiveV1ConversationType) -> String {
        let message = prepared.message
        let sender: String
        switch message.direction {
        case .outgoing: sender = "我"
        case .system: sender = "系统"
        case .incoming, .unknown: sender = conversationType == .group ? (message.senderDisplayName ?? "成员") : "对方"
        }
        let header = "\n**\(markdownEscape(sender)) · \(timeLabel(message.timestamp))**\n\n"
        switch message.normalizedType {
        case .text: return header + markdownEscape(message.textContent ?? "") + "\n"
        case .unknown: return header + "> 暂不支持的消息\n"
        case .image: return header + mediaLine(prepared.media.first, image: true, label: "图片")
        case .video: return header + mediaLine(prepared.media.first, image: false, label: "视频")
        case .voice:
            let label = prepared.media.first?.duration.map { "语音 \(durationLabel($0))" } ?? "语音"
            return header + mediaLine(prepared.media.first, image: false, label: label)
        }
    }

    private func mediaLine(_ media: ExportedMedia?, image: Bool, label: String) -> String {
        guard let media, media.available, let path = media.path else { return "[\(label)文件不可用]\n" }
        return image ? "![\(label)](\(path))\n" : "[\(label)](\(path))\n"
    }
}

private struct JSONConversation: Encodable {
    let title: String
    let type: String
    let messageCount: Int
    let avatar: String?
}

private struct JSONConversationMessage: Encodable {
    let timestamp: Int64
    let timestampISO8601: String
    let direction: String
    let sender: String?
    let type: String
    let text: String?
    let media: [ExportedMedia]
    let rawLocalType: Int64?

    init(prepared: ExportedMessage, technical: Bool) {
        timestamp = prepared.message.timestamp
        timestampISO8601 = exportTimestamp(date(prepared.message.timestamp))
        direction = prepared.message.direction.rawValue
        sender = prepared.message.direction == .outgoing ? "我" : prepared.message.senderDisplayName
        type = prepared.message.normalizedType.rawValue
        text = prepared.message.normalizedType == .text ? prepared.message.textContent : nil
        media = prepared.media
        rawLocalType = technical ? prepared.message.rawLocalType : nil
    }
}

private extension FileHandle {
    func writeUTF8(_ text: String) throws {
        try write(contentsOf: Data(text.utf8))
    }
}

private func htmlEscape(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func htmlAttribute(_ text: String) -> String { htmlEscape(text) }

private func markdownEscape(_ text: String) -> String {
    var escaped = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\", "#", "*", "_", ">", "`", "[", "]": escaped.append("\\")
        default: break
        }
        escaped.unicodeScalars.append(scalar)
    }
    return escaped
}

private func date(_ timestamp: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(max(timestamp, 0)))
}

private func exportTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func dayLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月d日"
    return formatter.string(from: date)
}

private func timeLabel(_ timestamp: Int64) -> String {
    guard timestamp > 0 else { return "未知时间" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date(timestamp))
}

private func durationLabel(_ duration: Double) -> String {
    let seconds = max(0, Int(duration.rounded()))
    return seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds) 秒"
}

private func needsDaySeparator(previous: Date?, current: Date) -> Bool {
    guard let previous else { return true }
    return !Calendar(identifier: .gregorian).isDate(previous, inSameDayAs: current)
}
