import Foundation

/// Starter taxonomy for screenshots and other non-photo junk.
///
/// This is its own library space, not a tag or folder inside Personal or
/// Hair Solutions. `discard` is where obsolete captures are moved so the live
/// set does not have to keep today's pile. Review state stays in tags.
public enum ScreenshotsLibraryTemplate: LibraryStarterTemplate {
    public static let name = "Screenshots library"
    public static let space = LibrarySpace.screenshots
    public static let initialCustomTagRawValues: [String] = []

    public static let folders: [LibraryFolderTemplate] = [
        .initialPath("screenshots"),
        .initialPath("screenshots/desktop"),
        .initialPath("screenshots/apps"),
        .initialPath("screenshots/web"),
        .initialPath("documents"),
        .initialPath("documents/receipts"),
        .initialPath("captures"),
        .initialPath("discard")
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
            allowedValues: ["mac", "phone", "browser", "app"],
            allowsCustomValues: false,
            allowsMultipleValuesPerAsset: false
        ),
        .init(namespace: "app", allowsCustomValues: true, allowsMultipleValuesPerAsset: true)
    ]
}
