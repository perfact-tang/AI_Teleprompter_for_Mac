import XCTest
import CoreImage
import AVFoundation
import Vision
import ImageIO
@testable import TeleprompterCore

final class AdvancedAppearanceTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let face = BeautyFace(bounds: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.55),
        leftEye: CGPoint(x: 0.4, y: 0.625), rightEye: CGPoint(x: 0.6, y: 0.625), mouth: CGPoint(x: 0.5, y: 0.35),
        nose: CGPoint(x: 0.5, y: 0.475), noseTip: CGPoint(x: 0.5, y: 0.42))
    private func gradient() -> CIImage {
        // An analytic chart avoids bitmap scanline orientation ambiguity.
        let kernel = CIColorKernel(source: "kernel vec4 chart() { vec2 p = destCoord(); return vec4(p.x / 400.0, p.y / 400.0, mod(p.x + p.y, 31.0) / 50.0 + 0.1, 1.0); }")!
        return kernel.apply(extent: CGRect(x: 0, y: 0, width: 400, height: 400), arguments: [])!
    }
    private func pixel(_ image: CIImage, x: Int, y: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &result, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return result
    }
    func testEveryReshapeHasIndependentPixelEffectInItsRegion() throws {
        let source = gradient(), processor = BeautyProcessor(context: context)
        XCTAssertTrue(processor.isAvailable)
        let probes: [FaceAdjustment: (Int, Int)] = [.smallFace: (245, 190), .smallHead: (245, 330), .narrowFace: (245, 190),
            .skull: (200, 332), .shortFace: (200, 120), .bigEyes: (250, 250), .noseWidth: (210, 190), .noseTip: (208, 168), .mouthShape: (210, 140)]
        var signatures: [String: [Float]] = [:]
        for control in FaceAdjustment.allCases {
            var a = FaceAdjustments(); a[control] = 1
            let image = try XCTUnwrap(processor.filteredImage(source, face: face, settings: BeautySettings(enabled: true, smoothing: 0, slimming: 0, adjustments: a)))
            XCTAssertEqual(image.extent, source.extent)
            let probe = try XCTUnwrap(probes[control])
            let before = pixel(source, x: probe.0, y: probe.1), after = pixel(image, x: probe.0, y: probe.1)
            XCTAssertGreaterThan(abs(after[0] - before[0]) + abs(after[1] - before[1]), 0.0005, "\(control.title) must move pixels in the intended region")
            let corner = pixel(image, x: 2, y: 2)
            XCTAssertEqual(corner[0], pixel(source, x: 2, y: 2)[0], accuracy: 0.0001, "\(control.title) must preserve distant background")
            signatures[control.rawValue] = probes.values.sorted { $0.0 < $1.0 }.flatMap { pixel(image, x: $0.0, y: $0.1).prefix(2) }
        }
        let keys = Array(signatures.keys)
        for i in keys.indices { for j in keys.indices where j > i {
            XCTAssertNotEqual(signatures[keys[i]], signatures[keys[j]], "Independent controls must not alias the same warp")
        } }
    }
    func testReshapeDirectionsAndMouthSignedRange() throws {
        let source = gradient(), processor = BeautyProcessor(context: context)
        func changed(_ c: FaceAdjustment, amount: Double = 1) throws -> CIImage {
            var a = FaceAdjustments(); a[c] = amount
            return try XCTUnwrap(processor.filteredImage(source, face: face, settings: BeautySettings(enabled: true, smoothing: 0, slimming: 0, adjustments: a)))
        }
        XCTAssertGreaterThan(pixel(try changed(.narrowFace), x: 245, y: 190)[0], pixel(source, x: 245, y: 190)[0])
        XCTAssertEqual(pixel(try changed(.narrowFace), x: 245, y: 190)[1], pixel(source, x: 245, y: 190)[1], accuracy: 0.0001)
        XCTAssertLessThan(pixel(try changed(.bigEyes), x: 250, y: 250)[0], pixel(source, x: 250, y: 250)[0])
        XCTAssertGreaterThan(pixel(try changed(.noseWidth), x: 210, y: 190)[0], pixel(source, x: 210, y: 190)[0])
        XCTAssertLessThan(pixel(try changed(.skull), x: 200, y: 332)[1], pixel(source, x: 200, y: 332)[1])
        XCTAssertLessThan(pixel(try changed(.shortFace), x: 200, y: 120)[1], pixel(source, x: 200, y: 120)[1])
        let original = pixel(source, x: 210, y: 140)[0]
        XCTAssertLessThan(pixel(try changed(.mouthShape), x: 210, y: 140)[0], original)
        XCTAssertGreaterThan(pixel(try changed(.mouthShape, amount: -1), x: 210, y: 140)[0], original)
    }
    func testAllZeroAndDisabledFaceRemainIdentity() throws {
        let source = gradient(), processor = BeautyProcessor(context: context)
        var a = FaceAdjustments(); for c in FaceAdjustment.allCases { a[c] = 1 }
        for settings in [BeautySettings(enabled: true, smoothing: 0, slimming: 0), BeautySettings(enabled: false, adjustments: a)] {
            let result = try XCTUnwrap(processor.filteredImage(source, face: face, settings: settings))
            XCTAssertEqual(pixel(result, x: 245, y: 190), pixel(source, x: 245, y: 190))
        }
    }
    func testExtremeCombinationStaysFiniteAndWithinDisplacementLimit() throws {
        var a = FaceAdjustments(); for c in FaceAdjustment.allCases { a[c] = 1 }
        let source = gradient()
        let result = try XCTUnwrap(BeautyProcessor(context: context).filteredImage(source, face: face, settings: BeautySettings(enabled: true, smoothing: 0, slimming: 1, adjustments: a)))
        for x in stride(from: 50, to: 350, by: 30) { for y in stride(from: 50, to: 350, by: 30) {
            let value = pixel(result, x: x, y: y), before = pixel(source, x: x, y: y)
            XCTAssertTrue(value.allSatisfy { $0.isFinite })
            let displacement = hypot(Double(value[0] - before[0]) * 400 / 200, Double(value[1] - before[1]) * 400 / 220)
            XCTAssertLessThanOrEqual(displacement, 0.183)
        } }
    }
    func testPresetsHaveDistinctLooksAndStrengthIsContinuous() {
        let source = gradient(), probe = (160, 170)
        var values: [[Float]] = []
        for preset in ColorPreset.allCases where preset != .none {
            let zero = ColorGrading.apply(source, settings: ColorGradingSettings(preset: preset, intensity: 0))
            XCTAssertEqual(pixel(zero, x: probe.0, y: probe.1), pixel(source, x: probe.0, y: probe.1))
            let weak = pixel(ColorGrading.apply(source, settings: ColorGradingSettings(preset: preset, intensity: 0.25)), x: probe.0, y: probe.1)
            let strong = pixel(ColorGrading.apply(source, settings: ColorGradingSettings(preset: preset, intensity: 0.9)), x: probe.0, y: probe.1)
            let original = pixel(source, x: probe.0, y: probe.1)
            let distance: ([Float]) -> Float = { value in zip(value.prefix(3), original).reduce(0) { $0 + abs($1.0 - $1.1) } }
            XCTAssertGreaterThan(distance(strong), distance(weak), "\(preset.title) intensity must have a real effect")
            values.append(strong)
        }
        for i in values.indices { for j in values.indices where j > i { XCTAssertNotEqual(values[i], values[j]) } }
    }
    func testCoolWhiteAndManualColorDirections() {
        let gray = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let cold = pixel(ColorGrading.apply(gray, settings: ColorGradingSettings(preset: .coolWhite, intensity: 1)), x: 200, y: 200)
        XCTAssertGreaterThan(cold[2], cold[0])
        let warm = pixel(ColorGrading.apply(gray, settings: ColorGradingSettings(warmth: 1)), x: 200, y: 200)
        XCTAssertGreaterThan(warm[0], warm[2])
        let low = pixel(ColorGrading.apply(gray, settings: ColorGradingSettings(exposure: -0.5)), x: 200, y: 200)
        let high = pixel(ColorGrading.apply(gray, settings: ColorGradingSettings(exposure: 0.5)), x: 200, y: 200)
        XCTAssertGreaterThan(high[0], low[0])
    }
    func testColorWithoutFaceAndWithoutBeautySwitch() throws {
        let source = gradient(), processor = BeautyProcessor(context: context)
        let result = try XCTUnwrap(processor.filteredImage(source, face: nil, settings: BeautySettings(enabled: false, color: ColorGradingSettings(preset: .clear, intensity: 1))))
        XCTAssertNotEqual(pixel(source, x: 160, y: 170), pixel(result, x: 160, y: 170))
        XCTAssertEqual(source.extent, result.extent)
    }
    func testRealFaceEveryControlAndFilterSurvivesMovieEncoding() async throws {
        guard let path = ProcessInfo.processInfo.environment["BEAUTY_FACE_FIXTURE"] else { throw XCTSkip("Set BEAUTY_FACE_FIXTURE for real-face visual and movie validation") }
        let photo = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: path)))
        let scale = 1280 / photo.extent.width
        let extent = CGRect(x: 0, y: 0, width: 1280, height: min(720, floor(photo.extent.height * scale / 2) * 2))
        let sourceImage = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: extent)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(extent.width), Int(extent.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        let sourcePixels = try XCTUnwrap(buffer)
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(sourceImage, to: sourcePixels, bounds: extent, colorSpace: rgb)
        CVBufferSetAttachment(sourcePixels, kCVImageBufferCGColorSpaceKey, rgb, .shouldPropagate)
        CVBufferSetAttachment(sourcePixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(sourcePixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: sourcePixels, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: sourcePixels, formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample)
        let inputSample = try XCTUnwrap(sample)
        let rawImage = CIImage(cvPixelBuffer: sourcePixels)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AdvancedAppearance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try context.writePNGRepresentation(of: rawImage, to: folder.appendingPathComponent("original.png"), format: .RGBA8, colorSpace: space)
        var cases: [(String, BeautySettings)] = [("smoothing", BeautySettings(enabled: true, smoothing: 1, slimming: 0)), ("slimming", BeautySettings(enabled: true, smoothing: 0, slimming: 1))]
        for control in FaceAdjustment.allCases {
            var a = FaceAdjustments(); a[control] = 1
            cases.append((control.rawValue, BeautySettings(enabled: true, smoothing: 0, slimming: 0, adjustments: a)))
        }
        for preset in ColorPreset.allCases where preset != .none { cases.append((preset.rawValue, BeautySettings(enabled: false, color: ColorGradingSettings(preset: preset, intensity: 1)))) }
        var combined = FaceAdjustments(); for control in FaceAdjustment.allCases { combined[control] = 0.35 }
        cases.append(("combined", BeautySettings(enabled: true, smoothing: 0.6, slimming: 0.25, adjustments: combined, color: ColorGradingSettings(preset: .clear))))
        func bitmap(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: Int(extent.width * extent.height) * 4)
            context.render(image, toBitmap: &bytes, rowBytes: Int(extent.width) * 4, bounds: extent, format: .RGBA8, colorSpace: space)
            return bytes
        }
        func mse(_ a: [UInt8], _ b: [UInt8]) -> Double {
            zip(a, b).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) } / Double(a.count)
        }
        let original = bitmap(rawImage)
        var expected: [[UInt8]] = [], thumbnails: [CGImage] = []
        let detector = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(ciImage: rawImage, orientation: .up).perform([detector])
        let box = try XCTUnwrap(detector.results?.max { $0.boundingBox.width < $1.boundingBox.width }).boundingBox
        let crop = CGRect(x: box.minX * extent.width, y: box.minY * extent.height, width: box.width * extent.width, height: box.height * extent.height)
            .insetBy(dx: -box.width * extent.width * 0.45, dy: -box.height * extent.height * 0.45).intersection(extent)
        thumbnails.append(try XCTUnwrap(context.createCGImage(rawImage, from: crop)))
        let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("all-effects.mov"), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(extent.width), AVVideoHeightKey: Int(extent.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.expectsMediaDataInRealTime = true
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let pipeline = BeautyVideoPipeline()
        for (index, item) in cases.enumerated() {
            var frame = pipeline.process(inputSample, settings: item.1)
            let wanted: BeautyStatus = item.1.hasFaceEffect ? .tracking : .colorOnly
            for _ in 0..<80 where frame.status != wanted {
                try await Task.sleep(nanoseconds: 50_000_000)
                frame = pipeline.process(inputSample, settings: item.1)
            }
            XCTAssertEqual(frame.status, wanted, item.0)
            XCTAssertTrue(frame.recording === frame.preview)
            let rendered = CIImage(cvPixelBuffer: try XCTUnwrap(CMSampleBufferGetImageBuffer(frame.recording)))
            let bytes = bitmap(rendered)
            XCTAssertGreaterThan(mse(bytes, original), 0.01, "\(item.0) must affect the actual detected face or color")
            expected.append(bytes)
            try context.writePNGRepresentation(of: rendered, to: folder.appendingPathComponent(item.0 + ".png"), format: .RGBA8, colorSpace: space)
            thumbnails.append(try XCTUnwrap(context.createCGImage(rendered, from: crop)))
            var next: CMSampleBuffer?
            var time = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: frame.recording, sampleTimingEntryCount: 1, sampleTimingArray: &time, sampleBufferOut: &next)
            for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(input.append(try XCTUnwrap(next)), item.0)
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
        let asset = AVURLAsset(url: folder.appendingPathComponent("all-effects.mov"))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        for (index, item) in cases.enumerated() {
            let decoded = try XCTUnwrap(output.copyNextSampleBuffer(), item.0)
            let pixels = bitmap(CIImage(cvPixelBuffer: try XCTUnwrap(CMSampleBufferGetImageBuffer(decoded))))
            XCTAssertLessThan(mse(pixels, expected[index]), mse(pixels, original), "\(item.0) saved pixels must match its processed result, not the raw input")
        }
        reader.cancelReading()
        // Internal QA sheet: source, then each named case in cases.txt order.
        let columns = 4, tileW = 260, tileH = 300, rows = (thumbnails.count + 3) / 4
        let canvas = try XCTUnwrap(CGContext(data: nil, width: tileW * columns, height: tileH * rows, bitsPerComponent: 8, bytesPerRow: tileW * columns * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, thumbnail) in thumbnails.enumerated() {
            canvas.draw(thumbnail, in: CGRect(x: (index % columns) * tileW, y: (rows - 1 - index / columns) * tileH, width: tileW, height: tileH))
        }
        let sheet = try XCTUnwrap(canvas.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent("contact-sheet.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sheet, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (["original"] + cases.map { $0.0 }).joined(separator: "\n").write(to: folder.appendingPathComponent("cases.txt"), atomically: true, encoding: .utf8)
        print("Advanced appearance visual/movie artifacts: \(folder.path)")
    }
    func testSettingsPersistenceAndSanitization() throws {
        var a = FaceAdjustments(); a.smallFace = .infinity; a.mouthShape = -3; a.bigEyes = 9
        let sanitized = a.sanitized
        XCTAssertEqual(sanitized.smallFace, 0); XCTAssertEqual(sanitized.mouthShape, -1); XCTAssertEqual(sanitized.bigEyes, 1)
        XCTAssertEqual(try JSONDecoder().decode(FaceAdjustments.self, from: JSONEncoder().encode(sanitized)), sanitized)
        let color = ColorGradingSettings(preset: .coolWhite, intensity: 2, exposure: .nan, warmth: -2)
        XCTAssertEqual(color.intensity, 1); XCTAssertEqual(color.exposure, 0); XCTAssertEqual(color.warmth, -1)
        XCTAssertEqual(try JSONDecoder().decode(ColorGradingSettings.self, from: JSONEncoder().encode(color)), color)
    }
}
