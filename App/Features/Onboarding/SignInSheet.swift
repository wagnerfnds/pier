import SwiftUI
import PierKit

/// Signing in to Claude Code, Codex or GitHub on a box from the app, with no terminal (`/v1/logins`, capability `logins`):
/// the box runs the CLI's own sign-in and reads its link and one-time code off the screen. Here the person opens the link
/// in their browser (a device sign-in's code is copied first, and shown large to type on the page), pastes back the code
/// Claude Code's page shows (`PasteButton`: no paste prompt), and follows how it goes (`GET /v1/logins/{id}` every 1.5 s
/// while it runs, at once on `login.changed`). "Abrir no terminal" shows the CLI's session for whatever this does not
/// cover. Closing the sheet before it is done cancels the sign-in on the box.
struct SignInSheet: View {
    let request: SignInRequest
    /// Shows the sign-in's session as a terminal (the sheet is closed first; the sign-in goes on there).
    var openTerminal: ((Session) -> Void)? = nil
    /// Called once it is done.
    var onDone: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var login: Login?
    @State private var startError: String?
    @State private var code = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var codeCopied = false
    @State private var opened = false
    /// "Abrir no terminal" was chosen: closing the sheet leaves the sign-in running.
    @State private var keep = false
    /// Bumped by "Tentar de novo": a new sign-in.
    @State private var attempt = 0
    @FocusState private var codeFocused: Bool

    private var conn: BoxConnection? { model.connection(for: request.box) }
    private var api: BoxAPI? { conn.map { BoxAPI(transport: $0.raw) } }
    private var name: String { SignIn.name(of: request.tool) }
    private var step: SignIn.Step { startError.map { .failed($0) } ?? SignIn.step(login) }
    private var cleanCode: String { SignIn.cleanCode(code) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    switch step {
                    case .done: done
                    case .failed(let why): failed(why)
                    default: steps
                    }
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .pierBackground()
            .navigationTitle(Text("Entrar no \(name)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step != .done { Button("Cancelar") { dismiss() }.accessibilityIdentifier("sign-in-cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == .done { Button("Concluir") { dismiss() }.accessibilityIdentifier("sign-in-finish") }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
        .task(id: attempt) { await start() }
        .task(id: login?.id) { await follow() }
        .task {
            // The box says when a sign-in moves: read it at once rather than at the next poll.
            for await h in model.hub.subscribe() where h.box == request.box && h.event.type == "login.changed" && h.event.str("id") == login?.id {
                await refresh()
            }
        }
        .onDisappear { cancelIfRunning() }
        .accessibilityIdentifier("sign-in-sheet")
    }

    // MARK: parts

    private var header: some View {
        HStack(spacing: 14) {
            ToolGlyph(tool: request.tool, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.textDim)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let n = request.accountName { return S("Conta \(n) na box \(request.box)") }
        return S("Na box \(request.box)")
    }

    /// What is happening now, in one line.
    private var status: some View {
        HStack(spacing: 8) {
            switch step {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Preparando o login na box…")
            case .open:
                ProgressView().controlSize(.small)
                Text(opened ? "Esperando você confirmar na página…" : "Abra a página e digite o código.")
            case .paste:
                Image(systemName: "arrow.down.doc").foregroundStyle(Theme.accent)
                Text("Depois de entrar, a página mostra um código: cole aqui.")
            case .confirming:
                ProgressView().controlSize(.small)
                Text("Conferindo com o \(name)…")
            case .done, .failed:
                EmptyView()
            }
        }
        .font(.subheadline).foregroundStyle(Theme.textDim)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sign-in-status")
    }

    @ViewBuilder private var steps: some View {
        status
        stepCard(n: 1, title: "Abra a página de login") {
            if let userCode = login?.userCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Na página, digite este código:").font(.footnote).foregroundStyle(Theme.textDim)
                    HStack(spacing: 10) {
                        Text(userCode)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.text).textSelection(.enabled)
                            .minimumScaleFactor(0.6).lineLimit(1)
                            .accessibilityIdentifier("sign-in-user-code")
                        Spacer(minLength: 0)
                        Button { copy(userCode) } label: {
                            Label(codeCopied ? "Copiado" : "Copiar", systemImage: codeCopied ? "checkmark" : "doc.on.doc")
                                .font(.footnote.weight(.semibold)).foregroundStyle(codeCopied ? Theme.green : Theme.accent)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background((codeCopied ? Theme.green : Theme.accent).opacity(0.13), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sign-in-copy-code")
                    }
                }
            }
            Button { openPage() } label: {
                Label(login?.userCode != nil ? "Copiar o código e abrir a página" : "Abrir a página de login", systemImage: "safari")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(login?.url == nil)
            .accessibilityIdentifier("sign-in-open")
            if let url = login?.url {
                Text(url.host() ?? url.absoluteString).font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
        }
        if login?.needsCode ?? (request.tool == "claude") {
            stepCard(n: 2, title: "Cole aqui o código") {
                HStack(spacing: 8) {
                    TextField("Código da página", text: $code)
                        .font(.mono(14))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($codeFocused)
                        .submitLabel(.send)
                        .onSubmit { Task { await send() } }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityIdentifier("sign-in-code")
                    PasteButton(payloadType: String.self) { strings in
                        code = SignIn.cleanCode(strings.first ?? "")
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("sign-in-paste")
                }
                if let e = sendError ?? (step == .paste ? login?.error : nil) {
                    Text(e).font(.footnote).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
                Button { Task { await send() } } label: {
                    if sending { ProgressView().tint(.white) } else { Text("Enviar") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(cleanCode.isEmpty || sending || step != .paste)
                .accessibilityIdentifier("sign-in-send")
            }
        }
        if openTerminal != nil, let session = login?.session, !session.isEmpty {
            Button { Task { await terminal(session) } } label: {
                Label("Abrir no terminal", systemImage: "terminal")
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("sign-in-terminal")
            Text("Se algo aqui não funcionar, o login continua no terminal da box, onde dá para copiar e colar.")
                .font(.caption).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var done: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.green)
            Text("\(name) conectado").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            Text("Os agentes da box \(request.box) já podem usar esta conta.")
                .font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            Button("Concluir") { dismiss() }.buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sign-in-done")
    }

    private func failed(_ why: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Não foi possível entrar", systemImage: "xmark.octagon.fill").font(.headline).foregroundStyle(Theme.red)
            if let why, !why.isEmpty {
                Text(why).font(.mono(12)).foregroundStyle(Theme.textDim).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Button("Tentar de novo") { attempt += 1 }.buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("sign-in-retry")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sign-in-failed")
    }

    private func stepCard<Content: View>(n: Int, title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(n)").font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
                    .frame(width: 24, height: 24).background(Theme.accent.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                Text(title).font(.headline).foregroundStyle(Theme.text)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }

    // MARK: actions

    private func start() async {
        login = nil; startError = nil; code = ""; sendError = nil; opened = false
        guard let api else { startError = S("A box \(request.box) não está conectada."); return }
        do {
            login = try await api.startLogin(tool: request.tool, account: request.account)
        } catch {
            startError = ComposeErrorText.message(error)
        }
    }

    /// Reads the sign-in again every 1.5 s until it is done or failed.
    private func follow() async {
        while let l = login, !l.state.isFinal, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
            await refresh()
        }
    }

    private func refresh() async {
        guard let api, let id = login?.id else { return }
        do {
            apply(try await api.login(id: id))
        } catch let e as BoxError where e.status == 404 {
            // pierd restarted: its sign-ins went with it.
            startError = S("A box perdeu este login (o pierd reiniciou?). Tente de novo.")
        } catch {}
    }

    private func apply(_ l: Login) {
        let was = login?.state
        login = l
        if l.state == .enterCode, was == .waiting { code = "" }
        if l.state == .done, was != .done {
            Haptic.success()
            onDone()
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        Haptic.impact(.light)
        withAnimation(.snappy) { codeCopied = true }
        Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation(.snappy) { codeCopied = false } }
    }

    /// The code first (a device sign-in asks for it on the page, where pasting is quicker than typing), then the page.
    private func openPage() {
        guard let url = login?.url else { return }
        if let c = login?.userCode { copy(c) }
        opened = true
        openURL(url)
        if login?.needsCode == true { codeFocused = true }
    }

    private func send() async {
        let c = cleanCode
        guard let api, let id = login?.id, !c.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            apply(try await api.sendLoginCode(id: id, code: c))
            sendError = nil
        } catch {
            sendError = ComposeErrorText.message(error)
        }
    }

    private func terminal(_ name: String) async {
        guard let conn, let openTerminal else { return }
        await conn.refreshSessions()
        guard let s = conn.sessions.first(where: { $0.name == name }) else { return }
        keep = true
        dismiss()
        openTerminal(s)
    }

    private func cancelIfRunning() {
        guard !keep, let api, let l = login, !l.state.isFinal else { return }
        Task { try? await api.cancelLogin(id: l.id) }
    }
}
