import Foundation

/// A row of a conversation view: one item, or a fold of the agent's steps between two of its messages.
public enum ConversationBlock: Sendable, Equatable, Identifiable {
    case item(TranscriptItem)
    case fold(id: String, steps: [TranscriptItem], live: Bool)

    public var id: String {
        switch self {
        case .item(let it): it.id
        case .fold(let id, _, _): id
        }
    }
}

public enum ConversationFold {
    /// A turn reads like a chat: what was asked, what the agent changed, and its answer. The steps in between (its
    /// narration and tool calls) fold into one line, opened on demand. While it works (`live`), the last turn's fold says
    /// so and its latest words stay in view.
    ///
    /// Rules: a `user`, `command` or `report` item starts a turn and is always shown. Within a turn, `edit`,
    /// `artifact`, `question` and `notice` items are shown; `text` items from the answer onward are shown; everything
    /// else (tools, crew, earlier narration) goes into the fold. The answer is the turn's last `text`, or, when several
    /// texts/edits sit at the end, the longest of them.
    public static func blocks(_ items: [TranscriptItem], live: Bool) -> [ConversationBlock] {
        var out: [ConversationBlock] = []
        var turn: [TranscriptItem] = []
        // A turn's fold is named after what started the turn, so it keeps its identity while the agent works (its first
        // step changes when a promoted answer is demoted back into the fold; a new id would recreate the row).
        var anchor = "start"
        func flush(isLast: Bool) {
            guard !turn.isEmpty else { return }
            let working = isLast && live
            var answer = -1
            for i in stride(from: turn.count - 1, through: 0, by: -1) where turn[i].type == .text {
                answer = i
                func len(_ j: Int) -> Int { turn[j].type == .text ? (turn[j].text?.count ?? 0) : 0 }
                var j = i - 1
                while j >= 0, turn[j].type == .text || turn[j].type == .edit {
                    if len(j) > len(answer) { answer = j }
                    j -= 1
                }
                break
            }
            var steps: [TranscriptItem] = []
            var shown: [TranscriptItem] = []
            for (i, it) in turn.enumerated() {
                let keep = (answer >= 0 && i >= answer && it.type == .text)
                    || [.edit, .artifact, .question, .notice].contains(it.type)
                if keep { shown.append(it) } else { steps.append(it) }
            }
            if !steps.isEmpty { out.append(.fold(id: "fold-after-\(anchor)", steps: steps, live: working)) }
            for it in shown { out.append(.item(it)) }
            turn = []
        }
        for it in items {
            if it.type == .user || it.type == .command || it.type == .report {
                flush(isLast: false)
                out.append(.item(it))
                anchor = it.id
            } else {
                turn.append(it)
            }
        }
        flush(isLast: true)
        return out
    }

    /// What a folded stretch of work did, counted: commands run, files read, searches, helpers, other tools, and the
    /// agent's intermediate notes.
    public struct Work: Sendable, Equatable {
        public var run = 0, read = 0, search = 0, other = 0, helpers = 0, notes = 0
        public init() {}
        public var isEmpty: Bool { run + read + search + other + helpers + notes == 0 }
    }

    public static func work(in steps: [TranscriptItem]) -> Work {
        var w = Work()
        for s in steps {
            switch s.type {
            case .tools:
                let n = s.items?.count ?? 0
                switch (s.verb ?? "").lowercased() {
                case "run", "bash", "shell", "exec": w.run += n
                case "read": w.read += n
                case "search", "grep", "glob", "find": w.search += n
                default: w.other += n
                }
            case .crew: w.helpers += s.names?.count ?? 1
            case .text: w.notes += 1
            default: break
            }
        }
        return w
    }
}
