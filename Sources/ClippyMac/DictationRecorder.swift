import AVFoundation

/// Captures a whole push-to-talk hold into a single 16 kHz mono buffer, rather
/// than feeding a recogniser while the user is still speaking.
///
/// This is the shape Handy (github.com/cjpais/Handy) uses, and it's why its
/// transcripts keep their last word. A streaming recogniser always trails the
/// microphone, so ending one mid-utterance truncates whatever it hadn't
/// committed yet — the old code papered over that with a 250 ms sleep after
/// `stopListening()` and still clipped under load. Recording to a buffer has no
/// such race: the tap stops, and the model then sees the complete utterance.
///
/// 16 kHz mono float is what Whisper and Parakeet both want, so the conversion
/// happens once here instead of separately inside each engine.
final class DictationRecorder {
    static let sampleRate: Double = 16_000

    /// Hard cap on a single hold, so a chord wedged down by a stuck key (or an
    /// app that swallows the release event) can't grow the buffer without
    /// bound. Ten minutes of 16 kHz mono float is ~38 MB.
    private static let maxSamples = Int(sampleRate) * 60 * 10

    /// Accumulates converted samples off the audio thread. The tap runs on a
    /// realtime thread that must not touch the main actor, so the buffer is
    /// its own lock-guarded box and the main actor reads it after `stop()`.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var level: Float = 0

        func append(_ new: [Float]) {
            lock.lock()
            defer { lock.unlock() }
            guard samples.count < DictationRecorder.maxSamples else { return }
            samples.append(contentsOf: new)
        }

        func setLevel(_ value: Float) {
            lock.lock()
            level = value
            lock.unlock()
        }

        var currentLevel: Float {
            lock.lock()
            defer { lock.unlock() }
            return level
        }

        func drain() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            let out = samples
            samples = []
            level = 0
            return out
        }
    }

    private let engine = AVAudioEngine()
    private let sink = Sink()
    private var isRunning = false

    /// Live microphone amplitude, 0...1, safe to read from any thread while
    /// recording. Drives the listening animation.
    var audioLevel: Float { sink.currentLevel }

    /// Opens the microphone and starts accumulating. Throws if the input
    /// format is unusable or the engine refuses to start; the caller is
    /// responsible for having already obtained microphone permission.
    func start() throws {
        stop()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // A zero sample rate means no usable input device — starting the
        // engine in that state throws an opaque CoreAudio error, so bail with
        // something a user can act on.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw DictationRecorderError.noInputDevice
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw DictationRecorderError.unsupportedInputFormat
        }

        let ratio = Self.sampleRate / inputFormat.sampleRate
        let sink = self.sink

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            sink.setLevel(Self.amplitude(of: buffer))

            // +1 frame of headroom: the resampler can emit one more frame than
            // the ratio suggests when the input length doesn't divide evenly,
            // and an undersized output buffer silently drops the remainder.
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard capacity > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
            else { return }

            // The converter pulls; hand it the tap buffer exactly once and
            // report end-of-stream after, or it will spin asking for more.
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, converted.frameLength > 0,
                  let channel = converted.floatChannelData
            else { return }

            sink.append(Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength))))
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    /// Closes the microphone and hands back everything recorded since `start()`.
    /// Safe to call when not recording; returns an empty buffer in that case.
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else {
            _ = sink.drain()
            return []
        }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        return sink.drain()
    }

    private static func amplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameCount { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(frameCount))
        // Typical speech RMS sits well under 1.0 — scale up so normal talking
        // volume visibly moves the listening animation.
        return min(1, rms * 12)
    }
}

enum DictationRecorderError: LocalizedError {
    case noInputDevice
    case unsupportedInputFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            "No microphone is available right now."
        case .unsupportedInputFormat:
            "This microphone's audio format isn't supported for dictation."
        }
    }
}
