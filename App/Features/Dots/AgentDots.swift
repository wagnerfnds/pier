import SwiftUI
import PierKit

/// One live agent session as a dot: amber needs you, blue working, green its turn ended ("Sua vez"), gray idle.
struct AgentDot: Identifiable, Hashable {
    let box: String
    let session: String
    let state: DashState
    let title: String
    let project: String
    var id: String { "\(box)/\(session)" }

    /// "Title · project" (and the box when there are several).
    var label: String { project.isEmpty ? title : "\(title) · \(project)" }
    /// VoiceOver: the state, then where ("Precisa de você, sandbox"). The project stays out of the label so a search by
    /// project name does not land on a dot.
    var accessibilityValue: String { project.isEmpty ? AgentDots.stateWord(state) : "\(AgentDots.stateWord(state)), \(project)" }
}

@MainActor enum AgentDots {
    /// Every live agent session across the boxes, needs-you first (waiting longest first), then working, your turn and idle
    /// (oldest first, so a dot keeps its place while the list refreshes). Archived turns and hidden projects are left out.
    static func make(_ model: AppModel) -> [AgentDot] {
        let prefs = model.prefs
        let multiBox = model.boxes.count > 1
        var out: [(dot: AgentDot, since: Date, created: Date)] = []
        for b in model.boxes {
            for s in b.sessions {
                guard let st = DashState(s) else { continue }
                let bs = BoxSession(box: b.name, session: s)
                if prefs.isHidden(box: b.name, location: bs.location) { continue }
                if st == .done, prefs.isClosed(box: b.name, session: s) { continue }
                var project = bs.location.isEmpty ? "" : prefs.displayName(box: b.name, location: bs.location)
                if let wt = bs.worktree { project += project.isEmpty ? wt : "/\(wt)" }
                if multiBox { project = project.isEmpty ? b.name : "\(project) (\(b.name))" }
                let dot = AgentDot(box: b.name, session: s.name, state: st, title: DisplayNames.sessionName(s, among: b.sessions), project: project)
                out.append((dot, s.stateSince ?? s.created, s.created))
            }
        }
        let rank: [DashState: Int] = [.needsYou: 0, .working: 1, .done: 2, .ready: 3]
        return out.sorted { a, b in
            let ra = rank[a.dot.state] ?? 9, rb = rank[b.dot.state] ?? 9
            if ra != rb { return ra < rb }
            if a.dot.state == .needsYou, a.since != b.since { return a.since < b.since }
            if a.created != b.created { return a.created < b.created }
            return a.dot.id < b.dot.id
        }.map(\.dot)
    }

    nonisolated static func stateWord(_ s: DashState) -> String {
        switch s {
        case .needsYou: S("Precisa de você")
        case .working: S("Trabalhando")
        case .done: S("Sua vez")
        case .ready: S("Pronto")
        }
    }
}

/// A compact strip with a dot per live agent. Tap a dot to open its session; the labels (title · project) show while ⌥ is
/// held (hardware keyboard), while the pointer rests on the strip (iPad, Mac) or after a long press (touch).
struct AgentDotStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?

    private var dotSize: CGFloat { 12 }
    /// More than this collapses the rest into "+N".
    private var maxDots: Int { 28 }

    var body: some View {
        let dots = AgentDots.make(model)
        let showLabels = ModifierKeys.shared.labelsPinned || hovering || ModifierKeys.shared.option
        Group {
            if !dots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if showLabels { labels(dots) } else { strip(dots) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
                }
                .contentShape(Rectangle())
                .onHover { inside in hover(inside) }
                .onLongPressGesture(minimumDuration: 0.35) { openLabelsForAWhile() }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: dots)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: showLabels)
        .background(ModifierKeysHook().frame(width: 0, height: 0))
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ModifierKeys.shared.optionSeen {
                Text(verbatim: "⌥").font(.system(size: 1)).opacity(0.02).accessibilityIdentifier("agent-dots-option-seen")
            }
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Agentes"))
        .accessibilityIdentifier("agent-dots")
    }

    // MARK: dots

    private func strip(_ dots: [AgentDot]) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                ForEach(dots.prefix(maxDots)) { d in
                    Button { open(d) } label: {
                        AgentDotView(state: d.state, size: dotSize)
                            .frame(width: dotSize + 6, height: dotSize + 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(d.label)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                    .accessibilityLabel(Text(d.title))
                    .accessibilityValue(Text(d.accessibilityValue))
                    .accessibilityHint(Text("Abre a sessão"))
                    .accessibilityIdentifier("agent-dot-\(d.session)")
                }
                if dots.count > maxDots {
                    Text("+\(dots.count - maxDots)").font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.textDim)
                        .accessibilityIdentifier("agent-dots-more")
                }
            }
            Spacer(minLength: 4)
            summary(dots)
        }
    }

    /// "2 precisam de você" in amber when someone waits, else how many agents there are.
    @ViewBuilder private func summary(_ dots: [AgentDot]) -> some View {
        let waiting = dots.filter { $0.state == .needsYou }.count
        Group {
            if waiting > 0 {
                Text(waiting == 1 ? S("1 precisa de você") : S("\(waiting) precisam de você")).foregroundStyle(Theme.orange)
            } else {
                Text(dots.count == 1 ? S("1 agente") : S("\(dots.count) agentes")).foregroundStyle(Theme.textDim)
            }
        }
        .font(.caption.weight(.medium).monospacedDigit())
        .lineLimit(1)
        .accessibilityIdentifier("agent-dots-summary")
    }

    // MARK: labels

    @ViewBuilder private func labels(_ dots: [AgentDot]) -> some View {
        let chips = ForEach(dots) { d in
            Button { open(d) } label: {
                HStack(spacing: 7) {
                    AgentDotView(state: d.state, size: 8)
                    Text(d.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if !d.project.isEmpty {
                        Text(d.project).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(maxWidth: 320, alignment: .leading)
                .background(d.state.color.opacity(0.13), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .transition(.opacity)
            .accessibilityLabel(Text(d.title))
            .accessibilityValue(Text(d.accessibilityValue))
            .accessibilityIdentifier("agent-label-\(d.session)")
        }
        FlowLayout(spacing: 6, lineSpacing: 6) { chips }
    }

    // MARK: actions

    private func open(_ d: AgentDot) {
        Haptic.impact(.light)
        ModifierKeys.shared.labelsPinned = false
        model.openSession(box: d.box, name: d.session)
    }

    private func openLabelsForAWhile() {
        Haptic.impact(.medium)
        ModifierKeys.shared.labelsPinned.toggle()
        collapseTask?.cancel()
        guard ModifierKeys.shared.labelsPinned else { return }
        collapseTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { ModifierKeys.shared.labelsPinned = false }
        }
    }

    /// The pointer resting on the strip (not just passing over it) shows the labels; leaving hides them.
    private func hover(_ inside: Bool) {
        hoverTask?.cancel()
        if inside {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { hovering = true }
            }
        } else {
            hovering = false
        }
    }
}

/// A state dot; working breathes gently (not with Reduce Motion), needs-you has a soft halo.
struct AgentDotView: View {
    let state: DashState
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            if state == .needsYou {
                Circle().fill(state.color.opacity(0.28)).frame(width: size + 6, height: size + 6)
            }
            if state == .working && !reduceMotion {
                Circle().stroke(state.color.opacity(breathe ? 0 : 0.55), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(breathe ? 1.9 : 1)
            }
            Circle().fill(state.color).frame(width: size, height: size)
        }
        .frame(width: size + 6, height: size + 6)
        .onAppear { if state == .working { startBreathing() } }
        .onChange(of: state) { _, s in breathe = false; if s == .working { startBreathing() } }
        .accessibilityHidden(true)
    }

    private func startBreathing() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { breathe = true }
    }
}
