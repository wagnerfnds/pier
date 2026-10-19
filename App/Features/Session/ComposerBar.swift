import SwiftUI
import PhotosUI
import PierKit

/// The reply box: grows with the text, Send turns into Stop while the agent works and nothing is typed, prompts sent
/// mid-turn show up as a queue chip, photos attach from the + button.
struct ComposerBar: View {
    let vm: SessionViewModel
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var showQueue = false
    /// The text a failed send gave back last, while the field still holds just that.
    @State private var restored: String?
    @FocusState private var focused: Bool
    /// What was typed when dictation started: what is heard goes after it.
    @State private var dictationBase = ""
    /// Dictation was started from this composer (its status shows here, not under every conversation's).
    @State private var dictatingHere = false
    private var dictation: Dictation { TalkCenter.shared.dictation }

    private var session: Session { vm.session }
    private var busy: Bool { session.agentState == .running || session.agentState == .waiting }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var uploading: Bool { vm.attachments.contains { $0.path == nil && !$0.failed } }
    private var canSend: Bool { vm.canSend && (hasText || vm.attachments.contains { $0.path != nil }) && !uploading }
    private var showsStop: Bool { vm.isRunning && !hasText && vm.attachments.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if vm.isClosed { closedBanner } else {
                if !vm.held.isEmpty { queueChip }
                VStack(alignment: .leading, spacing: 0) {
                    if !vm.attachments.isEmpty { attachmentStrip.padding(.horizontal, 8).padding(.top, 6) }
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...10)
                        .focused($focused)
                        .accessibilityIdentifier("composer-field")
                        .font(.body)
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                        .onSubmit { if canSend { Task { await send() } } }
                        // Esc right after sending takes the message back (the focused field gets the key first).
                        .onKeyPress(.escape) { PendingActions.shared.undoLatest() ? .handled : .ignored }
                        // Return sends on the Mac and from an iPad's keyboard, as Messages does; Shift- or Option-
                        // Return writes a new line (and Return does on the on-screen keyboard).
                        .returnSends(text: $text) { if canSend { Task { await send() } } }
                    HStack(alignment: .center, spacing: 6) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textDim).frame(width: 30, height: 30)
                                .contentShape(Circle())
                        }
                        .buttonStyle(ComposerIconStyle())    // no bezel around it on the Mac
                        .accessibilityLabel("Anexar foto")
                        agentLine
                        Spacer(minLength: 6)
                        micButton
                        if Platform.isMac || HardwareKeyboard.shared.connected, focused, hasText, !busy {
                            Text("↩ envia · ⇧↩ nova linha").font(.caption2).foregroundStyle(Theme.textFaint).lineLimit(1)
                                .transition(.opacity)
                        }
                        actionButton
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.35) : Theme.stroke))
                .shadow(color: Theme.cardShadow, radius: 10, y: 3)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { focused = true }
                if dictatingHere, dictation.isListening || dictation.state != .idle {
                    DictationStatusLine(dictation: dictation, typeInstead: S("Escreva a mensagem."))
                        .padding(.horizontal, 14)
                }
                if busy, hasText {
                    Text("Será enviada quando o agente terminar a vez atual.").font(.caption2).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: readableColumn + 8)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .animation(.snappy(duration: 0.2), value: showsStop)
        .animation(.snappy(duration: 0.2), value: hasText && busy)
        .onChange(of: vm.composerRestore, initial: true) { _, r in restore(r) }
        .onChange(of: dictation.transcript) { _, t in
            guard dictatingHere, dictation.isListening, !t.isEmpty else { return }
            text = dictationBase.isEmpty ? t : dictationBase + " " + t
        }
        .onDisappear { if dictatingHere, dictation.isListening || dictation.isPreparing { dictation.cancel() }; dictatingHere = false }
        #if DEBUG
        .task {
            // `-composerTypeReturn <text>`: the words typed into the field's own text view, then the line break a text
            // view writes when it takes Return itself, as UIKit inserts typed text (the Mac's Return, checked without
            // keys).
            guard let typed = UserDefaults.standard.string(forKey: "composerTypeReturn") else { return }
            try? await Task.sleep(for: .seconds(3))
            focused = true
            try? await Task.sleep(for: .milliseconds(500))
            guard let input = FirstResponder.current as? UIKeyInput else { return }
            input.insertText(typed)
            try? await Task.sleep(for: .milliseconds(300))
            input.insertText("\n")
        }
        #endif
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await load(item) }
        }
    }

    private var placeholder: String { S("Mensagem para \(session.agentShortName)") }

    /// Say the message instead of typing it: the same on-device dictation as Nova tarefa and Falar, written into the
    /// field as it is heard; it is sent like a typed one.
    private var micButton: some View {
        Button(action: toggleDictation) {
            ZStack {
                if dictatingHere, dictation.state == .finishing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: dictation.isListening ? "stop.fill" : "mic")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(dictation.isListening ? .white : Theme.textDim)
                }
            }
            .frame(width: 30, height: 30)
            .background(dictation.isListening ? Theme.red : .clear, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(ComposerIconStyle())
        .disabled(dictation.state == .finishing || dictation.isPreparing)
        .accessibilityLabel(dictation.isListening ? "Parar de ditar" : "Ditar")
        .accessibilityIdentifier("composer-mic")
    }

    private func toggleDictation() {
        if dictation.isListening {
            Task { await finishDictation() }
            Haptic.impact(.light)
        } else {
            dictationBase = text.trimmingCharacters(in: .whitespacesAndNewlines)
            dictatingHere = true
            Haptic.impact(.medium)
            Task { await dictation.start() }
        }
    }

    /// Stops listening and keeps what was heard in the field (Parakeet writes it a last time first).
    private func finishDictation() async {
        guard dictatingHere, dictation.isListening else { return }
        let heard = await dictation.finish()
        if !heard.isEmpty { text = dictationBase.isEmpty ? heard : dictationBase + " " + heard }
    }

    /// Who answers, quietly, beside the attach button: the agent's model, mode and effort, and how full its context is.
    @ViewBuilder private var agentLine: some View {
        let sig = vm.store.signals
        let parts = [sig?.shortModel, sig?.mode, sig?.effort].compactMap { $0 }.filter { !$0.isEmpty }
        HStack(spacing: 8) {
            Text(parts.isEmpty ? session.agentLabel : parts.joined(separator: " · "))
                .font(.caption.weight(.medium)).foregroundStyle(Theme.textFaint).lineLimit(1)
            if let pct = sig?.contextPercent {
                HStack(spacing: 4) {
                    Gauge(value: Double(min(max(pct, 0), 100)), in: 0...100) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.32).frame(width: 14, height: 14)
                        .tint(pct >= 85 ? Theme.orange : Theme.textDim)
                    Text("\(pct)%").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textFaint)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(S("Contexto \(pct)% usado"))
            }
        }
        .accessibilityIdentifier("composer-agent-line")
    }

    @ViewBuilder private var actionButton: some View {
        if showsStop {
            Button { Task { await vm.interrupt() } } label: {
                ZStack {
                    if vm.interrupting { ProgressView().controlSize(.small).tint(Theme.onFill) }
                    else { Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onFill) }
                }
                .frame(width: 30, height: 30)
                .background(Theme.text, in: Circle())
            }
            .buttonStyle(.plain)    // the Mac's bezel would make the field taller than one line
            .disabled(vm.interrupting)
            .accessibilityLabel("Interromper o agente")
            .transition(.scale.combined(with: .opacity))
        } else {
            Button { Task { await send() } } label: {
                Image(systemName: busy && hasText ? "clock.arrow.circlepath" : "arrow.up")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(canSend ? Theme.onFill : Theme.textFaint)
                    .frame(width: 30, height: 30)
                    .background(canSend ? Theme.text : Theme.cardRaised, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            // ⌘↩ sends too, from any keyboard (Return alone does where a keyboard is at hand: `returnSends`).
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(busy ? "Enviar quando o agente terminar" : "Enviar")
            .accessibilityIdentifier("composer-send")
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// The message shows and goes out at once (`scheduleSend`); failed, its text comes back through `composerRestore`.
    private func send() async {
        await finishDictation()
        let t = text
        if vm.scheduleSend(t) { text = "" }
    }

    /// Text given back by a failed send: in front of whatever was typed since, after the text given back just before it
    /// (messages that failed one after the other come back in the order they were written).
    private func restore(_ r: SessionViewModel.ComposerRestore?) {
        guard let r else { return }
        vm.composerRestore = nil
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let restored, text == restored { text = text + "\n" + r.text }
        else { text = typed.isEmpty ? r.text : r.text + "\n" + text }
        restored = text
        focused = true
    }

    private func load(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        // Decoding, scaling and encoding a photo takes a good part of a second: not on the main thread, where the
        // composer would stop taking keys meanwhile.
        let prepared = await Task.detached(priority: .userInitiated) { () -> (jpeg: Data, thumbnail: UIImage?)? in
            guard let img = UIImage(data: data) else { return nil }
            let maxSide: CGFloat = 2000
            let scale = min(1, maxSide / max(img.size.width, img.size.height))
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let resized = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return nil }
            return (jpeg, resized.preparingThumbnail(of: CGSize(width: 120, height: 120)))
        }.value
        guard let prepared else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        await vm.attach(data: prepared.jpeg, name: "foto-\(stamp).jpg", thumbnail: prepared.thumbnail)
    }

    private var closedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: vm.gone ? "xmark.circle" : "poweroff").foregroundStyle(Theme.gray)
            Text(vm.gone ? "Esta sessão foi encerrada na box." : "O programa terminou. A sessão não aceita mais mensagens.")
                .font(.footnote).foregroundStyle(Theme.textDim)
            Spacer()
        }
        .padding(.horizontal, 4).padding(.vertical, 8)
    }

    private var queueChip: some View {
        VStack(spacing: 6) {
            Button { withAnimation(.snappy) { showQueue.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.caption)
                    Text(vm.held.count == 1 ? "1 mensagem na fila" : "\(vm.held.count) mensagens na fila").font(.caption.weight(.semibold))
                    Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(showQueue ? 180 : 0))
                }
                .foregroundStyle(Theme.orange)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.orange.opacity(0.14), in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(vm.held.count) mensagens na fila")
            .accessibilityHint("Mostra as mensagens que serão enviadas quando o agente terminar")
            if showQueue {
                VStack(spacing: 0) {
                    ForEach(vm.held) { h in
                        HStack(spacing: 8) {
                            Text(h.preview).font(.footnote).foregroundStyle(Theme.text).lineLimit(2)
                            Spacer(minLength: 4)
                            Button("Enviar agora") { Task { await vm.sendHeldNow(h) } }
                                .font(.caption.weight(.semibold)).buttonStyle(.bordered).controlSize(.mini)
                            Button { Task { await vm.cancelHeld(h) } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint) }
                                .accessibilityLabel("Cancelar mensagem da fila")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        if h.id != vm.held.last?.id { Divider().overlay(Theme.stroke) }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.attachments) { a in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let t = a.thumbnail { Image(uiImage: t).resizable().scaledToFill() } else { Theme.card }
                        }
                        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            if a.path == nil && !a.failed { ProgressView().tint(.white).background(.black.opacity(0.4)) }
                            if a.failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red) }
                        }
                        Button { vm.attachments.removeAll { $0.id == a.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remover foto")
                    }
                }
            }.padding(.top, 5).padding(.horizontal, 4)
        }
    }
}

/// The composer's small icon buttons: the system's pointer highlight, no bezel.
private struct ComposerIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .hoverEffect(.highlight)
    }
}
