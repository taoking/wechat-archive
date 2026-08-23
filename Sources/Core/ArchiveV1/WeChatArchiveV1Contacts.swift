import Foundation
import SQLite3

private let archiveV1ContactSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Contact and group records read from a plaintext export. Their values are
/// private archive data and are never rendered by diagnostics or reports.
struct ArchiveV1ContactRecord: Sendable {
    let sourceIdentity: String
    let alias: String?
    let remark: String?
    let nickname: String?
    let displayName: String
    let contactType: String?
    let numericID: Int64
    let avatarSmallURL: String?
    let avatarLargeURL: String?

    var isGroup: Bool { sourceIdentity.lowercased().hasSuffix("@chatroom") }
}

struct ArchiveV1GroupMemberRecord: Sendable {
    let groupSourceIdentity: String
    let memberSourceIdentity: String
    let groupNickname: String?
    let displayName: String
}

struct ArchiveV1ContactImport: Sendable {
    let contacts: [ArchiveV1ContactRecord]
    let groupMembers: [ArchiveV1GroupMemberRecord]
    let ownerSourceIdentity: String?

    var groupContacts: [ArchiveV1ContactRecord] { contacts.filter(\.isGroup) }
}

/// Reads only the locally observed `contact` and chatroom-member schemas.
/// Missing contact metadata is non-fatal: messages remain losslessly imported
/// with anonymous viewer fallbacks.
struct WeChatContactAdapter: Sendable {
    func read(plainSQLiteRoot: URL, accountRoot: URL) throws -> ArchiveV1ContactImport {
        guard let contactURL = contactDatabaseURL(below: plainSQLiteRoot) else {
            return .init(contacts: [], groupMembers: [], ownerSourceIdentity: nil)
        }
        let database = try ContactSourceDatabase(url: contactURL)
        guard try database.hasObservedSchema else {
            return .init(contacts: [], groupMembers: [], ownerSourceIdentity: nil)
        }
        let contacts = try database.contacts()
        // The observed database has unique contact ids. Preserve a valid
        // import if a future database contains a duplicate rather than
        // trapping in `Dictionary(uniqueKeysWithValues:)`.
        var contactsByNumericID = [Int64: ArchiveV1ContactRecord]()
        for contact in contacts { contactsByNumericID[contact.numericID] = contact }
        let nicknames = try groupNicknames(below: plainSQLiteRoot)
        let members = try database.groupMemberships().compactMap { groupID, memberID -> ArchiveV1GroupMemberRecord? in
            guard let group = contactsByNumericID[groupID], group.isGroup,
                  let member = contactsByNumericID[memberID] else { return nil }
            let groupNickname = nicknames[GroupMemberKey(groupID: groupID, memberID: memberID)]
            return .init(
                groupSourceIdentity: group.sourceIdentity,
                memberSourceIdentity: member.sourceIdentity,
                groupNickname: groupNickname,
                displayName: groupNickname ?? member.displayName
            )
        }
        let owner = accountSourceIdentity(accountRoot: accountRoot, contacts: contacts)
        return .init(contacts: contacts, groupMembers: members, ownerSourceIdentity: owner)
    }

    private func contactDatabaseURL(below root: URL) -> URL? {
        safeDatabase(relativePath: "contact/contact.db", below: root)
    }

    private func groupNicknames(below root: URL) throws -> [GroupMemberKey: String] {
        guard let ftsURL = safeDatabase(relativePath: "contact/contact_fts.db", below: root) else { return [:] }
        let database = try ContactSourceDatabase(url: ftsURL)
        return try database.groupNicknames()
    }

    private func safeDatabase(relativePath: String, below root: URL) -> URL? {
        let requestedRoot = root.standardizedFileURL
        guard let rootValues = try? requestedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else { return nil }
        let components = relativePath.split(separator: "/").map(String.init)
        let requested = components.reduce(requestedRoot) { $0.appending(path: $1) }.standardizedFileURL
        guard let values = try? requested.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        let resolvedRoot = requestedRoot.resolvingSymlinksInPath().standardizedFileURL.path()
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolved.path().hasPrefix(prefix), resolved.pathExtension.lowercased() == "db" else { return nil }
        return resolved
    }

    private func accountSourceIdentity(accountRoot: URL, contacts: [ArchiveV1ContactRecord]) -> String? {
        let root = accountRoot.standardizedFileURL
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return nil }
        let identity = root.lastPathComponent.replacingOccurrences(
            of: "_c[0-9a-fA-F]+$",
            with: "",
            options: .regularExpression
        )
        guard identity.range(of: "^wxid_[A-Za-z0-9]+$", options: .regularExpression) != nil else { return nil }
        return contacts.first(where: { $0.sourceIdentity == identity })?.sourceIdentity
    }
}

private struct GroupMemberKey: Hashable {
    let groupID: Int64
    let memberID: Int64
}

private final class ContactSourceDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path(), &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveError.databaseFailure
        }
        handle = database
    }

    deinit { if let handle { sqlite3_close(handle) } }

    var hasObservedSchema: Bool {
        get throws { try tableExists("contact") }
    }

    func contacts() throws -> [ArchiveV1ContactRecord] {
        let columns = try tableColumns("contact")
        let largeURL = columns.contains("big_head_url") ? "big_head_url" : "NULL"
        let smallURL = columns.contains("small_head_url") ? "small_head_url" : "NULL"
        let statement = try prepare("SELECT id, username, alias, remark, nick_name, local_type, \(largeURL), \(smallURL) FROM \"contact\" WHERE username IS NOT NULL AND username <> ''")
        defer { sqlite3_finalize(statement) }
        var values = [ArchiveV1ContactRecord]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sourceIdentity = text(statement, 1), !sourceIdentity.isEmpty else { continue }
            let alias = text(statement, 2)
            let remark = text(statement, 3)
            let nickname = text(statement, 4)
            values.append(.init(
                sourceIdentity: sourceIdentity,
                alias: alias,
                remark: remark,
                nickname: nickname,
                displayName: preferredDisplayName(remark: remark, nickname: nickname, alias: alias, sourceIdentity: sourceIdentity),
                contactType: columnType(statement, 5) == SQLITE_NULL ? nil : String(sqlite3_column_int64(statement, 5)),
                numericID: sqlite3_column_int64(statement, 0),
                avatarSmallURL: text(statement, 7),
                avatarLargeURL: text(statement, 6)
            ))
        }
        return values
    }

    func groupMemberships() throws -> [(Int64, Int64)] {
        guard try tableExists("chatroom_member") else { return [] }
        let statement = try prepare("SELECT room_id, member_id FROM \"chatroom_member\"")
        defer { sqlite3_finalize(statement) }
        var values = [(Int64, Int64)]()
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append((sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1)))
        }
        return values
    }

    func groupNicknames() throws -> [GroupMemberKey: String] {
        guard try tableExists("chatroom_member_fts_v3") else { return [:] }
        let statement = try prepare("SELECT room_id, member_id, a_group_remark FROM \"chatroom_member_fts_v3\" WHERE a_group_remark IS NOT NULL AND length(a_group_remark) > 0")
        defer { sqlite3_finalize(statement) }
        var values = [GroupMemberKey: String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nickname = text(statement, 2), !nickname.isEmpty else { continue }
            values[.init(groupID: sqlite3_column_int64(statement, 0), memberID: sqlite3_column_int64(statement, 1))] = nickname
        }
        return values
    }

    private func tableExists(_ tableName: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, tableName, -1, archiveV1ContactSQLiteTransient) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw ArchiveError.databaseFailure }
        return result == SQLITE_ROW
    }

    private func tableColumns(_ tableName: String) throws -> Set<String> {
        guard tableName == "contact" else { throw ArchiveError.invalidInput }
        let statement = try prepare("PRAGMA table_info(\"contact\")")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { columns.insert(name.lowercased()) }
        }
        return columns
    }

    private func preferredDisplayName(remark: String?, nickname: String?, alias: String?, sourceIdentity: String) -> String {
        [remark, nickname, alias].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }.first ?? shortSourceIdentity(sourceIdentity)
    }

    private func shortSourceIdentity(_ value: String) -> String {
        guard value.count > 12 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil) == SQLITE_OK else { throw ArchiveError.databaseFailure }
        return statement
    }

    private func requireHandle() -> OpaquePointer {
        guard let handle else { preconditionFailure("Contact source database is closed") }
        return handle
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func columnType(_ statement: OpaquePointer?, _ index: Int32) -> Int32 { sqlite3_column_type(statement, index) }
}
