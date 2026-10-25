import AVFoundation
import Foundation
import TeleprompterCore

enum PrompterError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Session, writer and clock are confined to one serial queue. UI is never recorded.
final class CaptureRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "localprompter.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var configured = false
    let preview = VideoPreviewStream()
    private let beautyPipeline = BeautyVideoPipeline()
    private var beautySettings = BeautySettings()
    private var compareOriginal = false
    private var beautyStatus: BeautyStatus?
    var onBeautyStatus: ((BeautyStatus) -> Void)?

    func setBeauty(_ settings: BeautySettings, compareOriginal: Bool) {
        queue.async {
            self.beautySettings = settings; self.compareOriginal = compareOriginal
        }
    }
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var recordingURL: URL?
    private var startTime: CMTime?
    private var latestTime: Double = 0
    private var timeline = RecordingTimeline()
    private var paused = false
    private var resuming = false
    private var converter: AVAudioConverter?
    private var converterFormat: AVAudioFormat?
    private var lastDiskCheck = 0.0
    private var dropped = 0
    var onAudio: (([Float]) -> Void)?
    var onProgress: ((Double, Int) -> Void)?
    var onFailure: ((Error) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(sessionFailed(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionFailed(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func sessionFailed(_ notification: Notification) {
        let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "摄像头采集被中断，请检查设备连接或其他应用是否占用摄像头。"
        queue.async {
            if self.writer != nil {
                self.paused = true
                if self.startTime != nil { self.timeline.pause(at: self.latestTime) }
            }
            self.onFailure?(PrompterError.message(detail))
        }
    }

    func configure() async throws {
        for media in [AVMediaType.video, .audio] {
            let granted = await AVCaptureDevice.requestAccess(for: media)
            guard granted else { throw PrompterError.message("摄像头或麦克风未获授权。请到系统设置 → 隐私与安全性中允许访问，再重新打开应用。") }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if !self.configured {
                        self.session.beginConfiguration()
                        defer { self.session.commitConfiguration() }
                        self.session.inputs.forEach { self.session.removeInput($0) }
                        self.session.outputs.forEach { self.session.removeOutput($0) }
                        self.session.sessionPreset = .hd1280x720
                        guard let camera = AVCaptureDevice.default(for: .video), let microphone = AVCaptureDevice.default(for: .audio) else {
                            throw PrompterError.message("找不到摄像头或麦克风。请连接设备后重试。")
                        }
                        for device in [camera, microphone] {
                            let input = try AVCaptureDeviceInput(device: device)
                            guard self.session.canAddInput(input) else { throw PrompterError.message("无法添加采集设备。") }
                            self.session.addInput(input)
                        }
                        self.videoOutput.alwaysDiscardsLateVideoFrames = true
                        self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                        self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
                        self.audioOutput.setSampleBufferDelegate(self, queue: self.queue)
                        for output in [self.videoOutput as AVCaptureOutput, self.audioOutput] {
                            guard self.session.canAddOutput(output) else { throw PrompterError.message("无法建立音视频输出。") }
                            self.session.addOutput(output)
                        }
                        self.configured = true
                    }
                    self.session.startRunning()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.configured, self.session.isRunning, self.writer == nil else { throw PrompterError.message("摄像头尚未准备就绪，或录制正在进行。") }
                    let folder = Self.recoveryDirectory
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("Recording-\(UUID().uuidString).mov")
                    let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
                    guard let videoSettings = self.videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov),
                          let audioSettings = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) else {
                        throw PrompterError.message("设备未提供可用的音视频编码配置。")
                    }
                    var h264 = videoSettings
                    h264[AVVideoCodecKey] = AVVideoCodecType.h264
                    h264[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
                    var aac = audioSettings
                    aac[AVFormatIDKey] = kAudioFormatMPEG4AAC
                    let video = AVAssetWriterInput(mediaType: .video, outputSettings: h264)
                    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
                    video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
                    guard assetWriter.canAdd(video), assetWriter.canAdd(audio) else { throw PrompterError.message("无法配置 H.264 / AAC 编码器。") }
                    assetWriter.add(video); assetWriter.add(audio)
                    guard assetWriter.startWriting() else { throw assetWriter.error ?? PrompterError.message("无法开始写入视频。") }
                    self.writer = assetWriter; self.videoInput = video; self.audioInput = audio; self.recordingURL = url
                    self.startTime = nil; self.timeline = RecordingTimeline(); self.paused = false; self.resuming = false
                    self.latestTime = 0; self.lastDiskCheck = 0; self.dropped = 0
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static var recoveryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalPrompter/Recordings", isDirectory: true)
    }
    func setPaused(_ value: Bool) {
        queue.async {
            guard self.writer != nil, self.paused != value else { return }
            self.paused = value
            if value {
                if self.startTime != nil { self.timeline.pause(at: self.latestTime) }
            } else { self.resuming = self.startTime != nil }
        }
    }
    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let writer = self.writer, let url = self.recordingURL else {
                    continuation.resume(throwing: PrompterError.message("没有进行中的录制。")); return
                }
                let hasVideo = self.startTime != nil
                self.writer = nil; self.videoInput?.markAsFinished(); self.audioInput?.markAsFinished()
                self.videoInput = nil; self.audioInput = nil; self.recordingURL = nil
                guard hasVideo else {
                    writer.cancelWriting(); try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: PrompterError.message("未收到摄像头画面，录制未生成。")); return
                }
                writer.finishWriting {
                    if writer.status == .completed { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: writer.error ?? PrompterError.message("视频写入未完成。临时文件保留在恢复目录。")) }
                }
            }
        }
    }
    func shutdown() { queue.async { self.session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput
        var sampleBuffer = sampleBuffer
        if isVideo {
            let frame = beautyPipeline.process(sampleBuffer, settings: beautySettings, compareOriginal: compareOriginal)
            sampleBuffer = frame.recording
            preview.offer(frame.preview)
            if beautyStatus != frame.status { beautyStatus = frame.status; onBeautyStatus?(frame.status) }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        latestTime = max(latestTime, pts.seconds)
        guard let writer, !paused else { return }
        if resuming { timeline.resume(at: pts.seconds); resuming = false }
        if startTime == nil {
            guard isVideo else { return }
            startTime = pts; writer.startSession(atSourceTime: pts)
        }
        let adjustedTime = timeline.adjusted(pts.seconds)
        guard adjustedTime >= (startTime?.seconds ?? 0) else { return }
        do {
            let adjusted = try retime(sampleBuffer, offset: timeline.pauseOffset)
            let input = isVideo ? videoInput : audioInput
            if let input, input.isReadyForMoreMediaData {
                guard input.append(adjusted) else { throw writer.error ?? PrompterError.message("音视频写入失败。") }
            } else if isVideo { dropped += 1 }
            if !isVideo { extractAudio(sampleBuffer) }
            if isVideo {
                let elapsed = adjustedTime - (startTime?.seconds ?? adjustedTime)
                onProgress?(elapsed, dropped)
                if pts.seconds - lastDiskCheck > 5 {
                    lastDiskCheck = pts.seconds
                    let values = try Self.recoveryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    if let available = values.volumeAvailableCapacityForImportantUsage, available < 150_000_000 {
                        paused = true; timeline.pause(at: latestTime)
                        onFailure?(PrompterError.message("磁盘可用空间不足 150 MB，已暂停录制。请结束并保存，或腾出空间后继续。"))
                    }
                }
            }
        } catch {
            paused = true; timeline.pause(at: latestTime); onFailure?(error)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { dropped += 1 }

    private func retime(_ buffer: CMSampleBuffer, offset: Double) throws -> CMSampleBuffer {
        guard offset > 0 else { return buffer }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        let status = CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        guard status == noErr else { throw PrompterError.message("读取采集时间戳失败。") }
        let delta = CMTime(seconds: offset, preferredTimescale: 1_000_000_000)
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, delta)
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, delta) }
        }
        var result: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &result)
        guard copyStatus == noErr, let result else { throw PrompterError.message("重建录制时间戳失败。") }
        return result
    }
    private func extractAudio(_ buffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(buffer),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        if converterFormat != format { converter = AVAudioConverter(from: format, to: target); converterFormat = format }
        guard let converter else { return }
        let count = AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        pcm.frameLength = count
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard copyStatus == noErr else { return }
        let capacity = AVAudioFrameCount(ceil(Double(count) * 16000 / format.sampleRate)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return pcm
        }
        if let channel = converted.floatChannelData?[0], converted.frameLength > 0 {
            onAudio?(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
        }
    }
}
