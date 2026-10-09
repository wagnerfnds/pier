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
    @FocusState private var focused: Bool

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
                if !vm.attachments.isEmpty { attachmentStrip }
                HStack(alignment: .bottom, spacing: 8) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textDim).frame(width: 36, height: 36)
                            .background(Theme.card, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.stroke))
                    }
                    .buttonStyle(.plain)    // no bezel around the circle on the Mac
                    .accessibilityLabel("Anexar foto")
                    HStack(alignment: .bottom, spacing: 4) {
                        TextField(placeholder, text: $text, axis: .vertical)
                            .lineLimit(1...7)
                            .focused($focused)
                            .accessibilityIdentifier("composer-field")
                            .font(.body)
                            .padding(.leading, 14).padding(.vertical, 9)
                            .onSubmit { if canSend { Task { await send() } } }
                            // Esc right after sending takes the message back (the focused field gets the key first).
                            .onKeyPress(.escape) { PendingActions.shared.undoLatest() ? .handled : .ignored }
                        actionButton.padding(4)
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.4) : Theme.stroke))
                }
                if busy, hasText {
                    Text("Será enviada quando o agente terminar a vez atual.").font(.caption2).foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 48)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .background(Theme.bg)
        .animation(.snappy(duration: 0.2), value: showsStop)
        .animation(.snappy(duration: 0.2), value: hasText && busy)
        .onChange(of: vm.composerRestore, initial: true) { _, r in restore(r) }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await load(item) }
        }
    }

    private var placeholder: String { S("Mensagem para \(session.agentShortName)") }

    @ViewBuilder private var actionButton: some View {
        if showsStop {
            Button { Task { await vm.interrupt() } } label: {
                ZStack {
                    if vm.interrupting { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                }
                .frame(width: 30, height: 30)
                .background(Theme.red, in: Circle())
            }
            .disabled(vm.interrupting)
            .accessibilityLabel("Interromper o agente")
            .transition(.scale.combined(with: .opacity))
        } else {
            Button { Task { await send() } } label: {
                Image(systemName: busy && hasText ? "clock.arrow.circlepath" : "arrow.up")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(canSend ? Theme.accent : Theme.textFaint, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!canSend)
            // ⌘↩ sends from a hardware keyboard (Return alone writes a new line in the growing field).
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(busy ? "Enviar quando o agente terminar" : "Enviar")
            .accessibilityIdentifier("composer-send")
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// The message waits the undo window (`PendingActions`); undone or failed, its text comes back through `composerRestore`.
    private func send() async {
        let t = text
        if vm.scheduleSend(t) { text = "" }
    }

    /// Text given back by an undone or failed send: in front of whatever was typed since.
    private func restore(_ r: SessionViewModel.ComposerRestore?) {
        guard let r else { return }
        vm.composerRestore = nil
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = typed.isEmpty ? r.text : r.text + "\n" + text
        focused = true
    }

    private func load(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
        let maxSide: CGFloat = 2000
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        await vm.attach(data: jpeg, name: "foto-\(stamp).jpg", thumbnail: resized.preparingThumbnail(of: CGSize(width: 120, height: 120)))
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
