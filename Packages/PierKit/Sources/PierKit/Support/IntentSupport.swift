import Foundation

/// Counts of agent sessions by what the person cares about; feeds the spoken summary of "what are my agents doing?".
public struct AgentCounts: Sendable, Hashable {
    public var needsYou = 0
    public var working = 0
    public var finished = 0
    public var idle = 0

    public init(needsYou: Int = 0, working: Int = 0, finished: Int = 0, idle: Int = 0) {
        self.needsYou = needsYou
        self.working = working
        self.finished = finished
        self.idle = idle
    }

    /// Live agent sessions only (not exited, not services).
    public init(sessions: [Session]) {
        for s in sessions where s.isAgent && !s.exited {
            switch s.agentState {
            case .waiting: needsYou += 1
            case .running: working += 1
            case .finished: finished += 1
            case .idle: idle += 1
            default: break
            }
        }
    }

    /// From raw agent state strings ("waiting", "running", "finished", "idle").
    public init(items states: [String]) {
        for st in states {
            switch st {
            case "waiting": needsYou += 1
            case "running": working += 1
            case "finished": finished += 1
            case "idle": idle += 1
            default: break
            }
        }
    }

    public var total: Int { needsYou + working + finished + idle }

    public enum Language: Sendable { case pt, en }

    /// "2 precisam de você, 1 trabalhando" / "Nenhum agente ativo."
    public func summary(_ lang: Language) -> String {
        var parts: [String] = []
        switch lang {
        case .pt:
            if needsYou > 0 { parts.append(needsYou == 1 ? "1 precisa de você" : "\(needsYou) precisam de você") }
            if working > 0 { parts.append(working == 1 ? "1 trabalhando" : "\(working) trabalhando") }
            if finished > 0 { parts.append(finished == 1 ? "1 terminou" : "\(finished) terminaram") }
            if idle > 0 { parts.append(idle == 1 ? "1 parado" : "\(idle) parados") }
            return parts.isEmpty ? "Nenhum agente ativo." : parts.joined(separator: ", ") + "."
        case .en:
            if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
            if working > 0 { parts.append("\(working) working") }
            if finished > 0 { parts.append("\(finished) finished") }
            if idle > 0 { parts.append("\(idle) idle") }
            return parts.isEmpty ? "No active agents." : parts.joined(separator: ", ") + "."
        }
    }
}

/// Actionable-notification categories (`aps.category` for push, `categoryIdentifier` for local ones).
public enum NotificationCategoryID {
    /// A permission menu: Allow / Deny / Answer-in-app.
    public static let needsYouPermission = "NEEDS_YOU"
    /// A question or plan approval: open the app.
    public static let needsYouQuestion = "NEEDS_YOU_QUESTION"
    /// The agent finished: Review / Send a message.
    public static let finished = "FINISHED"
    /// A question (or plain menu) with `n` choices (2 to 4), as buttons "1" … "n": what pierd names when it could read
    /// the choices; the service extension swaps in a category whose buttons carry their words (docs/PUSH.md 4.3).
    public static func needsYouChoice(_ n: Int) -> String { "NEEDS_YOU_CHOICE_\(n)" }
    public static let choiceCounts = 2...4

    /// `nil` for states that do not notify.
    public static func category(state: AgentState?, ask: Ask?) -> String? {
        switch state {
        case .waiting: Ask.classify(ask) == .permission ? needsYouPermission : needsYouQuestion
        case .finished: finished
        default: nil
        }
    }
}
