import FramebaseDomain
import FramebaseTestSupport
import Testing
@testable import FramebaseCatalog

@Suite("Album location lookup", .serialized)
struct AlbumLocationTests {
    @Test("Album membership lookup returns only the selected assets in stable album order")
    func selectedAssetAlbumLocations() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let first = try makeAsset(parentFolderID: database.inboxID, filename: "first.jpg")
        let second = try makeAsset(parentFolderID: database.inboxID, filename: "second.jpg")
        try await database.insertAssets([first, second])

        let campaign = try await database.albums.createAlbum(named: "Campaign")
        let selects = try await database.albums.createAlbum(named: "Selects")
        try await database.albums.addAssets([first.id], to: campaign.id)
        try await database.albums.addAssets([first.id, second.id], to: selects.id)

        let locations = try await database.albums.albums(containing: [first.id, second.id])
        #expect(locations[first.id]?.map(\.name) == [campaign.name, selects.name])
        #expect(locations[second.id]?.map(\.name) == [selects.name])
        #expect(try await database.albums.albums(containing: []).isEmpty)
    }
}
