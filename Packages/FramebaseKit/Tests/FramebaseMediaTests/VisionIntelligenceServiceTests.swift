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

    @Test("Vision returns a bounded result for every active local analysis kind")
    func returnsResultsForAllLocalKinds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writePNG(at: directory.appendingPathComponent("fixture.png"), width: 800, height: 600)
        let results = try await VisionIntelligenceService().analyze(
            try AssetAnalysisRequest(assetID: AssetID(), kinds: AnalysisKind.activeLocalVisionKinds),
            sourceURL: source
        )

        #expect(Set(results.map(\.kind)) == AnalysisKind.activeLocalVisionKinds)
        #expect(results.allSatisfy { $0.status == .succeeded })
        #expect(results.allSatisfy { $0.provenance.derivativeMaximumPixelDimension <= 1_600 })
    }

    @Test("Vision captures QR payload details from a synthetic fixture")
    func capturesSyntheticQRDetails() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeQRPNG(at: directory.appendingPathComponent("qr.png"))
        let results = try await VisionIntelligenceService().analyze(
            try AssetAnalysisRequest(assetID: AssetID(), kinds: [.barcode]),
            sourceURL: source
        )
        let result = try #require(results.first)
        guard case let .barcode(count, observations) = result.payload else {
            Issue.record("Expected barcode payload")
            return
        }
        #expect(count == 1)
        #expect(observations.count == 1)
        #expect(observations.first?.symbology.lowercased().contains("qr") == true)
        #expect(observations.first?.payload == "FRAMEBASE-QR-FIXTURE-2026")
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

    /// A precomputed, synthetic QR matrix for `FRAMEBASE-QR-FIXTURE-2026`.
    /// Keeping the matrix in source avoids a generator dependency and means no
    /// personal barcode content is ever used by this test.
    private func writeQRPNG(at url: URL) throws -> URL {
        let modules = [
            "1111111010100010001111111", "1000001001001000101000001", "1011101010011000101011101",
            "1011101010101101101011101", "1011101001001010001011101", "1000001010001001001000001",
            "1111111010101010101111111", "0000000011010101100000000", "0101011111100010111101101",
            "0111110001011101100101001", "0000001011011111101010000", "1000110101111101110001111",
            "0110011110110011100100001", "0111010111100011011011111", "1011111000000101001100100",
            "0110110010010000000000001", "1100101011101111111110000", "0000000011110010100010101",
            "1111111011101010101010000", "1000001011111001100010010", "1011101000101111111111000",
            "1011101011010100001001010", "1011101001011100111100101", "1000001011110010100001101",
            "1111111001001011110101101"
        ]
        let quietZone = 4
        let moduleSize = 20
        let dimension = (modules.count + quietZone * 2) * moduleSize
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for (row, modulesInRow) in modules.enumerated() {
            for (column, module) in modulesInRow.enumerated() where module == "1" {
                context.fill(CGRect(
                    x: (column + quietZone) * moduleSize,
                    y: (row + quietZone) * moduleSize,
                    width: moduleSize,
                    height: moduleSize
                ))
            }
        }
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
