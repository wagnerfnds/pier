import Foundation
import PierKit

/// Builds a single-question form from the agent's screen when the transcript has no `question` item yet
/// (Claude only writes it after the answer). Handles one question with numbered options; forms with steps return nil.
enum ScreenQuestion {
    private static let option = try! NSRegularExpression(pattern: #"^\s*(?:[❯›>]\s*)?(\d)[.)]\s+(\S.*)$"#)
    private static let skip = ["type something", "chat about this", "other"]

    static func make(screen: String, ask: Ask?) -> TranscriptItem? {
        guard ask?.tool == "AskUserQuestion" || ask?.tool == "request_user_input", !MenuParser.questionForm(in: screen) else { return nil }
        let screen = MenuParser.stripPanel(screen)
        var opts: [(String, String)] = []   // label, description
        var desc: [String] = []
        var inList = false
        for raw in screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).suffix(40) {
            let line = String(raw.reversed().drop(while: \.isWhitespace).reversed())
            let r = NSRange(line.startIndex..., in: line)
            if let m = option.firstMatch(in: line, range: r), let kr = Range(m.range(at: 1), in: line), let lr = Range(m.range(at: 2), in: line) {
                if Int(line[kr]) == opts.count + 1 {
                    if !desc.isEmpty, !opts.isEmpty { opts[opts.count - 1].1 = desc.joined(separator: " ") }
                    desc = []
                    opts.append((String(line[lr]).trimmingCharacters(in: .whitespaces), ""))
                    inList = true
                    continue
                }
            }
            if inList {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.allSatisfy({ "─━-".contains($0) }) || t.lowercased().hasPrefix("enter to") { continue }
                if raw.hasPrefix("   ") { desc.append(t) }
            }
        }
        if !desc.isEmpty, !opts.isEmpty { opts[opts.count - 1].1 = desc.joined(separator: " ") }
        let real = opts.filter { o in !skip.contains { o.0.lowercased().hasPrefix($0) } }
        guard real.count >= 2, let q = ask?.input, !q.isEmpty else { return nil }
        let question = Question(question: q, options: real.map { QuestionOption(label: $0.0, description: $0.1.isEmpty ? nil : $0.1) })
        return TranscriptItem(kind: "question", id: "screen-question", tool: ask?.tool ?? "AskUserQuestion", questions: [question])
    }
}
