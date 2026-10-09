import Foundation
import AVFoundation
import Speech

/// On-device dictation for Falar: `SFSpeechRecognizer` fed by `AVAudioEngine`, in the app's language (pt-BR or English).
/// `start()` asks for the microphone and speech permissions the first time; a refusal leaves `state == .denied` and the
/// sheet explains how to turn them on. `transcript` updates live while listening; `stop()` ends and returns the text.
///
/// DEBUG: `-talkTranscript "texto"` replaces the microphone with that text, typed word by word (the simulator cannot
/// dictate reliably), so the hold-to-talk path is testable.
@MainActor @Observable
final class Dictation {
    enum State: Equatable { case idle, starting, listening, denied, unavailable }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    /// 0…1, the microphone's loudness (drives the waveform).
    private(set) var level: Double = 0

    var isListening: Bool { state == .listening || state == .starting }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var generation = 0
    #if DEBUG
    @ObservationIgnored private var fake: String?
    #endif

    static var localeID: String { (Bundle.main.preferredLocalizations.first ?? "pt-BR").hasPrefix("en") ? "en-US" : "pt-BR" }

    /// Whether both permissions were already given (so a hold can record at once, without a system alert mid-gesture).
    static var isAuthorized: Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "talkTranscript") != nil { return true }
        #endif
        return SFSpeechRecognizer.authorizationStatus() == .authorized && AVAudioApplication.shared.recordPermission == .granted
    }

    func start() async {
        guard !isListening else { return }
        transcript = ""
        level = 0
        generation += 1
        let gen = generation
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "talkTranscript") {
            fake = text
            state = .listening
            var typed: [Substring] = []
            for w in text.split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(140))
                guard generation == gen, state == .listening else { return }
                typed.append(w)
                transcript = typed.joined(separator: " ")
                level = Double.random(in: 0.3...0.9)
            }
            return
        }
        #endif
        state = .starting
        guard await Self.requestPermissions() else { if generation == gen { state = .denied }; return }
        guard generation == gen, state == .starting else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.localeID)), recognizer.isAvailable else {
            state = .unavailable; return
        }
        do {
            #if !targetEnvironment(macCatalyst)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            request.addsPunctuation = true
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { state = .unavailable; return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request: request) { [weak self] lvl in
                Task { @MainActor in if self?.generation == gen { self?.level = lvl } }
            })
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.request = request
            // Called on the recognizer's queue: not main-actor isolated (see speechAuthorization).
            self.task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.generation == gen else { return }
                    if let text { self.transcript = text }
                    if final || failed { self.teardown() }
                }
            }
            state = .listening
        } catch {
            teardown()
            state = .unavailable
        }
    }

    /// Ends listening and returns what was heard (the last partial result; the final one rarely adds anything).
    @discardableResult
    func stop() -> String {
        #if DEBUG
        if let fake { self.fake = nil; generation += 1; transcript = fake; state = .idle; level = 0; return fake }
        #endif
        request?.endAudio()
        teardown()
        return transcript
    }

    /// Stops without keeping anything.
    func cancel() {
        generation += 1
        #if DEBUG
        fake = nil
        #endif
        task?.cancel()
        teardown()
        transcript = ""
    }

    private func teardown() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.finish()
        engine = nil; request = nil; task = nil
        level = 0
        if state != .denied && state != .unavailable { state = .idle }
        #if !targetEnvironment(macCatalyst)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// The audio tap runs on the audio thread: it only feeds the request and measures the loudness.
    private nonisolated static func tap(request: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in
            request.append(buffer)
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in stride(from: 0, to: n, by: 8) { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(max(1, n / 8)))
            level(min(1, Double(rms) * 12))
        }
    }

    private static func requestPermissions() async -> Bool {
        guard await speechAuthorization() == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// The system answers on a queue of its own: the callback must not be main-actor isolated (Swift 6 checks it at run
    /// time and stops the app — it did on the Mac, the first time the person allowed dictation).
    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status) }
        }
    }
}
