import SwiftUI
import PierKit

/// The workspace's first tab, "Agentes": a box to start an agent here, as Claude's and Codex's home screens open on one,
/// and the agents that run in the project (in this worktree, for one that is not the main checkout) below it, a click
/// from their conversation. The box keeps what was typed while the app runs (`WorkspaceState.compose`), apart from the
/// composer screen's draft.
struct StartPane: View {
    let project: Location
    let worktree: Worktree
    let ref: WorkspaceRef
    @Bindable var compose: ComposeModel

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    @FocusState private var focused: Bool
    @State private var dropping = false

    private var conn: BoxConnection? { model.connection(for: ref.box) }
    private var name: String { prefs.displayName(box: ref.box, location: project.name) }

    /// The project's agents (this worktree's, outside the main checkout), the ones that need the person first.
    private var agents: [Session] {
        ProjectAgents.list(conn?.sessions ?? [], project: project.name, worktree: worktree.main == true ? nil : ref.execLocation)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("O que vamos fazer em \(name)?")
                        .font(.system(size: Platform.isMac ? 24 : 26, weight: .semibold)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.system(size: Density.small + 1)).foregroundStyle(Theme.textDim)
                }
                promptCard
                if let error = compose.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: Density.small + 1))
                        .foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
                if compose.prompt.isEmpty { suggestions }
                if !agents.isEmpty { agentList }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, Platform.isMac ? 56 : 32).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.card)
        .task {
            compose.bind(model)
            // On the Mac the box takes the keyboard when the tab shows: type and ⌘↩.
            if Platform.isMac {
                try? await Task.sleep(for: .milliseconds(250))
                focused = true
            }
        }
        .accessibilityIdentifier("workspace-start")
    }

    /// Where the agent will run, in one line.
    private var subtitle: String {
        if worktree.main == true {
            return compose.isNew ? String(localized: "Numa worktree nova a partir de \(compose.effectiveBase.isEmpty ? (worktree.branch ?? "main") : compose.effectiveBase), isolada do resto")
                                 : String(localized: "No checkout principal (\(worktree.branch ?? worktree.name))")
        }
        return compose.isNew ? String(localized: "Numa worktree nova, isolada desta")
                             : String(localized: "Na worktree \(worktree.name) (\(worktree.branch ?? worktree.name))")
    }

    // MARK: the box

    private var promptCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $compose.prompt)
                    .focused($focused)
                    .font(.system(size: Platform.isMac ? 14 : 16))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: Platform.isMac ? 96 : 110, maxHeight: 260)
                    .padding(.horizontal, 10).padding(.top, 8)
                    .onChange(of: compose.prompt) { _, _ in compose.promptChanged() }
                    .accessibilityIdentifier("start-prompt")
                if compose.prompt.isEmpty {
                    Text("Descreva a tarefa, o bug ou a ideia…")
                        .font(.system(size: Platform.isMac ? 14 : 16)).foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 15).padding(.top, 16).allowsHitTesting(false)
                }
            }
            if !compose.photos.isEmpty {
                ComposeAttachmentStrip(compose: compose).padding(.horizontal, 12).padding(.top, 6)
            }
            HStack(spacing: 8) {
                ComposeAttachButton(compose: compose) {
                    Image(systemName: "paperclip").font(.system(size: Density.small + 2, weight: .semibold)).foregroundStyle(Theme.textDim)
                        .frame(width: 28, height: 28).background(Theme.cardRaised, in: Circle())
                }
                .help("Anexar foto ou arquivo (ou arraste para cá)")
                agentMenu
                targetMenu
                Spacer(minLength: 8)
                if compose.stage.isBusy { ProgressView().controlSize(.small) }
                Button(action: start) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(compose.canSubmit ? Theme.accent : Theme.textFaint, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!compose.canSubmit)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Iniciar (⌘↩)")
                .accessibilityLabel("Iniciar agente")
                .accessibilityIdentifier("start-submit")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(dropping ? Theme.accent : focused ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: dropping ? 2 : 1))
        .composeDropTarget(compose, isTargeted: $dropping)
    }

    private var agentMenu: some View {
        Menu {
            ForEach(compose.agents) { a in
                Button { compose.selectAgent(a.id) } label: {
                    if a.id == compose.agentID { Label(agentName(a), systemImage: "checkmark") } else { Text(agentName(a)) }
                }
            }
            if let a = compose.agent, a.canPickModel, let models = a.models, !models.isEmpty {
                Divider()
                Picker(S("Modelo"), selection: Binding(get: { compose.model ?? "" }, set: { compose.model = $0.isEmpty ? nil : $0 })) {
                    Text("Padrão").tag("")
                    ForEach(models, id: \.self) { m in Text(ChoiceNames.model(m)).tag(m) }
                }
            }
            if let a = compose.agent, a.canPickEffort, let efforts = a.efforts, !efforts.isEmpty {
                Picker(S("Esforço"), selection: Binding(get: { compose.effort ?? "" }, set: { compose.effort = $0.isEmpty ? nil : $0 })) {
                    Text("Padrão").tag("")
                    ForEach(efforts, id: \.self) { e in Text(ChoiceNames.effort(e)).tag(e) }
                }
            }
        } label: {
            chip {
                AgentGlyph(agent: compose.agentID, size: 18)
                Text(compose.agent.map(agentName) ?? S("Agente"))
                if let m = compose.model, !m.isEmpty { Text(ChoiceNames.model(m)).foregroundStyle(Theme.textFaint) }
            }
        }
        .plainMenu()
        .accessibilityIdentifier("start-agent")
    }

    /// Where it runs: a worktree of its own (the default from the main checkout), or here.
    private var targetMenu: some View {
        Menu {
            Button { compose.selectTarget(.newWorktree) } label: {
                if compose.isNew { Label("Worktree nova", systemImage: "checkmark") } else { Text("Worktree nova") }
            }
            Button { compose.selectTarget(.existing(worktree.name)) } label: {
                let here = worktree.main == true ? S("Checkout principal") : S("Nesta worktree")
                if !compose.isNew { Label(here, systemImage: "checkmark") } else { Text(here) }
            }
        } label: {
            chip {
                Image(systemName: compose.isNew ? "plus.square.on.square" : "arrow.triangle.branch")
                    .font(.system(size: Density.small, weight: .semibold)).foregroundStyle(Theme.textDim)
                Text(compose.isNew ? S("Worktree nova") : worktree.main == true ? S("Checkout principal") : S("Nesta worktree"))
            }
        }
        .plainMenu()
        .accessibilityIdentifier("start-target")
    }

    private func chip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            content()
            Image(systemName: "chevron.down").font(.system(size: Density.small - 2, weight: .bold)).foregroundStyle(Theme.textFaint)
        }
        .font(.system(size: Density.small + 1, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Theme.cardRaised, in: Capsule())
    }

    // MARK: suggestions

    /// A few ways to start, filled in on a tap (and editable before Start).
    private var suggestions: some View {
        let picks = [
            S("Explique como este projeto está organizado e como rodá-lo"),
            S("Rode os testes e corrija o que estiver falhando"),
            S("Revise as mudanças ainda não commitadas e aponte problemas"),
        ]
        return FlowLayout(spacing: 8) {
            ForEach(picks, id: \.self) { p in
                Button {
                    compose.prompt = p
                    compose.promptChanged()
                    focused = true
                } label: {
                    Text(p).font(.system(size: Density.small + 1)).foregroundStyle(Theme.textDim).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(Theme.stroke))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: the agents here

    private var agentList: some View {
        let all = conn?.sessions ?? []
        let shown = Array(agents.prefix(12))
        return VStack(alignment: .leading, spacing: 6) {
            Text(worktree.main == true ? "Agentes neste projeto" : "Agentes nesta worktree")
                .font(.system(size: Density.small, weight: .semibold)).foregroundStyle(Theme.textDim)
                .padding(.top, 12)
            VStack(spacing: 0) {
                ForEach(shown, id: \.name) { s in
                    Button { open(s) } label: {
                        HStack(spacing: 10) {
                            AgentGlyph(agent: DisplayNames.agent(of: s), size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(DisplayNames.sessionName(s, among: all)).font(.system(size: Density.text)).foregroundStyle(Theme.text).lineLimit(1)
                                if worktree.main == true, let l = s.location, l != project.name {
                                    Text(verbatim: String(l.dropFirst(project.name.count + 1))).font(.system(size: Density.small)).foregroundStyle(Theme.textFaint).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            if let st = DashState(s) {
                                StateDot(state: st)
                                Text(st.title).font(.system(size: Density.small)).foregroundStyle(st.color)
                            } else {
                                Text("Encerrada").font(.system(size: Density.small)).foregroundStyle(Theme.textFaint)
                            }
                            Text(Fmt.elapsed(since: s.stateSince ?? s.created)).font(.system(size: Density.small).monospacedDigit())
                                .foregroundStyle(Theme.textFaint).frame(minWidth: 34, alignment: .trailing)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("start-agent-\(s.name)")
                    if s.name != shown.last?.name { Divider().overlay(Theme.stroke).padding(.leading, 44) }
                }
            }
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
        }
    }

    // MARK: actions

    private func agentName(_ a: AgentPreset) -> String { a.name.isEmpty ? DisplayNames.agentLabel(a.id) : a.name }

    /// Start: the agent's conversation opens in its place in the projects' tree (the sidebar follows it there).
    private func start() {
        guard compose.canSubmit else { return }
        Task {
            guard let s = await compose.submit() else { return }
            compose.prompt = ""
            compose.photos = []
            compose.title = ""
            compose.resetName()
            open(s)
        }
    }

    private func open(_ s: Session) {
        let loc = s.location ?? project.name
        let wt = loc.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init)
        let route = WorktreeRoute(box: ref.box, location: project.name, worktree: wt ?? (project.worktrees?.first { $0.main == true }?.name ?? project.name))
        router.select(.session(route, name: s.name), session: s)
    }
}
