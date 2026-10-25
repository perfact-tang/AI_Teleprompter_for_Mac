import AVFoundation

public struct BeautyVideoFrame {
    /// The exact sample used for recording and, normally, preview.
    public let recording: CMSampleBuffer
    public let preview: CMSampleBuffer
    public let status: BeautyStatus
}

/// A single processing path prevents preview-only filters from disappearing
/// in the saved movie. Call from the capture queue, including outside recording.
public final class BeautyVideoPipeline {
    private let processor = BeautyProcessor()
    public init() {}
    public func process(_ source: CMSampleBuffer, settings: BeautySettings, compareOriginal: Bool = false) -> BeautyVideoFrame {
        guard let pixels = CMSampleBufferGetImageBuffer(source) else {
            return BeautyVideoFrame(recording: source, preview: source, status: .unavailable("没有视频画面"))
        }
        guard let processed = processor.process(pixels, settings: settings, time: ProcessInfo.processInfo.systemUptime) else {
            return BeautyVideoFrame(recording: source, preview: source, status: processor.status)
        }
        var description: CMVideoFormatDescription?
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source), decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(source))
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: processed, formatDescriptionOut: &description) == noErr,
              let description,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: processed, formatDescription: description,
                sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else {
            return BeautyVideoFrame(recording: source, preview: source, status: .unavailable("重建视频帧失败"))
        }
        return BeautyVideoFrame(recording: sample, preview: compareOriginal ? source : sample, status: compareOriginal ? .original : processor.status)
    }
}
