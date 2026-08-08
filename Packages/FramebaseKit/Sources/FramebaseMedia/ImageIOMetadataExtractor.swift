import CoreFoundation
import Foundation
import FramebaseDomain
import ImageIO
import UniformTypeIdentifiers

public enum ImageIOMetadataExtractorError: Error, LocalizedError, Sendable {
    case unsupportedImage(URL)
    case unreadableImage(URL)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedImage(url):
            "Unsupported image format: \(url.lastPathComponent)"
        case let .unreadableImage(url):
            "The image could not be decoded: \(url.lastPathComponent)"
        }
    }
}

/// ImageIO-backed still-image validation and normalized metadata extraction.
///
/// The extractor reads only the first image in multi-frame formats. Validation
/// creates a one-pixel thumbnail so a corrupt file cannot enter the catalog
/// merely because its container header is readable.
public struct ImageIOMetadataExtractor: MetadataExtractor, Sendable {
    public init() {}

    public func supportsImage(at url: URL) async -> Bool {
        guard let source = imageSource(for: url), CGImageSourceGetCount(source) > 0 else {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    public func extract(from url: URL) async throws -> ExtractedAssetMetadata {
        guard let source = imageSource(for: url), CGImageSourceGetCount(source) > 0 else {
            throw ImageIOMetadataExtractorError.unsupportedImage(url)
        }

        let validationOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, validationOptions as CFDictionary) != nil,
              let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ImageIOMetadataExtractorError.unreadableImage(url)
        }

        let width = integer(rawProperties[kCGImagePropertyPixelWidth])
        let height = integer(rawProperties[kCGImagePropertyPixelHeight])
        let typeIdentifier = CGImageSourceGetType(source) as String?
        let contentType = typeIdentifier.flatMap(UTType.init)
        let exifDictionary = rawProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiffDictionary = rawProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let capturedAt = date(
            exifDictionary[kCGImagePropertyExifDateTimeOriginal]
                ?? exifDictionary[kCGImagePropertyExifDateTimeDigitized]
                ?? tiffDictionary[kCGImagePropertyTIFFDateTime]
        )

        let exif = EXIFMetadata(
            capturedAt: capturedAt,
            cameraMake: string(tiffDictionary[kCGImagePropertyTIFFMake]),
            cameraModel: string(tiffDictionary[kCGImagePropertyTIFFModel]),
            lensModel: string(exifDictionary[kCGImagePropertyExifLensModel]),
            iso: number(firstArrayValue(exifDictionary[kCGImagePropertyExifISOSpeedRatings])),
            focalLength: number(exifDictionary[kCGImagePropertyExifFocalLength]),
            aperture: number(exifDictionary[kCGImagePropertyExifFNumber]),
            exposureTime: number(exifDictionary[kCGImagePropertyExifExposureTime]),
            orientation: integer(rawProperties[kCGImagePropertyOrientation])
        )

        let excludedKeys: Set<String> = [
            kCGImagePropertyExifDictionary as String,
            kCGImagePropertyTIFFDictionary as String,
            kCGImagePropertyPixelWidth as String,
            kCGImagePropertyPixelHeight as String,
            kCGImagePropertyColorModel as String,
            kCGImagePropertyDepth as String,
            kCGImagePropertyHasAlpha as String,
            kCGImagePropertyOrientation as String
        ]
        let otherProperties = rawProperties.reduce(into: [String: MetadataValue]()) { result, pair in
            let key = pair.key as String
            guard !excludedKeys.contains(key), let value = metadataValue(pair.value) else { return }
            result[key] = value
        }

        let metadata = AssetMetadata(
            file: FileMetadata(
                filenameExtension: url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased(),
                typeIdentifier: typeIdentifier,
                mimeType: contentType?.preferredMIMEType
            ),
            image: ImageMetadata(
                pixelWidth: width,
                pixelHeight: height,
                colorModel: string(rawProperties[kCGImagePropertyColorModel]),
                bitDepth: integer(rawProperties[kCGImagePropertyDepth]),
                hasAlpha: boolean(rawProperties[kCGImagePropertyHasAlpha])
            ),
            exif: exif == EXIFMetadata() ? nil : exif,
            tiff: metadataDictionary(tiffDictionary),
            otherImageIO: otherProperties
        )

        return ExtractedAssetMetadata(
            width: width,
            height: height,
            createdAt: capturedAt,
            metadata: metadata
        )
    }

    private func imageSource(for url: URL) -> CGImageSource? {
        guard url.isFileURL else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        return CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary)
    }
}

private func string(_ value: Any?) -> String? {
    value as? String
}

private func integer(_ value: Any?) -> Int? {
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? Int { return value }
    return nil
}

private func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? Double { return value }
    return nil
}

private func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber else { return value as? Bool }
    return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : nil
}

private func firstArrayValue(_ value: Any?) -> Any? {
    (value as? [Any])?.first ?? value
}

private func date(_ value: Any?) -> Date? {
    if let date = value as? Date { return date }
    guard let text = value as? String else { return nil }

    let iso = ISO8601DateFormatter()
    if let parsed = iso.date(from: text) { return parsed }

    for format in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        if let parsed = formatter.date(from: text) { return parsed }
    }
    return nil
}

private func metadataDictionary(_ dictionary: [CFString: Any]) -> [String: MetadataValue] {
    dictionary.reduce(into: [:]) { result, pair in
        if let value = metadataValue(pair.value) {
            result[pair.key as String] = value
        }
    }
}

private func metadataValue(_ value: Any) -> MetadataValue? {
    if let value = value as? String { return .string(value) }
    if let value = value as? Date { return .date(value) }
    if let value = value as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return .boolean(value.boolValue) }
        let doubleValue = value.doubleValue
        if doubleValue.rounded() == doubleValue { return .integer(value.int64Value) }
        return .number(doubleValue)
    }
    if let values = value as? [Any] {
        return .array(values.compactMap(metadataValue))
    }
    if let dictionary = value as? [String: Any] {
        return .object(dictionary.compactMapValues(metadataValue))
    }
    if let dictionary = value as? [CFString: Any] {
        return .object(metadataDictionary(dictionary))
    }
    return nil
}
