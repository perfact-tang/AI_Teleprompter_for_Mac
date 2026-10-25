import SwiftUI
import AVFoundation
import AppKit
import TeleprompterCore

private let accent = Color(red: 0.57, green: 0.85, blue: 0.59)

struct ContentView: View {
    @ObservedObject var model: TeleprompterController
    @State private var showSettings = false
    @State private var showBeauty = false
    @State private var beautyPage = 0
    @AppStorage("overlayHorizontal") private var overlayHorizontal = 0.5
    @AppStorage("overlayWidth") private var overlayWidth = 0.72
    @AppStorage("overlayHeight") private var overlayHeight = 0.5
    @State private var moveStart: CGPoint?
    @State private var resizeStart: CGRect?
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("摄像头预览", systemImage: "viewfinder")
                        Spacer()
                        Text("720p · MOV · H.264 / AAC").font(.caption).foregroundStyle(.secondary)
                    }
                    stage
                    controls
                    HStack(spacing: 16) {
                        Label("仅在本机处理", systemImage: "lock.shield")
                        Text("提词文字不会录入视频")
                        Spacer()
                        Text("丢帧 \(model.droppedFrames)").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Label("识别动态", systemImage: "waveform")
                        Spacer()
                        if model.inferenceSeconds > 0 {
                            Text(String(format: "窗口 %.1fs · 推理 %.1fs · 匹配 %.0f%%", model.audioSeconds, model.inferenceSeconds, model.confidence * 100))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(model.transcript.isEmpty ? "开始朗读后，本地识别结果将显示在这里。" : model.transcript)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity)
                sidebar.frame(width: 290)
            }.padding(24)
            Divider()
            HStack {
                Circle().fill(model.state == .recording ? accent : Color.secondary).frame(width: 6, height: 6)
                Text(model.status).lineLimit(1)
                Spacer()
                Button("恢复目录") { model.revealRecovery() }.buttonStyle(.plain)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { settings }
        .alert("操作提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.viewfinder").font(.system(size: 25)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("本地提词").font(.title3.weight(.semibold))
                Text("专注表达，自然开口").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("LOCAL STUDIO").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(3).foregroundStyle(.secondary)
            Button { showBeauty.toggle() } label: {
                Label("美颜与滤镜", systemImage: "sparkles")
            }.tint(model.currentBeautySettings.hasEffect ? accent : nil)
                .popover(isPresented: $showBeauty, arrowEdge: .top) { beautyControls }
            Button { showSettings = true } label: { Label("识别设置", systemImage: "slider.horizontal.3") }
                .disabled(model.isLocked)
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
    private var stage: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black
                if model.cameraReady { CameraPreview(stream: model.capture.preview) }
                else {
                    VStack(spacing: 14) {
                        Image(systemName: "video").font(.system(size: 42, weight: .ultraLight))
                        Text("给你的表达，一个好开场").font(.title3)
                        Text("准备稿件后，开启摄像头预览").font(.caption).foregroundStyle(.secondary)
                        Button("开启摄像头") { Task { await model.openCamera() } }
                            .buttonStyle(StudioButtonStyle())
                            .disabled(model.isLocked)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.cameraReady {
                    movableTeleprompter(in: geometry.size)
                }
                VStack {
                    Spacer()
                    HStack {
                        Label(model.state == .recording ? "录制中" : model.state == .paused ? "已暂停" : "预览", systemImage: model.state == .recording ? "record.circle.fill" : "circle")
                            .foregroundStyle(model.state == .recording ? .red : .white)
                        if model.currentBeautySettings.hasEffect {
                            Text(beautyLiveLabel)
                                .foregroundStyle(beautyIsApplied ? accent : .orange)
                                .lineLimit(1)
                                .help(model.beautyStatus.message)
                        }
                        Spacer()
                        Text(timeString).monospacedDigit()
                    }.font(.caption.weight(.medium)).padding(12).background(.black.opacity(0.5))
                }
            }.coordinateSpace(name: "previewStage")
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }.aspectRatio(16 / 9, contentMode: .fit)
    }
    private func movableTeleprompter(in stage: CGSize) -> some View {
        // Leave room for the recording status strip; all stored values are relative
        // so the box stays inside the preview when the window changes size.
        let area = CGRect(x: 12, y: 12, width: max(1, stage.width - 24), height: max(1, stage.height - 54))
        let minimumWidth = min(240, area.width)
        let minimumHeight = min(130, area.height)
        let size = CGSize(width: min(area.width, max(minimumWidth, stage.width * overlayWidth)),
                          height: min(area.height, max(minimumHeight, stage.height * overlayHeight)))
        let origin = CGPoint(x: area.minX + (area.width - size.width) * min(1, max(0, overlayHorizontal)),
                             y: area.minY + (area.height - size.height) * min(1, max(0, model.overlayPosition)))
        let frame = CGRect(origin: origin, size: size)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label("拖动提词框", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8).contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .named("previewStage"))
                        .onChanged { value in
                            if moveStart == nil { moveStart = frame.origin }
                            guard let start = moveStart else { return }
                            let travelX = area.width - size.width
                            let travelY = area.height - size.height
                            overlayHorizontal = travelX > 0 ? min(1, max(0, (start.x + value.translation.width - area.minX) / travelX)) : 0.5
                            model.overlayPosition = travelY > 0 ? min(1, max(0, (start.y + value.translation.height - area.minY) / travelY)) : 0
                        }.onEnded { _ in moveStart = nil })
                    .help("按住这里拖动提词框")
                Button("复位") {
                    overlayHorizontal = 0.5; overlayWidth = 0.72; overlayHeight = 0.5
                    model.overlayPosition = 0.08
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                    .help("恢复居中位置和默认大小")
            }.padding(.horizontal, 14)
            teleprompter
        }
        .frame(width: size.width, height: size.height)
        .background(.black.opacity(model.overlayOpacity), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle()).padding(4)
                .help("拖动右下角调整提词框大小")
                .accessibilityLabel("调整提词框大小")
                .gesture(DragGesture(coordinateSpace: .named("previewStage"))
                    .onChanged { value in
                        if resizeStart == nil { resizeStart = frame }
                        guard let start = resizeStart else { return }
                        let width = min(area.maxX - start.minX, max(minimumWidth, start.width + value.translation.width))
                        let height = min(area.maxY - start.minY, max(minimumHeight, start.height + value.translation.height))
                        overlayWidth = width / stage.width; overlayHeight = height / stage.height
                        let travelX = area.width - width, travelY = area.height - height
                        overlayHorizontal = travelX > 0 ? min(1, max(0, (start.minX - area.minX) / travelX)) : 0.5
                        model.overlayPosition = travelY > 0 ? min(1, max(0, (start.minY - area.minY) / travelY)) : 0
                    }.onEnded { _ in resizeStart = nil })
        }
        .position(x: frame.midX, y: frame.midY)
    }
    private var teleprompter: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .center, spacing: 18) {
                    ForEach(model.paragraphs) { paragraph in
                        Text(paragraph.text)
                            .font(.system(size: model.fontSize, weight: paragraph.id == model.activeParagraph ? .semibold : .regular))
                            .foregroundStyle(paragraph.id == model.activeParagraph ? .white : .white.opacity(0.38))
                            .multilineTextAlignment(.center)
                            .lineSpacing(7).frame(maxWidth: .infinity, alignment: .center)
                            .contentShape(Rectangle()).onTapGesture { model.locate(paragraph) }
                            .id(paragraph.id)
                    }
                    Color.clear.frame(height: 160)
                }.padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 22)
            }
            .onChange(of: model.activeParagraph) { value in withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(value, anchor: .top) } }
            .onChange(of: model.currentOffset) { value in if value == 0 { withAnimation { proxy.scrollTo(model.activeParagraph, anchor: .top) } } }
        }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            if model.state == .recording || model.state == .paused {
                Button { model.togglePause() } label: {
                    Label(model.state == .paused ? "继续录制" : "暂停", systemImage: model.state == .paused ? "play.fill" : "pause.fill")
                }.controlSize(.large)
                Button(role: .destructive) { Task { await model.finish() } } label: { Label("结束并保存", systemImage: "stop.fill") }
                    .controlSize(.large)
            } else {
                Button { Task { await model.start() } } label: {
                    Label(model.state == .finishing ? "正在保存…" : model.state == .preparing ? "正在准备…" : "开始录制", systemImage: "record.circle")
                }.buttonStyle(StudioButtonStyle()).controlSize(.large)
                    .disabled(!model.cameraReady || model.isLocked || model.pendingRecording != nil)
            }
            if model.pendingRecording != nil { Button("保存视频…") { model.saveRecording() }.controlSize(.large) }
            if let url = model.savedURL { Button("显示视频") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            Spacer()
            Button { model.reset() } label: { Image(systemName: "backward.end") }.help("重置朗读位置")
                .disabled(model.state == .finishing)
            Text("\(Int(model.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("我的稿件").font(.headline)
                Spacer()
                Button { model.importScript() } label: { Label("导入", systemImage: "square.and.arrow.down") }.disabled(model.isLocked)
            }
            TextEditor(text: $model.script)
                .font(.system(size: 14)).lineSpacing(6).padding(8)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .frame(minHeight: 180, maxHeight: .infinity).disabled(model.isLocked)
            HStack { Text("TXT / Markdown · 纯文本"); Spacer(); Text("\(model.script.count) 字") }.font(.caption2).foregroundStyle(.secondary)
            Divider()
            Picker("朗读语言", selection: $model.language) {
                Text("中文").tag("zh")
                Text("日本語").tag("ja")
                Text("英语（English）").tag("en")
            }.disabled(model.isLocked)
            Toggle("语音自动跟随", isOn: $model.autoFollow).tint(accent).disabled(model.isLocked)
            HStack(spacing: 5) {
                Circle().fill(model.whisperReady ? accent : Color.orange).frame(width: 5, height: 5)
                Text(model.whisperReady ? "本地识别已就绪" : "需要配置 Whisper 工具与模型").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            HStack { Text("字号"); Spacer(); Text("\(Int(model.fontSize)) pt").foregroundStyle(.secondary) }.font(.caption)
            Slider(value: $model.fontSize, in: 20...48, step: 1).tint(accent)
            HStack { Text("提词位置"); Spacer(); Text("顶部 ↔ 底部").foregroundStyle(.secondary) }.font(.caption)
            Slider(value: $model.overlayPosition, in: 0...1).tint(accent)
            Text("拖动框顶移动 · 拖动右下角缩放").font(.caption2).foregroundStyle(.secondary)
            HStack { Text("底色浓度"); Spacer(); Text("\(Int(model.overlayOpacity * 100))%").foregroundStyle(.secondary) }.font(.caption)
            Slider(value: $model.overlayOpacity, in: 0.25...0.9).tint(accent)
        }
    }
    private var beautyControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("美颜与调色").font(.headline)
                Spacer()
                Toggle("人脸美颜", isOn: $model.beautyEnabled).toggleStyle(.switch).tint(accent)
            }
            Text("单人正面效果最佳 · 全程本地 · 滤镜独立生效").font(.caption).foregroundStyle(.secondary)
            Picker("调整分类", selection: $beautyPage) {
                Text("基础美颜").tag(0); Text("五官调整").tag(1); Text("滤镜调色").tag(2)
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if beautyPage == 2 { colorControls }
                    else {
                        Group {
                            if beautyPage == 0 {
                                appearanceSlider("磨皮", value: $model.skinSmoothing, hint: "平滑细小纹理，保护眼睛和嘴唇")
                                appearanceSlider("瘦脸", value: $model.faceSlimming, hint: "局部收拢左右脸颊，保留面部中心")
                            }
                            ForEach(FaceAdjustment.allCases.filter { $0.isFeature == (beautyPage == 1) }, id: \.rawValue) { control in
                                appearanceSlider(control.title, value: Binding(get: { model.faceAdjustments[control] }, set: { model.faceAdjustments[control] = $0 }), range: control.range, hint: control.hint)
                            }
                        }.disabled(!model.beautyEnabled)
                    }
                }.padding(.vertical, 4).padding(.trailing, 8)
            }.frame(height: 350).id(beautyPage)
            Divider()
            Toggle("预览原图对比", isOn: $model.compareOriginal).disabled(!model.currentBeautySettings.hasEffect)
            Text("对比只改变预览；录像仍保存当前美颜与调色。强度为零不应用该项。").font(.caption).foregroundStyle(.secondary)
            Text(model.beautyStatus.message).font(.caption).foregroundStyle(beautyIsApplied ? accent : .secondary)
            HStack {
                Button("本页归零") { model.resetBeautyPage(beautyPage) }
                Button("全部归零") { model.resetAllAppearance() }
                Spacer()
                Button("完成") { showBeauty = false }
            }
        }.padding(20).frame(width: 450)
    }
    private func appearanceSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Button { value.wrappedValue = 0 } label: { Image(systemName: "arrow.counterclockwise").font(.caption) }
                    .buttonStyle(.plain).help("\(title)归零").accessibilityLabel("\(title)归零")
            }.font(.callout)
            Slider(value: value, in: range).tint(accent).accessibilityLabel("\(title)强度")
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                ForEach(ColorPreset.allCases, id: \.rawValue) { preset in
                    Button { model.colorGrading.preset = preset } label: {
                        Text(preset.title).font(.callout).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(model.colorGrading.preset == preset ? accent.opacity(0.2) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.colorGrading.preset == preset ? accent : .clear))
                    }.buttonStyle(.plain).accessibilityLabel("\(preset.title)滤镜")
                        .accessibilityAddTraits(model.colorGrading.preset == preset ? .isSelected : [])
                }
            }
            Text(model.colorGrading.preset.detail).font(.caption).foregroundStyle(.secondary)
            appearanceSlider("滤镜", value: $model.colorGrading.intensity, hint: "只影响所选滤镜，手动调色独立保留")
                .disabled(model.colorGrading.preset == .none)
            Divider()
            appearanceSlider("曝光", value: $model.colorGrading.exposure, range: -1...1, hint: "压暗 ↔ 提亮")
            appearanceSlider("对比", value: $model.colorGrading.contrast, range: -1...1, hint: "柔和 ↔ 强烈")
            appearanceSlider("饱和", value: $model.colorGrading.saturation, range: -1...1, hint: "淡雅 ↔ 鲜明")
            appearanceSlider("冷暖", value: $model.colorGrading.warmth, range: -1...1, hint: "偏冷 ↔ 偏暖")
        }
    }
    private var beautyIsApplied: Bool {
        model.beautyStatus == .tracking || model.beautyStatus == .original || model.beautyStatus == .colorOnly
    }
    private var beautyLiveLabel: String {
        switch model.beautyStatus {
        case .tracking: return "人脸美颜生效" + (model.colorGrading.hasEffect ? " · 调色生效" : "")
        case .colorOnly: return "调色生效 · 未应用人脸调整"
        case .original: return "预览原图 · 视频保存当前效果"
        case .searching: return "未找到可靠人脸 · 当前原图"
        case .neutral: return "美颜强度为零 · 当前原图"
        case .unavailable: return "图像处理异常"
        case .waitingForCamera: return "图像处理待命"
        case .off: return "效果切换中"
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("本地识别设置").font(.title2.weight(.semibold))
            Text("使用 whisper.cpp 多语言 base 或 small 模型。配置完成后可断网录制。首次安装请运行项目中的 scripts/setup-whisper.sh。").font(.callout).foregroundStyle(.secondary)
            Text("whisper-cli 可执行文件").font(.headline)
            HStack { TextField("可执行文件路径", text: $model.executablePath); Button("选择…") { model.choosePath(model: false) } }
            Text("GGML 多语言模型").font(.headline)
            HStack { TextField("ggml-base.bin", text: $model.modelPath); Button("选择…") { model.choosePath(model: true) } }
            Label(model.whisperReady ? "文件检查通过" : "工具或模型未就绪，请检查路径", systemImage: model.whisperReady ? "checkmark.circle" : "exclamationmark.circle")
                .font(.callout).foregroundStyle(model.whisperReady ? accent : .orange)
            Text("当前实现每次识别使用最近 2–6 秒音频，只运行一个推理任务；负载较高时直接使用最新音频，避免积压。界面中的“推理”时间不包含音频收集等待。需在目标 Mac 实测跟随延迟。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { showSettings = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 620)
    }
    private var timeString: String {
        let total = Int(model.elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

private struct StudioButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(isEnabled ? Color.black : Color.white.opacity(0.45))
            .background(isEnabled ? accent.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

