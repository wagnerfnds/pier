import SwiftUI
import PierKit

/// State of one worktree's review: the `ReviewItem`, its PR and the git actions (all through `exec` in that worktree only).
@MainActor @Observable
final class ReviewStore {
    let route: ReviewRoute
    var item: ReviewItem?
    var pr: PullRequest?
    var loading = true
    var error: String?
    /// Session title (drafts the commit message).
    var sessionTitle: String?

    @ObservationIgnored private var client: (any PierBoxClient)?

    init(route: ReviewRoute) { self.route = route }

    func bind(_ model: AppModel) {
        client = model.client(for: route.box)
        if let name = route.session ?? item?.session, !name.isEmpty {
            sessionTitle = model.connection(for: route.box)?.sessions.first { $0.name == name }?.title
        }
    }

    /// `location` for exec: the bare repo name for the main checkout.
    var execLocation: String {
        if let item { return item.execLocation }
        return route.worktree == route.location ? route.location : "\(route.location)/\(route.worktree)"
    }

    var sessionName: String? {
        if let s = route.session, !s.isEmpty { return s }
        if let s = item?.session, !s.isEmpty { return s }
        return nil
    }

    var base: String { item?.base ?? "main" }
    var hasFiles: Bool { !(item?.files.isEmpty ?? true) }
    var hasWork: Bool { hasFiles || (item?.baseAhead ?? 0) > 0 || (item?.ahead ?? 0) > 0 }

    // MARK: loading

    func load() async {
        guard let client else { return }
        do {
            let items = try await client.review(all: true)
            if let found = items.first(where: { $0.location == route.location && $0.worktree == route.worktree }) {
                item = found
            } else {
                item = try await statusItem(client)
            }
            error = nil
        } catch {
            if !(error is CancellationError) { self.error = Self.message(error) }
        }
        loading = false
        await loadPR()
    }

    /// A worktree without changes or unpushed commits is not in `/v1/review`: build the item from `git status`.
    private func statusItem(_ client: any PierBoxClient) async throws -> ReviewItem {
        let r = try await client.exec(location: execLocationFallback, command: GitActions.statusCommand, timeout: "30s")
        let st = GitActions.parseStatus(r.output)
        let files = st.files.map { ReviewFile(path: $0.path, from: $0.from, code: $0.code, added: $0.added ?? 0, removed: $0.removed ?? 0, binary: $0.binary) }
        return ReviewItem(
            location: route.location, worktree: route.worktree, path: "", branch: st.branch.branch,
            upstream: st.branch.upstream, main: route.worktree == route.location, ahead: st.branch.ahead,
            behind: st.branch.behind, files: files,
            added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed },
            session: route.session ?? "")
    }
    private var execLocationFallback: String {
        route.worktree == route.location ? route.location : "\(route.location)/\(route.worktree)"
    }

    func loadPR() async {
        guard let client, item?.branch != nil else { return }
        let r = try? await client.exec(location: execLocation, command: GitActions.prView, timeout: "20s")
        if let r, r.exitCode == 0 { pr = GitActions.parsePullRequest(r.output) } else { pr = nil }
    }

    // MARK: actions

    struct ActionResult: Equatable {
        var ok: Bool
        var output: String
        var prURL: String?
    }

    func approve(message: String, push: Bool, openPR: (title: String, body: String, base: String)?) async -> ActionResult {
        guard let client else { return ActionResult(ok: false, output: String(localized: "Sem conexão com a box.")) }
        let cmd = GitActions.approve(hasFiles: hasFiles, message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                     push: push || openPR != nil, openPR: openPR)
        guard !cmd.isEmpty else { return ActionResult(ok: false, output: String(localized: "Nada para fazer.")) }
        return await run(client, cmd, timeout: "5m")
    }

    /// Commit message + PR text written by Haiku on the box from the real diff (`AIDraft`). Throws a readable message on failure.
    func aiDraft() async throws -> AIDraft.Draft {
        guard let client else { throw DraftError(String(localized: "Sem conexão com a box.")) }
        let base = item.map(GitActions.baseBranch) ?? "main"
        let r = try await client.exec(location: execLocation, command: AIDraft.command(base: base, task: sessionTitle), timeout: "150s")
        if r.exitCode == AIDraft.noCLIExit { throw DraftError(String(localized: "O Claude Code não foi encontrado na box.")) }
        guard r.exitCode == 0, let d = AIDraft.parse(r.output) else {
            let tail = r.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
            throw DraftError(tail.isEmpty ? String(localized: "A IA não respondeu.") : String(tail))
        }
        return d
    }

    struct DraftError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    func discard() async -> ActionResult {
        guard let client else { return ActionResult(ok: false, output: String(localized: "Sem conexão com a box.")) }
        return await run(client, GitActions.discard, timeout: "60s")
    }

    private func run(_ client: any PierBoxClient, _ cmd: String, timeout: String) async -> ActionResult {
        do {
            let r = try await client.exec(location: execLocation, command: cmd, timeout: timeout)
            let res = ActionResult(ok: r.exitCode == 0, output: r.output.trimmingCharacters(in: .whitespacesAndNewlines),
                                   prURL: GitActions.pullRequestURL(in: r.output))
            await load()
            return res
        } catch {
            return ActionResult(ok: false, output: Self.message(error))
        }
    }

    func sendBack(_ note: String) async throws {
        guard let client, let s = sessionName else { return }
        let text = GitActions.sendBackPrefix + note.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await client.send(session: s, SendRequest(text: text, enter: true, when: .idle))
    }

    var defaultMessage: String {
        if var t = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            if t.hasSuffix("…") { t.removeLast() }
            return t
        }
        return GitActions.commitMessage(summary: [], branch: item?.branch)
    }

    static func message(_ error: Error) -> String {
        if let e = error as? BoxError { return e.error }
        return (error as? PierError)?.localizedDescription ?? error.localizedDescription
    }
}

// MARK: file helpers

extension ReviewFile {
    /// Letter + colour for a porcelain XY code or a one-letter name-status.
    var badge: (letter: String, color: Color) {
        if code == "??" { return ("U", Theme.green) }
        let first = code.first(where: { $0 != " " }) ?? "M"
        switch first {
        case "A": return ("A", Theme.green)
        case "D": return ("D", Theme.red)
        case "R", "C": return ("R", Theme.accent)
        default: return ("M", Theme.orange)
        }
    }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var dir: String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") + "/" : ""
    }
}
