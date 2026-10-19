import Foundation
import AVFoundation
import Speech
import os
import SwiftUI
import PierSpeech

/// On-device dictation for Falar, Nova tarefa and a conversation's composer, with one of two engines (Ajustes ›
/// Ditado, `Engine`):
///
/// * **Parakeet** (the default): NVIDIA's Parakeet TDT on the Neural Engine (`PierSpeech`), Portuguese and English
///   told apart by the model. Only the microphone is asked for. The model is downloaded once, when the person accepts
///   the offer (`needsModel` → `downloadModel()`); after that a tap records at once while the model loads, the text is
///   written again about every second from all that was heard, and `finish()` writes it a last time.
/// * **System**: Apple's `SFSpeechRecognizer` in the app's language, which also needs speech recognition allowed and,
///   on the Mac, the system's Dictation turned on (`systemOff` says so).
///
/// `transcript` follows what is heard while listening; `finish()` ends and returns the final text, `cancel()` drops it.
///
/// DEBUG: `-talkTranscript "texto"` replaces the microphone with that text, typed word by word (the simulator cannot
/// dictate reliably), so the hold-to-talk path is testable. Parakeet's own check on recordings is PierSpeech's
/// `ParakeetEvalTests` (`PIER_SPEECH_EVAL=<folder>`).
@MainActor @Observable
final class Dictation {
    /// `systemOff`: the device's own Dictation (Siri and Dictation) is turned off, and the system serves no speech
    /// recognition to apps until it is on (macOS answers kLSRErrorDomain 201). `finishing`: the last words are being
    /// written (Parakeet). `needsModel`: Parakeet's model is not on this device yet, the offer to download it shows.
    /// `preparing`: the model is being downloaded (0…1) for a dictation that starts once it is ready. `modelFailed`:
    /// the download or loading failed.
    enum State: Equatable {
        case idle, starting, listening, finishing, denied, unavailable, systemOff
        case needsModel, preparing(Double), modelFailed
    }

    enum Engine: String, CaseIterable, Sendable {
        case parakeet, system
    }

    static let engineKey = "dictation.engine"

    /// The engine picked in Ajustes (Parakeet unless the person chose the system's).
    static var engine: Engine {
        get { UserDefaults.standard.string(forKey: engineKey).flatMap(Engine.init(rawValue:)) ?? .parakeet }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    /// 0…1, the microphone's loudness (drives the waveform).
    private(set) var level: Double = 0

    var isListening: Bool { state == .listening || state == .starting }
    /// Listening, writing the last words, or getting the model: a tap must not start another.
    var isBusy: Bool { isListening || state == .finishing || isPreparing }
    var isPreparing: Bool { if case .preparing = state { true } else { false } }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var collector: PCMCollector?
    @ObservationIgnored private var partials: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Bool, Never>?
    /// The engine of the dictation under way (the setting may change meanwhile).
    @ObservationIgnored private var running: Engine = .parakeet
    @ObservationIgnored private var generation = 0
    #if DEBUG
    @ObservationIgnored private var fake: String?
    #endif

    private static let log = Logger(subsystem: Shared.appBundleID, category: "dictation")

    /// What dictation finds without asking for anything or starting the microphone: permissions and the recognizers.
    static var status: String {
        let r = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        return "engine=\(engine.rawValue) parakeet=\(ParakeetEngine.isDownloaded ? "downloaded" : "absent") "
            + "speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic=\(AVAudioApplication.shared.recordPermission.rawValue) "
            + "locale=\(localeID) recognizer=\(r == nil ? "none" : "ok") available=\(r?.isAvailable ?? false) onDevice=\(r?.supportsOnDeviceRecognition ?? false)"
    }

    static var localeID: String { (Bundle.main.preferredLocalizations.first ?? "pt-BR").hasPrefix("en") ? "en-US" : "pt-BR" }

    /// Whether a hold can record at once, with no system alert or download offer in the middle of the gesture: the
    /// permissions given, and with Parakeet its model on the device.
    static var isAuthorized: Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "talkTranscript") != nil { return true }
        #endif
        let mic = AVAudioApplication.shared.recordPermission == .granted
        switch engine {
        case .parakeet: return mic && ParakeetEngine.isDownloaded
        case .system: return mic && SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    func start() async {
        guard !isBusy else { return }
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
        running = Self.engine
        switch running {
        case .parakeet: await startParakeet(gen)
        case .system: await startSystem(gen)
        }
    }

    /// The offer was accepted: the model is downloaded (and loaded), then dictation starts, as the tap asked
    /// (`listen`; Ajustes only downloads it).
    func downloadModel(listen: Bool = true) async {
        guard !isBusy else { return }
        generation += 1
        let gen = generation
        state = .preparing(0)
        do {
            try await ParakeetEngine.shared.prepare { [weak self] p in
                Task { @MainActor in
                    guard let self, self.generation == gen, self.isPreparing else { return }
                    self.state = .preparing(min(max(p, 0), 1))
                }
            }
        } catch {
            Self.log.error("the voice model did not download: \(String(describing: error), privacy: .public)")
            if generation == gen { state = .modelFailed }
            return
        }
        guard generation == gen, isPreparing else { return }
        state = .idle
        if listen { await start() }
    }

    /// Ends listening and returns the final text: with Parakeet, after one last pass over all that was heard.
    @discardableResult
    func finish() async -> String {
        #if DEBUG
        if let fake { self.fake = nil; generation += 1; transcript = fake; state = .idle; level = 0; return fake }
        #endif
        guard isListening else { return transcript }
        switch running {
        case .system:
            request?.endAudio()
            teardown()
            return transcript
        case .parakeet:
            let gen = generation
            stopRecording()
            partials?.cancel()
            state = .finishing
            let samples = collector?.samples ?? []
            if await loading?.value ?? ParakeetEngine.isDownloaded {
                do {
                    let text = try await ParakeetEngine.shared.transcribe(samples)
                    if generation == gen, !text.isEmpty || transcript.isEmpty { transcript = text }
                } catch {
                    Self.log.error("the last pass failed: \(String(describing: error), privacy: .public)")
                }
            }
            guard generation == gen else { return transcript }
            teardown()
            return transcript
        }
    }

    /// Stops without keeping anything (an offer or a failure is dismissed too).
    func cancel() {
        generation += 1
        #if DEBUG
        fake = nil
        #endif
        task?.cancel()
        partials?.cancel()
        teardown()
        transcript = ""
        if state == .needsModel || state == .modelFailed || isPreparing { state = .idle }
    }

    #if DEBUG
    /// `-dictationShow needsModel|preparing|finishing|failed`: that state on screen, for screenshots (nothing records).
    func debugShow(_ name: String) {
        switch name {
        case "needsModel": state = .needsModel
        case "preparing": state = .preparing(0.42)
        case "finishing": state = .finishing
        case "failed": state = .modelFailed
        default: break
        }
    }
    #endif

    // MARK: Parakeet

    private func startParakeet(_ gen: Int) async {
        guard await AVAudioApplication.requestRecordPermission() else { if generation == gen { state = .denied }; return }
        guard generation == gen, state == .starting else { return }
        guard ParakeetEngine.isDownloaded else { state = .needsModel; return }
        // On the device: it loads (a second or two, longer the first time) while the person already speaks.
        let load = Task<Bool, Never> {
            do { try await ParakeetEngine.shared.prepare(); return true } catch {
                Self.log.error("the voice model did not load: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        loading = load
        do {
            try openSession()
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard let collector = PCMCollector(input: format) else {
                Self.log.error("the microphone has no format (no input device, or no access): \(Self.status, privacy: .public)")
                state = .unavailable; return
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(collector: collector) { [weak self] lvl in
                Task { @MainActor in if self?.generation == gen { self?.level = lvl } }
            })
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.collector = collector
            state = .listening
            partials = Task { [weak self] in await self?.followPartials(gen, load: load) }
        } catch {
            Self.log.error("dictation did not start: \(String(describing: error), privacy: .public) \(Self.status, privacy: .public)")
            teardown()
            state = .unavailable
        }
    }

    /// While it listens, the text is written again from all that was heard: about every second, every few seconds
    /// once it runs past a minute (each pass takes longer), never two passes at once.
    private func followPartials(_ gen: Int, load: Task<Bool, Never>) async {
        guard await load.value else { return }
        var passed = 0
        while !Task.isCancelled, generation == gen, state == .listening, let collector {
            try? await Task.sleep(for: .milliseconds(collector.duration > 60 ? 2_500 : 900))
            guard !Task.isCancelled, generation == gen, state == .listening else { return }
            let samples = collector.samples
            // A quarter of a second more, at least: nothing new to say otherwise.
            guard samples.count - passed >= Int(PCMCollector.sampleRate / 4) else { continue }
            passed = samples.count
            guard let text = try? await ParakeetEngine.shared.transcribe(samples), !text.isEmpty else { continue }
            if generation == gen, state == .listening { transcript = text }
        }
    }

    /// The tap runs on the audio thread: it hands the audio to the collector and measures the loudness.
    private nonisolated static func tap(collector: PCMCollector, level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            collector.append(buffer)
            level(loudness(buffer))
        }
    }

    // MARK: the system's recognizer

    private func startSystem(_ gen: Int) async {
        guard await Self.requestPermissions() else { if generation == gen { state = .denied }; return }
        guard generation == gen, state == .starting else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.localeID)), recognizer.isAvailable else {
            Self.log.error("no recognizer available: \(Self.status, privacy: .public)")
            state = .unavailable; return
        }
        do {
            try openSession()
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

    /// The audio tap runs on the audio thread: it only feeds the request and measures the loudness.
    private nonisolated static func tap(request: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in
            request.append(buffer)
            level(loudness(buffer))
        }
    }

    // MARK: shared

    /// A recording session, on the Mac too: without one the engine opened only the output device, and the
    /// microphone's format came back empty ("O ditado não está disponível agora").
    private func openSession() throws {
        let session = AVAudioSession.sharedInstance()
        #if targetEnvironment(macCatalyst)
        try session.setCategory(.record, mode: .default)
        #else
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        #endif
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func stopRecording() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        level = 0
    }

    private func teardown() {
        stopRecording()
        task?.finish()
        request = nil; task = nil; collector = nil; partials = nil; loading = nil
        // What the person must act on stays on screen; anything else is over.
        let stays: [State] = [.denied, .unavailable, .systemOff, .needsModel, .modelFailed]
        if !stays.contains(state), !isPreparing { state = .idle }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 0…1 from a buffer's first channel (every eighth sample: enough for a waveform).
    private nonisolated static func loudness(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in stride(from: 0, to: n, by: 8) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(max(1, n / 8)))
        return min(1, Double(rms) * 12)
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

/// Under a field that takes dictation: the waveform while it listens, the last words being written, the offer to
/// download Parakeet's model and its progress, else why it can't (permissions, the device's Dictation off, nothing to
/// listen with). Nothing while idle.
struct DictationStatusLine: View {
    let dictation: Dictation
    /// The way out when dictation can't run ("Escreva o pedido.").
    var typeInstead: String

    var body: some View {
        Group {
            switch dictation.state {
            case .listening, .starting:
                HStack(spacing: 8) {
                    TalkWaveform(level: dictation.level, color: Theme.red).frame(width: 34, height: 18)
                    Text("Ouvindo… toque no microfone para parar").font(.caption).foregroundStyle(Theme.textDim)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            case .finishing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Transcrevendo…").font(.caption).foregroundStyle(Theme.textDim)
                    Spacer(minLength: 0)
                }
            case .needsModel:
                VStack(alignment: .leading, spacing: 6) {
                    Text("O ditado usa o Parakeet, um modelo de voz que roda neste aparelho: nada do que você diz sai dele. Ele precisa ser baixado uma vez (\(ByteCountFormatter.string(fromByteCount: ParakeetEngine.downloadBytes, countStyle: .file))).")
                        .font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button("Baixar e ditar") { Task { await dictation.downloadModel() } }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .accessibilityIdentifier("dictation-download")
                        Button("Usar o ditado do sistema") {
                            Dictation.engine = .system
                            dictation.cancel()
                            Task { await dictation.start() }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .preparing(let p):
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: p).tint(Theme.accent)
                    Text(p < 1 ? S("Baixando o modelo de voz… \(Int(p * 100))%") : S("Preparando o modelo de voz…"))
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("dictation-preparing")
            case .modelFailed:
                VStack(alignment: .leading, spacing: 6) {
                    Text("O modelo de voz não baixou. Confira a conexão e tente de novo. \(typeInstead)")
                        .font(.caption).foregroundStyle(Theme.orange)
                    Button("Tentar de novo") { Task { await dictation.downloadModel() } }.font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text(Dictation.engine == .parakeet
                         ? S("Para ditar, permita o microfone nos Ajustes. Você também pode escrever o pedido.")
                         : S("Para ditar, permita o microfone e o reconhecimento de fala nos Ajustes. Você também pode escrever o pedido."))
                        .font(.caption).foregroundStyle(Theme.orange)
                    Button("Abrir Ajustes") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .systemOff:
                DictationOffHint()
            case .unavailable:
                Text("O ditado não está disponível agora. \(typeInstead)").font(.caption).foregroundStyle(Theme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .idle:
                EmptyView()
            }
        }
    }
}
