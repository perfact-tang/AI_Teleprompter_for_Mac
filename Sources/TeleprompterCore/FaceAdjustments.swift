import Foundation

public enum FaceAdjustment: String, CaseIterable {
    case smallFace, smallHead, narrowFace, skull, shortFace, bigEyes, noseWidth, noseTip, mouthShape
    public var title: String {
        switch self {
        case .smallFace: return "小脸"
        case .smallHead: return "小头"
        case .narrowFace: return "窄脸"
        case .skull: return "颅骨"
        case .shortFace: return "短脸"
        case .bigEyes: return "大眼"
        case .noseWidth: return "瘦鼻"
        case .noseTip: return "鼻头"
        case .mouthShape: return "嘴型"
        }
    }
    public var hint: String {
        switch self {
        case .smallFace: return "整体收小面部，保留头发轮廓"
        case .smallHead: return "连同头发区域轻微缩头，调整头身比例"
        case .narrowFace: return "横向收窄整张脸"
        case .skull: return "轻抬颅顶、饱满上方头型；为二维颅顶形变"
        case .shortFace: return "收短中下庭，轻抬下巴"
        case .bigEyes: return "以双眼关键点为中心自然放大"
        case .noseWidth: return "收窄鼻梁和鼻翼"
        case .noseTip: return "局部收小鼻尖和鼻头"
        case .mouthShape: return "负值收小，正值放大嘴唇轮廓"
        }
    }
    public var isFeature: Bool { [.bigEyes, .noseWidth, .noseTip, .mouthShape].contains(self) }
    public var range: ClosedRange<Double> { self == .mouthShape ? -1...1 : 0...1 }
    var keyPath: WritableKeyPath<FaceAdjustments, Double> {
        switch self {
        case .smallFace: return \.smallFace
        case .smallHead: return \.smallHead
        case .narrowFace: return \.narrowFace
        case .skull: return \.skull
        case .shortFace: return \.shortFace
        case .bigEyes: return \.bigEyes
        case .noseWidth: return \.noseWidth
        case .noseTip: return \.noseTip
        case .mouthShape: return \.mouthShape
        }
    }
}

public struct FaceAdjustments: Equatable, Codable {
    public var smallFace = 0.0
    public var smallHead = 0.0
    public var narrowFace = 0.0
    public var skull = 0.0
    public var shortFace = 0.0
    public var bigEyes = 0.0
    public var noseWidth = 0.0
    public var noseTip = 0.0
    public var mouthShape = 0.0
    public init() {}
    public subscript(_ control: FaceAdjustment) -> Double {
        get { self[keyPath: control.keyPath] }
        set { self[keyPath: control.keyPath] = ColorGradingSettings.clamp(newValue, control.range) }
    }
    public var sanitized: Self {
        var copy = self
        for control in FaceAdjustment.allCases { copy[control] = self[control] }
        return copy
    }
    public var hasEffect: Bool { let values = sanitized; return FaceAdjustment.allCases.contains { values[$0] != 0 } }
}
