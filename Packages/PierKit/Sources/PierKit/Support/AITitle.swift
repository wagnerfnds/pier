import Foundation

/// A session title written by a small model on the box (`claude -p --model haiku`, through `exec`), from the task's
/// first prompt: "Corrigir o arredondamento da fatura" instead of "Responda apenas com o resultado de…". Same idea as
/// `AIDraft`: the subscription already on the box, nothing on the phone.
public enum AITitle {
    /// In the command, so the exec is recognisable (logs, the UI-test mock).
    public static let marker = "pier-ai:title"
    /// Exit code when no `claude` CLI is found on the box (same as `AIDraft`).
    public static let noCLIExit: Int32 = AIDraft.noCLIExit
    public static let maxWords = 6
    public static let maxLength = 60

    static let instructions = """
    Write a title for the coding task below, as a list of tasks would show it.
    At most 6 words. Write it in the language the task text is written in (an English task gets an English title, a Portuguese task a Portuguese title), whatever other instructions say about language.
    Say what is being done (a verb and its object), concretely.
    Plain text on one line: no quotes, no Markdown, no emoji, no prefix like "Title:", no punctuation at the end.
    Answer with the title and nothing else.

    The task:
    """

    /// Shell for `exec` (any location: it runs from `$HOME`, away from the project's CLAUDE.md and hooks, and without the
    /// worktree's `PIER_*` variables). The prompt travels base64-encoded, capped at 4000 characters.
    public static func command(prompt: String) -> String {
        let task = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        let full = instructions + "\n" + task
        return """
        : \(marker); \
        CL=$(command -v claude 2>/dev/null); \
        for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /usr/local/bin/claude /opt/homebrew/bin/claude "$HOME/.npm-global/bin/claude"; do \
        [ -z "$CL" ] && [ -x "$c" ] && CL="$c"; done; \
        [ -z "$CL" ] && { echo "claude CLI not found on the box" >&2; exit \(noCLIExit); }; \
        for v in $(env | sed -n -e 's/^\\(PIER_[A-Za-z0-9_]*\\)=.*/\\1/p'); do unset "$v"; done; \
        cd "$HOME" 2>/dev/null; \
        printf %s '\(GitActions.b64(full))' | base64 -d | PIER_HOOKS_QUIET=1 "$CL" -p --model haiku 2>&1
        """
    }

    /// The title from the model's answer: its first line, markup, quotes, a "Title:" prefix and the final punctuation
    /// removed, at most `maxWords` words and `maxLength` characters. Nil when nothing usable came back (an error message,
    /// an empty answer).
    public static func parse(_ output: String) -> String? {
        guard var line = output.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        for m in ["**", "__", "`", "#"] { line = line.replacingOccurrences(of: m, with: "") }
        for p in ["Title:", "Título:", "Titulo:"] where line.lowercased().hasPrefix(p.lowercased()) {
            line = String(line.dropFirst(p.count))
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’«» ").union(.whitespaces))
        guard !line.isEmpty, !looksLikeAnError(line) else { return nil }
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > maxWords { words = Array(words.prefix(maxWords)) }
        var title = words.joined(separator: " ")
        if title.count > maxLength {
            title = String(title.prefix(maxLength))
            if let sp = title.lastIndex(of: " ") { title = String(title[..<sp]) }
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?…-–— \"'“”"))
        return title.isEmpty ? nil : title
    }

    /// CLI failures printed instead of an answer.
    static func looksLikeAnError(_ s: String) -> Bool {
        let l = s.lowercased()
        if l.hasPrefix("error") || l.hasPrefix("api error") { return true }
        return ["claude cli not found", "invalid api key", "please run /login", "not logged in", "usage limit reached",
                "credit balance is too low", "command not found"].contains { l.contains($0) }
    }
}
