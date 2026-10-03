import FramebaseDomain
import FramebaseTestSupport
import GRDB
import Testing
@testable import FramebaseCatalog

@Suite("Screenshot content identity")
struct ScreenshotContentIdentityTests {
    @Test("The same original bytes stay one asset across a reopen")
    func duplicateBytesDoNotInsertASecondAsset() async throws {
        let temporary = try TemporaryCatalog()
        let hash = String(repeating: "ab", count: 32)
        #expect(FramebaseCatalogFoundation.currentSchemaVersion == 14)
        let schemaVersion = try temporary.database.databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM catalog_settings WHERE key = 'schema_version'")
        }
        let migrationCount = try temporary.database.databasePool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                arguments: [FramebaseCatalogFoundation.contentIdentityMigrationIdentifier]
            )
        }
        #expect(schemaVersion == "14")
        #expect(migrationCount == 1)

        let first = try makeAsset(parentFolderID: temporary.database.inboxID, filename: "one.png")
        await #expect(throws: ScreenshotContentIdentityError.invalidContentSHA256) {
            try await temporary.database.insertScreenshot(first, contentSHA256: "not-a-hash")
        }
        try await temporary.database.insertScreenshot(first, contentSHA256: hash)

        let second = try makeAsset(parentFolderID: temporary.database.inboxID, filename: "two.png")
        await #expect(throws: ScreenshotContentIdentityError.duplicateContent) {
            try await temporary.database.insertScreenshot(second, contentSHA256: hash.uppercased())
        }

        #expect(try await temporary.database.assetID(forContentSHA256: hash) == first.id)
        #expect(try await temporary.database.assets.count(matching: AssetQuery(scope: .allAssets)) == 1)

        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)
        #expect(try await reopened.assetID(forContentSHA256: hash) == first.id)
        #expect(try await reopened.assets.count(matching: AssetQuery(scope: .allAssets)) == 1)
        #expect(try await reopened.assets.asset(id: second.id) == nil)
    }
}
