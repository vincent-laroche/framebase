import SwiftUI

struct FoundationInspector: View {
    let model: LibraryWindowModel

    var body: some View {
        Form {
            Section("Selection") {
                LabeledContent("Assets", value: model.selectedAssetIDs.count.formatted())
            }

            Section("Foundation") {
                LabeledContent("Catalog schema", value: model.container.catalogSchemaVersion.formatted())
                LabeledContent(
                    "Thumbnail cache format",
                    value: model.container.thumbnailCacheFormatVersion.formatted()
                )
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
    }
}
