import SwiftUI
import PierKit

/// The Home's hold-to-talk mic (iPhone): hold and speak, release to send what was heard to the router; a short tap opens
/// Falar already listening (tap again there to stop).
struct TalkHoldButton: View {
    @State private var pressedAt: Date?
    private var center: TalkCenter { .shared }

    var body: some View {
        let holding = center.holding
        Image(systemName: holding ? "waveform" : "mic.fill")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(holding ? .white : Theme.accent)
            .symbolEffect(.variableColor.iterative, isActive: holding)
            .frame(width: 54, height: 54)
            .background(holding ? Theme.accent : Theme.cardRaised, in: Circle())
            .overlay(Circle().strokeBorder(holding ? .clear : Theme.accent.opacity(0.35), lineWidth: 1))
            .overlay {
                if holding {
                    Circle().stroke(Theme.accent.opacity(0.35), lineWidth: 6)
                        .scaleEffect(1 + center.dictation.level * 0.35)
                        .animation(.easeOut(duration: 0.12), value: center.dictation.level)
                }
            }
            .scaleEffect(holding ? 1.1 : 1)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .animation(.snappy(duration: 0.2), value: holding)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressedAt == nil else { return }
                        pressedAt = .now
                        center.beginHold()
                    }
                    .onEnded { _ in
                        let held = Date().timeIntervalSince(pressedAt ?? .now)
                        pressedAt = nil
                        center.endHold(tap: held < 0.35)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Falar")
            .accessibilityHint("Segure para falar e solte para enviar; toque para abrir")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { center.open(listen: true) }
            .accessibilityIdentifier("talk-mic-hold")
            #if DEBUG
            // Screenshot hook: `-talkHoldDemo 1` (with `-talkTranscript`) holds the mic by itself for a few seconds.
            .task {
                guard UserDefaults.standard.bool(forKey: "talkHoldDemo") else { return }
                try? await Task.sleep(for: .seconds(3))
                center.beginHold()
                try? await Task.sleep(for: .seconds(6))
                center.endHold(tap: false)
            }
            #endif
    }
}

/// Over the Home's hold mic while it is held: the live transcript.
struct TalkHoldOverlay: View {
    private var center: TalkCenter { .shared }

    var body: some View {
        let d = center.dictation
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TalkWaveform(level: d.level, color: Theme.accent).frame(width: 34, height: 16)
                Text("Ouvindo… solte para enviar").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
            }
            Text(d.transcript.isEmpty ? S("Diga o que você precisa") : d.transcript)
                .font(.body).foregroundStyle(d.transcript.isEmpty ? Theme.textFaint : Theme.text)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("talk-hold-transcript")
        }
        .padding(14)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.4)))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk-hold-overlay")
    }
}

/// Five bars that follow the microphone's level.
struct TalkWaveform: View {
    let level: Double
    var color: Color = Theme.accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let wave = (sin(t * 7 + Double(i) * 1.3) + 1) / 2
                    let amp = max(0.18, min(1, level)) * (0.45 + 0.55 * wave)
                    Capsule().fill(color).frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(x: 1, y: max(0.2, amp), anchor: .center)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// "Enviado para Corrigir login · Abrir": what Falar did, at the top of the app for a few seconds.
struct TalkReceiptHost: View {
    @Environment(AppModel.self) private var model
    private var center: TalkCenter { .shared }

    var body: some View {
        ZStack {
            if let r = center.receipt {
                HStack(spacing: 12) {
                    Image(systemName: r.symbol)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.green)
                        .frame(width: 34, height: 34)
                        .background(Theme.green.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                            .accessibilityIdentifier("talk-receipt-title")
                        Text(r.detail).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button {
                        center.dismissReceipt()
                        model.openSession(box: r.box, name: r.session)
                    } label: {
                        Text("Abrir").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.accent.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("talk-receipt-open")
                }
                .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10)
                .frame(maxWidth: 520)
                .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
                .padding(.horizontal, 12).padding(.top, 4)
                .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < -10 { center.dismissReceipt() } })
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("talk-receipt")
            }
        }
        .animation(.snappy, value: center.receipt)
    }
}
