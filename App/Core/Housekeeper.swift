import Foundation
import PierKit

/// Runs the "Faxina" (`Housekeeping` plan) on the boxes: from the screen (the person picks) and from Shortcuts (safe steps).
enum Housekeeper {
    struct BoxPlan: Sendable, Identifiable {
        let box: String
        let steps: [Housekeeping.Step]
        let error: String?
        var id: String { box }
    }

    struct Outcome: Sendable, Identifiable, Hashable {
        let box: String
        let step: Housekeeping.Step
        let ok: Bool
        let message: String
        var id: String { "\(box)|\(step.id)" }
    }

    static func scan(_ boxes: [(name: String, client: any PierBoxClient)]) async -> [BoxPlan] {
        await withTaskGroup(of: (Int, BoxPlan).self) { g in
            for (i, b) in boxes.enumerated() {
                g.addTask {
                    do {
                        async let wts = b.client.worktreeStatuses(location: nil)
                        async let ses = b.client.sessions()
                        let services = (try? await (b.client as? BoxAPI)?.services()) ?? []
                        let plan = Housekeeping.plan(worktrees: try await wts, sessions: try await ses, services: services)
                        return (i, BoxPlan(box: b.name, steps: plan, error: nil))
                    } catch {
                        return (i, BoxPlan(box: b.name, steps: [], error: SessionActions.describe(error)))
                    }
                }
            }
            var out: [Int: BoxPlan] = [:]
            for await (i, p) in g { out[i] = p }
            return boxes.indices.compactMap { out[$0] }
        }
    }

    /// Runs the steps: boxes in parallel, each box in order (sessions, worktrees, services, then the mains).
    static func run(_ work: [(name: String, client: any PierBoxClient, steps: [Housekeeping.Step])]) async -> [Outcome] {
        let order: [Housekeeping.Kind] = [.dropSession, .removeWorktree, .stopServices, .updateMain]
        return await withTaskGroup(of: [Outcome].self) { g in
            for b in work {
                g.addTask {
                    var out: [Outcome] = []
                    for kind in order {
                        for step in b.steps where step.kind == kind {
                            out.append(await perform(step, box: b.name, client: b.client))
                        }
                    }
                    return out
                }
            }
            var all: [Outcome] = []
            for await o in g { all += o }
            return all
        }
    }

    static func perform(_ step: Housekeeping.Step, box: String, client: any PierBoxClient) async -> Outcome {
        func done(_ ok: Bool, _ m: String) -> Outcome { Outcome(box: box, step: step, ok: ok, message: m) }
        do {
            switch step.kind {
            case .dropSession:
                try await client.kill(session: step.session ?? "")
                return done(true, String(localized: "Sessão removida"))
            case .removeWorktree:
                // An unsafe step only runs when the person ticked it: then uncommitted files go too.
                let r = try await client.removeWorktree(location: step.location, worktree: step.worktree, force: !step.safe, deleteBranch: true)
                switch r {
                case .removed: return done(true, String(localized: "Worktree removida (serviços parados, branch local apagada)"))
                case .archiving: return done(true, String(localized: "Arquivando: o script do projeto roda e a worktree some ao terminar"))
                }
            case .stopServices:
                guard let api = client as? BoxAPI else { return done(false, "—") }
                let running = try await api.worktreeServices(location: step.location, worktree: step.worktree).filter(\.isRunning)
                for s in running { try await api.serviceAction(location: step.location, worktree: step.worktree, service: s.name, "stop") }
                return done(true, String(localized: "\(running.count) serviço(s) parado(s)"))
            case .updateMain:
                let r = try await client.exec(location: step.location, command: GitActions.updateMain, timeout: "90s")
                switch GitActions.parseUpdateMain(exitCode: r.exitCode, output: r.output) {
                case .updated(let sha): return done(true, String(localized: "main atualizada (\(sha))"))
                case .dirty: return done(false, String(localized: "main com alterações locais: não atualizei"))
                case .failed(let m): return done(false, m)
                }
            }
        } catch {
            return done(false, SessionActions.describe(error))
        }
    }

    /// Shortcuts / automation: scan every paired box and run only the safe steps.
    static func runSafe(_ boxes: [(name: String, client: any PierBoxClient)]) async -> (plans: [BoxPlan], outcomes: [Outcome]) {
        let plans = await scan(boxes)
        let work = plans.compactMap { p -> (name: String, client: any PierBoxClient, steps: [Housekeeping.Step])? in
            guard let c = boxes.first(where: { $0.name == p.box })?.client else { return nil }
            return (p.box, c, p.steps.filter(\.safe))
        }
        let outcomes = await run(work)
        LastHousekeeping.save(Date(), summary: summary(outcomes))
        return (plans, outcomes)
    }

    static func summary(_ outcomes: [Outcome]) -> String {
        let mains = outcomes.filter { $0.step.kind == .updateMain && $0.ok }.count
        let wts = outcomes.filter { $0.step.kind == .removeWorktree && $0.ok }.count
        let svc = outcomes.filter { $0.step.kind == .stopServices && $0.ok }.count
        let fail = outcomes.filter { !$0.ok }.count
        var parts = [String(localized: "\(mains) main(s) atualizada(s)"), String(localized: "\(wts) worktree(s) removida(s)")]
        if svc > 0 { parts.append(String(localized: "serviços parados em \(svc)")) }
        if fail > 0 { parts.append(String(localized: "\(fail) falha(s)")) }
        return parts.joined(separator: " · ")
    }
}

/// When the last Faxina ran and what it did (shown in Settings).
enum LastHousekeeping {
    private static let key = "housekeeping.last"
    static func save(_ date: Date, summary: String) {
        UserDefaults.standard.set(["at": date.timeIntervalSince1970, "summary": summary], forKey: key)
    }
    static func load() -> (date: Date, summary: String)? {
        guard let d = UserDefaults.standard.dictionary(forKey: key), let at = d["at"] as? Double, let s = d["summary"] as? String else { return nil }
        return (Date(timeIntervalSince1970: at), s)
    }
}
