import AppKit
import FramebaseMedia
import SwiftUI

struct FramebaseSettingsView: View {
    let container: AppContainer

    @AppStorage("cache.diskLimitGB") private var diskLimitGB = 5.0
    @AppStorage("browser.thumbnailSize") private var thumbnailSize = 176.0
    @State private var isClearingCache = false
    @State private var message: String?

    var body: some View {
        TabView {
            Form {
                Section("Browser") {
                    LabeledContent("Default thumbnail size") {
                        HStack {
                            Slider(value: $thumbnailSize, in: 96...280, step: 8)
                                .frame(width: 200)
                            Text("\(thumbnailSize, specifier: "%.0f") pt")
                                .frame(width: 52, alignment: .trailing)
                        }
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

                    HStack {
                        Button("Clear Derived Cache") {
                            clearCache()
                        }
                        .disabled(isClearingCache || container.thumbnailProvider == nil)

                        if isClearingCache {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text("Original images and catalog records are never removed when this cache is cleared.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            Form {
                Section("Library") {
                    LabeledContent("State", value: libraryStateDescription)
                    if let rootURL = container.libraryRootURL {
                        LabeledContent("Location", value: rootURL.path)
                        Button("Reveal Library in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([rootURL])
                        }
                    }
                    LabeledContent("Catalog schema", value: container.catalogSchemaVersion.formatted())
                    LabeledContent(
                        "Thumbnail cache format",
                        value: container.thumbnailCacheFormatVersion.formatted()
                    )
                    LabeledContent(
                        "Memory cache limit",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(FramebaseMediaFoundation.defaultMemoryCacheBytes),
                            countStyle: .memory
                        )
                    )
                }

                Section("Scope") {
                    LabeledContent("Network", value: "Disabled")
                    LabeledContent("Original storage", value: "Managed locally")
                    LabeledContent("Permanent deletion", value: "Not implemented")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        }
        .frame(width: 560, height: 390)
        .scenePadding()
        .onChange(of: diskLimitGB) {
            do {
                try container.updateThumbnailDiskLimit(gigabytes: diskLimitGB)
            } catch {
                message = error.localizedDescription
            }
        }
        .alert("Framebase Settings", isPresented: messageBinding) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            do {
                try await container.clearDerivedCache()
                message = "The derived thumbnail and preview cache was cleared. Your originals are unchanged."
            } catch {
                message = error.localizedDescription
            }
            isClearingCache = false
        }
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
