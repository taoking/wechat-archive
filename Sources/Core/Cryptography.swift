import CryptoKit
import Foundation

enum ArchiveCryptography {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
            digest.update(data: chunk)
            return true
        }) {}
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension Message {
    /// Source IDs take priority. This fallback intentionally includes the source
    /// metadata that is least likely to collide when older databases lack IDs.
    var fallbackFingerprint: String {
        let mediaHashes = media.map(\.sha256).sorted().joined(separator: ",")
        let input = [
            conversationID,
            sender.id,
            ISO8601DateFormatter.makeArchiveFormatter().string(from: timestamp),
            type.rawValue,
            ArchiveCryptography.sha256(Data((content ?? "").utf8)),
            mediaHashes
        ].joined(separator: "\u{1F}")
        return ArchiveCryptography.sha256(Data(input.utf8))
    }
}

extension ISO8601DateFormatter {
    static func makeArchiveFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
