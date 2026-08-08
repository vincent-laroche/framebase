import FramebaseCatalog
import GRDB
import Testing

@Suite("Catalog foundation")
struct CatalogFoundationTests {
    @Test("Catalog configuration enables foreign keys")
    func foreignKeysAreEnabled() {
        var configuration = Configuration()
        FramebaseCatalogFoundation.configure(&configuration)

        #expect(configuration.foreignKeysEnabled)
        #expect(FramebaseCatalogFoundation.initialSchemaVersion == 1)
    }
}
