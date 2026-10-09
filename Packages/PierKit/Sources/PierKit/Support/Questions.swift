import Foundation

/// What a waiting agent wants from the person (docs/API.md §5.3 / §5.4).
public enum NeedsYouKind: Sendable, Hashable {
    /// A permission menu: read the screen, answer with the option's digit (`MenuParser`).
    case permission
    /// A question: `AskUserQuestion` / `request_user_input` (structured, see the transcript's `question` item) or `ExitPlanMode`.
    case question
}

extension Ask {
    private static let questionTools = Rx(#"^(AskUserQuestion|request_user_input|ExitPlanMode)$"#)

    /// Rule: no tool, or a question tool => question; anything else is a permission.
    public static func classify(_ ask: Ask?) -> NeedsYouKind {
        guard let tool = ask?.tool, !tool.isEmpty else { return .question }
        return questionTools.test(tool) ? .question : .permission
    }

    /// `ExitPlanMode`: a plain numbered menu on screen (parse like a permission); the plan is the preceding `text` item.
    public var isPlanApproval: Bool { tool == "ExitPlanMode" }

    /// "Bash  rm -rf build": what to show next to Allow / Deny.
    public var summary: String {
        [tool, input].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
    }
}

extension Session {
    /// `nil` unless the agent is waiting.
    public var needsYouKind: NeedsYouKind? { needsYou ? Ask.classify(ask) : nil }

    /// `POST .../answer` exists for Claude Code only (and for `AskUserQuestion`); otherwise answer with keys after reading the screen.
    public var canUseAnswerEndpoint: Bool { agent == "claude" && ask?.tool == "AskUserQuestion" }
}

extension QuestionAnswer {
    public static func pick(_ label: String) -> QuestionAnswer { QuestionAnswer(picks: [label], other: nil) }
    public static func picks(_ labels: [String]) -> QuestionAnswer { QuestionAnswer(picks: labels, other: nil) }
    /// The person's own words (a single line).
    public static func other(_ text: String) -> QuestionAnswer { QuestionAnswer(picks: nil, other: text) }
}

public enum QuestionHelpers {
    public enum Problem: Error, Sendable, Equatable, CustomStringConvertible {
        case countMismatch(expected: Int, got: Int)
        case empty(question: Int)
        case tooManyPicks(question: Int)
        case unknownOption(question: Int, label: String)
        case otherNotSingleLine(question: Int)

        public var description: String {
            switch self {
            case .countMismatch(let e, let g): "expected \(e) answers, got \(g)"
            case .empty(let q): "question \(q + 1) has no answer"
            case .tooManyPicks(let q): "question \(q + 1) takes one choice"
            case .unknownOption(let q, let l): "question \(q + 1) has no option \"\(l)\""
            case .otherNotSingleLine(let q): "question \(q + 1): free text must be a single line"
            }
        }
    }

    /// Check answers before `POST .../answer`: one entry per question, in order; `picks` are option labels
    /// (exactly one unless `multi`); `other` is a single line counted as an additional pick.
    public static func validate(_ answers: [QuestionAnswer], for questions: [Question]) -> Problem? {
        if answers.count != questions.count { return .countMismatch(expected: questions.count, got: answers.count) }
        for (i, (q, a)) in zip(questions, answers).enumerated() {
            let picks = a.picks ?? []
            let other = a.other?.jsTrimmed ?? ""
            if picks.isEmpty && other.isEmpty { return .empty(question: i) }
            if let o = a.other, o.contains("\n") { return .otherNotSingleLine(question: i) }
            if q.multi != true, picks.count + (other.isEmpty ? 0 : 1) > 1 { return .tooManyPicks(question: i) }
            for p in picks where !q.options.contains(where: { $0.label == p }) { return .unknownOption(question: i, label: p) }
        }
        return nil
    }

    /// The text the box reports back for one answer (`answered[i]`): picks and other joined with ", ".
    public static func summary(_ a: QuestionAnswer) -> String {
        ((a.picks ?? []) + [a.other].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: ", ")
    }

    /// Fallback when `POST .../answer` answers 409 ("finish in Claude's screen") or the agent is Codex: the digit of the
    /// option as the agent numbers it on screen (options are listed 1..n, followed by "Type something" / "Chat about this").
    public static func menuKey(forPick label: String, in question: Question) -> String? {
        guard let i = question.options.firstIndex(where: { $0.label == label }), i < 9 else { return nil }
        return String(i + 1)
    }

    /// The open `question` item of a transcript, if any.
    public static func openQuestion(in items: [TranscriptItem]) -> TranscriptItem? {
        items.last(where: { $0.kind == "question" && $0.done != true && $0.answers == nil })
    }
}
