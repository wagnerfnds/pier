import Foundation
import PierKit

/// A short "what is the agent doing" line read from the tail of its screen (cheap: one `GET .../screen`).
enum StepText {
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
                return resultBelow ? (thinking ? "Pensando…" : nil) : call
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
        return thinking ? "Pensando…" : nil
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
        case "Bash": return "Rodando \(short(arg))…"
        case "Read": return "Lendo \(name)…"
        case "Edit", "Update", "Write", "MultiEdit", "NotebookEdit": return "Editando \(name)…"
        case "Grep", "Glob", "Search": return "Buscando \(short(arg))…"
        case "WebFetch", "WebSearch": return "Pesquisando na web…"
        case "Task", "Agent": return "Delegando a um subagente…"
        case "TodoWrite": return "Atualizando a lista de tarefas…"
        default: return "Usando \(tool)…"
        }
    }

    private static func codexLine(_ s: String) -> String? {
        let lower = s.lowercased()
        for (prefix, verb) in [("ran ", "Rodando"), ("running ", "Rodando"), ("edited ", "Editando"), ("editing ", "Editando"),
                               ("read ", "Lendo"), ("explored", "Explorando"), ("searched ", "Buscando")] where lower.hasPrefix(prefix) {
            let rest = short(String(s.dropFirst(prefix.count)))
            return rest.isEmpty ? "\(verb)…" : "\(verb) \(rest)…"
        }
        return nil
    }

    private static func short(_ s: String, _ n: Int = 38) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }
}
