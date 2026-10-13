import CryptoKit
import Foundation

/// Binds only local files whose bytes match the structured message size and
/// MD5. Titles and extensions alone are never attachment evidence.
struct WeChatFileMessageAdapter {
    static func isFileMessage(_ values: [String: ArchivedSQLiteValue]) -> Bool {
        document(values)?.text(atPath: ["msg", "appmsg", "type"]) == "6"
    }

    private static func document(_ values: [String: ArchivedSQLiteValue]) -> WeChatMessageXMLDocument? {
        WeChatMessagePayloadDecoder.decodedPayload(from: values).flatMap(WeChatMessageXMLDocument.init(xml:))
    }

    func attachment(values: [String: ArchivedSQLiteValue], accountRoot: URL) throws -> ArchiveV1MediaInput {
        let missing = ArchiveV1MediaInput(mediaType: .file, variant: .raw, status: .missing, sourceFormat: nil,
            decodedFormat: nil, rawData: nil, decodedData: nil, width: nil, height: nil, sourceFileBase: nil)
        guard let doc = Self.document(values), doc.text(atPath: ["msg", "appmsg", "type"]) == "6",
              let title = doc.text(atPath: ["msg", "appmsg", "title"]), safeFilename(title),
              let size = doc.text(atPath: ["msg", "appmsg", "appattach", "totallen"]).flatMap(Int64.init), size >= 0,
              let digest = (doc.text(atPath: ["msg", "appmsg", "md5"]) ?? doc.text(atPath: ["msg", "appmsg", "appattach", "md5"]))?.lowercased(),
              digest.utf8.count == 32, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return missing }
        let root = accountRoot.standardizedFileURL
        let msg = root.appending(path: "msg"), files = msg.appending(path: "file")
        guard safeDirectory(root, below: nil), safeDirectory(msg, below: root), safeDirectory(files, below: msg) else { return missing }
        let months = try FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { safeDirectory($0, below: files) && $0.lastPathComponent.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var candidates = months.map { $0.appending(path: title) }
        for month in months {
            candidates += try FileManager.default.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
                .filter { $0.lastPathComponent != title }
        }
        for url in candidates {
            guard safeFile(url, below: files),
                  let before = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), Int64(before.fileSize ?? -1) == size,
                  let hash = try? md5(url), hash == digest,
                  let after = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { continue }
            return .init(mediaType: .file, variant: .raw, status: .rawArchived, sourceFormat: url.pathExtension,
                decodedFormat: nil, rawData: nil, rawFileURL: url, decodedData: nil, width: nil, height: nil, sourceFileBase: digest)
        }
        return missing
    }

    private func safeFilename(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func safeDirectory(_ url: URL, below root: URL?) -> Bool {
        guard let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), info.isDirectory == true, info.isSymbolicLink != true else { return false }
        return root.map { descendant(url, of: $0) } ?? true
    }

    private func safeFile(_ url: URL, below root: URL) -> Bool {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), info.isRegularFile == true, info.isSymbolicLink != true else { return false }
        return descendant(url, of: root)
    }

    private func descendant(_ url: URL, of root: URL) -> Bool {
        let path = root.resolvingSymlinksInPath().path()
        return url.resolvingSymlinksInPath().path().hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    private func md5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
