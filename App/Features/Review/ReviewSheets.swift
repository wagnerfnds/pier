import SwiftUI
import PierKit

struct ApproveSheet: View {
    let store: ReviewStore
    var onDone: (ReviewStore.ActionResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var push = false
    @State private var openPR = false
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var prBase = ""
    @State private var running = false
    @State private var result: ReviewStore.ActionResult?
    @State private var drafting = false
    @State private var draftError: String?
    /// What was last filled in automatically: a field that differs was typed by the person and a late draft keeps it.
    @State private var auto = Auto()
    private struct Auto { var message = "", title = "", body = "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    aiRow
                }
                if store.hasFiles {
                    Section("Mensagem do commit") {
                        TextEditor(text: $message).frame(minHeight: 110).font(.body)
                            .onChange(of: message) { _, new in
                                // The person edits the message: the title follows it until they edit the title too.
                                guard new != auto.message, prTitle == auto.title || prTitle.isEmpty else { return }
                                prTitle = firstLine(new); auto.title = prTitle
                            }
                    }
                    Section { Text("\(store.item?.files.count ?? 0) arquivo(s) serão adicionados (git add -A) e commitados.").font(.footnote).foregroundStyle(Theme.textDim) }
                } else {
                    Section { Text("Sem alterações pendentes: só push / PR dos commits existentes.").font(.footnote).foregroundStyle(Theme.textDim) }
                }
                Section {
                    Toggle("Fazer push", isOn: $push.animation()).disabled(openPR)
                    Toggle("Abrir PR", isOn: $openPR.animation())
                        .onChange(of: openPR) { _, on in if on { push = true; if prTitle.isEmpty { prTitle = firstLine(message); auto.title = prTitle } } }
                }
                if openPR {
                    Section("Pull request") {
                        TextField("Título", text: $prTitle)
                        TextField("Base", text: $prBase).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Descrição", text: $prBody, axis: .vertical).lineLimit(3...12)
                    }
                }
                if let r = result {
                    Section(r.ok ? "Resultado" : "Erro") {
                        if !r.output.isEmpty {
                            ScrollView(.horizontal) { MonoText(r.output, size: 11, color: r.ok ? Theme.text : Theme.red).textSelection(.enabled) }
                        } else {
                            Text(r.ok ? "Concluído." : "Falhou sem saída.").foregroundStyle(Theme.textDim)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .pierBackground()
            .navigationTitle("Aprovar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if running { ProgressView() } else {
                        Button(result?.ok == true ? "Fechar" : "Executar") {
                            if result?.ok == true { dismiss() } else { Task { await run() } }
                        }
                        .disabled(!canRun)
                    }
                }
            }
            .onAppear {
                if message.isEmpty {
                    message = store.defaultMessage; prTitle = firstLine(message)
                    auto = Auto(message: message, title: prTitle, body: "")
                }
                if prBase.isEmpty, let i = store.item { prBase = GitActions.baseBranch(i) }
            }
            .task { await draft(force: false) }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var aiRow: some View {
        HStack(spacing: 10) {
            if drafting {
                ProgressView().controlSize(.small)
                Text("Escrevendo com IA a partir do diff…").font(.footnote).foregroundStyle(Theme.textDim)
            } else if let draftError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.orange)
                Text(draftError).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(2)
            } else {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("Texto escrito pela IA (Haiku, na box)").font(.footnote).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 4)
            if !drafting {
                Button { Task { await draft(force: true) } } label: { Label("Gerar", systemImage: "arrow.clockwise").font(.footnote.weight(.semibold)) }
                    .buttonStyle(.borderless)
            }
        }
    }

    /// Asks the box for a draft. Automatic on open (keeps what the person typed); "Gerar" replaces everything.
    private func draft(force: Bool) async {
        guard !drafting else { return }
        drafting = true; draftError = nil
        defer { drafting = false }
        do {
            let d = try await store.aiDraft()
            if force || message == auto.message { message = d.commit }
            if force || prTitle == auto.title { prTitle = d.title }
            if force || prBody == auto.body { prBody = d.body }
            auto = Auto(message: d.commit, title: d.title, body: d.body)
        } catch is CancellationError {
        } catch {
            draftError = error.localizedDescription
        }
    }

    private var canRun: Bool {
        if store.hasFiles && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if openPR && prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return store.hasFiles || push || openPR
    }
    private func firstLine(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private func run() async {
        running = true
        let pr: (title: String, body: String, base: String)? = openPR
            ? (prTitle.trimmingCharacters(in: .whitespacesAndNewlines),
               prBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Aberto pelo Pier.") : prBody,
               prBase.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : prBase.trimmingCharacters(in: .whitespaces))
            : nil
        let r = await store.approve(message: message, push: push, openPR: pr)
        result = r
        running = false
        onDone(r)
        if r.ok && r.output.isEmpty { dismiss() }
    }
}

struct SendBackSheet: View {
    let store: ReviewStore
    var onSent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $note).frame(minHeight: 140)
                } header: { Text("O que o agente deve ajustar?") } footer: {
                    Text("Enviado como “\(GitActions.sendBackPrefix)…” quando o agente estiver livre.")
                }
                if let error { Section { Text(error).foregroundStyle(Theme.red) } }
            }
            .scrollContentBackground(.hidden)
            .pierBackground()
            .navigationTitle("Pedir ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else {
                        Button("Enviar") { Task { await send() } }
                            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() async {
        sending = true
        do {
            try await store.sendBack(note)
            dismiss()
            onSent()
        } catch {
            self.error = ReviewStore.message(error)
        }
        sending = false
    }
}
