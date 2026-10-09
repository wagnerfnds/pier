import Foundation

// Pure functions over screen text (`GET /v1/sessions/{name}/screen`). pierd has a Go port
// (Server/pierd/internal/push/menu/menu.go): keep the regexes identical in both.

/// A numbered option read from an agent's screen (`1. Yes`).
public struct MenuChoice: Sendable, Hashable {
    public let key: String
    public let label: String
    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

/// One of the three answers a person gives to a permission menu, wired to the option's own digit.
public struct PermissionChoice: Sendable, Hashable {
    public let key: String
    /// "Allow", "Always allow" or "Deny".
    public let label: String
    /// The option as the agent words it.
    public let title: String
}

public enum PermissionAction: Sendable, Hashable {
    case allow(key: String)
    case alwaysAllow(key: String)
    case deny(key: String)

    public var key: String {
        switch self {
        case .allow(let k), .alwaysAllow(let k), .deny(let k): k
        }
    }
}

/// What the foot of an agent's screen shows (`screenAt`).
/// A menu answered with arrows and Enter, not digits: Claude Code's current dialogs (`New MCP server found…`, pickers)
/// draw options without numbers and a `❯` on the selected one.
public struct CursorMenu: Sendable, Hashable {
    public let options: [String]
    public let selected: Int

    /// Keys that move the cursor from the selected option to `index` and confirm it.
    public func keys(toPick index: Int) -> [ControlKey] {
        let d = index - selected
        return Array(repeating: d > 0 ? ControlKey.down : .up, count: abs(d)) + [.enter]
    }
}

public enum ScreenKind: Sendable, Hashable {
    /// Its own prompt, waiting for words.
    case prompt
    /// A screen of its own that keys (or numbers) answer.
    case interactive
    case unknown
}

public enum MenuParser {
    // Agents draw chrome under their output: an input box, a prompt, hints.
    private static let rule = Rx(#"^[\s─━│┃╭╮╰╯═┌┐└┘├┤┬┴┼▔▁-]+$"#)
    private static let chrome: [Rx] = [
        Rx(#"^[❯>›$#%]\s*$"#),
        Rx(#"^[❯>›]\s+(Try "|$)"#),
        Rx(#"^\s*(⏵⏵|⏸|\? for shortcuts|esc to interrupt|bypass permissions|auto mode|accept edits|plan mode)"#, ignoreCase: true),
        Rx(#"·\s*\/effort\s*$"#),
        Rx(#"^\s*[●◐◑]\s*(low|medium|high|max)\s*·"#, ignoreCase: true),
    ]

    /// The lines that say what the agent is doing: the screen without rules and chrome, the last `count`, de-indented.
    public static func meaningfulTail(_ screen: String, _ count: Int) -> [String] {
        let lines = stripPanel(screen)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmedEnd }
            .filter { l in !l.isBlank && !rule.test(l) && !chrome.contains(where: { $0.test(l.jsTrimmed) }) }
        let tail = Array(lines.suffix(count))
        let indent = tail.map { $0.count - $0.trimmedStart.count }.min() ?? 0
        return tail.map { String($0.dropFirst(indent)) }
    }

    /// `❯ 1. Yes`, also inside a dialog box (`│ ❯ 1. Use this MCP server │`, as Claude Code draws its startup dialogs).
    private static let option = Rx(#"^\s*(?:[│┃]\s*)?(?:[❯›>]\s*)?(\d)[.)]\s+(\S.*?)(?:\s+[│┃])?\s*$"#)

    /// Cuts the side panel the box draws next to a wide pane (`agent text … │ panel text`): when most non-blank lines carry a
    /// `│` at one common column (past column 30), everything from that column on is dropped, and trailing blanks too. Idempotent;
    /// screens without a panel come back unchanged (apart from trailing whitespace).
    public static func stripPanel(_ screen: String) -> String {
        // Byte scan (`│` is E2 94 82): no `[Character]` per line. Columns are counted in Unicode scalars.
        let lines = screen.utf8.split(separator: 10, omittingEmptySubsequences: false).map { Substring($0) }
        var counts: [Int: Int] = [:]
        var nonBlank = 0
        var lastBar: [Int] = []
        lastBar.reserveCapacity(lines.count)
        for l in lines {
            var scalar = -1, last = -1, blank = true, needsUnicodeCheck = false
            var p1: UInt8 = 0, p2: UInt8 = 0
            for b in l.utf8 {
                if b & 0xC0 != 0x80 { scalar += 1 }
                if b == 0x82 && p1 == 0x94 && p2 == 0xE2 { last = scalar }
                if blank {
                    if b < 0x80 { if b != 0x20 && b != 0x09 && b != 0x0D && b != 0x0B && b != 0x0C { blank = false } } else { needsUnicodeCheck = true }
                }
                p2 = p1; p1 = b
            }
            if blank && needsUnicodeCheck { blank = String(l).isBlank }
            lastBar.append(last)
            if blank { continue }
            nonBlank += 1
            if last > 30 { counts[last, default: 0] += 1 }
        }
        if nonBlank > 3, let (col, n) = counts.max(by: { $0.value < $1.value }), Double(n) / Double(nonBlank) > 0.5 {
            var out: [String] = []
            out.reserveCapacity(lines.count)
            for (k, l) in lines.enumerated() {
                if lastBar[k] >= col {
                    let u = l.unicodeScalars
                    if let i = u.index(u.startIndex, offsetBy: col, limitedBy: u.endIndex), i < u.endIndex, u[i] == "\u{2502}" {
                        out.append(String(u[..<i]).trimmedEnd)
                        continue
                    }
                }
                out.append(String(l))
            }
            return out.joined(separator: "\n").trimmedEnd
        }
        return screen.trimmedEnd
    }

    /// The numbered options an agent is asking about, such as Claude Code's `❯ 1. Yes / 2. No, and tell Claude what to do
    /// differently`: the first of each digit within the last 14 lines; a real menu counts up from 1 and has 2+ options (max 4).
    /// A form of questions (`questionFormIn`) is not a menu.
    ///
    /// Addition to the original rule: the box's side panel (` │ ...`) is cut first (`stripPanel`), so raw screens work.
    public static func choices(in screen: String) -> [MenuChoice] {
        if questionForm(in: screen) { return [] }
        // A pane taller than what the agent drew ends in blank lines.
        let lines = stripPanel(screen).split(separator: "\n", omittingEmptySubsequences: false).suffix(14)
        var out: [MenuChoice] = []
        for l in lines {
            let line = String(l)
            if let m = option.match(line), let key = m[1], let label = m[2], !out.contains(where: { $0.key == key }) {
                out.append(MenuChoice(key: key, label: label.jsTrimmed))
            }
        }
        // A real menu counts up from 1.
        return out.count >= 2 && out[0].key == "1" ? Array(out.prefix(4)) : []
    }

    /// The rows a question's numbered list ends with that are the agent's own, not choices ("4. Type something.",
    /// "5. Chat about this").
    private static let ownRow = Rx(#"^(type something|chat about this|other)\b"#, ignoreCase: true)

    /// What the numbered menu on screen offers, in order and as the agent words it, without a question's own trailing
    /// rows: a plan approval's "Yes, approve plan" / "No, keep planning", a question's "Three tiers" / "One plan". Empty
    /// when the screen shows no menu (a form of questions included). pierd's push engine has the same (`menu.OptionLabels`)
    /// so a notification's buttons and the app agree.
    public static func optionLabels(in screen: String) -> [String] {
        choices(in: screen).map(\.label).filter { !ownRow.test($0) }
    }

    private static let cursorLine = Rx(#"^(\s*)[❯›]\s+(\S.*)$"#)

    /// An unnumbered menu at the foot of the screen: a `❯ option` line with sibling options at the same text column and a
    /// key hint (`Enter to confirm`) below them. Numbered menus are `choices(in:)`; nil for those and for the prompt.
    public static func cursorMenu(in screen: String) -> CursorMenu? {
        let lines = stripPanel(screen).split(separator: "\n", omittingEmptySubsequences: false).suffix(18).map { raw -> String in
            // Dialogs drawn in a box: drop the borders, keep the inner indentation.
            var l = String(raw).trimmedEnd
            if l.hasPrefix("│") || l.hasPrefix("┃") { l.removeFirst() }
            if l.hasSuffix("│") || l.hasSuffix("┃") { l.removeLast(); l = l.trimmedEnd }
            return l
        }
        guard let hint = lines.lastIndex(where: { keyHint.test($0) }),
              let sel = lines[..<hint].lastIndex(where: { cursorLine.test($0) && option.match($0) == nil }),
              let m = cursorLine.match(lines[sel]), let text = m[2] else { return nil }
        let column = lines[sel].count - text.count
        func optionText(_ l: String) -> String? {
            guard !l.isBlank, !cursorLine.test(l) else { return nil }
            let indent = l.count - l.trimmedStart.count
            return indent == column ? l.trimmedStart : nil
        }
        var above: [String] = []
        var i = sel - 1
        while i >= 0, let t = optionText(lines[i]) { above.insert(t, at: 0); i -= 1 }
        var below: [String] = []
        i = sel + 1
        while i < hint, let t = optionText(lines[i]) { below.append(t); i += 1 }
        let options = above + [text.jsTrimmed] + below
        guard options.count >= 2, options.count <= 9 else { return nil }
        return CursorMenu(options: options, selected: above.count)
    }

    private static let formTabs = Rx(#"^\s*←\s+[☐☒]"#)
    private static let formBox = Rx(#"[☐☒]"#)
    private static let formSubmit = Rx(#"✔\s*Submit"#)

    /// The screen's foot shows Claude Code's form of questions with steps (its tab row `←  ☐ Colour  ☐ Toppings  ✔ Submit →`).
    /// One question with one pick shows a single `☐ Drink` and answers by number.
    public static func questionForm(in screen: String) -> Bool {
        stripPanel(screen).split(separator: "\n", omittingEmptySubsequences: false).suffix(40).contains { l in
            let s = String(l)
            return formTabs.test(s) || (formBox.test(s) && formSubmit.test(s))
        }
    }

    // What an agent's screen shows at its foot.
    private static let promptRule = Rx(#"^\s*[─━]{8,}\s*$"#)
    private static let keyHint = Rx(
        #"(esc to (cancel|close|go back|exit|clear|dismiss)|enter to (confirm|select|continue|change|set|submit|save|toggle)|press enter|space to (select|toggle)|↑\/↓|←\/→|to navigate|to switch|type to (filter|search))"#,
        ignoreCase: true)
    private static let codexPrompt = Rx(#"^›(\s|$)"#)
    private static let claudePrompt = Rx(#"^\s*[❯>!#](\s|$)"#)

    /// Its own prompt (`prompt`); a screen of its own that only keys can answer, such as /model's picker or a trust dialog
    /// (`interactive`); or neither for sure (`unknown`). Claude Code draws its prompt between two rules; Codex a `›` line
    /// over its footer. Caveat inherited from the original: a Codex menu whose selected row is drawn `› 1. ...` and whose footer
    /// has no key hint reads as `prompt`, so check `choices(in:)` before trusting `prompt`.
    public static func screenAt(agent: String?, _ screen: String) -> ScreenKind {
        let lines = stripPanel(screen).split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmedEnd }
        let tail = Array(lines.suffix(16))
        let hinted = tail.filter { !$0.isBlank }.suffix(4).contains { keyHint.test($0) }
        var prompt = false
        if agent == "codex" {
            // The input line sits within the last few lines, over the footer.
            let last = tail.filter { !$0.isBlank }.suffix(4)
            prompt = last.contains { codexPrompt.test($0) } && !hinted
        } else if tail.count >= 3 {
            var i = 1
            while i < tail.count - 1 && !prompt {
                defer { i += 1 }
                guard claudePrompt.test(tail[i]), promptRule.test(tail[i - 1]) else { continue }
                prompt = tail[(i + 1)..<min(tail.count, i + 10)].contains { promptRule.test($0) }
            }
        }
        if prompt { return .prompt }
        if hinted || !choices(in: screen).isEmpty { return .interactive }
        return .unknown
    }

    /// The foot is a screen of the agent's own that only keys answer (a trust dialog, a picker): key hints and no numbered
    /// options. No word or Yes answers it.
    public static func keysOnly(_ screen: String) -> Bool {
        choices(in: screen).isEmpty && !questionForm(in: screen) && screenAt(agent: nil, screen) == .interactive
    }

    // MARK: permission mapping

    private static let alwaysRx = Rx(#"don.t ask again|always|allow all|this session"#, ignoreCase: true)
    /// Claude's extra permission options: "Yes, allow reading from … this project", "Yes, and switch to auto mode".
    private static let extraRx = Rx(#"^yes,?\s+(and\s+)?(allow\s+\w+\s+from|switch to|allow\b.*\b(project|directory|folder)\b)|this project\b"#, ignoreCase: true)
    private static let allowRx = Rx(#"^(yes|allow|approve|proceed)\b"#, ignoreCase: true)
    private static let denyRx = Rx(#"^(no|deny|reject)\b"#, ignoreCase: true)

    /// Match a menu's options to Allow / Always allow (when offered, e.g. "Yes, and don't ask again for ls commands") / Deny.
    /// Keys stay the option's own number. `nil` unless both Allow and Deny are found (then show the screen and a key bar).
    public static func permissionChoices(_ choices: [MenuChoice]) -> [PermissionChoice]? {
        let (allow, always, deny) = permissionActions(choices)
        guard let allow, let deny else { return nil }
        return [PermissionChoice(key: allow.key, label: "Allow", title: allow.label)]
            + (always.map { [PermissionChoice(key: $0.key, label: "Always allow", title: $0.label)] } ?? [])
            + [PermissionChoice(key: deny.key, label: "Deny", title: deny.label)]
    }

    /// The raw classification behind `permissionChoices`.
    public static func permissionActions(_ c: [MenuChoice]) -> (allow: MenuChoice?, always: MenuChoice?, deny: MenuChoice?) {
        // "Don't ask again" wins; Claude's other Yes-extras stand in for it when it is not offered. An option worded as a
        // refusal ("No, and don't ask again") is never "Always allow", whatever else its label says.
        let always = c.first { alwaysRx.test($0.label) && !denyRx.test($0.label) } ?? c.first { extraRx.test($0.label) && !denyRx.test($0.label) }
        let allow = c.first { $0 != always && !alwaysRx.test($0.label) && !extraRx.test($0.label) && allowRx.test($0.label) }
        let deny = c.first { denyRx.test($0.label) }
        return (allow, always, deny)
    }

    /// Buttons for a screen: parse + classify in one step (`nil` when no Allow/Deny pair is parsable).
    public static func actions(in screen: String) -> [PermissionAction]? {
        guard let p = permissionChoices(choices(in: screen)) else { return nil }
        return p.map { c in
            switch c.label {
            case "Allow": .allow(key: c.key)
            case "Always allow": .alwaysAllow(key: c.key)
            default: .deny(key: c.key)
            }
        }
    }

    // MARK: last message (review summaries)

    private static let bullet = Rx(#"^\s*●\s"#)
    private static let brewed = Rx(#"^\s*[✻✽✳✶*]\s+\S+ for \d.*·"#)
    private static let selected = Rx(#"^[❯›>]"#)

    /// What the agent said last: Claude Code starts each message with `●`, so it is the text from the last `●` to the input
    /// box. Other agents get the last few meaningful lines. Continuation lines lose the terminal's indent.
    public static func lastMessage(_ screen: String) -> [String] {
        let lines = meaningfulTail(screen, 60)
        var start = -1
        for i in stride(from: lines.count - 1, through: 0, by: -1) where bullet.test(lines[i]) {
            start = i
            break
        }
        let msg = (start >= 0 ? Array(lines[start...]) : Array(lines.suffix(8))).filter { !brewed.test($0) }
        guard !msg.isEmpty else { return [] }
        let first = Rx(#"^\s*●\s*"#).replacing(msg[0], with: "")
        let rest = Array(msg.dropFirst())
        // A selected option ("❯ 1. Yes") sits left of the text; it sets no indent.
        let indents = rest.filter { !$0.isBlank && !selected.test($0) }.map { $0.count - $0.trimmedStart.count }
        let indent = indents.min()
        func dedent(_ l: String) -> String {
            guard let indent, String(l.prefix(indent)).isBlank else { return l }
            return String(l.dropFirst(indent))
        }
        return ([first] + rest.map(dedent)).map { $0.trimmedEnd }
    }
}

// MARK: spec-named free functions (docs/API.md §13.4)

/// 5.3: numbered menu from `screen` (side panel cut), last 14 lines.
public func parseMenu(_ screen: String) -> [MenuChoice] { MenuParser.choices(in: screen) }

/// 5.3: Allow / Always allow / Deny from a parsed menu.
public func permissionActions(_ c: [MenuChoice]) -> (allow: MenuChoice?, always: MenuChoice?, deny: MenuChoice?) {
    MenuParser.permissionActions(c)
}
