import FramebaseMedia
import Foundation
import Testing

@Suite("Media foundation")
struct MediaFoundationTests {
    @Test("Cache defaults match the implementation plan")
    func cacheDefaults() {
        #expect(FramebaseMediaFoundation.defaultMemoryCacheBytes == 268_435_456)
        #expect(FramebaseMediaFoundation.defaultDiskCacheBytes == 5_368_709_120)
        #expect(FramebaseMediaFoundation.thumbnailCacheFormatVersion == 1)
    }

    @Test("Verified export copies bytes without modifying the source")
    func verifiedExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        let destination = root.appendingPathComponent("export.jpg")
        let bytes = Data([0, 1, 2, 3, 4, 255])
        try bytes.write(to: source)

        let receipt = try await VerifiedExportService().export(sourceURL: source, to: destination)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(receipt.destinationURL == destination)
        #expect(receipt.byteSize == Int64(bytes.count))
    }
}
