import CryptoKit
import FramebaseDomain
import Foundation

public enum FramebaseMediaFoundation {
    public static let thumbnailCacheFormatVersion = 1
    public static let defaultMemoryCacheBytes = 256 * 1_024 * 1_024
    public static let defaultDiskCacheBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

    /// Maximum pixel size of the throwaway decode that proves an import
    /// candidate contains readable pixels.
    ///
    /// ImageIO returns no thumbnail at one or two pixels for some perfectly
    /// valid JPEGs — notably iPhone captures carrying both a JFIF APP0 segment
    /// and EXIF — so a smaller value silently rejects real photographs.
    public static let importValidationMaxPixelSize = 32
}

public struct VerifiedExportReceipt: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let sha256: String
    public let byteSize: Int64
}

public enum VerifiedExportError: Error, Equatable, Sendable {
    case sourceUnavailable, destinationAlreadyExists, invalidDestination, checksumMismatch
}

public actor VerifiedExportService {
    public init() {}

    public func export(sourceURL: URL, to destinationURL: URL) throws -> VerifiedExportReceipt {
        let fileManager = FileManager.default
        guard sourceURL.isFileURL, fileManager.fileExists(atPath: sourceURL.path) else { throw VerifiedExportError.sourceUnavailable }
        guard destinationURL.isFileURL, !destinationURL.hasDirectoryPath,
              !fileManager.fileExists(atPath: destinationURL.path),
              fileManager.fileExists(atPath: destinationURL.deletingLastPathComponent().path) else {
            throw VerifiedExportError.invalidDestination
        }
        let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent(".framebase-export-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: sourceURL, to: temporary)
        let sourceDigest = try digest(sourceURL)
        let exportDigest = try digest(temporary)
        guard sourceDigest == exportDigest else { throw VerifiedExportError.checksumMismatch }
        try fileManager.moveItem(at: temporary, to: destinationURL)
        return VerifiedExportReceipt(sourceURL: sourceURL, destinationURL: destinationURL, sha256: sourceDigest.0, byteSize: sourceDigest.1)
    }

    private func digest(_ url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteSize: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteSize += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteSize)
    }
}
