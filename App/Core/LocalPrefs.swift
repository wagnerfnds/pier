import Foundation
import PierKit

/// Phone-local organisation of projects: sections, renames, hidden. JSON in Application Support.
/// A project key is "<box>/<location>".
@MainActor @Observable
final class LocalPrefs {
    struct Section: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var projects: [String] = []
    }
    /// Last composer choices for a project (agent / model / effort).
    struct Pick: Codable, Hashable {
        var agent: String?
        var model: String?
        var effort: String?
    }
    /// A saved prompt (template) for the composer.
    struct SavedPrompt: Codable, Identifiable, Hashable {
        var id = UUID()
        var title: String
        var text: String
    }
    struct Data: Codable {
        var sections: [Section] = []
        var renames: [String: String] = [:]
        var hidden: Set<String> = []
        /// Most recently used project keys, newest first.
        var recentProjects: [String] = []
        var picks: [String: Pick] = [:]
        var prompts: [SavedPrompt] = []
        var lastBox: String?
        var lastAgent: String?
        /// The composer's unsent prompt, kept until a task is created.
        var composeDraft: String = ""
        /// Sessions the person marked as over ("box/session" -> when). A finished turn is "your turn" until then.
        var closed: [String: Date] = [:]
        /// Finished turns the person has looked at ("box/session" -> when): the Inbox badge counts the others.
        var seen: [String: Date] = [:]
        /// Questions dismissed in the Inbox ("box/session" -> the wait's `state_since`); a new wait shows again.
        var dismissed: [String: Date] = [:]
        /// Box health cards ignored for a while (card id -> until when).
        var snoozedHealth: [String: Date] = [:]
        /// Sidebar sections the person opened or folded (section id, or "working" / "chats" / "archived" / "hidden" /
        /// "unsorted" -> open). Missing means the section's default.
        var sidebarExpanded: [String: Bool] = [:]

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
            renames = try c.decodeIfPresent([String: String].self, forKey: .renames) ?? [:]
            hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
            recentProjects = try c.decodeIfPresent([String].self, forKey: .recentProjects) ?? []
            picks = try c.decodeIfPresent([String: Pick].self, forKey: .picks) ?? [:]
            prompts = try c.decodeIfPresent([SavedPrompt].self, forKey: .prompts) ?? []
            lastBox = try c.decodeIfPresent(String.self, forKey: .lastBox)
            lastAgent = try c.decodeIfPresent(String.self, forKey: .lastAgent)
            composeDraft = try c.decodeIfPresent(String.self, forKey: .composeDraft) ?? ""
            closed = try c.decodeIfPresent([String: Date].self, forKey: .closed) ?? [:]
            seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
            dismissed = try c.decodeIfPresent([String: Date].self, forKey: .dismissed) ?? [:]
            snoozedHealth = try c.decodeIfPresent([String: Date].self, forKey: .snoozedHealth) ?? [:]
            sidebarExpanded = try c.decodeIfPresent([String: Bool].self, forKey: .sidebarExpanded) ?? [:]
        }
    }

    private(set) var data = Data()
    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        load()
    }

    static var defaultURL: URL {
        #if DEBUG
        // A mock run (UI tests, screenshots) seeds sections and marks of its own: on the Mac it shares the installed app's
        // container, so it keeps them in a file of its own instead of the person's prefs.
        if UITestMock.enabled { return Shared.supportDirectory.appendingPathComponent("prefs-mock.json") }
        #endif
        return Shared.supportDirectory.appendingPathComponent("prefs.json")
    }

    static func key(box: String, location: String) -> String { "\(box)/\(location)" }

    var sections: [Section] { data.sections }
    func displayName(box: String, location: String) -> String {
        data.renames[Self.key(box: box, location: location)] ?? location
    }
    func isHidden(box: String, location: String) -> Bool { data.hidden.contains(Self.key(box: box, location: location)) }

    func rename(box: String, location: String, to name: String?) {
        let k = Self.key(box: box, location: location)
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { data.renames[k] = name } else { data.renames[k] = nil }
        save()
    }
    func setHidden(_ hidden: Bool, box: String, location: String) {
        let k = Self.key(box: box, location: location)
        if hidden { data.hidden.insert(k) } else { data.hidden.remove(k) }
        save()
    }
    func addSection(_ name: String) { data.sections.append(Section(name: name)); save() }
    func removeSection(_ id: UUID) { data.sections.removeAll { $0.id == id }; save() }
    func renameSection(_ id: UUID, to name: String) {
        if let i = data.sections.firstIndex(where: { $0.id == id }) { data.sections[i].name = name; save() }
    }
    func moveSections(from: IndexSet, to: Int) {
        data.sections.move(fromOffsets: from, toOffset: to); save()
    }
    /// Put a project in a section (nil = unsorted); a project lives in at most one section.
    func assign(project key: String, to section: UUID?) {
        for i in data.sections.indices { data.sections[i].projects.removeAll { $0 == key } }
        if let section, let i = data.sections.firstIndex(where: { $0.id == section }) { data.sections[i].projects.append(key) }
        save()
    }
    /// Reorder the projects of one section.
    func moveProjects(in section: UUID, from: IndexSet, to: Int) {
        guard let i = data.sections.firstIndex(where: { $0.id == section }) else { return }
        data.sections[i].projects.move(fromOffsets: from, toOffset: to); save()
    }

    /// Put a project in a section (nil = unsorted) right before another project of it (nil = at the end): a drop in the
    /// sidebar. Unsorted projects keep their activity order, so `before` only matters inside a section.
    func place(project key: String, in section: UUID?, before other: String?) {
        guard key != other else { return }
        for i in data.sections.indices { data.sections[i].projects.removeAll { $0 == key } }
        if let section, let i = data.sections.firstIndex(where: { $0.id == section }) {
            let at = other.flatMap { o in data.sections[i].projects.firstIndex(of: o) } ?? data.sections[i].projects.endIndex
            data.sections[i].projects.insert(key, at: at)
        }
        save()
    }

    func isSidebarExpanded(_ id: String, default open: Bool = true) -> Bool { data.sidebarExpanded[id] ?? open }
    func setSidebarExpanded(_ id: String, _ open: Bool) {
        guard data.sidebarExpanded[id] != open else { return }
        data.sidebarExpanded[id] = open
        save()
    }

    // MARK: composer memory & saved prompts

    var recentProjects: [String] { data.recentProjects }
    var prompts: [SavedPrompt] { data.prompts }
    var lastBox: String? { data.lastBox }
    func pick(for key: String) -> Pick? { data.picks[key] }
    var lastAgent: String? { data.lastAgent }

    func noteComposed(box: String, location: String, pick: Pick) {
        let k = Self.key(box: box, location: location)
        data.recentProjects.removeAll { $0 == k }
        data.recentProjects.insert(k, at: 0)
        if data.recentProjects.count > 20 { data.recentProjects.removeLast(data.recentProjects.count - 20) }
        data.picks[k] = pick
        data.lastBox = box
        if let a = pick.agent { data.lastAgent = a }
        save()
    }
    /// A chat's choices, kept per box under the empty location (it is no recent project).
    func noteChatted(box: String, pick: Pick) {
        data.picks[Self.key(box: box, location: "")] = pick
        data.lastBox = box
        if let a = pick.agent { data.lastAgent = a }
        save()
    }
    var composeDraft: String { data.composeDraft }
    @ObservationIgnored private var draftSave: Task<Void, Never>?
    /// Kept while typing; written to disk a moment after the last keystroke (the file is rewritten whole).
    func setComposeDraft(_ text: String) {
        guard data.composeDraft != text else { return }
        data.composeDraft = text
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(text.isEmpty ? 0 : 800))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
    func addPrompt(title: String, text: String) { data.prompts.insert(SavedPrompt(title: title, text: text), at: 0); save() }
    func removePrompt(_ id: UUID) { data.prompts.removeAll { $0.id == id }; save() }

    // MARK: your turn vs closed

    /// Marked as over and nothing happened since (a new turn reopens it by itself).
    func isClosed(box: String, session: Session) -> Bool {
        guard let at = data.closed["\(box)/\(session.name)"] else { return false }
        return at >= (session.stateSince ?? session.created)
    }
    func setClosed(_ closed: Bool, box: String, session: String) {
        let k = "\(box)/\(session)"
        if closed {
            data.closed[k] = Date()
            // Keep the file small: forget marks older than two weeks.
            let cutoff = Date().addingTimeInterval(-14 * 86400)
            data.closed = data.closed.filter { $0.value > cutoff }
        } else {
            data.closed[k] = nil
        }
        save()
    }

    // MARK: seen and dismissed (the Inbox's attention)

    /// The person looked at this finished turn (the session screen, or the reply opened in the Inbox); the card stays
    /// until archived, but the badge no longer counts it. A newer turn is unseen again by itself.
    func isSeen(box: String, session: Session) -> Bool {
        guard let at = data.seen["\(box)/\(session.name)"] else { return false }
        return at >= (session.stateSince ?? session.created)
    }
    func markSeen(box: String, session: String) {
        let k = "\(box)/\(session)"
        if let at = data.seen[k], Date().timeIntervalSince(at) < 1 { return }
        data.seen[k] = Date()
        data.seen = Self.pruned(data.seen)
        save()
    }

    /// A question dismissed in the Inbox stays out until the agent asks again (a newer `state_since`).
    func isDismissed(box: String, session: Session) -> Bool {
        guard let at = data.dismissed["\(box)/\(session.name)"] else { return false }
        return at == (session.stateSince ?? session.created)
    }
    func setDismissed(_ dismissed: Bool, box: String, session: Session) {
        let k = "\(box)/\(session.name)"
        data.dismissed[k] = dismissed ? (session.stateSince ?? session.created) : nil
        data.dismissed = Self.pruned(data.dismissed)
        save()
    }

    /// A box health card "ignored for today": out of the Inbox until `until`.
    func isHealthSnoozed(_ id: String) -> Bool {
        guard let until = data.snoozedHealth[id] else { return false }
        return until > Date()
    }
    func snoozeHealth(_ id: String, until: Date) {
        data.snoozedHealth[id] = until
        data.snoozedHealth = data.snoozedHealth.filter { $0.value > Date() }
        save()
    }

    /// Forgets every Inbox mark (seen, dismissed, snoozed health cards): what a UI test run leaves behind.
    func resetInboxMarks() {
        data.seen = [:]
        data.dismissed = [:]
        data.snoozedHealth = [:]
        save()
    }

    /// Keeps the file small: marks older than two weeks go.
    private static func pruned(_ marks: [String: Date]) -> [String: Date] {
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        return marks.filter { $0.value > cutoff }
    }

    func section(of key: String) -> UUID? { data.sections.first { $0.projects.contains(key) }?.id }

    private func load() {
        guard let d = try? Foundation.Data(contentsOf: url), let v = try? JSONDecoder().decode(Data.self, from: d) else { return }
        data = v
    }
    private func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(data) { try? d.write(to: url, options: .atomic) }
        // The widget extension shows display names and honours hidden projects, so mirror them into the App Group.
        SharedDisplayPrefs(renames: data.renames, hidden: data.hidden).save()
    }
}
