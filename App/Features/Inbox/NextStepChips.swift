import SwiftUI
import PierKit

/// The suggested next steps of a finished turn (`NextStepsStore`): full-width rows, each a reply ready to send. A tap
/// sends it (through the caller, which wraps it in the undo window): the row turns green with a check while the window
/// runs and a receipt ("✓ Enviado para Claude") shows once it went out; "Desfazer" puts the row back.
struct NextStepChips: View {
    let key: NextSteps.Key
    let place: ExecPlace?
    let reply: String?
    let task: String?
    let client: (any PierBoxClient)?
    /// Show the 1 / 2 keycaps (the Inbox, where the keys pick them).
    var numbered = false
    var disabled = false
    /// A small heading over the chips (only while there is something to show).
    var heading: LocalizedStringKey? = nil
    /// Who gets the reply ("Claude"), for the receipt.
    var recipient: String = ""
    /// Sends the words; returns the undo window's token when one started (the row stays marked until it ends).
    let onPick: (String) -> PendingActions.Token?

    @State private var chosen: Int?
    @State private var token: PendingActions.Token?
    @State private var receipt = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var store: NextStepsStore { NextStepsStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.phase(key) {
            case .loading?:
                headingView
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardRaised).frame(height: 40)
                    }
                }
                .overlay(alignment: .leading) {
                    ShimmerText(text: S("Sugerindo próximos passos…"), font: .caption).padding(.leading, 12)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("next-steps-loading")
            case .ready(let replies)? where !replies.isEmpty:
                headingView
                VStack(spacing: 6) {
                    ForEach(Array(replies.enumerated()), id: \.offset) { i, r in row(i, r) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("next-steps")
                if receipt { receiptPill }
            default:
                EmptyView()
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: chosen)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: receipt)
        .task(id: "\(key.id)|\(reply?.count ?? 0)") {
            store.request(key, place: place, reply: reply, task: task, client: client)
        }
        .onChange(of: PendingActions.shared.last) { _, outcome in
            // The window this row started ended: the receipt, or the row back as it was.
            guard let token, token.matches(outcome) else { return }
            self.token = nil
            if outcome?.sent == true {
                receipt = true
                Task { try? await Task.sleep(for: .seconds(4)); receipt = false; chosen = nil }
            } else {
                chosen = nil
            }
        }
    }

    @ViewBuilder private var headingView: some View {
        if let heading {
            Text(heading).font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint).textCase(.uppercase).tracking(0.5)
        }
    }

    private func row(_ i: Int, _ text: String) -> some View {
        let on = chosen == i
        return Button {
            guard chosen == nil else { return }
            chosen = i
            token = onPick(text)
            if token == nil { chosen = nil }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onFill)
                            .frame(width: 20, height: 20)
                            .background(Theme.green, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else if numbered {
                        Text("\(i + 1)").font(.mono(11, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 20, height: 20)
                            .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: "arrow.turn.down.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 20, height: 20)
                    }
                }
                Text(text).font(.subheadline.weight(.medium)).foregroundStyle(on ? Theme.green : Theme.text)
                    .multilineTextAlignment(.leading).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Theme.green.opacity(0.14) : Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.green.opacity(0.45) : Theme.accent.opacity(0.3)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled || (chosen != nil && !on))
        .opacity(disabled || (chosen != nil && !on) ? 0.55 : 1)
        .accessibilityLabel(text)
        .accessibilityValue(on ? Text("Escolhido") : Text(""))
        .accessibilityHint("Envia esta resposta ao agente")
        .accessibilityIdentifier("next-step-\(i + 1)")
    }

    private var receiptPill: some View { NextStepReceipt(recipient: recipient) }
}

/// "✓ Enviado para Claude", a moment after the words went out.
struct NextStepReceipt: View {
    let recipient: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.green).accessibilityHidden(true)
            Text(recipient.isEmpty ? S("Enviado") : S("Enviado para \(recipient)")).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.cardRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("next-steps-receipt")
    }
}

/// The end of a finished turn in the session's chat: the suggested replies, right above the composer.
struct SessionNextSteps: View {
    let vm: SessionViewModel
    /// The undo window of the step just picked; the receipt shows once it went out (the rows are gone by then: the
    /// agent is working again), so it lives here, above the composer, not in the rows.
    @State private var token: PendingActions.Token?
    @State private var receipt = false

    /// The agent's last reply of this turn (nothing after the person's last prompt means no reply yet).
    static func lastReply(_ items: [TranscriptItem]) -> String? {
        for item in items.reversed() {
            if item.kind == "user" { return nil }
            if item.kind == "text", let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        }
        return nil
    }

    var body: some View {
        let s = vm.session
        VStack(alignment: .leading, spacing: 8) {
            if s.agentState == .finished, !vm.isRunning, !vm.isWaiting, !vm.isClosed, vm.store.pending.isEmpty,
               let since = s.stateSince, let reply = Self.lastReply(vm.store.displayItems) {
                NextStepChips(key: NextSteps.Key(box: vm.box, session: vm.name, since: since), place: s.execPlace, reply: reply,
                              task: s.title, client: vm.client, disabled: vm.sending, heading: "Próximos passos", recipient: s.agentShortName) { text in
                    // The undo window, like the Inbox's chips and the composer: "Desfazer" and nothing goes out.
                    let t = PendingActions.shared.schedule(label: text, perform: { _ = await vm.send(text, when: .idle) })
                    token = t
                    return t
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
            if receipt { NextStepReceipt(recipient: s.agentShortName) }
        }
        .animation(.snappy(duration: 0.25), value: receipt)
        .onChange(of: PendingActions.shared.last) { _, outcome in
            guard let token, token.matches(outcome) else { return }
            self.token = nil
            guard outcome?.sent == true else { return }
            receipt = true
            Task { try? await Task.sleep(for: .seconds(4)); receipt = false }
        }
    }
}
