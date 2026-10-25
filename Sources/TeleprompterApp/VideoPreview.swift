import AVFoundation
import AppKit
import SwiftUI

/// Single-slot handoff: a slow UI replaces old frames instead of queuing them.
final class VideoPreviewStream: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CMSampleBuffer?
    func offer(_ frame: CMSampleBuffer) { lock.lock(); latest = frame; lock.unlock() }
    func takeLatest() -> CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        let frame = latest; latest = nil; return frame
    }
}

struct CameraPreview: NSViewRepresentable {
    let stream: VideoPreviewStream
    func makeNSView(context: Context) -> ProcessedPreviewView { ProcessedPreviewView(stream: stream) }
    func updateNSView(_ view: ProcessedPreviewView, context: Context) {}
    static func dismantleNSView(_ view: ProcessedPreviewView, coordinator: ()) { view.stop() }
}

final class ProcessedPreviewView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private var timer: Timer?
    private let stream: VideoPreviewStream
    init(stream: VideoPreviewStream) {
        self.stream = stream
        super.init(frame: .zero)
        wantsLayer = true; layer = CALayer()
        display.videoGravity = .resizeAspectFill
        layer?.addSublayer(display)
        timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.showLatest() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }
    func stop() { timer?.invalidate(); timer = nil; display.flushAndRemoveImage() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); display.frame = bounds; CATransaction.commit()
    }
    private func showLatest() {
        guard let frame = stream.takeLatest() else { return }
        if display.status == .failed { display.flush() }
        guard display.isReadyForMoreMediaData else { return }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: frame, sampleBufferOut: &copy) == noErr, let copy else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        display.enqueue(copy)
    }
}
