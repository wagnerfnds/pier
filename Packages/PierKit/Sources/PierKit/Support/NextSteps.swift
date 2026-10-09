import Foundation

/// Suggested next steps for a finished turn: up to two short replies the person would likely send next ("Abra o PR",
/// "Rode os testes de novo"), written by a small model on the box (`claude -p --model haiku` through `exec` in the session's
/// worktree, like `AIDraft`) from the agent's last reply. They are only ever sent when the person picks one.
public enum NextSteps {
    /// At most this many suggestions.
    public static let maxReplies = 2
    /// A suggestion longer than this is dropped (it would not fit a chip, and cutting it would change what it says).
    public static let maxLength = 60
    /// The reply is capped before it goes into the prompt.
    public static let maxInput = 6000
    /// Marks the command (logs, mocks).
    public static let marker = "# pier-next-steps"

    /// One suggestion set per finished turn: box, session and the moment the turn ended (`state_since`).
    public struct Key: Hashable, Sendable, Codable {
        public let box: String
        public let session: String
        public let since: Date
        public init(box: String, session: String, since: Date) { self.box = box; self.session = session; self.since = since }
        public var id: String { "\(box)/\(session)@\(Int(since.timeIntervalSince1970 * 1000))" }
    }

    static let instructions = """
    You suggest what a developer would most likely reply next to their coding agent, which just finished a turn.
    Below is the agent's last message. Write at most two short replies the developer could send as-is to keep the work going
    (for example: open the PR, run the tests again, commit, fix what the agent says is left, answer the agent's question).
    Rules:
    - Write in the same language as the agent's message (Portuguese stays Portuguese, English stays English).
    - Each reply at most 60 characters, imperative, addressed to the agent, no quotes, no emoji, no trailing period.
    - Only replies that make sense for this message; if the agent asked a direct question, the first reply answers it.
    - If nothing sensible comes to mind, return an empty list.
    Answer with strict JSON only, nothing before or after it: {"replies":["...","..."]}
    """

    /// The prompt sent to the model (instructions + the reply, capped; `task` is context only).
    public static func prompt(reply: String, task: String?) -> String {
        var p = instructions
        if let t = task?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            p += "\n\nThe task the agent was given (context only):\n\(String(t.prefix(800)))"
        }
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        p += "\n\nThe agent's last message:\n<<<\n\(r.count > maxInput ? String(r.suffix(maxInput)) : r)\n>>>"
        return p
    }

    /// Shell for `exec` in the session's worktree. The prompt never touches the shell (base64), and the CLI is looked up
    /// like `AIDraft` does (exit `AIDraft.noCLIExit` when it is missing).
    public static func command(reply: String, task: String?) -> String {
        """
        CL=$(command -v claude 2>/dev/null); \
        for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /usr/local/bin/claude /opt/homebrew/bin/claude "$HOME/.npm-global/bin/claude"; do \
        [ -z "$CL" ] && [ -x "$c" ] && CL="$c"; done; \
        [ -z "$CL" ] && { echo "claude CLI not found on the box" >&2; exit \(AIDraft.noCLIExit); }; \
        printf %s '\(GitActions.b64(prompt(reply: reply, task: task)))' | base64 -d | PIER_HOOKS_QUIET=1 "$CL" -p --model haiku 2>&1 \(marker)
        """
    }

    /// The suggestions in the model's answer: the JSON object (bare, fenced or with words around it), trimmed, deduplicated,
    /// at most `maxReplies`, each at most `maxLength` characters. nil when the answer holds no such JSON (a failure, not "no
    /// suggestions").
    public static func parse(_ output: String) -> [String]? {
        guard let replies = decode(output) else { return nil }
        var seen = Set<String>()
        var out: [String] = []
        for raw in replies {
            var r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            r = r.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'`"))
            while r.hasSuffix(".") && !r.hasSuffix("..") { r.removeLast() }
            r = r.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !r.isEmpty, r.count <= maxLength, seen.insert(r.lowercased()).inserted else { continue }
            out.append(r)
            if out.count == maxReplies { break }
        }
        return out
    }

    private struct Answer: Decodable { let replies: [String] }

    /// Tries every `{` from the first, against the last `}`s, so prose or a code fence around the object does not matter.
    private static func decode(_ output: String) -> [String]? {
        let chars = Array(output)
        let opens = chars.indices.filter { chars[$0] == "{" }
        let closes = chars.indices.filter { chars[$0] == "}" }.reversed()
        for o in opens {
            for c in closes where c > o {
                let s = String(chars[o...c])
                guard s.contains("replies") else { continue }
                if let a = try? JSONDecoder().decode(Answer.self, from: Data(s.utf8)) { return a.replies }
            }
        }
        return nil
    }
}
