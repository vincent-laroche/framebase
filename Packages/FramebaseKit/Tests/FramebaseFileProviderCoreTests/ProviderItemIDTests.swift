import Foundation
import FramebaseDomain
import FramebaseFileProviderCore
import Testing

@Suite("File Provider item identifiers")
struct ProviderItemIDTests {
    @Test("Asset identifiers round trip without using a filename")
    func assetIdentifierRoundTrip() throws {
        let assetID = AssetID(rawValue: UUID(uuidString: "A2181953-AE87-4AA3-9E9A-4D91647A0A31")!)
        let identifier = ProviderItemID.asset(assetID)

        #expect(try ProviderItemID.parse(identifier.rawValue) == identifier)
        #expect(!identifier.rawValue.contains("summer-photo"))
    }

    @Test("Malformed identifiers are rejected")
    func malformedIdentifierIsRejected() {
        #expect(throws: ProviderItemIDError.self) {
            try ProviderItemID.parse("fb://v1/asset/not-a-uuid")
        }
    }

    @Test("Root and Trash identifiers stay scoped to one catalog")
    func catalogScopedRootsAndTrash() throws {
        let catalogID = CatalogID(rawValue: UUID(uuidString: "305EE1F5-6D83-4B1F-83CD-CFD250D1A9DE")!)

        #expect(try ProviderItemID.parse(ProviderItemID.root(catalogID).rawValue) == .root(catalogID))
        #expect(try ProviderItemID.parse(ProviderItemID.trash(catalogID).rawValue) == .trash(catalogID))
    }
}
