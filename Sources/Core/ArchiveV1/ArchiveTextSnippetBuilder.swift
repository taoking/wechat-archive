import Foundation

/// Shared substring-with-ellipsis snippet builder used by both the archive
/// viewer's read-only LIKE search and the derived FTS/LIKE search service,
/// so their snippet formatting cannot drift apart.
enum ArchiveTextSnippetBuilder {
    static func snippet(for content: String, query: String, contextLength: Int = 24) -> String {
        guard let range = content.range(of: query, options: [.caseInsensitive]) else {
            return content.count > 60 ? String(content.prefix(60)) + "…" : content
        }
        let lowerBound = content.index(range.lowerBound, offsetBy: -contextLength, limitedBy: content.startIndex) ?? content.startIndex
        let upperBound = content.index(range.upperBound, offsetBy: contextLength, limitedBy: content.endIndex) ?? content.endIndex
        var snippet = String(content[lowerBound..<upperBound])
        if lowerBound != content.startIndex { snippet = "…" + snippet }
        if upperBound != content.endIndex { snippet += "…" }
        return snippet
    }
}
