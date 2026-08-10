import AVFoundation
import FluidAudio
import Speech
import WhisperKit

@MainActor
final class SpeechService: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var transcript = ""
    @Published var authorizationError: String?

    /// True between the microphone closing and the transcript arriving. Only
    /// the batch engines can be in this state; Apple's streams as it goes.
    @Published private(set) var isTranscribing = false

    /// Live microphone amplitude while `isListening`, 0...1. Engine-agnostic,
    /// so the listening animation reacts the same way regardless of which
    /// engine is active.
    @Published var audioLevel: Float = 0

    /// Which recogniser dictation runs through. Persisted so it survives
    /// relaunches.
    @Published var engine: DictationEngine {
        didSet {
            guard oldValue != engine else { return }
            UserDefaults.standard.set(engine.rawValue, forKey: Self.engineDefaultsKey)
            if isListening { stopListening() }
        }
    }

    @Published private(set) var isPreparingModel = false
    @Published private(set) var modelDownloadProgress: Double = 0
    /// Engines whose models are loaded and ready to transcribe.
    @Published private(set) var readyEngines: Set<DictationEngine> = []

    private static let engineDefaultsKey = "dictationEngine"
    /// The pre-Parakeet setting: a plain "use Whisper instead of Apple" flag.
    /// Read once to migrate existing installs onto `engine`.
    private static let legacyWhisperDefaultsKey = "useLocalWhisperDictation"

    /// base.en balances accuracy against the size of the one-time download and
    /// load time on CPU/ANE; this is not user-configurable today.
    private static let whisperModelVariant = "base.en"

    /// Below this, whatever the VAD kept is a click or a breath rather than a
    /// word, and transcribing it only invites a hallucinated token.
    private static let minimumSpeechSamples = Int(DictationRecorder.sampleRate * 0.25)

    private let synthesizer = AVSpeechSynthesizer()

    // Apple streaming path.
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Batch path, shared by both local engines.
    private let recorder = DictationRecorder()
    private var levelPollTask: Task<Void, Never>?

    private var whisperKit: WhisperKit?
    private var parakeet: AsrManager?
    private var vad: VadManager?

    override init() {
        let stored = UserDefaults.standard.string(forKey: Self.engineDefaultsKey)
        if let stored, let known = DictationEngine(rawValue: stored) {
            engine = known
        } else if UserDefaults.standard.bool(forKey: Self.legacyWhisperDefaultsKey) {
            engine = .whisper
        } else {
            engine = .appleSpeech
        }
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.49
        utterance.pitchMultiplier = 1.04
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
    }

    func toggleListening() async {
        if isListening {
            await finishListening()
        } else {
            await startListening()
        }
    }

    /// Downloads and loads whatever the selected engine needs ahead of time, so
    /// the first dictation attempt doesn't stall on a multi-second (or, on a
    /// slow connection, multi-minute) fetch. Safe to call repeatedly; a second
    /// call while one is in flight, or after the model is loaded, is a no-op.
    func prepareModel() async {
        guard engine.needsModelDownload,
              !readyEngines.contains(engine),
              !isPreparingModel
        else { return }
        do {
            switch engine {
            case .whisper: _ = try await ensureWhisperLoaded()
            case .parakeet: _ = try await ensureParakeetLoaded()
            case .appleSpeech: break
            }
        } catch {
            authorizationError = "Couldn't download the \(engine.displayName) model: \(error.localizedDescription)"
        }
    }

    func startListening() async {
        switch engine {
        case .appleSpeech: await startAppleListening()
        case .whisper, .parakeet: await startBatchListening()
        }
    }

    /// Bumped by every push-to-talk edge. `startListening()` suspends on the
    /// permission prompt and (first time) the model load, so a key release can
    /// easily land before `isListening` has even become true — a plain
    /// `stopListening()` at that moment is a no-op and the microphone is then
    /// opened *after* the user let go. Comparing generations lets the start
    /// path notice it was superseded and shut itself down.
    private var pushToTalkGeneration = 0

    /// Begin a hold-to-talk session. Does nothing if dictation is already
    /// running, so holding the chord mid-session can't restart it and discard
    /// the transcript so far.
    func beginPushToTalk() async {
        guard !isListening else { return }
        pushToTalkGeneration &+= 1
        let generation = pushToTalkGeneration
        await startListening()
        if generation != pushToTalkGeneration {
            stopListening()
        }
    }

    /// End a hold-to-talk session and return what was heard.
    @discardableResult
    func endPushToTalk() async -> String {
        pushToTalkGeneration &+= 1
        await finishListening()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abandon a hold-to-talk session without transcribing it. Used when the
    /// chord turned out to be an ordinary typing modifier: the audio is
    /// thrown away, so there's no point spending a model pass on it — and on
    /// a batch engine, transcribing a cancelled hold would land the text in
    /// the composer a second or two after the user had moved on.
    func cancelPushToTalk() {
        pushToTalkGeneration &+= 1
        stopListening()
        transcript = ""
    }

    /// Close the microphone and settle on a final transcript.
    ///
    /// For the batch engines this is where the actual recognition happens, so
    /// the transcript is complete the moment this returns. Apple's path has no
    /// such join: its callbacks hop to the main actor, so an update produced
    /// just before the stop can still be in flight, and reading synchronously
    /// clips the last word or two — hence the short wait, which applies only
    /// there.
    private func finishListening() async {
        switch engine {
        case .appleSpeech:
            stopListening()
            try? await Task.sleep(for: .milliseconds(250))
        case .whisper, .parakeet:
            await finishBatchListening()
        }
    }

    // MARK: - Apple (streaming)

    private func startAppleListening() async {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            authorizationError = "Speech recognition permission is required for dictation."
            return
        }

        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard micAllowed else {
            authorizationError = "Microphone permission is required for dictation."
            return
        }

        stopListening()
        transcript = ""
        authorizationError = nil

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            authorizationError = "Speech recognition is unavailable right now."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.amplitude(of: buffer)
            Task { @MainActor in self?.audioLevel = level }
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self?.stopListening() }
                }
                if error != nil { self?.stopListening() }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
            authorizationError = error.localizedDescription
            stopListening()
        }
    }

    // MARK: - Local engines (record, then transcribe)

    private func startBatchListening() async {
        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard micAllowed else {
            authorizationError = "Microphone permission is required for dictation."
            return
        }

        stopListening()
        transcript = ""
        authorizationError = nil

        // Load the model *before* opening the microphone. The other order
        // records the first seconds of speech into a buffer nobody has a
        // transcriber for yet, and on a cold start that's the entire hold.
        do {
            switch engine {
            case .whisper: _ = try await ensureWhisperLoaded()
            case .parakeet: _ = try await ensureParakeetLoaded()
            case .appleSpeech: return
            }
        } catch {
            authorizationError = "Couldn't load the \(engine.displayName) model: \(error.localizedDescription)"
            return
        }

        do {
            try recorder.start()
        } catch {
            authorizationError = error.localizedDescription
            return
        }

        isListening = true
        // The tap can't touch the main actor, so the published level is
        // sampled rather than pushed. 20 Hz is well under the animation's
        // needs and costs nothing.
        levelPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await MainActor.run { self.audioLevel = self.recorder.audioLevel }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func finishBatchListening() async {
        guard isListening else { return }
        let engineForRun = engine
        let samples = stopRecording()
        isListening = false
        audioLevel = 0

        guard !samples.isEmpty else { return }

        isTranscribing = true
        defer { isTranscribing = false }

        // Gate on voice activity first. Silence is what makes Whisper invent
        // text, and it's also pure latency for Parakeet.
        let speech = await speechOnly(from: samples)
        guard let speech else { return }

        do {
            switch engineForRun {
            case .whisper:
                transcript = try await transcribeWithWhisper(speech)
            case .parakeet:
                transcript = try await transcribeWithParakeet(speech)
            case .appleSpeech:
                break
            }
        } catch {
            authorizationError = "Dictation failed: \(error.localizedDescription)"
        }
    }

    /// Runs the VAD and returns only the speech, or nil when there wasn't any.
    ///
    /// A VAD that fails to load or run is not fatal — falling back to the raw
    /// recording is strictly better than dropping what the user just said.
    private func speechOnly(from samples: [Float]) async -> [Float]? {
        guard let vad = await loadedVad() else {
            return samples.count >= Self.minimumSpeechSamples ? samples : nil
        }
        do {
            let config = VadSegmentationConfig(
                minSpeechDuration: DictationVadTuning.minSpeechDuration,
                minSilenceDuration: DictationVadTuning.minSilenceDuration,
                speechPadding: DictationVadTuning.speechPadding
            )
            let segments = try await vad.segmentSpeechAudio(samples, config: config)
            return stitchSpeechSegments(segments, minimumSamples: Self.minimumSpeechSamples)
        } catch {
            return samples.count >= Self.minimumSpeechSamples ? samples : nil
        }
    }

    private func transcribeWithWhisper(_ samples: [Float]) async throws -> String {
        guard let whisperKit else { return "" }
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                task: .transcribe,
                language: "en",
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                wordTimestamps: false
            )
        )
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeWithParakeet(_ samples: [Float]) async throws -> String {
        guard let parakeet else { return "" }
        // A fresh decoder state per utterance: holds are independent, and
        // carrying state across them lets one dictation bias the next.
        var decoderState = try TdtDecoderState()
        let result = try await parakeet.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Model loading

    private func ensureWhisperLoaded() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }

        isPreparingModel = true
        modelDownloadProgress = 0
        defer { isPreparingModel = false }

        let modelFolder = try await WhisperKit.download(variant: Self.whisperModelVariant) { [weak self] progress in
            Task { @MainActor in self?.modelDownloadProgress = progress.fractionCompleted }
        }
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: modelFolder.path, download: false))
        whisperKit = kit
        readyEngines.insert(.whisper)
        return kit
    }

    private func ensureParakeetLoaded() async throws -> AsrManager {
        if let parakeet { return parakeet }

        isPreparingModel = true
        modelDownloadProgress = 0
        defer { isPreparingModel = false }

        let models = try await AsrModels.downloadAndLoad(version: .v3) { [weak self] progress in
            Task { @MainActor in self?.modelDownloadProgress = progress.fractionCompleted }
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        parakeet = manager
        readyEngines.insert(.parakeet)
        return manager
    }

    /// The Silero VAD, loaded lazily and shared by both local engines. Returns
    /// nil rather than throwing: gating is an improvement, not a requirement,
    /// and a failed VAD download shouldn't take dictation down with it.
    private func loadedVad() async -> VadManager? {
        if let vad { return vad }
        do {
            let manager = try await VadManager(config: VadConfig())
            vad = manager
            return manager
        } catch {
            return nil
        }
    }

    // MARK: - Teardown

    /// Immediate stop that discards anything not yet transcribed. Used when a
    /// session is abandoned (chord cancelled, engine switched) rather than
    /// completed — the completing path is `finishListening()`.
    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        _ = stopRecording()

        isListening = false
        audioLevel = 0
    }

    @discardableResult
    private func stopRecording() -> [Float] {
        levelPollTask?.cancel()
        levelPollTask = nil
        return recorder.stop()
    }

    private nonisolated static func amplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameCount { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(frameCount))
        // Typical speech RMS sits well under 1.0 — scale up so normal
        // talking volume visibly moves the listening animation.
        return min(1, rms * 12)
    }
}
