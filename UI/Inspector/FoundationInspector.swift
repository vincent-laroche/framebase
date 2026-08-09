import AppKit
import FramebaseDomain
import SwiftUI

struct FoundationInspector: View {
    let model: LibraryWindowModel

    var body: some View {
        Group {
            if model.selectedAssetIDs.isEmpty {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "info.circle",
                    description: Text("Select an image to inspect its details.")
                )
            } else if model.inspectorSelectionIsLimited {
                Form {
                    Section("Selection") {
                        LabeledContent("Assets", value: model.selectedAssetIDs.count.formatted())
                        Text("Detailed aggregation is limited to selections of 500 images so selecting the entire library stays responsive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Apply to selection") {
                        HStack {
                            Button("Favorite All") { Task { await model.setFavorite(true) } }
                            Button("Unfavorite All") { Task { await model.setFavorite(false) } }
                        }
                        tagEditingControls
                    }
                }
                .formStyle(.grouped)
            } else if model.selectedAssets.isEmpty {
                ProgressView("Loading selection…")
            } else if model.selectedAssets.count == 1, let asset = model.selectedAssets.first {
                singleAssetInspector(asset)
            } else {
                multiAssetInspector(model.selectedAssets)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("inspector.content")
    }

    private func singleAssetInspector(_ asset: Asset) -> some View {
        Form {
            Section {
                preview
                    .frame(maxWidth: .infinity)
            }

            Section("File") {
                AssetDisplayNameEditor(asset: asset) { proposedName in
                    Task { await model.renameSelectedAsset(to: proposedName) }
                }
                LabeledContent("Name", value: asset.filename)
                LabeledContent("Folder", value: folderName(asset.parentFolderID))
                LabeledContent("Dimensions", value: dimensions(asset))
                LabeledContent(
                    "Size",
                    value: ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file)
                )
                LabeledContent("Created", value: formatted(asset.createdAt))
                LabeledContent("Modified", value: formatted(asset.modifiedAt))
                LabeledContent("Imported", value: formatted(asset.importedAt))
            }

            Section("Organization") {
                Toggle("Favorite", isOn: favoriteBinding(asset.favorite))
                Picker("Rating", selection: ratingBinding(asset.rating.rawValue)) {
                    Text("Unrated").tag(0)
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value) star\(value == 1 ? "" : "s")").tag(value)
                    }
                }
                tagEditingControls
            }

            if let trashEntry = model.trashEntriesByAssetID[asset.id] {
                Section("Trash") {
                    LabeledContent("Restore by", value: formatted(trashEntry.expiresAt))
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        LabeledContent(
                            "Time remaining",
                            value: retentionCountdown(until: trashEntry.expiresAt, now: context.date)
                        )
                    }
                    Text("The original remains in its managed location. Framebase does not purge it automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Image metadata") {
                LabeledContent("Format", value: asset.metadata.file.typeIdentifier ?? "Unknown")
                LabeledContent("Color model", value: asset.metadata.image.colorModel ?? "Unknown")
                if let bitDepth = asset.metadata.image.bitDepth {
                    LabeledContent("Bit depth", value: bitDepth.formatted())
                }
                if let exif = asset.metadata.exif {
                    if let camera = cameraDescription(exif) {
                        LabeledContent("Camera", value: camera)
                    }
                    if let lens = exif.lensModel {
                        LabeledContent("Lens", value: lens)
                    }
                    if let capturedAt = exif.capturedAt {
                        LabeledContent("Captured", value: formatted(capturedAt))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
    }

    private func multiAssetInspector(_ assets: [Asset]) -> some View {
        let folders = Set(assets.map(\.parentFolderID))
        let ratings = Dictionary(grouping: assets, by: { $0.rating.rawValue })
            .map { "\($0.key): \($0.value.count)" }
            .sorted()
            .joined(separator: ", ")

        return Form {
            Section("Selection") {
                LabeledContent("Assets", value: assets.count.formatted())
                LabeledContent(
                    "Total size",
                    value: ByteCountFormatter.string(
                        fromByteCount: assets.reduce(0) { $0 + $1.fileSize },
                        countStyle: .file
                    )
                )
                LabeledContent(
                    "Folder",
                    value: folders.count == 1 ? folderName(folders.first!) : "Mixed"
                )
                LabeledContent("Favorites", value: assets.filter(\.favorite).count.formatted())
                LabeledContent("Ratings", value: ratings.isEmpty ? "None" : ratings)
                if let first = assets.map(\.createdAt).min(), let last = assets.map(\.createdAt).max() {
                    LabeledContent("Date range", value: "\(formatted(first)) – \(formatted(last))")
                }
                let expiryDates = assets.compactMap { model.trashEntriesByAssetID[$0.id]?.expiresAt }
                if let nextExpiry = expiryDates.min() {
                    LabeledContent("Next restore deadline", value: formatted(nextExpiry))
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        LabeledContent(
                            "Next deadline in",
                            value: retentionCountdown(until: nextExpiry, now: context.date)
                        )
                    }
                }
            }

            Section("Apply to selection") {
                HStack {
                    Button("Favorite All") { Task { await model.setFavorite(true) } }
                    Button("Unfavorite All") { Task { await model.setFavorite(false) } }
                }
                Picker("Rating", selection: ratingBinding(0)) {
                    Text("Set rating…").tag(0)
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value) star\(value == 1 ? "" : "s")").tag(value)
                    }
                }
                tagEditingControls
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.secondary.opacity(0.08))
            switch model.inspectorPreviewState {
            case let .ready(payload):
                if let image = NSImage(data: payload.encodedData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    previewPlaceholder("exclamationmark.triangle", "Preview unavailable")
                }
            case .loading:
                ProgressView()
            case .missing:
                previewPlaceholder("questionmark.folder", "Original missing")
            case .corrupt:
                previewPlaceholder("exclamationmark.triangle", "Image unreadable")
            case nil:
                previewPlaceholder("photo", "Preview")
            }
        }
        .frame(height: 220)
    }

    private func previewPlaceholder(_ symbol: String, _ label: String) -> some View {
        Label(label, systemImage: symbol)
            .foregroundStyle(.secondary)
    }

    private func favoriteBinding(_ value: Bool) -> Binding<Bool> {
        Binding(
            get: { value },
            set: { newValue in Task { await model.setFavorite(newValue) } }
        )
    }

    @ViewBuilder
    private var tagEditingControls: some View {
        if model.tags.isEmpty {
            Text("Create a tag from File to organize this selection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Menu("Add Tag") {
                ForEach(model.tags) { tag in
                    Button(tag.name) { Task { await model.addTag(tag.id) } }
                }
            }
            .accessibilityIdentifier("inspector.addTag")

            Menu("Remove Tag") {
                ForEach(model.tags) { tag in
                    Button(tag.name) { Task { await model.removeTag(tag.id) } }
                }
            }
            .accessibilityIdentifier("inspector.removeTag")
        }
    }

    private func ratingBinding(_ value: Int) -> Binding<Int> {
        Binding(
            get: { value },
            set: { newValue in
                guard let rating = try? AssetRating(newValue) else { return }
                Task { await model.setRating(rating) }
            }
        )
    }

    private func folderName(_ folderID: FolderID) -> String {
        model.folderTreeSnapshot?.folders.first(where: { $0.id == folderID })?.name.rawValue
            ?? "Unavailable"
    }

    private func dimensions(_ asset: Asset) -> String {
        guard let width = asset.width, let height = asset.height else { return "Unknown" }
        return "\(width) × \(height)"
    }

    private func cameraDescription(_ exif: EXIFMetadata) -> String? {
        [exif.cameraMake, exif.cameraModel]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func retentionCountdown(until expiry: Date, now: Date) -> String {
        guard expiry > now else { return "Restore window elapsed" }
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: expiry)
        let days = components.day ?? 0
        let hours = components.hour ?? 0
        let minutes = components.minute ?? 0
        if days > 0 { return "\(days)d \(hours)h remaining" }
        if hours > 0 { return "\(hours)h \(minutes)m remaining" }
        return "\(max(minutes, 1))m remaining"
    }
}

private struct AssetDisplayNameEditor: View {
    let asset: Asset
    let onRename: (String) -> Void
    @State private var proposedName: String

    init(asset: Asset, onRename: @escaping (String) -> Void) {
        self.asset = asset
        self.onRename = onRename
        _proposedName = State(initialValue: asset.displayName)
    }

    var body: some View {
        TextField("Display name", text: $proposedName)
            .onSubmit { onRename(proposedName) }
            .accessibilityIdentifier("inspector.assetDisplayName")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
