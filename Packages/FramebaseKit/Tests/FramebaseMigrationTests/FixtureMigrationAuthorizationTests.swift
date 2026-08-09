import Foundation
import FramebaseMigration
import Testing

@Suite("Fixture migration authorization", .serialized)
struct FixtureMigrationAuthorizationTests {
    @Test("Fixture authorization rejects a non-fixture library root before inventory")
    func rejectsNonFixtureRoot() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "FramebaseMigrationAuthorization-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        #expect(throws: FixtureMigrationAuthorizationError.nonFixtureRoot(temporary)) {
            _ = try FixtureMigrationAuthorization.fixtureOnly(rootURL: temporary)
        }
    }
}
