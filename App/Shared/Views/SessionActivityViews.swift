import SwiftUI
import AppIntents

// Live Activity content (lock screen banner and Dynamic Island parts). Shared with the in-app debug gallery.

typealias ActivityContentState = SessionActivityAttributes.ContentState

extension ActivityPhase {
    var color: Color {
        switch self {
        case .starting, .running: BTheme.accent
        case .waiting: BTheme.orange
        case .finished: BTheme.green
        case .ended: BTheme.gray
        }
    }
    var symbol: String {
        switch self {
        case .starting: "hourglass"
        case .running: "circle.dotted"
        case .waiting: "exclamationmark.bubble.fill"
        case .finished: "checkmark.circle.fill"
        case .ended: "stop.circle.fill"
        }
    }
}

/// A timer counting up from `since`, or nothing for final phases.
struct PhaseTimer: View {
    let state: ActivityContentState
    var size: CGFloat = 13

    var body: some View {
        if state.phase.isFinal {
            Image(systemName: state.phase.symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(state.phase.color)
        } else {
            Text(state.since, style: .timer)
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(state.phase.color)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct DiffCounts: View {
    let added: Int
    let removed: Int
    var body: some View {
        HStack(spacing: 6) {
            Text("+\(added)").foregroundStyle(BTheme.green)
            Text("−\(removed)").foregroundStyle(BTheme.red)
        }
        .font(.system(size: 14, weight: .semibold, design: .monospaced))
    }
}

struct ActivityPermissionButtons: View {
    let attrs: SessionActivityAttributes
    var body: some View {
        HStack(spacing: 8) {
            Button(intent: DenyPermissionIntent(box: attrs.box, session: attrs.session)) {
                Label("Negar", systemImage: "xmark").labelStyle(.titleAndIcon)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(BTheme.red)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(BTheme.red.opacity(0.16), in: Capsule())
            }
            Button(intent: AllowPermissionIntent(box: attrs.box, session: attrs.session)) {
                Label("Permitir", systemImage: "checkmark").labelStyle(.titleAndIcon)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(BTheme.onFill)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(BTheme.orange, in: Capsule())
            }
        }
        .buttonStyle(.plain)
    }
}

/// "Revisar": the Review screen of the session's worktree (`pier://review`), not the chat.
struct ReviewLink: View {
    let attrs: SessionActivityAttributes
    var body: some View {
        Link(destination: Shared.reviewURL(box: attrs.box, name: attrs.session)) {
            Label("Revisar", systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(BTheme.onFill)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(BTheme.green, in: Capsule())
        }
    }
}

/// The line under the title: what the agent asks, does, or did.
struct DetailLine: View {
    let state: ActivityContentState
    var body: some View {
        switch state.phase {
        case .waiting:
            Text(state.ask ?? "Aguardando sua resposta")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(BTheme.orange).lineLimit(3)
        case .running, .starting:
            Text(state.step ?? (state.phase == .starting ? "Iniciando…" : "Trabalhando…"))
                .font(.system(size: 12)).foregroundStyle(BTheme.textDim).lineLimit(1)
        case .finished:
            if let reply = state.reply, !reply.isEmpty {
                Text(reply).font(.system(size: 13)).foregroundStyle(BTheme.text).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Terminou").font(.system(size: 12)).foregroundStyle(BTheme.textDim)
            }
        case .ended:
            Text("Sessão encerrada").font(.system(size: 12)).foregroundStyle(BTheme.textDim)
        }
    }
}

// MARK: lock screen

struct SessionLockScreenView: View {
    let attrs: SessionActivityAttributes
    let state: ActivityContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SharedAgentGlyph(agent: attrs.agent, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attrs.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(BTheme.text).lineLimit(1)
                    Text(attrs.project).font(.system(size: 12)).foregroundStyle(BTheme.textDim).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: state.phase.symbol).font(.system(size: 11, weight: .semibold))
                        Text(state.phase.title).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(state.phase.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(state.phase.color.opacity(0.16), in: Capsule())
                    if !state.phase.isFinal { PhaseTimer(state: state, size: 13) }
                }
            }
            DetailLine(state: state)
            if state.phase == .waiting && state.hasMenu {
                ActivityPermissionButtons(attrs: attrs)
            } else if state.phase == .finished {
                HStack {
                    if let a = state.added, let r = state.removed, a + r > 0 { DiffCounts(added: a, removed: r) }
                    Spacer()
                    ReviewLink(attrs: attrs)
                }
            }
        }
        .padding(16)
    }
}

// MARK: Dynamic Island

struct IslandCompactLeading: View {
    let attrs: SessionActivityAttributes
    let state: ActivityContentState
    var body: some View { SharedAgentGlyph(agent: attrs.agent, size: 22) }
}

struct IslandCompactTrailing: View {
    let state: ActivityContentState
    var body: some View {
        if state.phase == .waiting, let n = state.choices, n > 1 {
            // A question with its choices: the count next to the symbol, so the compact island says what it needs.
            HStack(spacing: 2) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 13, weight: .semibold))
                Text("\(n)").font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(state.phase.color)
        } else if state.phase.isFinal || state.phase == .waiting {
            Image(systemName: state.phase.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(state.phase.color)
        } else {
            Text(state.since, style: .timer)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(state.phase.color)
                .frame(width: 46).multilineTextAlignment(.trailing)
        }
    }
}

struct IslandMinimal: View {
    let state: ActivityContentState
    var body: some View {
        Image(systemName: state.phase.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(state.phase.color)
    }
}

struct IslandExpandedLeading: View {
    let attrs: SessionActivityAttributes
    var body: some View { SharedAgentGlyph(agent: attrs.agent, size: 34) }
}

struct IslandExpandedTrailing: View {
    let state: ActivityContentState
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(state.phase.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(state.phase.color)
            if !state.phase.isFinal { PhaseTimer(state: state, size: 15) }
            else if let a = state.added, let r = state.removed, a + r > 0 { DiffCounts(added: a, removed: r) }
        }
    }
}

struct IslandExpandedCenter: View {
    let attrs: SessionActivityAttributes
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(attrs.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(attrs.project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IslandExpandedBottom: View {
    let attrs: SessionActivityAttributes
    let state: ActivityContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailLine(state: state).frame(maxWidth: .infinity, alignment: .leading)
            if state.phase == .waiting && state.hasMenu {
                ActivityPermissionButtons(attrs: attrs)
            } else if state.phase == .waiting, let n = state.choices, n > 1 {
                // The choices are a tap away (the notification's buttons, the Inbox): say how many.
                HStack(spacing: 5) {
                    Image(systemName: "list.number").font(.system(size: 11, weight: .semibold))
                    Text("\(n) opções · toque para responder").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(BTheme.orange)
            } else if state.phase == .finished {
                HStack { Spacer(); ReviewLink(attrs: attrs) }
            }
        }
    }
}

// MARK: samples

extension SessionActivityAttributes {
    static var sample: SessionActivityAttributes {
        .init(box: "demo", session: "shop-checkout-claude-1x2y", title: "Corrigir retries do webhook", project: "shop · checkout-fix", agent: "claude")
    }
}

extension ActivityContentState {
    static var sampleRunning: Self { .init(phase: .running, since: Date().addingTimeInterval(-754), step: "Rodando pnpm test…", ask: nil, hasMenu: false) }
    static var sampleWaiting: Self { .init(phase: .waiting, since: Date().addingTimeInterval(-42), step: nil, ask: "Bash  rm -rf node_modules && pnpm install", hasMenu: true) }
    static var sampleQuestion: Self { .init(phase: .waiting, since: Date().addingTimeInterval(-20), step: nil, ask: "Which layout for the pricing page?", hasMenu: false, choices: 3) }
    static var sampleFinished: Self { .init(phase: .finished, since: Date().addingTimeInterval(-60), step: nil, ask: nil, hasMenu: false, added: 128, removed: 34,
                                            reply: "Corrigi os retries do webhook: agora o backoff é exponencial e os testes de integração passam. Também removi o timeout fixo de 30 s.") }
}
