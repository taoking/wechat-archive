import Foundation
import SQLite3
import XCTest
@testable import WeChatArchiveCore

final class ConversationExportTests: XCTestCase {
    func testCancellableFileCopierReportsChunkProgressAndRemovesPartialFile() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "CancellableCopy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let sourceRoot = parent.appending(path: "Archive")
        let stagingRoot = parent.appending(path: "Export.staging")
        let source = sourceRoot.appending(path: "media/video/large.mp4")
        let destination = stagingRoot.appending(path: "media/video/large.mp4")
        try writePrivate(Data(repeating: 0x5A, count: 24 * 1_024 * 1_024), to: source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var progress = [Int64]()
        XCTAssertThrowsError(try CancellableFileCopier().copy(
            from: source,
            to: destination,
            sourceRoot: sourceRoot,
            destinationRoot: stagingRoot,
            shouldCancel: { (progress.last ?? 0) >= 16 * 1_024 * 1_024 },
            progress: { progress.append($0) }
        )) { error in
            XCTAssertEqual(error as? ConversationExportError, .cancelled)
        }

        XCTAssertGreaterThanOrEqual(progress.count, 2)
        XCTAssertGreaterThan(progress.last ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path()))
    }

    func testConversationExporterCancelsDuringLargeVideoAndCleansStaging() throws {
        let fixture = try makeFixture(largeVideoBytes: 24 * 1_024 * 1_024)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var copiedBytes: Int64 = 0

        XCTAssertThrowsError(try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: destination,
            format: .html,
            shouldCancel: { copiedBytes >= 16 * 1_024 * 1_024 },
            progress: { copiedBytes = $0.bytesCopied }
        )) { error in
            XCTAssertEqual(error as? ConversationExportError, .cancelled)
        }

        XCTAssertGreaterThanOrEqual(copiedBytes, 16 * 1_024 * 1_024)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: destination.path())
        XCTAssertFalse(siblings.contains { $0.contains(".ChatExport-") })
        XCTAssertFalse(siblings.contains { $0.hasPrefix("ChatExport-") })
    }

    func testConversationExporterUsesUnicodeSafeOutputFolderWithoutPathEscape() throws {
        let fixture = try makeFixture(conversationTitle: "测试 / : 群 😀")
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: destination,
            format: .markdown
        )

        let outputName = (result.outputRoot.path(percentEncoded: false) as NSString).lastPathComponent
        XCTAssertTrue(outputName.contains("测试"))
        XCTAssertTrue(outputName.contains("😀"))
        XCTAssertFalse(outputName.contains("/"))
        XCTAssertFalse(outputName.contains(":"))
        XCTAssertEqual(
            result.outputRoot.deletingLastPathComponent().path(percentEncoded: false),
            destination.standardizedFileURL.path(percentEncoded: false)
        )
    }

    func testConversationExporterKeepsEveryFormatAndAssetUnderAbsoluteOutputDirectory() throws {
        let fixture = try makeFixture(conversationTitle: "绝对路径测试 😀")
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for format in [ConversationExportFormat.html, .json, .markdown] {
            let result = try WeChatArchiveConversationExporter().export(
                archiveRoot: fixture.root,
                conversationID: fixture.conversationID,
                destinationRoot: destination,
                format: format
            )
            let expectedPrimary = result.outputRoot.appendingPathComponent(format.filename)

            XCTAssertEqual(result.outputRoot.deletingLastPathComponent().standardizedFileURL, destination.standardizedFileURL)
            XCTAssertEqual(result.primaryFileURL.standardizedFileURL, expectedPrimary.standardizedFileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPrimary.path(percentEncoded: false)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputRoot.appendingPathComponent("avatars", isDirectory: true).path(percentEncoded: false)))
        }
    }

    func testTimelinePagingStateRetainsAnchorWhenPrependingOlderMessages() {
        var state = TimelinePagingState()
        XCTAssertEqual(state.replaceWithRecent(["m-3", "m-4"], hasMore: true), .scrollToBottom)
        XCTAssertEqual(state.prependOlder(["m-1", "m-2"], hasMore: false), .preserveAnchor("m-3"))
        XCTAssertEqual(state.messageIDs, ["m-1", "m-2", "m-3", "m-4"])
        XCTAssertFalse(state.hasMore)
    }

    func testSearchDebouncerOnlyAcceptsMostRecentQueryTicket() {
        var debouncer = SearchDebouncer()
        let a = debouncer.schedule()
        let ab = debouncer.schedule()
        let abc = debouncer.schedule()

        XCTAssertFalse(debouncer.shouldRun(ticket: a))
        XCTAssertFalse(debouncer.shouldRun(ticket: ab))
        XCTAssertTrue(debouncer.shouldRun(ticket: abc))
        debouncer.cancelAll()
        XCTAssertFalse(debouncer.shouldRun(ticket: abc))
    }

    func testConversationTimestampFormatterUsesChatStyleDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 14, minute: 32)))
        let today = try XCTUnwrap(calendar.date(byAdding: .minute, value: -3, to: now))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let saturday = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: now))
        let earlierThisYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 2)))
        let priorYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31)))

        XCTAssertEqual(ConversationTimestampFormatter.string(for: today, now: now, calendar: calendar), "14:29")
        XCTAssertEqual(ConversationTimestampFormatter.string(for: yesterday, now: now, calendar: calendar), "昨天")
        XCTAssertEqual(ConversationTimestampFormatter.string(for: saturday, now: now, calendar: calendar), "周五")
        XCTAssertEqual(ConversationTimestampFormatter.string(for: earlierThisYear, now: now, calendar: calendar), "5月2日")
        XCTAssertEqual(ConversationTimestampFormatter.string(for: priorYear, now: now, calendar: calendar), "2025/12/31")
    }

    func testMessageCopyFormatterIncludesOnlyRequestedContext() {
        let message = ArchiveViewerMessage(
            id: "fixture-message",
            timestamp: 1_700_000_000,
            normalizedType: .text,
            rawLocalType: 1,
            textContent: "第一行\n第二行",
            hasSender: true,
            direction: .incoming,
            senderDisplayName: "Fixture sender",
            avatar: nil,
            media: []
        )

        XCTAssertEqual(ArchiveViewerMessageCopyFormatter.text(message), "第一行\n第二行")
        XCTAssertEqual(
            ArchiveViewerMessageCopyFormatter.textWithTimestamp(message, timeZone: TimeZone(secondsFromGMT: 0)!),
            "2023-11-14 22:13\n第一行\n第二行"
        )
        XCTAssertEqual(
            ArchiveViewerMessageCopyFormatter.textWithSenderAndTimestamp(message, timeZone: TimeZone(secondsFromGMT: 0)!),
            "Fixture sender · 2023-11-14 22:13\n第一行\n第二行"
        )
    }

    func testConversationExporterWritesEscapedPortableHTMLWithMediaAndAvatars() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: destination,
            format: .html,
            options: .init(pageSize: 2)
        )
        let html = try String(contentsOf: result.primaryFileURL, encoding: .utf8)

        XCTAssertEqual(result.messagesExported, 5)
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("media/images/"))
        XCTAssertTrue(html.contains("media/video/"))
        XCTAssertTrue(html.contains("media/voice/"))
        XCTAssertTrue(html.contains("avatars/"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("sensitive-source.db"))
        XCTAssertFalse(html.contains("source_sqlite_rowid"))
        XCTAssertEqual(try permissionBits(at: result.outputRoot), 0o700)
        XCTAssertEqual(try permissionBits(at: result.primaryFileURL), 0o600)
    }

    func testConversationExporterWritesPrivateJSONWithoutTechnicalMetadataAndMarkdownEscapesText() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let exporter = WeChatArchiveConversationExporter()
        let json = try exporter.export(archiveRoot: fixture.root, conversationID: fixture.conversationID, destinationRoot: destination, format: .json)
        let jsonData = try Data(contentsOf: json.primaryFileURL)
        let jsonObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let messages = try XCTUnwrap(jsonObject["messages"] as? [[String: Any]])
        let markdown = try exporter.export(archiveRoot: fixture.root, conversationID: fixture.conversationID, destinationRoot: destination, format: .markdown)
        let markdownText = try String(contentsOf: markdown.primaryFileURL, encoding: .utf8)

        XCTAssertEqual(jsonObject["format"] as? String, "WeChatConversationExport")
        XCTAssertEqual(jsonObject["version"] as? Int, 1)
        XCTAssertEqual(messages.count, 5)
        XCTAssertNil(jsonObject["source_database"])
        XCTAssertFalse(String(decoding: jsonData, as: UTF8.self).contains("sensitive-source.db"))
        XCTAssertTrue(markdownText.contains("\\# \\[not a heading\\]"))
        XCTAssertTrue(markdownText.contains("[图片]"))
        XCTAssertTrue(markdownText.contains("[语音"))
        XCTAssertTrue(markdownText.contains("[视频]"))
    }

    func testConversationExporterSupportsTechnicalMetadataOnlyWhenExplicitlyEnabled() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: destination,
            format: .json,
            options: .init(includeTechnicalMetadata: true)
        )
        let text = try String(contentsOf: result.primaryFileURL, encoding: .utf8)

        XCTAssertTrue(text.contains("rawLocalType"))
        XCTAssertFalse(text.contains("sensitive-source.db"))
    }

    func testConversationExporterRejectsArchiveDestinationAndCleansCancelledStaging() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let exporter = WeChatArchiveConversationExporter()

        XCTAssertThrowsError(
            try exporter.export(archiveRoot: fixture.root, conversationID: fixture.conversationID, destinationRoot: fixture.root, format: .html)
        )
        XCTAssertThrowsError(
            try exporter.export(
                archiveRoot: fixture.root,
                conversationID: fixture.conversationID,
                destinationRoot: fixture.root.deletingLastPathComponent(),
                format: .html,
                shouldCancel: { true }
            )
        )
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.root.deletingLastPathComponent().path())
        XCTAssertFalse(siblings.contains { $0.contains(".ChatExport-") })
    }

    func testConversationExporterRejectsSymlinkDestinationAndDoesNotCopySymlinkMedia() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let parent = fixture.root.deletingLastPathComponent()
        let realDestination = parent.appending(path: "RealExports")
        let linkedDestination = parent.appending(path: "LinkedExports")
        try FileManager.default.createDirectory(at: realDestination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedDestination, withDestinationURL: realDestination)
        XCTAssertThrowsError(try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: linkedDestination,
            format: .html
        ))

        let image = fixture.root.appending(path: "media/images/decoded/image-asset.png")
        try FileManager.default.removeItem(at: image)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        let result = try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: realDestination,
            format: .html
        )
        let exportedImages = result.outputRoot.appendingPathComponent("media/images", isDirectory: true)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: exportedImages.path(percentEncoded: false))).isEmpty)
    }

    func testConversationExporterStreamsFiveThousandMessagesInPages() throws {
        let fixture = try makeFixture(messageCount: 5_000)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let destination = fixture.root.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var progressPages = 0

        let result = try WeChatArchiveConversationExporter().export(
            archiveRoot: fixture.root,
            conversationID: fixture.conversationID,
            destinationRoot: destination,
            format: .markdown,
            options: .init(pageSize: 250),
            progress: { progress in
                if progress.messagesExported.isMultiple(of: 250) { progressPages += 1 }
            }
        )

        XCTAssertEqual(result.messagesExported, 5_000)
        XCTAssertGreaterThanOrEqual(progressPages, 20)
    }

    func testWorkspacePreferencesPersistOnlyWorkspaceLocationsAndGracefullyRejectInvalidArchive() throws {
        let suite = "WeChatArchiveTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WorkspacePreferences(defaults: defaults)
        let root = try makeFixture().root
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        preferences.lastPlainSQLiteRoot = URL(fileURLWithPath: "/fixture/plain")
        preferences.lastAccountRoot = URL(fileURLWithPath: "/fixture/account")
        preferences.lastArchiveParentDirectory = URL(fileURLWithPath: "/fixture/archives")
        preferences.lastDatabaseStorageRoot = URL(fileURLWithPath: "/fixture/db_storage")
        preferences.lastPlainSQLiteExportParent = URL(fileURLWithPath: "/fixture/plain-export")
        preferences.lastKeyMapPath = URL(fileURLWithPath: "/fixture/all_keys.json")
        preferences.lastConversationExportDirectory = URL(fileURLWithPath: "/fixture/exports")
        preferences.lastConversationExportFormat = .markdown
        preferences.recordOpenedArchive(root)

        let restored = WorkspacePreferences(defaults: defaults)
        XCTAssertEqual(restored.lastPlainSQLiteRoot?.path, "/fixture/plain")
        XCTAssertEqual(restored.lastAccountRoot?.path, "/fixture/account")
        XCTAssertEqual(restored.lastArchiveParentDirectory?.path, "/fixture/archives")
        XCTAssertEqual(restored.lastDatabaseStorageRoot?.path, "/fixture/db_storage")
        XCTAssertEqual(restored.lastPlainSQLiteExportParent?.path, "/fixture/plain-export")
        XCTAssertEqual(restored.lastKeyMapPath?.path, "/fixture/all_keys.json")
        XCTAssertEqual(restored.lastConversationExportDirectory?.path, "/fixture/exports")
        XCTAssertEqual(restored.lastConversationExportFormat, .markdown)
        XCTAssertEqual(try restored.validLastOpenedArchive()?.standardizedFileURL, root.standardizedFileURL)
        let allowedWorkspaceKeys: Set<String> = [
            "workspace.plainSQLiteRoot", "workspace.accountRoot", "workspace.archiveParent",
            "workspace.databaseStorageRoot", "workspace.plainSQLiteExportParent", "workspace.databaseKeyMap",
            "workspace.lastArchive", "workspace.recentArchives", "workspace.conversationExportDirectory",
            "workspace.conversationExportFormat", "workspace.selectedConversation", "workspace.reopenLastArchive"
        ]
        let storedWorkspaceKeys = Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("workspace.") })
        XCTAssertTrue(storedWorkspaceKeys.isSubset(of: allowedWorkspaceKeys))
        XCTAssertFalse(storedWorkspaceKeys.contains { $0.localizedCaseInsensitiveContains("aes") || $0.localizedCaseInsensitiveContains("password") || $0.localizedCaseInsensitiveContains("secret") })
        XCTAssertEqual(defaults.data(forKey: "workspace.databaseKeyMap")
            .flatMap { try? JSONDecoder().decode(PersistedFolderLocation.self, from: $0) }?.path, "/fixture/all_keys.json")

        let unicode = URL(filePath: "/fixture/归档 😀", directoryHint: .isDirectory)
        preferences.lastConversationExportDirectory = unicode
        XCTAssertEqual(WorkspacePreferences(defaults: defaults).lastConversationExportDirectory?.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")), "fixture/归档 😀")

        try FileManager.default.removeItem(at: root)
        XCTAssertNil(try restored.validLastOpenedArchive())
        XCTAssertNil(restored.lastOpenedArchiveRoot)
    }

    func testViewerSearchesConversationTitlesAndV4CreatesTimelineIndex() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)
        let page = try viewer.searchConversationPage(query: "Fixture", limit: 20)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.id, fixture.conversationID)
        XCTAssertTrue(try hasTimelineIndex(in: fixture.root.appending(path: "archive.sqlite")))
    }

    func testCoverageSummaryCountsMessagesByTypeAndMediaByStatus() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)

        let summary = try viewer.coverageSummary()

        XCTAssertEqual(summary.totalConversations, 1)
        XCTAssertEqual(summary.totalMessages, 5)
        XCTAssertEqual(summary.byType.reduce(0) { $0 + $1.messageCount }, 5)
        XCTAssertEqual(summary.byType.first(where: { $0.normalizedType == .unknown })?.messageCount, 1)
        XCTAssertTrue(summary.mediaByStatus.contains { $0.mediaType == .image && $0.status == .decoded && $0.count == 1 })
        XCTAssertTrue(summary.mediaByStatus.contains { $0.mediaType == .video && $0.status == .rawArchived && $0.count == 1 })
    }

    func testSearchMessagePageFindsTextAcrossConversationsAndComputesSnippet() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)

        let page = try viewer.searchMessagePage(query: "emoji")

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.conversationID, fixture.conversationID)
        XCTAssertEqual(page.items.first?.normalizedType, .text)
        XCTAssertTrue(page.items.first?.snippet.contains("emoji") ?? false)

        let empty = try viewer.searchMessagePage(query: "no-such-fragment-xyz")
        XCTAssertTrue(empty.items.isEmpty)

        // A raw LIKE wildcard in the query must be treated literally, not as a pattern.
        let escaped = try viewer.searchMessagePage(query: "100%")
        XCTAssertTrue(escaped.items.isEmpty)
    }

    func testDerivedSearchIndexSupportsChineseSubstringAndRebuildsOnArchiveChange() throws {
        let fixture = try makeFixture(messageCount: 20)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let cacheRoot = fixture.root.deletingLastPathComponent().appending(path: "SearchIndexes")
        let search = ArchiveMessageSearchService(archiveRoot: fixture.root, indexRoot: cacheRoot)

        let firstBuild = try search.prepareIndex()
        XCTAssertEqual(firstBuild.state, .built)
        XCTAssertEqual(firstBuild.tokenizer, .trigram)
        XCTAssertEqual(try search.search(query: "深圳", offset: 0, limit: 50).items.count, 20)
        XCTAssertEqual(try search.search(query: "咖啡", offset: 0, limit: 50).items.count, 20)
        XCTAssertEqual(try search.search(query: "Hello", offset: 0, limit: 50).items.count, 20)

        XCTAssertEqual(try search.prepareIndex().state, .reused)
        let databaseURL = try XCTUnwrap(search.indexURL)
        XCTAssertEqual(try permissionBits(at: databaseURL), 0o600)
        XCTAssertEqual(try permissionBits(at: cacheRoot), 0o700)

        let archiveDatabase = fixture.root.appending(path: "archive.sqlite")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: archiveDatabase.path)
        XCTAssertEqual(try search.prepareIndex().state, .built)
    }

    func testDerivedSearchFallsBackBeforeBuildAndCancelsWithoutPublishingPartialIndex() throws {
        let fixture = try makeFixture(messageCount: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let cacheRoot = fixture.root.deletingLastPathComponent().appending(path: "SearchIndexes")
        let search = ArchiveMessageSearchService(archiveRoot: fixture.root, indexRoot: cacheRoot)

        XCTAssertEqual(try search.search(query: "深圳", offset: 0, limit: 50).items.count, 50, "LIKE fallback remains available while indexing")

        var indexed = 0
        XCTAssertThrowsError(try search.prepareIndex(
            shouldCancel: { indexed >= 250 },
            progress: { count, _ in indexed = count }
        )) { error in
            XCTAssertEqual(error as? ArchiveSearchIndexError, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(indexed, 250)
        let target = try XCTUnwrap(search.indexURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testDerivedSearchIndexStoresOnlyDisplaySearchFields() throws {
        let fixture = try makeFixture(messageCount: 20)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let search = ArchiveMessageSearchService(archiveRoot: fixture.root, indexRoot: fixture.root.deletingLastPathComponent().appending(path: "SearchIndexes"))
        _ = try search.prepareIndex()
        let indexURL = try XCTUnwrap(search.indexURL)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(indexURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT sql FROM sqlite_master WHERE type = 'table' OR type = 'index'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var schema = ""
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { schema += String(cString: value) }
        }
        XCTAssertFalse(schema.contains("source_database"))
        XCTAssertFalse(schema.contains("source_table"))
        XCTAssertFalse(schema.contains("source_sqlite_rowid"))
    }

    func testDerivedSearchFallsBackWhenItsDisposableIndexIsCorrupt() throws {
        let fixture = try makeFixture(messageCount: 20)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let search = ArchiveMessageSearchService(archiveRoot: fixture.root, indexRoot: fixture.root.deletingLastPathComponent().appending(path: "SearchIndexes"))
        _ = try search.prepareIndex()
        let indexURL = try XCTUnwrap(search.indexURL)
        try FileManager.default.removeItem(at: indexURL)
        try writePrivate(Data("not a sqlite database".utf8), to: indexURL)

        XCTAssertEqual(try search.search(query: "深圳", offset: 0, limit: 50).items.count, 20)
    }

    func testMessageOffsetMatchesAscendingTimelinePosition() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)
        let ordered = try viewer.messagePage(conversationID: fixture.conversationID, limit: 100).items

        for (index, message) in ordered.enumerated() {
            let offset = try viewer.messageOffset(conversationID: fixture.conversationID, messageID: message.id)
            XCTAssertEqual(offset, index)
        }

        XCTAssertNil(try viewer.messageOffset(conversationID: fixture.conversationID, messageID: "missing-message-id"))
    }

    func testMessageWindowAroundAnchorProvidesStableBidirectionalCursors() throws {
        let fixture = try makeFixture(messageCount: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)
        let target = try XCTUnwrap(viewer.messagePage(conversationID: fixture.conversationID, offset: 500, limit: 1).items.first)

        let window = try viewer.messageWindow(conversationID: fixture.conversationID, aroundMessageID: target.id, before: 50, after: 50)

        XCTAssertEqual(window.items.count, 101)
        XCTAssertEqual(window.items[50].id, target.id)
        XCTAssertTrue(window.hasOlder)
        XCTAssertTrue(window.hasNewer)
        XCTAssertEqual(Set(window.items.map(\.id)).count, window.items.count)
        XCTAssertEqual(window.items, window.items.sorted { $0.timestamp < $1.timestamp || ($0.timestamp == $1.timestamp && $0.id < $1.id) }, "fixture timestamps are unique")
    }

    func testCursorPagingHandlesSameTimestampsWithoutDuplicatesOrGaps() throws {
        let fixture = try makeFixture(messageCount: 1_000, sameTimestamp: true)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)
        let target = try XCTUnwrap(viewer.messagePage(conversationID: fixture.conversationID, offset: 500, limit: 1).items.first)
        let cursor = try XCTUnwrap(viewer.messageCursor(conversationID: fixture.conversationID, messageID: target.id))

        let older = try viewer.olderMessages(conversationID: fixture.conversationID, before: cursor, limit: 100)
        let newer = try viewer.newerMessages(conversationID: fixture.conversationID, after: cursor, limit: 100)
        let window = try viewer.messageWindow(conversationID: fixture.conversationID, aroundMessageID: target.id, before: 50, after: 50)

        XCTAssertEqual(older.items.count, 100)
        XCTAssertEqual(newer.items.count, 100)
        XCTAssertFalse(Set(older.items.map(\.id)).contains(target.id))
        XCTAssertFalse(Set(newer.items.map(\.id)).contains(target.id))
        XCTAssertTrue(Set(older.items.map(\.id)).isDisjoint(with: Set(newer.items.map(\.id))))
        XCTAssertEqual(window.items.count, 101)
        XCTAssertEqual(window.items[50].id, target.id)
        XCTAssertEqual(Set(window.items.map(\.id)).count, window.items.count)
    }

    func testTenThousandMessageTimelineCanPageBackwardWithStableCursors() throws {
        let fixture = try makeFixture(messageCount: 10_000, sameTimestamp: true)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)
        var page = try viewer.recentMessagePage(conversationID: fixture.conversationID, limit: 100)
        var seen = Set(page.items.map(\.id))

        while page.hasMore {
            let cursor = try XCTUnwrap(viewer.messageCursor(conversationID: fixture.conversationID, messageID: try XCTUnwrap(page.items.first).id))
            page = try viewer.olderMessages(conversationID: fixture.conversationID, before: cursor, limit: 100)
            let pageIDs = page.items.map(\.id)
            XCTAssertTrue(seen.isDisjoint(with: pageIDs))
            seen.formUnion(pageIDs)
        }
        XCTAssertEqual(seen.count, 10_000)
    }

    func testConversationDateBucketsUseRequestedTimezone() throws {
        let fixture = try makeFixture(messageCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!

        let buckets = try viewer.conversationDateBuckets(conversationID: fixture.conversationID, calendar: calendar)

        XCTAssertEqual(buckets.reduce(0) { $0 + $1.messageCount }, 5)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.messageCount, 5)
        let first = try viewer.messagePage(conversationID: fixture.conversationID, limit: 1).items.first
        XCTAssertEqual(
            try viewer.firstMessageID(conversationID: fixture.conversationID, on: try XCTUnwrap(buckets.first?.day), calendar: calendar),
            first?.id
        )
    }

    func testConversationDateBucketsRespectLocalTimezoneAcrossUTCMidnight() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let boundary = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 15, minute: 59, second: 59)))
        let fixture = try makeFixture(
            messageCount: 2,
            timestamps: [Int64(boundary.timeIntervalSince1970), Int64(boundary.timeIntervalSince1970) + 2]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: fixture.root)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!

        let buckets = try viewer.conversationDateBuckets(conversationID: fixture.conversationID, calendar: local)
        XCTAssertEqual(buckets.map(\.day), ["2026-08-01", "2026-08-02"])
        XCTAssertEqual(buckets.map(\.messageCount), [1, 1])
    }

    /// Opt-in local acceptance coverage. It deliberately emits no private
    /// archive values and is skipped in normal CI.
    func testOptionalExistingArchiveExportsFromArchiveOnly() throws {
        guard let rootPath = ProcessInfo.processInfo.environment["WECHAT_ARCHIVE_REAL_ROOT"], !rootPath.isEmpty else {
            throw XCTSkip("Set WECHAT_ARCHIVE_REAL_ROOT for local archive acceptance coverage.")
        }
        let viewer = try WeChatArchiveViewerDatabase(archiveRoot: URL(fileURLWithPath: rootPath))
        let conversations = try viewer.conversationPage(limit: 100).items
        guard let privateConversation = conversations.filter({ $0.type == .private && $0.messageCount > 0 }).min(by: { $0.messageCount < $1.messageCount }),
              let groupConversation = conversations.filter({ $0.type == .group && $0.messageCount > 0 }).min(by: { $0.messageCount < $1.messageCount }) else {
            throw XCTSkip("The local archive did not expose both non-empty private and group conversations in its first page.")
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "ConversationExportAcceptance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let exporter = WeChatArchiveConversationExporter()
        let privateHTML = try exporter.export(archiveRoot: viewer.archiveRoot, conversationID: privateConversation.id, destinationRoot: destination, format: .html)
        let groupJSON = try exporter.export(archiveRoot: viewer.archiveRoot, conversationID: groupConversation.id, destinationRoot: destination, format: .json)
        let groupMarkdown = try exporter.export(archiveRoot: viewer.archiveRoot, conversationID: groupConversation.id, destinationRoot: destination, format: .markdown)

        XCTAssertGreaterThan(privateHTML.messagesExported, 0)
        XCTAssertGreaterThan(groupJSON.messagesExported, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateHTML.primaryFileURL.path(percentEncoded: false)))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: groupJSON.primaryFileURL)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: groupMarkdown.primaryFileURL.path(percentEncoded: false)))

        // Aggregate timing only: never print paths, names, IDs, or content.
        let initialStart = Date()
        let page = try viewer.conversationPage(limit: 100)
        let initialMilliseconds = Date().timeIntervalSince(initialStart) * 1_000
        guard let conversation = page.items.first else { throw XCTSkip("The local archive has no conversations.") }

        let searchStart = Date()
        _ = try viewer.searchConversationPage(query: String(conversation.title.prefix(1)), limit: 100)
        let searchMilliseconds = Date().timeIntervalSince(searchStart) * 1_000
        let recentStart = Date()
        let recent = try viewer.recentMessagePage(conversationID: conversation.id, limit: 100)
        let recentMilliseconds = Date().timeIntervalSince(recentStart) * 1_000
        let olderStart = Date()
        _ = try viewer.recentMessagePage(conversationID: conversation.id, offset: recent.items.count, limit: 100)
        let olderMilliseconds = Date().timeIntervalSince(olderStart) * 1_000

        let timelineIndex = try hasTimelineIndex(in: URL(fileURLWithPath: rootPath).appending(path: "archive.sqlite"))
        print("Archive viewer query performance (ms): page=\(Int(initialMilliseconds)) search=\(Int(searchMilliseconds)) recent100=\(Int(recentMilliseconds)) older100=\(Int(olderMilliseconds)) timelineIndex=\(timelineIndex ? "yes" : "no")")
        XCTAssertGreaterThanOrEqual(recent.items.count, 0)
    }

    private func makeFixture(
        messageCount: Int = 5,
        conversationTitle: String = "Fixture Group 中文",
        largeVideoBytes: Int? = nil,
        sameTimestamp: Bool = false,
        timestamps: [Int64]? = nil
    ) throws -> ConversationExportFixture {
        let parent = FileManager.default.temporaryDirectory.appending(path: "ConversationExport-\(UUID().uuidString)")
        let root = parent.appending(path: "WeChatArchive")
        let database = try WeChatArchiveV1Database(url: root.appending(path: "archive.sqlite"))
        defer { database.close() }
        let contactID = try database.upsertContact(sourceIdentity: "fixture-contact", alias: nil, remark: nil, nickname: "Fixture sender", displayName: "Fixture sender", contactType: "contact")
        try database.setAccount(sourceIdentity: "fixture-owner", displayName: "Fixture owner")
        let conversationID = try database.upsertConversation(sourceIdentity: "fixture-conversation", type: .group, displayName: conversationTitle, contactID: contactID)
        let base = root.appending(path: "media")
        try writePrivate(Data([0x89, 0x50, 0x4E, 0x47]), to: base.appending(path: "images/decoded/image-asset.png"))
        let videoData = largeVideoBytes.map { Data(repeating: 0x66, count: $0) } ?? Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        try writePrivate(videoData, to: base.appending(path: "video/play/video-asset.mp4"))
        try writePrivate(Data("RIFF----WAVEfmt ".utf8), to: base.appending(path: "voice/decoded/voice-asset.wav"))
        try writePrivate(Data([0x89, 0x50, 0x4E, 0x47]), to: base.appending(path: "avatars/contacts/contact-avatar.png"))
        try writePrivate(Data([0x89, 0x50, 0x4E, 0x47]), to: base.appending(path: "avatars/account/account-avatar.png"))
        let contactAvatar = try database.upsertAvatarAsset(sourceKey: "fixture-contact", sourceFormat: "png", archivePath: "media/avatars/contacts/contact-avatar.png", width: 1, height: 1, size: 4, sha256: ArchiveCryptography.sha256(Data([0x89, 0x50, 0x4E, 0x47])), sourceURL: nil, status: .archived)
        let accountAvatar = try database.upsertAvatarAsset(sourceKey: "fixture-owner", sourceFormat: "png", archivePath: "media/avatars/account/account-avatar.png", width: 1, height: 1, size: 4, sha256: ArchiveCryptography.sha256(Data([0x89, 0x50, 0x4E, 0x47])), sourceURL: nil, status: .archived)
        try database.linkAvatar(assetID: contactAvatar, ownerType: .contact, ownerID: contactID)
        try database.linkAvatar(assetID: accountAvatar, ownerType: .account, ownerID: "1")

        for index in 0..<messageCount {
            let types: [ArchiveV1NormalizedType] = [.text, .image, .voice, .video, .unknown]
            let type = messageCount > 5 ? .text : types[index % types.count]
            let message = try database.insertMessage(
                conversationID: conversationID,
                sourceDatabase: "sensitive-source.db",
                sourceTable: "sensitive-table",
                sourceSQLiteRowID: Int64(index + 1),
                sourceLocalID: Int64(index + 1),
                sourceServerID: nil,
                timestamp: timestamps?[index] ?? (sameTimestamp ? 1_700_000_000 : Int64(1_700_000_000 + index)),
                senderSourceID: index.isMultiple(of: 2) ? "fixture-contact" : "fixture-owner",
                receiverSourceID: nil,
                rawLocalType: Int64(index + 1),
                normalizedType: type,
                textContent: type == .text ? "今天去深圳湾喝咖啡。Hello\n# [not a heading] <script>alert('x')</script> & \"quoted\"\nemoji 😀" : nil,
                replySourceID: nil,
                sourceSequence: Int64(index),
                sourceValues: ["private_blob": .blob(Data([0xAA]))],
                senderContactID: contactID,
                senderDisplayName: "Fixture sender",
                direction: index.isMultiple(of: 2) ? .incoming : .outgoing
            )
            switch type {
            case .image:
                _ = try database.insertMediaAsset(messageID: message.id, assetID: "image-asset", mediaType: .image, variant: .main, status: .decoded, sourceFormat: "dat", decodedFormat: "png", rawArchivePath: nil, decodedArchivePath: "media/images/decoded/image-asset.png", rawSize: nil, decodedSize: 4, width: 1, height: 1, rawSHA256: nil, decodedSHA256: ArchiveCryptography.sha256(Data([0x89, 0x50, 0x4E, 0x47])), sourceFileBase: "private")
            case .voice:
                _ = try database.insertMediaAsset(messageID: message.id, assetID: "voice-asset", mediaType: .voice, variant: .playback, status: .decoded, sourceFormat: "silk", decodedFormat: "wav", rawArchivePath: nil, decodedArchivePath: "media/voice/decoded/voice-asset.wav", rawSize: nil, decodedSize: 16, width: nil, height: nil, duration: 8, rawSHA256: nil, decodedSHA256: ArchiveCryptography.sha256(Data("RIFF----WAVEfmt ".utf8)), sourceFileBase: "private")
            case .video:
                _ = try database.insertMediaAsset(messageID: message.id, assetID: "video-asset", mediaType: .video, variant: .play, status: .rawArchived, sourceFormat: "mp4", decodedFormat: nil, rawArchivePath: "media/video/play/video-asset.mp4", decodedArchivePath: nil, rawSize: Int64(videoData.count), decodedSize: nil, width: 2, height: 2, duration: 9, rawSHA256: ArchiveCryptography.sha256(videoData), decodedSHA256: nil, sourceFileBase: "private")
            case .text, .unknown: break
            }
        }
        return .init(root: root, conversationID: conversationID)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func permissionBits(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
    }

    private func hasTimelineIndex(in databaseURL: URL) throws -> Bool {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'messages_conversation_timeline'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

private struct ConversationExportFixture {
    let root: URL
    let conversationID: String
}
