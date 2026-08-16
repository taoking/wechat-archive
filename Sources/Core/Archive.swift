import Foundation

public struct NDJSONWriter: Sendable {
    public init() {}

    public func write(_ messages: [Message], to url: URL) throws {
        let encoder = JSONEncoder.archiveLineEncoder
        let data = try messages.reduce(into: Data()) { output, message in
            output.append(try encoder.encode(message))
            output.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}

public struct NDJSONReader: Sendable {
    public init() {}

    public func read(from url: URL) throws -> [Message] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw ArchiveError.invalidArchive }
        let decoder = JSONDecoder.archiveDecoder
        return try text.split(whereSeparator: \.isNewline).map { line in
            guard let lineData = line.data(using: .utf8) else { throw ArchiveError.invalidArchive }
            return try decoder.decode(Message.self, from: lineData)
        }
    }
}

public final class ArchiveWriter: @unchecked Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Writes the v1 portable representation. Existing message partitions are
    /// replaced only when the caller intentionally writes this archive root.
    public func write(
        messages: [Message],
        account: Account,
        contacts: [Contact] = [],
        conversations: [Conversation] = []
    ) throws {
        try createArchiveDirectories()
        try writeJSON(account, named: "account.json")
        try writeJSON(contacts, named: "contacts.json")
        try writeJSON(conversations, named: "conversations.json")

        let grouped = Dictionary(grouping: messages) { message in
            "\(message.conversationID)/\(year(for: message))"
        }
        for (partition, values) in grouped {
            let parts = partition.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ArchiveError.invalidInput }
            let directory = rootURL.appending(path: "messages").appending(path: parts[0])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try NDJSONWriter().write(values.sorted { $0.timestamp < $1.timestamp }, to: directory.appending(path: "\(parts[1]).ndjson"))
        }

        let manifest = ArchiveManifest(
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: messages.count,
            conversationCount: Set(messages.map(\.conversationID)).count,
            mediaCount: Set(messages.flatMap(\.media).map(\.sha256)).count
        )
        try writeJSON(manifest, named: "manifest.json")
        try ChecksumWriter().write(for: rootURL)
    }

    private func createArchiveDirectories() throws {
        for directory in [
            "messages", "media/images", "media/videos", "media/voice", "media/files",
            "media/stickers", "media/thumbnails", "database", "sources", "exports", "checksums"
        ] {
            try FileManager.default.createDirectory(at: rootURL.appending(path: directory), withIntermediateDirectories: true)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, named filename: String) throws {
        let data = try JSONEncoder.archiveEncoder.encode(value)
        try data.write(to: rootURL.appending(path: filename), options: .atomic)
    }

    private func year(for message: Message) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: message.sourceTimeZone) ?? .current
        return calendar.component(.year, from: message.timestamp)
    }
}

public struct ArchiveReader: Sendable {
    public init() {}

    public func manifest(from rootURL: URL) throws -> ArchiveManifest {
        let url = rootURL.appending(path: "manifest.json")
        do {
            let manifest = try JSONDecoder.archiveDecoder.decode(ArchiveManifest.self, from: Data(contentsOf: url))
            guard manifest.format == ArchiveManifest.formatName, manifest.version == ArchiveManifest.currentVersion else {
                throw ArchiveError.invalidArchive
            }
            return manifest
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.invalidArchive
        }
    }
}

public struct MediaStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func store(data: Data, suggestedFilename: String, category: MediaCategory, mimeType: String? = nil) throws -> MediaAsset {
        let hash = ArchiveCryptography.sha256(data)
        // The hash, not a user-controlled filename or extension, determines the
        // physical object path. This makes identical bytes share one file.
        let relativePath = "media/\(category.rawValue)/\(hash.prefix(2))/\(hash).bin"
        let destination = rootURL.appending(path: relativePath)
        if !FileManager.default.fileExists(atPath: destination.path()) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        return MediaAsset(
            id: "sha256:\(hash)",
            relativePath: relativePath,
            sha256: hash,
            mimeType: mimeType,
            size: Int64(data.count),
            category: category
        )
    }

}

public struct ArchiveHealthReport: Equatable, Sendable {
    public let messageCount: Int
    public let mediaCount: Int
    public let missingFiles: Int
    public let corruptedFiles: Int
    public let databaseErrors: Int
    public let issues: [String]

    public var isHealthy: Bool {
        missingFiles == 0 && corruptedFiles == 0 && databaseErrors == 0
    }
}

public struct ArchiveVerifier: Sendable {
    public init() {}

    public func verify(at rootURL: URL) throws -> ArchiveHealthReport {
        _ = try ArchiveReader().manifest(from: rootURL)
        var issues: [String] = []
        var corrupted = Set<String>()
        var missing = Set<String>()
        let checksums = try ChecksumReader().read(from: rootURL.appending(path: "checksums/SHA256SUMS.txt"))

        for (relativePath, expectedHash) in checksums {
            let fileURL = rootURL.appending(path: relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path()) else {
                missing.insert(relativePath)
                issues.append("Missing archive file: \(relativePath)")
                continue
            }
            if try ArchiveCryptography.sha256(fileAt: fileURL) != expectedHash {
                corrupted.insert(relativePath)
                issues.append("Checksum mismatch: \(relativePath)")
            }
        }

        let messageFiles = try regularFiles(in: rootURL.appending(path: "messages"), withExtension: "ndjson")
        var messages: [Message] = []
        for file in messageFiles {
            do {
                messages.append(contentsOf: try NDJSONReader().read(from: file))
            } catch {
                let relative = relativePath(file, from: rootURL)
                if !corrupted.contains(relative) {
                    corrupted.insert(relative)
                    issues.append("Unreadable message partition: \(relative)")
                }
            }
        }
        for media in messages.flatMap(\.media) {
            let path = rootURL.appending(path: media.relativePath)
            if !FileManager.default.fileExists(atPath: path.path()) {
                missing.insert(media.relativePath)
                issues.append("Missing referenced media: \(media.relativePath)")
            }
        }

        return ArchiveHealthReport(
            messageCount: messages.count,
            mediaCount: Set(messages.flatMap(\.media).map(\.sha256)).count,
            missingFiles: missing.count,
            corruptedFiles: corrupted.count,
            databaseErrors: 0,
            issues: issues.sorted()
        )
    }

    private func regularFiles(in directory: URL, withExtension fileExtension: String) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path()) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true { return [url] }
            return try? regularFiles(in: url, withExtension: fileExtension)
        }.flatMap { $0 }.filter { $0.pathExtension == fileExtension }
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        String(url.path().dropFirst(root.path().count + 1))
    }
}

struct ChecksumWriter: Sendable {
    func write(for rootURL: URL) throws {
        let entries = try allRegularFiles(in: rootURL)
            .filter { relativePath($0, from: rootURL) != "checksums/SHA256SUMS.txt" }
            .sorted { $0.path() < $1.path() }
            .map { "\(try ArchiveCryptography.sha256(fileAt: $0))  \(relativePath($0, from: rootURL))" }
        let output = entries.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
        try Data(output.utf8).write(to: rootURL.appending(path: "checksums/SHA256SUMS.txt"), options: .atomic)
    }

    private func allRegularFiles(in rootURL: URL) throws -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ArchiveError.ioFailure
        }
        var files: [URL] = []
        for case let file as URL in iterator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(file)
            }
        }
        return files
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        String(url.path().dropFirst(root.path().count + 1))
    }
}

struct ChecksumReader: Sendable {
    func read(from url: URL) throws -> [String: String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try content.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].count == 64 else { throw ArchiveError.invalidArchive }
            result[String(parts[1])] = String(parts[0])
        }
    }
}

extension JSONEncoder {
    static var archiveEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.archive.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var archiveLineEncoder: JSONEncoder {
        let encoder = archiveEncoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var archiveDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ISO8601DateFormatter.archive.date(from: value) else { throw ArchiveError.invalidArchive }
            return date
        }
        return decoder
    }
}
