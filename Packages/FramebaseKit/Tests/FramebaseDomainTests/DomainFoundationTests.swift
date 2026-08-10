import Foundation
import FramebaseDomain
import FramebaseTestSupport
import Testing

@Suite("Domain foundation")
struct DomainFoundationTests {
    @Test("Identifiers serialize as stable UUID-backed values")
    func identifierRoundTrip() throws {
        let id = AssetID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(AssetID.self, from: data)

        #expect(decoded == id)
        #expect(id.description == "12345678-1234-1234-1234-1234567890ab")
    }

    @Test("Folder names are trimmed and constrained")
    func folderNameValidation() throws {
        #expect(try FolderName("  Client Work  ").rawValue == "Client Work")
        #expect(throws: DomainValidationError.emptyFolderName) {
            try FolderName("   ")
        }
        #expect(throws: DomainValidationError.invalidFolderNameCharacter) {
            try FolderName("Client/Work")
        }
    }

    @Test("Ratings remain in the zero through five range")
    func ratingValidation() throws {
        #expect(try AssetRating(5).rawValue == 5)
        #expect(throws: DomainValidationError.ratingOutOfRange) {
            try AssetRating(6)
        }
    }

    @Test("Fixture assets use relative immutable storage keys")
    func fixtureStorageKey() throws {
        let asset = try FixtureFactory.asset()

        #expect(!asset.storageKey.rawValue.hasPrefix("/"))
        #expect(asset.localURL == nil)
    }

    @Test("Hair Solutions taxonomy keeps review state in tags and avoids empty on-demand folders")
    func hairSolutionsTaxonomy() {
        #expect(HairSolutionsLibraryTemplate.folders.contains {
            $0.path == ["00_inbox"] && $0.provisioning == .initial
        })
        #expect(HairSolutionsLibraryTemplate.folders.contains {
            $0.path == ["04_lifestyle", "active"] && $0.provisioning == .onFirstUse
        })
        let status = HairSolutionsLibraryTemplate.tagNamespaces.first { $0.namespace == "status" }
        #expect(status?.allowedValues.contains("review") == true)
        #expect(status?.allowsMultipleValuesPerAsset == false)
        #expect(HairSolutionsLibraryTemplate.tagNamespaces.contains { $0.namespace == "product" && $0.allowsCustomValues })
    }
}
