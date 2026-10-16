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

    /// "Bash  rm -rf build": what to show next to Allow / Deny. A question is its words alone ("Which colour?"): the
    /// tool's name means nothing to the person answering it.
    public var summary: String {
        if tool == "AskUserQuestion" || tool == "request_user_input", let input, !input.isEmpty { return input }
        return [tool, input].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
    }

    /// The open question as a transcript item, from the form the hook sent (`questions`): Claude Code records the call
    /// only once it is answered, so while it waits this is the form. Answered through `POST .../answer` with the tool's
    /// own name (`AskUserQuestion`), which the box matches to the wait's form.
    public var questionItem: TranscriptItem? {
        guard tool == "AskUserQuestion", let qs = questions, !qs.isEmpty, qs.allSatisfy({ !$0.options.isEmpty }) else { return nil }
        return TranscriptItem(kind: "question", id: "ask-question", tool: "AskUserQuestion", questions: qs)
    }

    /// The one line a glance shows (Live Activity, widgets): `summary`, with the agent's message or reason when the
    /// hook gave no input. nil when there is nothing to say.
    public var glance: String? {
        if tool == "AskUserQuestion" || tool == "request_user_input", let input, !input.isEmpty { return input }
        let t = [tool, input ?? message ?? why].compactMap { $0 }.joined(separator: "  ")
        return t.isEmpty ? nil : t
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

/// A question form answered one question at a time, where there is no form to show, only rows picked by number (the
/// Inbox's cards, the Mac panel): a single choice answers its question and moves on; a multiple choice ticks rows and
/// moves on with `next()`. Complete, `answers` is what `POST .../answer` takes, one entry per question, in order.
public struct QuestionSteps: Sendable, Hashable {
    public let questions: [Question]
    public private(set) var answers: [QuestionAnswer] = []
    /// The current multiple choice's ticked labels, in the order of its options.
    public private(set) var ticked: [String] = []

    public init(questions: [Question]) { self.questions = questions }

    /// Needs stepping: more than one question, or a multiple choice (one single choice is answered by its row alone).
    public static func needed(for questions: [Question]) -> Bool {
        questions.count > 1 || questions.contains { $0.multi == true }
    }

    public var index: Int { answers.count }
    public var current: Question? { questions.indices.contains(index) ? questions[index] : nil }
    public var isComplete: Bool { !questions.isEmpty && answers.count == questions.count }
    public var isLast: Bool { index == questions.count - 1 }

    /// A row of the current question: answers a single choice (and moves on), ticks or unticks a multiple choice's.
    /// False when the label is not one of its options.
    @discardableResult
    public mutating func choose(_ label: String) -> Bool {
        guard let q = current, q.options.contains(where: { $0.label == label }) else { return false }
        if q.multi == true {
            let set = ticked.contains(label) ? Set(ticked).subtracting([label]) : Set(ticked).union([label])
            ticked = q.options.map(\.label).filter(set.contains)
        } else {
            answers.append(.pick(label))
        }
        return true
    }

    /// A multiple choice's ticks are its answer; moves on. False with nothing ticked (or not at a multiple choice).
    @discardableResult
    public mutating func next() -> Bool {
        guard current?.multi == true, !ticked.isEmpty else { return false }
        answers.append(.picks(ticked))
        ticked = []
        return true
    }

    /// Takes back the last answer (an undone send): its question is current again, a multiple choice with its ticks.
    public mutating func back() {
        guard let last = answers.popLast() else { return }
        ticked = questions[answers.count].multi == true ? (last.picks ?? []) : []
    }
}
