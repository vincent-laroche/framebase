import FramebaseMedia
import Testing

@Suite("Media foundation")
struct MediaFoundationTests {
    @Test("Cache defaults match the implementation plan")
    func cacheDefaults() {
        #expect(FramebaseMediaFoundation.defaultMemoryCacheBytes == 268_435_456)
        #expect(FramebaseMediaFoundation.defaultDiskCacheBytes == 5_368_709_120)
        #expect(FramebaseMediaFoundation.thumbnailCacheFormatVersion == 1)
    }
}
