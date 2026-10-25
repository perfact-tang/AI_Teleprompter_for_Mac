import XCTest
import CoreImage
import AVFoundation
@testable import TeleprompterCore

final class BeautyProcessorTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let face = BeautyFace(bounds: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8),
        leftEye: CGPoint(x: 0.38, y: 0.68), rightEye: CGPoint(x: 0.62, y: 0.68), mouth: CGPoint(x: 0.5, y: 0.3))

    private func fixture() -> CIImage {
        var bytes = [UInt8](repeating: 255, count: 160 * 120 * 4)
        for y in 0..<120 { for x in 0..<160 {
            let base = (x / 2 + y / 2) % 2 == 0 ? 155 : 181
            let i = (y * 160 + x) * 4
            bytes[i] = UInt8(base + 32); bytes[i + 1] = UInt8(base); bytes[i + 2] = UInt8(base - 22)
        } }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: 160 * 4, size: CGSize(width: 160, height: 120), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    private func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 160 * 120 * 4)
        context.render(image, toBitmap: &bytes, rowBytes: 640, bounds: CGRect(x: 0, y: 0, width: 160, height: 120), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }
    private func difference(_ a: CIImage, _ b: CIImage, rect: CGRect) -> Double {
        // Render the requested Core Image region directly: bitmap row order
        // must not be mistaken for Vision's bottom-left coordinate system.
        func region(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: Int(rect.width * rect.height) * 4)
            context.render(image, toBitmap: &bytes, rowBytes: Int(rect.width) * 4, bounds: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return bytes
        }
        let before = region(a), after = region(b)
        var sum = 0, count = 0
        for index in before.indices where index % 4 != 3 { sum += abs(Int(before[index]) - Int(after[index])); count += 1 }
        return Double(sum) / Double(count)
    }
    func testKernelsCompileAndZeroStrengthPreservesPixels() throws {
        let processor = BeautyProcessor(context: context)
        XCTAssertTrue(processor.isAvailable, "Core Image beauty kernels must compile on the actual runtime")
        let source = fixture()
        let zero = try XCTUnwrap(processor.filteredImage(source, face: face, settings: BeautySettings(enabled: true, smoothing: 0, slimming: 0)))
        XCTAssertEqual(pixels(source), pixels(zero))
    }
    func testSmoothingChangesCheeksButProtectsEyesAndBackground() throws {
        let processor = BeautyProcessor(context: context)
        let source = fixture()
        let result = try XCTUnwrap(processor.filteredImage(source, face: face, settings: BeautySettings(enabled: true, smoothing: 1, slimming: 0)))
        let before = pixels(source), after = pixels(result)
        XCTAssertGreaterThan(difference(source, result, rect: CGRect(x: 68, y: 57, width: 24, height: 8)), 2)
        XCTAssertLessThan(difference(source, result, rect: CGRect(x: 58, y: 78, width: 6, height: 6)), 0.5)
        XCTAssertLessThan(difference(source, result, rect: CGRect(x: 0, y: 0, width: 20, height: 20)), 0.5)
        // The high-frequency alternating skin texture should be less pronounced.
        let i = (60 * 160 + 80) * 4, j = (60 * 160 + 82) * 4
        XCTAssertLessThan(abs(Int(after[i]) - Int(after[j])), abs(Int(before[i]) - Int(before[j])))
    }
    func testSlimmingDisplacesCheeksAndKeepsCenterAndCanvas() throws {
        let processor = BeautyProcessor(context: context)
        let source = fixture()
        let result = try XCTUnwrap(processor.filteredImage(source, face: face, settings: BeautySettings(enabled: true, smoothing: 0, slimming: 1)))
        XCTAssertEqual(result.extent, source.extent)
        XCTAssertGreaterThan(difference(source, result, rect: CGRect(x: 47, y: 44, width: 15, height: 15)), 2)
        XCTAssertLessThan(difference(source, result, rect: CGRect(x: 78, y: 56, width: 4, height: 8)), 0.5)
        XCTAssertLessThan(difference(source, result, rect: CGRect(x: 0, y: 0, width: 20, height: 20)), 0.5)
    }
    func testStrongerSmoothingChangesMoreThanLowStrength() throws {
        let processor = BeautyProcessor(context: context), source = fixture()
        let weak = try XCTUnwrap(processor.filteredImage(source, face: face, settings: BeautySettings(enabled: true, smoothing: 0.2, slimming: 0)))
        let strong = try XCTUnwrap(processor.filteredImage(source, face: face, settings: BeautySettings(enabled: true, smoothing: 0.8, slimming: 0)))
        let region = CGRect(x: 68, y: 57, width: 24, height: 8)
        XCTAssertGreaterThan(difference(source, strong, rect: region), difference(source, weak, rect: region))
    }
    func testSettingsClampAndDisabledIsIdentity() throws {
        XCTAssertEqual(BeautySettings(enabled: true, smoothing: .nan, slimming: 8).smoothing, 0)
        XCTAssertEqual(BeautySettings(enabled: true, smoothing: -1, slimming: 8).slimming, 1)
        let processor = BeautyProcessor(context: context), source = fixture()
        let result = try XCTUnwrap(processor.filteredImage(source, face: face, settings: BeautySettings(enabled: false, smoothing: 1, slimming: 1)))
        XCTAssertEqual(pixels(source), pixels(result))
    }
    func testNoFaceBypassesWithoutChangingTimestamp() throws {
        let sample = try sampleBuffer(fixture())
        let pipeline = BeautyVideoPipeline()
        let first = pipeline.process(sample, settings: BeautySettings(enabled: true))
        XCTAssertTrue(first.recording === sample)
        XCTAssertTrue(first.preview === sample)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(first.recording), CMTime(value: 15, timescale: 30))
        let disabled = pipeline.process(sample, settings: BeautySettings())
        XCTAssertEqual(disabled.status, .off)
        XCTAssertTrue(disabled.recording === sample)
    }
    /// Opt-in integration test uses a caller-provided local photo, never a
    /// committed personal image or downloaded model. Exercises real Vision,
    /// Core Image, sample timing, H.264 encoding and decoding without a camera.
    func testRealFacePipelineAndRecordedMovie() async throws {
        guard let path = ProcessInfo.processInfo.environment["BEAUTY_FACE_FIXTURE"] else {
            throw XCTSkip("Set BEAUTY_FACE_FIXTURE to a local frontal-face photo for full integration validation")
        }
        let photo = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: path)))
        let scale = 1280 / photo.extent.width
        let image = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: 1280, height: min(720, floor(photo.extent.height * scale / 2) * 2)))
        let sample = try sampleBuffer(image)
        let pipeline = BeautyVideoPipeline()
        let settings = BeautySettings(enabled: true, smoothing: 1, slimming: 1)
        var frame = pipeline.process(sample, settings: settings)
        for _ in 0..<100 where frame.status != .tracking {
            try await Task.sleep(nanoseconds: 50_000_000)
            frame = pipeline.process(sample, settings: settings)
        }
        XCTAssertEqual(frame.status, .tracking, "Vision must find the provided face and produce actual filtered frames")
        XCTAssertFalse(frame.recording === sample)
        XCTAssertTrue(frame.recording === frame.preview, "Preview and recording must share the same processed sample")
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(frame.recording), CMSampleBufferGetPresentationTimeStamp(sample))
        XCTAssertEqual(CMSampleBufferGetDuration(frame.recording), CMSampleBufferGetDuration(sample))
        var frameTimes: [Double] = []
        for _ in 0..<20 {
            let started = ProcessInfo.processInfo.systemUptime
            frame = pipeline.process(sample, settings: settings)
            if frame.status == .tracking { frameTimes.append(ProcessInfo.processInfo.systemUptime - started) }
        }
        XCTAssertFalse(frameTimes.isEmpty)
        print("Beauty 720p warm render average (ms): \(frameTimes.reduce(0, +) / Double(max(1, frameTimes.count)) * 1000)")
        let compare = pipeline.process(sample, settings: settings, compareOriginal: true)
        XCTAssertTrue(compare.preview === sample)
        XCTAssertFalse(compare.recording === sample, "Original comparison must not disable recorded beauty")
        let processedPixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(frame.recording))
        let processed = CIImage(cvPixelBuffer: processedPixels)
        func bitmap(_ input: CIImage) -> [UInt8] {
            let w = Int(image.extent.width), h = Int(image.extent.height)
            var data = [UInt8](repeating: 0, count: w * h * 4)
            context.render(input, toBitmap: &data, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return data
        }
        let raw = bitmap(image), beauty = bitmap(processed)
        func error(_ a: [UInt8], _ b: [UInt8]) -> Double {
            zip(a, b).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) } / Double(a.count)
        }
        XCTAssertGreaterThan(error(raw, beauty), 1, "Beauty must change real facial pixels")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPrompterBeautyVerification-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try context.writePNGRepresentation(of: image, to: folder.appendingPathComponent("original.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        try context.writePNGRepresentation(of: processed, to: folder.appendingPathComponent("beauty.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let url = folder.appendingPathComponent("beauty.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(image.extent.width), AVVideoHeightKey: Int(image.extent.height)])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<15 {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
            var next: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: frame.recording, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &next), noErr)
            for _ in 0..<200 where !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(input.append(try XCTUnwrap(next)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.5, accuracy: 0.04)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        let decoded = try XCTUnwrap(output.copyNextSampleBuffer())
        let decodedImage = CIImage(cvPixelBuffer: try XCTUnwrap(CMSampleBufferGetImageBuffer(decoded)))
        let decodedPixels = bitmap(decodedImage)
        XCTAssertLessThan(error(beauty, decodedPixels), error(raw, decodedPixels), "Saved H.264 pixels must match beauty more closely than the original")
        reader.cancelReading()
        let disabled = pipeline.process(sample, settings: BeautySettings())
        XCTAssertTrue(disabled.recording === sample)
        let blank = try sampleBuffer(CIImage(color: .gray).cropped(to: image.extent))
        _ = pipeline.process(blank, settings: settings)
        try await Task.sleep(nanoseconds: 500_000_000)
        let noFace = pipeline.process(blank, settings: settings)
        XCTAssertTrue(noFace.recording === blank, "A lost face must never keep deforming the background")
        XCTAssertEqual(noFace.status, .searching)
        print("Beauty integration artifacts: \(folder.path)")
    }
    func testContinuousRealVideoWithEncoderRetainingFrames() async throws {
        guard let path = ProcessInfo.processInfo.environment["BEAUTY_VIDEO_FIXTURE"] else { throw XCTSkip("Set BEAUTY_VIDEO_FIXTURE for continuous real-video encoding audit") }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output); XCTAssertTrue(reader.startReading())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BeautyContinuous-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("audit.mov"), fileType: .mov)
        let size = try await track.load(.naturalSize)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.expectsMediaDataInRealTime = true
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let pipeline = BeautyVideoPipeline()
        var applied = 0, statuses: [String: Int] = [:], samples = 0
        let start = ProcessInfo.processInfo.systemUptime
        var lastSource: CMSampleBuffer?
        while samples < 180 {
            if let next = output.copyNextSampleBuffer() { lastSource = next }
            guard let source = lastSource else { break }
            let deadline = start + Double(samples) / 30
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            var adjustments = FaceAdjustments()
            for control in FaceAdjustment.allCases { adjustments[control] = 0.35 }
            let frame = pipeline.process(source, settings: BeautySettings(enabled: true, smoothing: 0.73, slimming: 0.23,
                adjustments: adjustments, color: ColorGradingSettings(preset: .clear)))
            if samples >= 30 {
                statuses[frame.status.message, default: 0] += 1
                if frame.status == .tracking { applied += 1 }
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(samples), timescale: 30), decodeTimeStamp: .invalid)
            var next: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: frame.recording, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &next)
            for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(input.append(try XCTUnwrap(next)))
            samples += 1
        }
        input.markAsFinished(); await writer.finishWriting(); reader.cancelReading()
        print("Continuous beauty audit: applied=\(applied)/\(max(0, samples - 30)), statuses=\(statuses), output=\(folder.path)")
        XCTAssertEqual(writer.status, .completed)
        XCTAssertGreaterThan(Double(applied) / Double(max(1, samples - 30)), 0.9)
    }
    private func sampleBuffer(_ image: CIImage) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixelBuffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        context.render(image, to: pixels)
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: 15, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
