import AppKit
import FramebaseDomain
import FramebaseMedia
import SwiftUI

struct FramebaseSettingsView: View {
    let container: AppContainer

    @AppStorage("cache.diskLimitGB") private var diskLimitGB = 5.0
    @AppStorage("browser.thumbnailSize") private var thumbnailSize = 176.0
    @State private var isClearingCache = false
    @State private var pairingCredential = ""
    @State private var isPreparingCloud = false
    @State private var isUploadingCloud = false
    @State private var resolvingConflictID: UUID?
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
                    LabeledContent("Network", value: "Local unless cloud backing is explicitly enabled")
                    LabeledContent("Original storage", value: "Managed locally")
                    LabeledContent("Permanent deletion", value: "Not implemented")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Form {
                Section("Cloud backing") {
                    LabeledContent("Mode", value: cloudModeDescription)
                    LabeledContent("Pending changes", value: container.cloudStatus.pendingOutboxCount.formatted())
                    LabeledContent("Unresolved conflicts", value: container.cloudStatus.unresolvedConflictCount.formatted())

                    SecureField("One-time pairing credential", text: $pairingCredential)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Prepare Migration Manifest") {
                            prepareCloudMigration()
                        }
                        .disabled(isPreparingCloud || !container.canBrowseLibrary || pairingCredential.isEmpty)

                        if isPreparingCloud {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack {
                        Button("Upload Prepared Originals") {
                            uploadPreparedCloudBlobs()
                        }
                        .disabled(isUploadingCloud || container.cloudSync == nil)

                        if isUploadingCloud {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                Section("Safety") {
                    Text("Preparing cloud backing snapshots the local catalog and hashes managed originals. It does not delete, move, or replace any local original. The pairing credential is used once in memory and is never saved by Framebase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !container.cloudConflicts.isEmpty {
                    Section("Conflicts requiring review") {
                        ForEach(container.cloudConflicts) { conflict in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(conflict.entityType.capitalized) \(conflict.entityID)")
                                    .font(.subheadline.weight(.medium))
                                Text("Detected \(conflict.detectedAt.formatted(date: .abbreviated, time: .shortened)). Framebase retained the queued local version and the remote rejection context; it will not choose a resolution automatically.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Keep Local") { resolve(conflict, as: .keptLocal) }
                                    Button("Keep Remote") { resolve(conflict, as: .keptRemote) }
                                }
                                .disabled(resolvingConflictID != nil)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Cloud", systemImage: "icloud")
            }
        }
        .frame(width: 560, height: 460)
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

    private func prepareCloudMigration() {
        isPreparingCloud = true
        let credential = pairingCredential
        Task {
            defer {
                pairingCredential = ""
                isPreparingCloud = false
            }
            do {
                try await container.prepareCloudMigration(pairingCredential: credential)
                message = "The local migration manifest is ready. Your originals remain managed locally until every remote verification succeeds."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func uploadPreparedCloudBlobs() {
        isUploadingCloud = true
        Task {
            defer { isUploadingCloud = false }
            do {
                try await container.uploadPreparedCloudBlobs()
                message = "Prepared originals were uploaded and verified. Local originals remain unchanged."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func resolve(_ conflict: SyncConflict, as resolution: SyncConflictResolutionState) {
        resolvingConflictID = conflict.id
        Task {
            defer { resolvingConflictID = nil }
            do {
                try await container.resolveCloudConflict(conflict, as: resolution)
                message = resolution == .keptLocal
                    ? "The local edit was rebased on the latest cloud revision."
                    : "The remote version replaced the stale local replica."
            } catch {
                message = error.localizedDescription
            }
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

    private var cloudModeDescription: String {
        switch container.cloudStatus.mode {
        case .localOnly: "Local only"
        case .preparingMigration: "Preparing migration"
        case .syncing: "Syncing"
        case .cloudBacked: "Cloud backed"
        case .paused: "Paused"
        case .failed: "Needs attention"
        }
    }
}
