import SwiftUI

/// "Ainda sem pierd na box?": the two ways to put pierd on a box before pairing. The quick one hands the job to the agent
/// already running there (the prompt is copied and pasted into Claude Code or Codex on the box, which builds, installs
/// and pairs pierd and prints the pier:// link); the other lists the commands, each with Copiar. Reached from the pairing
/// step of the onboarding and from "Adicionar box" in Ajustes.
struct InstallHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    /// What the agent on the box is asked to do (in English, the language every agent reads best). `pierd doctor` at the
    /// end so what is still missing shows up at once.
    static let agentPrompt = """
    Set up Pier's server, pierd, on this machine so my phone can follow the coding agents running here. Its source is \
    in the Pier repository under Server/pierd (Go 1.25, standard library only; clone the repository first if it is not \
    on this machine). Do everything as my user; the only sudo allowed is step 3.
    1. In Server/pierd run: GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o pierd ./cmd/pierd, then put \
    the binary in ~/.local/bin (make sure that folder is on the PATH).
    2. Run: pierd install --listen <this machine's Tailscale or LAN address>:7444 (installs a user service and the \
    agents' hooks).
    3. Run: sudo loginctl enable-linger $USER, so pierd keeps running after I log out.
    4. For each repository I work in on this machine run: pierd location add <name> <path>.
    5. Run: pierd pair, and show me the pier:// link it prints (I will scan or paste it on my phone).
    Finally run pierd doctor and tell me what it reports.
    """

    private struct Command: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let command: String
    }

    private let commands: [Command] = [
        Command(id: "build", title: "Compile o pierd (na pasta Server/pierd do repositório)",
                command: "GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o pierd ./cmd/pierd"),
        Command(id: "install", title: "Na box, instale o serviço e os hooks dos agentes",
                command: "pierd install --listen <endereço-da-box>:7444"),
        Command(id: "linger", title: "Deixe o pierd rodando depois do logout",
                command: "sudo loginctl enable-linger $USER"),
        Command(id: "location", title: "Aponte os repositórios que o app deve ver",
                command: "pierd location add <nome> <caminho>"),
        Command(id: "pair", title: "Gere o link de pareamento (um QR code aparece)",
                command: "pierd pair"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("O pierd é o pequeno servidor que cada box roda. Dois jeitos de colocá-lo lá.")
                        .font(.subheadline).foregroundStyle(Theme.textDim)
                    section(title: "Peça ao seu agente", symbol: "sparkles") {
                        Text("Já roda o Claude Code ou o Codex nessa box? Cole este pedido lá: ele compila, instala e pareia o pierd, e mostra o link pier:// para você escanear.")
                            .font(.subheadline).foregroundStyle(Theme.textDim)
                        Text(Self.agentPrompt).font(.mono(11.5)).foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIdentifier("install-help-prompt")
                        copyButton(id: "prompt", text: Self.agentPrompt, label: "Copiar o pedido")
                            .accessibilityIdentifier("install-help-copy-prompt")
                    }
                    section(title: "Ou faça na mão", symbol: "terminal") {
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
            .navigationTitle("Pôr o pierd na box")
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
