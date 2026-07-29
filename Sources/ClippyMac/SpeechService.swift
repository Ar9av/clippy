import AVFoundation
import Speech
import WhisperKit

@MainActor
final class SpeechService: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var transcript = ""
    @Published var authorizationError: String?

    /// Live microphone amplitude while `isListening`, 0...1. Engine-agnostic
    /// (updated for both the Apple and Whisper paths below) so the listening
    /// animation reacts the same way regardless of which is active.
    @Published var audioLevel: Float = 0

    /// Whether dictation should route through the bundled local Whisper model
    /// (see `WhisperKit`) instead of Apple's on-device Speech framework.
    /// Offered as an optional choice in onboarding/Settings; persisted so it
    /// survives relaunches.
    @Published var useLocalWhisper: Bool {
        didSet {
            guard oldValue != useLocalWhisper else { return }
            UserDefaults.standard.set(useLocalWhisper, forKey: "useLocalWhisperDictation")
            if isListening { stopListening() }
        }
    }

    @Published private(set) var isPreparingWhisperModel = false
    @Published private(set) var whisperModelReady = false
    @Published private(set) var whisperModelDownloadProgress: Double = 0

    /// base.en balances accuracy against the size of the one-time download
    /// and load time on CPU/ANE; this is not user-configurable today.
    private static let whisperModelVariant = "base.en"

    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var whisperKit: WhisperKit?
    private var whisperStreamTranscriber: AudioStreamTranscriber?
    private var whisperStreamTask: Task<Void, Never>?

    override init() {
        useLocalWhisper = UserDefaults.standard.bool(forKey: "useLocalWhisperDictation")
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
            stopListening()
        } else {
            await startListening()
        }
    }

    /// Downloads and loads the local Whisper model ahead of time, so the
    /// first dictation attempt doesn't stall on a multi-second (or, on a
    /// slow connection, multi-minute) fetch. Safe to call repeatedly; a
    /// second call while one is already in flight, or after the model is
    /// already loaded, is a no-op.
    func prepareWhisperModel() async {
        guard !whisperModelReady, !isPreparingWhisperModel else { return }
        do {
            _ = try await ensureWhisperKitLoaded()
        } catch {
            authorizationError = "Couldn't download the local Whisper model: \(error.localizedDescription)"
        }
    }

    func startListening() async {
        if useLocalWhisper {
            await startWhisperListening()
        } else {
            await startAppleListening()
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

    /// End a hold-to-talk session and return what was heard. The microphone
    /// closes immediately — releasing the keys stops the recording — but the
    /// transcript is read a beat later: recognition callbacks hop to the main
    /// actor, so an update produced just before the stop can still be in
    /// flight, and reading synchronously clips the last word or two.
    @discardableResult
    func endPushToTalk() async -> String {
        pushToTalkGeneration &+= 1
        stopListening()
        try? await Task.sleep(for: .milliseconds(250))
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    private func startWhisperListening() async {
        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard micAllowed else {
            authorizationError = "Microphone permission is required for dictation."
            return
        }

        stopListening()
        transcript = ""
        authorizationError = nil

        let kit: WhisperKit
        do {
            kit = try await ensureWhisperKitLoaded()
        } catch {
            authorizationError = "Couldn't load the local Whisper model: \(error.localizedDescription)"
            return
        }
        guard let tokenizer = kit.tokenizer else {
            authorizationError = "The local Whisper model isn't ready yet."
            return
        }

        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: DecodingOptions(
                task: .transcribe,
                language: "en",
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                wordTimestamps: false
            )
        ) { [weak self] _, newState in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                let confirmed = newState.confirmedSegments.map(\.text).joined()
                let unconfirmed = newState.unconfirmedSegments.map(\.text).joined()
                let live = newState.currentText == "Waiting for speech..." ? "" : newState.currentText
                self.transcript = (confirmed + unconfirmed + live)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let level = newState.bufferEnergy.last {
                    self.audioLevel = min(1, max(0, level))
                }
            }
        }
        whisperStreamTranscriber = transcriber
        isListening = true

        whisperStreamTask = Task { [weak self] in
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                await MainActor.run {
                    self?.authorizationError = error.localizedDescription
                    self?.isListening = false
                }
            }
        }
    }

    private func ensureWhisperKitLoaded() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }

        isPreparingWhisperModel = true
        whisperModelDownloadProgress = 0
        defer { isPreparingWhisperModel = false }

        let modelFolder = try await WhisperKit.download(variant: Self.whisperModelVariant) { [weak self] progress in
            Task { @MainActor in self?.whisperModelDownloadProgress = progress.fractionCompleted }
        }
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: modelFolder.path, download: false))
        whisperKit = kit
        whisperModelReady = true
        return kit
    }

    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        if let whisperStreamTranscriber {
            Task { await whisperStreamTranscriber.stopStreamTranscription() }
        }
        whisperStreamTask?.cancel()
        whisperStreamTask = nil
        whisperStreamTranscriber = nil

        isListening = false
        audioLevel = 0
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
