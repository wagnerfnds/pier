import SwiftUI
import GhosttyTerminal
import PierKit

// A shell on the box as a real terminal: libghostty (Ghostty's VT engine and Metal renderer, through GhosttyTerminal)
// draws it, fed by the box's terminal stream (`POST /v1/sessions/{name}/tty`: the app is a tmux client of the session),
// and what is typed in it goes back the same way, as a keyboard on the box would type it: ⌃C, the arrows, Tab
// completion, a paste, a program's own keys. A box without the stream (capability `tty`) keeps the screen read every
// second and the command line (TerminalPane, SessionTerminals.swift).

/// The bytes between the terminal and the box. Ghostty calls back on its own queue, so this is reached from any thread.
final class TerminalPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: TerminalStream?
    private var size: (cols: Int, rows: Int)?

    /// The stream what is typed goes to.
    func attach(_ s: TerminalStream) { lock.withLock { stream = s } }

    /// `s` ended: nothing typed goes anywhere until the next stream, unless a newer one took its place already.
    func detach(_ s: TerminalStream) { lock.withLock { if stream === s { stream = nil } } }

    /// The terminal's size in characters, once laid out.
    var currentSize: (cols: Int, rows: Int)? { lock.withLock { size } }

    func type(_ data: Data) {
        let s = lock.withLock { () -> TerminalStream? in
            // A line ends with Enter (or is dropped with ⌃C); any other key edits the one being typed.
            if data.contains(0x0D) || data.contains(0x0A) || data.contains(0x03) {
                typing = false
            } else if data.contains(where: { $0 >= 0x20 || $0 == 0x1B }) {
                typing = true
            }
            keyed &+= 1
            return stream
        }
        s?.type(data)
    }

    /// Keys typed since the last Enter: the prompt's line on screen is being typed, nothing was run from it yet.
    var isTyping: Bool { lock.withLock { typing } }
    private var typing = false
    private var keyed = 0

    /// Returns after `timeout`, or a moment after a key is typed (its answer drawn by then).
    func keyOrTimeout(_ timeout: Duration) async {
        let start = lock.withLock { keyed }
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            if lock.withLock({ keyed }) != start {
                try? await Task.sleep(for: .milliseconds(250))
                return
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let s = lock.withLock { () -> TerminalStream? in
            size = (cols, rows)
            return stream
        }
        s?.resize(cols: cols, rows: rows)
    }
}

/// One terminal on the box, live while its view is on screen (`run()`), kept for the app's run so a tab picked again
/// shows at once. A new stream starts over: the box sends the scrollback and the screen again.
@MainActor @Observable
final class LiveTerminal {
    enum Phase: Equatable {
        /// Opening the stream (the first time, or again after the screen closed).
        case connecting
        case live
        /// The connection dropped: trying again, the last screen still up.
        case reconnecting
        /// The session is gone.
        case ended
        /// The box refused it (too many open, a gate): the reason, in its words.
        case failed(String)
    }

    let box: String
    let name: String
    private(set) var phase: Phase = .connecting
    /// What runs in front, read from the screen (the tab's name); nil at a prompt.
    private(set) var running: String?
    /// The screen's last lines, read every two seconds while it shows and VoiceOver runs: what VoiceOver reads of it.
    private(set) var screenText = ""

    /// Ghostty's state for the view (configuration, focus, keys).
    @ObservationIgnored let state: TerminalViewState
    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private let pipe: TerminalPipe
    @ObservationIgnored private weak var model: AppModel?
    /// A stream fed this surface already: the next one clears it first (its scrollback comes again).
    @ObservationIgnored private var fed = false
    /// The latest `run()`: two views can show one terminal for a moment (two agents' screens of a worktree, in a push),
    /// and the newer one's stream is the one that feeds the surface and takes the keys.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastScreen = ""
    @ObservationIgnored private var lastTyping = false

    private init(box: String, name: String, model: AppModel?) {
        self.box = box
        self.name = name
        self.model = model
        let pipe = TerminalPipe()
        self.pipe = pipe
        session = InMemoryTerminalSession(
            write: { pipe.type($0) },
            resize: { pipe.resize(cols: Int($0.columns), rows: Int($0.rows)) },
            // Only columns and rows matter to the box; a drag of the window repaints once per character, not per pixel.
            suppressesPixelOnlyResizes: true)
        state = TerminalViewState(theme: Self.theme, terminalConfiguration: Self.base)
        // The first terminal starts Ghostty, which sets the process's C locale to the person's (`setlocale(LC_ALL, "")`):
        // with a decimal comma (pt_BR) `strtod` stops at the point, and UIKit's SF Symbols came out about 3 points wide
        // for the rest of the run (blank buttons; one drawn at that size aborted the app). Numbers go back to the C
        // locale; the rest stays as Ghostty set it (UTF-8 text).
        setlocale(LC_NUMERIC, "C")
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), resizeThrottleMilliseconds: 50)
    }

    private static var registry: [String: LiveTerminal] = [:]

    /// The terminal of session `name` on `box`, made the first time it shows.
    static func of(box: String, name: String, model: AppModel?) -> LiveTerminal {
        let key = "\(box)/\(name)"
        if let t = registry[key] {
            if t.model == nil { t.model = model }
            return t
        }
        let t = LiveTerminal(box: box, name: name, model: model)
        registry[key] = t
        return t
    }

    /// The terminal of a session shown already; nil for one that never showed.
    static func existing(box: String, name: String) -> LiveTerminal? { registry["\(box)/\(name)"] }

    /// The terminals of sessions that are gone are let go.
    static func forget(box: String, keeping names: Set<String>, among all: [String]) {
        for name in all where !names.contains(name) { registry["\(box)/\(name)"] = nil }
    }

    /// Whether `box` serves terminal streams (capability `tty`): else the screen is read and lines are sent.
    static func supported(box: String, model: AppModel?) -> Bool {
        model?.connection(for: box)?.info?.has("tty") == true
    }

    /// The session is still on the box's list, as last read.
    private var listed: Bool { model?.connection(for: box)?.sessions.contains { $0.name == name } ?? false }

    /// The stream, while the view shows: opened once the terminal knows its size, opened again when the connection
    /// drops (a moment later, then less often), ended when the session is. A newer run takes over from this one.
    func run() async {
        generation &+= 1
        let mine = generation
        var current: Bool { generation == mine && !Task.isCancelled }
        // The box draws at the terminal's size: wait until the surface is laid out.
        while pipe.currentSize == nil {
            try? await Task.sleep(for: .milliseconds(50))
            if !current { return }
        }
        var backoff = 1.0
        while current {
            guard let size = pipe.currentSize, let client = model?.client(for: box) else { return }
            let stream = client.terminal(session: name, cols: size.cols, rows: size.rows, history: nil)
            pipe.attach(stream)
            if fed {
                // The box draws it all again, the scrollback first: the old one goes (a full reset, then the
                // scrollback erased).
                session.receive(Data("\u{1b}c\u{1b}[3J".utf8))
            }
            if phase != .reconnecting { phase = .connecting }
            var liveSince: ContinuousClock.Instant?
            do {
                for try await chunk in stream.output {
                    guard generation == mine else { break }
                    if phase != .live {
                        phase = .live
                        liveSince = .now
                    }
                    fed = true
                    session.receive(chunk)
                }
                stream.close()
                pipe.detach(stream)
                if !current { return }
                // The box ended it: the session is gone (a shell that ended stays, its last screen shown), unless its
                // terminal was detached on the box (`tmux detach`) while the session goes on: then it opens again.
                guard listed else {
                    phase = .ended
                    return
                }
                phase = .reconnecting
            } catch let e as BoxError {
                pipe.detach(stream)
                if !current { return }
                if e.status == 404 { phase = .ended } else { phase = .failed(e.error) }
                return
            } catch let e as PierError where !e.isTransient {
                // Revoked, the box's key changed: trying again would not help.
                pipe.detach(stream)
                if !current { return }
                phase = .failed(e.errorDescription ?? "\(e)")
                return
            } catch {
                pipe.detach(stream)
                if !current { return }
                phase = .reconnecting
            }
            // A stream that lasted starts the wait over; one that ends at once (its scrollback came, then nothing) waits
            // longer each time, up to 15 s.
            if let since = liveSince, ContinuousClock.now - since > .seconds(5) { backoff = 1 }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 15)
        }
    }

    /// Reads the screen (what runs in front, the text VoiceOver reads) every two seconds while the terminal shows; at
    /// once after a key, so a line's answer is read as soon as it is drawn.
    func watchRunning() async {
        while !Task.isCancelled {
            // Off the main thread (the read is thread-safe): it walks the screen row by row through the engine.
            let session = session
            let read = await Task.detached(priority: .utility) { session.readViewportText() }.value
            if let text = read, text != lastScreen || pipe.isTyping != lastTyping {
                lastTyping = pipe.isTyping
                lastScreen = text
                // Only while VoiceOver runs: the whole screen as the terminal's value, rewritten every two seconds, was
                // read by everything that walks the app's accessibility tree (window managers, text expanders) and on the
                // Mac each walk goes through the main thread.
                let spoken = UIAccessibility.isVoiceOverRunning ? Self.spoken(text) : ""
                if spoken != screenText { screenText = spoken }
                let command = WorktreeTerminals.runningCommand(in: text, typing: pipe.isTyping)
                if command != running { running = command }
            }
            await pipe.keyOrTimeout(.seconds(2))
        }
    }

    /// The screen's last lines, trimmed, as VoiceOver reads them.
    private static func spoken(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(40)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tries a refused or ended terminal again (the banner's Tentar de novo).
    func retry() { phase = .connecting }

    /// A key from the keys bar, encoded as the program's modes want it.
    func press(_ key: ControlKey) {
        switch key {
        case .escape: state.sendKey(.escape)
        case .enter: state.sendKey(.enter)
        case .tab: state.sendKey(.tab)
        case .btab: state.sendKey(.tab, modifiers: .shift)
        case .up: state.sendKey(.arrowUp)
        case .down: state.sendKey(.arrowDown)
        case .left: state.sendKey(.arrowLeft)
        case .right: state.sendKey(.arrowRight)
        case .interrupt: state.sendKey(.c, modifiers: .ctrl)
        default: pipe.type(Data(key.rawValue.utf8))
        }
    }

    // MARK: look

    /// The app's terminal colors (Theme.terminalBg / terminalText), with GitHub's ANSI palettes, which were made for
    /// them; JetBrains Mono, which Ghostty carries, with the Nerd Font symbols of a fancy prompt. Ghostty sizes fonts at
    /// 96 dpi under UIKit, so a size here shows a third larger: these come out at about 12.5 pt on the Mac, 13 on the
    /// iPad and 11.5 on the iPhone, as the screen's own terminal text.
    static let fontSize: Float = Platform.isMac ? 9.5 : UIDevice.current.userInterfaceIdiom == .pad ? 9.75 : 8.75

    private static let base = TerminalConfiguration {
        $0.withFontSize(fontSize)
        $0.withWindowPaddingX(10)
        $0.withWindowPaddingY(8)
        $0.withCursorStyle(.bar)
        // A color too close to the background (yellow on white) is darkened until it reads.
        $0.withMinimumContrast(1.6)
    }

    private static let theme = TerminalTheme(
        light: palette(background: "#FBFBFC", foreground: "#24292F", cursor: "#0A67D0", selection: "#CFE3FB", ansi: [
            "#24292F", "#CF222E", "#116329", "#4D2D00", "#0969DA", "#8250DF", "#1B7C83", "#6E7781",
            "#57606A", "#A40E26", "#1A7F37", "#633C01", "#218BFF", "#A475F9", "#3192AA", "#8C959F",
        ]),
        dark: palette(background: "#121416", foreground: "#D6D9DE", cursor: "#4A99FA", selection: "#264466", ansi: [
            "#484F58", "#FF7B72", "#3FB950", "#D29922", "#58A6FF", "#BC8CFF", "#39C5CF", "#B1BAC4",
            "#6E7681", "#FFA198", "#56D364", "#E3B341", "#79C0FF", "#D2A8FF", "#56D4DD", "#F0F6FC",
        ]))

    private static func palette(background: String, foreground: String, cursor: String, selection: String, ansi: [String]) -> TerminalConfiguration {
        TerminalConfiguration {
            $0.withBackground(background)
            $0.withForeground(foreground)
            $0.withCursorColor(cursor)
            $0.withSelectionBackground(selection)
            for (i, c) in ansi.enumerated() { $0.withPalette(i, color: c) }
        }
    }
}

// MARK: - the view

/// A live terminal filling its space: Ghostty's surface, a word over it while it connects or after it ended, and on
/// the iPhone and the iPad the keys bar under it while the keyboard is down (Esc, Tab, ⌃C, the arrows; with the
/// keyboard up, Ghostty's own bar has them). Clicking it (or picking its tab on the Mac) gives it the keyboard.
struct LiveTerminalView: View {
    let terminal: LiveTerminal
    /// Shown (its tab picked): hidden ones keep their stream but stop drawing.
    var visible = true
    /// Take the keyboard when it shows (a terminal just opened, its tab picked on the Mac).
    var focus = false
    var onFocused: () -> Void = {}
    var showsKeys = !Platform.isMac
    @Environment(\.scenePhase) private var scenePhase
    @State private var attempt = 0
    /// The software keyboard is up: Ghostty's own bar rides on it (Esc, Ctrl, Tab, the arrows, symbols), so ours goes.
    @State private var keyboardUp = false

    private struct Run: Equatable { let foreground: Bool; let attempt: Int }

    var body: some View {
        VStack(spacing: 0) {
            TerminalSurfaceView(context: terminal.state)
                .overlay { overlay }
                .background(Theme.terminalBg)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Terminal")
                .accessibilityValue(terminal.screenText)
                .accessibilityIdentifier("live-terminal")
            if showsKeys, visible, !keyboardUp { LiveKeysBar(terminal: terminal) }
        }
        // A terminal kept mounted under another tab is no part of what is on screen.
        .accessibilityHidden(!visible)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        // The stream lives while the terminal shows and the app is in front (on the Mac, a window behind another
        // still is); it starts over when it comes back.
        .task(id: Run(foreground: Platform.isMac || scenePhase != .background, attempt: attempt)) {
            guard Platform.isMac || scenePhase != .background else { return }
            await terminal.run()
        }
        .task(id: visible) {
            guard visible else { return }
            await terminal.watchRunning()
        }
        .onChange(of: visible, initial: true) { _, v in
            terminal.state.isSurfaceVisible = v
            // Put away (another tab, Conversa), it lets go of the keyboard: what is typed next is not for a shell no one
            // sees.
            if !v, let view = terminal.state.attachedPlatformView, view.isFirstResponder { view.resignFirstResponder() }
        }
        .onChange(of: focus, initial: true) { _, f in
            guard f, visible else { return }
            terminal.state.requestFocus()
            onFocused()
        }
    }

    @ViewBuilder private var overlay: some View {
        switch terminal.phase {
        case .connecting:
            ProgressView().controlSize(.small)
        case .reconnecting:
            notice(Text("Reconectando…"), symbol: "wifi.exclamationmark", action: nil)
        case .ended:
            notice(Text("Esta sessão terminou na box."), symbol: "poweroff", action: nil)
        case .failed(let why):
            notice(Text(verbatim: why), symbol: "exclamationmark.triangle", action: (S("Tentar de novo"), {
                terminal.retry()
                attempt += 1
            }))
        case .live:
            EmptyView()
        }
    }

    private func notice(_ text: Text, symbol: String, action: (String, () -> Void)?) -> some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Theme.textDim)
                text.font(.system(size: Density.small + 1)).foregroundStyle(Theme.text).lineLimit(2)
                if let action {
                    Button(action.0, action: action.1).buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 10)
            Spacer()
        }
    }
}

/// The keys a phone's keyboard lacks, typed into the live terminal as the program's modes want them.
private struct LiveKeysBar: View {
    let terminal: LiveTerminal

    private let keys: [(label: String, key: ControlKey, a11y: String?)] = [
        ("Esc", .escape, nil), ("Tab", .tab, nil), ("⌃C", .interrupt, S("Control C, interromper")),
        ("↑", .up, S("Seta para cima")), ("↓", .down, S("Seta para baixo")), ("←", .left, S("Seta para a esquerda")),
        ("→", .right, S("Seta para a direita")), ("↵", .enter, "Enter"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.label) { k in
                    Button { terminal.press(k.key) } label: {
                        Text(verbatim: k.label).font(.mono(14, weight: .semibold))
                            .foregroundStyle(k.key == .interrupt ? Theme.red : Theme.text)
                            .frame(minWidth: 36).padding(.vertical, 8).padding(.horizontal, 6)
                            .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(k.a11y ?? k.label)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Theme.bg)
        .accessibilityIdentifier("live-terminal-keys")
    }
}
