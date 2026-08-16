import Foundation
#if canImport(Security)
import Security
#endif

/// Sensitive key material intentionally has no textual description. Providers
/// return it only to the explicit import flow, which should release it when the
/// decryptor finishes.
public struct WeChatDatabaseKey: Sendable {
    private var bytes: Data

    public init(hex: String) throws {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2), !normalized.isEmpty else { throw ArchiveError.keyInvalid }
        var data = Data()
        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let next = normalized.index(cursor, offsetBy: 2)
            guard let value = UInt8(normalized[cursor..<next], radix: 16) else { throw ArchiveError.keyInvalid }
            data.append(value)
            cursor = next
        }
        bytes = data
    }

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= 128 else { throw ArchiveError.keyInvalid }
        bytes = data
    }

    /// Keep material scoped to the decryptor invocation; no provider logs,
    /// persists, or exposes a printable representation of this value.
    func withData<T>(_ work: (Data) throws -> T) rethrows -> T {
        try work(bytes)
    }

    /// SQLCipher's documented raw-key syntax is a hexadecimal blob literal.
    /// This value is derived transiently from in-memory bytes and is never
    /// persisted, logged, sent to a subprocess, or exposed publicly.
    func withSQLCipherHex<T>(_ work: (String) throws -> T) rethrows -> T {
        try work(bytes.map { String(format: "%02x", $0) }.joined())
    }
}

public protocol WeChatKeyProvider: Sendable {
    func key(for databaseURL: URL) async throws -> WeChatDatabaseKey
}

public actor ManualKeyProvider: WeChatKeyProvider {
    private var pendingKey: WeChatDatabaseKey?

    public init(hex: String) throws {
        pendingKey = try WeChatDatabaseKey(hex: hex)
    }

    public func key(for databaseURL: URL) async throws -> WeChatDatabaseKey {
        guard let key = pendingKey else { throw ArchiveError.keyUnavailable }
        pendingKey = nil
        return key
    }
}

public struct LocalKeyFileProvider: WeChatKeyProvider {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func key(for databaseURL: URL) async throws -> WeChatDatabaseKey {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_024 else { throw ArchiveError.keyInvalid }
        guard let input = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw ArchiveError.keyInvalid }
        return try WeChatDatabaseKey(hex: input)
    }
}

public struct EnvironmentKeyProvider: WeChatKeyProvider {
    public let variableName: String

    public init(variableName: String = "WECHAT_DATABASE_KEY") {
        self.variableName = variableName
    }

    public func key(for databaseURL: URL) async throws -> WeChatDatabaseKey {
        guard let value = ProcessInfo.processInfo.environment[variableName], !value.isEmpty else {
            throw ArchiveError.keyUnavailable
        }
        return try WeChatDatabaseKey(hex: value)
    }
}

#if canImport(Security)
public struct KeychainKeyProvider: WeChatKeyProvider {
    public let account: String
    private let service = "com.wechatarchive.database-key"

    public init(account: String) {
        self.account = account
    }

    public func key(for databaseURL: URL) async throws -> WeChatDatabaseKey {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw ArchiveError.keyUnavailable }
        return try WeChatDatabaseKey(data: data)
    }
}
#else
public struct KeychainKeyProvider: WeChatKeyProvider {
    public init(account: String) {}
    public func key(for databaseURL: URL) async throws -> WeChatDatabaseKey { throw ArchiveError.keyUnavailable }
}
#endif

public protocol WeChatDatabaseDecryptor: Sendable {
    func validate(databaseURL: URL, key: WeChatDatabaseKey) throws
    func decrypt(databaseURL: URL, key: WeChatDatabaseKey, into workingDirectory: URL) throws -> URL
}

/// This dependency-free build deliberately does not claim SQLCipher support it
/// cannot provide. Applications can inject an audited SQLCipher decryptor while
/// retaining the same local-only key and snapshot boundaries.
public struct UnavailableSQLCipherDecryptor: WeChatDatabaseDecryptor {
    public init() {}

    public func validate(databaseURL: URL, key: WeChatDatabaseKey) throws {
        throw ArchiveError.databaseDecryptionFailed
    }

    public func decrypt(databaseURL: URL, key: WeChatDatabaseKey, into workingDirectory: URL) throws -> URL {
        throw ArchiveError.databaseDecryptionFailed
    }
}
