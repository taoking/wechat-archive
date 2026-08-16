import Darwin
import Foundation

/// Typed SQLCipher settings applied after the key and before the first page is
/// read. Defaults are SQLCipher's own defaults; callers may opt into a known
/// source layout without accepting arbitrary SQL text.
public struct SQLCipherConfiguration: Sendable, Equatable {
    public enum HMACAlgorithm: String, Sendable, CaseIterable {
        case sha1 = "HMAC_SHA1"
        case sha256 = "HMAC_SHA256"
        case sha512 = "HMAC_SHA512"
    }

    public enum KDFAlgorithm: String, Sendable, CaseIterable {
        case sha1 = "PBKDF2_HMAC_SHA1"
        case sha256 = "PBKDF2_HMAC_SHA256"
        case sha512 = "PBKDF2_HMAC_SHA512"
    }

    public var pageSize: Int?
    public var kdfIterations: Int?
    public var hmacAlgorithm: HMACAlgorithm?
    public var kdfAlgorithm: KDFAlgorithm?
    public var usesHMAC: Bool?

    public init(
        pageSize: Int? = nil,
        kdfIterations: Int? = nil,
        hmacAlgorithm: HMACAlgorithm? = nil,
        kdfAlgorithm: KDFAlgorithm? = nil,
        usesHMAC: Bool? = nil
    ) {
        self.pageSize = pageSize
        self.kdfIterations = kdfIterations
        self.hmacAlgorithm = hmacAlgorithm
        self.kdfAlgorithm = kdfAlgorithm
        self.usesHMAC = usesHMAC
    }

    fileprivate func validatedStatements() throws -> [String] {
        var statements: [String] = []
        if let pageSize {
            guard pageSize >= 512, pageSize <= 65_536, pageSize.nonzeroBitCount == 1 else { throw ArchiveError.invalidInput }
            statements.append("PRAGMA cipher_page_size = \(pageSize)")
        }
        if let kdfIterations {
            guard kdfIterations >= 1_000, kdfIterations <= 10_000_000 else { throw ArchiveError.invalidInput }
            statements.append("PRAGMA kdf_iter = \(kdfIterations)")
        }
        if let hmacAlgorithm { statements.append("PRAGMA cipher_hmac_algorithm = \(hmacAlgorithm.rawValue)") }
        if let kdfAlgorithm { statements.append("PRAGMA cipher_kdf_algorithm = \(kdfAlgorithm.rawValue)") }
        if let usesHMAC { statements.append("PRAGMA cipher_use_hmac = \(usesHMAC ? "ON" : "OFF")") }
        return statements
    }
}

/// Local SQLCipher implementation for databases the current user is authorized
/// to access. The source is opened read-only, a documented SQLCipher raw-key
/// literal is applied in-process, and only a protected plaintext copy is written.
public struct SQLCipherDatabaseDecryptor: WeChatDatabaseDecryptor, @unchecked Sendable {
    private let api: SQLCipherAPI
    private let plaintextHeaderValidator: @Sendable (URL) throws -> Void
    public let configuration: SQLCipherConfiguration

    /// Finds a locally installed SQLCipher runtime. Supply `libraryURL` only for
    /// an explicitly bundled/managed SQLCipher dylib; it is never fetched.
    public init(configuration: SQLCipherConfiguration = .init(), libraryURL: URL? = nil) throws {
        try self.init(
            configuration: configuration,
            libraryURL: libraryURL,
            plaintextHeaderValidator: { url in try Self.validatePlaintextHeader(at: url) }
        )
    }

    init(
        configuration: SQLCipherConfiguration = .init(),
        libraryURL: URL? = nil,
        plaintextHeaderValidator: @escaping @Sendable (URL) throws -> Void
    ) throws {
        api = try SQLCipherAPI(libraryURL: libraryURL)
        self.configuration = configuration
        self.plaintextHeaderValidator = plaintextHeaderValidator
    }

    public func validate(databaseURL: URL, key: WeChatDatabaseKey) throws {
        try validateInputs(key: key)
        let validationDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WeChatArchive-Validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: validationDirectory) }
        do {
            try FileManager.default.createDirectory(
                at: validationDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let snapshot = try DatabaseSnapshotter().snapshot(
                databaseURL: databaseURL,
                into: validationDirectory.appending(path: "snapshot")
            )
            let connection = try openConnection(databaseURL: snapshot, key: key, mode: .readOnly)
            defer { connection.close() }
            try connection.verifyKey()
        } catch {
            if let archiveError = error as? ArchiveError { throw archiveError }
            throw ArchiveError.databaseDecryptionFailed
        }
    }

    public func decrypt(databaseURL: URL, key: WeChatDatabaseKey, into workingDirectory: URL) throws -> URL {
        try validateInputs(key: key)
        let destination = try createProtectedDestination(in: workingDirectory)
        let snapshotDirectory = workingDirectory.appending(path: "encrypted-snapshot-\(UUID().uuidString)")
        let manager = FileManager.default
        do {
            let snapshot = try DatabaseSnapshotter().snapshot(databaseURL: databaseURL, into: snapshotDirectory)
            try exportSnapshot(snapshot, key: key, to: destination)
            try plaintextHeaderValidator(destination)
            try restrictSQLiteArtifacts(at: destination, using: manager)
            try manager.removeItem(at: snapshotDirectory)
            return destination
        } catch {
            removeExportArtifacts(at: destination)
            try? manager.removeItem(at: snapshotDirectory)
            if let archiveError = error as? ArchiveError { throw archiveError }
            throw ArchiveError.databaseDecryptionFailed
        }
    }

    private func exportSnapshot(_ snapshot: URL, key: WeChatDatabaseKey, to destination: URL) throws {
        let connection = try openConnection(databaseURL: snapshot, key: key, mode: .readWriteSnapshot)
        defer { connection.close() }
        try connection.verifyKey()
        try connection.exportPlaintext(to: destination)
    }

    private func validateInputs(key: WeChatDatabaseKey) throws {
        let validRawKeyLength = key.withData { data in data.count == 32 || data.count == 48 }
        guard validRawKeyLength else { throw ArchiveError.keyInvalid }
        _ = try configuration.validatedStatements()
    }

    private func openConnection(databaseURL: URL, key: WeChatDatabaseKey, mode: SQLCipherOpenMode) throws -> SQLCipherConnection {
        let values = try databaseURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw ArchiveError.invalidInput }
        let connection = try SQLCipherConnection(api: api, databaseURL: databaseURL, mode: mode)
        do {
            try connection.apply(key: key, configuration: configuration)
            return connection
        } catch {
            connection.close()
            if let archiveError = error as? ArchiveError { throw archiveError }
            throw ArchiveError.databaseDecryptionFailed
        }
    }

    private func createProtectedDestination(in workingDirectory: URL) throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: workingDirectory.path()) {
            let values = try workingDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw ArchiveError.invalidInput }
        } else {
            try manager.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workingDirectory.path())
        let destination = workingDirectory.appending(path: "decrypted-\(UUID().uuidString).sqlite")
        guard destination.deletingLastPathComponent().standardizedFileURL == workingDirectory.standardizedFileURL else {
            throw ArchiveError.invalidInput
        }
        return destination
    }

    private static func validatePlaintextHeader(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16) ?? Data()
        guard data.starts(with: Data("SQLite format 3\0".utf8)) else { throw ArchiveError.databaseDecryptionFailed }
    }

    private func restrictSQLiteArtifacts(at databaseURL: URL, using manager: FileManager) throws {
        for artifact in SQLiteSidecar.allArtifacts(for: databaseURL) where manager.fileExists(atPath: artifact.path()) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifact.path())
        }
    }

    private func removeExportArtifacts(at destination: URL) {
        removeSQLiteArtifacts(for: destination)
    }
}

private final class SQLCipherConnection {
    private let api: SQLCipherAPI
    private var handle: OpaquePointer?

    init(api: SQLCipherAPI, databaseURL: URL, mode: SQLCipherOpenMode) throws {
        self.api = api
        var database: OpaquePointer?
        let status = databaseURL.path().withCString { path in
            api.open(path, &database, mode.flags | SQLCipherAPI.openFullMutex, nil)
        }
        guard status == SQLCipherAPI.ok, let database else { throw ArchiveError.databaseDecryptionFailed }
        handle = database
    }

    func apply(key: WeChatDatabaseKey, configuration: SQLCipherConfiguration) throws {
        guard handle != nil else { throw ArchiveError.databaseDecryptionFailed }
        try key.withSQLCipherHex { hex in
            // `hex` is generated from validated bytes, so it cannot alter SQL
            // syntax. It is never passed to a process, file, or logger.
            try execute("PRAGMA key = \"x'\(hex)'\"")
        }
        for statement in try configuration.validatedStatements() {
            try execute(statement)
        }
    }

    func verifyKey() throws {
        try execute("SELECT count(*) FROM sqlite_master")
    }

    func exportPlaintext(to destination: URL) throws {
        let escapedPath = destination.path().replacingOccurrences(of: "'", with: "''")
        try execute("ATTACH DATABASE '\(escapedPath)' AS plaintext KEY ''")
        do {
            try execute("SELECT sqlcipher_export('plaintext')")
            try execute("DETACH DATABASE plaintext")
        } catch {
            _ = try? execute("DETACH DATABASE plaintext")
            throw error
        }
    }

    func close() {
        if let handle {
            _ = api.close(handle)
            self.handle = nil
        }
    }

    private func execute(_ sql: String) throws {
        guard let handle else { throw ArchiveError.databaseDecryptionFailed }
        let result = sql.withCString { pointer in api.exec(handle, pointer, nil, nil, nil) }
        guard result == SQLCipherAPI.ok else { throw ArchiveError.databaseDecryptionFailed }
    }

}

private enum SQLCipherOpenMode {
    case readOnly
    case readWriteSnapshot

    var flags: Int32 {
        switch self {
        case .readOnly: SQLCipherAPI.openReadOnly
        case .readWriteSnapshot: SQLCipherAPI.openReadWrite | SQLCipherAPI.openCreate
        }
    }
}

private final class SQLCipherAPI: @unchecked Sendable {
    typealias ExecCallback = @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    typealias Open = @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?
    ) -> Int32
    typealias Close = @convention(c) (OpaquePointer?) -> Int32
    typealias Exec = @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, ExecCallback?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    static let ok: Int32 = 0
    static let openReadOnly: Int32 = 0x00000001
    static let openReadWrite: Int32 = 0x00000002
    static let openCreate: Int32 = 0x00000004
    static let openFullMutex: Int32 = 0x00010000

    let handle: UnsafeMutableRawPointer
    let open: Open
    let close: Close
    let exec: Exec

    init(libraryURL: URL?) throws {
        let url = try libraryURL ?? Self.defaultLibraryURL()
        guard let handle = dlopen(url.path(), RTLD_NOW | RTLD_LOCAL) else { throw ArchiveError.decryptionRuntimeUnavailable }
        do {
            self.handle = handle
            open = try Self.load("sqlite3_open_v2", from: handle, as: Open.self)
            close = try Self.load("sqlite3_close", from: handle, as: Close.self)
            exec = try Self.load("sqlite3_exec", from: handle, as: Exec.self)
        } catch {
            dlclose(handle)
            throw ArchiveError.decryptionRuntimeUnavailable
        }
    }

    deinit { dlclose(handle) }

    private static func defaultLibraryURL() throws -> URL {
        let candidates = [
            "/opt/homebrew/opt/sqlcipher/lib/libsqlcipher.dylib",
            "/usr/local/opt/sqlcipher/lib/libsqlcipher.dylib",
            "/opt/homebrew/lib/libsqlcipher.dylib",
            "/usr/local/lib/libsqlcipher.dylib"
        ].map(URL.init(fileURLWithPath:))
        guard let match = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path()) }) else {
            throw ArchiveError.decryptionRuntimeUnavailable
        }
        return match
    }

    private static func load<T>(_ symbol: String, from handle: UnsafeMutableRawPointer, as type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, symbol) else { throw ArchiveError.decryptionRuntimeUnavailable }
        return unsafeBitCast(pointer, to: type)
    }
}
