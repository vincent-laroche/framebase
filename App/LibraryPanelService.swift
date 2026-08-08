import AppKit
import UniformTypeIdentifiers

@MainActor
enum LibraryPanelService {
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
