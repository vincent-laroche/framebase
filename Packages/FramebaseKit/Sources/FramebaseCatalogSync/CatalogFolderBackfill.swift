import FramebaseDomain

/// Enqueues a library's *existing* folders into the outbox, so a library
/// that already had folders before sync was enabled doesn't wait for the
/// next rename to have them exist in the cloud. Scoped to folders only —
/// asset rating/favorite backfill would be incomplete without asset
/// creation sync (a second device can't apply a rating change to an asset
/// it has never heard of), so that's deliberately not attempted here.
///
/// One-shot: this doesn't track "already backfilled" state, so it's the
/// caller's responsibility to run it exactly once per library, when sync
/// is first enabled — not on every launch.
public enum CatalogFolderBackfill {
    public static func enqueueExistingFolders(
        from folders: any FolderRepository,
        into recorder: CatalogOutboxRecorder
    ) async throws {
        let snapshot = try await folders.treeSnapshot()
        let byID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })

        for folderID in orderedParentBeforeChild(roots: snapshot.roots, childrenByParent: snapshot.childrenByParent) {
            guard let folder = byID[folderID], folder.systemKind != .inbox else { continue }
            try await recorder.recordFolderCreated(folder)
        }
    }

    /// A breadth-first walk starting from `roots` visits every folder
    /// before any of its children, which is exactly the order
    /// `create_folder` payloads need — a child's `parentId` must reference
    /// a folder the recorder has already pushed.
    private static func orderedParentBeforeChild(
        roots: [FolderID],
        childrenByParent: [FolderID: [FolderID]]
    ) -> [FolderID] {
        var ordered: [FolderID] = []
        var queue = roots
        while !queue.isEmpty {
            let folderID = queue.removeFirst()
            ordered.append(folderID)
            queue.append(contentsOf: childrenByParent[folderID] ?? [])
        }
        return ordered
    }
}
