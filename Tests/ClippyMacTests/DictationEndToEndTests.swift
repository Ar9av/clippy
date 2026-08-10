import AVFoundation
import FluidAudio
import XCTest
@testable import ClippyMac

/// Exercises the real local dictation path — download the models, gate on the
/// VAD, transcribe — against audio synthesised by `say`, so it needs no
/// microphone and has a known-correct answer.
///
/// Skipped unless `CLIPPY_STT_E2E=1`, because it pulls ~600 MB the first time
/// and takes minutes on a cold cache. Run it after touching `SpeechService`,
/// `DictationRecorder`, or the FluidAudio dependency:
///
///     CLIPPY_STT_E2E=1 swift test --filter DictationEndToEndTests
final class DictationEndToEndTests: XCTestCase {
    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLIPPY_STT_E2E"] == "1",
            "Set CLIPPY_STT_E2E=1 to run the local dictation integration tests."
        )
    }

    /// 16 kHz mono float samples of `text`, spoken by the system voice —
    /// the same format `DictationRecorder` hands to the engines.
    private func spokenSamples(_ text: String) throws -> [Float] {
        let aiff = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-stt-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, text]
        try say.run()
        say.waitUntilExit()
        try XCTSkipUnless(say.terminationStatus == 0, "`say` is unavailable on this machine.")

        return try AudioConverter().resampleAudioFile(aiff)
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(DictationRecorder.sampleRate * seconds))
    }

    func testVadKeepsSpeechAndDropsSilence() async throws {
        try skipUnlessEnabled()

        let speech = try spokenSamples("The quick brown fox jumps over the lazy dog.")
        let padded = silence(seconds: 1.5) + speech + silence(seconds: 1.5)

        let vad = try await VadManager(config: VadConfig())
        let config = VadSegmentationConfig(
            minSpeechDuration: DictationVadTuning.minSpeechDuration,
            minSilenceDuration: DictationVadTuning.minSilenceDuration,
            speechPadding: DictationVadTuning.speechPadding
        )

        let kept = try await vad.segmentSpeechAudio(padded, config: config)
        let stitched = try XCTUnwrap(
            stitchSpeechSegments(kept, minimumSamples: Int(DictationRecorder.sampleRate * 0.25)),
            "The VAD found no speech in a recording that is mostly speech."
        )

        // Three seconds of padding should be gone, and the speech should not.
        XCTAssertLessThan(stitched.count, padded.count)
        XCTAssertGreaterThan(Double(stitched.count) / Double(speech.count), 0.7)
    }

    func testAHoldWithNoSpeechInItProducesNothing() async throws {
        try skipUnlessEnabled()

        // The case that makes Whisper invent text. Gating must stop here.
        let vad = try await VadManager(config: VadConfig())
        let config = VadSegmentationConfig(
            minSpeechDuration: DictationVadTuning.minSpeechDuration,
            minSilenceDuration: DictationVadTuning.minSilenceDuration,
            speechPadding: DictationVadTuning.speechPadding
        )

        let kept = try await vad.segmentSpeechAudio(silence(seconds: 4), config: config)
        XCTAssertNil(stitchSpeechSegments(kept, minimumSamples: Int(DictationRecorder.sampleRate * 0.25)))
    }

    func testParakeetTranscribesSynthesisedSpeech() async throws {
        try skipUnlessEnabled()

        let samples = try spokenSamples("The quick brown fox jumps over the lazy dog.")

        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        let text = result.text.lowercased()

        XCTAssertTrue(text.contains("quick brown fox"), "Got: \(result.text)")
        XCTAssertTrue(text.contains("lazy dog"), "Got: \(result.text)")
    }
}
