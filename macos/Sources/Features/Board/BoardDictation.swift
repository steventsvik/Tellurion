#if os(macOS)
import AVFoundation
import Speech

/// Speech to text for the board's bar: hold Space (or click the microphone) and talk. Runs on
/// the Mac when it can, and asks for the microphone and speech recognition once.
final class BoardDictation: ObservableObject {
    @Published private(set) var listening = false

    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Let go before permission came back: don't start.
    private var wanted = false

    /// Starts listening; `update` gets the words so far, `failed` a reason it can't.
    func start(update: @escaping (String) -> Void, failed: @escaping (String) -> Void) {
        guard !listening else { return }
        wanted = true
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    failed("Turn on Speech Recognition for Tellurion in System Settings → Privacy & Security.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            failed("Turn on the Microphone for Tellurion in System Settings → Privacy & Security.")
                            return
                        }
                        guard self.wanted else { return }
                        self.begin(update: update, failed: failed)
                    }
                }
            }
        }
    }

    /// Stops listening; the last words still arrive.
    func stop() {
        wanted = false
        guard listening else { return }
        listening = false
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
    }

    private func begin(update: @escaping (String) -> Void, failed: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            failed("Speech recognition isn't available right now.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = audio.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            failed("The microphone didn't start.")
            return
        }
        self.request = request
        listening = true
        task?.cancel()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result { update(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true {
                    self?.task = nil
                    self?.stop()
                }
            }
        }
    }
}
#endif
