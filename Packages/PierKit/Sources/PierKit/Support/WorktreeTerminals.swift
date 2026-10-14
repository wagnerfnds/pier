import Foundation

/// The plain terminals of a worktree, as the session screen's terminal tabs show them beside an agent working there: the
/// shells and commands the person runs there (no agent, no service), oldest first; what each tab is called; and what
/// one runs right now, read from its screen.
public enum WorktreeTerminals {
    /// A shell or a command: no agent (by its preset or by its command) and no service. A chat is always an agent.
    public static func isTerminal(_ s: Session) -> Bool {
        s.service == nil && !s.chat && DisplayNames.agent(of: s) == nil
    }

    /// The terminals of one worktree, oldest first (a new one is the last tab): those started on its ref (`"loc/wt"`, or
    /// `"loc"` for the main checkout), and those started with no location in its folder or one inside it, when no other
    /// worktree's folder (`paths`: every worktree of the box, other projects' too) holds theirs more closely.
    public static func sessions(_ all: [Session], ref: String, path: String, paths: [String]) -> [Session] {
        let own = folder(path)
        return all.filter { s in
            guard isTerminal(s) else { return false }
            if let l = s.location, !l.isEmpty { return l == ref }
            return !own.isEmpty && closest(s.dir, in: paths + [path]) == own
        }
        .sorted { ($0.created, $0.name) < ($1.created, $1.name) }
    }

    /// The worktree folder that holds `dir` most closely: `dir` itself, or the deepest one it is inside.
    static func closest(_ dir: String, in paths: [String]) -> String? {
        let d = folder(dir)
        guard !d.isEmpty else { return nil }
        return paths.map(folder).filter { !$0.isEmpty && (d == $0 || d.hasPrefix($0 + "/")) }.max { $0.count < $1.count }
    }

    private static func folder(_ path: String) -> String {
        var p = path.jsTrimmed
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: names

    /// What a tab says.
    public enum Label: Equatable, Sendable {
        /// The name the person gave it (or the box did, after the first line typed in a terminal opened elsewhere).
        case named(String)
        /// A command: the one running at its prompt (read from its screen), else the one it was started with.
        case command(String)
        /// "Terminal 2": the number in the title the app gave it, else its place among the worktree's terminals.
        case numbered(Int)
    }

    private static let titleWord = "Terminal "

    /// The title the app gives a terminal it opens, so the box does not name it after the first line typed (docs/API.md
    /// 4.3); a tab with one shows what runs in it instead, when something does. Not translated: it is kept on the box,
    /// which devices in either language share; each shows it in its own (`Label.numbered`).
    public static func defaultTitle(_ n: Int) -> String { titleWord + String(n) }

    /// The number in a default title ("Terminal 2" → 2); nil for any other title.
    public static func number(inTitle title: String?) -> Int? {
        guard let t = title?.jsTrimmed, t.hasPrefix(titleWord), let n = Int(t.dropFirst(titleWord.count)), n > 0 else { return nil }
        return n
    }

    /// The tab of `s`, the `position`-th (from 1) of its worktree's terminals; `running`: what its screen shows running
    /// (`runningCommand(in:)`), once the screen has been read.
    public static func label(_ s: Session, position: Int, running: String?) -> Label {
        let title = s.title?.jsTrimmed ?? ""
        let n = number(inTitle: title)
        if !title.isEmpty, n == nil { return .named(title) }
        if !s.exited, let running, !running.isEmpty { return .command(running) }
        if let c = s.command?.jsTrimmed, !c.isEmpty { return .command(c) }
        return .numbered(n ?? position)
    }

    /// The number for a new terminal: the smallest one the worktree's terminals do not show.
    public static func nextNumber(_ terminals: [Session]) -> Int {
        var taken = Set<Int>()
        for (i, s) in terminals.enumerated() {
            if let n = number(inTitle: s.title) {
                taken.insert(n)
            } else if (s.title?.jsTrimmed ?? "").isEmpty, (s.command?.jsTrimmed ?? "").isEmpty {
                taken.insert(i + 1)
            }
        }
        var n = 1
        while taken.contains(n) { n += 1 }
        return n
    }

    /// A session name for a terminal when the box's own (`<ref>-shell-<time>`, the same for two opened in one second) is
    /// taken: the ref with what tmux names refuse turned into "-", then `suffix` (names are `[A-Za-z0-9][A-Za-z0-9_-]*`,
    /// 63 characters at most).
    public static func sessionName(location: String, suffix: String) -> String {
        var base = Rx.unsafeName.replacing(location, with: "-")
        while let f = base.first, f == "-" || f == "_" { base.removeFirst() }
        if base.isEmpty { base = "term" }
        return String((base.prefix(40) + "-shell-" + suffix).prefix(63))
    }

    // MARK: what runs

    /// The command typed at the shell's latest prompt while that prompt has not come back: what the terminal runs right
    /// now ("npm run dev"). nil at an idle prompt, and when no prompt can be read on the screen's last 400 lines (a
    /// full-screen program, a prompt of an unusual shape): the tab then keeps its name.
    public static func runningCommand(in screen: String) -> String? {
        let lines = screen.components(separatedBy: "\n")
        var i = lines.count - 1
        while i >= 0, lines[i].isBlank { i -= 1 }
        guard i >= 0 else { return nil }
        // Output with no line break at its end puts the prompt after it, on the same line ("doneubuntu@devbox:~$").
        if Rx.promptAtEnd.test(lines[i].trimmedEnd) { return nil }
        let floor = max(0, i - 400)
        while i >= floor {
            if let typed = promptInput(lines[i]) { return typed.isEmpty ? nil : typed }
            i -= 1
        }
        return nil
    }

    /// A line of the screen read as a shell's prompt: what was typed after it ("" at a prompt with nothing typed); nil when
    /// the line is no prompt. Bash's `user@host:~/dir$`, `[user@host dir]$` and root's `#`, fish's `user@host ~/dir>`,
    /// zsh's `user@host ~ %` and `host%`, a bare `$`, Starship's and Pure's `❯`, oh-my-zsh's `➜  dir git:(main) ✗`.
    static func promptInput(_ line: String) -> String? {
        let l = line.trimmedEnd
        for p in Rx.prompts {
            if let m = p.match(l) { return (m.count > 1 ? m[m.count - 1] : nil)?.jsTrimmed ?? "" }
        }
        return nil
    }
}

extension Rx {
    /// What tmux session names may not hold (pierd's `unsafeSessionChars`).
    static let unsafeName = Rx(#"[^A-Za-z0-9_-]+"#)
    /// The shapes of prompt `WorktreeTerminals.promptInput` reads; the last group is what was typed.
    static let prompts = [
        Rx(#"^\[?[\w.+-]+@[\w.-]+(?:[ :][^\n]{0,160}?)?[$#%>](?: (.*))?$"#),
        Rx(#"^[$%](?: (.*))?$"#),
        Rx(#"^[A-Za-z][\w.-]*%(?: (.*))?$"#),
        Rx(#"^❯(?: (.*))?$"#),
        Rx(#"^➜ +[^ ]+(?: +git:\([^)]*\))?(?: +✗)?(?: +(.*))?$"#),
    ]
    /// A `user@host…$` (or root's `#`) prompt closing the last line, after output that had no line break.
    static let promptAtEnd = Rx(#"[\w.+-]+@[\w.-]+[ :][^\n]{0,160}[$#]$"#)
}
