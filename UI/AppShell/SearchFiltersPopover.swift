import FramebaseDomain
import Foundation
import SwiftUI

/// A local-only editor for the structured fields that back an `AssetQuery`.
/// The browser model remains the only place that starts/restarts catalog
/// observation, so this view never reaches into SQL or storage directly.
struct SearchFiltersPopover: View {
    @State private var criteria: AssetSearchCriteria

    let tags: [Tag]
    let albums: [Album]
    let onChange: (AssetSearchCriteria) -> Void

    init(
        criteria: AssetSearchCriteria,
        tags: [Tag],
        albums: [Album],
        onChange: @escaping (AssetSearchCriteria) -> Void
    ) {
        _criteria = State(initialValue: criteria)
        self.tags = tags
        self.albums = albums
        self.onChange = onChange
    }

    var body: some View {
        Form {
            Section("Text fields") {
                TextField("Folder path", text: stringBinding(\.folderPathText))
                TextField("Metadata", text: stringBinding(\.metadataText))
            }

            Section("Asset state") {
                Picker("Rating", selection: ratingBinding) {
                    Text("Any").tag(-1)
                    ForEach(0...5, id: \.self) { value in
                        Text(value == 0 ? "Unrated" : "\(value) stars").tag(value)
                    }
                }

                Picker("Favorite", selection: favoriteBinding) {
                    Text("Any").tag("any")
                    Text("Favorite").tag("yes")
                    Text("Not favorite").tag("no")
                }
            }

            Section("Capture date") {
                Toggle("Limit by capture date", isOn: dateEnabledBinding)
                if criteria.capturedDateRange != nil {
                    DatePicker("From", selection: capturedStartBinding, displayedComponents: .date)
                    DatePicker("To", selection: capturedEndBinding, displayedComponents: .date)
                }
            }

            if !tags.isEmpty {
                Section("Tags — match all selected") {
                    ForEach(tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
                        Toggle(tag.name, isOn: tagBinding(tag.id))
                    }
                }
            }

            if !albums.isEmpty {
                Section("Albums — match all selected") {
                    ForEach(albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { album in
                        Toggle(album.name, isOn: albumBinding(album.id))
                    }
                }
            }

            Button("Clear All Filters", role: .destructive) {
                criteria = AssetSearchCriteria()
            }
            .disabled(criteria.isEmpty)
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onChange(of: criteria) { _, newCriteria in
            onChange(newCriteria)
        }
        .accessibilityIdentifier("search.filters")
    }

    private var ratingBinding: Binding<Int> {
        Binding(
            get: { criteria.rating?.rawValue ?? -1 },
            set: { value in
                criteria.rating = value < 0 ? nil : try? AssetRating(value)
            }
        )
    }

    private var favoriteBinding: Binding<String> {
        Binding(
            get: {
                switch criteria.favorite {
                case true: "yes"
                case false: "no"
                case nil: "any"
                }
            },
            set: { value in
                criteria.favorite = switch value {
                case "yes": true
                case "no": false
                default: nil
                }
            }
        )
    }

    private var dateEnabledBinding: Binding<Bool> {
        Binding(
            get: { criteria.capturedDateRange != nil },
            set: { enabled in
                criteria.capturedDateRange = enabled
                    ? AssetDateRange(start: Date(), end: Date())
                    : nil
            }
        )
    }

    private var capturedStartBinding: Binding<Date> {
        Binding(
            get: { criteria.capturedDateRange?.start ?? Date() },
            set: { start in
                let end = criteria.capturedDateRange?.end ?? start
                criteria.capturedDateRange = AssetDateRange(start: start, end: end)
            }
        )
    }

    private var capturedEndBinding: Binding<Date> {
        Binding(
            get: { criteria.capturedDateRange?.end ?? Date() },
            set: { end in
                let start = criteria.capturedDateRange?.start ?? end
                criteria.capturedDateRange = AssetDateRange(start: start, end: end)
            }
        )
    }

    private func stringBinding(_ keyPath: WritableKeyPath<AssetSearchCriteria, String?>) -> Binding<String> {
        Binding(
            get: { criteria[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                criteria[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private func tagBinding(_ tagID: TagID) -> Binding<Bool> {
        Binding(
            get: { criteria.tagIDs.contains(tagID) },
            set: { selected in
                if selected {
                    criteria.tagIDs.insert(tagID)
                } else {
                    criteria.tagIDs.remove(tagID)
                }
            }
        )
    }

    private func albumBinding(_ albumID: AlbumID) -> Binding<Bool> {
        Binding(
            get: { criteria.albumIDs.contains(albumID) },
            set: { selected in
                if selected {
                    criteria.albumIDs.insert(albumID)
                } else {
                    criteria.albumIDs.remove(albumID)
                }
            }
        )
    }
}
