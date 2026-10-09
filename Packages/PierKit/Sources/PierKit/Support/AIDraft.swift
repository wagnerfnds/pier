import Foundation

/// Commit message and PR title/description written by a small model on the box (`claude -p --model haiku`, through
/// `exec` in the worktree): it reads the real diff, uses the subscription already on the box and needs no key on the phone.
public enum AIDraft {
    public struct Draft: Equatable, Sendable {
        public var commit: String
        public var title: String
        public var body: String
    }

    /// Exit code when no `claude` CLI is found on the box.
    public static let noCLIExit: Int32 = 3

    static let instructions = """
    You write git commit messages and pull request text for the change below.
    Read the diff and describe what the change does and why, concretely; do not repeat the task request verbatim.
    Use the same language and style as the repository's recent commit messages (English if unclear).
    Commit: a subject line of at most 72 characters in the imperative mood, a blank line, then a short body (wrapped bullet points are fine).
    PR title: at most 72 characters. PR body: Markdown with a "## Summary" section of 2-6 bullets, and a "## Notes" section only if there is something a reviewer must know (risks, migrations, follow-ups).
    Answer with exactly these three blocks and nothing else:
    <<<COMMIT
    ...
    >>>
    <<<TITLE
    ...
    >>>
    <<<BODY
    ...
    >>>
    """

    /// Shell for `exec` in the worktree. `base` is the PR base branch without `origin/`; `task` the session's request (context only).
    /// The diff covers everything since the merge base with the base branch (commits + uncommitted), capped in size.
    public static func command(base: String, task: String?) -> String {
        var prompt = instructions
        if let t = task?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            prompt += "\n\nThe task the agent was given (context only):\n\(String(t.prefix(1500)))"
        }
        let b = GitActions.q(base)
        return """
        CL=$(command -v claude 2>/dev/null); \
        for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /usr/local/bin/claude /opt/homebrew/bin/claude "$HOME/.npm-global/bin/claude"; do \
        [ -z "$CL" ] && [ -x "$c" ] && CL="$c"; done; \
        [ -z "$CL" ] && { echo "claude CLI not found on the box" >&2; exit \(noCLIExit); }; \
        MB=$(git merge-base HEAD origin/\(b) 2>/dev/null || git merge-base HEAD \(b) 2>/dev/null || echo HEAD); \
        { printf %s '\(GitActions.b64(prompt))' | base64 -d; \
        printf '\\n\\n## Recent commits on the base\\n'; git log -8 --pretty='- %s' "$MB" 2>/dev/null; \
        printf '\\n## Commits on this branch\\n'; git log --pretty='- %s' "$MB"..HEAD 2>/dev/null | head -40; \
        printf '\\n## New files\\n'; git ls-files --others --exclude-standard | head -40; \
        printf '\\n## Diff stat\\n'; git diff "$MB" --stat 2>/dev/null | tail -60; \
        printf '\\n## Diff\\n'; git diff "$MB" 2>/dev/null | head -c 60000; } \
        | PIER_HOOKS_QUIET=1 "$CL" -p --model haiku 2>&1
        """
    }

    /// The three blocks from the model's answer; nil when the answer has no usable title and commit.
    public static func parse(_ output: String) -> Draft? {
        func block(_ name: String) -> String? {
            guard let start = output.range(of: "<<<\(name)") else { return nil }
            let rest = output[start.upperBound...]
            let end = rest.range(of: ">>>")?.lowerBound ?? rest.endIndex
            let v = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        let commit = block("COMMIT"), title = block("TITLE")
        guard let c = commit ?? title, let t = title ?? c.split(separator: "\n").first.map(String.init) else { return nil }
        let oneLine = t.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? t
        return Draft(commit: c, title: oneLine, body: block("BODY") ?? "")
    }
}
