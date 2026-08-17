import Foundation

struct ArchiveV1StoredMedia: Sendable {
    let relativePath: String
    let size: Int64
    let sha256: String
}

/// Writes only into the private archive destination. Source DAT files are read
/// by the adapter and never renamed, changed, or deleted.
struct WeChatArchiveV1MediaStore: Sendable {
    let root: URL

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        let rootValues = try self.root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        let media = self.root.appending(path: "media")
        let images = media.appending(path: "images")
        try Self.createProtectedDirectory(media, below: self.root)
        try Self.createProtectedDirectory(images, below: self.root)
        try Self.createProtectedDirectory(images.appending(path: "raw"), below: self.root)
        try Self.createProtectedDirectory(images.appending(path: "decoded"), below: self.root)
    }

    func storeRawDAT(_ data: Data, assetID: String) throws -> ArchiveV1StoredMedia {
        try store(data, relativeDirectory: "media/images/raw", filename: "\(assetID).dat")
    }

    func storeDecoded(_ data: Data, assetID: String, format: String?) throws -> ArchiveV1StoredMedia {
        let extensionName: String
        switch format?.lowercased() {
        case "jpeg": extensionName = "jpg"
        case "png", "gif", "webp", "heic", "wxgf": extensionName = format!.lowercased()
        default: extensionName = "bin"
        }
        return try store(data, relativeDirectory: "media/images/decoded", filename: "\(assetID).\(extensionName)")
    }

    private func store(_ data: Data, relativeDirectory: String, filename: String) throws -> ArchiveV1StoredMedia {
        let directory = root.appending(path: relativeDirectory).standardizedFileURL
        guard isDescendant(directory, of: root) else { throw ArchiveError.invalidInput }
        let destination = directory.appending(path: filename).standardizedFileURL
        guard isDescendant(destination, of: directory), !FileManager.default.fileExists(atPath: destination.path()) else {
            throw ArchiveError.ioFailure
        }

        let temporary = directory.appending(path: ".\(UUID().uuidString.lowercased()).staging")
        let expectedHash = ArchiveCryptography.sha256(data)
        do {
            FileManager.default.createFile(atPath: temporary.path(), contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path())
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value == Int64(data.count),
                  try ArchiveCryptography.sha256(fileAt: temporary) == expectedHash else {
                throw ArchiveError.ioFailure
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path())
            return ArchiveV1StoredMedia(relativePath: "\(relativeDirectory)/\(filename)", size: Int64(data.count), sha256: expectedHash)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func createProtectedDirectory(_ url: URL, below root: URL) throws {
        let manager = FileManager.default
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard isDescendant(parent, of: root) else { throw ArchiveError.invalidInput }
        if manager.fileExists(atPath: url.path()) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.invalidInput }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path())
        guard isDescendant(url, of: root) else { throw ArchiveError.invalidInput }
    }

    private func isDescendant(_ url: URL, of parent: URL) -> Bool {
        Self.isDescendant(url, of: parent)
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path()
        let valuePath = url.resolvingSymlinksInPath().standardizedFileURL.path()
        return valuePath.hasPrefix(parentPath.hasSuffix("/") ? parentPath : parentPath + "/")
    }
}
