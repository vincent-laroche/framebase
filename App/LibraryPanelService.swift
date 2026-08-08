import AppKit

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
}
