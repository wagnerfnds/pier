import SwiftUI
import PierKit

/// The app's sections, in the order the tab bar and the sidebar show them (and ⌘1–4 pick them).
enum AppTab: Hashable { case home, inbox, board, projects, settings }

struct PendingPair: Identifiable {
    let id = UUID()
    let link: PairingLink
    /// The link came from outside the app (a tapped `pier://` URL): the sheet asks before pairing. Links the person
    /// scanned or pasted are their own doing and pair at once.
    var confirm = false
}

/// What the regular-width sidebar shows selected: an app section, or an item of the projects tree.
enum SidebarItem: Hashable {
    case tab(AppTab)
    case project(ProjectRoute)
    case worktree(WorktreeRoute)
    /// A session listed under its worktree (by name: the `Session` value changes with every refresh).
    case session(WorktreeRoute, name: String)

    /// How many screens the item puts on the Projetos stack (project, then worktree, then session).
    var depth: Int {
        switch self {
        case .tab: 0
        case .project: 1
        case .worktree: 2
        case .session: 3
        }
    }

    /// The item one level up the tree (nil above a project).
    var parent: SidebarItem? {
        switch self {
        case .tab, .project: nil
        case .worktree(let w): .project(ProjectRoute(box: w.box, location: w.location))
        case .session(let w, _): .worktree(w)
        }
    }
}

/// Navigation state: one NavigationStack path per tab + deep links. The same state drives both layouts: the TabView on
/// compact width (one stack per tab) and the sidebar + detail on regular width (the detail shows the stack of `tab`).
@MainActor @Observable
final class Router {
    var tab: AppTab = .home
    var homePath = NavigationPath()
    /// The Inbox's stack (a session opened from a card goes here, so Back returns to the Inbox).
    var inboxPath = NavigationPath()
    /// The agents board's stack (a session opened from a card goes here).
    var boardPath = NavigationPath()
    var projectsPath = NavigationPath()
    /// Ajustes' stack (Faxina): in the router like the others, so picking the section again (or another one) resets it.
    var settingsPath = NavigationPath()

    /// The projects tree item picked in the sidebar (regular width): the bottom of what the Projetos stack shows.
    private(set) var projectsFocus: SidebarItem?

    /// Set by deep links / scanner / paste; the root presents the pairing sheet.
    var pendingPair: PendingPair?
    var showAddBox = false
    /// The first-run onboarding reached its pairing step: the root keeps it on screen after the box pairs, for "Tudo pronto!".
    var onboardingFinishing = false
    /// ⌘K / ⌘P: the command palette.
    var showPalette = false

    /// Set by the model: opens a session (deep link `pier://session?box=&name=` from widgets and Live Activities).
    var onOpenSession: ((String, String) -> Void)?
    /// Set by the model: the Review of a session's worktree (`pier://review?box=&name=`, the Live Activity's "Revisar").
    var onOpenReview: ((String, String) -> Void)?

    /// "box/session" of the session screen on top right now (in-app banners skip it).
    var visibleSession: String?

    init() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "startTab") {
        case "settings": tab = .settings
        case "projects": tab = .projects
        case "inbox": tab = .inbox
        case "board": tab = .board
        default: break
        }
        // Test hook: `-openBoard 1` starts on the agents board.
        if UserDefaults.standard.bool(forKey: "openBoard") { tab = .board }
        #endif
    }

    /// Push a route on the current tab's stack.
    func push<R: Hashable>(_ route: R) {
        switch tab {
        case .home: homePath.append(route)
        case .inbox: inboxPath.append(route)
        case .board: boardPath.append(route)
        case .projects: projectsPath.append(route)
        case .settings: settingsPath.append(route)
        }
    }

    /// Pop the screen on top of the current tab's stack.
    func popTop() {
        switch tab {
        case .home: if !homePath.isEmpty { homePath.removeLast() }
        case .inbox: if !inboxPath.isEmpty { inboxPath.removeLast() }
        case .board: if !boardPath.isEmpty { boardPath.removeLast() }
        case .projects: if !projectsPath.isEmpty { projectsPath.removeLast() }
        case .settings: if !settingsPath.isEmpty { settingsPath.removeLast() }
        }
    }

    /// Replace the screen on top of the current tab's stack by `route` (Compose -> Session).
    func replaceTop<R: Hashable>(with route: R) {
        popTop()
        push(route)
    }

    // MARK: sidebar (regular width)

    /// The sidebar's selection: the current section, or the project / worktree / session picked under Projetos.
    var sidebarSelection: SidebarItem {
        if tab == .projects, let projectsFocus { return projectsFocus }
        return .tab(tab)
    }

    /// Sidebar pick. A section shows its root (picking the current one again pops to it, like tapping a tab); a project,
    /// worktree or session goes on the Projetos stack above its parents, so Back walks up the tree.
    /// `session` is the live value for a `.session` item.
    func select(_ item: SidebarItem, session: Session? = nil) {
        switch item {
        case .tab(let t):
            tab = t
            switch t {
            case .home: homePath = NavigationPath()
            case .inbox: inboxPath = NavigationPath()
            case .board: boardPath = NavigationPath()
            case .projects: projectsPath = NavigationPath(); projectsFocus = nil
            case .settings: settingsPath = NavigationPath()
            }
        case .project(let p):
            tab = .projects
            projectsFocus = item
            projectsPath = NavigationPath([p])
        case .worktree(let w):
            tab = .projects
            projectsFocus = item
            var path = NavigationPath()
            path.append(ProjectRoute(box: w.box, location: w.location))
            path.append(w)
            projectsPath = path
        case .session(let w, _):
            guard let session else { return }
            tab = .projects
            projectsFocus = item
            var path = NavigationPath()
            path.append(ProjectRoute(box: w.box, location: w.location))
            path.append(w)
            path.append(SessionRoute(box: w.box, session: session))
            projectsPath = path
        }
    }

    /// Back in the detail went below the picked item: move the sidebar selection up the tree with it.
    func projectsPathChanged() {
        while let f = projectsFocus, f.depth > projectsPath.count { projectsFocus = f.parent }
    }

    func openSession(box: String, session: Session) {
        tab = .home
        homePath = NavigationPath()
        homePath.append(SessionRoute(box: box, session: session))
    }

    func openWorktree(box: String, location: String, worktree: String) {
        tab = .home
        homePath = NavigationPath()
        homePath.append(WorktreeRoute(box: box, location: location, worktree: worktree))
    }

    /// `trusted`: the URL is the person's own request (a Debug launch argument), not something another app handed over;
    /// a pairing link from outside is confirmed before anything is sent to the box it names.
    func handle(url: URL, trusted: Bool = false) {
        guard url.scheme?.lowercased() == "pier" else { return }
        switch url.host?.lowercased() {
        case "home":
            tab = .home
            homePath = NavigationPath()
            return
        case "session", "review":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let box = items.first(where: { $0.name == "box" })?.value,
               let name = items.first(where: { $0.name == "name" })?.value {
                if url.host?.lowercased() == "review" { onOpenReview?(box, name) } else { onOpenSession?(box, name) }
            }
            return
        default: break
        }
        if let link = try? PairingLink.parse(url.absoluteString) {
            pendingPair = PendingPair(link: link, confirm: !trusted)
        }
    }
}
