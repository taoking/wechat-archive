import Foundation

@main
struct ManualTestRunner {
    static func main() {
        let suite = ArchiveCoreTests()
        let tests: [(String, () throws -> Void)] = [
            ("archive partitions and preserves unknown payload", suite.testArchiveWriterPartitionsMessagesByConversationAndYearAndPreservesUnknownPayload),
            ("media SHA-256 deduplication", suite.testMediaStoreDeduplicatesContentUsingSHA256InsteadOfFilename),
            ("incremental import deduplication and history", suite.testImportCoordinatorSkipsStableAndFallbackDuplicatesAndRecordsSessionCounts),
            ("SQLite FTS search filters", suite.testSQLiteIndexFindsMessagesWithFTSAndAppliesFilters),
            ("offline HTML and CSV exporters", suite.testExportersEscapeContentAndRemainOffline),
            ("integrity verification redacts content", suite.testVerifierReportsChecksumMismatchWithoutExposingMessageContent),
            ("archive statistics", suite.testStatisticsCountsMessageTypesAndPreservesDateRange),
            ("import provider contracts", suite.testImportProviderContractsCoverEverySupportedSourceKind)
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name) — \(error)")
            }
        }
        if failures > 0 {
            exit(EXIT_FAILURE)
        }
    }
}
