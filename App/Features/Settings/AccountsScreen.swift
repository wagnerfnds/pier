import SwiftUI
import PierKit

/// A box's settings page on the navigation stack (so a screen they open, such as the sign-in terminal, comes back to them).
struct BoxSettingsRoute: Hashable {
    enum Page: Hashable { case projects, accounts, variables, mcp }
    let box: String
    let page: Page
}

struct BoxSettingsDestination: View {
    let route: BoxSettingsRoute
    var body: some View {
        switch route.page {
        case .projects: BoxProjectsSettingsScreen(box: route.box)
        case .accounts: AccountsScreen(box: route.box)
        case .variables: BoxVariablesScreen(box: route.box)
        case .mcp: MCPServersScreen(box: route.box)
        }
    }
}

/// A box's Claude Code and Codex accounts (`/v1/accounts`): each subscription in a folder of its own (CLAUDE_CONFIG_DIR /
/// CODEX_HOME, the documented way to keep logins apart), signed in from the app (`SignInSheet`, through the browser; a
/// terminal in the app on a box without `logins`), one of them the box's default, any of them chosen per project (the
/// project's screen). Limits per account are on the Home.
struct AccountsScreen: View {
    let box: String

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var accounts: [AgentAccount] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var adding: String?
    @State private var newName = ""
    @State private var removing: AgentAccount?
    @State private var signIn: SignInRequest?

    private var conn: BoxConnection? { model.connection(for: box) }
    private var api: BoxAPI? { conn.map { BoxAPI(transport: $0.raw) } }
    /// The box signs in from the app (`/v1/logins`); older ones open the sign-in's terminal.
    private var signsIn: Bool { conn?.info?.has("logins") == true }

    var body: some View {
        Form {
            ForEach(["claude", "codex"], id: \.self) { agent in
                Section {
                    ForEach(accounts.filter { $0.agent == agent }) { a in row(a) }
                    Button { newName = ""; adding = agent } label: { Label("Adicionar conta", systemImage: "plus.circle") }
                        .accessibilityIdentifier("account-add-\(agent)")
                } header: {
                    HStack(spacing: 6) { AgentGlyph(agent: agent, size: 16); Text(agent == "claude" ? "Claude Code" : "Codex") }
                } footer: {
                    if agent == "claude" {
                        Text("Cada conta é uma pasta própria do Claude Code (CLAUDE_CONFIG_DIR), com login, configurações e histórico separados, como a documentação do Claude Code recomenda para várias contas.")
                    } else {
                        Text("Cada conta é uma pasta própria do Codex (CODEX_HOME), com o próprio login.")
                    }
                }
                .listRowBackground(Theme.card)
            }
            if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
        }
        .pierBackground()
        .navigationTitle("Contas em \(box)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .alert("Nova conta", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            TextField("Nome (ex.: Trabalho)", text: $newName)
            Button("Criar e entrar") { if let a = adding { Task { await add(agent: a) } } }.keyboardShortcut(.defaultAction)
            Button("Cancelar", role: .cancel) {}
        } message: {
            if signsIn { Text("Depois de criar, você entra na conta pelo navegador.") } else { Text("Depois de criar, um terminal abre na box para você entrar na conta.") }
        }
        .sheet(item: $signIn) { r in
            SignInSheet(request: r, openTerminal: { s in router.push(SessionRoute(box: box, session: s)) }, onDone: { Task { await load() } })
                .environment(model)
        }
        .confirmationDialog("Remover “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remover conta", role: .destructive) { if let a = removing { Task { await remove(a) } } }
        } message: { Text("A pasta da conta é apagada da box, com o login. Os projetos que a usavam voltam para a conta padrão.") }
    }

    private func row(_ a: AgentAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(a.name).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                if a.isDefault {
                    Text("padrão").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.accent.opacity(0.12), in: Capsule())
                }
                Spacer()
                if !a.signedInKnown {
                    EmptyView()
                } else if a.signedIn {
                    Label("conectada", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(Theme.green)
                } else {
                    Label("sem login", systemImage: "exclamationmark.circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(Theme.orange)
                }
            }
            MonoText(a.dir, size: 11, color: Theme.textFaint).lineLimit(1).truncationMode(.middle)
            if let t = Accounts.tightest(a.limits) {
                Text("\(Accounts.windowLabel(t)): \(Int(t.usedPercent.rounded()))% usado").font(.caption).foregroundStyle(Theme.textDim)
            }
            if !a.projects.isEmpty {
                Text(a.projects.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
            }
            HStack(spacing: 14) {
                Button { Task { await login(a) } } label: { Label(a.signedIn && a.signedInKnown ? "Entrar de novo" : "Entrar", systemImage: "person.badge.key") }
                    .accessibilityIdentifier("account-login-\(a.id)")
                if !a.isDefault {
                    Button { Task { await makeDefault(a) } } label: { Label("Tornar padrão", systemImage: "checkmark.circle") }
                        .accessibilityIdentifier("account-default-\(a.id)")
                }
                if !a.builtin {
                    Button(role: .destructive) { removing = a } label: { Label("Remover", systemImage: "trash") }
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("account-\(a.id)")
    }

    private func load() async {
        guard let api else { return }
        do { accounts = try await api.accounts(); error = nil } catch { self.error = ComposeErrorText.message(error) }
        loaded = true
    }

    private func add(agent: String) async {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard let api, !n.isEmpty else { return }
        do {
            let a = try await api.addAccount(agent: agent, name: n)
            await load()
            await login(a)
        } catch { self.error = ComposeErrorText.message(error) }
    }

    /// The sign-in: the sheet where the box signs in from the app, else the terminal where the person signs in.
    private func login(_ a: AgentAccount) async {
        if signsIn {
            signIn = SignInRequest(box: box, tool: a.agent, account: a.id, accountName: a.builtin ? nil : a.name)
            return
        }
        guard let api, let conn else { return }
        do {
            let s = try await api.loginAccount(id: a.id)
            await conn.refreshSessions()
            router.push(SessionRoute(box: box, session: s))
        } catch { self.error = ComposeErrorText.message(error) }
    }

    private func makeDefault(_ a: AgentAccount) async {
        guard let api else { return }
        do { _ = try await api.makeDefaultAccount(id: a.id); await load() } catch { self.error = ComposeErrorText.message(error) }
    }

    private func remove(_ a: AgentAccount) async {
        guard let api else { return }
        do { try await api.removeAccount(id: a.id); await load(); await conn?.refreshLocations() } catch { self.error = ComposeErrorText.message(error) }
    }
}

/// The box's variables (every project gets them) with a note on what each is for, and pierd's skills that tell Claude
/// Code and Codex about them (`/v1/env`, `/v1/skills`). Secret-looking values are hidden until asked for.
struct BoxVariablesScreen: View {
    let box: String

    @Environment(AppModel.self) private var model
    @State private var vars = BoxVariables()
    @State private var saved = BoxVariables()
    @State private var skills: [BoxSkill] = []
    @State private var revealed: Set<String> = []
    @State private var newKey = ""
    @State private var saving = false
    @State private var error: String?

    private var api: BoxAPI? { model.connection(for: box).map { BoxAPI(transport: $0.raw) } }
    private var keys: [String] { vars.env.keys.sorted() }

    var body: some View {
        Form {
            Section {
                if keys.isEmpty { Text("Nenhuma variável ainda.").font(.subheadline).foregroundStyle(Theme.textDim) }
                ForEach(keys, id: \.self) { k in variableRow(k) }
                HStack {
                    TextField("NOVA_VARIAVEL", text: $newKey).font(.mono(14)).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onSubmit(addKey)
                        .accessibilityIdentifier("var-new-key")
                    Button("Adicionar", action: addKey).disabled(!Accounts.isValidVariable(newKey) || vars.env[newKey] != nil)
                        .accessibilityIdentifier("var-add")
                }
            } header: { Text("Variáveis da box") } footer: {
                Text("Todo projeto da box recebe estas variáveis (agentes, terminais, serviços). O env do próprio projeto tem prioridade. A nota diz aos agentes para que serve cada uma; o valor nunca vai para as skills.")
            }
            .listRowBackground(Theme.card)

            Section {
                ForEach(skills) { s in
                    Toggle(isOn: Binding(get: { s.installed }, set: { v in Task { await setSkill(s, v) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).foregroundStyle(Theme.text)
                            Text(s.description).font(.caption).foregroundStyle(Theme.textDim)
                        }
                    }
                    .accessibilityIdentifier("skill-\(s.id)")
                }
            } header: { Text("Skills para Claude e Codex") } footer: {
                Text("Instaladas em cada conta do Claude Code (skills/) e para o Codex (~/.agents/skills), atualizadas quando as variáveis mudam. Uma skill sua com o mesmo nome não é tocada.")
            }
            .listRowBackground(Theme.card)
            if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
        }
        .pierBackground()
        .navigationTitle("Variáveis e skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Salvar") { Task { await save() } }.disabled(vars == saved).accessibilityIdentifier("vars-save")
                }
            }
        }
        .task { await load() }
    }

    private func variableRow(_ k: String) -> some View {
        let secret = Accounts.isSecret(k) && !revealed.contains(k)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(k).font(.mono(13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if Accounts.isSecret(k) {
                    Button { if revealed.contains(k) { revealed.remove(k) } else { revealed.insert(k) } } label: {
                        Image(systemName: revealed.contains(k) ? "eye.slash" : "eye")
                    }.buttonStyle(.borderless).accessibilityLabel("Mostrar valor")
                }
                Button(role: .destructive) { vars.env[k] = nil; vars.notes[k] = nil } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless).tint(Theme.red).accessibilityLabel("Remover \(k)")
            }
            Group {
                if secret {
                    SecureField("valor", text: binding(k))
                } else {
                    TextField("valor", text: binding(k))
                }
            }
            .font(.mono(13)).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("var-value-\(k)")
            TextField("para que serve (os agentes leem)", text: Binding(get: { vars.notes[k] ?? "" }, set: { vars.notes[k] = $0 }))
                .font(.caption).foregroundStyle(Theme.textDim)
                .accessibilityIdentifier("var-note-\(k)")
        }
        .padding(.vertical, 3)
    }

    private func binding(_ k: String) -> Binding<String> { Binding(get: { vars.env[k] ?? "" }, set: { vars.env[k] = $0 }) }

    private func addKey() {
        let k = newKey.trimmingCharacters(in: .whitespaces)
        guard Accounts.isValidVariable(k), vars.env[k] == nil else { return }
        vars.env[k] = ""
        newKey = ""
    }

    private func load() async {
        guard let api else { return }
        do {
            async let v = api.boxVariables()
            async let s = api.skills()
            vars = try await v; saved = vars
            skills = (try? await s) ?? []
            error = nil
        } catch { self.error = ComposeErrorText.message(error) }
    }

    private func save() async {
        guard let api else { return }
        saving = true
        defer { saving = false }
        do {
            vars = try await api.setBoxVariables(vars); saved = vars
            skills = (try? await api.skills()) ?? skills
            error = nil
            model.toast = AppToast(text: String(localized: "Variáveis salvas. Valem para os agentes e terminais que começarem agora."), symbol: "checkmark.circle")
        } catch { self.error = ComposeErrorText.message(error) }
    }

    private func setSkill(_ s: BoxSkill, _ on: Bool) async {
        guard let api else { return }
        do { skills = try await api.setSkill(id: s.id, installed: on); error = nil } catch { self.error = ComposeErrorText.message(error) }
    }
}

/// The boxes' accounts, read by the screens that offer to choose one (a section with no rows yet cannot load itself:
/// its parent screen calls `load`).
@MainActor @Observable
final class AccountsCache {
    static let shared = AccountsCache()
    private(set) var byBox: [String: [AgentAccount]] = [:]

    func load(box: String, model: AppModel) async {
        guard let conn = model.connection(for: box), conn.info?.has("accounts") == true,
              let list = try? await BoxAPI(transport: conn.raw).accounts() else { return }
        byBox[box] = list
    }
}

/// Which account a project's agents use, per agent (`PUT …/accounts`): the box's default, or one of the box's accounts.
/// Shown when the box has more than one account for an agent; the parent screen loads them (`AccountsCache.load`).
struct ProjectAccountsSection: View {
    let box: String
    let location: Location

    @Environment(AppModel.self) private var model
    @State private var error: String?
    private let cache = AccountsCache.shared

    private var conn: BoxConnection? { model.connection(for: box) }
    private var accounts: [AgentAccount] { cache.byBox[box] ?? [] }

    var body: some View {
        Section {
            ForEach(["claude", "codex"], id: \.self) { agent in
                let mine = accounts.filter { $0.agent == agent }
                if mine.count > 1 {
                    Picker(selection: Binding(get: { location.accounts?[agent] ?? "" }, set: { id in Task { await choose(agent, id) } })) {
                        Text("Padrão da box (\(mine.first(where: \.isDefault)?.name ?? "—"))").tag("")
                        ForEach(mine) { Text($0.name).tag($0.id) }
                    } label: {
                        Label { Text(agent == "claude" ? "Claude Code" : "Codex") } icon: { AgentGlyph(agent: agent, size: 18) }
                    }
                    .accessibilityIdentifier("project-account-\(agent)")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.red) }
        } header: {
            if accounts.filter({ $0.agent == "claude" }).count > 1 || accounts.filter({ $0.agent == "codex" }).count > 1 { Text("Conta dos agentes") }
        } footer: {
            if accounts.filter({ $0.agent == "claude" }).count > 1 || accounts.filter({ $0.agent == "codex" }).count > 1 {
                Text("Os agentes que começarem neste projeto usam esta conta. Os que já estão rodando continuam na deles.")
            }
        }
        .listRowBackground(Theme.card)
    }

    private func choose(_ agent: String, _ id: String) async {
        guard let conn else { return }
        do {
            _ = try await BoxAPI(transport: conn.raw).setProjectAccounts(location: location.name, [agent: id])
            await conn.refreshLocations()
            await AccountsCache.shared.load(box: box, model: model)
            error = nil
        } catch { self.error = ComposeErrorText.message(error) }
    }
}
