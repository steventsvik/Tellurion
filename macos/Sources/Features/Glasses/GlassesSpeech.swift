#if os(macOS)
import AVFoundation
import Speech

/// Turns one utterance of speech into text. Everything is called on the main thread.
protocol SpeechTranscriber: AnyObject {
    /// Starts an utterance. `update` gets the words so far, and once with `final` when
    /// that's all; `failed` gets a plain reason instead, once.
    func start(update: @escaping (_ text: String, _ final: Bool) -> Void, failed: @escaping (String) -> Void)
    /// More sound: 16 kHz, one channel, signed 16-bit little-endian.
    func append(_ pcm: Data)
    /// No more sound is coming; the final text follows.
    func finish()
    /// Drops the utterance; nothing more is reported.
    func cancel()
}

/// Which transcriber the glasses' voice uses.
enum GlassesSpeech {
    /// On this Mac only, with Apple's recognizer.
    ///
    /// A transcriber that sends the sound to a service would be chosen here, behind a
    /// setting of its own and the user's own key. There is none: nothing the glasses hear
    /// leaves this Mac.
    static func makeTranscriber() -> SpeechTranscriber {
        OnDeviceSpeechTranscriber()
    }
}

/// The glasses' sound as the recognizer takes it.
enum GlassesAudio {
    static let sampleRate: Double = 16_000
    static let bytesPerSecond = 32_000
    /// The longest one utterance may be.
    static let maxUtterance = 60 * bytesPerSecond

    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)

    /// A buffer of samples from signed 16-bit little-endian bytes. An odd last byte is left out.
    static func buffer(from pcm: Data) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0, let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        let bytes = [UInt8](pcm)
        for index in 0..<frames {
            let value = Int16(bitPattern: UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8)
            samples[index] = Float(value) / 32_768
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}

/// Apple's speech recognition, required to run on this Mac. It asks for Speech Recognition
/// the way dictation on a board does, and not for the microphone: the sound comes from the glasses.
final class OnDeviceSpeechTranscriber: SpeechTranscriber {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Sound that arrived before permission did, and an odd byte kept for the next piece.
    private var waiting = Data()
    private var odd = Data()
    private var finished = false
    private var ended = false
    private var last = ""
    private var update: (String, Bool) -> Void = { _, _ in }
    private var failed: (String) -> Void = { _ in }
    /// How long the last words may take after the sound ends.
    private static let patience: TimeInterval = 4

    func start(update: @escaping (String, Bool) -> Void, failed: @escaping (String) -> Void) {
        self.update = update
        self.failed = failed
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                guard status == .authorized else {
                    self.fail("Turn on Speech Recognition for Tellurion in System Settings → Privacy & Security.")
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            fail("Speech recognition isn't available right now.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            fail("This Mac can't recognize speech by itself in its language. Add the language under Keyboard → Dictation.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognizer = recognizer
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                if let result {
                    self.last = result.bestTranscription.formattedString
                    if result.isFinal { self.end() } else { self.update(self.last, false) }
                } else if error != nil {
                    self.end()
                }
            }
        }
        if !waiting.isEmpty, let buffer = GlassesAudio.buffer(from: waiting) { request.append(buffer) }
        waiting = Data()
        if finished { finish() }
    }

    func append(_ pcm: Data) {
        guard !ended, !finished else { return }
        var bytes = odd + pcm
        odd = bytes.count % 2 == 1 ? bytes.suffix(1) : Data()
        if !odd.isEmpty { bytes.removeLast() }
        guard let request else {
            if waiting.count + bytes.count <= GlassesAudio.maxUtterance { waiting.append(bytes) }
            return
        }
        if let buffer = GlassesAudio.buffer(from: bytes) { request.append(buffer) }
    }

    func finish() {
        finished = true
        guard let request, !ended else { return }
        request.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in self?.end() }
    }

    func cancel() {
        ended = true
        task?.cancel()
        task = nil
        request = nil
    }

    /// The utterance is over: what was heard, or that nothing was.
    private func end() {
        guard !ended else { return }
        let text = last.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { fail("Didn't catch that.") } else { cancel(); update(text, true) }
    }

    private func fail(_ message: String) {
        guard !ended else { return }
        cancel()
        failed(message)
    }
}
#endif
