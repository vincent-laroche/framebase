import FramebaseDomain

/// Wraps a real `FolderRepository`, recording the mutations the cloud
/// contract supports (`create_folder`, `rename_folder`) to the outbox after
/// each successful local write. Every other method passes through
/// unchanged — folder delete/restore aren't in `Cloud/apps/api`'s mutation
/// vocabulary yet, so there's nothing to record them as.
public struct SyncingFolderRepository: FolderRepository {
    private let wrapped: any FolderRepository
    private let recorder: CatalogOutboxRecorder

    public init(wrapping wrapped: any FolderRepository, recorder: CatalogOutboxRecorder) {
        self.wrapped = wrapped
        self.recorder = recorder
    }

    public func treeSnapshot() async throws -> FolderTreeSnapshot {
        try await wrapped.treeSnapshot()
    }

    public func observeTree() -> AsyncThrowingStream<FolderTreeSnapshot, any Error> {
        wrapped.observeTree()
    }

    public func createFolder(named name: FolderName, in parentFolderID: FolderID?) async throws -> Folder {
        let folder = try await wrapped.createFolder(named: name, in: parentFolderID)
        try await recorder.recordFolderCreated(folder)
        return folder
    }

    public func createFolder(id: FolderID, named name: FolderName, in parentFolderID: FolderID?) async throws -> Folder {
        let folder = try await wrapped.createFolder(id: id, named: name, in: parentFolderID)
        try await recorder.recordFolderCreated(folder)
        return folder
    }

    public func renameFolder(_ folderID: FolderID, to name: FolderName) async throws {
        try await wrapped.renameFolder(folderID, to: name)
        try await recorder.recordFolderRenamed(folderID, name: name)
    }

    public func reparentFolder(_ folderID: FolderID, to parentFolderID: FolderID?) async throws {
        try await wrapped.reparentFolder(folderID, to: parentFolderID)
    }

    public func deletePreservingAssets(_ folderID: FolderID) async throws -> FolderDeletionReceipt {
        try await wrapped.deletePreservingAssets(folderID)
    }

    public func restoreDeletedFolder(using receipt: FolderDeletionReceipt) async throws {
        try await wrapped.restoreDeletedFolder(using: receipt)
    }
}
