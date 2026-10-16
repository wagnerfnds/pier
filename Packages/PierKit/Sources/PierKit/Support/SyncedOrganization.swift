import Foundation

/// How the person organises their projects (sections, names, hidden ones, the order of the rest, folded sections), kept
/// the same on every device of theirs through iCloud's key-value store: the iPhone's Projetos and the Mac's and iPad's
/// sidebar show the same sections. The newest change wins; a device that never synced merges into what iCloud has, so
/// neither side's sections are lost on the first sync.
public struct SyncedOrganization: Codable, Sendable, Hashable {
    public struct Section: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var name: String
        public var projects: [String]
        public var sort: ProjectSort
        public init(id: UUID, name: String, projects: [String], sort: ProjectSort) {
            self.id = id; self.name = name; self.projects = projects; self.sort = sort
        }
    }

    public var sections: [Section]
    public var renames: [String: String]
    public var hidden: Set<String>
    public var unsortedSort: ProjectSort
    public var unsortedOrder: [String]
    public var expanded: [String: Bool]
    /// When it was last changed, by the device that changed it.
    public var updatedAt: Date

    public init(sections: [Section] = [], renames: [String: String] = [:], hidden: Set<String> = [], unsortedSort: ProjectSort = .activity,
                unsortedOrder: [String] = [], expanded: [String: Bool] = [:], updatedAt: Date = .distantPast) {
        self.sections = sections; self.renames = renames; self.hidden = hidden; self.unsortedSort = unsortedSort
        self.unsortedOrder = unsortedOrder; self.expanded = expanded; self.updatedAt = updatedAt
    }

    /// Nothing organised yet.
    public var isEmpty: Bool { sections.isEmpty && renames.isEmpty && hidden.isEmpty && unsortedOrder.isEmpty }

    /// The same organisation, the time aside.
    public func sameContent(as o: SyncedOrganization) -> Bool {
        var a = self, b = o
        a.updatedAt = .distantPast; b.updatedAt = .distantPast
        return a == b
    }

    /// What a device shows once it has read iCloud's copy (`remote`) next to its own (`local`).
    ///
    /// - `synced`: this device synced before; the newer copy wins whole.
    /// - Never synced (the first launch of a version that syncs): a merge. iCloud's sections come first; a local section
    ///   with the name of one of them adds its projects to it, the others are added after; a project sits in one section
    ///   only (iCloud's place wins). Names and hidden projects are joined (iCloud's name wins); folds are joined.
    public static func resolve(local: SyncedOrganization, remote: SyncedOrganization?, synced: Bool) -> SyncedOrganization {
        guard let remote, !remote.isEmpty else { return local }
        if local.isEmpty { return remote }
        if synced { return remote.updatedAt > local.updatedAt ? remote : local }
        var out = remote
        var placed = Set(remote.sections.flatMap(\.projects))
        for s in local.sections {
            let fresh = s.projects.filter { !placed.contains($0) }
            placed.formUnion(fresh)
            if let i = out.sections.firstIndex(where: { $0.name.caseInsensitiveCompare(s.name) == .orderedSame }) {
                out.sections[i].projects += fresh
            } else {
                out.sections.append(Section(id: s.id, name: s.name, projects: fresh, sort: s.sort))
            }
        }
        out.renames = local.renames.merging(remote.renames) { _, r in r }
        out.hidden = remote.hidden.union(local.hidden)
        out.unsortedOrder = remote.unsortedOrder + local.unsortedOrder.filter { !remote.unsortedOrder.contains($0) }
        out.expanded = local.expanded.merging(remote.expanded) { _, r in r }
        out.updatedAt = max(remote.updatedAt, local.updatedAt)
        return out
    }
}
