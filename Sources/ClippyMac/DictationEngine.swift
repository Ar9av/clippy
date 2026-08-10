import Foundation

/// Which recogniser dictation runs through.
///
/// Apple's is the default because it needs no download and streams partial
/// results as you speak. The two local engines trade that live feedback for
/// privacy and accuracy: they record the whole hold and transcribe once on
/// release (see `DictationRecorder`).
enum DictationEngine: String, CaseIterable, Identifiable {
    /// `SFSpeechRecognizer` — streaming, English-ish, no download, but the
    /// audio may leave the machine depending on the user's dictation settings.
    case appleSpeech
    /// WhisperKit `base.en` — on-device, English only.
    case whisper
    /// Parakeet v3 via FluidAudio — on-device, multilingual with automatic
    /// language detection, and markedly faster than Whisper on the Neural
    /// Engine. This is the engine Handy defaults to for the same reasons.
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: "Apple dictation"
        case .whisper: "Whisper (local, English)"
        case .parakeet: "Parakeet v3 (local, multilingual)"
        }
    }

    var detail: String {
        switch self {
        case .appleSpeech:
            "Built in, nothing to download, and text appears as you speak."
        case .whisper:
            "Runs on your Mac. One-time ~150 MB download. English only."
        case .parakeet:
            "Runs on your Mac, detects the language itself, and is the fastest of the three. One-time ~600 MB download."
        }
    }

    /// Whether this engine records the full hold and transcribes on release,
    /// rather than emitting partial results while recording.
    var isBatch: Bool { self != .appleSpeech }

    /// Whether this engine needs a model fetched before first use.
    var needsModelDownload: Bool { self != .appleSpeech }
}

/// Voice-activity gating parameters, ported from Handy's `SmoothedVad`
/// (`audio_toolkit/vad/smoothed.rs`, `VAD_*_FRAMES` in `vad/mod.rs`).
///
/// Handy counts 30 ms frames: 2 onset frames before speech is admitted, 15
/// frames of pre-roll so the attack of the first word isn't clipped, and 15
/// frames of hangover so a mid-sentence breath doesn't end the segment.
/// FluidAudio's `segmentSpeech` runs the same state machine, expressed as
/// durations, so this is the frame counts converted rather than a
/// reimplementation.
///
/// The pre-roll and hangover are deliberately not Handy's exact 450 ms:
/// FluidAudio asserts `speechPadding <= minSpeechDuration`, and 200 ms of
/// padding is enough to keep word onsets while still dropping lip smacks and
/// key clicks — which is the whole point of gating.
enum DictationVadTuning {
    /// Handy's onset, rounded up to what FluidAudio's padding assert allows.
    static let minSpeechDuration: TimeInterval = 0.2
    /// Handy's 15-frame hangover: 15 × 30 ms.
    static let minSilenceDuration: TimeInterval = 0.45
    /// Handy's pre-roll, capped by `minSpeechDuration`.
    static let speechPadding: TimeInterval = 0.2
}

/// Joins the speech regions the VAD kept into one buffer for the transcriber.
///
/// Split out as a free function purely so the stitching is testable without a
/// microphone or a CoreML model. Returns nil when the VAD found no speech at
/// all — the caller should skip transcription entirely rather than hand an
/// empty (or silent) buffer to Whisper, which is exactly the input that makes
/// it hallucinate "Thank you." / "you" into an otherwise empty transcript.
func stitchSpeechSegments(_ segments: [[Float]], minimumSamples: Int) -> [Float]? {
    let speech = segments.filter { !$0.isEmpty }
    guard !speech.isEmpty else { return nil }
    let joined = speech.flatMap { $0 }
    guard joined.count >= minimumSamples else { return nil }
    return joined
}
