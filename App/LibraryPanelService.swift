import AppKit
import UniformTypeIdentifiers

@MainActor
enum LibraryPanelService {
#if DEBUG
    static let uiTestImportSourcesKey = "FRAMEBASE_UI_TEST_IMPORT_SOURCES"
#endif

    static func chooseExistingLibrary() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Framebase Library"
        panel.message = "Choose an existing .framebase library package."
        panel.prompt = "Open Library"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true

        guard panel.runModal() == .OK,
              let selectedURL = panel.url,
              selectedURL.pathExtension.lowercased() == LibraryPackageLayout.packageExtension else {
            return nil
        }

        return selectedURL
    }

    static func chooseImagesForImport() -> [URL] {
#if DEBUG
        // A modal open panel cannot be driven from a UI test, so tests supply
        // the selection directly and everything downstream stays real.
        if let sources = ProcessInfo.processInfo.environment[uiTestImportSourcesKey] {
            return sources
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0), isDirectory: false) }
        }
#endif

        let panel = NSOpenPanel()
        panel.title = "Import Images"
        panel.message = "Choose still images to copy into your Framebase library."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
