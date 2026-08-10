import Foundation
import FramebaseDomain

public enum ManagedAssetBlobStoreError: Error, Equatable, Sendable {
    case invalidDirectoryURL(URL)
    case unsafeDirectoryRelationship
    case directoryIsSymbolicLink(URL)
    case expectedDirectory(URL)
    case stagingAndOriginalsMustShareVolume
    case sourceIsNotAFileURL(URL)
    case sourceIsInsideManagedStorage(URL)
    case sourceDoesNotExist(URL)
    case sourceIsNotARegularFile(URL)
    case sourceIsSymbolicLink(URL)
    case unsafeFilenameExtension(String)
    case unrecognizedStagedBlob
    case stagedBlobMissing(URL)
    case managedAssetAlreadyExists(AssetID)
    case invalidStorageKey(String)
    case managedBlobMissing(AssetStorageKey)
    case rollbackNotPermitted(AssetStorageKey)
    case managedBlobChanged(AssetStorageKey)
}

/// Actor-isolated storage for immutable, managed copies of imported originals.
///
/// The store owns only the two directories supplied at initialization. Source files are copied into
/// staging and are never moved, renamed, or removed. Committed blobs use a stable, relative storage
/// key and can be removed only by the actor instance that committed them, for catalog rollback.
public actor ManagedAssetBlobStore: RemoteOriginalMaterializing {
    public let originalsDirectoryURL: URL
    public let stagingDirectoryURL: URL

    private struct StagedRegistration {
        let assetID: AssetID
        let sourceURL: URL
        let stagingURL: URL
        let filenameExtension: String
    }

    private struct CommittedRegistration {
        let assetID: AssetID
        let storageKey: AssetStorageKey
        let localURL: URL
        let fileSize: Int64
        let modifiedAt: Date
    }

    private let fileManager: FileManager
    private var stagedRegistrations: [String: StagedRegistration] = [:]
    private var committedRegistrations: [AssetStorageKey: CommittedRegistration] = [:]

    public init(
        originalsDirectoryURL: URL,
        stagingDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let originals = try Self.normalizedDirectoryURL(originalsDirectoryURL)
        let staging = try Self.normalizedDirectoryURL(stagingDirectoryURL)

        guard !Self.isSameOrDescendant(originals, of: staging),
              !Self.isSameOrDescendant(staging, of: originals) else {
            throw ManagedAssetBlobStoreError.unsafeDirectoryRelationship
        }

        try Self.prepareDirectory(originals, using: fileManager)
        try Self.prepareDirectory(staging, using: fileManager)

        let resolvedOriginals = originals.resolvingSymlinksInPath().standardizedFileURL
        let resolvedStaging = staging.resolvingSymlinksInPath().standardizedFileURL
        guard !Self.isSameOrDescendant(resolvedOriginals, of: resolvedStaging),
              !Self.isSameOrDescendant(resolvedStaging, of: resolvedOriginals) else {
            throw ManagedAssetBlobStoreError.unsafeDirectoryRelationship
        }

        let originalsVolume = try? resolvedOriginals.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let stagingVolume = try? resolvedStaging.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        if let originalsVolume, let stagingVolume, !originalsVolume.isEqual(stagingVolume) {
            throw ManagedAssetBlobStoreError.stagingAndOriginalsMustShareVolume
        }

        self.originalsDirectoryURL = resolvedOriginals
        self.stagingDirectoryURL = resolvedStaging
        self.fileManager = fileManager
    }

    public func stage(sourceURL: URL, for assetID: AssetID) async throws -> StagedBlob {
        try verifyOwnedDirectories()

        guard sourceURL.isFileURL else {
            throw ManagedAssetBlobStoreError.sourceIsNotAFileURL(sourceURL)
        }

        let source = sourceURL.standardizedFileURL
        guard !Self.isSameOrDescendant(source.resolvingSymlinksInPath(), of: originalsDirectoryURL),
              !Self.isSameOrDescendant(source.resolvingSymlinksInPath(), of: stagingDirectoryURL) else {
            throw ManagedAssetBlobStoreError.sourceIsInsideManagedStorage(source)
        }

        let sourceAttributes: [FileAttributeKey: Any]
        do {
            sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw ManagedAssetBlobStoreError.sourceDoesNotExist(source)
        } catch {
            throw error
        }

        let sourceType = sourceAttributes[.type] as? FileAttributeType
        if sourceType == .typeSymbolicLink {
            throw ManagedAssetBlobStoreError.sourceIsSymbolicLink(source)
        }
        guard sourceType == .typeRegular else {
            throw ManagedAssetBlobStoreError.sourceIsNotARegularFile(source)
        }

        let filenameExtension = try Self.validatedFilenameExtension(source.pathExtension)
        let stagedName = "\(assetID.description)--\(UUID().uuidString.lowercased()).stage"
        let stagingURL = stagingDirectoryURL.appendingPathComponent(stagedName, isDirectory: false)
        guard Self.isDirectChild(stagingURL, of: stagingDirectoryURL), !itemExists(at: stagingURL) else {
            throw ManagedAssetBlobStoreError.unrecognizedStagedBlob
        }

        do {
            try fileManager.copyItem(at: source, to: stagingURL)
            try verifyRegularFile(at: stagingURL, missingError: .stagedBlobMissing(stagingURL))
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        let registration = StagedRegistration(
            assetID: assetID,
            sourceURL: source,
            stagingURL: stagingURL,
            filenameExtension: filenameExtension
        )
        stagedRegistrations[stagingURL.path] = registration

        return StagedBlob(
            assetID: assetID,
            sourceURL: source,
            stagingURL: stagingURL,
            preferredFilenameExtension: filenameExtension
        )
    }

    public func commit(_ stagedBlob: StagedBlob) async throws -> CommittedBlob {
        try verifyOwnedDirectories()

        let stagedURL = stagedBlob.stagingURL.standardizedFileURL
        guard let registration = stagedRegistrations[stagedURL.path],
              registration.assetID == stagedBlob.assetID,
              registration.sourceURL == stagedBlob.sourceURL.standardizedFileURL,
              registration.stagingURL == stagedURL,
              registration.filenameExtension == stagedBlob.preferredFilenameExtension,
              Self.isDirectChild(stagedURL, of: stagingDirectoryURL) else {
            throw ManagedAssetBlobStoreError.unrecognizedStagedBlob
        }

        try verifyRegularFile(at: stagedURL, missingError: .stagedBlobMissing(stagedURL))
        try ensureNoManagedBlobExists(for: stagedBlob.assetID)

        let uuid = stagedBlob.assetID.description
        let shard = String(uuid.prefix(2))
        let shardURL = originalsDirectoryURL.appendingPathComponent(shard, isDirectory: true)
        try Self.prepareDirectory(shardURL, using: fileManager)
        guard Self.isDirectChild(shardURL, of: originalsDirectoryURL) else {
            throw ManagedAssetBlobStoreError.unsafeDirectoryRelationship
        }

        let filename = "\(uuid).\(registration.filenameExtension)"
        let localURL = shardURL.appendingPathComponent(filename, isDirectory: false)
        guard Self.isDirectChild(localURL, of: shardURL), !itemExists(at: localURL) else {
            throw ManagedAssetBlobStoreError.managedAssetAlreadyExists(stagedBlob.assetID)
        }

        let relativeKey = "\(shard)/\(filename)"
        let storageKey: AssetStorageKey
        do {
            storageKey = try AssetStorageKey(relativeKey)
        } catch {
            throw ManagedAssetBlobStoreError.invalidStorageKey(relativeKey)
        }

        let stagedAttributes = try fileManager.attributesOfItem(atPath: stagedURL.path)
        guard let sizeNumber = stagedAttributes[.size] as? NSNumber,
              let modifiedAt = stagedAttributes[.modificationDate] as? Date else {
            throw ManagedAssetBlobStoreError.sourceIsNotARegularFile(stagedURL)
        }
        let fileSize = sizeNumber.int64Value

        try fileManager.moveItem(at: stagedURL, to: localURL)
        stagedRegistrations.removeValue(forKey: stagedURL.path)
        let registrationRecord = CommittedRegistration(
            assetID: stagedBlob.assetID,
            storageKey: storageKey,
            localURL: localURL,
            fileSize: fileSize,
            modifiedAt: modifiedAt
        )
        committedRegistrations[storageKey] = registrationRecord

        return CommittedBlob(
            assetID: stagedBlob.assetID,
            storageKey: storageKey,
            localURL: localURL,
            fileSize: fileSize,
            modifiedAt: modifiedAt
        )
    }

    public func resolve(_ storageKey: AssetStorageKey) async throws -> URL {
        try verifyOwnedDirectories()
        return try resolvedURL(for: storageKey)
    }

    public func materializeRemoteOriginal(
        from temporaryURL: URL,
        assetID: AssetID,
        storageKey: AssetStorageKey
    ) async throws -> URL {
        try verifyOwnedDirectories()
        let expectedFilenamePrefix = "\(assetID.description)."
        let components = try Self.validatedStorageKeyComponents(storageKey)
        guard components.filename.hasPrefix(expectedFilenamePrefix) else {
            throw ManagedAssetBlobStoreError.invalidStorageKey(storageKey.rawValue)
        }
        let destination = try resolvedURLForMaterialization(storageKey)
        if itemExists(at: destination) {
            try verifyRegularFile(at: destination, missingError: .managedBlobMissing(storageKey))
            return destination
        }
        try verifyRegularFile(at: temporaryURL, missingError: .sourceDoesNotExist(temporaryURL))
        let stagingURL = stagingDirectoryURL.appendingPathComponent("remote-\(UUID().uuidString.lowercased()).stage", isDirectory: false)
        guard Self.isDirectChild(stagingURL, of: stagingDirectoryURL) else { throw ManagedAssetBlobStoreError.unrecognizedStagedBlob }
        do {
            try fileManager.copyItem(at: temporaryURL, to: stagingURL)
            try verifyRegularFile(at: stagingURL, missingError: .stagedBlobMissing(stagingURL))
            let parent = destination.deletingLastPathComponent()
            try Self.prepareDirectory(parent, using: fileManager)
            try fileManager.moveItem(at: stagingURL, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func resolvedURL(for storageKey: AssetStorageKey) throws -> URL {
        let components = try Self.validatedStorageKeyComponents(storageKey)
        let url = originalsDirectoryURL
            .appendingPathComponent(components.shard, isDirectory: true)
            .appendingPathComponent(components.filename, isDirectory: false)
            .standardizedFileURL

        guard Self.isSameOrDescendant(url, of: originalsDirectoryURL) else {
            throw ManagedAssetBlobStoreError.invalidStorageKey(storageKey.rawValue)
        }
        try verifyRegularFile(at: url, missingError: .managedBlobMissing(storageKey))
        return url
    }

    private func resolvedURLForMaterialization(_ storageKey: AssetStorageKey) throws -> URL {
        let components = try Self.validatedStorageKeyComponents(storageKey)
        let url = originalsDirectoryURL
            .appendingPathComponent(components.shard, isDirectory: true)
            .appendingPathComponent(components.filename, isDirectory: false)
            .standardizedFileURL
        guard Self.isSameOrDescendant(url, of: originalsDirectoryURL) else {
            throw ManagedAssetBlobStoreError.invalidStorageKey(storageKey.rawValue)
        }
        return url
    }

    public func validate(_ storageKey: AssetStorageKey) async -> Bool {
        do {
            _ = try await resolve(storageKey)
            return true
        } catch {
            return false
        }
    }

    public func removeNewlyCommitted(_ committedBlob: CommittedBlob) async throws {
        try verifyOwnedDirectories()
        guard let registration = committedRegistrations[committedBlob.storageKey],
              registration.assetID == committedBlob.assetID,
              registration.storageKey == committedBlob.storageKey,
              registration.localURL == committedBlob.localURL.standardizedFileURL,
              registration.fileSize == committedBlob.fileSize,
              registration.modifiedAt == committedBlob.modifiedAt else {
            throw ManagedAssetBlobStoreError.rollbackNotPermitted(committedBlob.storageKey)
        }

        let resolvedURL = try resolvedURL(for: committedBlob.storageKey)
        guard resolvedURL == registration.localURL else {
            throw ManagedAssetBlobStoreError.rollbackNotPermitted(committedBlob.storageKey)
        }

        let attributes = try fileManager.attributesOfItem(atPath: resolvedURL.path)
        let currentSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let currentModifiedAt = (attributes[.modificationDate] as? Date) ?? Date.distantPast
        guard currentSize == registration.fileSize, currentModifiedAt == registration.modifiedAt else {
            throw ManagedAssetBlobStoreError.managedBlobChanged(committedBlob.storageKey)
        }

        try fileManager.removeItem(at: resolvedURL)
        committedRegistrations.removeValue(forKey: committedBlob.storageKey)
    }

    public func recoverStaging() async throws -> StagingRecoveryResult {
        try verifyOwnedDirectories()
        let candidates = try fileManager.contentsOfDirectory(
            at: stagingDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: []
        )

        var recoveredCount = 0
        var failedURLs: [URL] = []
        for candidate in candidates.sorted(by: { $0.path < $1.path }) {
            let url = candidate.standardizedFileURL
            guard Self.isDirectChild(url, of: stagingDirectoryURL) else {
                failedURLs.append(url)
                continue
            }

            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, values.isDirectory != true else {
                    failedURLs.append(url)
                    continue
                }
                try fileManager.removeItem(at: url)
                stagedRegistrations.removeValue(forKey: url.path)
                recoveredCount += 1
            } catch {
                failedURLs.append(url)
            }
        }

        return StagingRecoveryResult(recoveredCount: recoveredCount, failedURLs: failedURLs)
    }

    private func verifyOwnedDirectories() throws {
        try Self.verifyDirectory(originalsDirectoryURL, using: fileManager)
        try Self.verifyDirectory(stagingDirectoryURL, using: fileManager)
    }

    private func verifyRegularFile(
        at url: URL,
        missingError: ManagedAssetBlobStoreError
    ) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw missingError
        }

        let type = attributes[.type] as? FileAttributeType
        guard type != .typeSymbolicLink, type == .typeRegular else {
            throw ManagedAssetBlobStoreError.sourceIsNotARegularFile(url)
        }
    }

    private func ensureNoManagedBlobExists(for assetID: AssetID) throws {
        let shardURL = originalsDirectoryURL.appendingPathComponent(
            String(assetID.description.prefix(2)),
            isDirectory: true
        )
        guard itemExists(at: shardURL) else { return }
        try Self.verifyDirectory(shardURL, using: fileManager)

        let expectedBaseName = assetID.description
        let existing = try fileManager.contentsOfDirectory(at: shardURL, includingPropertiesForKeys: nil)
        if existing.contains(where: { $0.deletingPathExtension().lastPathComponent == expectedBaseName }) {
            throw ManagedAssetBlobStoreError.managedAssetAlreadyExists(assetID)
        }
    }

    private func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func normalizedDirectoryURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw ManagedAssetBlobStoreError.invalidDirectoryURL(url)
        }
        return url.standardizedFileURL
    }

    private static func prepareDirectory(_ url: URL, using fileManager: FileManager) throws {
        if (try? fileManager.attributesOfItem(atPath: url.path)) == nil {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try verifyDirectory(url, using: fileManager)
    }

    private static func verifyDirectory(_ url: URL, using fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            throw ManagedAssetBlobStoreError.directoryIsSymbolicLink(url)
        }
        guard type == .typeDirectory else {
            throw ManagedAssetBlobStoreError.expectedDirectory(url)
        }
    }

    private static func validatedFilenameExtension(_ value: String) throws -> String {
        let scalars = value.unicodeScalars
        let isSafe = !value.isEmpty && value.count <= 16 && scalars.allSatisfy { scalar in
            ("a"..."z").contains(Character(String(scalar)))
                || ("A"..."Z").contains(Character(String(scalar)))
                || ("0"..."9").contains(Character(String(scalar)))
        }
        guard isSafe else {
            throw ManagedAssetBlobStoreError.unsafeFilenameExtension(value)
        }
        return value
    }

    private static func validatedStorageKeyComponents(
        _ storageKey: AssetStorageKey
    ) throws -> (shard: String, filename: String) {
        let rawValue = storageKey.rawValue
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw ManagedAssetBlobStoreError.invalidStorageKey(rawValue)
        }

        let shard = String(parts[0])
        let filename = String(parts[1])
        guard shard.count == 2,
              shard.unicodeScalars.allSatisfy({ ("0"..."9").contains(Character(String($0))) || ("a"..."f").contains(Character(String($0))) }),
              filename.count >= 38,
              !filename.contains("\\") else {
            throw ManagedAssetBlobStoreError.invalidStorageKey(rawValue)
        }

        let filenameURL = URL(fileURLWithPath: filename)
        let filenameExtension = filenameURL.pathExtension
        let baseName = filenameURL.deletingPathExtension().lastPathComponent
        guard let uuid = UUID(uuidString: baseName),
              uuid.uuidString.lowercased() == baseName,
              String(baseName.prefix(2)) == shard else {
            throw ManagedAssetBlobStoreError.invalidStorageKey(rawValue)
        }
        _ = try validatedFilenameExtension(filenameExtension)
        return (shard, filename)
    }

    private static func isDirectChild(_ candidate: URL, of directory: URL) -> Bool {
        let parent = candidate.deletingLastPathComponent().standardizedFileURL
        return parent == directory.standardizedFileURL
    }

    private static func isSameOrDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let directoryComponents = directory.standardizedFileURL.pathComponents
        guard candidateComponents.count >= directoryComponents.count else { return false }
        return Array(candidateComponents.prefix(directoryComponents.count)) == directoryComponents
    }
}
