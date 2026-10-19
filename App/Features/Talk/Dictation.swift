import Foundation
import AVFoundation
import Speech
import os
import SwiftUI

/// On-device dictation for Falar: `SFSpeechRecognizer` fed by `AVAudioEngine`, in the app's language (pt-BR or English).
/// `start()` asks for the microphone and speech permissions the first time; a refusal leaves `state == .denied` and the
/// sheet explains how to turn them on. `transcript` updates live while listening; `stop()` ends and returns the text.
///
/// DEBUG: `-talkTranscript "texto"` replaces the microphone with that text, typed word by word (the simulator cannot
/// dictate reliably), so the hold-to-talk path is testable.
@MainActor @Observable
final class Dictation {
    /// `systemOff`: the device's own Dictation (Siri and Dictation) is turned off, and the system serves no speech
    /// recognition to apps until it is on (macOS answers kLSRErrorDomain 201).
    enum State: Equatable { case idle, starting, listening, denied, unavailable, systemOff }

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

    private static let log = Logger(subsystem: Shared.appBundleID, category: "dictation")

    /// What dictation finds without asking for anything or starting the microphone: permissions and the recognizer.
    static var status: String {
        let r = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        return "speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic=\(AVAudioApplication.shared.recordPermission.rawValue) "
            + "locale=\(localeID) recognizer=\(r == nil ? "none" : "ok") available=\(r?.isAvailable ?? false) onDevice=\(r?.supportsOnDeviceRecognition ?? false)"
    }

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
            Self.log.error("no recognizer available: \(Self.status, privacy: .public)")
            state = .unavailable; return
        }
        do {
            // On the Mac too: without a recording session the engine opened only the output device, and the
            // microphone's format came back empty ("O ditado não está disponível agora").
            let session = AVAudioSession.sharedInstance()
            #if targetEnvironment(macCatalyst)
            try session.setCategory(.record, mode: .default)
            #else
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            #endif
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            request.addsPunctuation = true
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                Self.log.error("the microphone has no format (no input device, or no access): \(Self.status, privacy: .public)")
                state = .unavailable; return
            }
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
                let off = (error as NSError?).map(Self.isDictationOff) ?? false
                let reason = error.map { String(describing: $0) }
                Task { @MainActor in
                    guard let self, self.generation == gen else { return }
                    if let text { self.transcript = text }
                    if let reason, self.transcript.isEmpty { Self.log.error("recognition ended: \(reason, privacy: .public)") }
                    if off {
                        self.teardown()
                        self.state = .systemOff
                        return
                    }
                    if final || failed { self.teardown() }
                }
            }
            state = .listening
        } catch {
            Self.log.error("dictation did not start: \(String(describing: error), privacy: .public) \(Self.status, privacy: .public)")
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
        if state != .denied && state != .unavailable && state != .systemOff { state = .idle }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

    /// The system's "Siri and Dictation are disabled" (kLSRErrorDomain 201, also kAFAssistantErrorDomain 1700 on older
    /// systems): nothing the app can do but say where to turn Dictation on.
    private nonisolated static func isDictationOff(_ e: NSError) -> Bool {
        (e.domain == "kLSRErrorDomain" && e.code == 201) || (e.domain == "kAFAssistantErrorDomain" && e.code == 1700)
            || e.localizedDescription.localizedCaseInsensitiveContains("Dictation are disabled")
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

/// Dictation is off on the device: where to turn it on, and on the Mac a button straight to that pane.
struct DictationOffHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if targetEnvironment(macCatalyst)
            Text("O Ditado está desligado neste Mac. Ligue em Ajustes do Sistema › Teclado › Ditado e toque no microfone de novo.")
                .font(.caption).foregroundStyle(Theme.orange)
            Button("Abrir Teclado nos Ajustes do Sistema") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { UIApplication.shared.open(u) }
            }
            .font(.caption.weight(.semibold))
            #else
            Text("O Ditado está desligado. Ligue em Ajustes › Geral › Teclado › Ditado e toque no microfone de novo.")
                .font(.caption).foregroundStyle(Theme.orange)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("dictation-off")
    }
}

/// Under a field that takes dictation: the waveform while it listens, else why it can't (permissions, the device's
/// Dictation off, nothing to listen with). Nothing while idle.
struct DictationStatusLine: View {
    let dictation: Dictation
    /// The way out when dictation can't run ("Escreva o pedido.").
    var typeInstead: String

    var body: some View {
        if dictation.isListening {
            HStack(spacing: 8) {
                TalkWaveform(level: dictation.level, color: Theme.red).frame(width: 34, height: 18)
                Text("Ouvindo… toque no microfone para parar").font(.caption).foregroundStyle(Theme.textDim)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else if dictation.state == .denied {
            VStack(alignment: .leading, spacing: 6) {
                Text("Para ditar, permita o microfone e o reconhecimento de fala nos Ajustes. Você também pode escrever o pedido.")
                    .font(.caption).foregroundStyle(Theme.orange)
                Button("Abrir Ajustes") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
                .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if dictation.state == .systemOff {
            DictationOffHint()
        } else if dictation.state == .unavailable {
            Text("O ditado não está disponível agora. \(typeInstead)").font(.caption).foregroundStyle(Theme.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
