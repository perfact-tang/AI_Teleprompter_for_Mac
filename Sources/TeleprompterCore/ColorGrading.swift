import CoreImage

public enum ColorPreset: String, CaseIterable, Codable {
    case none, natural, clear, coolWhite, highDefinition
    public var title: String {
        switch self {
        case .none: return "原色"
        case .natural: return "自然"
        case .clear: return "清透"
        case .coolWhite: return "冷白皮"
        case .highDefinition: return "高清"
        }
    }
    public var detail: String {
        switch self {
        case .none: return "保留原始色彩"
        case .natural: return "轻提亮，保留自然肤色"
        case .clear: return "通透阴影，柔和高光"
        case .coolWhite: return "偏冷肤色，柔亮中间调"
        case .highDefinition: return "增强局部清晰度与层次，不改变分辨率"
        }
    }
}

public struct ColorGradingSettings: Equatable, Codable {
    public var preset: ColorPreset
    public var intensity: Double
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var warmth: Double
    public init(preset: ColorPreset = .none, intensity: Double = 0.65, exposure: Double = 0,
                contrast: Double = 0, saturation: Double = 0, warmth: Double = 0) {
        self.preset = preset; self.intensity = Self.clamp(intensity, 0...1)
        self.exposure = Self.clamp(exposure, -1...1); self.contrast = Self.clamp(contrast, -1...1)
        self.saturation = Self.clamp(saturation, -1...1); self.warmth = Self.clamp(warmth, -1...1)
    }
    public var hasEffect: Bool {
        (preset != .none && intensity > 0) || exposure != 0 || contrast != 0 || saturation != 0 || warmth != 0
    }
    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double { value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : 0 }
    public var sanitized: Self { Self(preset: preset, intensity: intensity, exposure: exposure, contrast: contrast, saturation: saturation, warmth: warmth) }
}

/// Original recipes inspired by common portrait looks, not Meitu LUTs/SDKs.
/// Global color grading remains active even if no reliable face is detected.
public enum ColorGrading {
    public static func apply(_ image: CIImage, settings input: ColorGradingSettings) -> CIImage {
        let settings = input.sanitized
        guard settings.hasEffect else { return image }
        var result = image
        if settings.preset != .none && settings.intensity > 0 {
            var styled = image
            switch settings.preset {
            case .none: break
            case .natural:
                styled = controls(styled, exposure: 0.06, contrast: 1.025, saturation: 1.025)
                    .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.05])
            case .clear:
                styled = controls(styled, exposure: 0.12, contrast: 1.04, saturation: 1.035)
                    .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.16, "inputHighlightAmount": 0.93])
                styled = curve(styled, values: [0, 0.265, 0.535, 0.785, 1])
            case .coolWhite:
                styled = controls(styled, exposure: 0.12, contrast: 1.01, saturation: 0.96)
                styled = balance(styled, red: 0.985, green: 1.006, blue: 1.04)
                styled = curve(styled, values: [0, 0.28, 0.55, 0.785, 1])
            case .highDefinition:
                styled = controls(styled, exposure: 0.02, contrast: 1.075, saturation: 1.025)
                    .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.07])
                    .clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.4, kCIInputIntensityKey: 0.38])
            }
            result = settings.intensity >= 1 ? styled : image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: styled, kCIInputTimeKey: settings.intensity])
        }
        if settings.exposure != 0 || settings.contrast != 0 || settings.saturation != 0 {
            result = controls(result, exposure: settings.exposure * 1.5, contrast: 1 + settings.contrast * 0.3, saturation: 1 + settings.saturation * 0.5)
        }
        if settings.warmth != 0 {
            result = balance(result, red: 1 + settings.warmth * 0.07, green: 1, blue: 1 - settings.warmth * 0.07)
        }
        return result.cropped(to: image.extent)
    }
    private static func controls(_ image: CIImage, exposure: Double, contrast: Double, saturation: Double) -> CIImage {
        image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation, kCIInputBrightnessKey: 0])
    }
    private static func balance(_ image: CIImage, red: Double, green: Double, blue: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }
    private static func curve(_ image: CIImage, values: [Double]) -> CIImage {
        var parameters: [String: Any] = [:]
        for i in 0..<5 { parameters["inputPoint\(i)"] = CIVector(x: Double(i) * 0.25, y: values[i]) }
        return image.applyingFilter("CIToneCurve", parameters: parameters)
    }
}
