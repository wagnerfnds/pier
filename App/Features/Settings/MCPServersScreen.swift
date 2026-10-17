import SwiftUI
import PierKit

/// The box's MCP servers (`/v1/mcp`): pierd writes each one into every Claude Code and Codex account on the box, through
/// the agents' own CLIs, so any agent started there can use it. Testar asks the box how each agent's default account sees
/// them (Claude Code's own list; a handshake with the token for Codex). A token goes to the box and never comes back.
struct MCPServersScreen: View {
    let box: String

    @Environment(AppModel.self) private var model
    @State private var servers: [MCPServer] = []
    @State private var loaded = false
    @State private var testing = false
    @State private var error: String?
    @State private var editing: MCPServerSheet.Target?
    @State private var removing: MCPServer?

    private var conn: BoxConnection? { model.connection(for: box) }
    private var api: BoxAPI? { conn.map { BoxAPI(transport: $0.raw) } }

    var body: some View {
        Form {
            Section {
                if loaded && servers.isEmpty {
                    Text("Nenhum servidor MCP ainda.").font(.subheadline).foregroundStyle(Theme.textDim)
                }
                ForEach(servers) { s in row(s) }
                Button { editing = .new } label: { Label("Adicionar servidor", systemImage: "plus.circle") }
                    .accessibilityIdentifier("mcp-add")
            } header: { Text("Servidores") } footer: {
                Text("O pierd coloca cada servidor em todas as contas do Claude Code e do Codex da box, pelos próprios CLIs deles, e os agentes que começarem depois já o usam. Um servidor que você adicionou à mão com o mesmo nome fica como está.")
            }
            .listRowBackground(Theme.card)
            if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
        }
        .pierBackground()
        .navigationTitle("Servidores MCP")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if testing { ProgressView() } else {
                    Button("Testar") { Task { await test() } }
                        .disabled(!servers.contains(where: \.enabled))
                        .accessibilityIdentifier("mcp-test")
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $editing) { target in
            MCPServerSheet(box: box, target: target, taken: Set(servers.map(\.name))) { saved in
                upsert(saved)
                if saved.enabled { Task { await test() } }
            }
        }
        .confirmationDialog("Remover “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remover servidor", role: .destructive) { if let s = removing { Task { await remove(s) } } }
        } message: { Text("O servidor sai de todas as contas em que o pierd o colocou. Os agentes que já estão rodando continuam com ele até terminar.") }
    }

    private func row(_ s: MCPServer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(s.name).font(.mono(14, weight: .semibold)).foregroundStyle(Theme.text)
                healthChip(s)
                Spacer()
                Toggle("Ligado", isOn: Binding(get: { s.enabled }, set: { on in Task { await setEnabled(s, on) } }))
                    .labelsHidden()
                    .accessibilityLabel(Text("Usar \(s.name)"))
                    .accessibilityIdentifier("mcp-enabled-\(s.name)")
            }
            MonoText(s.transport == "stdio" ? ([s.command ?? ""] + s.args).joined(separator: " ") : s.url ?? "", size: 11, color: Theme.textFaint)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                ForEach(s.agents, id: \.self) { AgentGlyph(agent: $0, size: 16) }
                if s.tokenSet {
                    Image(systemName: "key.fill").font(.caption2).foregroundStyle(Theme.textDim).accessibilityLabel(Text("Com token"))
                }
            }
            if s.enabled && !s.status.isEmpty {
                ForEach(s.agents, id: \.self) { agent in
                    if let st = s.status[agent] { agentLine(agent, st) }
                }
            } else if s.enabled {
                ForEach(s.problems, id: \.self) { p in
                    Text(p).font(.caption).foregroundStyle(Theme.orange).lineLimit(3)
                }
            }
            HStack(spacing: 14) {
                if s.transport == "http" {
                    Button { editing = .edit(s) } label: { Label("Editar", systemImage: "pencil") }
                        .accessibilityIdentifier("mcp-edit-\(s.name)")
                }
                Button(role: .destructive) { removing = s } label: { Label("Remover", systemImage: "trash") }
                    .accessibilityIdentifier("mcp-remove-\(s.name)")
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("mcp-\(s.name)")
    }

    @ViewBuilder private func healthChip(_ s: MCPServer) -> some View {
        switch MCPServers.health(s) {
        case .connected: chip("Conectado", Theme.green)
        case .configured: chip("Configurado", Theme.accent)
        case .failing: chip("Falhou", Theme.red)
        case .off: chip("Desligado", Theme.textFaint)
        case .unknown: EmptyView()
        }
    }

    private func chip(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1).background(color.opacity(0.12), in: Capsule())
    }

    /// How one agent sees the server, and why when it fails.
    private func agentLine(_ agent: String, _ st: MCPAgentStatus) -> some View {
        let kind = MCPServers.kind(st)
        let (text, color): (LocalizedStringKey, Color) = switch kind {
        case .connected: ("Conectado", Theme.green)
        case .configured: ("Configurado", Theme.accent)
        case .failed: ("Falhou", Theme.red)
        case .off: ("Desligado", Theme.textFaint)
        case .missing: ("Ainda não está nesta conta", Theme.orange)
        case .taken: ("Já existe um servidor seu com este nome", Theme.orange)
        case .unavailable: ("Não está instalado na box", Theme.textFaint)
        case .unknown: ("Sem resposta", Theme.orange)
        }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                AgentGlyph(agent: agent, size: 14)
                Text(st.account ?? (agent == "claude" ? "Claude Code" : "Codex")).font(.caption).foregroundStyle(Theme.textDim)
                Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            }
            if let issue = st.issue, kind != .connected, kind != .taken {
                Text(issue).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(3).padding(.leading, 20)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func upsert(_ s: MCPServer) {
        if let i = servers.firstIndex(where: { $0.name == s.name }) { servers[i] = s } else {
            servers.append(s)
            servers.sort { $0.name < $1.name }
        }
    }

    private func load() async {
        guard let api else { return }
        do { servers = try await api.mcpServers(); error = nil } catch { self.error = ComposeErrorText.message(error) }
        loaded = true
    }

    /// Asks the box how each agent sees the servers: up to about 20 seconds.
    private func test() async {
        guard let api, !testing else { return }
        testing = true
        defer { testing = false }
        do { servers = try await api.mcpServers(status: true); error = nil } catch { self.error = ComposeErrorText.message(error) }
    }

    private func setEnabled(_ s: MCPServer, _ on: Bool) async {
        guard let api else { return }
        var u = MCPServerUpdate(s)
        u.enabled = on
        do {
            let saved = try await api.setMCPServer(name: s.name, u)
            upsert(saved)
            error = nil
            if on { await test() }
        } catch { self.error = ComposeErrorText.message(error) }
    }

    private func remove(_ s: MCPServer) async {
        guard let api else { return }
        do {
            try await api.removeMCPServer(name: s.name)
            servers.removeAll { $0.name == s.name }
            error = nil
        } catch { self.error = ComposeErrorText.message(error) }
    }
}

/// Add or edit an http MCP server: its URL, name, token (never shown back: empty keeps the box's), extra headers and which
/// agents get it.
struct MCPServerSheet: View {
    enum Target: Identifiable {
        case new
        case edit(MCPServer)
        var id: String {
            switch self {
            case .new: "new"
            case .edit(let s): "edit-\(s.name)"
            }
        }
    }

    struct HeaderRow: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    let box: String
    let target: Target
    /// The names already on the box: a new server cannot take one (saving would replace it).
    let taken: Set<String>
    var onSaved: (MCPServer) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var nameEdited = false
    @State private var url = ""
    @State private var token = ""
    @State private var removeToken = false
    @State private var headers: [HeaderRow] = []
    @State private var claude = true
    @State private var codex = true
    @State private var working = false
    @State private var error: String?
    @State private var filled = false

    private var existing: MCPServer? {
        if case .edit(let s) = target { s } else { nil }
    }

    private var nameTaken: Bool { existing == nil && taken.contains(name) }

    private var headersValid: Bool {
        headers.allSatisfy { h in
            let n = h.name.trimmingCharacters(in: .whitespaces), v = h.value.trimmingCharacters(in: .whitespaces)
            return (n.isEmpty && v.isEmpty) || MCPServers.isValidHeader(name: n, value: v)
        }
    }

    private var canSave: Bool {
        MCPServers.isValidName(name) && !nameTaken && MCPServers.isValidURL(url) && (claude || codex)
            && (token.isEmpty || MCPServers.isValidToken(token)) && headersValid && !working
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://mcp.exemplo.com/mcp", text: $url)
                        .font(.mono(14)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onChange(of: url) { if existing == nil && !nameEdited { name = MCPServers.suggestedName(for: url) } }
                        .accessibilityIdentifier("mcp-url")
                    if existing == nil {
                        TextField("nome (ex.: crm)", text: Binding(get: { name }, set: { name = $0.lowercased(); nameEdited = true }))
                            .font(.mono(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("mcp-name")
                    } else {
                        LabeledContent("Nome") { Text(verbatim: name).font(.mono(14)) }
                    }
                    if nameTaken {
                        Text("Já existe um servidor com este nome.").font(.caption).foregroundStyle(Theme.red)
                    }
                } header: { Text("Servidor") } footer: {
                    Text("O endereço MCP (HTTP) do serviço. O nome identifica o servidor para os agentes (as ferramentas dele viram mcp__nome__…): letras minúsculas, números, - e _.")
                }
                .listRowBackground(Theme.card)

                Section {
                    SecureField(existing?.tokenSet == true ? "Token salvo: deixe vazio para manter" : "Token (opcional)", text: $token)
                        .font(.mono(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(removeToken)
                        .accessibilityIdentifier("mcp-token")
                    if existing?.tokenSet == true {
                        Toggle("Remover o token salvo", isOn: $removeToken).onChange(of: removeToken) { if removeToken { token = "" } }
                    }
                } header: { Text("Token") } footer: {
                    Text("Vai como Authorization: Bearer e fica só na box: o Claude Code o guarda na configuração de cada conta, o Codex o lê de \(MCPServers.tokenVariable(name.isEmpty ? "nome" : name)), que toda sessão recebe. O app nunca o mostra de volta.")
                }
                .listRowBackground(Theme.card)

                Section {
                    ForEach($headers) { $h in
                        HStack {
                            TextField("X-Cabecalho", text: $h.name).font(.mono(13)).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("valor", text: $h.value).font(.mono(13)).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button(role: .destructive) { headers.removeAll { $0.id == h.id } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless).tint(Theme.red).accessibilityLabel(Text("Remover cabeçalho"))
                        }
                    }
                    Button { headers.append(HeaderRow()) } label: { Label("Adicionar cabeçalho", systemImage: "plus.circle") }
                        .accessibilityIdentifier("mcp-add-header")
                } header: { Text("Cabeçalhos extras (opcional)") } footer: {
                    Text("Só o Claude Code envia estes cabeçalhos (o Codex recebe só o token), e eles aparecem no app: não coloque segredos aqui.")
                }
                .listRowBackground(Theme.card)

                Section {
                    Toggle(isOn: $claude) { Label { Text(verbatim: "Claude Code") } icon: { AgentGlyph(agent: "claude", size: 18) } }
                        .accessibilityIdentifier("mcp-agent-claude")
                    Toggle(isOn: $codex) { Label { Text(verbatim: "Codex") } icon: { AgentGlyph(agent: "codex", size: 18) } }
                        .accessibilityIdentifier("mcp-agent-codex")
                } header: { Text("Agentes") } footer: {
                    Text("Em todas as contas da box de cada agente marcado.")
                }
                .listRowBackground(Theme.card)

                if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
            }
            .pierBackground()
            .navigationTitle(existing.map { Text(verbatim: $0.name) } ?? Text("Novo servidor MCP"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Salvar") { Task { await save() } }.disabled(!canSave).keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("mcp-save")
                    }
                }
            }
            .task { fill() }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(working)
    }

    /// The fields from the server being edited, or a new server's defaults: the agents the box has.
    private func fill() {
        guard !filled else { return }
        filled = true
        if let s = existing {
            name = s.name
            url = s.url ?? ""
            headers = s.headers.sorted { $0.key < $1.key }.map { HeaderRow(name: $0.key, value: $0.value) }
            claude = s.agents.contains("claude")
            codex = s.agents.contains("codex")
        } else if let agents = model.connection(for: box)?.info?.agents.map(\.id), !agents.isEmpty {
            claude = agents.contains("claude")
            codex = agents.contains("codex")
            if !claude && !codex { claude = true; codex = true }
        }
    }

    private func save() async {
        guard let conn = model.connection(for: box), canSave else { return }
        working = true
        defer { working = false }
        var u = existing.map(MCPServerUpdate.init) ?? MCPServerUpdate()
        u.transport = "http"
        u.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var h: [String: String] = [:]
        for row in headers {
            let n = row.name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { h[n] = row.value.trimmingCharacters(in: .whitespaces) }
        }
        u.headers = h.isEmpty ? nil : h
        u.agents = (claude ? ["claude"] : []) + (codex ? ["codex"] : [])
        // Left empty, the box keeps the token it has; "" removes it.
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        u.token = !t.isEmpty ? t : (removeToken ? "" : nil)
        do {
            let saved = try await BoxAPI(transport: conn.raw).setMCPServer(name: name, u)
            onSaved(saved)
            model.toast = AppToast(text: String(localized: "Servidor salvo. Os agentes que começarem agora já o usam."), symbol: "checkmark.circle")
            dismiss()
        } catch { self.error = ComposeErrorText.message(error) }
    }
}
