import Foundation
@testable import WeChatArchiveCore

final class ArchiveCoreTests {

    func testArchiveWriterPartitionsMessagesByConversationAndYearAndPreservesUnknownPayload() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeMessage(
            id: "m-2024",
            timestamp: date("2024-12-31T23:30:00+08:00"),
            type: .text,
            content: "跨年消息"
        )
        let unknown = makeMessage(
            id: "m-2025",
            timestamp: date("2025-01-01T00:30:00+08:00"),
            type: .unknown,
            content: nil,
            raw: ["legacy_type": "0xDEAD", "payload": "kept"]
        )
        let archive = ArchiveWriter(rootURL: directory)

        try archive.write(messages: [first, unknown], account: Account(id: "me", displayName: "我"))

        let messages2024 = try NDJSONReader().read(from: directory.appending(path: "messages/chat-1/2024.ndjson"))
        let messages2025 = try NDJSONReader().read(from: directory.appending(path: "messages/chat-1/2025.ndjson"))
        let manifest = try ArchiveReader().manifest(from: directory)

        try expectEqual(messages2024.map(\.id), ["m-2024"])
        try expectEqual(messages2025.first?.raw?["legacy_type"], "0xDEAD")
        try expectEqual(manifest.messageCount, 2)
        try expectEqual(manifest.format, ArchiveManifest.formatName)
    }

    func testMediaStoreDeduplicatesContentUsingSHA256InsteadOfFilename() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaStore(rootURL: directory)

        let first = try store.store(data: Data("same bytes".utf8), suggestedFilename: "summer-photo.jpg", category: .images)
        let second = try store.store(data: Data("same bytes".utf8), suggestedFilename: "renamed.png", category: .images)

        try expectEqual(first.sha256, second.sha256)
        try expectEqual(first.relativePath, second.relativePath)
        try expectEqual(first.size, 10)
        try expectTrue(FileManager.default.fileExists(atPath: directory.appending(path: first.relativePath).path()))
    }

    func testImportCoordinatorSkipsStableAndFallbackDuplicatesAndRecordsSessionCounts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try SQLiteArchiveIndex(url: directory.appending(path: "archive.sqlite"))
        let coordinator = ImportCoordinator(index: index)
        let original = makeMessage(id: "source-1", timestamp: date("2025-02-03T04:05:06+08:00"), type: .text, content: "hello")
        let noSourceID = makeMessage(id: "generated-a", timestamp: original.timestamp, type: .text, content: "hello", sourceMessageID: nil)
        let sameFallback = makeMessage(id: "generated-b", timestamp: original.timestamp, type: .text, content: "hello", sourceMessageID: nil)

        let first = try coordinator.importMessages([original, noSourceID], source: .jsonFile, sourceHash: "hash-1")
        let second = try coordinator.importMessages([original, sameFallback], source: .jsonFile, sourceHash: "hash-2")

        try expectEqual(first.messagesInserted, 2)
        try expectEqual(second.messagesInserted, 0)
        try expectEqual(second.messagesSkipped, 2)
        try expectEqual(try index.messageCount(), 2)
        try expectEqual(try index.importSessions().count, 2)
    }

    func testSQLiteIndexFindsMessagesWithFTSAndAppliesFilters() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try SQLiteArchiveIndex(url: directory.appending(path: "archive.sqlite"))
        let waterfall = makeMessage(id: "search-1", timestamp: date("2025-04-01T10:00:00+08:00"), type: .text, content: "黄果树瀑布真美")
        let unrelated = makeMessage(id: "search-2", timestamp: date("2025-04-02T10:00:00+08:00"), type: .image, content: "照片")

        _ = try index.upsert(messages: [waterfall, unrelated])
        let result = try index.search(.init(query: "黄果树", conversationID: "chat-1", types: [.text], limit: 20))

        try expectEqual(result.map(\.id), ["search-1"])
    }

    func testExportersEscapeContentAndRemainOffline() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = makeMessage(id: "html-1", timestamp: date("2025-05-06T10:00:00+08:00"), type: .text, content: "<script>alert(1)</script>,\"ok\"")

        let htmlURL = try HTMLExporter().export(messages: [message], conversationName: "测试", to: directory)
        let csvURL = try CSVExporter().export(messages: [message], conversationName: "测试", to: directory)
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let csv = try String(contentsOf: csvURL, encoding: .utf8)

        try expectFalse(html.contains("<script>alert"))
        try expectTrue(html.contains("&lt;script&gt;"))
        try expectFalse(html.contains("https://"))
        try expectTrue(csv.contains("\"\"ok\"\""))
    }

    func testVerifierReportsChecksumMismatchWithoutExposingMessageContent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ArchiveWriter(rootURL: directory)
        try archive.write(messages: [makeMessage(id: "verify-1", timestamp: date("2025-06-01T10:00:00+08:00"), type: .text, content: "private text")], account: Account(id: "me", displayName: "我"))
        let ndjson = directory.appending(path: "messages/chat-1/2025.ndjson")
        try Data("tampered".utf8).write(to: ndjson)

        let report = try ArchiveVerifier().verify(at: directory)

        try expectFalse(report.isHealthy)
        try expectEqual(report.corruptedFiles, 1)
        try expectFalse(report.issues.joined(separator: " ").contains("private text"))
    }

    func testStatisticsCountsMessageTypesAndPreservesDateRange() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeMessage(id: "stats-1", timestamp: date("2021-01-01T10:00:00+08:00"), type: .text, content: "first")
        let image = makeMessage(id: "stats-2", timestamp: date("2022-01-01T10:00:00+08:00"), type: .image, content: nil)
        let video = makeMessage(id: "stats-3", timestamp: date("2023-01-01T10:00:00+08:00"), type: .video, content: nil)
        let file = makeMessage(id: "stats-4", timestamp: date("2024-01-01T10:00:00+08:00"), type: .file, content: nil)
        let conversations = [
            Conversation(id: "chat-1", displayName: "群聊", isGroup: true),
            Conversation(id: "chat-2", displayName: "联系人", isGroup: false)
        ]

        let stats = try ArchiveStatisticsCalculator().calculate(
            messages: [video, file, first, image],
            conversations: conversations,
            archiveRoot: directory
        )

        try expectEqual(stats.messageCount, 4)
        try expectEqual(stats.contactCount, 1)
        try expectEqual(stats.groupCount, 1)
        try expectEqual(stats.imageCount, 1)
        try expectEqual(stats.videoCount, 1)
        try expectEqual(stats.fileCount, 1)
        try expectEqual(stats.earliestMessageAt, first.timestamp)
        try expectEqual(stats.latestMessageAt, file.timestamp)
    }

    func testImportProviderContractsCoverEverySupportedSourceKind() throws {
        let providers: [any ChatImportProvider] = [
            JSONImportProvider(), NDJSONImportProvider(), CSVImportProvider(),
            TXTImportProvider(), HTMLImportProvider(), WeChatDatabaseImportProvider()
        ]

        try expectEqual(Set(providers.map(\.source)), Set(ImportSource.allCases))
    }

    private func makeMessage(
        id: String,
        timestamp: Date,
        type: MessageType,
        content: String?,
        raw: [String: String]? = nil,
        sourceMessageID: String? = "source-id",
        conversationID: String = "chat-1"
    ) -> Message {
        Message(
            id: id,
            sourceMessageID: sourceMessageID,
            conversationID: conversationID,
            timestamp: timestamp,
            sourceTimeZone: "Asia/Shanghai",
            sender: MessageSender(id: "wxid_friend", displayName: "朋友"),
            type: type,
            content: content,
            replyTo: nil,
            media: [],
            raw: raw
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)!
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WeChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) throws {
    guard actual == expected else { throw TestFailure(description: "Expected \(expected), got \(actual) at \(file):\(line)") }
}

private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard value else { throw TestFailure(description: "Expected true at \(file):\(line)") }
}

private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard !value else { throw TestFailure(description: "Expected false at \(file):\(line)") }
}
