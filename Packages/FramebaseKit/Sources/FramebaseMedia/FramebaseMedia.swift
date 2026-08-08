import FramebaseDomain

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
