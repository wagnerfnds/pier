import SwiftUI
import PierKit

/// "↑2 ↓1 · 3 alterados · 1 sessão · :41000" for a worktree.
struct WorktreeIndicators: View {
    let status: WorktreeStatus?
    let worktree: Worktree?
    var sessions: Int

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 4) {
            if let s = status {
                if s.ahead > 0 { tag("arrow.up", "\(s.ahead)", Theme.green) }
                if s.behind > 0 { tag("arrow.down", "\(s.behind)", Theme.orange) }
                let changes = s.changed + s.untracked
                if changes > 0 {
                    tag("pencil.line", changes == 1 ? String(localized: "1 alterado") : String(localized: "\(changes) alterados"), Theme.accent)
                } else if s.ahead == 0 && s.behind == 0 {
                    tag("checkmark", String(localized: "limpa"), Theme.textFaint)
                }
            }
            if sessions > 0 { tag("terminal", sessions == 1 ? String(localized: "1 sessão") : String(localized: "\(sessions) sessões"), Theme.textDim) }
            if let port = status?.port ?? worktree?.port { tag("network", ":\(port)", Theme.textDim) }
            if worktree?.settingUp == true { tag("hammer", String(localized: "configurando"), Theme.orange) }
            if status?.paused == true { tag("pause.circle", String(localized: "pausada"), Theme.gray) }
        }
    }

    private func tag(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(text).font(.caption.monospacedDigit())
        }.foregroundStyle(color)
    }
}

/// Confirm + perform removal of a worktree (kills its sessions; may answer 202 "archiving").
struct RemoveWorktreeSheet: View {
    let box: String
    let location: String
    let worktree: String
    var changes: Int
    var sessions: Int
    var onFinished: (BannerMessage) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var force = false
    @State private var deleteBranch = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Remover “\(worktree)”").font(.headline).foregroundStyle(Theme.text)
                    if sessions > 0 {
                        Label(sessions == 1 ? "Isto encerra 1 sessão em andamento nesta worktree." : "Isto encerra \(sessions) sessões em andamento nesta worktree.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange).font(.subheadline)
                    }
                    if changes > 0 {
                        Label("Há \(changes) arquivo(s) com mudanças não commitadas.", systemImage: "pencil.line").foregroundStyle(Theme.orange).font(.subheadline)
                    }
                }.listRowBackground(Theme.card)
                Section {
                    Toggle("Descartar mudanças não commitadas", isOn: $force).tint(Theme.red)
                    Toggle("Apagar também a branch", isOn: $deleteBranch)
                } footer: { Text("Se o projeto tem um script de arquivamento, ele roda primeiro e a worktree some quando terminar.") }
                    .listRowBackground(Theme.card)
                if let error {
                    Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card)
                }
                Section {
                    Button(role: .destructive) { Task { await remove() } } label: {
                        HStack { Spacer(); if working { ProgressView() } else { Text("Remover worktree").fontWeight(.semibold) }; Spacer() }
                    }.disabled(working)
                }.listRowBackground(Theme.card)
            }
            .pierBackground()
            .navigationTitle("Remover worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(working)
        #if DEBUG
        .task { if UserDefaults.standard.bool(forKey: "removeAuto") { try? await Task.sleep(for: .seconds(2)); force = true; await remove() } }
        #endif
    }

    private func remove() async {
        guard let conn = model.connection(for: box) else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let r = try await conn.client.removeWorktree(location: location, worktree: worktree, force: force, deleteBranch: deleteBranch)
            // Keep only the main, up to date: fast-forward it now that the worktree is gone.
            var mainNote = ""
            if case .removed = r, let u = try? await conn.client.exec(location: location, command: GitActions.updateMain, timeout: "90s"),
               case .updated(let sha) = GitActions.parseUpdateMain(exitCode: u.exitCode, output: u.output) {
                mainNote = " " + String(localized: "main atualizada (\(sha)).")
            }
            await conn.refreshLocations(); await conn.refreshSessions()
            switch r {
            case .removed: onFinished(BannerMessage(text: String(localized: "Worktree “\(worktree)” removida.") + mainNote, kind: .success))
            case .archiving: onFinished(BannerMessage(text: String(localized: "Arquivando “\(worktree)”… o script de arquivamento está rodando; a worktree some quando terminar."), kind: .info))
            }
            dismiss()
        } catch {
            let msg = ComposeErrorText.message(error)
            if let e = error as? BoxError, e.kind == .gitFailed || msg.lowercased().contains("modified") || msg.lowercased().contains("untracked") {
                self.error = String(localized: "O git recusou: \(msg)\nAtive “Descartar mudanças” para forçar.")
                force = true
            } else { self.error = msg }
        }
    }
}

/// Create a worktree (name + base branch) without starting an agent.
struct NewWorktreeSheet: View {
    let box: String
    let location: Location
    var onCreated: (Worktree) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var base: String?
    @State private var branches: BranchList?
    @State private var picking = false
    @State private var working = false
    @State private var error: String?

    private var taken: Set<String> { Set(location.worktrees?.map(\.name) ?? []) }
    private var valid: Bool { WorktreeNaming.isValid(name) && !taken.contains(name) }
    private var effectiveBase: String { base ?? branches?.default ?? location.defaultBranch ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome (e branch)") {
                    TextField("nome-da-worktree", text: $name).font(.mono(16))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if taken.contains(name) { Text("Já existe uma worktree com esse nome.").font(.footnote).foregroundStyle(Theme.red) }
                }.listRowBackground(Theme.card)
                Section("Criar a partir de") {
                    Button { picking = true } label: {
                        HStack { Text("Branch base").foregroundStyle(Theme.text); Spacer(); Text(effectiveBase.isEmpty ? "—" : effectiveBase).font(.mono(14)).foregroundStyle(Theme.textDim); Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Theme.textFaint) }
                    }
                }.listRowBackground(Theme.card)
                if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
            }
            .pierBackground()
            .navigationTitle("Nova worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else { Button("Criar") { Task { await create() } }.disabled(!valid) }
                }
            }
            .task { branches = try? await model.client(for: box)?.branches(location: location.name) }
            .sheet(isPresented: $picking) {
                BranchPickerSheet(branches: branches, selected: effectiveBase, defaultBranch: branches?.default ?? location.defaultBranch) { base = $0 }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(working)
    }

    private func create() async {
        guard let conn = model.connection(for: box) else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let wt = try await conn.client.createWorktree(location: location.name, WorktreeRequest(name: name, branch: name, base: effectiveBase.isEmpty ? nil : effectiveBase))
            await conn.refreshLocations()
            onCreated(wt)
            dismiss()
        } catch { self.error = ComposeErrorText.message(error) }
    }
}
