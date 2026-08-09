import CryptoKit
import Foundation

public struct FileDigest: Equatable, Sendable {
    public let sha256: String
    public let byteSize: Int64

    public init(sha256: String, byteSize: Int64) {
        self.sha256 = sha256
        self.byteSize = byteSize
    }
}

/// Reads in bounded chunks on its own actor, keeping checksum work off UI state
/// and avoiding a full-original `Data(contentsOf:)` allocation.
public actor FileDigestService {
    public init() {}

    public func digest(at url: URL) throws -> FileDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteSize: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteSize += Int64(chunk.count)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileDigest(sha256: hash, byteSize: byteSize)
    }
}
