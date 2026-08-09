import Foundation

public enum FixtureMigrationAuthorizationError: Error, Equatable, Sendable {
    case nonFixtureRoot(URL)
}

/// A capability issued only to deterministic migration fixtures. This is a
/// deliberate hard boundary: the Phase 3.1 coordinator cannot be pointed at
/// the user's library by swapping a URL argument.
public struct FixtureMigrationAuthorization: Sendable {
    public static let fixtureLibraryDirectoryName = "Framebase Fixture Library.framebase"

    public let rootURL: URL

    private init(rootURL: URL) { self.rootURL = rootURL }

    public static func fixtureOnly(rootURL: URL) throws -> FixtureMigrationAuthorization {
        let normalized = rootURL.standardizedFileURL
        guard normalized.lastPathComponent == fixtureLibraryDirectoryName else {
            throw FixtureMigrationAuthorizationError.nonFixtureRoot(normalized)
        }
        return FixtureMigrationAuthorization(rootURL: normalized)
    }
}
