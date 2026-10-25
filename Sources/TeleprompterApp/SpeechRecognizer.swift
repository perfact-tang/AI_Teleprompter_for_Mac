import Foundation

struct SpeechObservation {
    let text: String
    let inferenceSeconds: Double
    let audioSeconds: Double
}
protocol SpeechRecognizer: AnyObject {
    var onResult: ((SpeechObservation) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start(executable: URL, model: URL, language: String)
    func append(_ samples: [Float])
    func suspend(_ suspended: Bool)
    func stop()
}

/// Offline whisper.cpp adapter. A bounded rolling window avoids an ever-growing queue.
/// The CLI reloads the model per job; measure on target hardware before tuning windows.
final class WhisperCLIRecognizer: SpeechRecognizer {
    var onResult: ((SpeechObservation) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "localprompter.whisper", qos: .userInitiated)
    private var samples: [Float] = []
    private var freshSamples = 0
    private var active = false
    private var suspended = false
    private var generation = UUID()
    private var process: Process?
    private var executable = URL(fileURLWithPath: "/usr/bin/false")
    private var model = URL(fileURLWithPath: "/missing")
    private var language = "zh"
    func start(executable: URL, model: URL, language: String) {
        queue.async {
            self.cancel(); self.executable = executable; self.model = model; self.language = language
            self.active = true; self.suspended = false
        }
    }
    func append(_ chunk: [Float]) {
        queue.async {
            guard self.active, !self.suspended else { return }
            self.samples.append(contentsOf: chunk); self.freshSamples += chunk.count
            if self.samples.count > 96_000 { self.samples.removeFirst(self.samples.count - 96_000) }
            self.launchIfReady()
        }
    }
    func suspend(_ suspended: Bool) {
        queue.async {
            self.suspended = suspended; self.samples = []; self.freshSamples = 0
            self.generation = UUID(); self.process?.terminate()
        }
    }
    func stop() { queue.async { self.cancel() } }
    private func cancel() {
        active = false; generation = UUID(); samples = []; freshSamples = 0
        process?.terminate()
    }
    private func launchIfReady() {
        guard active, !suspended, process == nil, freshSamples >= 32_000, samples.count >= 32_000 else { return }
        freshSamples = 0
        let window = samples
        let rms = sqrt(window.reduce(0.0) { $0 + Double($1 * $1) } / Double(window.count))
        guard rms > 0.004 else { return } // Silence must not advance the script.
        let id = generation
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPrompter-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let wav = folder.appendingPathComponent("audio.wav")
            try Self.wav(window).write(to: wav)
            let output = folder.appendingPathComponent("result")
            let log = folder.appendingPathComponent("whisper.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: log)
            let job = Process()
            job.executableURL = executable
            job.arguments = ["-m", model.path, "-f", wav.path, "-l", language, "-otxt", "-of", output.path, "-nt", "-t", "4"]
            job.standardOutput = logHandle; job.standardError = logHandle
            let started = Date()
            job.terminationHandler = { [weak self] finished in
                self?.queue.async {
                    guard let self else { return }
                    try? logHandle.close()
                    defer { try? FileManager.default.removeItem(at: folder) }
                    self.process = nil
                    if self.generation == id, self.active, !self.suspended {
                        if finished.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.appendingPathExtension("txt").path) {
                            let text = (try? String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8)) ?? ""
                            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleaned.isEmpty {
                                self.onResult?(SpeechObservation(text: cleaned, inferenceSeconds: Date().timeIntervalSince(started), audioSeconds: Double(window.count) / 16000))
                            }
                        } else {
                            let details = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                            self.active = false
                            self.onError?("Whisper 识别失败，录制仍在继续。\n" + String(details.suffix(900)))
                        }
                    }
                    self.launchIfReady()
                }
            }
            process = job
            try job.run()
            // Bound hung or pathological inference; canceling also invalidates late results.
            queue.asyncAfter(deadline: .now() + 45) { [weak self, weak job] in
                guard let self, let job, self.process === job, job.isRunning else { return }
                self.generation = UUID(); self.active = false; job.terminate()
                self.onError?("Whisper 单次识别超过 45 秒，自动跟随已停止；录制继续。请使用 base 模型或检查本地工具。")
            }
        } catch {
            process = nil; active = false
            try? FileManager.default.removeItem(at: folder)
            onError?("无法运行本地 Whisper：\(error.localizedDescription)")
        }
    }
    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func ascii(_ string: String) { data.append(contentsOf: string.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); integer(UInt32(36 + samples.count * 2)); ascii("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(16000))
        integer(UInt32(32000)); integer(UInt16(2)); integer(UInt16(16)); ascii("data")
        integer(UInt32(samples.count * 2))
        for value in samples { integer(Int16(max(-1, min(1, value)) * 32767)) }
        return data
    }
}
