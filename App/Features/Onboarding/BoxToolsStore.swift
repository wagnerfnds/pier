import SwiftUI
import PierKit

/// The tools the boxes install from the app (`GET /v1/tools`, `POST /v1/tools/install`, capability `tools`): Claude Code,
/// Codex and the GitHub CLI per box, and the installs asked for here, followed every 2 s until they end. Then the box's
/// info (a new agent to start), its health cards and its accounts are read again.
@MainActor @Observable
final class BoxToolsStore {
    static let shared = BoxToolsStore()

    /// Box -> its tools, as last read.
    private(set) var tools: [String: [BoxTool]] = [:]
    /// "box/tool" of installs asked for here that the box has not finished yet.
    private(set) var asked: Set<String> = []
    @ObservationIgnored private var polling: [String: Task<Void, Never>] = [:]

    func load(box: String, model: AppModel) async {
        guard let conn = model.connection(for: box), conn.info?.has("tools") == true,
              let list = try? await BoxAPI(transport: conn.raw).tools() else { return }
        if tools[box] != list { tools[box] = list }
    }

    func tool(_ id: String, box: String) -> BoxTool? { tools[box]?.first { $0.id == id } }

    /// An install of `id` on `box` runs (or was just asked for).
    func installing(_ id: String, box: String) -> Bool {
        asked.contains("\(box)/\(id)") || tool(id, box: box)?.installing == true
    }

    /// Installs `ids` on `box` in the background; nil when the box took it, else why not.
    @discardableResult
    func install(_ ids: [String], box: String, model: AppModel) async -> String? {
        guard let conn = model.connection(for: box) else { return String(localized: "A box não está conectada.") }
        for id in ids { asked.insert("\(box)/\(id)") }
        do {
            tools[box] = try await BoxAPI(transport: conn.raw).installTools(ids)
            follow(box: box, model: model)
            return nil
        } catch {
            for id in ids { asked.remove("\(box)/\(id)") }
            return ComposeErrorText.message(error)
        }
    }

    private func follow(box: String, model: AppModel) {
        guard polling[box] == nil else { return }
        polling[box] = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self.load(box: box, model: model)
                let list = self.tools[box] ?? []
                if list.contains(where: \.installing) { continue }
                for t in list { self.asked.remove("\(box)/\(t.id)") }
                break
            }
            self?.polling[box] = nil
            // A new agent shows in the box's info; the cards and the accounts see what changed.
            if let conn = model.connection(for: box), let info = try? await BoxAPI(transport: conn.raw).info() { conn.info = info }
            await BoxHealthStore.shared.refresh(model: model, force: true)
            await AccountsCache.shared.load(box: box, model: model)
        }
    }
}

/// What a sign-in sheet is for (`.sheet(item:)`).
struct SignInRequest: Identifiable, Hashable {
    let box: String
    /// `claude`, `codex` or `gh`.
    let tool: String
    /// The account it signs in (an id of `GET /v1/accounts`; the box's default when nil), and its name for an added one.
    var account: String? = nil
    var accountName: String? = nil
    var id: String { "\(box)/\(tool)/\(account ?? "")" }
}

/// A tool's mark: the agents' glyph, a branch for the GitHub CLI.
struct ToolGlyph: View {
    let tool: String
    var size: CGFloat = 34

    var body: some View {
        if tool == "gh" {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(Theme.purple)
                .frame(width: size, height: size)
                .background(Theme.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                .accessibilityLabel("GitHub")
        } else {
            AgentGlyph(agent: tool, size: size)
        }
    }
}
