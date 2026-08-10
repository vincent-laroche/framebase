import CryptoKit
import Foundation
import FramebaseDomain

public enum AssetExportError: Error, Equatable, Sendable {
    case destinationMustBeDirectory
    case noAssets
    case exportedBytesDidNotVerify(AssetID)
}

/// Copies immutable managed originals to an explicit user-selected directory.
/// It never changes catalog placement, storage keys, or managed bytes. The
/// adjacent manifest hashes every output file so the catalog can retain a
/// destination-independent receipt without storing a private filesystem path.
public actor AssetExporter {
    private let blobStore: any AssetBlobStore
    private let fileManager: FileManager

    public init(blobStore: any AssetBlobStore, fileManager: FileManager = .default) {
        self.blobStore = blobStore
        self.fileManager = fileManager
    }

    public func export(_ assets: [Asset], to destinationDirectoryURL: URL) async throws -> (manifest: AssetExportManifest, receipt: AssetExportReceipt) {
        guard !assets.isEmpty else { throw AssetExportError.noAssets }
        let destination = destinationDirectoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AssetExportError.destinationMustBeDirectory
        }

        let orderedAssets = assets.sorted { $0.id.description < $1.id.description }
        var entries: [AssetExportManifestEntry] = []
        for asset in orderedAssets {
            let sourceURL = try await blobStore.resolve(asset.storageKey)
            let outputName = "\(asset.id.description)-\(safeFilename(asset.filename))"
            let outputURL = destination.appendingPathComponent(outputName, isDirectory: false)
            try fileManager.copyItem(at: sourceURL, to: outputURL)
            let sourceDigest = try sha256(of: sourceURL)
            let outputDigest = try sha256(of: outputURL)
            guard sourceDigest.sha256 == outputDigest.sha256, sourceDigest.byteSize == outputDigest.byteSize else {
                try? fileManager.removeItem(at: outputURL)
                throw AssetExportError.exportedBytesDidNotVerify(asset.id)
            }
            entries.append(AssetExportManifestEntry(assetID: asset.id, filename: outputName, byteSize: outputDigest.byteSize, sha256: outputDigest.sha256))
        }

        let receiptID = ExportReceiptID()
        let manifest = AssetExportManifest(assets: entries)
        let manifestURL = destination.appendingPathComponent("framebase-export-\(receiptID.description).manifest.json", isDirectory: false)
        let temporaryManifestURL = destination.appendingPathComponent(".framebase-export-\(UUID().uuidString.lowercased()).json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: temporaryManifestURL, options: .atomic)
        try fileManager.moveItem(at: temporaryManifestURL, to: manifestURL)
        let manifestDigest = try sha256(of: manifestURL)
        let receipt = AssetExportReceipt(id: receiptID, manifestSHA256: manifestDigest.sha256, assetIDs: orderedAssets.map(\.id))
        return (manifest, receipt)
    }

    private func safeFilename(_ value: String) -> String {
        let result = value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        return result.isEmpty ? "asset" : result
    }

    private func sha256(of url: URL) throws -> (sha256: String, byteSize: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteSize: Int64 = 0
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
            byteSize += Int64(data.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteSize)
    }
}
