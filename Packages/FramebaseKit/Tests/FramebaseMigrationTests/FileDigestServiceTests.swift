import Foundation
import FramebaseMigration
import Testing

@Suite("File digest service", .serialized)
struct FileDigestServiceTests {
    @Test("Digesting a fixture file returns its SHA-256 and byte count")
    func digestsFixtureBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "FramebaseDigest-\(UUID().uuidString).jpg", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("fixture-bytes".utf8).write(to: url)

        let result = try await FileDigestService().digest(at: url)

        #expect(result.sha256 == "c16a40a4584e5bccc84b45172fcdfa922f59ff1edebf3adba7b8266ea04eb39a")
        #expect(result.byteSize == 13)
    }
}
