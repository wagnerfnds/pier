import SwiftUI
import PierKit

/// "Encerrar sessão": just stop the agent, or stop it and clean up after it: remove the worktree (pierd stops its services
/// and kills what runs in it), delete the local branch and fast-forward the project's main. Work not sent yet is listed,
/// and the cleanup then needs an explicit "discard".
struct EndSessionSheet: View {
    let vm: SessionViewModel
    let title: String
    var onDone: (String?) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var status: WorktreeStatus?
    @State private var loading = true
    @State private var cleanup = true
    @State private var discard = false
    @State private var working = false
    @State private var error: String?

    private var target: (location: String, worktree: String)? { vm.reviewTarget.map { ($0.0, $0.1) } }
    private var isMain: Bool { status?.main == true || target == nil }
    private var others: [Session] {
        guard let ref = vm.session.location else { return [] }
        return model.connection(for: vm.box)?.sessions.filter { $0.location == ref && $0.name != vm.name && !$0.exited } ?? []
    }
    private var risks: [String] {
        guard let s = status else { return [] }
        var r: [String] = []
        if s.changed > 0 { r.append(String(localized: "\(s.changed) arquivo(s) alterado(s) e não commitado(s)")) }
        if s.untracked > 0 { r.append(String(localized: "\(s.untracked) arquivo(s) novo(s) fora do git")) }
        if s.ahead > 0 { r.append(String(localized: "\(s.ahead) commit(s) que não estão no GitHub")) }
        return r
    }
    /// The branch has its own upstream (`base` is `origin/<branch>` once pushed; else the main branch).
    private var pushed: Bool { status.map { $0.base == "origin/\($0.branch ?? "")" && $0.ahead == 0 } ?? false }
    private var canRun: Bool { !working && !loading && (!cleanup || isMain || risks.isEmpty || discard) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.headline).foregroundStyle(Theme.text).lineLimit(2)
                    if let t = target, !isMain { Label("\(t.location) · \(t.worktree)", systemImage: "arrow.triangle.branch").font(.subheadline).foregroundStyle(Theme.textDim) }
                }.listRowBackground(Theme.card)

                if loading {
                    Section { HStack { ProgressView(); Text("Conferindo a worktree…").foregroundStyle(Theme.textDim) } }.listRowBackground(Theme.card)
                } else if !isMain {
                    Section {
                        option(true, "Encerrar e limpar", "Remove a worktree e a branch local, para os serviços dela e atualiza a main do projeto.", "sparkles")
                        option(false, "Só encerrar o agente", "A worktree, as alterações e os serviços continuam na box.", "stop.circle")
                    }.listRowBackground(Theme.card)

                    if cleanup {
                        Section {
                            if risks.isEmpty {
                                Label(pushed ? "Tudo enviado ao GitHub: nada se perde. A branch continua lá (e o PR, se houver)."
                                             : "Nada além da main nesta worktree: nada se perde.", systemImage: "checkmark.shield")
                                    .font(.subheadline).foregroundStyle(Theme.green)
                            } else {
                                ForEach(risks, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(Theme.orange) }
                                Toggle("Descartar isso e limpar mesmo assim", isOn: $discard).tint(Theme.red)
                            }
                            if !others.isEmpty {
                                Label(others.count == 1 ? "Também encerra outra sessão nesta worktree." : "Também encerra \(others.count) outras sessões nesta worktree.",
                                      systemImage: "person.2").font(.subheadline).foregroundStyle(Theme.orange)
                            }
                        }.listRowBackground(Theme.card)
                    }
                } else if vm.session.chat {
                    // A chat has no worktree: the box removes its folder too, unless the agent wrote something there.
                    Section { Text("A conversa será encerrada. A pasta dela na box só é apagada se o agente não tiver deixado nada lá.").font(.subheadline).foregroundStyle(Theme.textDim) }
                        .listRowBackground(Theme.card)
                } else {
                    Section { Text("O agente será encerrado. É a main do projeto: ela não é removida.").font(.subheadline).foregroundStyle(Theme.textDim) }
                        .listRowBackground(Theme.card)
                }

                if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }

                Section {
                    Button(role: .destructive) { Task { await run() } } label: {
                        HStack { Spacer(); if working { ProgressView() } else { Text(cleanup && !isMain ? "Encerrar e limpar" : "Encerrar sessão").fontWeight(.semibold) }; Spacer() }
                    }
                    .disabled(!canRun)
                    .accessibilityIdentifier("end-session-run")
                }.listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .pierBackground()
            .navigationTitle("Encerrar sessão")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(working)
        .task { await load() }
    }

    private func option(_ value: Bool, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ symbol: String) -> some View {
        Button { withAnimation(.snappy) { cleanup = value } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: cleanup == value ? "largecircle.fill.circle" : "circle").foregroundStyle(cleanup == value ? Theme.accent : Theme.textFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(.caption).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        defer { loading = false }
        guard let t = target, let c = model.client(for: vm.box) else { cleanup = false; return }
        status = (try? await c.worktreeStatuses(location: t.location))?.first { $0.name == t.worktree }
        if status?.main == true { cleanup = false }
    }

    private func run() async {
        guard let c = model.client(for: vm.box) else { return }
        working = true; error = nil
        defer { working = false }
        guard cleanup, !isMain, let t = target else {
            if await vm.kill() { dismiss(); onDone(nil) } else { error = vm.actionError }
            return
        }
        let removal: WorktreeRemoval
        do {
            // Removing the worktree kills its sessions (this one included) and stops its services.
            removal = try await c.removeWorktree(location: t.location, worktree: t.worktree, force: discard || !risks.isEmpty, deleteBranch: true)
        } catch {
            self.error = SessionActions.describe(error)
            return
        }
        var note: String
        switch removal {
        case .removed: note = String(localized: "Sessão encerrada, worktree “\(t.worktree)” removida e serviços parados.")
        case .archiving: note = String(localized: "Sessão encerrada e serviços parados; o script de arquivamento do projeto roda e a worktree “\(t.worktree)” some em instantes.")
        }
        if let r = try? await c.exec(location: t.location, command: GitActions.updateMain, timeout: "90s") {
            switch GitActions.parseUpdateMain(exitCode: r.exitCode, output: r.output) {
            case .updated(let sha): note += " " + String(localized: "main atualizada (\(sha)).")
            case .dirty: note += " " + String(localized: "A main tem alterações locais: não atualizei.")
            case .failed: note += " " + String(localized: "Não consegui atualizar a main.")
            }
        }
        if let conn = model.connection(for: vm.box) { await conn.refreshLocations(); await conn.refreshSessions() }
        Haptic.success()
        dismiss()
        onDone(note)
    }
}
