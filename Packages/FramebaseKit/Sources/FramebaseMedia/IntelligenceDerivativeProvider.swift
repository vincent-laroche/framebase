import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct AnalysisDerivative: Sendable {
    public let data: Data
    public let sha256: String
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public enum IntelligenceDerivativeError: Error, Sendable { case decodeFailed, encodeFailed }

public struct IntelligenceDerivativeProvider: Sendable {
    public static let maximumPixelDimension = 1_600

    public init() {}

    public func makeDerivative(from sourceURL: URL) throws -> AnalysisDerivative {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw IntelligenceDerivativeError.decodeFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw IntelligenceDerivativeError.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw IntelligenceDerivativeError.encodeFailed }
        let encoded = data as Data
        return AnalysisDerivative(data: encoded, sha256: SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(), pixelWidth: image.width, pixelHeight: image.height)
    }
}
