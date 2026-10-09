import AppIntents
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import Foundation
import PierKit

// Intents for Live Activity buttons and Shortcuts. Compiled into the app AND the widget extension (App/Shared).
// Names and parameters are stable: other code (App/Intents) reuses them.

/// Answers a permission prompt of an agent session: sends the option digit the screen's menu assigns to Allow / Deny.
enum PermissionAnswer: Sendable {
    case allow, deny

    /// Reads the session's screen, maps the menu (docs/API.md §5.3) and sends the option's own digit.
    /// Returns the key sent, or throws a user-facing error.
    static func send(_ answer: PermissionAnswer, box: String, session: String) async throws -> String {
        guard let access = BoxAccess.load(), let client = access.client(box: box) else { throw SessionIntentError.notPaired }
        let screen: String
        do { screen = try await client.screen(session: session, history: 0) } catch { throw SessionIntentError.unreachable }
        guard let actions = MenuParser.actions(in: screen) else { throw SessionIntentError.noMenu }
        let key: String? = actions.compactMap { a -> String? in
            switch (answer, a) {
            case (.allow, .allow(let k)): k
            case (.deny, .deny(let k)): k
            default: nil
            }
        }.first
        guard let key else { throw SessionIntentError.noMenu }
        do { _ = try await client.send(session: session, .key(key)) } catch { throw SessionIntentError.unreachable }
        await SessionActivityBridge.answered(box: box, session: session)
        return key
    }
}

enum SessionIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notPaired, unreachable, noMenu

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired: "Nenhuma box pareada."
        case .unreachable: "Não foi possível alcançar a box."
        case .noMenu: "O agente não está mais pedindo permissão."
        }
    }
}

struct AllowPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Permitir"
    static let description = IntentDescription("Permite a ação que o agente está pedindo.")
    /// Allowing runs code on the box: the lock-screen button asks to unlock first, like the push action (`.authenticationRequired`).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Box") var box: String
    @Parameter(title: "Sessão") var session: String

    init() {}
    init(box: String, session: String) { self.box = box; self.session = session }

    func perform() async throws -> some IntentResult {
        _ = try await PermissionAnswer.send(.allow, box: box, session: session)
        return .result()
    }
}

struct DenyPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Negar"
    static let description = IntentDescription("Nega a ação que o agente está pedindo.")

    @Parameter(title: "Box") var box: String
    @Parameter(title: "Sessão") var session: String

    init() {}
    init(box: String, session: String) { self.box = box; self.session = session }

    func perform() async throws -> some IntentResult {
        _ = try await PermissionAnswer.send(.deny, box: box, session: session)
        return .result()
    }
}

/// Opens the app on a session (deep link `pier://session?box=&name=`).
struct OpenSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir sessão"
    static let description = IntentDescription("Abre uma sessão de agente no Pier.")
    static let openAppWhenRun = true

    @Parameter(title: "Box") var box: String
    @Parameter(title: "Sessão") var session: String

    init() {}
    init(box: String, session: String) { self.box = box; self.session = session }

    func perform() async throws -> some IntentResult {
        PendingDeepLink.set(Shared.sessionURL(box: box, name: session))
        return .result()
    }
}

/// A deep link left in the App Group by an intent; the app opens it when it becomes active.
enum PendingDeepLink {
    private static let key = "pendingDeepLink"
    static func set(_ url: URL) { Shared.defaults.set(url.absoluteString, forKey: key) }
    static func take() -> URL? {
        let d = Shared.defaults
        guard let s = d.string(forKey: key) else { return nil }
        d.removeObject(forKey: key)
        return URL(string: s)
    }
}

/// After a button answered the prompt, flip the running activity out of "waiting" right away (the box will confirm on the
/// next refresh). No Live Activities on the Mac.
enum SessionActivityBridge {
    static func answered(box: String, session: String) async {
        #if !targetEnvironment(macCatalyst)
        for a in Activity<SessionActivityAttributes>.activities where a.attributes.box == box && a.attributes.session == session {
            var s = a.content.state
            guard s.phase == .waiting else { continue }
            s.phase = .running; s.since = Date(); s.ask = nil; s.hasMenu = false; s.step = nil
            await a.update(ActivityContent(state: s, staleDate: nil))
        }
        #endif
    }
}
