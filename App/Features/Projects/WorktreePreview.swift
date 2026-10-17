import SwiftUI
import PierKit

/// The words for a worktree's preparation, shared by the composer, Agentes and Detalhes.
enum PrepareText {
    /// A way to prepare a new worktree, as a chip or a menu item.
    static func choice(_ m: PrepareMode) -> String {
        switch m {
        case .none: String(localized: "Só o código")
        case .script: String(localized: "Script do projeto")
        case .agent: String(localized: "Agente prepara")
        }
    }

    /// What the way picked does, under the chips.
    static func choiceDetail(_ m: PrepareMode) -> String {
        switch m {
        case .none: String(localized: "Só o código; prepare depois em Detalhes")
        case .script: String(localized: "Setup e serviços automáticos ao criar")
        case .agent: String(localized: "Um agente instala o que falta, sobe o servidor e cria um login de teste, ao lado da sua tarefa")
        }
    }
}

/// A worktree's preview in Detalhes and in the session's inspector (`GET …/preview`, docs/API.md §2.12.1): the page the
/// setup agent (or another) recorded, at its public link first (Copiar, Abrir, Enviar, and in Detalhes Abrir no Pier; a
/// link is made by the box itself, a day at a time, and renewed while the worktree is there), then on the box's own
/// address, and the app's test login with the password hidden until asked for (again for each worktree: its owner gives
/// the block the worktree's identity).
struct WorktreePreviewBlock: View {
    let preview: WorktreePreview
    /// The box's address as this device reaches it (empty through a relay).
    let host: String
    /// Whether the page answers on the box's own address from here (nil: not checked).
    var reachable: Bool? = nil
    /// The worktree, where its page can open in the app's own browser too (Detalhes: Abrir no Pier).
    var place: WorktreeDetailsRoute? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = Previews.publicURL(preview) { publicLink(url) }
            if let url = Previews.directURL(preview, host: host) { directLink(url) }
            if let login = preview.login { loginBlock(login) }
            if let note = preview.note {
                Text(note).font(.caption).foregroundStyle(Theme.textDim).textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    /// The public link, the way to send the page to anyone: big enough to read, with its actions beside it.
    private func publicLink(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "globe.americas.fill").foregroundStyle(Theme.green)
                Text(url.absoluteString).font(.mono(13)).foregroundStyle(Theme.text).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("preview-public-link")
                Spacer(minLength: 4)
            }
            HStack(spacing: 14) {
                Button { copy(url.absoluteString, S("Link público copiado.")) } label: { Label("Copiar", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("preview-copy-link")
                Button { openURL(url) } label: { Label("Abrir", systemImage: "safari") }
                    .accessibilityIdentifier("preview-open-link")
                ShareLink(item: url) { Label("Enviar", systemImage: "square.and.arrow.up") }
                if let place { PreviewOpenButton(box: place.box, location: place.location, worktree: place.worktree, url: url) }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
            if let s = preview.share, let expires = s.expires {
                Text(s.auto ? S("Público até \(expires.formatted(date: .abbreviated, time: .shortened)), renovado enquanto a worktree existir.")
                            : S("Público até \(expires.formatted(date: .abbreviated, time: .shortened)): qualquer pessoa com o link vê a página."))
                    .font(.caption2).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func directLink(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Circle().fill(reachable == true ? Theme.green : reachable == false ? Theme.orange : Theme.textFaint).frame(width: 7, height: 7)
            Text(url.absoluteString).font(.mono(12)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 4)
            if let place { PreviewOpenButton(box: place.box, location: place.location, worktree: place.worktree, url: url) }
            Button { openURL(url) } label: { Image(systemName: "safari") }.buttonStyle(.borderless).accessibilityLabel("Abrir")
            Button { copy(url.absoluteString, S("Link copiado.")) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                .accessibilityLabel("Copiar link")
        }
        .font(.subheadline)
        .accessibilityIdentifier("preview-direct-link")
    }

    /// The app's test login: the user in sight, the password behind a tap, each with its copy button.
    private func loginBlock(_ login: PreviewLogin) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Acesso de teste").font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").foregroundStyle(Theme.textFaint).frame(width: 18)
                Text(login.user).font(.mono(13)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .accessibilityIdentifier("preview-login-user")
                Spacer(minLength: 4)
                Button { copy(login.user, S("Usuário copiado.")) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    .accessibilityLabel("Copiar usuário").accessibilityIdentifier("preview-copy-user")
            }
            if let password = login.password {
                HStack(spacing: 8) {
                    Image(systemName: "key").foregroundStyle(Theme.textFaint).frame(width: 18)
                    Text(revealed ? password : String(repeating: "•", count: min(max(password.count, 6), 12)))
                        .font(.mono(13)).foregroundStyle(Theme.text).lineLimit(1).textSelection(.enabled)
                        .accessibilityLabel(revealed ? password : S("Senha escondida"))
                        .accessibilityIdentifier("preview-login-password")
                    Spacer(minLength: 4)
                    Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                        .accessibilityLabel(revealed ? S("Esconder senha") : S("Mostrar senha")).accessibilityIdentifier("preview-reveal-password")
                    Button { copy(password, S("Senha copiada.")) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                        .accessibilityLabel("Copiar senha").accessibilityIdentifier("preview-copy-password")
                }
            }
            if let note = login.note { Text(note).font(.caption2).foregroundStyle(Theme.textFaint) }
        }
        .padding(10)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func copy(_ text: String, _ said: String) {
        UIPasteboard.general.string = text
        model.toast = AppToast(text: said, symbol: "doc.on.doc")
    }
}

/// Visualização in the session's inspector, for a session in a worktree: the worktree's preview (the same block as its
/// Detalhes, from a `WorktreeDetailsStore` the inspector keeps up to date: `follow`), else the dev servers listening
/// there. Nothing while neither.
struct SessionPreviewSection: View {
    let store: WorktreeDetailsStore

    @Environment(AppModel.self) private var model

    private var host: String { model.connection(for: store.box)?.record.host ?? "" }

    var body: some View {
        if let p = store.preview, !p.isEmpty {
            Section("Visualização") {
                WorktreePreviewBlock(preview: p, host: host, reachable: p.port.flatMap { store.reachable[$0] })
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("session-preview")
            }
            .listRowBackground(Theme.card)
        } else if !store.servers.isEmpty {
            Section("Visualização") {
                ForEach(store.servers) { s in
                    if let url = Projects.previewURL(host: host, port: s.port) {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Circle().fill(store.reachable[s.port] == false ? Theme.orange : Theme.green).frame(width: 7, height: 7)
                                Text(url.absoluteString).font(.mono(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }
            }
            .listRowBackground(Theme.card)
        }
    }

    /// Keeps the store's preview and dev servers current: now, every 15 s, and when the box says they changed. Runs
    /// from a view that is always there (a section with nothing to show has no task of its own).
    @MainActor static func follow(_ store: WorktreeDetailsStore, model: AppModel) async {
        let events = Task { @MainActor in
            for await h in model.hub.subscribe() where h.box == store.box {
                let t = h.event.type
                if t.hasPrefix("preview.") || t.hasPrefix("share.") || t.hasPrefix("worktree.prepare") || t.hasPrefix("service.") {
                    await store.load(model: model, previewOnly: true)
                }
            }
        }
        defer { events.cancel() }
        while !Task.isCancelled {
            await store.load(model: model, previewOnly: true)
            try? await Task.sleep(for: .seconds(15))
        }
    }
}
