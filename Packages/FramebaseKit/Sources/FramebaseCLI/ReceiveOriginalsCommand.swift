import Foundation
import FramebaseAPIClient
import FramebaseCatalog
import FramebaseDomain
import FramebaseMedia

extension FramebaseCLI {
    static func receiveOriginals(arguments: [String]) async throws -> String {
        var values = arguments
        let libraryPath = try flagValue("--library", in: &values)
        let spaceName = try flagValue("--space", in: &values)
        let api = try flagValue("--api", in: &values)
        let token = try flagValue("--token", in: &values)
        guard let libraryPath else { throw FramebaseCLIError.missingLibraryPath }
        guard let spaceName, let space = LibrarySpace(rawValue: spaceName) else { throw FramebaseCLIError.missingLibrarySpace }
        guard !values.isEmpty else { throw FramebaseCLIError.missingReceiveSource }
        if let api {
            guard let url = URL(string: api), url.host != nil else { throw FramebaseCLIError.unexpectedArgument("--api") }
            try OriginalReceiveAPIPolicy.validate(url)
        }
        switch (api, token) {
        case (nil, nil):
            break
        case let (api?, token?) where !token.isEmpty && !api.isEmpty:
            break
        default:
            throw OriginalReceiveError.cloudCredentialsIncomplete
        }
        let sources = values.map { URL(fileURLWithPath: $0) }

        let package = try FramebaseLibraryPackage(rootURL: URL(fileURLWithPath: libraryPath, isDirectory: true))
        let catalogExists = FileManager.default.fileExists(atPath: package.catalogDatabaseURL.path)
        if !catalogExists, !package.matches(space) {
            throw OriginalReceiveError.librarySpaceMismatch(existing: nil, requested: space)
        }
        try package.prepare()
        let catalog = try CatalogDatabase(catalogURL: package.catalogDatabaseURL)
        let blobStore = try ManagedAssetBlobStore(
            originalsDirectoryURL: package.originalsDirectoryURL,
            stagingDirectoryURL: package.stagingDirectoryURL
        )
        let recovery = try await blobStore.recoverStaging()
        if !recovery.failedURLs.isEmpty {
            throw OriginalReceiveError.stagingRecoveryFailed
        }
        let receive = LibraryOriginalReceive(
            space: space,
            catalog: catalog,
            blobStore: blobStore,
            libraryRootURL: package.rootURL
        )
        let receipts = try await receive.receive(sources: sources)
        let uploader = try makeUploader(api: api, token: token)
        var items: [OriginalReceiveItem] = []
        var failures: [String] = []
        for receipt in receipts {
            var blob: OriginalBlobDisposition = .localOnly
            if let uploader {
                do {
                    blob = try await uploader.store(OriginalCloudUpload(
                        fileURL: receipt.fileURL,
                        sha256: receipt.sha256,
                        byteSize: receipt.byteSize,
                        mediaType: receipt.mediaType,
                        originalExtension: receipt.originalExtension,
                        assetID: receipt.asset.id.description,
                        displayName: receipt.displayName,
                        librarySpace: space.rawValue
                    ))
                } catch {
                    failures.append(receipt.filename)
                }
            }
            items.append(OriginalReceiveItem(
                filename: receipt.filename,
                assetID: receipt.asset.id.description,
                disposition: receipt.disposition,
                blob: blob
            ))
        }
        let bucket = uploader == nil ? "local" : OriginalR2Endpoint.bucketName
        return try encode(OriginalReceiveReport(librarySpace: space.rawValue, bucket: bucket, items: items, failureFilenames: failures))
    }

    private static func makeUploader(api: String?, token: String?) throws -> OriginalR2Store? {
        switch (api, token) {
        case (nil, nil):
            return nil
        case let (api?, token?) where !token.isEmpty:
            guard let url = URL(string: api), url.host != nil else { throw FramebaseCLIError.unexpectedArgument("--api") }
            try OriginalReceiveAPIPolicy.validate(url)
            let session = DeviceSession(
                deviceID: "receive-originals",
                token: token,
                expiresAt: Date().addingTimeInterval(50 * 60)
            )
            let client = FramebaseAPIClient(
                configuration: FramebaseAPIConfiguration(baseURL: url),
                sessionStore: InMemoryDeviceSessionStore(session: session)
            )
            return OriginalR2Store(transport: client)
        default:
            throw OriginalReceiveError.cloudCredentialsIncomplete
        }
    }
}
