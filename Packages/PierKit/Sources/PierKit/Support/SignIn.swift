import Foundation

/// Signing in to the box's agents and GitHub from the app, and installing them (`/v1/logins`, `/v1/tools`, docs/API.md
/// §2.10.1 and §2.13): where the sign-in sheet is at each state of the box's sign-in, a pasted code cleaned up, what a
/// health card's button does, and each tool's row in the onboarding's "Contas" step. Pure; the app puts the words to it.
public enum SignIn {
    /// The tools the app installs and signs in to, in the order it lists them.
    public static let tools = ["claude", "codex", "gh"]

    /// "Claude Code", "Codex", "GitHub".
    public static func name(of tool: String) -> String {
        switch tool {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "gh": "GitHub"
        default: tool
        }
    }

    // MARK: the sheet

    /// Where the sign-in sheet is.
    public enum Step: Sendable, Hashable {
        /// The box starts the CLI; nothing to show yet.
        case starting
        /// Open the page (a device sign-in: and type the code shown here there).
        case open
        /// Open the page, then paste back the code it shows (Claude Code).
        case paste
        /// The code went in: the CLI finishes.
        case confirming
        case done
        case failed(String?)
    }

    public static func step(_ login: Login?) -> Step {
        guard let l = login else { return .starting }
        switch l.state {
        case .starting, .unknown: return .starting
        case .openLink: return l.needsCode ? .paste : .open
        case .enterCode: return .paste
        case .waiting: return .confirming
        case .done: return .done
        case .failed: return .failed(l.error)
        }
    }

    /// A code pasted from the sign-in page: its first line with words, without the spaces around it (a paste can bring a
    /// line break or a space along). Claude Code's page shows `code#state`, which goes back whole.
    public static func cleanCode(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    // MARK: the health cards

    /// What a health card's button does.
    public enum Action: Sendable, Hashable {
        case signIn(tool: String, account: String?)
        case install([String])
    }

    /// The button a box's health card gets, on a box that signs in (`logins`) or installs (`tools`) from the app; nil for a
    /// card only the command fixes. A card from an older pierd names its tool only in its name.
    public static func action(for issue: BoxHealth.Issue, logins: Bool, tools: Bool) -> Action? {
        switch issue.kind {
        case .agentSignIn(let agent):
            guard logins, let tool = issue.tool ?? tool(named: agent) else { return nil }
            return .signIn(tool: tool, account: issue.account)
        case .tool(let name) where name == "gh":
            return tools ? .install(["gh"]) : nil
        case .noAgents:
            return tools ? .install(["claude", "codex"]) : nil
        default:
            return nil
        }
    }

    /// The tool a sign-in check's name is about ("Codex sign-in" → codex), for a box that does not say.
    static func tool(named agent: String) -> String? {
        switch agent {
        case "Claude Code": "claude"
        case "Codex": "codex"
        case "GitHub": "gh"
        default: nil
        }
    }

    // MARK: the onboarding's "Contas"

    public enum Status: Sendable, Hashable {
        case missing
        case installing
        case installFailed(String)
        case signedOut
        case signedIn
        /// Installed; whether it is signed in cannot be told (Claude Code on a Mac keeps its login in the Keychain).
        case unknown
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public let tool: String
        public let status: Status
        /// The account a sign-in goes to: the agent's default one (nil for GitHub, or when the box lists none).
        public let account: String?
        public var id: String { tool }

        public init(tool: String, status: Status, account: String? = nil) {
            self.tool = tool
            self.status = status
            self.account = account
        }
    }

    /// Claude Code, Codex and GitHub as the box has them: installed or not (`GET /v1/tools`), and signed in or not, an
    /// agent by its default account (`GET /v1/accounts`), GitHub by doctor's "GitHub sign-in".
    public static func rows(tools: [BoxTool], accounts: [AgentAccount], doctor: [DoctorCheck]) -> [Row] {
        Self.tools.map { id in
            if let t = tools.first(where: { $0.id == id }) {
                if t.installing { return Row(tool: id, status: .installing) }
                if !t.installed { return Row(tool: id, status: t.error.map { .installFailed($0) } ?? .missing) }
            }
            if id != "gh", let a = accounts.first(where: { $0.agent == id && $0.isDefault }) ?? accounts.first(where: { $0.agent == id && $0.builtin }) {
                let status: Status = a.signedInKnown ? (a.signedIn ? .signedIn : .signedOut) : .unknown
                return Row(tool: id, status: status, account: a.id)
            }
            let check = doctor.first { c in
                c.area == "Agents" && (c.tool == id && (c.account == nil || c.account == id) || c.name == "\(name(of: id)) sign-in")
            }
            return Row(tool: id, status: status(of: check))
        }
    }

    static func status(of check: DoctorCheck?) -> Status {
        switch check?.status {
        case "ok": .signedIn
        case "warn", "fail": .signedOut
        default: .unknown
        }
    }

    /// Every row signed in: nothing left for the step to do.
    public static func allSet(_ rows: [Row]) -> Bool { rows.allSatisfy { $0.status == .signedIn } }
}
