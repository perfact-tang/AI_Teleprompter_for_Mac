# 本地提词 LocalPrompter

面向 Apple Silicon Mac 的原生 SwiftUI 提词录制 MVP。根据《Mac智能提词录制工具_MVP开发需求.docx》实现：UTF-8 TXT / Markdown 导入、中文、日文与英语、本地摄像头预览、可调提词、暂停续录、H.264 / AAC MOV 保存、whisper.cpp 离线识别与局部模糊对齐。没有服务器、账户或云端语音请求。

## 运行

需要完整 Xcode（建议 15 或更新版本），macOS 13+，摄像头与麦克风。工程针对 arm64。

1. 打开 `LocalPrompter.xcodeproj`，选择 **LocalPrompter → My Mac**，按 ⌘R。
2. 导入 `.txt` / `.md`，或直接编辑右侧稿件；选择中文 / 日本語 / 英语（English）。
3. 初次可先关闭“语音自动跟随”，点击“开启摄像头”，授予摄像头与麦克风权限，验证基础录制。
4. 提词文字居中显示。按住框顶“拖动提词框”移动位置，拖动右下角手柄调整宽高；点击“复位”恢复默认居中布局。位置和大小会自动保留。设置字号、底色后点击“开始录制”。可多次暂停 / 继续，点击“结束并保存”选择 `.mov` 路径。
5. 安装本地识别组件后，启用自动跟随。点击预览中的段落可以手动定位，回到开头按钮可重置。

也可直接构建独立应用（无需付费开发者账户）：

```bash
./scripts/build-app.sh release
open dist/LocalPrompter.app
```

这是本机 ad-hoc 签名应用，不是经公证的公开分发包。请运行 `.app`；直接 `swift run` 缺少应用包内的权限用途说明，不适合作为摄像头入口。Xcode 工程已配置相同的 Info.plist 和本机签名。

## 安装本地 Whisper

应用本身没有 Swift 第三方依赖。识别组件独立安装，首次安装需要 Git、CMake 和网络；实际录制不联网。CMake 可通过已有的包管理器安装。

```bash
./scripts/setup-whisper.sh base
# 比较 small 时再执行：
./scripts/setup-whisper.sh small
```

安装脚本固定 whisper.cpp `v1.8.2`，启用 Metal，使用当前 Xcode 的 macOS SDK。默认安装到：

```text
~/Library/Application Support/LocalPrompter/whisper.cpp/
  build/bin/whisper-cli
  models/ggml-base.bin
  models/ggml-small.bin     # 仅安装 small 后存在
```

“识别设置”中可手动选择 CLI 与模型。必须使用**多语言**模型，不能用 `base.en` / `small.en`。更换模型不需要重新编译应用。脚本已存在的源码目录会沿用其版本；需要更新时明确管理该目录。

开发时可将安装位置放在项目内部（已被 Git 忽略）；从此源码编译的应用会自动检测该路径：

```bash
LOCALPROMPTER_WHISPER_DIR="$PWD/.local/whisper.cpp" ./scripts/setup-whisper.sh base
```

上游构建、模型和 CLI 参数参考：[whisper.cpp](https://github.com/ggml-org/whisper.cpp/tree/v1.8.2)、[CLI 源码](https://github.com/ggml-org/whisper.cpp/blob/v1.8.2/examples/cli/cli.cpp)。

## 美颜与滤镜

新增基础美颜、五官调整、滤镜调色三个标签页，完整使用说明见 [美颜与滤镜说明](docs/APPEARANCE.md)。支持磨皮、小脸、小头、窄脸、颅骨、短脸、大眼、瘦鼻、鼻头、嘴型，并保留独立瘦脸。提供自然、清透、冷白皮、高清四种自研配色和曝光 / 对比 / 饱和 / 冷暖调色。


点击窗口右上角“美颜与滤镜”，开启人脸美颜后可分别调整各项效果。初始自然强度为磨皮 35%、瘦脸 20%；开关和强度保存在本机，重启继续使用。录制过程中也可以调节。

- 磨皮使用面部局部双边滤波，降低细小纹理，同时保护眼睛和嘴唇。不会把整个画面一起模糊。
- 瘦脸用人脸轮廓定位左右脸颊，做小范围向内形变，保护鼻子、嘴巴所在的中心区域。
- “预览原图对比”只改变预览；**录制仍然使用当前美颜参数**。需要录制完全原图时关闭人脸美颜，选择原色并归零所有手动调色。
- 适合一个人、正面、光线充足的录制。没有找到可靠人脸、明显侧脸或大幅歪头时，人脸调整回退，所选全局调色继续生效。快速移动时检测会有短暂延迟；大强度局部形变也可能带动脸旁的背景，建议从低强度开始。
- 全局滤镜独立生效；无脸时保留调色，只有人脸调整回退。使用系统 Vision 和 Core Image，不下载美颜模型、不调用云端、不存储人脸特征或额外照片。人脸检测约每 0.12 秒尝试一次，同时最多一个任务；检测结果超过 0.4 秒失效。处理不可用时显示原因并回退原图。

## 实现与边界

- `CaptureRecorder`：单一串行队列管理 AVCaptureSession、视频 / 音频输出与 AVAssetWriter；同一个麦克风样本用于 AAC 写入和 16 kHz 单声道识别输入。没有第二路麦克风或系统语音服务。
- 提词是 SwiftUI 覆盖层，不进入视频。美颜通过 `BeautyVideoPipeline` 在摄像头帧进入预览和写入器之前统一处理；默认预览和录制使用同一处理后的视频帧。原图对比是单独的预览分支。画面和提词正常方向显示。
- 暂停期间丢弃样本；继续时扣除同一个累计时间偏移，重建音视频样本 PTS / DTS，保持两轨相对时间。暂停不会切成多个文件。
- `SpeechRecognizer` 协议隔离 whisper.cpp。当前通过本地 CLI 处理 2–6 秒重叠窗口，每次重新加载模型；只允许一个推理任务，缓冲有上限，避免识别积压。暂停 / 结束会终止旧任务、丢弃过期结果。单次 45 秒超时会停止识别，录制继续。
- `ScriptAligner`：忽略标点和空格、统一大小写、全角字符与繁简字，统一逐位数字及含十 / 百 / 千的常见中日文数词（例如“三百二十”与“320”）。局部编辑距离匹配、0.72 阈值、最少 4 个有效字符、限制单次推进、较大跳句需两次证据、重复结果不重复推进。尚不处理万以上数词、口语省略（如“一百二”）或日语假名 / 汉字同音转换。
- 提词稿按短句和最多 60 字拆分，当前片段稳定置于滚动区上方，用 0.45 秒动画移动。是片段跟随，不是逐字卡拉 OK。
- 字号、位置和底色可在录制时调整；稿件、语言和模型在录制期间锁定。稿件内容与识别路径在本机 UserDefaults 保留。
- 显示已录时长、掉帧数、识别窗口长度、单次推理耗时和文本匹配分数。匹配分数不是声学置信度；推理耗时不等于端到端跟随延迟。base / small 的表现须在目标 M2 上测量。

取消保存不会丢失已完成的视频；界面保留“保存视频”入口，并阻止新的录制覆盖它。退出时的已完成视频也留在恢复目录：

```text
~/Library/Application Support/LocalPrompter/Recordings/
```

写入失败会提示并保留能找到的临时文件，低于 150 MB 可用空间会暂停录制。强制退出 / 断电可能使未完成的 MOV 缺少索引，**无法保证恢复**；正常退出时会先完成写入。恢复目录不会自动删除历史文件，请自行整理。

## 验证

```bash
swift test
xcodebuild -project LocalPrompter.xcodeproj -scheme LocalPrompter \
  -destination 'platform=macOS,arch=arm64' -configuration Debug build
```

受限执行环境中若系统模块缓存不可写，可使用：

```bash
CLANG_MODULE_CACHE_PATH=/tmp/localprompter-module-cache \
  swift test --disable-sandbox --scratch-path /tmp/localprompter-build
```

原有 10 项自动测试覆盖中日文、繁简、标点 / 全角 / 数字、口误、静音 / 无关结果、重复、跳句、重置和多次暂停时钟。摄像头硬件、麦克风、长时音画同步及 M2 性能仍需实际验收，见 [手工验收清单](docs/ACCEPTANCE.md)。

当前共 31 项测试，覆盖基础录制时钟 / 对齐、美颜像素、九个新增形变、四款滤镜、连续编码、逐项成片回读及控制器重启恢复。三个真实素材集成场景默认跳过；指定本机正面图片与视频可完整运行（个人素材不放入仓库）：

```bash
BEAUTY_FACE_FIXTURE="/absolute/path/to/frontal-face.png" \
BEAUTY_VIDEO_FIXTURE="/absolute/path/to/local-video.mov" \
swift test --disable-sandbox
```

集成测试的图片和短视频输出到系统临时目录，便于检查；不采集摄像头。实时摄像头、长时间美颜与语音同时运行的性能仍需实际试录。
