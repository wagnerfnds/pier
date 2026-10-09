import SwiftUI
import PierKit

/// One pull request, named by repo and number. `box` is where `gh` runs; nil = a box with a clone of `repo` (else any box).
struct PullRequestRoute: Hashable {
    var box: String? = nil
    let repo: String
    let number: Int
    /// Shown while the PR loads.
    var title: String? = nil
}

/// State of the PR screen. Everything goes through `exec` on the box (`PRCommands`): reads and actions name the PR with
/// `--repo`, so they run from the location that clones the repo, or from any location when none does.
@MainActor @Observable
final class PullRequestStore {
    let route: PullRequestRoute
    private(set) var box: String?
    var pr: PRDetail?
    var loading = true
    var error: HomeError?

    @ObservationIgnored private weak var model: AppModel?

    init(route: PullRequestRoute) { self.route = route }

    var repo: String { route.repo }
    var number: Int { route.number }
    var conn: BoxConnection? { box.flatMap { model?.connection(for: $0) } }

    // MARK: where gh runs

    /// The box named by the route, else one whose project clones the repo, else the first box that is online.
    func bind(_ model: AppModel) {
        self.model = model
        if let b = route.box, model.connection(for: b) != nil { box = b; return }
        let clones = model.boxes.first { c in c.locations.contains { Self.matches($0, repo) } }
        box = (clones ?? model.boxes.first { $0.state.isOnline } ?? model.boxes.first)?.name
    }

    static func matches(_ l: Location, _ repo: String) -> Bool {
        guard l.repo else { return false }
        let slug = l.slug ?? l.remote.flatMap(PRCommands.slug(fromRemote:))
        return slug?.lowercased() == repo.lowercased()
    }

    /// The project (main checkout) that clones the repo, on the chosen box.
    var location: Location? { conn?.locations.first { Self.matches($0, repo) } }

    /// The working directory of every `gh` call.
    var execLocation: String? {
        guard let conn else { return nil }
        return location?.name ?? conn.locations.first(where: \.repo)?.name ?? conn.locations.first?.name
    }

    // MARK: loading

    func load() async {
        // Opened at launch (a notification, a link, a test hook) the boxes may not have answered yet: wait for a project
        // list (bounded), choosing the box again as they come in.
        if execLocation == nil, let model {
            for _ in 0..<50 where execLocation == nil {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                bind(model)
            }
        }
        guard let conn, let loc = execLocation else {
            error = HomeError(problem: .other, message: S("Nenhuma box conectada com um projeto para rodar o gh."))
            loading = false
            return
        }
        do {
            let r = try await conn.client.exec(location: loc, command: PRCommands.view(number: number, repo: repo), timeout: "45s")
            pr = try PRCommands.parseView(exitCode: r.exitCode, output: r.output)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? HomeError) ?? HomeError(problem: .other, message: ReviewStore.message(error))
        }
        loading = false
    }

    // MARK: actions

    enum Action: Equatable {
        case merge(PRMergeMethod, deleteBranch: Bool)
        case comment(String)
        case review(PRReviewKind, String)
        case close
        case ready

        var command: (Int, String) -> String {
            switch self {
            case .merge(let m, let d): { PRCommands.merge(number: $0, repo: $1, method: m, deleteBranch: d) }
            case .comment(let b): { PRCommands.comment(number: $0, repo: $1, body: b) }
            case .review(let k, let b): { PRCommands.review(number: $0, repo: $1, kind: k, body: b) }
            case .close: { PRCommands.close(number: $0, repo: $1) }
            case .ready: { PRCommands.ready(number: $0, repo: $1) }
            }
        }

        /// What the banner says when it worked.
        var done: String {
            switch self {
            case .merge: S("PR mesclado.")
            case .comment: S("Comentário publicado.")
            case .review(.approve, _): S("PR aprovado.")
            case .review(.requestChanges, _): S("Mudanças pedidas.")
            case .review(.comment, _): S("Revisão publicada.")
            case .close: S("PR fechado.")
            case .ready: S("PR pronto para revisão.")
            }
        }
    }

    struct ActionResult: Equatable {
        var ok: Bool
        var output: String
    }

    /// Runs one `gh` action (2-minute limit), then reads the PR again.
    func run(_ action: Action) async -> ActionResult {
        guard let conn, let loc = execLocation else { return ActionResult(ok: false, output: S("Sem conexão com a box.")) }
        do {
            let r = try await conn.client.exec(location: loc, command: action.command(number, repo), timeout: "2m")
            let res = ActionResult(ok: r.exitCode == 0, output: r.output.trimmingCharacters(in: .whitespacesAndNewlines))
            if res.ok { Haptic.success(); await load() }
            return res
        } catch {
            return ActionResult(ok: false, output: ReviewStore.message(error))
        }
    }

    func fileDiffCommand(_ path: String) -> String { PRCommands.fileDiff(number: number, repo: repo, path: path) }

    // MARK: bringing the PR into a worktree

    /// A worktree of the project that already has the PR's branch checked out (same-repository PRs only).
    var existingWorktree: Worktree? {
        guard let pr, !pr.isCrossRepository, let location else { return nil }
        return location.worktrees?.first { $0.branch == pr.headRefName }
    }

    enum BringStep: Equatable { case fetching, creating, checkingOut }

    struct Brought: Equatable {
        let location: String
        let worktree: String
        /// `loc/wt`, what sessions are started in.
        let ref: String
        let branch: String
        /// Set when the worktree exists but the checkout did not fully work (gh/git output).
        var warning: String?
    }

    struct BringError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Creates worktree `name` in the project that clones the repo, on the PR's head branch:
    /// - same repository: `git fetch origin <head>` in the main checkout, then pierd creates the worktree on `<head>` tracking
    ///   `origin/<head>` (docs/API.md §2.4) and `trackHead` sets the upstream, so `git push` updates the PR;
    /// - fork: the worktree starts on the throwaway branch `name` from the base, then `gh pr checkout` brings the fork's head
    ///   in and configures the branch to push back to it.
    func bringToWorktree(name: String, step: (BringStep) -> Void) async throws -> Brought {
        guard let conn, let pr, let loc = location else { throw BringError(message: S("Nenhum projeto desta box é um clone de \(repo).")) }
        func exec(_ at: String, _ cmd: String, _ timeout: String = "2m") async throws -> ExecResult {
            try await conn.client.exec(location: at, command: cmd, timeout: timeout)
        }
        func tail(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)) }
        let wt: Worktree
        var out: ExecResult
        if !pr.isCrossRepository {
            step(.fetching)
            out = try await exec(loc.name, PRCommands.fetchHead(pr.headRefName))
            guard out.exitCode == 0 else { throw BringError(message: tail(out.output)) }
            step(.creating)
            wt = try await conn.client.createWorktree(location: loc.name, WorktreeRequest(name: name, branch: pr.headRefName))
            step(.checkingOut)
            out = try await exec(loc.ref(wt), PRCommands.trackHead(pr.headRefName))
        } else {
            step(.creating)
            let base = pr.baseRefName.isEmpty ? nil : "origin/\(pr.baseRefName)"
            wt = try await conn.client.createWorktree(location: loc.name, WorktreeRequest(name: name, branch: name, base: base))
            step(.checkingOut)
            out = try await exec(loc.ref(wt), PRCommands.checkoutFork(number: number, repo: repo, scratch: name))
        }
        await conn.refreshLocations()
        let branch = PRCommands.parseBranch(out.output) ?? wt.branch ?? pr.headRefName
        return Brought(location: loc.name, worktree: wt.name, ref: loc.ref(wt), branch: branch,
                       warning: out.exitCode == 0 ? nil : tail(out.output))
    }

    /// The agent's first prompt, in the person's language.
    func agentPrompt(branch: String) -> String {
        guard let pr else { return "" }
        var t = PRCommands.PromptText()
        t.intro = { n, title, author, url in S("Continue o trabalho no PR #\(n) (\(title)) de @\(author): \(url)") }
        t.branch = { b in S("Você está na branch do PR, `\(b)`. Ao terminar, faça commit e `git push`: isso atualiza o PR.") }
        t.forkNoEdit = S("O autor não permite que mantenedores enviem para o fork, então o push vai falhar: me avise antes de tentar.")
        t.requested = S("Os revisores pediram mudanças:")
        t.inline = { r, n in S("Leia também os comentários da revisão no código: `gh api repos/\(r)/pulls/\(n)/comments`.") }
        t.task = S("Faça as mudanças pedidas, rode os testes e me diga o que mudou.")
        t.taskNoReview = { n, r in S("Leia o PR (`gh pr view \(n) --repo \(r) --comments`) e o diff, e me diga o que falta antes de mudar qualquer coisa.") }
        return PRCommands.agentPrompt(pr, repo: repo, branch: branch, text: t)
    }

    /// Starts an agent in the worktree (`POST /v1/sessions`).
    func startAgent(ref: String, agent: AgentPreset, model: String?, effort: String?, prompt: String) async throws -> Session {
        guard let conn, let box else { throw BringError(message: S("Sem conexão com a box.")) }
        let title = "PR #\(number) · \(pr?.title ?? "")"
        let s = try await conn.client.startSession(SessionRequest(
            location: ref, agent: agent.id, prompt: prompt,
            model: agent.canPickModel ? model?.nilIfEmpty : nil, effort: agent.canPickEffort ? effort?.nilIfEmpty : nil,
            title: String(title.prefix(60))))
        conn.scheduleRefresh(sessions: true, locations: true)
        NotificationCenter.default.post(name: .pierTaskCreated, object: nil, userInfo: ["box": box, "session": s.name])
        return s
    }
}
