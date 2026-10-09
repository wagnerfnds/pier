import Foundation

/// "Falar": a request in plain words goes to the right agent, or starts a new one. A small model on a box
/// (`claude -p --model haiku`, through `exec`, like `AIDraft`) reads the request plus a compact list of the person's live
/// sessions and projects and answers one JSON object; `parse` validates it against that same list, so the app never acts
/// on a session or project that does not exist. Nothing here sends anything: the app shows the decision and waits for the
/// person to confirm.
///
/// Contract (one object, nothing else):
/// `{"action":"send","box":"…","session":"…","text":"…"}`
/// `{"action":"new_task","box":"…","location":"…","prompt":"…","title":"…"}`
/// `{"action":"ask","question":"…"}`
public enum TalkRouter {
    /// One live agent session as the model sees it.
    public struct SessionInfo: Sendable, Hashable {
        public var box: String
        /// The session's id on the box (`/v1/sessions/{name}`).
        public var name: String
        /// What the person sees: the AI or user title, else the name.
        public var title: String
        /// "project" or "project/worktree" (the session's `location`).
        public var location: String
        /// needs_you | working | your_turn | ready
        public var state: String
        public var agent: String?
        /// First line of the agent's last reply, when known.
        public var lastReply: String?

        public init(box: String, name: String, title: String, location: String, state: String, agent: String? = nil, lastReply: String? = nil) {
            self.box = box; self.name = name; self.title = title; self.location = location
            self.state = state; self.agent = agent; self.lastReply = lastReply
        }
    }

    /// One project (a repo location) a new task can start in.
    public struct ProjectInfo: Sendable, Hashable {
        public var box: String
        /// The location's name on the box (what `POST /v1/tasks` takes).
        public var location: String
        /// The person's name for it, when renamed on the phone.
        public var displayName: String?
        public var worktrees: [String]

        public init(box: String, location: String, displayName: String? = nil, worktrees: [String] = []) {
            self.box = box; self.location = location; self.displayName = displayName; self.worktrees = worktrees
        }
    }

    public struct Context: Sendable, Hashable {
        public var sessions: [SessionInfo]
        public var projects: [ProjectInfo]
        public init(sessions: [SessionInfo], projects: [ProjectInfo]) { self.sessions = sessions; self.projects = projects }

        public func session(box: String, name: String) -> SessionInfo? { sessions.first { $0.box == box && $0.name == name } }
        public func project(box: String, location: String) -> ProjectInfo? { projects.first { $0.box == box && $0.location == location } }
    }

    public enum Decision: Sendable, Hashable {
        case send(box: String, session: String, text: String)
        case newTask(box: String, location: String, prompt: String, title: String?)
        case ask(question: String)
    }

    public enum Failure: Error, Sendable, Hashable {
        /// No JSON object in the answer, or not valid JSON.
        case malformed
        case unknownAction(String)
        /// The session does not exist (or is not live) in the list the model was given.
        case unknownSession(String)
        case unknownProject(String)
        /// The message / prompt / question is empty.
        case empty
    }

    /// Exit code when no `claude` CLI is found on the box (same as `AIDraft`).
    public static let noCLIExit: Int32 = AIDraft.noCLIExit
    /// A comment in the command, so logs (and the UI-test mock) can tell the router's exec apart.
    public static let marker = "pier-talk"

    static let maxSessions = 60
    static let maxProjects = 80

    // MARK: prompt

    /// The prompt for the model. `language` names the language for the question / title ("Brazilian Portuguese", "English").
    public static func prompt(request: String, context: Context, language: String) -> String {
        var out = """
        You route a person's request to one of their coding agents (AI agents working in git worktrees on dev boxes).
        Answer with exactly ONE JSON object and nothing else: no code fence, no prose before or after.

        Pick one action:
        1. {"action":"send","box":"<box>","session":"<session id>","text":"<message for that agent>"}
           when the request is about the work of one listed session: it continues, corrects or asks about that session's task,
           names its title, project, worktree or feature, or says "tell the agent…".
        2. {"action":"new_task","box":"<box>","location":"<project>","prompt":"<task for a new agent>","title":"<short title>"}
           when the request is new work in one listed project (no listed session is already doing it).
        3. {"action":"ask","question":"<one short question>"}
           when you cannot tell which session or project is meant, several match equally, or the request is not something an agent can do.

        Rules:
        - Copy "box", "session" and "location" exactly from the lists below (the session id is the first column, not its title). Never invent one.
        - "text" / "prompt": the person's request written as a clear instruction for the agent, in the person's own language, keeping every detail they gave. Do not add requirements.
        - "title": at most 6 words. Write "title" and "question" in \(language).
        - When a session and a new task both fit, prefer the session if the request continues its work.

        The request:
        <<<
        \(String(request.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000)))
        >>>

        """
        out += "\nLive sessions (session id | box | title | project/worktree | state | last reply):\n"
        let sessions = context.sessions.prefix(maxSessions)
        if sessions.isEmpty { out += "(none)\n" }
        for s in sessions {
            let reply = s.lastReply.map { oneLine($0, max: 120) } ?? "-"
            out += "- \(s.name) | \(s.box) | \(oneLine(s.title, max: 80)) | \(s.location) | \(s.state) | \(reply)\n"
        }
        out += "\nProjects (location | box | name | worktrees):\n"
        let projects = context.projects.prefix(maxProjects)
        if projects.isEmpty { out += "(none)\n" }
        for p in projects {
            let wts = p.worktrees.isEmpty ? "-" : p.worktrees.prefix(12).joined(separator: ", ")
            out += "- \(p.location) | \(p.box) | \(p.displayName.map { oneLine($0, max: 60) } ?? p.location) | \(wts)\n"
        }
        return out
    }

    /// Shell for `exec`: finds `claude` on the box and pipes the prompt to Haiku from `$HOME` (so no project's CLAUDE.md
    /// or settings get loaded). The prompt travels base64-encoded, never interpolated.
    public static func command(prompt: String) -> String {
        """
        : \(marker); cd "$HOME" 2>/dev/null; \
        CL=$(command -v claude 2>/dev/null); \
        for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /usr/local/bin/claude /opt/homebrew/bin/claude "$HOME/.npm-global/bin/claude"; do \
        [ -z "$CL" ] && [ -x "$c" ] && CL="$c"; done; \
        [ -z "$CL" ] && { echo "claude CLI not found on the box" >&2; exit \(noCLIExit); }; \
        printf %s '\(GitActions.b64(prompt))' | base64 -d | PIER_HOOKS_QUIET=1 "$CL" -p --model haiku 2>&1
        """
    }

    // MARK: parse

    /// Reads the model's answer and checks it against `context`. Tolerates a code fence or words around the object;
    /// accepts a session given by its exact title when that title is unique, and fills a missing box when only one fits.
    public static func parse(_ output: String, context: Context) -> Result<Decision, Failure> {
        guard let obj = jsonObject(in: output) else { return .failure(.malformed) }
        func str(_ k: String) -> String? {
            (obj[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }
        let action = (str("action") ?? "").lowercased().replacingOccurrences(of: "-", with: "_")
        switch action {
        case "send":
            guard let text = str("text") else { return .failure(.empty) }
            let key = str("session") ?? ""
            guard let s = resolveSession(key, box: str("box"), in: context) else { return .failure(.unknownSession(key)) }
            return .success(.send(box: s.box, session: s.name, text: text))
        case "new_task", "newtask", "new":
            guard let prompt = str("prompt") ?? str("text") else { return .failure(.empty) }
            let key = str("location") ?? str("project") ?? ""
            guard let p = resolveProject(key, box: str("box"), in: context) else { return .failure(.unknownProject(key)) }
            let title = str("title").map { String(oneLine($0, max: 60)) }
            return .success(.newTask(box: p.box, location: p.location, prompt: prompt, title: title))
        case "ask":
            guard let q = str("question") ?? str("text") else { return .failure(.empty) }
            return .success(.ask(question: q))
        default:
            return .failure(.unknownAction(action))
        }
    }

    static func resolveSession(_ key: String, box: String?, in c: Context) -> SessionInfo? {
        guard !key.isEmpty else { return nil }
        let pool = box.map { b in c.sessions.filter { $0.box == b } } ?? c.sessions
        let byName = pool.filter { $0.name == key }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { return nil }   // same id on two boxes and no box given: ambiguous
        let byTitle = pool.filter { $0.title.caseInsensitiveCompare(key) == .orderedSame }
        return byTitle.count == 1 ? byTitle[0] : nil
    }

    static func resolveProject(_ key: String, box: String?, in c: Context) -> ProjectInfo? {
        guard !key.isEmpty else { return nil }
        let pool = box.map { b in c.projects.filter { $0.box == b } } ?? c.projects
        let byName = pool.filter { $0.location == key }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { return nil }
        let byDisplay = pool.filter { $0.displayName?.caseInsensitiveCompare(key) == .orderedSame }
        return byDisplay.count == 1 ? byDisplay[0] : nil
    }

    /// The first balanced `{…}` that parses as a JSON object (strings and escapes respected).
    static func jsonObject(in text: String) -> [String: Any]? {
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var depth = 0, inString = false, escaped = false, j = i
            var end: Int?
            while j < chars.count {
                let ch = chars[j]
                if inString {
                    if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                } else if ch == "\"" { inString = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" { depth -= 1; if depth == 0 { end = j; break } }
                j += 1
            }
            guard let end else { return nil }
            var s = String.UnicodeScalarView(); s.append(contentsOf: chars[i...end])
            if let d = String(s).data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
            i += 1
        }
        return nil
    }

    static func oneLine(_ s: String, max: Int) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map { String($0) } ?? ""
        let t = line.replacingOccurrences(of: "|", with: "/").trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
