import SwiftUI
import PierKit

/// Shows gh's output when an action failed (the sheet stays open so the person can fix and retry).
private struct FailureSection: View {
    let result: PullRequestStore.ActionResult?
    var body: some View {
        if let r = result, !r.ok {
            Section("Erro") {
                if r.output.isEmpty {
                    Text("Falhou sem saída.").foregroundStyle(Theme.textDim)
                } else {
                    ScrollView(.horizontal) { MonoText(r.output, size: 11, color: Theme.red).textSelection(.enabled) }
                        .accessibilityIdentifier("pr-action-error")
                }
            }
        }
    }
}

// MARK: merge

struct PRMergeSheet: View {
    let store: PullRequestStore
    var onDone: (PullRequestStore.Action) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var method: PRMergeMethod = .squash
    @State private var deleteBranch = true
    @State private var confirming = false
    @State private var running = false
    @State private var result: PullRequestStore.ActionResult?

    var body: some View {
        let pr = store.pr
        NavigationStack {
            Form {
                Section {
                    Picker("Como mesclar", selection: $method) {
                        Text("Squash").tag(PRMergeMethod.squash)
                        Text("Merge").tag(PRMergeMethod.merge)
                        Text("Rebase").tag(PRMergeMethod.rebase)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("pr-merge-method")
                } header: { Text("Como mesclar") } footer: { Text(hint(base: pr?.baseRefName ?? "main")) }
                if pr?.isCrossRepository == false {
                    Section {
                        Toggle(S("Apagar a branch \(pr?.headRefName ?? "") depois"), isOn: $deleteBranch)
                    } footer: { Text("Só no GitHub; nenhuma worktree da box é mexida.") }
                }
                if let pr, !warnings(pr).isEmpty {
                    Section {
                        ForEach(warnings(pr), id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.orange)
                        }
                    }
                }
                FailureSection(result: result)
            }
            .scrollContentBackground(.hidden)
            .pierBackground()
            .navigationTitle(Text(S("Mesclar #\(store.number)")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if running { ProgressView() } else {
                        Button("Mesclar") { confirming = true }.accessibilityIdentifier("pr-merge-go")
                    }
                }
            }
            .alert(S("Mesclar o PR #\(store.number) em \(pr?.baseRefName ?? "main")?"), isPresented: $confirming) {
                Button("Mesclar") { Task { await run() } }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(summary(pr))
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func hint(base: String) -> String {
        switch method {
        case .squash: S("Um commit só em \(base), com o título do PR.")
        case .merge: S("Todos os commits da branch, mais um commit de merge.")
        case .rebase: S("Os commits reaplicados em cima de \(base), sem commit de merge.")
        }
    }

    private func summary(_ pr: PRDetail?) -> String {
        let how = switch method {
        case .squash: S("Squash")
        case .merge: S("Merge commit")
        case .rebase: S("Rebase")
        }
        guard let pr, !pr.isCrossRepository, deleteBranch else { return how }
        return "\(how) · " + S("a branch \(pr.headRefName) será apagada")
    }

    private func warnings(_ pr: PRDetail) -> [String] {
        var out: [String] = []
        if pr.checkRollup == .fail { out.append(S("Há checks falhando.")) }
        if pr.checkRollup == .pending { out.append(S("Há checks rodando ainda.")) }
        if pr.reviewDecision == "CHANGES_REQUESTED" { out.append(S("Um revisor pediu mudanças.")) }
        if pr.reviewDecision == "REVIEW_REQUIRED" { out.append(S("O PR ainda não foi aprovado.")) }
        if pr.mergeable == "CONFLICTING" { out.append(S("Tem conflitos com \(pr.baseRefName).")) }
        return out
    }

    private func run() async {
        running = true
        let action = PullRequestStore.Action.merge(method, deleteBranch: deleteBranch && store.pr?.isCrossRepository == false)
        let r = await store.run(action)
        running = false
        result = r
        if r.ok { onDone(action); dismiss() }
    }
}

// MARK: review / comment

struct PRReviewSheet: View {
    let store: PullRequestStore
    @State var kind: PRReviewKind
    var onDone: (PullRequestStore.Action) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var confirming = false
    @State private var running = false
    @State private var result: PullRequestStore.ActionResult?
    @FocusState private var focused: Bool

    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { kind == .approve || !blank }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tipo", selection: $kind) {
                        Text("Comentar").tag(PRReviewKind.comment)
                        Text("Aprovar").tag(PRReviewKind.approve)
                        Text("Pedir mudanças").tag(PRReviewKind.requestChanges)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("pr-review-kind")
                }
                Section {
                    TextEditor(text: $text).frame(minHeight: 150).focused($focused)
                        .accessibilityIdentifier("pr-review-text")
                } header: { Text(kind == .approve ? S("Comentário (opcional)") : kind == .comment ? S("Comentário") : S("O que precisa mudar?")) } footer: {
                    Text(footer)
                }
                FailureSection(result: result)
            }
            .scrollContentBackground(.hidden)
            .pierBackground()
            .navigationTitle(Text(S("PR #\(store.number)")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if running { ProgressView() } else {
                        Button("Enviar") { focused = false; confirming = true }.disabled(!canSend).accessibilityIdentifier("pr-review-send")
                    }
                }
            }
            .alert(confirmTitle, isPresented: $confirming) {
                Button(confirmButton) { Task { await run() } }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(blank ? S("Sem comentário.") : String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))
            }
            .onAppear { if kind != .approve { focused = true } }
        }
        .presentationDetents([.medium, .large])
    }

    private var footer: String {
        switch kind {
        case .comment: S("Publicado na conversa do PR, com o seu usuário do gh na box.")
        case .approve: S("Aprova o PR com o seu usuário do gh na box.")
        case .requestChanges: S("Uma revisão pedindo mudanças; o autor é avisado.")
        }
    }
    private var confirmTitle: String {
        switch kind {
        case .comment: S("Publicar comentário no PR #\(store.number)?")
        case .approve: S("Aprovar o PR #\(store.number)?")
        case .requestChanges: S("Pedir mudanças no PR #\(store.number)?")
        }
    }
    private var confirmButton: String {
        switch kind {
        case .comment: S("Publicar")
        case .approve: S("Aprovar")
        case .requestChanges: S("Pedir mudanças")
        }
    }

    private func run() async {
        running = true
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let action: PullRequestStore.Action = kind == .comment ? .comment(body) : .review(kind, body)
        let r = await store.run(action)
        running = false
        result = r
        if r.ok { onDone(action); dismiss() }
    }
}

// MARK: bring into a worktree, then an agent

struct PRWorktreeSheet: View {
    let store: PullRequestStore
    /// The agent started: (box, session). The screen opens it once the sheet is gone.
    var onStarted: (String, Session) -> Void
    var openWorktree: (String, String, String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var step: PullRequestStore.BringStep?
    @State private var brought: PullRequestStore.Brought?
    @State private var error: String?
    @State private var agentID: String?
    @State private var modelChoice = ""
    @State private var effort = ""
    @State private var prompt = ""
    @State private var starting = false

    private var location: Location? { store.location }
    private var agents: [AgentPreset] { mergedAgents(box: store.conn?.info, location: location) }
    private var agent: AgentPreset? { agents.first { $0.id == agentID } }

    var body: some View {
        NavigationStack {
            Form {
                if let b = brought {
                    broughtSection(b)
                    agentSection(b)
                } else if location == nil {
                    Section {
                        Label(S("Nenhum projeto da box é um clone de \(store.repo)."), systemImage: "folder.badge.questionmark")
                            .foregroundStyle(Theme.orange)
                    } footer: { Text("Adicione o repositório como projeto na box para trazer PRs dele.") }
                } else {
                    if let wt = store.existingWorktree, let loc = location { existingSection(wt, loc) }
                    createSection()
                }
                if let error {
                    Section("Erro") {
                        ScrollView(.horizontal) { MonoText(error, size: 11, color: Theme.red).textSelection(.enabled) }
                            .accessibilityIdentifier("pr-worktree-error")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .pierBackground()
            .navigationTitle(brought == nil ? Text("Trazer para uma worktree") : Text("Continuar com um agente"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(brought == nil ? S("Cancelar") : S("Fechar")) { dismiss() } }
                if brought == nil && location != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if step != nil { ProgressView() } else {
                            Button("Criar") { Task { await bring() } }
                                .disabled(!WorktreeNaming.isValid(name) || takenNames.contains(name))
                                .accessibilityIdentifier("pr-worktree-create")
                        }
                    }
                }
            }
            .onAppear {
                if name.isEmpty { name = PRCommands.worktreeName(number: store.number, taken: takenNames) }
                if agentID == nil {
                    let ids = agents.map(\.id)
                    agentID = [model.prefs.lastAgent, "claude"].compactMap { $0 }.first { ids.contains($0) } ?? ids.first
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(step != nil || starting)
    }

    private var takenNames: Set<String> { Set(location?.worktrees?.map(\.name) ?? []) }

    // MARK: before

    private func existingSection(_ wt: Worktree, _ loc: Location) -> some View {
        Section {
            Text(S("A branch \(wt.branch ?? "") já está na worktree \(wt.name)."))
                .font(.subheadline).foregroundStyle(Theme.text)
            Button {
                let b = PullRequestStore.Brought(location: loc.name, worktree: wt.name, ref: loc.ref(wt), branch: wt.branch ?? "")
                prompt = store.agentPrompt(branch: b.branch)
                brought = b
            } label: { Label("Usar essa worktree", systemImage: "arrow.right.circle") }
            Button { openWorktree(store.box ?? "", loc.name, wt.name) } label: { Label("Abrir worktree", systemImage: "folder") }
        } header: { Text("Já existe") }
    }

    @ViewBuilder private func createSection() -> some View {
        let pr = store.pr
        Section {
            TextField("Nome", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.mono(15)).accessibilityIdentifier("pr-worktree-name")
        } header: { Text("Nova worktree") } footer: {
            if takenNames.contains(name) { Text("Já existe uma worktree com esse nome.").foregroundStyle(Theme.orange) }
        }
        Section {
            LabeledContent(S("Projeto"), value: location.map { model.prefs.displayName(box: store.box ?? "", location: $0.name) } ?? "")
            LabeledContent(S("Branch"), value: pr.map { $0.isCrossRepository ? "\($0.headOwner ?? "?"):\($0.headRefName)" : $0.headRefName } ?? "")
            if let step { progress(step) }
        } footer: {
            if let pr { pushNote(pr) }
        }
    }

    private func progress(_ s: PullRequestStore.BringStep) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(s == .fetching ? S("Buscando a branch do PR…") : s == .creating ? S("Criando a worktree…") : S("Fazendo o checkout do PR…"))
                .font(.subheadline).foregroundStyle(Theme.textDim)
        }
    }

    private func pushNote(_ pr: PRDetail) -> some View {
        Group {
            if !pr.isCrossRepository {
                Text(S("A worktree fica na branch \(pr.headRefName), seguindo origin/\(pr.headRefName): um git push dali atualiza o PR."))
            } else if pr.maintainerCanModify {
                Text("PR de um fork: o gh pr checkout configura a branch para enviar ao fork, então o push atualiza o PR.")
            } else {
                Text("PR de um fork que não aceita edições de mantenedores: dá para rodar e testar, mas o push para o PR vai falhar.")
                    .foregroundStyle(Theme.orange)
            }
        }
    }

    private func bring() async {
        error = nil
        do {
            let b = try await store.bringToWorktree(name: name) { step = $0 }
            prompt = store.agentPrompt(branch: b.branch)
            brought = b
            Haptic.success()
        } catch {
            self.error = (error as? PullRequestStore.BringError)?.message ?? ComposeErrorText.message(error)
        }
        step = nil
    }

    // MARK: after

    private func broughtSection(_ b: PullRequestStore.Brought) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(S("Worktree \(b.worktree) pronta")).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(S("na branch \(b.branch)")).font(.caption).foregroundStyle(Theme.textDim)
                }
            } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
            .accessibilityIdentifier("pr-worktree-ready")
            if let w = b.warning {
                VStack(alignment: .leading, spacing: 4) {
                    Label("O checkout não terminou como esperado", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.orange)
                    ScrollView(.horizontal) { MonoText(w, size: 11) }
                }
            }
            Button { openWorktree(store.box ?? "", b.location, b.worktree) } label: { Label("Abrir worktree", systemImage: "folder") }
        }
    }

    @ViewBuilder private func agentSection(_ b: PullRequestStore.Brought) -> some View {
        Section {
            Picker(S("Agente"), selection: Binding(get: { agentID ?? "" }, set: { agentID = $0; modelChoice = ""; effort = "" })) {
                ForEach(agents) { a in Text(a.name.isEmpty ? DisplayNames.agentLabel(a.id) : a.name).tag(a.id) }
            }
            if let a = agent, a.canPickModel, let models = a.models, !models.isEmpty {
                Picker(S("Modelo"), selection: $modelChoice) {
                    Text("Padrão").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            if let a = agent, a.canPickEffort, let efforts = a.efforts, !efforts.isEmpty {
                Picker(S("Esforço"), selection: $effort) {
                    Text("Padrão").tag("")
                    ForEach(efforts, id: \.self) { Text($0).tag($0) }
                }
            }
        } header: { Text("Continuar com um agente") }
        Section {
            TextEditor(text: $prompt).frame(minHeight: 220).font(.callout)
                .accessibilityIdentifier("pr-agent-prompt")
        } header: { Text("Prompt") } footer: { Text("Montado a partir do PR e das mudanças pedidas pelos revisores. Edite à vontade.") }
        Section {
            Button {
                Task { await start(b) }
            } label: {
                HStack { if starting { ProgressView().tint(.white) }; Text("Iniciar agente") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(starting || agent == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            .accessibilityIdentifier("pr-agent-start")
        }
    }

    private func start(_ b: PullRequestStore.Brought) async {
        guard let agent, let box = store.box else { return }
        starting = true
        error = nil
        do {
            let s = try await store.startAgent(ref: b.ref, agent: agent, model: modelChoice, effort: effort, prompt: prompt)
            Haptic.success()
            onStarted(box, s)
            dismiss()
        } catch {
            self.error = ComposeErrorText.message(error)
        }
        starting = false
    }
}
