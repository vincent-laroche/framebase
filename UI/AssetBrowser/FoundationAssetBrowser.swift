import SwiftUI

struct FoundationAssetBrowser: View {
    let model: LibraryWindowModel

    var body: some View {
        ContentUnavailableView {
            Label(model.navigationTarget.title, systemImage: "photo.stack")
        } description: {
            Text(description)
        }
        .navigationTitle(model.navigationTarget.title)
    }

    private var description: String {
        switch model.container.libraryState {
        case .notConfigured:
            "The native foundation is ready. Library creation begins in Milestone 1."
        case .opening:
            "Opening the managed Framebase library…"
        case .ready:
            "No assets match this destination."
        case let .failed(message):
            message
        }
    }
}
