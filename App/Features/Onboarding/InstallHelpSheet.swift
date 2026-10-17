import SwiftUI

/// "Outros jeitos de instalar": the ways to put pierd on a machine before pairing. The quick one hands the job to the
/// agent already running there (the prompt is copied and pasted into Claude Code or Codex, which runs the installer and
/// prints the pier:// link); the other lists the commands (the installer, npm, Homebrew), each with Copiar. Reached from
/// the pairing step of the onboarding and from "Adicionar box" in Ajustes.
struct InstallHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    /// What the agent on the box is asked to do (in English, the language every agent reads best). `pierd doctor` at the
    /// end so what is still missing shows up at once.
    static let agentPrompt = """
    Set up Pier's server, pierd, on this machine so my phone and my Mac can follow the coding agents running here. \
    Do everything as my user.
    1. Run: \(PierLinks.installCommand)
    It installs pierd from github.com/wagnerfnds/pier, installs Claude Code, Codex and the GitHub CLI where they are \
    missing (in ~/.local/bin, no sudo), runs pierd as a user service, installs the agents' hooks, adds the git \
    repositories it finds as projects and prints a pier:// pairing link with its QR code. If it cannot run here, use \
    \(PierLinks.npmCommand) instead. I will sign in to the agents and GitHub from the Pier app.
    2. On Linux, pierd keeps running after I log out only with lingering on: setup turns it on when the system lets my \
    user do it. If pierd doctor still says it stops at logout, run loginctl enable-linger $USER (no sudo); only if that \
    is refused, ask me before running sudo loginctl enable-linger $USER.
    3. If a repository I work in is missing, add it with: pierd location add <name> <path>.
    4. Show me the pier:// link (I will scan or paste it), then run pierd doctor and tell me what it reports.
    """

    private struct Command: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let command: String
    }

    private let commands: [Command] = [
        Command(id: "install", title: "Instale e pareie (um QR code aparece)", command: PierLinks.installCommand),
        Command(id: "npm", title: "Ou pelo npm", command: PierLinks.npmCommand),
        Command(id: "brew", title: "Ou pelo Homebrew", command: PierLinks.brewCommand),
        Command(id: "linger", title: "No Linux, deixe o pierd rodando depois do logout (o setup já tenta, sem sudo)", command: "loginctl enable-linger $USER"),
        Command(id: "linger-admin", title: "Se o sistema recusar, quem administra a máquina roda", command: "sudo loginctl enable-linger $USER"),
        Command(id: "pair", title: "Um link de pareamento novo, quando precisar", command: "pierd pair"),
        Command(id: "relay", title: "Opcional: um relay seu no lugar do túnel do Pier (pierd relay install num servidor)",
                command: "pierd relay use HOST --token TOKEN"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("O pierd é o pequeno servidor que roda os agentes: num servidor ou no seu Mac. Dois jeitos de instalar.")
                        .font(.subheadline).foregroundStyle(Theme.textDim)
                    section(title: "Peça ao seu agente", symbol: "sparkles") {
                        Text("Já roda o Claude Code ou o Codex nessa máquina? Cole este pedido lá: ele instala e pareia o pierd, e mostra o link pier:// para você escanear.")
                            .font(.subheadline).foregroundStyle(Theme.textDim)
                        Text(Self.agentPrompt).font(.mono(11.5)).foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIdentifier("install-help-prompt")
                        copyButton(id: "prompt", text: Self.agentPrompt, label: "Copiar o pedido")
                            .accessibilityIdentifier("install-help-copy-prompt")
                    }
                    section(title: "Ou rode você mesmo", symbol: "terminal") {
                        ForEach(commands) { c in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(c.title).font(.footnote).foregroundStyle(Theme.textDim)
                                HStack(alignment: .center, spacing: 8) {
                                    Text(c.command).font(.mono(12)).foregroundStyle(Theme.text).textSelection(.enabled)
                                        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    copyButton(id: c.id, text: c.command, label: "Copiar")
                                }
                            }
                        }
                        Text("Já tem o pierd? Rode  pierd pair  e volte aqui para escanear.")
                            .font(.footnote).foregroundStyle(Theme.textFaint)
                    }
                }
                .padding(20)
            }
            .pierBackground()
            .navigationTitle("Instalar o pierd")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
    }

    @ViewBuilder private func section<Content: View>(title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(Theme.text)
            content()
        }
    }

    private func copyButton(id: String, text: String, label: LocalizedStringKey) -> some View {
        let done = copied == id
        return Button {
            UIPasteboard.general.string = text
            Haptic.impact(.light)
            withAnimation(.snappy) { copied = id }
            Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation(.snappy) { if copied == id { copied = nil } } }
        } label: {
            Label(done ? "Copiado" : label, systemImage: done ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.semibold)).foregroundStyle(done ? Theme.green : Theme.accent)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background((done ? Theme.green : Theme.accent).opacity(0.13), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(done ? text : "")   // what went to the clipboard (the UI tests cannot read it)
    }
}
