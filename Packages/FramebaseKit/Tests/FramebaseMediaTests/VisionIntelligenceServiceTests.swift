import CoreGraphics
import Foundation
import FramebaseDomain
import FramebaseMedia
import ImageIO
import Testing

@Suite("Local Vision intelligence")
struct VisionIntelligenceServiceTests {
    @Test("Vision analyzes a bounded synthetic derivative with provenance")
    func boundedDerivativeAndOCR() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writePNG(at: directory.appendingPathComponent("fixture.png"), width: 2_400, height: 1_200)
        let assetID = AssetID()
        let results = try await VisionIntelligenceService().analyze(try AssetAnalysisRequest(assetID: assetID, kinds: [.ocr]), sourceURL: source)
        let result = try #require(results.first)
        #expect(result.assetID == assetID)
        #expect(result.kind == .ocr)
        #expect(result.provenance.engine == "Apple Vision")
        #expect(result.provenance.derivativeMaximumPixelDimension == 1_600)
        #expect(result.provenance.derivativeSHA256.count == 64)
    }

    private func writePNG(at url: URL, width: Int, height: Int) throws -> URL {
        let bytesPerRow = width * 4
        let pixels = Data(repeating: 0x7f, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
