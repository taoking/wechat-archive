import Foundation

/// Copies a verified archive file in bounded chunks so a conversation export
/// can react to cancellation while a large video is being copied. Both roots
/// are explicit trust boundaries: the copier rejects symlinks and path escapes
/// instead of relying on a caller-provided relative path.
public struct CancellableFileCopier: Sendable {
    public static let chunkSize = 8 * 1_024 * 1_024

    public init() {}

    public func copy(
        from source: URL,
        to destination: URL,
        sourceRoot: URL,
        destinationRoot: URL,
        shouldCancel: () -> Bool,
        progress: (Int64) -> Void
    ) throws {
        try validate(source, inside: sourceRoot, mustExist: true)
        try validate(destination, inside: destinationRoot, mustExist: false)

        let parent = destination.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw ConversationExportError.invalidDestination
        }
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)),
              FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConversationExportError.ioFailure
        }

        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }

            var copied: Int64 = 0
            while true {
                try checkCancellation(shouldCancel)
                guard let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                progress(copied)
            }
            try checkCancellation(shouldCancel)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path(percentEncoded: false))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if error is CancellationError || (error as? ConversationExportError) == .cancelled {
                throw ConversationExportError.cancelled
            }
            throw error
        }
    }

    private func checkCancellation(_ shouldCancel: () -> Bool) throws {
        if shouldCancel() { throw ConversationExportError.cancelled }
    }

    private func validate(_ url: URL, inside root: URL, mustExist: Bool) throws {
        let standardized = url.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(standardized, of: root.standardizedFileURL),
              isDescendant(resolved, of: resolvedRoot) else {
            throw ConversationExportError.invalidDestination
        }
        if mustExist {
            let values = try standardized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ConversationExportError.invalidDestination
            }
        }
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let prefix = root.path().hasSuffix("/") ? root.path() : root.path() + "/"
        return candidate.path() != root.path() && candidate.path().hasPrefix(prefix)
    }
}
