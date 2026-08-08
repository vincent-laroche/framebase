import SwiftUI

@main
struct FramebaseApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup("Framebase", id: "library") {
            LibraryWindowView(container: container)
                .frame(minWidth: 1_100, minHeight: 700)
        }
        .defaultSize(width: 1_440, height: 900)
        .commands {
            FramebaseCommands()
        }

        Settings {
            FramebaseSettingsView(container: container)
        }
    }
}
