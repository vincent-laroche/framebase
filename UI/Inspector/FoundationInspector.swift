import AppKit
import FramebaseDomain
import SwiftUI

struct FoundationInspector: View {
    let model: LibraryWindowModel
    @State private var proposedTagName = ""
    @State private var proposedDisplayName = ""
    @State private var correctedBusinessQuality = BusinessPhotoQuality.needsReview
    @State private var correctedPhotoRole = PhotoRole.unclear
    @State private var correctedHairlinePresentation = HairlinePresentation.unclear

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
                LabeledContent("Name", value: asset.filename)
                TextField("Display name", text: $proposedDisplayName)
                    .onSubmit(saveProposedDisplayName)
                Button("Save Display Name", action: saveProposedDisplayName)
                    .disabled(proposedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || proposedDisplayName == asset.displayName)
                LabeledContent("Dimensions", value: dimensions(asset))
                LabeledContent(
                    "Size",
                    value: ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file)
                )
                LabeledContent("Created", value: formatted(asset.createdAt))
                LabeledContent("Modified", value: formatted(asset.modifiedAt))
                LabeledContent("Imported", value: formatted(asset.importedAt))
                if case .missing = model.inspectorPreviewState, model.container.cloudSync != nil {
                    Button("Download Verified Original") {
                        Task { await model.materializeOriginal(asset.id) }
                    }
                }
            }

            assetLocation(asset)

            localAnalysis

            visualAssessmentReview

            Section("Organization") {
                Toggle("Favorite", isOn: favoriteBinding(asset.favorite))
                Picker("Rating", selection: ratingBinding(asset.rating.rawValue)) {
                    Text("Unrated").tag(0)
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value) star\(value == 1 ? "" : "s")").tag(value)
                    }
                }
                organizationActions
            }

            trashRecoveryState

            tagEditor

            if let candidate = model.selectedDuplicateCandidate {
                Section("Exact-byte duplicate") {
                    Text("This original has \(candidate.assetIDs.count - 1) verified exact-byte duplicate\(candidate.assetIDs.count == 2 ? "" : "s").")
                    Text("Framebase will not merge, remove, or otherwise change candidates automatically.")
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
        .task(id: asset.id) {
            proposedDisplayName = asset.displayName
        }
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
                    value: folders.count == 1 ? model.folderPath(for: folders.first!) : "Mixed"
                )
                LabeledContent("Favorites", value: assets.filter(\.favorite).count.formatted())
                LabeledContent("Ratings", value: ratings.isEmpty ? "None" : ratings)
                if let first = assets.map(\.createdAt).min(), let last = assets.map(\.createdAt).max() {
                    LabeledContent("Date range", value: "\(formatted(first)) – \(formatted(last))")
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
                organizationActions
            }
            Section("Local analysis") {
                analysisControls
            }
            beforeAfterReview(assets)
            trashRecoveryState
            tagEditor
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

    private func assetLocation(_ asset: Asset) -> some View {
        let albumNames = model.albums(containing: asset.id).map(\.name)
        return Section("Location") {
            locationRow(
                title: "Folder",
                value: model.folderPath(for: asset.parentFolderID),
                symbol: "folder",
                identifier: "inspector.location.folder"
            )
            locationRow(
                title: "Albums",
                value: albumNames.isEmpty ? "Not in an album" : albumNames.joined(separator: " · "),
                symbol: "rectangle.stack",
                identifier: "inspector.location.albums"
            )
            locationRow(
                title: "Open view",
                value: model.navigationLocationLabel,
                symbol: "eye",
                identifier: "inspector.location.view"
            )
        }
    }

    private func locationRow(title: String, value: String, symbol: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Label(value, systemImage: symbol)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title): \(value)")
    }

    @ViewBuilder
    private var organizationActions: some View {
        if !model.availableMoveDestinations.isEmpty {
            Menu("Move To") {
                ForEach(model.availableMoveDestinations, id: \.id) { folder in
                    Button(folder.name.rawValue) {
                        Task { await model.moveAssets(model.selectedAssetIDs, to: folder.id) }
                    }
                }
            }
        }
        if model.navigationTarget == .trash {
            Button("Restore from Trash") { Task { await model.restoreSelectedAssets() } }
        } else {
            Button("Move to Trash", role: .destructive) { Task { await model.trashSelectedAssets() } }
        }
        if model.selectedAssetIDs.count == 1, let assetID = model.selectedAssetIDs.first {
            Button("Reveal Original in Finder") {
                Task { await model.revealOriginal(assetID) }
            }
        }
        Button("Export Selection…") {
            guard let destinationURL = LibraryPanelService.chooseExportDirectory() else { return }
            Task { await model.exportSelectedAssets(to: destinationURL) }
        }
    }

    @ViewBuilder
    private var trashRecoveryState: some View {
        if !model.selectedTrashReceipts.isEmpty {
            Section("Trash retention") {
                let earliestPurge = model.selectedTrashReceipts.map(\.scheduledPurgeAt).min() ?? .now
                LabeledContent("Scheduled purge review", value: earliestPurge.formatted(date: .abbreviated, time: .shortened))
                Text("Purge is intentionally locked. Originals cannot be deleted from this screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Review Permanent Purge…", action: {})
                    .disabled(true)
            }
        }
    }

    private var tagEditor: some View {
        Section("Tags") {
            if model.selectedTags.isEmpty {
                Text("No common tags")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.selectedTags) { tag in
                    HStack {
                        Text(tag.name.rawValue)
                            .accessibilityIdentifier("inspector.tag.\(tag.name.rawValue)")
                        Spacer()
                        Button("Remove", role: .destructive) {
                            Task { await model.removeTag(tag.id) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("namespace:value", text: $proposedTagName)
                    .onSubmit(addProposedTag)
                    .accessibilityIdentifier("inspector.tagName")
                Button("Add", action: addProposedTag)
                    .accessibilityIdentifier("inspector.addTag")
                    .disabled(proposedTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var localAnalysis: some View {
        Section("Local analysis") {
            analysisControls
            if model.selectedAnalysisResults.isEmpty {
                Text("No local analysis has been run for this image.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.selectedAnalysisResults.filter { $0.kind != .faceRegions }, id: \.id) { result in
                    Divider()
                    Text("Local analysis provenance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("analysis.provenance")
                    LabeledContent("Type", value: analysisTitle(result.kind))
                    LabeledContent("Status", value: result.status.rawValue.capitalized)
                    LabeledContent("Engine", value: result.provenance.engine)
                    LabeledContent("Captured", value: formatted(result.provenance.capturedAt))
                    LabeledContent("Derivative", value: "max \(result.provenance.derivativeMaximumPixelDimension) px")
                    LabeledContent("Request revision", value: result.provenance.requestRevision.formatted())
                    LabeledContent("Derivative SHA-256") {
                        Text(result.provenance.derivativeSHA256)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    analysisPayload(result.payload)
                }
            }
        }
    }

    private var visualAssessmentReview: some View {
        Section("Visual assessment review") {
            if model.selectedPhotoAssessments.isEmpty {
                Text("No visual assessment is available for this image yet.")
                    .foregroundStyle(.secondary)
                Text("Any future assessment is advisory. Your review is stored as learning evidence and never organizes this asset automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.selectedPhotoAssessments, id: \.id) { assessment in
                    LabeledContent("Business quality", value: assessment.businessQuality.rawValue)
                    LabeledContent("Photo role", value: assessment.photoRole.rawValue)
                    LabeledContent("Hairline presentation", value: assessment.hairlinePresentation.rawValue)
                    LabeledContent("Confidence", value: assessment.confidence.formatted(.percent.precision(.fractionLength(0))))
                    LabeledContent("Provider", value: assessment.modelRevision.provider.rawValue)
                    LabeledContent("Model", value: assessment.modelRevision.modelIdentifier)
                    LabeledContent("Assessment schema", value: assessment.modelRevision.assessmentSchemaVersion.formatted())
                    LabeledContent("Derivative", value: "max \(assessment.derivativeMaximumPixelDimension) px")
                    LabeledContent("Derivative SHA-256") {
                        Text(assessment.derivativeSHA256)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Rationale", value: assessment.rationale)
                    if let reviews = model.selectedAssessmentReviews[assessment.id], !reviews.isEmpty {
                        LabeledContent("Review history", value: "\(reviews.count) recorded")
                        ForEach(reviews, id: \.id) { review in
                            Text("\(review.decision.rawValue) · \(formatted(review.reviewedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Accept") {
                            Task { await model.recordAssessmentReview(assessment, decision: .accepted) }
                        }
                        .accessibilityIdentifier("assessment.accept")
                        Button("Needs Context") {
                            Task { await model.recordAssessmentReview(assessment, decision: .needsMoreContext) }
                        }
                        .accessibilityIdentifier("assessment.needsContext")
                        Button("Reject", role: .destructive) {
                            Task { await model.recordAssessmentReview(assessment, decision: .rejected) }
                        }
                        .accessibilityIdentifier("assessment.reject")
                    }
                    Picker("Correct business quality", selection: $correctedBusinessQuality) {
                        ForEach(BusinessPhotoQuality.allCases, id: \.self) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    Picker("Correct photo role", selection: $correctedPhotoRole) {
                        ForEach(PhotoRole.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                    Picker("Correct hairline presentation", selection: $correctedHairlinePresentation) {
                        ForEach(HairlinePresentation.allCases, id: \.self) { presentation in
                            Text(presentation.rawValue).tag(presentation)
                        }
                    }
                    Button("Record Correction") {
                        Task {
                            await model.recordAssessmentCorrection(
                                assessment,
                                businessQuality: correctedBusinessQuality,
                                photoRole: correctedPhotoRole,
                                hairlinePresentation: correctedHairlinePresentation
                            )
                        }
                    }
                    .accessibilityIdentifier("assessment.correct")
                    .disabled(
                        correctedBusinessQuality == assessment.businessQuality &&
                        correctedPhotoRole == assessment.photoRole &&
                        correctedHairlinePresentation == assessment.hairlinePresentation
                    )
                    Text("Reviewing records feedback only; folders, tags, ratings, favorites, and originals remain unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.selectedBeforeAfterRelationships.isEmpty {
                    Divider()
                    Text("Related before / after evidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.selectedBeforeAfterRelationships, id: \.id) { relationship in
                        LabeledContent("Relationship", value: relationship.status.rawValue)
                    }
                }
            }
        }
        .task(id: model.selectedPhotoAssessments) {
            guard let assessment = model.selectedPhotoAssessments.first else { return }
            correctedBusinessQuality = assessment.businessQuality
            correctedPhotoRole = assessment.photoRole
            correctedHairlinePresentation = assessment.hairlinePresentation
        }
    }

    @ViewBuilder
    private func beforeAfterReview(_ assets: [Asset]) -> some View {
        if assets.count == 2 {
            Section("Before / after review") {
                Text("Choose the before image explicitly. This records a relationship only; it never moves, tags, rates, or edits either asset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(assets) { beforeAsset in
                    let afterAsset = assets.first { $0.id != beforeAsset.id }!
                    Menu("Set \(beforeAsset.displayName) as Before") {
                        Button("Confirm Pair") {
                            Task { await model.recordBeforeAfterRelationship(beforeAssetID: beforeAsset.id, afterAssetID: afterAsset.id, status: .confirmed) }
                        }
                        Button("Reject Pair", role: .destructive) {
                            Task { await model.recordBeforeAfterRelationship(beforeAssetID: beforeAsset.id, afterAssetID: afterAsset.id, status: .rejected) }
                        }
                    }
                    .accessibilityIdentifier("beforeAfter.choose.\(beforeAsset.id.description)")
                }
            }
        }
    }

    @ViewBuilder
    private var analysisControls: some View {
        Button {
            Task { await model.analyzeSelectedAssets() }
        } label: {
            if model.isAnalyzingSelection {
                Label("Analyzing Locally…", systemImage: "hourglass")
            } else {
                Label("Analyze Locally", systemImage: "text.viewfinder")
            }
        }
        .accessibilityIdentifier("inspector.analyzeLocally")
        .disabled(model.isAnalyzingSelection)

        Text("Runs OCR, barcode, and document detection on this Mac. Framebase will not organize assets automatically.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func analysisPayload(_ payload: AnalysisPayload) -> some View {
        switch payload {
        case let .ocr(lines):
            LabeledContent("Recognized text", value: "\(lines.count) line\(lines.count == 1 ? "" : "s")")
            ForEach(Array(lines.prefix(5).enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if lines.count > 5 {
                Text("\(lines.count - 5) additional recognized line\(lines.count == 6 ? "" : "s") are indexed for local search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .barcode(count, observations):
            LabeledContent("Barcodes", value: count.formatted())
            ForEach(Array(observations.prefix(5).enumerated()), id: \.offset) { _, observation in
                Text("\(observation.symbology): \(observation.payload ?? "Unreadable payload")")
                    .font(.caption)
                    .textSelection(.enabled)
            }
        case let .document(confidence):
            LabeledContent("Document confidence", value: confidence.formatted(.percent.precision(.fractionLength(0))))
        case .faceRegions:
            EmptyView()
        }
    }

    private func analysisTitle(_ kind: AnalysisKind) -> String {
        switch kind {
        case .ocr: "Recognized text"
        case .barcode: "Barcode detection"
        case .document: "Document detection"
        case .faceRegions: "Legacy face-region record"
        }
    }

    private func addProposedTag() {
        let name = proposedTagName
        proposedTagName = ""
        Task { await model.addTag(named: name) }
    }

    private func saveProposedDisplayName() {
        let displayName = proposedDisplayName
        Task { await model.renameSelectedAsset(to: displayName) }
    }

    private func favoriteBinding(_ value: Bool) -> Binding<Bool> {
        Binding(
            get: { value },
            set: { newValue in Task { await model.setFavorite(newValue) } }
        )
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
