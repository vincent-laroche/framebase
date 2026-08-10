import CoreGraphics
import CoreText
import Foundation
import FramebaseDomain
import FramebaseMedia
import ImageIO
import Testing

@Suite("Local Vision intelligence", .serialized)
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

    @Test("Vision recognizes fixture text with geometry and provenance")
    func recognizesFixtureText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeTextPNG(at: directory.appendingPathComponent("text.png"), text: "FRAMEBASE")
        let results = try await VisionIntelligenceService().analyze(
            try AssetAnalysisRequest(assetID: AssetID(), kinds: [.ocr]),
            sourceURL: source
        )
        let result = try #require(results.first)
        guard case let .ocr(lines) = result.payload else { Issue.record("Expected OCR payload"); return }
        #expect(lines.contains { $0.text.uppercased().contains("FRAMEBASE") })
        #expect(lines.allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 })
        #expect(lines.allSatisfy { $0.boundingBox.width > 0 && $0.boundingBox.height > 0 })
    }

    @Test("Vision returns a bounded result for every local analysis kind")
    func returnsResultsForAllLocalKinds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writePNG(at: directory.appendingPathComponent("fixture.png"), width: 800, height: 600)
        let results = try await VisionIntelligenceService().analyze(
            try AssetAnalysisRequest(assetID: AssetID(), kinds: Set(AnalysisKind.allCases)),
            sourceURL: source
        )

        #expect(Set(results.map(\.kind)) == Set(AnalysisKind.allCases))
        #expect(results.allSatisfy { $0.status == .succeeded })
        #expect(results.allSatisfy { $0.provenance.derivativeMaximumPixelDimension <= 1_600 })
    }

    @Test("Vision honors pre-start cancellation")
    func honorsPreStartCancellation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writePNG(at: directory.appendingPathComponent("fixture.png"), width: 800, height: 600)
        let service = VisionIntelligenceService()
        let cancelled = Task {
            try await service.analyze(
                try AssetAnalysisRequest(assetID: AssetID(), kinds: [.ocr]),
                sourceURL: source
            )
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

    private func writeTextPNG(at url: URL, text: String) throws -> URL {
        let width = 2_400
        let height = 900
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 230, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 160, y: 330)
        CTLineDraw(line, context)
        return try writePNG(context: context, at: url)
    }

    private func writePNG(context: CGContext, at url: URL) throws -> URL {
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
