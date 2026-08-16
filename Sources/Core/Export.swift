import Foundation

public protocol ArchiveExporter: Sendable {
    func export(messages: [Message], conversationName: String, to directory: URL) throws -> URL
}

public struct JSONExporter: ArchiveExporter {
    public init() {}

    public func export(messages: [Message], conversationName: String, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "messages.json")
        try JSONEncoder.archiveEncoder.encode(messages).write(to: output, options: .atomic)
        return output
    }
}

public struct NDJSONExporter: ArchiveExporter {
    public init() {}

    public func export(messages: [Message], conversationName: String, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "messages.ndjson")
        try NDJSONWriter().write(messages, to: output)
        return output
    }
}

public struct CSVExporter: ArchiveExporter {
    public init() {}

    public func export(messages: [Message], conversationName: String, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "messages.csv")
        let header = "timestamp,conversation,sender,type,content,media_path"
        let rows = messages.map { message in
            [
                ISO8601DateFormatter.archive.string(from: message.timestamp), conversationName,
                message.sender.displayName, message.type.rawValue, message.content ?? "",
                message.media.map(\.relativePath).joined(separator: ";")
            ].map(escapeCSV).joined(separator: ",")
        }
        try Data(([header] + rows).joined(separator: "\n").appending("\n").utf8).write(to: output, options: .atomic)
        return output
    }

    private func escapeCSV(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

public struct HTMLExporter: ArchiveExporter {
    public init() {}

    public func export(messages: [Message], conversationName: String, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "index.html")
        let title = escapeHTML(conversationName)
        let rows = messages.sorted { $0.timestamp < $1.timestamp }.map(render).joined(separator: "\n")
        let document = """
            <!doctype html>
            <html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title) · WeChat Archive</title>
            <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 0; background: #f5f5f3; color: #20211f; } main { max-width: 780px; margin: auto; padding: 28px 18px; }
            h1 { font-size: 20px; } .message { display: grid; grid-template-columns: 108px 1fr; gap: 12px; margin: 14px 0; }
            time { color: #6a6c67; font-size: 12px; } .sender { font-weight: 600; font-size: 13px; } .bubble { background: #fff; border-radius: 12px; padding: 10px 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
            .meta { color: #6a6c67; font-size: 12px; margin-bottom: 4px; }
            @media (prefers-color-scheme: dark) { body { background: #1d1e1b; color: #eceee9; } .bubble { background: #2a2c28; } }
            </style></head><body><main><h1>\(title)</h1>\(rows)</main></body></html>
            """
        try Data(document.utf8).write(to: output, options: .atomic)
        return output
    }

    private func render(_ message: Message) -> String {
        let time = ISO8601DateFormatter.archive.string(from: message.timestamp)
        let content: String
        if let text = message.content {
            content = escapeHTML(text)
        } else if let asset = message.media.first {
            content = "<a href=\"\(escapeAttribute(asset.relativePath))\">\(escapeHTML(message.type.rawValue))</a>"
        } else {
            content = escapeHTML(message.type.rawValue)
        }
        return "<article class=\"message\"><time datetime=\"\(escapeAttribute(time))\">\(escapeHTML(time))</time><div><div class=\"sender\">\(escapeHTML(message.sender.displayName))</div><div class=\"bubble\">\(content)</div></div></article>"
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func escapeAttribute(_ value: String) -> String {
        escapeHTML(value).replacingOccurrences(of: "`", with: "&#96;")
    }
}
