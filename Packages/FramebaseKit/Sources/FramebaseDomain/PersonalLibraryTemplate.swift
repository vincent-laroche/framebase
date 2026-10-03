import Foundation

/// Starter taxonomy for Vincent's private photo library.
///
/// Folders record durable photo facts. Tags record changing review state and
/// cross-cutting people or places. This is not the Hair Solutions product tree.
/// `archive` is the durable place to move retired or obsolete originals out of
/// the active library; duplicate detection itself stays a tag, not a folder.
public enum PersonalLibraryTemplate: LibraryStarterTemplate {
    public static let name = "Personal library"
    public static let space = LibrarySpace.personal
    public static let initialCustomTagRawValues: [String] = []

    public static let folders: [LibraryFolderTemplate] = [
        .initialPath("people"),
        .initialPath("people/family"),
        .initialPath("people/portraits"),
        .initialPath("places"),
        .initialPath("places/home"),
        .initialPath("places/travel"),
        .initialPath("events"),
        .initialPath("projects"),
        .initialPath("archive")
    ]

    public static let tagNamespaces: [LibraryTagNamespaceTemplate] = [
        .init(
            namespace: "status",
            allowedValues: ["keep", "review", "duplicate", "obsolete", "archived"],
            allowsCustomValues: false,
            allowsMultipleValuesPerAsset: false
        ),
        .init(
            namespace: "source",
            allowedValues: ["camera", "phone", "scan", "shared"],
            allowsCustomValues: false,
            allowsMultipleValuesPerAsset: false
        ),
        .init(namespace: "person", allowsCustomValues: true, allowsMultipleValuesPerAsset: true),
        .init(namespace: "place", allowsCustomValues: true, allowsMultipleValuesPerAsset: true)
    ]
}
