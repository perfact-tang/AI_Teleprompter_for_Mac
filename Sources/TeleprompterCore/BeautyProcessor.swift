import AVFoundation
import CoreImage
import Vision

public struct BeautySettings: Equatable {
    public var enabled: Bool
    public var smoothing: Double
    public var slimming: Double
    public var adjustments: FaceAdjustments
    public var color: ColorGradingSettings
    public init(enabled: Bool = false, smoothing: Double = 0.35, slimming: Double = 0.2,
                adjustments: FaceAdjustments = FaceAdjustments(), color: ColorGradingSettings = ColorGradingSettings()) {
        self.enabled = enabled
        self.smoothing = smoothing.isFinite ? min(1, max(0, smoothing)) : 0
        self.slimming = slimming.isFinite ? min(1, max(0, slimming)) : 0
        self.adjustments = adjustments.sanitized; self.color = color.sanitized
    }
    public var hasFaceEffect: Bool { enabled && (smoothing > 0 || slimming > 0 || adjustments.hasEffect) }
    public var hasEffect: Bool { hasFaceEffect || color.hasEffect }
}

/// Normalized, bottom-left-origin coordinates, shared by Vision and Core Image.
public struct BeautyFace {
    public let bounds: CGRect
    public let leftEye: CGPoint
    public let rightEye: CGPoint
    public let mouth: CGPoint
    public let leftCheek: CGPoint
    public let rightCheek: CGPoint
    public let nose: CGPoint
    public let noseTip: CGPoint
    public init(bounds: CGRect, leftEye: CGPoint, rightEye: CGPoint, mouth: CGPoint,
                leftCheek: CGPoint? = nil, rightCheek: CGPoint? = nil, nose: CGPoint? = nil, noseTip: CGPoint? = nil) {
        self.bounds = bounds; self.leftEye = leftEye; self.rightEye = rightEye; self.mouth = mouth
        self.leftCheek = leftCheek ?? CGPoint(x: bounds.minX + bounds.width * 0.17, y: bounds.minY + bounds.height * 0.4)
        self.rightCheek = rightCheek ?? CGPoint(x: bounds.maxX - bounds.width * 0.17, y: bounds.minY + bounds.height * 0.4)
        self.nose = nose ?? CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.48)
        self.noseTip = noseTip ?? CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.4)
    }
    func blended(with next: BeautyFace, amount: CGFloat) -> BeautyFace {
        func point(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount) }
        return BeautyFace(bounds: CGRect(origin: point(bounds.origin, next.bounds.origin),
            size: CGSize(width: bounds.width + (next.bounds.width - bounds.width) * amount, height: bounds.height + (next.bounds.height - bounds.height) * amount)),
            leftEye: point(leftEye, next.leftEye), rightEye: point(rightEye, next.rightEye), mouth: point(mouth, next.mouth),
            leftCheek: point(leftCheek, next.leftCheek), rightCheek: point(rightCheek, next.rightCheek), nose: point(nose, next.nose), noseTip: point(noseTip, next.noseTip))
    }
}

public enum BeautyStatus: Equatable {
    case off, waitingForCamera, neutral, searching, tracking, colorOnly, original, unavailable(String)
    public var message: String {
        switch self {
        case .off: return "美颜未开启"
        case .waitingForCamera: return "开启摄像头后开始人脸跟随"
        case .neutral: return "当前强度为零 · 显示并录制原图"
        case .searching: return "未检测到正面人脸 · 显示原图"
        case .tracking: return "人脸跟随中 · 效果会保存到视频"
        case .colorOnly: return "调色已生效 · 当前未应用人脸调整"
        case .original: return "原图对比 · 录制仍保留美颜与调色"
        case .unavailable(let reason): return "美颜未生效：\(reason)"
        }
    }
}

/// Capture-queue-only renderer. Face detection is asynchronous, with at most one
/// request in flight. Cached landmarks expire; no unbounded per-frame work queue.
public final class BeautyProcessor {
    private let context: CIContext
    private let smoothKernel: CIKernel?
    private let slimKernel: CIWarpKernel?
    private let detectionQueue = DispatchQueue(label: "localprompter.face", qos: .userInitiated)
    private let lock = NSLock()
    private var detecting = false
    private var detectedFace: BeautyFace?
    private var detectedAt: TimeInterval = -.infinity
    private var lastDetection: TimeInterval = -.infinity
    private var detectionError: String?
    private var epoch = 0
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var previousEnabled = false
    public private(set) var status: BeautyStatus = .off
    public var isAvailable: Bool { smoothKernel != nil && slimKernel != nil }

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
        smoothKernel = CIKernel(source: Self.smoothingSource)
        slimKernel = CIWarpKernel(source: Self.slimmingSource)
    }

    /// Called on capture queue even when idle/paused, so preview remains live.
    /// Nil means bypass: pass the original buffer to BOTH preview and recorder.
    public func process(_ buffer: CVPixelBuffer, settings: BeautySettings, time: TimeInterval) -> CVPixelBuffer? {
        if previousEnabled != settings.hasFaceEffect {
            lock.lock(); epoch += 1; detectedFace = nil; detectedAt = -.infinity
            lastDetection = -.infinity; detectionError = nil; lock.unlock()
            previousEnabled = settings.hasFaceEffect
        }
        guard settings.hasEffect else { status = settings.enabled ? .neutral : .off; return nil }
        var face: BeautyFace?
        var faceStatus: BeautyStatus = .off
        if settings.hasFaceEffect {
            if isAvailable {
                detectIfNeeded(buffer, time: time)
                lock.lock()
                face = time - detectedAt <= 0.4 ? detectedFace : nil
                let error = detectionError
                lock.unlock()
                faceStatus = face != nil ? .tracking : (error.map { .unavailable($0) } ?? .searching)
            } else { faceStatus = .unavailable("图像处理内核不可用") }
        }
        guard face != nil || settings.color.hasEffect else { status = faceStatus; return nil }
        let source = CIImage(cvPixelBuffer: buffer)
        guard let image = filteredImage(source, face: face, settings: settings), let output = outputBuffer(size: source.extent.size) else {
            status = .unavailable("图像缓冲不足或滤镜失败"); return nil
        }
        context.render(image, to: output, bounds: source.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        status = face != nil ? .tracking : .colorOnly
        return output
    }

    /// Deterministic rendering entry point used by pixel-level regression tests.
    public func filteredImage(_ source: CIImage, face: BeautyFace?, settings: BeautySettings) -> CIImage? {
        guard settings.hasEffect else { return source }
        guard settings.hasFaceEffect, let face else { return ColorGrading.apply(source, settings: settings.color) }
        guard let smoothKernel, let slimKernel else { return nil }
        let extent = source.extent
        let width = extent.width, height = extent.height
        guard width > 0, height > 0, face.bounds.width > 0, face.bounds.height > 0 else { return source }
        let rect = CGRect(x: extent.minX + face.bounds.minX * width, y: extent.minY + face.bounds.minY * height,
                          width: face.bounds.width * width, height: face.bounds.height * height)
        func point(_ p: CGPoint) -> CIVector { CIVector(x: extent.minX + p.x * width, y: extent.minY + p.y * height) }
        let faceVector = CIVector(x: rect.midX, y: rect.midY, z: rect.width * 0.5, w: rect.height * 0.55)
        var result = source
        if settings.smoothing > 0 {
            let step = max(1, rect.width / 150)
            guard let smoothed = smoothKernel.apply(extent: extent, roiCallback: { _, roi in roi.insetBy(dx: -step * 3, dy: -step * 3) },
                arguments: [source.clampedToExtent(), faceVector, point(face.leftEye), point(face.rightEye), point(face.mouth), settings.smoothing, step]) else { return nil }
            result = smoothed.cropped(to: extent)
        }
        if settings.slimming > 0 || settings.adjustments.hasEffect {
            let a = settings.adjustments.sanitized
            // Bounds include the head envelope above the Vision face box.
            let margin = max(rect.width, rect.height) * 0.5
            guard let slimmed = slimKernel.apply(extent: extent, roiCallback: { _, roi in roi.insetBy(dx: -margin, dy: -margin) },
                image: result.clampedToExtent(), arguments: [faceVector, point(face.leftCheek), point(face.rightCheek), point(face.leftEye), point(face.rightEye), point(face.nose), point(face.noseTip), point(face.mouth),
                    CIVector(x: settings.slimming, y: a.smallFace, z: a.smallHead, w: a.narrowFace),
                    CIVector(x: a.skull, y: a.shortFace, z: a.bigEyes, w: a.noseWidth), CIVector(x: a.noseTip, y: a.mouthShape)]) else { return nil }
            result = slimmed.cropped(to: extent)
        }
        return ColorGrading.apply(result, settings: settings.color)
    }

    private func outputBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || size != poolSize {
            poolSize = size
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var result: CVPixelBuffer?
        let code = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary, &result)
        if let result, code == kCVReturnSuccess {
            // Rendered bytes are sRGB. Explicit tagging keeps preview and the
            // H.264 RGB-to-YUV conversion from guessing different transfer curves.
            CVBufferSetAttachment(result, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
            CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        }
        return code == kCVReturnSuccess ? result : nil
    }

    private func detectIfNeeded(_ buffer: CVPixelBuffer, time: TimeInterval) {
        lock.lock()
        guard !detecting, time - lastDetection >= 0.12 else { lock.unlock(); return }
        detecting = true; lastDetection = time
        let requestEpoch = epoch
        lock.unlock()
        // Retain one camera buffer only, never queue every captured frame.
        detectionQueue.async { [weak self] in
            guard let self else { return }
            let request = VNDetectFaceLandmarksRequest()
            let image = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 640 / max(image.extent.width, image.extent.height))
            do {
                try VNImageRequestHandler(ciImage: image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), orientation: .up).perform([request])
                let observation = request.results?.filter {
                    $0.confidence >= 0.65 && $0.boundingBox.width >= 0.08 && abs($0.yaw?.doubleValue ?? 0) < 0.55 && abs($0.roll?.doubleValue ?? 0) < 0.45
                }.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
                let found = observation.flatMap(Self.face)
                self.lock.lock(); defer { self.lock.unlock() }
                self.detecting = false
                guard requestEpoch == self.epoch else { return }
                self.detectionError = nil
                if let found {
                    if let old = self.detectedFace, hypot(old.bounds.midX - found.bounds.midX, old.bounds.midY - found.bounds.midY) < 0.1,
                       abs(old.bounds.width - found.bounds.width) < 0.08 {
                        self.detectedFace = old.blended(with: found, amount: 0.65)
                    } else { self.detectedFace = found }
                    // Timestamp is the source frame's time, so slow results expire.
                    self.detectedAt = time
                } else { self.detectedFace = nil }
            } catch {
                self.lock.lock(); defer { self.lock.unlock() }
                self.detecting = false
                guard requestEpoch == self.epoch else { return }
                self.detectedFace = nil; self.detectionError = "人脸检测暂不可用"
            }
        }
    }
    private static func face(_ observation: VNFaceObservation) -> BeautyFace? {
        let box = observation.boundingBox
        guard let landmarks = observation.landmarks, let left = landmarks.leftEye, let right = landmarks.rightEye,
              let lips = landmarks.outerLips, left.pointCount > 0, right.pointCount > 0, lips.pointCount > 0 else { return nil }
        func converted(_ p: CGPoint) -> CGPoint { CGPoint(x: box.minX + p.x * box.width, y: box.minY + p.y * box.height) }
        func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let points = region.normalizedPoints
            return converted(CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count), y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count)))
        }
        let eyes = [center(left), center(right)].sorted { $0.x < $1.x }
        // Pick jaw-contour points near cheek height rather than hard-coding the
        // Vision constellation index, which differs between request revisions.
        let contour = landmarks.faceContour?.normalizedPoints.map(converted) ?? []
        func cheek(leftSide: Bool) -> CGPoint? {
            contour.filter { leftSide ? $0.x < box.midX - box.width * 0.15 : $0.x > box.midX + box.width * 0.15 }
                .min { abs($0.y - (box.minY + box.height * 0.4)) < abs($1.y - (box.minY + box.height * 0.4)) }
        }
        let nose = landmarks.nose.map(center)
        let tip = landmarks.noseCrest?.normalizedPoints.min { $0.y < $1.y }.map(converted)
        return BeautyFace(bounds: box, leftEye: eyes[0], rightEye: eyes[1], mouth: center(lips), leftCheek: cheek(leftSide: true), rightCheek: cheek(leftSide: false), nose: nose, noseTip: tip)
    }

    private static let smoothingSource: String = {
        // Spatial/range bilateral weights preserve edges. The soft face mask
        // excludes eyes/brows and mouth, instead of blurring the whole frame.
        var taps = ""
        for y in -2...2 { for x in -2...2 {
            let spatial = exp(-Double(x * x + y * y) / 5)
            taps += "{ vec2 delta = vec2(\(x).0, \(y).0) * stepSize; vec4 c = sample(image, samplerTransform(image, p + delta)); vec3 d = c.rgb - original.rgb; float w = \(spatial) * exp(-dot(d,d) / 0.06); sum += c.rgb * w; weight += w; }\n"
        } }
        return """
        kernel vec4 smoothSkin(sampler image, vec4 face, vec2 leftEye, vec2 rightEye, vec2 mouth, float amount, float stepSize) {
            vec2 p = destCoord();
            vec4 original = sample(image, samplerTransform(image, p));
            vec2 local = (p - face.xy) / face.zw;
            float mask = 1.0 - smoothstep(0.65, 1.0, dot(local, local));
            vec2 eyeSize = vec2(face.z * 0.32, face.w * 0.19);
            float le = length((p - leftEye) / eyeSize);
            float re = length((p - rightEye) / eyeSize);
            float lip = length((p - mouth) / vec2(face.z * 0.46, face.w * 0.2));
            mask *= smoothstep(0.8, 1.35, le) * smoothstep(0.8, 1.35, re) * smoothstep(0.8, 1.3, lip);
            vec3 sum = vec3(0.0); float weight = 0.0;
            \(taps)
            return vec4(mix(original.rgb, sum / max(weight, 0.0001), mask * amount * 0.9), original.a);
        }
        """
    }()
    private static let slimmingSource = """
    float weightAt(vec2 p, vec2 center, vec2 radius) {
        vec2 d = (p - center) / radius;
        float w = max(0.0, 1.0 - dot(d, d));
        return w * w;
    }
    kernel vec2 reshapeFace(vec4 face, vec2 leftCheek, vec2 rightCheek, vec2 leftEye, vec2 rightEye, vec2 nose, vec2 noseTip, vec2 mouth, vec4 shape, vec4 feature, vec2 detail) {
        vec2 p = destCoord();
        vec2 q = p;
        float w = face.z * 2.0;
        float h = face.w / 0.55;
        // Small head: broad isotropic compression, including an estimated hair envelope.
        vec2 headCenter = face.xy + vec2(0.0, h * 0.16);
        float head = weightAt(p, headCenter, vec2(w * 0.9, h * 1.1));
        q += (p - headCenter) * shape.z * 0.16 * head;
        // Small face: compact facial area, smaller support than small-head.
        float facial = weightAt(p, face.xy, vec2(w * 0.7, h * 0.7));
        q += (p - face.xy) * shape.y * 0.16 * facial;
        // Narrow face changes width only, unlike the two isotropic controls.
        q.x += (p.x - face.x) * shape.w * 0.23 * facial;
        // Cranial vault: lift and round the estimated upper head silhouette.
        vec2 topCenter = face.xy + vec2(0.0, h * 0.53);
        float top = weightAt(p, topCenter, vec2(w * 0.72, h * 0.48));
        q -= (p - topCenter) * feature.x * 0.15 * top;
        q.y -= feature.x * h * 0.065 * top;
        // Short face: compress below the eye line, fading out above it.
        float eyeLine = (leftEye.y + rightEye.y) * 0.5;
        float lower = weightAt(p, face.xy - vec2(0.0, h * 0.15), vec2(w * 0.7, h * 0.62));
        q.y += min(0.0, p.y - eyeLine) * feature.y * 0.20 * lower;
        // Preserve the existing cheek slimming control as an independent adjustment.
        vec2 radius = vec2(face.z * 0.72, face.w * 0.62);
        float shift = face.z * 0.13 * shape.x;
        float wl = weightAt(p, leftCheek + vec2(shift, 0.0), radius);
        float wr = weightAt(p, rightCheek - vec2(shift, 0.0), radius);
        float centerProtection = smoothstep(face.z * 0.22, face.z * 0.48, abs(p.x - face.x));
        q.x += shift * (wr - wl) * centerProtection;
        // Eyes expand independently around the detected eye centers.
        float el = weightAt(p, leftEye, vec2(w * 0.16, h * 0.115));
        float er = weightAt(p, rightEye, vec2(w * 0.16, h * 0.115));
        q -= (p - leftEye) * feature.z * 0.28 * el;
        q -= (p - rightEye) * feature.z * 0.28 * er;
        // Nose bridge/alar width and the nose tip use different centers/support.
        float nw = weightAt(p, nose, vec2(w * 0.16, h * 0.25));
        q.x += (p.x - nose.x) * feature.w * 0.32 * nw;
        float nt = weightAt(p, noseTip, vec2(w * 0.14, h * 0.12));
        q += (p - noseTip) * detail.x * vec2(0.30, 0.22) * nt;
        // Signed lip size: negative shrinks, positive enlarges.
        float lips = weightAt(p, mouth, vec2(w * 0.25, h * 0.13));
        q -= (p - mouth) * detail.y * vec2(0.28, 0.25) * lips;
        // Bound combined displacement when several controls are maxed at once.
        vec2 delta = (q - p) / vec2(w, h);
        float amount = length(delta);
        if (amount > 0.18) { q = p + (q - p) * (0.18 / amount); }
        return q;
    }
    """
}
