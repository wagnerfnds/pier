import SwiftUI
import PierKit

/// The person's consent to setup agents for a project, asked once per project before the first one runs there
/// (`PUT /v1/locations/{l}/setup-agent`, docs/API.md §2.6.1). A setup agent works unattended in the project's new
/// worktrees: it installs what they lack (system packages with sudo, where the box allows it) and runs what the project
/// needs, which is only for code the person trusts. Allowed, the box prepares the project's new worktrees without a
/// recipe with one by itself; Ajustes › Projetos takes it back.
struct SetupAgentConsentSheet: View {
    let box: String
    let location: String
    /// Called once the box recorded the consent: what the person picked goes ahead.
    var onAllowed: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?

    private var name: String { model.prefs.displayName(box: box, location: location) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ProjectGlyph(name: name, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.headline).foregroundStyle(Theme.text)
                            Text("Deixar um agente preparar este projeto?").font(.subheadline).foregroundStyle(Theme.textDim)
                        }
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    point("sparkles", "Trabalha sozinho, numa sessão ao lado da sua tarefa, sem pedir aprovação a cada comando.")
                    point("shippingbox", "Instala o que falta (dependências, banco de dados e, onde a box permite, pacotes do sistema com sudo), sobe o servidor e cria um login de teste.")
                    point("hand.raised", "Segue as regras da box, mas roda o que o projeto precisa: permita só em projetos cujo código você confia.")
                } footer: {
                    Text("A partir de agora, as worktrees novas deste projeto sem receita são preparadas assim. Desligue quando quiser em Ajustes › Projetos.")
                }
                .font(.subheadline)
                .listRowBackground(Theme.card)

                if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
            }
            .pierBackground()
            .navigationTitle("Agente prepara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Agora não") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Permitir neste projeto") { Task { await allow() } }.keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("setup-agent-allow")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(working)
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text).foregroundStyle(Theme.text) } icon: { Image(systemName: symbol).foregroundStyle(Theme.accent) }
    }

    private func allow() async {
        guard let conn = model.connection(for: box) else { return }
        working = true; error = nil
        defer { working = false }
        do {
            _ = try await BoxAPI(transport: conn.raw).setSetupAgent(location: location, allowed: true)
            await conn.refreshLocations()
            onAllowed()
            dismiss()
        } catch { self.error = ComposeErrorText.message(error) }
    }
}
