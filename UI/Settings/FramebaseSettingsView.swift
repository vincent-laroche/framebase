import FramebaseMedia
import SwiftUI

struct FramebaseSettingsView: View {
    let container: AppContainer

    @AppStorage("cache.diskLimitGB") private var diskLimitGB = 5.0
    @AppStorage("browser.thumbnailSize") private var thumbnailSize = 176.0

    var body: some View {
        TabView {
            Form {
                Section("Browser") {
                    LabeledContent("Default thumbnail size") {
                        Slider(value: $thumbnailSize, in: 96...280, step: 8)
                            .frame(width: 220)
                    }
                }

                Section("Derived cache") {
                    LabeledContent("Disk limit") {
                        HStack {
                            Slider(value: $diskLimitGB, in: 1...20, step: 1)
                                .frame(width: 180)
                            Text("\(diskLimitGB, specifier: "%.0f") GB")
                                .frame(width: 48, alignment: .trailing)
                        }
                    }

                    Button("Clear Derived Cache") {}
                        .disabled(true)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            Form {
                Section("Library") {
                    LabeledContent("State", value: libraryStateDescription)
                    LabeledContent("Catalog schema", value: container.catalogSchemaVersion.formatted())
                    LabeledContent(
                        "Default memory cache",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(FramebaseMediaFoundation.defaultMemoryCacheBytes),
                            countStyle: .memory
                        )
                    )
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        }
        .frame(width: 520, height: 340)
        .scenePadding()
    }

    private var libraryStateDescription: String {
        switch container.libraryState {
        case .notConfigured: "Not configured"
        case .opening: "Opening"
        case .ready: "Ready"
        case .failed: "Unavailable"
        }
    }
}
