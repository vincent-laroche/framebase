import SwiftUI

struct LibrarySetupView: View {
    let container: AppContainer

    var body: some View {
        ContentUnavailableView {
            Label("Set Up Framebase", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(description)
        } actions: {
            HStack {
                Button("Create Default Library") {
                    Task {
                        await container.createDefaultLibrary()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Open Existing…") {
                    guard let libraryURL = LibraryPanelService.chooseExistingLibrary() else {
                        return
                    }

                    Task {
                        await container.openLibrary(at: libraryURL)
                    }
                }
            }
        }
    }

    private var description: String {
        if case let .failed(message) = container.libraryState {
            return message
        }
        return "Create a managed library in Pictures, or reopen an existing .framebase package."
    }
}

