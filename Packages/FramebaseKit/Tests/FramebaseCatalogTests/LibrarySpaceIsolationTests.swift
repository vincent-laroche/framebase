import Foundation
import FramebaseDomain
import Testing
@testable import FramebaseCatalog

@Suite("Library space isolation")
struct LibrarySpaceIsolationTests {
    @Test("Three catalogs isolate nested folders, albums, and tags")
    func threeCatalogsStayIsolated() async throws {
        let personal = try TemporaryCatalog()
        let hairSolutions = try TemporaryCatalog()
        let screenshots = try TemporaryCatalog()
        try await personal.database.assignLibrarySpace(.personal)
        try await hairSolutions.database.assignLibrarySpace(.hairSolutions)
        try await screenshots.database.assignLibrarySpace(.screenshots)

        let identities = [
            personal.database.catalogID,
            hairSolutions.database.catalogID,
            screenshots.database.catalogID
        ]
        #expect(Set(identities).count == 3)
        #expect(Set([
            personal.database.inboxID,
            hairSolutions.database.inboxID,
            screenshots.database.inboxID
        ]).count == 3)

        let personalReceipt = try await personal.database.applyLibraryTemplate(for: .personal)
        let hairReceipt = try await hairSolutions.database.applyLibraryTemplate(for: .hairSolutions)
        let screenshotReceipt = try await screenshots.database.applyLibraryTemplate(for: .screenshots)
        #expect(!personalReceipt.createdFolderIDs.isEmpty)
        #expect(!hairReceipt.createdTagIDs.isEmpty)
        #expect(!screenshotReceipt.createdFolderIDs.isEmpty)

        let repeated = try await personal.database.applyLibraryTemplate(for: .personal)
        #expect(repeated.createdFolderIDs.isEmpty)
        #expect(repeated.createdTagIDs.isEmpty)

        let personalTree = try await personal.database.folders.treeSnapshot()
        let family = try #require(personalTree.folders.first { $0.name.rawValue == "family" })
        let people = try #require(personalTree.folders.first { $0.name.rawValue == "people" })
        #expect(family.parentFolderID == people.id)
        #expect(personalTree.childrenByParent[people.id]?.contains(family.id) == true)
        #expect(personalTree.folders.contains { $0.id == personal.database.inboxID })
        #expect(!personalTree.folders.contains { $0.name.rawValue == "01_products" || $0.name.rawValue == "desktop" })

        let hairTree = try await hairSolutions.database.folders.treeSnapshot()
        let thinSkin = try #require(hairTree.folders.first { $0.name.rawValue == "thin-skin-pro" })
        let raw = try #require(hairTree.folders.first { $0.name.rawValue == "raw" && $0.parentFolderID == thinSkin.id })
        #expect(raw.parentFolderID == thinSkin.id)
        #expect(!hairTree.folders.contains { $0.name.rawValue == "family" || $0.name.rawValue == "desktop" })

        let screenshotTree = try await screenshots.database.folders.treeSnapshot()
        let desktop = try #require(screenshotTree.folders.first { $0.name.rawValue == "desktop" })
        let screenshotFolder = try #require(screenshotTree.folders.first { $0.name.rawValue == "screenshots" })
        #expect(desktop.parentFolderID == screenshotFolder.id)
        #expect(!screenshotTree.folders.contains { $0.name.rawValue == "family" || $0.name.rawValue == "thin-skin-pro" })

        let asset = try makeAsset(parentFolderID: family.id, filename: "kept.jpg")
        try await personal.database.insertAssets([asset])
        let album = try await personal.database.albums.createAlbum(named: "Spring")
        try await personal.database.albums.addAssets([asset.id], to: album.id)
        let keep = try #require(try await personal.database.tags.tags().first { $0.name.rawValue == "status:keep" })
        try await personal.database.tags.addTags([keep.id], to: [asset.id])

        let stored = try #require(try await personal.database.assets.asset(id: asset.id))
        #expect(stored.parentFolderID == family.id)
        #expect(stored.storageKey == asset.storageKey)
        #expect(try await personal.database.assets.orderedIDs(
            matching: AssetQuery(scope: .album(album.id)),
            sortedBy: .defaultSort
        ) == [asset.id])
        #expect(try await personal.database.tags.tags(for: [asset.id])[asset.id]?.map(\.name.rawValue) == ["status:keep"])

        let review = try #require(try await personal.database.tags.tags().first { $0.name.rawValue == "status:review" })
        try await personal.database.tags.addTags([review.id], to: [asset.id])
        let afterReview = try #require(try await personal.database.assets.asset(id: asset.id))
        #expect(afterReview.parentFolderID == family.id)
        #expect(try await personal.database.tags.tags(for: [asset.id])[asset.id]?.map(\.name.rawValue) == ["status:review"])
        #expect(try await personal.database.albums.albums(containing: [asset.id])[asset.id]?.map(\.id) == [album.id])

        try await personal.database.tags.addTags([keep.id], to: [asset.id])
        #expect(try await personal.database.assets.asset(id: asset.id)?.parentFolderID == family.id)
        #expect(try await personal.database.tags.tags(for: [asset.id])[asset.id]?.map(\.name.rawValue) == ["status:keep"])

        let hairAsset = try makeAsset(parentFolderID: thinSkin.id, filename: "gallery.jpg")
        try await hairSolutions.database.insertAssets([hairAsset])
        let noiseAsset = try makeAsset(parentFolderID: desktop.id, filename: "menu.png")
        try await screenshots.database.insertAssets([noiseAsset])
        let noiseAlbum = try await screenshots.database.albums.createAlbum(named: "UI passes")
        try await screenshots.database.albums.addAssets([noiseAsset.id], to: noiseAlbum.id)
        let noiseTag = try await screenshots.database.tags.createTag(named: TagName("app:framebase"))
        try await screenshots.database.tags.addTags([noiseTag.id], to: [noiseAsset.id])
        #expect(try await screenshots.database.assets.asset(id: noiseAsset.id)?.parentFolderID == desktop.id)

        for foreign in [hairSolutions.database, screenshots.database] {
            #expect(try await foreign.assets.asset(id: asset.id) == nil)
            #expect(try await foreign.albums.albums().contains { $0.id == album.id } == false)
            #expect(try await foreign.tags.tags().contains { $0.id == keep.id } == false)
            #expect(try await foreign.folders.treeSnapshot().folders.contains { $0.id == family.id } == false)
        }
        #expect(try await personal.database.assets.asset(id: hairAsset.id) == nil)
        #expect(try await personal.database.assets.asset(id: noiseAsset.id) == nil)
        #expect(try await hairSolutions.database.assets.asset(id: noiseAsset.id) == nil)
        #expect(try await hairSolutions.database.albums.albums().contains { $0.id == noiseAlbum.id } == false)
        #expect(try await personal.database.tags.tags().contains { $0.id == noiseTag.id } == false)

        await expectCatalogFailure {
            try await personal.database.assignLibrarySpace(.screenshots)
        }
        await expectCatalogFailure {
            try await personal.database.applyLibraryTemplate(for: .hairSolutions)
        }
        await expectCatalogFailure {
            try await screenshots.database.applyLibraryTemplate(for: .personal)
        }
        await expectCatalogFailure {
            _ = try await hairSolutions.database.tags.createTag(named: TagName("status:keep"))
        }
        await expectCatalogFailure {
            _ = try await personal.database.tags.createTag(named: TagName("status:approved"))
        }
        await expectCatalogFailure {
            _ = try await personal.database.tags.createTag(named: TagName("source:browser"))
        }
        let browser = try #require(try await screenshots.database.tags.tags().first { $0.name.rawValue == "source:browser" })
        try await screenshots.database.tags.addTags([browser.id], to: [noiseAsset.id])
        #expect(try await screenshots.database.assets.asset(id: noiseAsset.id)?.parentFolderID == desktop.id)

        let reopened = try CatalogDatabase(catalogURL: screenshots.databaseURL)
        #expect(try await reopened.librarySpace() == .screenshots)
        #expect(try await reopened.assets.asset(id: noiseAsset.id)?.parentFolderID == desktop.id)
        #expect(try await reopened.assets.asset(id: asset.id) == nil)
    }
}

private func expectCatalogFailure(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected the library-space boundary to fail closed")
    } catch {
        #expect(error is CatalogError || error is DomainValidationError)
    }
}
