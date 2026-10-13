import Foundation

/// Automation must never report a partial or unvalidated export as complete.
/// Missing databases can be allowed by exact relative path, never by a wildcard.
public struct DatabaseExportCoveragePolicy: Sendable {
    public let allowedMissing: Set<String>

    public init(allowedMissing: Set<String> = []) {
        self.allowedMissing = allowedMissing
    }

    public func check(_ databases: [ScannedWeChatDatabase]) throws {
        guard !databases.isEmpty else { throw ArchiveError.invalidInput }
        for database in databases {
            switch database.validationStatus {
            case .valid: continue
            case .missingKey:
                guard allowedMissing.contains(database.relativePath) else { throw ArchiveError.keyUnavailable }
            case .invalid, .notValidated: throw ArchiveError.keyInvalid
            }
        }
        guard databases.contains(where: { $0.validationStatus == .valid }) else {
            throw ArchiveError.keyUnavailable
        }
    }
}
