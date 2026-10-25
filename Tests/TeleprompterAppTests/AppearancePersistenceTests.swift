import XCTest
import TeleprompterCore
@testable import TeleprompterApp

@MainActor
final class AppearancePersistenceTests: XCTestCase {
    private func withPreferences(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "LocalPrompter.Tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        try body(preferences)
    }
    func testStartupNeverOverwritesUnreadAppearanceSettings() throws {
        try withPreferences { preferences in
            var face = FaceAdjustments(); face.bigEyes = 0.26; face.noseWidth = 0.42; face.smallHead = 0.3
            let color = ColorGradingSettings(preset: .coolWhite, intensity: 0.81, warmth: -0.15)
            preferences.set(true, forKey: "beautyEnabled")
            preferences.set(0.72, forKey: "skinSmoothing"); preferences.set(0.41, forKey: "faceSlimming")
            preferences.set(try JSONEncoder().encode(face), forKey: "faceAdjustmentsV1")
            preferences.set(try JSONEncoder().encode(color), forKey: "colorGradingV1")
            for _ in 0..<2 {
                let model = TeleprompterController(defaults: preferences)
                XCTAssertEqual(model.skinSmoothing, 0.72); XCTAssertEqual(model.faceSlimming, 0.41)
                XCTAssertEqual(model.faceAdjustments, face); XCTAssertEqual(model.colorGrading, color)
                XCTAssertEqual(try JSONDecoder().decode(ColorGradingSettings.self, from: XCTUnwrap(preferences.data(forKey: "colorGradingV1"))), color)
            }
        }
    }
    func testPageResetKeepsOtherPagesAndSurvivesReload() throws {
        try withPreferences { preferences in
            let model = TeleprompterController(defaults: preferences)
            model.faceAdjustments.bigEyes = 0.6; model.faceAdjustments.smallHead = 0.3
            model.colorGrading = ColorGradingSettings(preset: .clear)
            model.resetBeautyPage(1)
            XCTAssertEqual(model.faceAdjustments.bigEyes, 0)
            XCTAssertEqual(model.faceAdjustments.smallHead, 0.3)
            XCTAssertEqual(model.colorGrading.preset, .clear)
            let restored = TeleprompterController(defaults: preferences)
            XCTAssertEqual(restored.faceAdjustments, model.faceAdjustments)
            XCTAssertEqual(restored.colorGrading, model.colorGrading)
        }
    }
    func testFullResetHasNoEffectAndColorIsIndependentOfFaceSwitch() {
        withPreferences { preferences in
            let model = TeleprompterController(defaults: preferences)
            model.beautyEnabled = false
            model.colorGrading.preset = .natural
            XCTAssertTrue(model.currentBeautySettings.hasEffect)
            XCTAssertFalse(model.currentBeautySettings.hasFaceEffect)
            model.faceAdjustments.noseTip = 0.6
            model.resetAllAppearance()
            XCTAssertFalse(model.currentBeautySettings.hasEffect)
            XCTAssertEqual(model.faceAdjustments, FaceAdjustments())
        }
    }
}
