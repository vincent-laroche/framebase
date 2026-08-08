import Foundation
import FramebaseDomain

public enum ManagedImportCoordinatorError: Error, LocalizedError, Sendable {
    case importAlreadyInProgress
    case catalogCommitFailed(String)
    case rollbackFailed(originalReason: String, failedCopyCount: Int)

    public var errorDescription: String? {
        switch self {
        case .importAlreadyInProgress:
            "An import is already in progress."
        case let .catalogCommitFailed(reason):
            "The imported files could not be added to the catalog: \(reason)"
        case let .rollbackFailed(reason, count):
            "The catalog update failed (\(reason)), and Framebase could not remove \(count) newly managed copy/copies."
        }
    }
}

/// Coordinates one transactional import batch across managed storage and the catalog.
///
/// Individual invalid files become `ImportFailure` values so valid siblings can
/// continue. Valid originals are committed first, then inserted into the catalog
/// in one caller-supplied transaction. If that transaction fails, only copies
/// committed by this coordinator's blob-store instance are rolled back.
public actor ManagedImportCoordinator: ImportCoordinator {
    public typealias CatalogInsert = @Sendable ([Asset]) async throws -> Void

    private let blobStore: any AssetBlobStore
    private let metadataExtractor: any MetadataExtractor
    private let insertIntoCatalog: CatalogInsert
    private var activeImportID: UUID?
    private var cancellationRequestedFor: UUID?

    public init(
        blobStore: any AssetBlobStore,
        metadataExtractor: any MetadataExtractor,
        insertIntoCatalog: @escaping CatalogInsert
    ) {
        self.blobStore = blobStore
        self.metadataExtractor = metadataExtractor
        self.insertIntoCatalog = insertIntoCatalog
    }

    public func importAssets(
        _ request: ImportRequest,
        progress: @escaping @Sendable (ImportProgress) async -> Void
    ) async throws -> ImportResult {
        guard activeImportID == nil else {
            throw ManagedImportCoordinatorError.importAlreadyInProgress
        }

        let importID = UUID()
        activeImportID = importID
        cancellationRequestedFor = nil
        defer {
            activeImportID = nil
            cancellationRequestedFor = nil
        }

        let sources = request.sourceURLs
        var committedBlobs: [CommittedBlob] = []
        var assets: [Asset] = []
        var failures: [ImportFailure] = []

        await progress(ImportProgress(completedCount: 0, totalCount: sources.count, currentFilename: nil))

        for (index, sourceURL) in sources.enumerated() {
            if shouldCancel(importID) {
                await cleanUpCancelledImport(committedBlobs)
                return ImportResult(importedAssetIDs: [], failures: failures, cancelled: true)
            }

            await progress(ImportProgress(
                completedCount: index,
                totalCount: sources.count,
                currentFilename: sourceURL.lastPathComponent
            ))

            do {
                let assetID = AssetID()
                let staged = try await blobStore.stage(sourceURL: sourceURL, for: assetID)

                guard await metadataExtractor.supportsImage(at: staged.stagingURL) else {
                    _ = try? await blobStore.recoverStaging()
                    failures.append(ImportFailure(
                        sourceURL: sourceURL,
                        reason: "Unsupported or unreadable still image."
                    ))
                    await publishCompletion(index: index, sources: sources, progress: progress)
                    continue
                }

                let extracted = try await metadataExtractor.extract(from: staged.stagingURL)
                var metadata = extracted.metadata
                metadata.file.filenameExtension = sourceURL.pathExtension.isEmpty
                    ? nil
                    : sourceURL.pathExtension.lowercased()

                if shouldCancel(importID) {
                    _ = try? await blobStore.recoverStaging()
                    await cleanUpCancelledImport(committedBlobs)
                    return ImportResult(importedAssetIDs: [], failures: failures, cancelled: true)
                }

                let committed = try await blobStore.commit(staged)
                committedBlobs.append(committed)
                let now = Date()
                let sourceCreatedAt = try? sourceURL.resourceValues(forKeys: [.creationDateKey]).creationDate
                let baseName = sourceURL.deletingPathExtension().lastPathComponent
                let displayName = baseName.isEmpty ? sourceURL.lastPathComponent : baseName

                assets.append(Asset(
                    id: assetID,
                    filename: sourceURL.lastPathComponent,
                    displayName: displayName,
                    parentFolderID: request.destinationFolderID,
                    storageKey: committed.storageKey,
                    localURL: committed.localURL,
                    width: extracted.width,
                    height: extracted.height,
                    fileSize: committed.fileSize,
                    createdAt: extracted.createdAt ?? sourceCreatedAt ?? committed.modifiedAt,
                    modifiedAt: committed.modifiedAt,
                    importedAt: now,
                    updatedAt: now,
                    metadata: metadata
                ))
            } catch is CancellationError {
                _ = try? await blobStore.recoverStaging()
                await cleanUpCancelledImport(committedBlobs)
                return ImportResult(importedAssetIDs: [], failures: failures, cancelled: true)
            } catch {
                _ = try? await blobStore.recoverStaging()
                failures.append(ImportFailure(sourceURL: sourceURL, reason: error.localizedDescription))
            }

            await publishCompletion(index: index, sources: sources, progress: progress)
        }

        if shouldCancel(importID) {
            await cleanUpCancelledImport(committedBlobs)
            return ImportResult(importedAssetIDs: [], failures: failures, cancelled: true)
        }

        guard !assets.isEmpty else {
            return ImportResult(importedAssetIDs: [], failures: failures, cancelled: false)
        }

        do {
            try await insertIntoCatalog(assets)
        } catch {
            let rollbackFailures = await rollBack(committedBlobs)
            if rollbackFailures > 0 {
                throw ManagedImportCoordinatorError.rollbackFailed(
                    originalReason: error.localizedDescription,
                    failedCopyCount: rollbackFailures
                )
            }
            throw ManagedImportCoordinatorError.catalogCommitFailed(error.localizedDescription)
        }

        return ImportResult(
            importedAssetIDs: assets.map(\.id),
            failures: failures,
            cancelled: false
        )
    }

    public func cancelCurrentImport() async {
        cancellationRequestedFor = activeImportID
    }

    private func shouldCancel(_ importID: UUID) -> Bool {
        Task.isCancelled || cancellationRequestedFor == importID
    }

    private func publishCompletion(
        index: Int,
        sources: [URL],
        progress: @escaping @Sendable (ImportProgress) async -> Void
    ) async {
        await progress(ImportProgress(
            completedCount: index + 1,
            totalCount: sources.count,
            currentFilename: nil
        ))
    }

    private func cleanUpCancelledImport(_ committedBlobs: [CommittedBlob]) async {
        _ = await rollBack(committedBlobs)
        _ = try? await blobStore.recoverStaging()
    }

    private func rollBack(_ committedBlobs: [CommittedBlob]) async -> Int {
        var failures = 0
        for blob in committedBlobs.reversed() {
            do {
                try await blobStore.removeNewlyCommitted(blob)
            } catch {
                failures += 1
            }
        }
        return failures
    }
}
