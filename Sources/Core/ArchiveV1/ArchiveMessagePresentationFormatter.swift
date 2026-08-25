import Foundation

/// Readable presentation of WeChat's quote-reply text. The archive retains
/// the original source values separately; this type intentionally projects
/// only a compact, safe summary for Viewer and conversation exports.
public struct ArchiveQuotedMessagePresentation: Equatable, Sendable {
    public let quotedSender: String
    public let quotedSummary: String
    public let replyText: String

    public var displayText: String {
        let quote = "引用「\(quotedSender)」：\(quotedSummary)"
        return replyText.isEmpty ? quote : "\(quote)\n\(replyText)"
    }
}

/// Keeps WeChat's quoted-message transport XML out of ordinary UI, search
/// snippets, and portable exports. It does not parse XML documents or resolve
/// entities, so it cannot perform network or external-DTD resolution.
public enum ArchiveMessagePresentationFormatter {
    private static let quotePrefix = "引用「"
    private static let quoteSeparator = "」："
    private static let maximumQuotedTextLength = 120

    /// Converts the legacy stored quote string into a structured, readable
    /// preview. Returns nil when the text is not in the archive's quote form.
    public static func quotedPresentation(for text: String?) -> ArchiveQuotedMessagePresentation? {
        guard let text, text.hasPrefix(quotePrefix) else { return nil }
        let senderStart = text.index(text.startIndex, offsetBy: quotePrefix.count)
        guard let separator = text.range(of: quoteSeparator, range: senderStart..<text.endIndex) else { return nil }
        let sender = String(text[senderStart..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty else { return nil }

        let remainder = String(text[separator.upperBound...])
        let parts = quotedContentAndReply(from: remainder)
        return .init(
            quotedSender: sender,
            quotedSummary: quotedMessageSummary(referType: nil, quotedContent: parts.quotedContent),
            replyText: parts.replyText
        )
    }

    /// Returns readable text for either a legacy quote or an already
    /// normalized message. This is the common presentation boundary for every
    /// source-independent consumer of Archive text.
    public static func displayText(for text: String?) -> String? {
        guard let text else { return nil }
        return quotedPresentation(for: text)?.displayText ?? text
    }

    /// Normalizes the referenced payload while importing new archives. A
    /// quoted XML payload is never returned verbatim, even when an unexpected
    /// reference type claims it is plain text.
    public static func quotedMessageSummary(referType: String?, quotedContent: String) -> String {
        let trimmed = quotedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "[引用消息]" }

        if let typeSummary = referenceTypeSummary(referType) {
            return typeSummary
        }
        if isXMLLike(trimmed) {
            return xmlSummary(trimmed)
        }

        // WeChat marks ordinary quoted text as type 1. Some observed payloads
        // omit the type, so a clearly non-XML content value remains readable.
        return quotedTextPreview(trimmed)
    }

    private static func referenceTypeSummary(_ referType: String?) -> String? {
        switch Int(referType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
        case 3: "[图片]"
        case 34: "[语音]"
        case 43: "[视频]"
        case 47: "[表情]"
        case 49: "[分享]"
        default: nil
        }
    }

    private static func quotedContentAndReply(from remainder: String) -> (quotedContent: String, replyText: String) {
        let leadingTrimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leadingTrimmed.isEmpty else { return ("", "") }

        if isXMLLike(leadingTrimmed) {
            if let end = XMLBoundary.endIndex(in: leadingTrimmed) {
                let xml = String(leadingTrimmed[..<end])
                let reply = String(leadingTrimmed[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (xml, reply)
            }
            // A malformed XML payload is still never displayed. Without a
            // reliable document boundary, a newline might be XML formatting
            // rather than the reply body, so do not risk leaking attributes.
            return (leadingTrimmed, "")
        }
        return splitAtFirstNewline(leadingTrimmed)
    }

    private static func splitAtFirstNewline(_ text: String) -> (quotedContent: String, replyText: String) {
        guard let newline = text.firstIndex(of: "\n") else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let quoted = String(text[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (quoted, reply)
    }

    private static func isXMLLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<") || trimmed.hasPrefix("<?xml")
    }

    private static func xmlSummary(_ xml: String) -> String {
        let lower = xml.lowercased()
        if lower.contains("<img") { return "[图片]" }
        if lower.contains("<videomsg") { return "[视频]" }
        if lower.contains("<voicemsg") { return "[语音]" }
        if lower.contains("<emoji") { return "[表情]" }
        if lower.contains("<location") { return "[位置]" }
        if lower.contains("<appmsg") {
            return appMessageTitle(in: xml).map { "[分享] \($0)" } ?? "[分享]"
        }
        return "[引用消息]"
    }

    private static func appMessageTitle(in xml: String) -> String? {
        guard let start = xml.range(of: "<title>", options: [.caseInsensitive]),
              let end = xml.range(of: "</title>", options: [.caseInsensitive], range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        let raw = String(xml[start.upperBound..<end.lowerBound])
        guard !raw.contains("<") else { return nil }
        let title = raw
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : quotedTextPreview(title)
    }

    private static func quotedTextPreview(_ text: String) -> String {
        let compact = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard compact.count > maximumQuotedTextLength else { return compact }
        return String(compact.prefix(maximumQuotedTextLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private enum XMLBoundary {
    /// Finds a bounded XML document end without initializing an XML parser.
    /// Quote payloads are not trusted presentation data, and the fallback
    /// intentionally hides malformed XML instead of exposing attributes.
    static func endIndex(in text: String) -> String.Index? {
        let roots = ["msg", "sysmsg", "appmsg"]
        guard let root = roots
            .compactMap({ name in text.range(of: "<\(name)", options: [.caseInsensitive]).map { (name, $0) } })
            .min(by: { $0.1.lowerBound < $1.1.lowerBound })?.0 else {
            return nil
        }
        let closeTag = "</\(root)>"
        var searchStart = text.startIndex
        var boundary: String.Index?
        while let range = text.range(of: closeTag, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            boundary = range.upperBound
            searchStart = range.upperBound
        }
        return boundary
    }
}
