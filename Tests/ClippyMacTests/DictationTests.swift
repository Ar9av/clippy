import XCTest
@testable import ClippyMac

final class DictationTests: XCTestCase {
    private let minimum = 4_000  // 0.25s at 16 kHz

    // MARK: - Speech stitching

    func testReturnsNilWhenVadFoundNoSpeech() {
        // The whole point of gating: an empty result must stop the pipeline
        // before Whisper sees a silent buffer and invents a sentence for it.
        XCTAssertNil(stitchSpeechSegments([], minimumSamples: minimum))
    }

    func testReturnsNilWhenEverySegmentIsEmpty() {
        XCTAssertNil(stitchSpeechSegments([[], []], minimumSamples: minimum))
    }

    func testReturnsNilWhenKeptSpeechIsTooShortToBeAWord() {
        let blip = [Float](repeating: 0.4, count: 1_000)
        XCTAssertNil(stitchSpeechSegments([blip], minimumSamples: minimum))
    }

    func testJoinsSegmentsInOrder() {
        let first = [Float](repeating: 0.1, count: 3_000)
        let second = [Float](repeating: 0.2, count: 3_000)
        let joined = stitchSpeechSegments([first, second], minimumSamples: minimum)

        XCTAssertEqual(joined?.count, 6_000)
        XCTAssertEqual(joined?.first, 0.1)
        XCTAssertEqual(joined?.last, 0.2)
    }

    func testDropsEmptySegmentsWithoutDiscardingTheRest() {
        let speech = [Float](repeating: 0.3, count: 5_000)
        XCTAssertEqual(stitchSpeechSegments([[], speech, []], minimumSamples: minimum)?.count, 5_000)
    }

    func testShortSegmentsCombineToClearTheMinimum() {
        // A pause mid-sentence splits one utterance into two segments; neither
        // half alone clears the floor, but the utterance does.
        let half = [Float](repeating: 0.3, count: 2_500)
        XCTAssertEqual(stitchSpeechSegments([half, half], minimumSamples: minimum)?.count, 5_000)
    }

    // MARK: - VAD tuning

    func testPaddingSatisfiesFluidAudiosSegmentationAssert() {
        // VadSegmentationConfig asserts speechPadding <= minSpeechDuration and
        // traps in debug builds otherwise, so this is a real tripwire, not a
        // restatement of the constants.
        XCTAssertLessThanOrEqual(
            DictationVadTuning.speechPadding,
            DictationVadTuning.minSpeechDuration
        )
        XCTAssertLessThanOrEqual(
            DictationVadTuning.minSilenceDuration,
            14.0  // VadSegmentationConfig's default maxSpeechDuration
        )
    }

    // MARK: - Engine

    func testOnlyAppleStreams() {
        XCTAssertFalse(DictationEngine.appleSpeech.isBatch)
        XCTAssertTrue(DictationEngine.whisper.isBatch)
        XCTAssertTrue(DictationEngine.parakeet.isBatch)
    }

    func testOnlyLocalEnginesNeedADownload() {
        XCTAssertFalse(DictationEngine.appleSpeech.needsModelDownload)
        XCTAssertTrue(DictationEngine.whisper.needsModelDownload)
        XCTAssertTrue(DictationEngine.parakeet.needsModelDownload)
    }

    func testRawValuesAreStableAcrossReleases() {
        // These are persisted in UserDefaults; renaming one silently resets
        // every existing user's dictation engine back to the default.
        XCTAssertEqual(DictationEngine.appleSpeech.rawValue, "appleSpeech")
        XCTAssertEqual(DictationEngine.whisper.rawValue, "whisper")
        XCTAssertEqual(DictationEngine.parakeet.rawValue, "parakeet")
    }

    @MainActor
    func testMigratesTheOldWhisperToggleForwards() {
        let defaults = UserDefaults.standard
        let previousEngine = defaults.object(forKey: "dictationEngine")
        let previousToggle = defaults.object(forKey: "useLocalWhisperDictation")
        defer {
            defaults.set(previousEngine, forKey: "dictationEngine")
            defaults.set(previousToggle, forKey: "useLocalWhisperDictation")
        }

        // Someone who had opted into local Whisper keeps local Whisper.
        defaults.removeObject(forKey: "dictationEngine")
        defaults.set(true, forKey: "useLocalWhisperDictation")
        XCTAssertEqual(SpeechService().engine, .whisper)

        // Everyone else stays on Apple's.
        defaults.removeObject(forKey: "dictationEngine")
        defaults.set(false, forKey: "useLocalWhisperDictation")
        XCTAssertEqual(SpeechService().engine, .appleSpeech)

        // An explicit choice wins over the legacy flag.
        defaults.set("parakeet", forKey: "dictationEngine")
        defaults.set(true, forKey: "useLocalWhisperDictation")
        XCTAssertEqual(SpeechService().engine, .parakeet)
    }

    // MARK: - Recorder

    func testStoppingAnUnstartedRecorderIsHarmless() {
        let recorder = DictationRecorder()
        XCTAssertTrue(recorder.stop().isEmpty)
        XCTAssertTrue(recorder.stop().isEmpty)
        XCTAssertEqual(recorder.audioLevel, 0)
    }
}
