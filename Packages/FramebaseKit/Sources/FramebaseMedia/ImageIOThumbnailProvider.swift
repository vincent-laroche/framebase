import CoreGraphics
import Foundation
import FramebaseDomain
import ImageIO
import UniformTypeIdentifiers

public enum ImageIOThumbnailProviderError: Error, LocalizedError, Sendable {
    case invalidCacheDirectory(URL)
    case cacheDirectoryIsSymbolicLink(URL)
    case sourceDecodeFailed(AssetStorageKey)
    case thumbnailEncodeFailed(AssetStorageKey)

    public var errorDescription: String? {
        switch self {
        case let .invalidCacheDirectory(url):
            "The thumbnail cache directory is invalid: \(url.path)"
        case let .cacheDirectoryIsSymbolicLink(url):
            "The thumbnail cache directory cannot be a symbolic link: \(url.path)"
        case let .sourceDecodeFailed(key):
            "The managed image could not be decoded: \(key.rawValue)"
        case let .thumbnailEncodeFailed(key):
            "Framebase could not encode a thumbnail for: \(key.rawValue)"
        }
    }
}

private final class ThumbnailCacheBox: NSObject, @unchecked Sendable {
    let payload: ThumbnailPayload

    init(_ payload: ThumbnailPayload) {
        self.payload = payload
    }
}

/// ImageIO downsampling with cost-bounded memory caching and LRU disk caching.
public actor ImageIOThumbnailProvider: ThumbnailProvider {
    private enum Kind: String {
        case thumbnail
        case preview
    }

    public let cacheDirectoryURL: URL

    private let blobStore: any AssetBlobStore
    private let fileManager: FileManager
    private let diskCacheByteLimit: Int64
    private let memoryCache = NSCache<NSString, ThumbnailCacheBox>()
    private var cancelledRequestIDs: Set<ThumbnailRequestID> = []

    public init(
        blobStore: any AssetBlobStore,
        cacheDirectoryURL: URL,
        memoryCacheByteLimit: Int = FramebaseMediaFoundation.defaultMemoryCacheBytes,
        diskCacheByteLimit: Int64 = FramebaseMediaFoundation.defaultDiskCacheBytes,
        fileManager: FileManager = .default
    ) throws {
        guard cacheDirectoryURL.isFileURL, cacheDirectoryURL.hasDirectoryPath,
              memoryCacheByteLimit >= 0, diskCacheByteLimit >= 0 else {
            throw ImageIOThumbnailProviderError.invalidCacheDirectory(cacheDirectoryURL)
        }

        let cache = cacheDirectoryURL.standardizedFileURL
        if fileManager.fileExists(atPath: cache.path) {
            let attributes = try fileManager.attributesOfItem(atPath: cache.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ImageIOThumbnailProviderError.cacheDirectoryIsSymbolicLink(cache)
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ImageIOThumbnailProviderError.invalidCacheDirectory(cache)
            }
        } else {
            try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        }

        self.blobStore = blobStore
        self.cacheDirectoryURL = cache
        self.fileManager = fileManager
        self.diskCacheByteLimit = diskCacheByteLimit
        memoryCache.totalCostLimit = memoryCacheByteLimit
    }

    public func thumbnail(for request: ThumbnailRequest) async throws -> ThumbnailPayload {
        try await payload(for: request, kind: .thumbnail)
    }

    public func preview(for request: ThumbnailRequest) async throws -> ThumbnailPayload {
        try await payload(for: request, kind: .preview)
    }

    public func cancel(requestID: ThumbnailRequestID) async {
        cancelledRequestIDs.insert(requestID)
    }

    public func clearDerivedCache() async throws {
        memoryCache.removeAllObjects()
        cancelledRequestIDs.removeAll()
        for file in try regularCacheFiles() {
            try fileManager.removeItem(at: file)
        }
    }

    private func regularCacheFiles() throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func payload(for request: ThumbnailRequest, kind: Kind) async throws -> ThumbnailPayload {
        defer { cancelledRequestIDs.remove(request.id) }
        try checkCancellation(request.id)

        let key = cacheKey(for: request, kind: kind)
        if let cached = memoryCache.object(forKey: key as NSString)?.payload {
            return cached
        }

        let diskURL = cacheURL(for: key, assetID: request.fingerprint.assetID)
        if let diskPayload = try loadDiskPayload(at: diskURL) {
            try checkCancellation(request.id)
            memoryCache.setObject(
                ThumbnailCacheBox(diskPayload),
                forKey: key as NSString,
                cost: diskPayload.encodedData.count
            )
            return diskPayload
        }

        let sourceURL = try await blobStore.resolve(request.storageKey)
        try checkCancellation(request.id)
        let generated = try generatePayload(from: sourceURL, request: request)
        try checkCancellation(request.id)
        try persist(generated, at: diskURL)
        memoryCache.setObject(
            ThumbnailCacheBox(generated),
            forKey: key as NSString,
            cost: generated.encodedData.count
        )
        try evictDiskCacheIfNeeded()
        return generated
    }

    private func generatePayload(from sourceURL: URL, request: ThumbnailRequest) throws -> ThumbnailPayload {
        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ImageIOThumbnailProviderError.sourceDecodeFailed(request.storageKey)
        }

        let target = request.target
        let maxDimension = max(
            Int((Double(target.width) * target.displayScale).rounded(.up)),
            Int((Double(target.height) * target.displayScale).rounded(.up))
        )
        guard maxDimension > 0 else {
            throw ImageIOThumbnailProviderError.sourceDecodeFailed(request.storageKey)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageIOThumbnailProviderError.sourceDecodeFailed(request.storageKey)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageIOThumbnailProviderError.thumbnailEncodeFailed(request.storageKey)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageIOThumbnailProviderError.thumbnailEncodeFailed(request.storageKey)
        }

        return ThumbnailPayload(
            encodedData: data as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private func loadDiskPayload(at url: URL) throws -> ThumbnailPayload? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else {
                try fileManager.removeItem(at: url)
                return nil
            }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return ThumbnailPayload(encodedData: data, pixelWidth: width, pixelHeight: height)
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    private func persist(_ payload: ThumbnailPayload, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try payload.encodedData.write(to: url, options: .atomic)
    }

    private func evictDiskCacheIfNeeded() throws {
        guard diskCacheByteLimit >= 0,
              let enumerator = fileManager.enumerator(
                at: cacheDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        var entries: [(url: URL, size: Int64, modifiedAt: Date)] = []
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }

        guard totalBytes > diskCacheByteLimit else { return }
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            try fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
            if totalBytes <= diskCacheByteLimit { break }
        }
    }

    private func cacheKey(for request: ThumbnailRequest, kind: Kind) -> String {
        let target = request.target
        return [
            "v\(FramebaseMediaFoundation.thumbnailCacheFormatVersion)",
            kind.rawValue,
            request.fingerprint.assetID.description,
            String(request.fingerprint.fileSize),
            String(request.fingerprint.modifiedAtMilliseconds),
            "\(target.width)x\(target.height)",
            String(target.displayScale.bitPattern, radix: 16)
        ].joined(separator: "-")
    }

    private func cacheURL(for key: String, assetID: AssetID) -> URL {
        let shard = String(assetID.description.prefix(2))
        return cacheDirectoryURL
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent("\(key).png", isDirectory: false)
    }

    private func checkCancellation(_ requestID: ThumbnailRequestID) throws {
        if Task.isCancelled || cancelledRequestIDs.contains(requestID) {
            throw CancellationError()
        }
    }
}
