import Foundation

public struct ArchiveStatistics: Equatable, Sendable {
    public let messageCount: Int
    public let contactCount: Int
    public let groupCount: Int
    public let imageCount: Int
    public let videoCount: Int
    public let voiceCount: Int
    public let fileCount: Int
    public let earliestMessageAt: Date?
    public let latestMessageAt: Date?
    public let archiveSize: Int64
}

public struct ArchiveStatisticsCalculator: Sendable {
    public init() {}

    public func calculate(messages: [Message], conversations: [Conversation], archiveRoot: URL) throws -> ArchiveStatistics {
        let timestamps = messages.map(\.timestamp)
        return ArchiveStatistics(
            messageCount: messages.count,
            contactCount: conversations.filter { !$0.isGroup }.count,
            groupCount: conversations.filter(\.isGroup).count,
            imageCount: messages.filter { $0.type == .image }.count,
            videoCount: messages.filter { $0.type == .video }.count,
            voiceCount: messages.filter { $0.type == .voice }.count,
            fileCount: messages.filter { $0.type == .file }.count,
            earliestMessageAt: timestamps.min(),
            latestMessageAt: timestamps.max(),
            archiveSize: try archiveSize(at: archiveRoot)
        )
    }

    private func archiveSize(at rootURL: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: rootURL.path()) else { return 0 }
        guard let iterator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            throw ArchiveError.ioFailure
        }
        var total: Int64 = 0
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true, let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
