import AppKit
import AVFoundation
import Combine
import TeleprompterCore
import UniformTypeIdentifiers

struct ScriptParagraph: Identifiable {
    let id: Int
    let text: String
    let start: Int
    let end: Int
}
enum RecordingState { case idle, preparing, recording, paused, finishing }

@MainActor
final class TeleprompterController: ObservableObject {
    @Published var script = "大家好，欢迎来到本地提词。\n\n把想说的话写在这里，放松地看向摄像头。\n\n开启自动跟随后，提词会根据你的朗读进度向前移动。停顿时，文字也会停下来。\n\n所有录制和识别都在这台 Mac 上完成。现在，开始你的第一次录制吧。" {
        didSet { rebuildScript(); preferences.set(script, forKey: "script") }
    }
    @Published var paragraphs: [ScriptParagraph] = []
    @Published var state: RecordingState = .idle
    @Published var cameraReady = false
    @Published var elapsed = 0.0
    @Published var droppedFrames = 0
    @Published var currentOffset = 0
    @Published var transcript = ""
    @Published var confidence = 0.0
    @Published var inferenceSeconds = 0.0
    @Published var audioSeconds = 0.0
    @Published var errorMessage: String?
    @Published var status = "导入稿件，准备好后开启摄像头。"
    @Published var pendingRecording: URL?
    @Published var savedURL: URL?
    @Published var fontSize = 30.0
    @Published var overlayPosition = 0.08 {
        didSet { preferences.set(overlayPosition, forKey: "overlayPosition") }
    }
    @Published var overlayOpacity = 0.68
    @Published var beautyEnabled = false { didSet { updateBeauty() } }
    @Published var skinSmoothing = 0.35 { didSet { updateBeauty() } }
    @Published var faceSlimming = 0.2 { didSet { updateBeauty() } }
    @Published var faceAdjustments = FaceAdjustments() { didSet { updateBeauty() } }
    @Published var colorGrading = ColorGradingSettings() { didSet { updateBeauty() } }
    @Published var compareOriginal = false { didSet { updateBeauty() } }
    @Published var beautyStatus: BeautyStatus = .off
    @Published var language = "zh"
    @Published var autoFollow = true
    @Published var executablePath: String { didSet { preferences.set(executablePath, forKey: "whisperExecutable") } }
    @Published var modelPath: String { didSet { preferences.set(modelPath, forKey: "whisperModel") } }
    let capture = CaptureRecorder()
    private let recognizer: SpeechRecognizer = WhisperCLIRecognizer()
    private var aligner = ScriptAligner()
    private var progressDate = Date.distantPast
    private var loadingAppearance = true
    private let preferences: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.preferences = defaults
        if defaults.object(forKey: "overlayPosition") != nil { overlayPosition = min(1, max(0, defaults.double(forKey: "overlayPosition"))) }
        let installed = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalPrompter/whisper.cpp")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".local/whisper.cpp")
        let base = FileManager.default.isExecutableFile(atPath: development.appendingPathComponent("build/bin/whisper-cli").path) ? development : installed
        executablePath = defaults.string(forKey: "whisperExecutable") ?? base.appendingPathComponent("build/bin/whisper-cli").path
        modelPath = defaults.string(forKey: "whisperModel") ?? base.appendingPathComponent("models/ggml-base.bin").path
        if let saved = defaults.string(forKey: "script") { script = saved }
        rebuildScript()
        beautyEnabled = defaults.bool(forKey: "beautyEnabled")
        if defaults.object(forKey: "skinSmoothing") != nil { skinSmoothing = min(1, max(0, defaults.double(forKey: "skinSmoothing"))) }
        if defaults.object(forKey: "faceSlimming") != nil { faceSlimming = min(1, max(0, defaults.double(forKey: "faceSlimming"))) }
        if let data = defaults.data(forKey: "faceAdjustmentsV1"), let saved = try? JSONDecoder().decode(FaceAdjustments.self, from: data) { faceAdjustments = saved.sanitized }
        if let data = defaults.data(forKey: "colorGradingV1"), let saved = try? JSONDecoder().decode(ColorGradingSettings.self, from: data) { colorGrading = saved.sanitized }
        capture.onBeautyStatus = { [weak self] status in
            Task { @MainActor in self?.beautyStatus = status }
        }
        loadingAppearance = false
        updateBeauty()
        let speech = recognizer
        capture.onAudio = { speech.append($0) }
        capture.onProgress = { [weak self] elapsed, dropped in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.progressDate) > 0.15 else { return }
                self.progressDate = Date(); self.elapsed = elapsed; self.droppedFrames = dropped
            }
        }
        capture.onFailure = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error.localizedDescription
                if self?.state == .recording { self?.state = .paused; self?.recognizer.suspend(true) }
            }
        }
        recognizer.onResult = { [weak self] observation in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.transcript = observation.text
                self.inferenceSeconds = observation.inferenceSeconds; self.audioSeconds = observation.audioSeconds
                if let match = self.aligner.consume(observation.text) {
                    self.currentOffset = match.characterOffset; self.confidence = match.confidence
                }
            }
        }
        recognizer.onError = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message; self?.status = "自动跟随已停止，可手动定位；录制继续。" }
        }
    }
    private func updateBeauty() {
        // Load all persisted fields before any observer writes defaults back.
        // Otherwise the first restored field can overwrite the unread fields.
        guard !loadingAppearance else { return }
        preferences.set(beautyEnabled, forKey: "beautyEnabled")
        preferences.set(skinSmoothing, forKey: "skinSmoothing")
        preferences.set(faceSlimming, forKey: "faceSlimming")
        if let data = try? JSONEncoder().encode(faceAdjustments) { preferences.set(data, forKey: "faceAdjustmentsV1") }
        if let data = try? JSONEncoder().encode(colorGrading) { preferences.set(data, forKey: "colorGradingV1") }
        let settings = currentBeautySettings
        if !settings.hasEffect { beautyStatus = beautyEnabled ? .neutral : .off }
        else if !cameraReady { beautyStatus = .waitingForCamera }
        capture.setBeauty(settings, compareOriginal: compareOriginal)
    }
    var currentBeautySettings: BeautySettings {
        BeautySettings(enabled: beautyEnabled, smoothing: skinSmoothing, slimming: faceSlimming, adjustments: faceAdjustments, color: colorGrading)
    }
    func resetBeautyPage(_ page: Int) {
        if page == 2 { colorGrading = ColorGradingSettings(); return }
        if page == 0 { skinSmoothing = 0; faceSlimming = 0 }
        var value = faceAdjustments
        for control in FaceAdjustment.allCases where control.isFeature == (page == 1) { value[control] = 0 }
        faceAdjustments = value
    }
    func resetAllAppearance() {
        skinSmoothing = 0; faceSlimming = 0; faceAdjustments = FaceAdjustments()
        colorGrading = ColorGradingSettings(); compareOriginal = false
    }
    var isLocked: Bool { state != .idle }
    var activeParagraph: Int {
        paragraphs.first(where: { currentOffset < $0.end })?.id ?? paragraphs.last?.id ?? 0
    }
    var progress: Double { script.isEmpty ? 0 : min(1, Double(currentOffset) / Double(script.count)) }
    var whisperReady: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath) && FileManager.default.fileExists(atPath: modelPath) && !modelPath.contains(".en.")
    }
    func rebuildScript() {
        aligner.load(script); currentOffset = 0
        var offset = 0, start = 0
        var chunk = ""
        paragraphs = []
        func flush() {
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paragraphs.append(ScriptParagraph(id: paragraphs.count, text: chunk.trimmingCharacters(in: .newlines), start: start, end: offset))
            }
            chunk = ""; start = offset
        }
        for character in script {
            chunk.append(character); offset += 1
            if character == "\n" || chunk.count >= 60 || (chunk.count >= 18 && "。！？.!?；;".contains(character)) { flush() }
        }
        flush()
    }
    func locate(_ paragraph: ScriptParagraph) { currentOffset = paragraph.start; aligner.seek(characterOffset: currentOffset) }
    func reset() { currentOffset = 0; aligner.seek(characterOffset: 0); confidence = 0; transcript = "" }
    func importScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 2_000_000 else { throw PrompterError.message("稿件超过 2 MB，请拆分后导入。") }
            script = try String(contentsOf: url, encoding: .utf8); status = "已导入 \(url.lastPathComponent)"
        } catch { errorMessage = "导入失败，请选择 UTF-8 TXT 或 Markdown。\n\(error.localizedDescription)" }
    }
    func choosePath(model: Bool) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.message = model ? "选择多语言 GGML 模型，例如 ggml-base.bin（勿选 .en 模型）" : "选择 whisper.cpp 的 whisper-cli 可执行文件"
        if panel.runModal() == .OK, let url = panel.url {
            if model { modelPath = url.path } else { executablePath = url.path }
        }
    }
    func openCamera() async {
        guard state == .idle else { return }
        state = .preparing
        do { try await capture.configure(); cameraReady = true; status = "摄像头已就绪。文字仅供预览，不会进入视频。" }
        catch { errorMessage = error.localizedDescription }
        state = .idle
    }
    func start() async {
        guard state == .idle, cameraReady, pendingRecording == nil else { return }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "请先输入或导入稿件。"; return }
        if autoFollow && !whisperReady {
            errorMessage = "自动跟随需要本地 whisper-cli 与多语言 GGML 模型。请在识别设置中选择文件，或关闭自动跟随后进行基础录制。"; return
        }
        state = .preparing; reset(); elapsed = 0; droppedFrames = 0; savedURL = nil
        do {
            try await capture.start()
            if autoFollow { recognizer.start(executable: URL(fileURLWithPath: executablePath), model: URL(fileURLWithPath: modelPath), language: language) }
            state = .recording; status = autoFollow ? "正在录制 · 本地语音自动跟随" : "正在录制 · 点击提词段落可手动定位"
        } catch { state = .idle; errorMessage = error.localizedDescription }
    }
    func togglePause() {
        guard state == .recording || state == .paused else { return }
        let pause = state == .recording
        capture.setPaused(pause); recognizer.suspend(pause)
        state = pause ? .paused : .recording
        status = pause ? "已暂停，录制时间与提词进度保持不动。" : "已继续录制。"
    }
    func finish() async {
        guard state == .recording || state == .paused else { return }
        state = .finishing; recognizer.stop()
        do {
            let url = try await capture.finish()
            pendingRecording = url; state = .idle; status = "录制完成，请保存视频。"
            saveRecording()
        } catch { state = .idle; errorMessage = error.localizedDescription }
    }
    func saveRecording() {
        guard let source = pendingRecording else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.quickTimeMovie]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "提词录制-\(formatter.string(from: Date())).mov"
        guard panel.runModal() == .OK, let destination = panel.url else {
            status = "已保留录制。点击“保存视频”重试；临时视频也可在恢复目录找到。"; return
        }
        do {
            if source.standardizedFileURL != destination.standardizedFileURL {
                // Atomic replacement preserves an existing destination if copying fails.
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: source, to: staging)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                } else { try FileManager.default.moveItem(at: staging, to: destination) }
                try FileManager.default.removeItem(at: source)
            }
            savedURL = destination; pendingRecording = nil; status = "已保存：\(destination.lastPathComponent)"
        } catch { errorMessage = "保存失败，原始录制仍保留：\(source.path)\n\(error.localizedDescription)" }
    }
    func revealRecovery() {
        try? FileManager.default.createDirectory(at: CaptureRecorder.recoveryDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(CaptureRecorder.recoveryDirectory)
    }
}
