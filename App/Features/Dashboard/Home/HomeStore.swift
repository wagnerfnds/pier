import SwiftUI
import PierKit

/// Data behind the Home widgets.
///
/// - Sessions-driven widgets (needs you, working, finished, areas) read the live `SessionsStore`; the working agents' current
///   step, background work and the finished turns' line changes come from `SessionSignals` (shared with the agents board).
/// - Services come from `GET /v1/services` (30 s, and on `service.*` events), with a TCP reachability probe.
/// - Pull requests, CI failures and git activity are computed on the BOX with one `exec` each (see `HomeCommands`),
///   cached in memory and on disk with their timestamps, and refreshed every 5/10/15 minutes and on pull-to-refresh.
///   The shell starts in the first repo location of a box (any location works as a working directory).
@MainActor @Observable
final class HomeStore {
    struct Remote<T: Codable & Sendable>: Codable, Sendable {
        var value: T?
        var updatedAt: Date?
        var error: HomeError?
    }
    typealias LineChange = SessionSignals.LineChange
    struct ServiceEntry: Identifiable, Hashable {
        let box: String
        let host: String
        let service: BoxService
        var id: String { "\(box)/\(service.id)" }
        var url: URL? { URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(service.port)") }
    }
    /// A project's pull request, with the box whose clone of the repo answered it.
    struct BoxPR: Codable, Sendable, Hashable, Identifiable {
        let box: String
        let pr: HomePR
        var id: String { pr.id }
    }
    private struct Cache: Codable {
        var prs = Remote<HomePRs>()
        var projectPRs = Remote<[BoxPR]>()
        var ci = Remote<[CIFailure]>()
        var git = Remote<GitActivity>()
        /// The boxes these came from (fingerprints): with others (one unpaired, the demo's, a UI test's mock box on the
        /// same Mac) the Home starts over instead of showing what is not theirs.
        var boxes: [String]?
    }

    private(set) var prs = Remote<HomePRs>()
    private(set) var projectPRs = Remote<[BoxPR]>()
    private(set) var ci = Remote<[CIFailure]>()
    private(set) var git = Remote<GitActivity>()
    private(set) var services: [ServiceEntry] = []
    private(set) var servicesAt: Date?
    private(set) var servicesError: String?
    private(set) var reachable: [String: Bool] = [:]
    /// Each box's agent accounts with their limits (`GET /v1/accounts`).
    struct LimitsEntry: Identifiable, Hashable {
        let box: String
        let account: AgentAccount
        var id: String { "\(box)/\(account.id)" }
    }
    private(set) var limits: [LimitsEntry] = []
    private(set) var limitsAt: Date?
    private(set) var limitsError: String?
    var steps: [String: String] { signals.steps }
    /// Finished turns that still run work in the background (session id -> what runs), so they read as working, not done.
    var background: [String: [BackgroundItem]] { signals.background }
    var changes: [String: LineChange] { signals.changes }
    private(set) var loading: Set<HomeWidgetKind> = []

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let signals = SessionSignals.shared
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var cachedBoxes: [String]?

    static let interval: [HomeWidgetKind: TimeInterval] = [.prs: 300, .projectPRs: 300, .ci: 600, .git: 900, .services: 30, .limits: 120]

    static let shared = HomeStore()

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? Shared.supportDirectory.appendingPathComponent("home-cache.json")
        if let d = try? Data(contentsOf: self.cacheURL), let c = try? Self.decoder.decode(Cache.self, from: d) {
            prs = c.prs; projectPRs = c.projectPRs; ci = c.ci; git = c.git; cachedBoxes = c.boxes
        }
    }

    /// The cache is the paired boxes' or it goes (`Cache.boxes`).
    private func matchBoxes() {
        guard let model else { return }
        let now = model.boxes.map { $0.record.fingerprint.description }.sorted()
        guard now != cachedBoxes else { return }
        cachedBoxes = now
        prs = Remote(); projectPRs = Remote(); ci = Remote(); git = Remote()
        // The store lives for the app's run (`shared`): the old boxes' services and limits go too, and come back fresh.
        services = []; servicesAt = nil; servicesError = nil; reachable = [:]
        limits = []; limitsAt = nil; limitsError = nil
        saveCache()
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()

    private func saveCache() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? Self.encoder.encode(Cache(prs: prs, projectPRs: projectPRs, ci: ci, git: git, boxes: cachedBoxes)) { try? d.write(to: cacheURL, options: .atomic) }
    }

    // MARK: driving

    /// While the Home is on screen: refresh whatever is older than its interval, every few seconds. The boxes' doctor
    /// reports ride along (10 minutes each), so the box chip can say what needs fixing before the Inbox is opened.
    func run(model: AppModel) async {
        self.model = model
        while !Task.isCancelled {
            await refreshStale()
            await BoxHealthStore.shared.refresh(model: model)
            try? await Task.sleep(for: .seconds(4))
        }
    }

    /// Event-driven refreshes (service lifecycle, agent turns).
    func listen(model: AppModel) async {
        self.model = model
        for await h in model.hub.subscribe() {
            let t = h.event.type
            if t.hasPrefix("service.") { Task { await refresh(.services, force: true) } }
            if t.hasPrefix("account.") { Task { await refresh(.limits, force: true) } }
            if t.hasPrefix("agent.") || t.hasPrefix("session.") { signals.invalidate() }
        }
    }

    func refreshStale() async {
        matchBoxes()
        async let a: Void = refresh(.prs)
        async let b: Void = refresh(.ci)
        async let c: Void = refresh(.git)
        async let d: Void = refresh(.services)
        async let e: Void = sessionSignals()
        async let f: Void = refresh(.limits)
        async let g: Void = refresh(.projectPRs)
        _ = await (a, b, c, d, e, f, g)
    }

    /// Pull-to-refresh.
    func refreshAll() async {
        matchBoxes()
        async let a: Void = refresh(.prs, force: true)
        async let b: Void = refresh(.ci, force: true)
        async let c: Void = refresh(.git, force: true)
        async let d: Void = refresh(.services, force: true)
        async let e: Void = sessionSignals(force: true)
        async let f: Void = refresh(.limits, force: true)
        async let g: Void = refresh(.projectPRs, force: true)
        _ = await (a, b, c, d, e, f, g)
    }

    // MARK: targets

    private struct Target: Sendable {
        let name: String
        let host: String
        let client: any PierBoxClient
        let raw: any PierTransport
        /// The location the shell starts in.
        let cwd: String?
        let repos: [(slug: String, branches: Set<String>)]
        /// Every repo's slug that is not hidden (the projects' pull requests), busy ones first.
        let allSlugs: [String]
        let projects: [HomeGitProject]
    }

    private func targets() -> [Target] {
        guard let model else { return [] }
        let busy = Set(model.sessionsStore.all.map { "\($0.box)/\($0.location)" })
        return model.boxes.filter { $0.state.isOnline }.map { c in
            let cname = c.name
            let repos = c.locations.filter(\.repo)
            // Repos with extra worktrees or live sessions first, so a cap never drops the busy ones.
            let ranked = repos.sorted { a, b in
                func score(_ l: Location) -> Int { ((l.worktrees?.count ?? 0) > 1 ? 2 : 0) + (busy.contains("\(cname)/\(l.name)") ? 1 : 0) }
                return score(a) > score(b)
            }
            let slugs = ranked.compactMap { l -> (String, Set<String>)? in
                guard let s = l.slug, !s.isEmpty else { return nil }
                return (s, Set((l.worktrees ?? []).compactMap(\.branch)))
            }
            var seen = Set<String>()
            let projects = ranked.filter { !model.prefs.isHidden(box: c.name, location: $0.name) && !$0.path.isEmpty && seen.insert($0.path).inserted }
                .prefix(30).map { HomeGitProject(name: model.prefs.displayName(box: c.name, location: $0.name), path: $0.path) }
            let shown = ranked.filter { !model.prefs.isHidden(box: c.name, location: $0.name) }.compactMap(\.slug).filter { !$0.isEmpty }
            return Target(name: c.name, host: c.record.host, client: c.client, raw: c.raw, cwd: repos.first?.name, repos: Array(slugs.prefix(12)),
                          allSlugs: Array(shown.prefix(40)), projects: Array(projects))
        }
    }

    nonisolated private static func problem(_ error: Error) -> HomeError {
        (error as? HomeError) ?? HomeError(problem: .other, message: (error as? PierError)?.localizedDescription ?? error.localizedDescription)
    }

    func updatedAt(_ k: HomeWidgetKind) -> Date? {
        switch k {
        case .prs: prs.updatedAt
        case .projectPRs: projectPRs.updatedAt
        case .ci: ci.updatedAt
        case .git: git.updatedAt
        case .services: servicesAt
        case .limits: limitsAt
        default: nil
        }
    }

    // MARK: remote widgets

    func refresh(_ k: HomeWidgetKind, force: Bool = false) async {
        guard let interval = Self.interval[k], !loading.contains(k) else { return }
        if !force, let at = updatedAt(k), Date().timeIntervalSince(at) < interval { return }
        let ts = targets()
        guard !ts.isEmpty else { return }
        loading.insert(k)
        defer { loading.remove(k) }
        switch k {
        case .prs: await fetchPRs(ts)
        case .projectPRs: await fetchProjectPRs(ts)
        case .ci: await fetchCI(ts)
        case .git: await fetchGit(ts)
        case .services: await fetchServices(ts)
        case .limits: await fetchLimits(ts)
        default: break
        }
    }

    private func fetchPRs(_ ts: [Target]) async {
        let results: [Result<HomePRs, HomeError>] = await withTaskGroup(of: Result<HomePRs, HomeError>.self) { g in
            for t in ts {
                guard let cwd = t.cwd else { continue }
                g.addTask { do { return .success(try await t.client.homePullRequests(location: cwd)) } catch { return .failure(Self.problem(error)) } }
            }
            return await gather(&g)
        }
        let ok = results.compactMap { try? $0.get() }
        guard let first = ok.first else {
            let err = results.compactMap { r -> HomeError? in if case .failure(let e) = r { e } else { nil } }.first
                ?? HomeError(problem: .other, message: HL("Nenhuma box com um repositório para rodar o gh."))
            prs.error = err; saveCache(); return
        }
        var merged = HomePRs(viewer: first.viewer)
        func union(_ lists: [[HomePR]]) -> [HomePR] {
            var seen = Set<String>()
            return lists.flatMap { $0 }.filter { seen.insert($0.url).inserted }.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        }
        merged.review = union(ok.map(\.review)); merged.mine = union(ok.map(\.mine))
        merged.reviewCount = ok.map(\.reviewCount).max() ?? 0; merged.mineCount = ok.map(\.mineCount).max() ?? 0
        prs = Remote(value: merged, updatedAt: Date(), error: nil)
        saveCache()
    }

    /// Every box's projects' open pull requests (anyone's); a repo cloned on two boxes is listed once.
    private func fetchProjectPRs(_ ts: [Target]) async {
        let results: [Result<[BoxPR], HomeError>] = await withTaskGroup(of: Result<[BoxPR], HomeError>.self) { g in
            for t in ts {
                guard let cwd = t.cwd, !t.allSlugs.isEmpty else { continue }
                g.addTask {
                    do { return .success(try await t.client.projectPullRequests(location: cwd, repos: t.allSlugs, perRepo: 5).map { BoxPR(box: t.name, pr: $0) }) }
                    catch { return .failure(Self.problem(error)) }
                }
            }
            return await gather(&g)
        }
        let ok = results.compactMap { try? $0.get() }
        guard !ok.isEmpty else {
            let err = results.compactMap { r -> HomeError? in if case .failure(let e) = r { e } else { nil } }.first
            if let err { projectPRs.error = err } else { projectPRs = Remote(value: [], updatedAt: Date(), error: nil) }
            saveCache(); return
        }
        var seen = Set<String>()
        let all = ok.flatMap { $0 }.filter { seen.insert($0.pr.url).inserted }
            .sorted { ($0.pr.updatedAt ?? .distantPast) > ($1.pr.updatedAt ?? .distantPast) }
        projectPRs = Remote(value: all, updatedAt: Date(), error: nil)
        saveCache()
    }

    private func fetchCI(_ ts: [Target]) async {
        let results: [Result<[CIFailure], HomeError>] = await withTaskGroup(of: Result<[CIFailure], HomeError>.self) { g in
            for t in ts {
                guard let cwd = t.cwd, !t.repos.isEmpty else { continue }
                g.addTask {
                    do {
                        let runs = try await t.client.homeCIFailures(location: cwd, repos: t.repos.map(\.slug))
                        // Only the branches of your worktrees.
                        let branches = Dictionary(t.repos.map { ($0.slug, $0.branches) }, uniquingKeysWith: { $0.union($1) })
                        return .success(runs.filter { branches[$0.repo]?.contains($0.branch) == true })
                    } catch { return .failure(Self.problem(error)) }
                }
            }
            return await gather(&g)
        }
        let ok = results.compactMap { try? $0.get() }
        guard !ok.isEmpty else {
            let err = results.compactMap { r -> HomeError? in if case .failure(let e) = r { e } else { nil } }.first
            if let err { ci.error = err; saveCache() } else { ci = Remote(value: [], updatedAt: Date(), error: nil); saveCache() }
            return
        }
        var seen = Set<Int>()
        let all = ok.flatMap { $0 }.filter { seen.insert($0.runID).inserted }.sorted { $0.createdAt > $1.createdAt }
        ci = Remote(value: all, updatedAt: Date(), error: nil)
        saveCache()
    }

    private func fetchGit(_ ts: [Target]) async {
        let results: [Result<GitActivity, HomeError>] = await withTaskGroup(of: Result<GitActivity, HomeError>.self) { g in
            for t in ts {
                guard let cwd = t.cwd, !t.projects.isEmpty else { continue }
                g.addTask { do { return .success(try await t.client.homeGitActivity(location: cwd, projects: t.projects)) } catch { return .failure(Self.problem(error)) } }
            }
            return await gather(&g)
        }
        let ok = results.compactMap { try? $0.get() }
        guard let first = ok.first else {
            if let err = results.compactMap({ r -> HomeError? in if case .failure(let e) = r { e } else { nil } }).first { git.error = err; saveCache() }
            return
        }
        var days = first.days
        for other in ok.dropFirst() {
            for (i, d) in other.days.enumerated() where days.indices.contains(i) && days[i].day == d.day {
                days[i].commits += d.commits; days[i].add += d.add; days[i].del += d.del
            }
        }
        let by = ok.flatMap(\.byProject).sorted { $0.commits > $1.commits }
        git = Remote(value: GitActivity(days: days, byProject: by), updatedAt: Date(), error: nil)
        saveCache()
    }

    // MARK: services

    private func fetchServices(_ ts: [Target]) async {
        let results: [(String, String, [BoxService]?)] = await withTaskGroup(of: (String, String, [BoxService]?).self) { g in
            for t in ts {
                g.addTask { (t.name, t.host, try? await BoxAPI(transport: t.raw).services()) }
            }
            return await gather(&g)
        }
        guard results.contains(where: { $0.2 != nil }) else { servicesError = HL("Não foi possível listar os serviços."); return }
        let hidden = model?.prefs
        var out: [ServiceEntry] = []
        for (box, host, list) in results {
            for s in list ?? [] where hidden?.isHidden(box: box, location: s.location) != true && s.port > 0 {
                out.append(ServiceEntry(box: box, host: host, service: s))
            }
        }
        services = out.sorted { $0.service.port < $1.service.port }
        servicesAt = Date(); servicesError = nil
        // Which ones answer from this phone (tap opens them in Safari).
        let probes: [(String, Bool)] = await withTaskGroup(of: (String, Bool).self) { g in
            for e in out { g.addTask { (e.id, await PortProbe.reachable(host: e.host, port: e.service.port)) } }
            return await gather(&g)
        }
        reachable = Dictionary(probes, uniquingKeysWith: { $1 })
    }

    // MARK: limits

    private func fetchLimits(_ ts: [Target]) async {
        let capable = Set(model?.boxes.filter { $0.info?.has("accounts") == true }.map(\.name) ?? [])
        let results: [(String, [AgentAccount]?)] = await withTaskGroup(of: (String, [AgentAccount]?).self) { g in
            for t in ts where capable.contains(t.name) {
                g.addTask { (t.name, try? await BoxAPI(transport: t.raw).accounts()) }
            }
            return await gather(&g)
        }
        if !capable.isEmpty, !results.contains(where: { $0.1 != nil }) { limitsError = HL("Não foi possível ler os limites."); return }
        let order = ts.map(\.name)
        limits = results.flatMap { box, list in (list ?? []).map { LimitsEntry(box: box, account: $0) } }
            .sorted { (order.firstIndex(of: $0.box) ?? 0, $0.account.agent, $0.account.builtin ? 0 : 1, $0.account.name) < (order.firstIndex(of: $1.box) ?? 0, $1.account.agent, $1.account.builtin ? 0 : 1, $1.account.name) }
        limitsAt = Date(); limitsError = nil
    }

    /// After the widget changed something on a box (default account, status line): read the limits again now.
    func reloadLimits() async { await refresh(.limits, force: true) }

    // MARK: live bits of sessions-driven widgets

    private func sessionSignals(force: Bool = false) async {
        guard let model else { return }
        await signals.refreshStale(model: model, force: force)
    }
}

/// Collects a task group's results.
@MainActor private func gather<T: Sendable>(_ g: inout TaskGroup<T>) async -> [T] {
    var out: [T] = []
    for await r in g { out.append(r) }
    return out
}
