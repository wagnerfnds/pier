import SwiftUI
import PierKit

/// One project (a git location on one box) as the phone lists it.
struct ProjectEntry: Identifiable, Hashable {
    let box: String
    let location: Location
    var id: String { key }
    var key: String { "\(box)/\(location.name)" }
    var route: ProjectRoute { ProjectRoute(box: box, location: location.name) }
    var worktreeCount: Int { location.worktrees?.count ?? 0 }
}

struct ProjectGroup: Identifiable {
    enum Kind { case section(UUID), unsorted, hidden }
    let kind: Kind
    let title: String
    var entries: [ProjectEntry]
    var id: String {
        switch kind {
        case .section(let u): u.uuidString
        case .unsorted: "unsorted"
        case .hidden: "hidden"
        }
    }
}

enum ProjectGrouping {
    /// Every repo location of every box.
    @MainActor static func entries(in boxes: [BoxConnection]) -> [ProjectEntry] {
        boxes.flatMap { b in b.locations.filter(\.repo).map { ProjectEntry(box: b.name, location: $0) } }
    }

    /// Sections (user order, projects in the user's order), then the rest, then hidden.
    @MainActor static func groups(entries: [ProjectEntry], prefs: LocalPrefs, activity: (ProjectEntry) -> Int, includeEmptySections: Bool) -> [ProjectGroup] {
        let byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var placed = Set<String>()
        var groups: [ProjectGroup] = []
        for s in prefs.sections {
            let items = s.projects.compactMap { k -> ProjectEntry? in
                guard let e = byKey[k], !prefs.data.hidden.contains(k) else { return nil }
                return e
            }
            placed.formUnion(s.projects)
            if !items.isEmpty || includeEmptySections { groups.append(ProjectGroup(kind: .section(s.id), title: s.name, entries: items)) }
        }
        let rest = entries.filter { !placed.contains($0.key) && !prefs.data.hidden.contains($0.key) }
            .sorted { (activity($0), $1.location.name.lowercased()) > (activity($1), $0.location.name.lowercased()) }
        if !rest.isEmpty {
            groups.append(ProjectGroup(kind: .unsorted, title: groups.isEmpty ? String(localized: "Projetos") : String(localized: "Sem seção"), entries: rest))
        }
        let hidden = entries.filter { prefs.data.hidden.contains($0.key) }.sorted { $0.location.name < $1.location.name }
        if !hidden.isEmpty { groups.append(ProjectGroup(kind: .hidden, title: String(localized: "Ocultos"), entries: hidden)) }
        return groups
    }

    static func matches(_ e: ProjectEntry, _ q: String, display: String) -> Bool {
        let q = q.lowercased()
        return display.lowercased().contains(q) || e.location.name.lowercased().contains(q)
            || (e.location.slug ?? "").lowercased().contains(q) || (e.location.remote ?? "").lowercased().contains(q)
    }
}

/// Agent sessions of a location grouped by dashboard state.
extension BoxConnection {
    func agentCounts(location: String, worktree: String? = nil) -> [DashState: Int] {
        var out: [DashState: Int] = [:]
        for s in sessions {
            guard let st = DashState(s) else { continue }
            let bs = BoxSession(box: name, session: s)
            guard bs.location == location else { continue }
            if let worktree, bs.worktree != worktree { continue }
            out[st, default: 0] += 1
        }
        return out
    }

    /// The same for one worktree by its ref ("loc" for the main one, "loc/wt" otherwise).
    func agentCounts(ref: String) -> [DashState: Int] {
        var out: [DashState: Int] = [:]
        for s in sessions where s.location == ref {
            if let st = DashState(s) { out[st, default: 0] += 1 }
        }
        return out
    }
}

struct CountPill: View {
    let state: DashState
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            if state == .working { ProgressView().controlSize(.mini).tint(state.color) }
            else { Image(systemName: state.symbol).font(.system(size: 10, weight: .semibold)) }
            Text("\(count)").font(.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(state.color.opacity(0.14), in: Capsule())
    }
}

struct CountPills: View {
    let counts: [DashState: Int]
    var body: some View {
        HStack(spacing: 5) {
            ForEach([DashState.needsYou, .working, .done, .ready], id: \.self) { s in
                if let n = counts[s], n > 0 { CountPill(state: s, count: n) }
            }
        }
    }
}
