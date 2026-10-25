import XCTest
@testable import TeleprompterCore
final class ScriptAlignerTests: XCTestCase {
    func testChinesePunctuationAndProgress() {
        var aligner = ScriptAligner(script: "大家好，欢迎来到今天的分享。今天我们介绍本地提词工具。")
        let result = aligner.consume("大家好欢迎来到今天的分享")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.characterOffset, "大家好，欢迎来到今天的分享".count)
        let position = aligner.position
        XCTAssertNil(aligner.consume(""))
        XCTAssertNil(aligner.consume("这完全是无关的噪声内容"))
        XCTAssertEqual(aligner.position, position)
        XCTAssertNotNil(aligner.consume("今天我们介绍本地提词工具"))
    }
    func testJapaneseAndWidth() {
        var aligner = ScriptAligner(script: "こんにちは。今日はＭａｃで動画を撮影します。よろしくお願いします。")
        XCTAssertNotNil(aligner.consume("こんにちは今日はMacで動画を撮影します"))
        let old = aligner.position
        XCTAssertNil(aligner.consume("こんにちは"))
        XCTAssertEqual(aligner.position, old)
    }
    func testEnglishCasePunctuationAndContractions() {
        var aligner = ScriptAligner(script: "Hello, everyone! Welcome to LocalPrompter. Let's record a video.")
        XCTAssertEqual(aligner.consume("HELLO EVERYONE")?.characterOffset, "Hello, everyone".count)
        XCTAssertNotNil(aligner.consume("welcome to localprompter"))
        let position = aligner.position
        XCTAssertNil(aligner.consume("welcome to localprompter"))
        XCTAssertEqual(aligner.position, position)
        XCTAssertNotNil(aligner.consume("lets record a video"))
    }
    func testFuzzyMatchAndReset() {
        var aligner = ScriptAligner(script: "欢迎来到本地智能提词工具的演示。")
        XCTAssertNotNil(aligner.consume("欢迎来到本地智能提词工具的展示"))
        aligner.seek(characterOffset: 0)
        XCTAssertEqual(aligner.position, 0)
        XCTAssertNotNil(aligner.consume("欢迎来到本地智能提词工具的演示"))
    }
    func testLargeJumpRequiresEvidence() {
        var aligner = ScriptAligner(script: String(repeating: "甲", count: 40) + "现在开始介绍我们的全新工具")
        XCTAssertNil(aligner.consume("现在开始介绍我们的全新工具"))
        XCTAssertNotNil(aligner.consume("现在开始介绍我们的全新工具"))
    }
    func testEmptyAndVeryShort() {
        var aligner = ScriptAligner()
        XCTAssertNil(aligner.consume("你好世界"))
        aligner.load("你好")
        XCTAssertNil(aligner.consume("你好"))
    }
    func testDuplicateObservationDoesNotSkipRepeatedSentence() {
        var aligner = ScriptAligner(script: "欢迎使用本地提词。欢迎使用本地提词。现在开始演示。")
        XCTAssertNotNil(aligner.consume("欢迎使用本地提词"))
        let position = aligner.position
        XCTAssertNil(aligner.consume("欢迎使用本地提词"))
        XCTAssertEqual(aligner.position, position)
    }
    func testNormalization() {
        XCTAssertEqual(ScriptAligner.normalize("ＡＢＣ，１２３！"), ScriptAligner.normalize("abc一二三"))
        XCTAssertEqual(ScriptAligner.normalize("三百二十个视频"), ScriptAligner.normalize("320个视频"))
        XCTAssertEqual(ScriptAligner.normalize("十二月三十一日"), ScriptAligner.normalize("12月31日"))
    }
    func testNumericNormalizationPreservesOriginalOffsets() {
        var aligner = ScriptAligner(script: "我们今天准备三百二十个视频。然后开始录制。")
        let result = aligner.consume("我们今天准备320个视频")
        XCTAssertEqual(result?.characterOffset, "我们今天准备三百二十个视频".count)
    }
    func testTraditionalWhisperOutputMatchesSimplifiedScript() {
        var aligner = ScriptAligner(script: "我们使用本地智能提词工具录制视频。所有声音都在这台电脑上处理。")
        XCTAssertNotNil(aligner.consume("我們使用本地智能提詞工具錄製視頻"))
        XCTAssertNotNil(aligner.consume("所有聲音都在這台電腦上處理"))
    }
    func testPauseClockPreservesAVDifference() {
        var clock = RecordingTimeline()
        clock.pause(at: 10); clock.pause(at: 11); clock.resume(at: 15)
        XCTAssertEqual(clock.adjusted(15), 10)
        XCTAssertEqual(clock.adjusted(15.02) - clock.adjusted(15), 0.02, accuracy: 0.0001)
        clock.pause(at: 20); clock.resume(at: 23)
        XCTAssertEqual(clock.adjusted(23), 15)
        clock.resume(at: 30)
        XCTAssertEqual(clock.pauseOffset, 8)
    }
}
