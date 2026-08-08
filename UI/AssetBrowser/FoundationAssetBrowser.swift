import AppKit
import FramebaseDomain
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
                if model.orderedVisibleAssetIDs.isEmpty {
                    ContentUnavailableView {
                        Label(model.navigationTarget.title, systemImage: "photo.stack")
                    } description: {
                        Text("No assets match this destination.")
                    }
                    .accessibilityIdentifier("assetBrowser.empty.\(model.navigationTarget.title)")
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: model.thumbnailSize), spacing: 16)],
                            spacing: 18
                        ) {
                            ForEach(model.assetGridRecords) { record in
                                AssetThumbnailTile(record: record, model: model)
                            }
                        }
                        .padding(20)
                    }
                    .accessibilityIdentifier("assetBrowser.grid")
                }
            }
        }
        .navigationTitle(model.navigationTarget.title)
    }
}

private struct AssetThumbnailTile: View {
    let record: AssetGridRecord
    let model: LibraryWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))

                switch model.thumbnailStates[record.id] {
                case let .ready(payload):
                    if let image = NSImage(data: payload.encodedData) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        thumbnailFailure("exclamationmark.triangle", label: "Corrupt thumbnail")
                    }
                case .missing:
                    thumbnailFailure("questionmark.folder", label: "Original missing")
                case .corrupt:
                    thumbnailFailure("exclamationmark.triangle", label: "Image unreadable")
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                case nil:
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: model.thumbnailSize)

            Text(record.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .onAppear {
            model.requestThumbnail(
                for: record,
                displayScale: Double(NSScreen.main?.backingScaleFactor ?? 2)
            )
        }
        .onDisappear {
            model.cancelThumbnail(for: record.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(record.displayName)
    }

    @ViewBuilder
    private func thumbnailFailure(_ symbol: String, label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}
