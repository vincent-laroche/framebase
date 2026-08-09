import AppKit
import FramebaseAPIClient
import FramebaseMedia
import SwiftUI

struct FramebaseSettingsView: View {
    let container: AppContainer

    @AppStorage("cache.diskLimitGB") private var diskLimitGB = 5.0
    @AppStorage("browser.thumbnailSize") private var thumbnailSize = 176.0
    @State private var isClearingCache = false
    @State private var message: String?
    @State private var enrollmentSecret = ""
    @State private var isEnrolling = false
    @State private var isCheckingHealth = false
    @State private var healthResult: String?
    @AppStorage("framebase.cloudSyncEnabled") private var cloudSyncEnabled = false

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
                    LabeledContent("Network", value: networkScopeDescription)
                    LabeledContent("Original storage", value: "Managed locally")
                    LabeledContent("Permanent deletion", value: "Not implemented")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Form {
                Section("Device Enrollment") {
                    LabeledContent("Status", value: enrollmentStatusDescription)

                    if !isEnrolled {
                        SecureField("Enrollment secret", text: $enrollmentSecret)
                    }

                    HStack {
                        if isEnrolled {
                            Button("Forget Device", role: .destructive) {
                                forgetDevice()
                            }
                            .disabled(isEnrolling)
                        } else {
                            Button("Enroll This Mac") {
                                enroll()
                            }
                            .disabled(enrollmentSecret.isEmpty || isEnrolling)
                        }

                        if isEnrolling {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text(
                        "Paste the value of FRAMEBASE_API_DEV_ENROLLMENT_SECRET from ~/.env. " +
                        "The secret itself is never stored — only the resulting session token, in Keychain."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Connection") {
                    HStack {
                        Button("Check Health") {
                            checkHealth()
                        }
                        .disabled(isCheckingHealth)

                        if isCheckingHealth {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let healthResult {
                        Text(healthResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Library Sync") {
                    Toggle("Sync this library's folders and ratings to the cloud", isOn: $cloudSyncEnabled)
                        .disabled(!isEnrolled)
                        .onChange(of: cloudSyncEnabled) {
                            Task { await container.refreshCatalogSyncActivation() }
                        }

                    if let rootURL = container.libraryRootURL {
                        Text("Applies to the open library: \(rootURL.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(
                        "When on and this Mac is enrolled, folder names, ratings, and favorites for the " +
                        "open library sync to framebase-api-dev. Original photo files are never uploaded, " +
                        "on or off."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Text(
                        "This is a Phase 2 development surface for framebase-api-dev. Enrolling alone " +
                        "never syncs anything — Library Sync above is a separate switch, off by default."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Cloud (Dev)", systemImage: "icloud")
            }
            .task {
                await container.refreshEnrollmentStatus()
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

    private var isEnrolled: Bool {
        switch container.enrollmentStatus {
        case .enrolled, .expired: true
        case .notEnrolled: false
        }
    }

    private var enrollmentStatusDescription: String {
        switch container.enrollmentStatus {
        case .notEnrolled:
            "Not enrolled"
        case .enrolled(let deviceId, let expiresAt):
            "Enrolled as \(deviceId.prefix(8))… · expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))"
        case .expired(let deviceId):
            "Expired · device \(deviceId.prefix(8))… needs re-enrollment"
        }
    }

    private var networkScopeDescription: String {
        isEnrolled ? "Dev cloud enrollment only" : "Disabled"
    }

    private func enroll() {
        isEnrolling = true
        Task {
            do {
                try await container.enrollDevice(
                    enrollmentSecret: enrollmentSecret,
                    deviceName: Host.current().localizedName ?? "This Mac"
                )
                enrollmentSecret = ""
                message = "Enrolled successfully."
            } catch {
                message = error.localizedDescription
            }
            isEnrolling = false
        }
    }

    private func forgetDevice() {
        isEnrolling = true
        Task {
            do {
                try await container.forgetDevice()
                message = "Device credential removed."
            } catch {
                message = error.localizedDescription
            }
            isEnrolling = false
        }
    }

    private func checkHealth() {
        isCheckingHealth = true
        Task {
            do {
                let health = try await container.checkCloudHealth()
                healthResult = "Status: \(health.status) · DB: \(health.db) · v\(health.version)"
            } catch {
                healthResult = error.localizedDescription
            }
            isCheckingHealth = false
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
