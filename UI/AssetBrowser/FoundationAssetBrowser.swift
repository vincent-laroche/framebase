import SwiftUI

struct FoundationAssetBrowser: View {
    let model: LibraryWindowModel

    var body: some View {
        Group {
            switch model.container.libraryState {
            case .notConfigured, .failed:
                LibrarySetupView(container: model.container)
            case .opening:
                ProgressView("Opening Framebase Library…")
                    .controlSize(.large)
            case .ready:
                ContentUnavailableView {
                    Label(model.navigationTarget.title, systemImage: "photo.stack")
                } description: {
                    Text("No assets match this destination.")
                }
                .accessibilityIdentifier("assetBrowser.empty.\(model.navigationTarget.title)")
            }
        }
        .navigationTitle(model.navigationTarget.title)
    }
}
