import Foundation
import FramebaseDomain
import Testing

@Suite("Library spaces")
struct LibrarySpaceTests {
    @Test("Personal, Hair Solutions, and Screenshots are separate package scopes")
    func threePackageScopes() {
        #expect(Set(LibrarySpace.allCases.map(\.packageName)).count == 3)
        #expect(LibrarySpace.personal.packageName == "Personal Library.framebase")
        #expect(LibrarySpace.hairSolutions.packageName == "HSC Library.framebase")
        #expect(LibrarySpace.screenshots.packageName == "Screenshots Library.framebase")
        #expect(LibrarySpace.inferred(from: URL(fileURLWithPath: "/Users/vMac/Pictures/Framebase Library.framebase")) == nil)
        #expect(LibrarySpace.inferred(from: URL(fileURLWithPath: "/Users/vMac/Pictures/Screenshots Library.framebase")) == .screenshots)
    }

    @Test("Personal and Screenshots templates are nested and are not the Hair Solutions tree")
    func templatesStayInTheirSpaces() throws {
        let hairSolutions = folderPaths(HairSolutionsLibraryTemplate.folders)
        let personal = folderPaths(PersonalLibraryTemplate.folders)
        let screenshots = folderPaths(ScreenshotsLibraryTemplate.folders)

        #expect(hairSolutions.contains("00_inbox"))
        #expect(hairSolutions.contains("10_private/sensitive"))
        #expect(hairSolutions.contains("09_reference/ops-screenshots"))
        #expect(personal.isDisjoint(with: hairSolutions))
        #expect(screenshots.isDisjoint(with: hairSolutions))
        #expect(personal.isDisjoint(with: screenshots))
        #expect(personal.contains("people/family"))
        #expect(personal.contains("archive"))
        #expect(screenshots.contains("screenshots/desktop"))
        #expect(screenshots.contains("discard"))
        #expect(!personal.contains { $0.contains("screenshot") })

        assertParentsPrecedeChildren(PersonalLibraryTemplate.initialFolders)
        assertParentsPrecedeChildren(HairSolutionsLibraryTemplate.initialFolders)
        assertParentsPrecedeChildren(ScreenshotsLibraryTemplate.initialFolders)

        let personalTags = try PersonalLibraryTemplate.initialTagNames()
        let screenshotTags = try ScreenshotsLibraryTemplate.initialTagNames()
        #expect(personalTags.contains { $0.rawValue == "status:keep" })
        #expect(personalTags.contains { $0.rawValue == "status:duplicate" })
        #expect(!personalTags.contains { $0.rawValue == "status:approved" })
        #expect(!personalTags.contains { $0.namespace == "product" })
        #expect(screenshotTags.contains { $0.rawValue == "source:browser" })
        #expect(!screenshotTags.contains { $0.rawValue == "source:camera" })
        #expect(try HairSolutionsLibraryTemplate.initialTagNames().contains { $0.rawValue == "status:approved" })
        #expect(HairSolutionsLibraryTemplate.validates(try TagName("status:approved")))
        #expect(!PersonalLibraryTemplate.validates(try TagName("status:approved")))
        #expect(PersonalLibraryTemplate.validates(try TagName("person:someone")))
    }

    @Test("Registry migration, path checks, and catalog identity stay isolated")
    func registryIsolationRules() throws {
        let personalID = CatalogID()
        let hairSolutionsID = CatalogID()
        let screenshotsID = CatalogID()
        let legacy = LibraryRegistrationRules.legacyPersonalLibrary(
            catalogID: personalID,
            rootPath: "/Users/vMac/Pictures/Framebase Library.framebase"
        )
        #expect(legacy.space == .personal)
        #expect(legacy.displayName == "Personal Library")
        #expect(legacy.rootPath == "/Users/vMac/Pictures/Framebase Library.framebase")

        var libraries = try LibraryRegistrationRules.upsert(
            existing: [],
            catalogID: personalID,
            rootPath: legacy.rootPath,
            preferredSpace: nil
        )
        #expect(libraries.count == 1)
        #expect(libraries[0].catalogID == personalID)
        #expect(libraries[0].space == .personal)
        #expect(libraries[0].displayName == "Personal Library")
        #expect(libraries[0].rootPath.hasSuffix("Framebase Library.framebase"))
        #expect(!libraries[0].rootPath.contains("Personal Library.framebase"))

        libraries = try LibraryRegistrationRules.upsert(
            existing: libraries,
            catalogID: hairSolutionsID,
            rootPath: "/Users/vMac/Pictures/HSC Library.framebase",
            preferredSpace: .hairSolutions
        )
        libraries = try LibraryRegistrationRules.upsert(
            existing: libraries,
            catalogID: screenshotsID,
            rootPath: "/Users/vMac/Pictures/Screenshots Library.framebase",
            preferredSpace: .screenshots
        )
        #expect(Set(libraries.map(\.space)) == Set(LibrarySpace.allCases))
        #expect(Set(libraries.map(\.catalogID)).count == 3)
        #expect(Set(libraries.map(\.rootPath)).count == 3)

        let duplicated = try LibraryRegistrationRules.upsert(
            existing: libraries,
            catalogID: screenshotsID,
            rootPath: "/Users/vMac/Pictures/Screenshots Library.framebase",
            preferredSpace: .screenshots
        )
        #expect(duplicated.count == 3)

        let moved = try LibraryRegistrationRules.upsert(
            existing: libraries,
            catalogID: screenshotsID,
            rootPath: "/Users/vMac/Pictures/Moved Screenshots.framebase",
            preferredSpace: nil
        )
        #expect(moved.count == 3)
        #expect(moved.contains { $0.catalogID == screenshotsID && $0.space == .screenshots && $0.rootPath.hasSuffix("Moved Screenshots.framebase") })
        #expect(!moved.contains { $0.rootPath.hasSuffix("Screenshots Library.framebase") })

        #expect(throws: LibraryRegistrationError.catalogIDMismatch(expected: personalID, observed: screenshotsID)) {
            _ = try LibraryRegistrationRules.upsert(
                existing: libraries,
                catalogID: screenshotsID,
                rootPath: legacy.rootPath,
                preferredSpace: nil
            )
        }
        #expect(throws: LibraryRegistrationError.librarySpaceConflict(existing: .personal, requested: .screenshots)) {
            _ = try LibraryRegistrationRules.upsert(
                existing: libraries,
                catalogID: personalID,
                rootPath: legacy.rootPath,
                preferredSpace: .screenshots
            )
        }
        #expect(throws: LibraryRegistrationError.unavailableRoot("/missing/library.framebase")) {
            try LibraryRegistrationRules.requireAvailableRoot("/missing/library.framebase", isDirectory: false)
        }
        #expect(throws: LibraryRegistrationError.unavailableRoot("")) {
            try LibraryRegistrationRules.requireAvailableRoot("", isDirectory: true)
        }
    }

    private func folderPaths(_ folders: [LibraryFolderTemplate]) -> Set<String> {
        Set(folders.map { $0.path.joined(separator: "/") })
    }

    private func assertParentsPrecedeChildren(_ folders: [LibraryFolderTemplate]) {
        var seen: Set<String> = []
        for folder in folders where folder.provisioning == .initial {
            let path = folder.path.joined(separator: "/")
            let parent = folder.path.dropLast().joined(separator: "/")
            if !parent.isEmpty {
                #expect(seen.contains(parent))
            }
            seen.insert(path)
        }
    }
}
