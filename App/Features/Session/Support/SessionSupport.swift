import SwiftUI
import PierKit

// Localisation helpers: keys are the pt-BR strings; English lives in Localizable.xcstrings.
func T(_ key: LocalizedStringKey) -> Text { Text(key) }
func S(_ key: String.LocalizationValue) -> String { String(localized: key) }

enum SessionViewMode: String, Hashable { case conversation, terminal }

/// Per-session memory of the view the person chose (conversation is the default; terminal only when asked for).
enum SessionViewPrefs {
    private static func key(_ box: String, _ name: String) -> String { "session.view.\(box)/\(name)" }
    static func mode(box: String, name: String) -> SessionViewMode? {
        UserDefaults.standard.string(forKey: key(box, name)).flatMap(SessionViewMode.init(rawValue:))
    }
    static func set(_ mode: SessionViewMode, box: String, name: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: key(box, name))
    }
}

extension Session {
    /// Best display title: rename/first prompt, else worktree, else name.
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let wt = BoxSession(box: "", session: self).worktree { return wt }
        return name
    }

    /// "Claude Code", "Codex", "Terminal".
    var agentLabel: String { agent.map(DisplayNames.agentLabel) ?? S("Terminal") }

    /// The agent's first name, for sentences: "Claude quer executar", "Mensagem para Codex".
    var agentShortName: String {
        guard let a = agent, !a.isEmpty else { return S("o terminal") }
        return DisplayNames.agentLabel(a).split(separator: " ").first.map(String.init) ?? a
    }

    /// One short word for the header, the same four words every screen uses: "Trabalhando", "Precisa de você", "Sua vez",
    /// "Pronto" (and "Encerrada" / "Terminal").
    var stateWord: String {
        if exited { return S("Encerrada") }
        guard isAgent else { return S("Terminal") }
        switch agentState {
        case .waiting: return S("Precisa de você")
        case .running: return S("Trabalhando")
        case .finished: return S("Sua vez")
        default: return S("Pronto")
        }
    }
}

/// Terminal text clean-up for display: strips ANSI and the box's side panel (PierKit does the parsing on raw screens).
enum TerminalText {
    static func clean(_ raw: String) -> String { MenuParser.stripPanel(ANSI.strip(raw)) }

    /// For display: long runs of blank lines (tall panes) collapse to one.
    static func compact(_ s: String) -> String {
        var out: [Substring] = []
        var blanks = 0
        for l in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if l.allSatisfy(\.isWhitespace) { blanks += 1; if blanks > 1 { continue } } else { blanks = 0 }
            out.append(l)
        }
        return out.joined(separator: "\n")
    }
}

enum Haptic {
    @MainActor static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    @MainActor static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// "Leu 3 arquivos", "Editou calc.py" ...
enum ToolSummary {
    static func title(verb: String, calls: [TranscriptItem.Call]) -> String {
        let p = parts(verb: verb, calls: calls)
        return p.target.map { "\(p.title) \($0)" } ?? p.title
    }

    /// The verb in words and, for a single call, what it acted on (drawn in monospace): ("Executou", "python3 test.py").
    static func parts(verb: String, calls: [TranscriptItem.Call]) -> (title: String, target: String?) {
        let n = calls.count
        let one = n == 1 ? shortTarget(calls[0].target) : ""
        switch verb.lowercased() {
        case "read": return n == 1 ? (S("Leu"), one) : (S("Leu \(n) arquivos"), nil)
        case "run", "bash", "shell", "exec": return n == 1 ? (S("Executou"), one) : (S("Executou \(n) comandos"), nil)
        case "edit", "write", "patch", "update": return n == 1 ? (S("Editou"), one) : (S("Editou \(n) arquivos"), nil)
        case "search", "grep", "glob", "find": return n == 1 ? (S("Buscou"), one) : (S("Fez \(n) buscas"), nil)
        case "fetch", "web", "webfetch", "websearch": return n == 1 ? (S("Acessou"), one) : (S("Acessou a web \(n)×"), nil)
        case "task", "agent": return n == 1 ? (S("Delegou a um subagente"), nil) : (S("Delegou \(n) tarefas"), nil)
        case "todo", "todowrite": return (S("Atualizou a lista de tarefas"), nil)
        default: return n == 1 ? (verb, one) : ("\(verb) ×\(n)", nil)
        }
    }

    static func symbol(verb: String) -> String {
        switch verb.lowercased() {
        case "read": "doc.text"
        case "run", "bash", "shell", "exec": "terminal"
        case "edit", "write", "patch", "update": "pencil"
        case "search", "grep", "glob", "find": "magnifyingglass"
        case "fetch", "web", "webfetch", "websearch": "globe"
        case "task", "agent": "person.2"
        default: "wrench.and.screwdriver"
        }
    }

    static func shortTarget(_ t: String) -> String {
        let one = t.split(separator: "\n").first.map(String.init) ?? t
        return one.count > 40 ? String(one.prefix(40)) + "…" : one
    }

    /// "3 comandos, 5 arquivos lidos, 2 buscas" for a folded stretch of work.
    static func workSummary(_ steps: [TranscriptItem]) -> String {
        let w = ConversationFold.work(in: steps)
        var parts: [String] = []
        if w.run > 0 { parts.append(w.run == 1 ? S("1 comando") : S("\(w.run) comandos")) }
        if w.read > 0 { parts.append(w.read == 1 ? S("1 arquivo lido") : S("\(w.read) arquivos lidos")) }
        if w.search > 0 { parts.append(w.search == 1 ? S("1 busca") : S("\(w.search) buscas")) }
        if w.helpers > 0 { parts.append(w.helpers == 1 ? S("1 subagente") : S("\(w.helpers) subagentes")) }
        if w.other > 0 { parts.append(w.other == 1 ? S("1 ferramenta") : S("\(w.other) ferramentas")) }
        if parts.isEmpty, w.notes > 0 { parts.append(w.notes == 1 ? S("1 nota") : S("\(w.notes) notas")) }
        return parts.joined(separator: ", ")
    }
}

/// What the agent wants, in words: "quer executar", "quer editar"...
enum PermissionWording {
    static func headline(agent: String, tool: String?) -> (text: String, mono: Bool) {
        guard let tool, !tool.isEmpty else { return (S("\(agent) precisa de você"), false) }
        if tool.hasPrefix("mcp__") {
            let parts = tool.split(separator: "__", maxSplits: 2).map(String.init)
            let name = parts.count > 2 ? parts[2].replacingOccurrences(of: "_", with: " ") : tool
            return (S("\(agent) quer usar \(name)"), false)
        }
        switch tool {
        case "Bash": return (S("\(agent) quer executar"), true)
        case "Edit", "MultiEdit", "NotebookEdit": return (S("\(agent) quer editar"), true)
        case "Write": return (S("\(agent) quer escrever"), true)
        case "Read": return (S("\(agent) quer ler"), true)
        case "WebFetch": return (S("\(agent) quer acessar"), true)
        case "WebSearch": return (S("\(agent) quer pesquisar na web"), false)
        case "AskUserQuestion", "request_user_input": return (S("\(agent) tem uma pergunta"), false)
        case "ExitPlanMode": return (S("\(agent) tem um plano para você aprovar"), false)
        default: return (S("\(agent) quer usar \(tool)"), false)
        }
    }
}

extension Signals {
    var contextPercent: Int? {
        guard let c = context, let w = c.window, w > 0 else { return nil }
        return min(100, Int((Double(c.tokens) / Double(w) * 100).rounded()))
    }
    static func compactTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
    var shortModel: String? {
        guard let m = model, !m.isEmpty else { return nil }
        return m.replacingOccurrences(of: "claude-", with: "")
    }
}

/// A label whose text a soft light passes over: "Trabalhando" while the agent works. The light is a gradient layer that
/// Core Animation moves (`ShimmerSweep`), masked by the text: nothing runs on the main thread per frame. (A SwiftUI
/// `repeatForever` animation updated the view graph 60 times a second, about a fifth of the main thread while an agent
/// worked, and every streamed update on top of it missed frames.)
struct ShimmerText: View {
    let text: String
    var font: Font = .footnote.weight(.medium)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text).font(font)
            .foregroundStyle(Theme.textDim)
            .overlay {
                if !reduceMotion, Motion.endless { ShimmerSweep().mask(Text(text).font(font)).accessibilityHidden(true) }
            }
    }
}

/// Whether endless animations run. Core Animation's (`ShimmerSweep`, `PulsingDot`) read to XCUITest as an app that
/// never goes idle, so every tap while one showed waited 60 s: under the mock box's UI tests they stand still, as with
/// Reduce Motion (the performance probe keeps them, to measure what people get).
enum Motion {
    static let endless = !UITestMock.enabled || UserDefaults.standard.bool(forKey: "chatPerfProbe")
}

/// The light of `ShimmerText`: a soft band of the text color crossing the view every 2.2 s.
private struct ShimmerSweep: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> SweepView { SweepView() }

    func updateUIView(_ view: SweepView, context: Context) {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        view.color = UIColor(Theme.text).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    final class SweepView: UIView {
        private let band = CAGradientLayer()
        private var animatedWidth: CGFloat = -1
        var color: UIColor = .label {
            didSet { band.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor] }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            layer.addSublayer(band)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.width != animatedWidth { sweep() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Core Animation drops animations from a layer that leaves the window (another tab, the app in the background).
            if window != nil { sweep() }
        }

        private func sweep() {
            let w = bounds.width
            guard w > 0, window != nil else { return }
            animatedWidth = w
            let bandWidth = max(40, w * 0.6)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.bounds = CGRect(x: 0, y: 0, width: bandWidth, height: bounds.height)
            band.position = CGPoint(x: -bandWidth / 2, y: bounds.midY)
            CATransaction.commit()
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -w * 0.6 + bandWidth / 2
            move.toValue = w + bandWidth / 2
            move.duration = 2.2
            move.repeatCount = .infinity
            band.add(move, forKey: "sweep")
        }
    }
}
