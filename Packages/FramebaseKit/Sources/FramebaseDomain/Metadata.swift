import Foundation

public indirect enum MetadataValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case date(Date)
    case array([MetadataValue])
    case object([String: MetadataValue])
    case null
}

public struct AssetMetadata: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var file: FileMetadata
    public var image: ImageMetadata
    public var exif: EXIFMetadata?
    public var tiff: [String: MetadataValue]
    public var otherImageIO: [String: MetadataValue]

    public init(
        version: Int = AssetMetadata.currentVersion,
        file: FileMetadata = .init(),
        image: ImageMetadata = .init(),
        exif: EXIFMetadata? = nil,
        tiff: [String: MetadataValue] = [:],
        otherImageIO: [String: MetadataValue] = [:]
    ) {
        self.version = version
        self.file = file
        self.image = image
        self.exif = exif
        self.tiff = tiff
        self.otherImageIO = otherImageIO
    }
}

public struct FileMetadata: Codable, Equatable, Sendable {
    public var filenameExtension: String?
    public var typeIdentifier: String?
    public var mimeType: String?

    public init(
        filenameExtension: String? = nil,
        typeIdentifier: String? = nil,
        mimeType: String? = nil
    ) {
        self.filenameExtension = filenameExtension
        self.typeIdentifier = typeIdentifier
        self.mimeType = mimeType
    }
}

public struct ImageMetadata: Codable, Equatable, Sendable {
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var colorModel: String?
    public var bitDepth: Int?
    public var hasAlpha: Bool?

    public init(
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        colorModel: String? = nil,
        bitDepth: Int? = nil,
        hasAlpha: Bool? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.colorModel = colorModel
        self.bitDepth = bitDepth
        self.hasAlpha = hasAlpha
    }
}

public struct EXIFMetadata: Codable, Equatable, Sendable {
    public var capturedAt: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var iso: Double?
    public var focalLength: Double?
    public var aperture: Double?
    public var exposureTime: Double?
    public var orientation: Int?

    public init(
        capturedAt: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        iso: Double? = nil,
        focalLength: Double? = nil,
        aperture: Double? = nil,
        exposureTime: Double? = nil,
        orientation: Int? = nil
    ) {
        self.capturedAt = capturedAt
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.focalLength = focalLength
        self.aperture = aperture
        self.exposureTime = exposureTime
        self.orientation = orientation
    }
}
