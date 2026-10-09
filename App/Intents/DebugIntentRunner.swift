#if DEBUG
import SwiftUI
import UserNotifications
import AppIntents
import PierKit

/// Test hooks (Siri is not scriptable). Launch args, e.g.:
///   -runIntent status | task | send | allow | deny | postNotif | notifAction
///   -intentProject sandbox  -intentPrompt "..."  -intentSession box/name  -intentText "..."  -notifActionID ALLOW
@MainActor @Observable
final class DebugIntentState {
    static let shared = DebugIntentState()
    var dialog: String?
    var items: [SessionEntity] = []
    var counts = AgentCounts()
}

enum DebugIntentRunner {
    @MainActor
    static func runIfRequested(model: AppModel) async {
        let d = UserDefaults.standard
        guard let which = d.string(forKey: "runIntent") else { return }
        func out(_ s: String) {
            print("[intent] \(s)"); fflush(stdout)
            let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("intent.log")
            let line = Data("\(s)\n".utf8)
            if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: u) }
        }
        func session() -> (box: String, name: String)? {
            guard let s = d.string(forKey: "intentSession") else { return nil }
            let p = s.split(separator: "/", maxSplits: 1).map(String.init)
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        do {
            switch which {
            case "status":
                let g = try await AgentsStatusIntent.gather()
                _ = try await AgentsStatusIntent().perform()
                DebugIntentState.shared.dialog = g.text
                DebugIntentState.shared.items = g.items
                DebugIntentState.shared.counts = g.counts
                out("status: \(g.text)")
                for e in g.items { out("  \(e.id) | \(e.title) | \(e.project) | \(e.state)") }
            case "projects":
                let ps = try await IntentCatalog.projects()
                out("projects: " + ps.map { "\($0.id)=\($0.name)" }.joined(separator: ", "))
                out("agents: " + (await IntentCatalog.agents()).map(\.id).joined(separator: ", "))
            case "task":
                let ps = try await IntentCatalog.projects()
                let want = d.string(forKey: "intentProject") ?? ""
                guard let p = ps.first(where: { $0.location == want || $0.name == want }) else { out("project not found: \(want) in \(ps.map(\.id))"); return }
                let i = CreateTaskIntent()
                i.project = p
                i.prompt = d.string(forKey: "intentPrompt") ?? "diga olá"
                if let a = d.string(forKey: "intentAgent") { i.agent = AgentEntity(id: a, name: a) }
                i.openInApp = false
                _ = try await i.perform()
                out("task created in \(p.id)")
            case "send":
                guard let s = session() else { out("-intentSession box/name required"); return }
                let i = SendMessageIntent()
                i.session = SessionEntity(id: "\(s.box)/\(s.name)", box: s.box, session: s.name, title: s.name, project: "", agent: "", state: "idle")
                i.text = d.string(forKey: "intentText") ?? "ok"
                _ = try await i.perform()
                out("message queued")
            case "allow", "deny":
                guard let s = session() else { out("-intentSession box/name required"); return }
                let e = SessionEntity(id: "\(s.box)/\(s.name)", box: s.box, session: s.name, title: s.name, project: "", agent: "", state: "waiting")
                if which == "allow" { let i = AllowAgentRequestIntent(); i.session = e; _ = try await i.perform() }
                else { let i = DenyAgentRequestIntent(); i.session = e; _ = try await i.perform() }
                out("\(which) done")
            case "postNotif":
                // Real session data -> the same notification the transition code posts (a question's choices as buttons
                // included). `-intentProvisional 1` asks quietly (no system prompt); the default asks like the app does.
                guard let s = session() else { out("-intentSession box/name required"); return }
                let access = try HeadlessBoxes.box(s.box)
                guard let sess = try await access.client.sessions().first(where: { $0.name == s.name }) else { out("no such session"); return }
                let quiet = d.bool(forKey: "intentProvisional")
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: quiet ? [.alert, .sound, .badge, .provisional] : [.alert, .sound, .badge])
                if d.double(forKey: "intentDelay") > 0 { try? await Task.sleep(for: .seconds(d.double(forKey: "intentDelay"))) }
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                let options = sess.agentState == .waiting ? await ChoiceOptions.fetch(client: access.client, session: sess) : nil
                await Notifications.post(box: s.box, session: sess, to: sess.agentState, showBox: true, options: options)
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications().first
                let category = delivered?.request.content.categoryIdentifier ?? NotificationCategoryID.category(state: sess.agentState, ask: sess.ask) ?? "-"
                let buttons = await UNUserNotificationCenter.current().notificationCategories().first { $0.identifier == category }?.actions.map(\.title) ?? []
                let line = "auth=\(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus.rawValue) posted \(sess.agentState?.rawValue ?? "?") category=\(category) buttons=\(buttons.joined(separator: " | "))"
                out(line)
                DebugIntentState.shared.dialog = line
            case "notifDelivered":
                // What is in Notification Center right now, with the buttons each one's category offers: how a push sent
                // with `xcrun simctl push` (through the service extension) is checked.
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                let categories = await UNUserNotificationCenter.current().notificationCategories()
                var lines: [String] = []
                for n in delivered {
                    let c = n.request.content
                    let buttons = categories.first { $0.identifier == c.categoryIdentifier }?.actions.map(\.title) ?? []
                    lines.append("\(c.title) | category=\(c.categoryIdentifier) buttons=\(buttons.joined(separator: " | "))")
                }
                let line = lines.isEmpty ? "delivered: none" : "delivered: " + lines.joined(separator: "\n")
                out(line)
                DebugIntentState.shared.dialog = line
            case "notifAction":
                guard let s = session() else { out("-intentSession box/name required"); return }
                let id = d.string(forKey: "notifActionID") ?? "ALLOW"
                // A choice button needs the options the notification carried: read them like the transition code does.
                var options: [String]?
                if NotificationChoices.index(of: id) != nil, let access = try? HeadlessBoxes.box(s.box),
                   let sess = try? await access.client.sessions().first(where: { $0.name == s.name }) {
                    options = await ChoiceOptions.fetch(client: access.client, session: sess)
                }
                let r = await model.notifications.handle(action: id, box: s.box, session: s.name, location: nil, text: d.string(forKey: "intentText"), options: options)
                out("action \(id) -> \(r)")
                DebugIntentState.shared.dialog = "action \(id) -> \(r)"
            default:
                out("unknown intent \(which)")
            }
        } catch {
            out("ERROR \(error)")
        }
    }
}

struct DebugSnippetOverlay: View {
    @State private var state = DebugIntentState.shared
    var body: some View {
        if let dialog = state.dialog {
            VStack(spacing: 12) {
                Text(dialog).font(.headline)
                AgentsSnippetView(items: state.items, counts: state.counts)
            }
            .padding(14)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color.black.opacity(0.5))
            .onTapGesture { state.dialog = nil }
        }
    }
}
#endif
