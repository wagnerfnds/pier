import Foundation
import PierKit

/// A short "what is the agent doing" line read from the tail of its screen (cheap: one `GET .../screen`), in the app's
/// language (the keys are the Portuguese lines, translated in the string catalog).
enum StepText {
    /// The line for an agent that is thinking (no call on screen), so views can tell it apart.
    static var thinking: String { String(localized: "Pensando…") }

    static func from(screen: String) -> String? {
        let lines = MenuParser.meaningfulTail(screen, 40)
        var thinking = false
        // Claude draws the call ("● Bash(sleep 8)"), then its result ("⎿ one") once it finished; while it runs, the spinner
        // line sits under a call with no result yet. So: a result seen before (below) a call means the call is done.
        var resultBelow = false
        for l in lines.reversed() {
            let t = l.trimmingCharacters(in: .whitespaces)
            // Claude Code: "● Bash(pnpm test)" / "● Update(calc.py)"
            if t.hasPrefix("●"), let call = parseCall(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)) {
                return resultBelow ? (thinking ? Self.thinking : nil) : call
            }
            if t.hasPrefix("⎿") || t.hasPrefix("└") || t.hasPrefix("⎾") {
                if !t.lowercased().contains("running") { resultBelow = true }
                continue
            }
            // Codex: "• Ran pnpm test", "• Edited calc.py", "• Explored"
            if t.hasPrefix("•") {
                let body = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let s = codexLine(body) { return s }
            }
            // Spinner line: "✻ Stewing… (5s …)"
            if let f = t.first, "✻✽✳✶*·".contains(f), t.contains("…") { thinking = true; continue }
            if t.hasPrefix("●") { resultBelow = true }   // the agent's own words: whatever ran before is done
        }
        return thinking ? Self.thinking : nil
    }

    private static func parseCall(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") || s.contains(")") else { return nil }
        let tool = String(s[..<open])
        guard !tool.isEmpty, tool.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == ":" }) else { return nil }
        var arg = String(s[s.index(after: open)...])
        if let close = arg.lastIndex(of: ")") { arg = String(arg[..<close]) }
        arg = arg.trimmingCharacters(in: .whitespaces)
        let name = short(arg.split(separator: "/").last.map(String.init) ?? arg)
        switch tool {
        case "Bash": return String(localized: "Rodando \(short(arg))…")
        case "Read": return String(localized: "Lendo \(name)…")
        case "Edit", "Update", "Write", "MultiEdit", "NotebookEdit": return String(localized: "Editando \(name)…")
        case "Grep", "Glob", "Search": return String(localized: "Buscando \(short(arg))…")
        case "WebFetch", "WebSearch": return String(localized: "Pesquisando na web…")
        case "Task", "Agent": return String(localized: "Delegando a um subagente…")
        case "TodoWrite": return String(localized: "Atualizando a lista de tarefas…")
        default: return String(localized: "Usando \(tool)…")
        }
    }

    private static func codexLine(_ s: String) -> String? {
        let lower = s.lowercased()
        func line(_ prefix: String, _ bare: String, _ with: (String) -> String) -> String? {
            guard lower.hasPrefix(prefix) else { return nil }
            let rest = short(String(s.dropFirst(prefix.count)))
            return rest.isEmpty ? bare : with(rest)
        }
        return line("ran ", String(localized: "Rodando…")) { String(localized: "Rodando \($0)…") }
            ?? line("running ", String(localized: "Rodando…")) { String(localized: "Rodando \($0)…") }
            ?? line("edited ", String(localized: "Editando…")) { String(localized: "Editando \($0)…") }
            ?? line("editing ", String(localized: "Editando…")) { String(localized: "Editando \($0)…") }
            ?? line("read ", String(localized: "Lendo…")) { String(localized: "Lendo \($0)…") }
            ?? line("explored", String(localized: "Explorando…")) { String(localized: "Explorando \($0)…") }
            ?? line("searched ", String(localized: "Buscando…")) { String(localized: "Buscando \($0)…") }
    }

    /// At most `n` characters, no ellipsis of its own: every line above ends in "…" already.
    private static func short(_ s: String, _ n: Int = 38) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n - 1)).trimmingCharacters(in: .whitespaces) : one
    }
}
