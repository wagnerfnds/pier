import SwiftUI
import UserNotifications
import PierKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var confirmUnpair: BoxConnection?
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(TalkCenter.sendDirectKey) private var talkSendDirect = false
    #if DEBUG
    /// `-openInvite 1` (with `-startTab settings`): opens "Levar para o iPhone".
    @State private var debugInvite = UserDefaults.standard.bool(forKey: "openInvite")
    #endif

    var body: some View {
        @Bindable var router = router
        Form {
            Section("Boxes") {
                ForEach(model.boxes) { conn in
                    BoxSettingsRow(conn: conn)
                        .swipeActions {
                            Button("Desparear", role: .destructive) { confirmUnpair = conn }
                        }
                        .listRowBackground(Theme.card)
                }
                Button { router.showAddBox = true } label: { Label("Adicionar box", systemImage: "plus.circle") }
                    .listRowBackground(Theme.card)
                // Pair another device with the same boxes, no terminal needed (InviteDeviceScreen).
                if !model.boxes.isEmpty {
                    NavigationLink { InviteDeviceScreen() } label: {
                        Label(InviteDeviceScreen.title, systemImage: "qrcode")
                    }
                    .accessibilityIdentifier("settings-invite-device")
                    .listRowBackground(Theme.card)
                }
            }
            Section("Aparência") {
                Picker("Aparência", selection: $appearance) {
                    ForEach(Appearance.allCases) { a in Text(a.title).tag(a) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance-picker")
                .listRowBackground(Theme.card)
            }
            Section {
                NavigationLink(value: HousekeepingRoute()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Faxina", systemImage: "sparkles")
                        if let last = LastHousekeeping.load() {
                            Text("Última: \(last.date.formatted(.relative(presentation: .named))) · \(last.summary)")
                                .font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
                        }
                    }
                }
                .listRowBackground(Theme.card)
            } header: { Text("Manutenção") } footer: {
                Text("Atualiza a main de cada projeto e limpa worktrees, serviços e sessões que sobraram. Para rodar sozinha, crie uma automação no app Atalhos com “Faxina nas boxes”.")
            }
            UndoSettingsSection()
            #if targetEnvironment(macCatalyst)
            MacSurfaceSettingsSection()
            #endif
            Section {
                Toggle("Enviar direto", isOn: $talkSendDirect).listRowBackground(Theme.card)
                    .accessibilityIdentifier("talk-send-direct")
            } header: { Text("Falar") } footer: {
                Text("Ligado, o pedido vai na hora para o agente que o Pier escolher. Desligado, o Pier mostra a decisão e espera você tocar em Enviar.")
            }
            Section("Notificações") {
                HStack {
                    Text("Avisar quando um agente precisar de você ou terminar").font(.subheadline)
                    Spacer()
                }.listRowBackground(Theme.card)
                switch model.notifications.status {
                case .authorized, .provisional, .ephemeral:
                    Label("Ativadas", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).listRowBackground(Theme.card)
                case .denied:
                    Button("Ativar em Ajustes do iOS") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }.listRowBackground(Theme.card)
                default:
                    Button("Permitir notificações") { Task { await model.notifications.requestAuthorization() } }
                        .listRowBackground(Theme.card)
                }
                Text("Com o push configurado no pierd da box, as notificações chegam na hora, mesmo com o app fechado. Sem ele, chegam com o app aberto ou quando o iOS atualiza em segundo plano.")
                    .font(.footnote).foregroundStyle(Theme.textFaint).listRowBackground(Color.clear)
            }
            PushSettingsSection()
            Section("Sobre") {
                LabeledContent("Versão", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    .listRowBackground(Theme.card)
                LabeledContent("Este aparelho", value: model.clientName()).listRowBackground(Theme.card)
                if let id = model.identity {
                    LabeledContent("Chave") { MonoText(id.fingerprint.short, size: 12) }.listRowBackground(Theme.card)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .pierBackground()
        .navigationTitle("Ajustes")
        .sheet(isPresented: $router.showAddBox) {
            OnboardingView(embedded: true).environment(model).environment(router)
                .presentationDetents([.large])
        }
        .confirmationDialog("Desparear \(confirmUnpair?.name ?? "")?", isPresented: .constant(confirmUnpair != nil), titleVisibility: .visible) {
            Button("Desparear", role: .destructive) {
                if let c = confirmUnpair { Task { await model.unpair(c) } }
                confirmUnpair = nil
            }
            Button("Cancelar", role: .cancel) { confirmUnpair = nil }
        } message: {
            Text("O app esquece esta box. Para revogar o acesso de vez, use “pierd revoke” na box.")
        }
        .task { await model.notifications.refreshStatus() }
        #if DEBUG
        .navigationDestination(isPresented: $debugInvite) { InviteDeviceScreen() }
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Ajustes → Mac: the edge surface (the tab at the screen's edge with the toolbar and the Inbox card), the ⌥ double tap
/// and "point at it", with the macOS permissions each one needs and where to grant them.
struct MacSurfaceSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MacSurfaceSettings.enabledKey) private var enabled = true
    @AppStorage(MacSurfaceSettings.edgeKey) private var edge = "right"
    @AppStorage(MacSurfaceSettings.fractionKey) private var fraction = 0.55
    @AppStorage(MacSurfaceSettings.displayKey) private var display = "main"
    @AppStorage(MacSurfaceSettings.sizeKey) private var size = "medium"
    @AppStorage(MacSurfaceSettings.fullScreenKey) private var fullScreen = false
    @AppStorage(MacSurfaceSettings.optionTapKey) private var optionTap = true
    @AppStorage(MacSurfaceSettings.menuBarKey) private var menuBar = false
    private var bridge: MenuBarBridge { .shared }

    var body: some View {
        Section {
            Toggle("Aba na borda da tela", isOn: $enabled).listRowBackground(Theme.card)
                .accessibilityIdentifier("mac-surface-enabled")
                .onChange(of: enabled) { _, on in if !on { menuBar = true } }   // never both off (MacSurfaceSettings.enforce)
            if enabled {
                Picker("Borda", selection: $edge) {
                    Text("Esquerda").tag("left")
                    Text("Direita").tag("right")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Theme.card)
                // Where along the edge (the tab's drag writes the same value; the tab moves as the slider does).
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Posição na borda")
                        Spacer()
                        Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                    }
                    Slider(value: $fraction, in: 0...1) { Text("Posição na borda") } minimumValueLabel: { Text("Topo").font(.caption2) } maximumValueLabel: { Text("Base").font(.caption2) }
                        .accessibilityIdentifier("mac-surface-fraction")
                }
                .listRowBackground(Theme.card)
                Picker("Tamanho", selection: $size) {
                    Text("Pequeno").tag("small")
                    Text("Médio").tag("medium")
                    Text("Grande").tag("large")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Theme.card)
                .accessibilityIdentifier("mac-surface-size")
                Picker("Tela", selection: $display) {
                    Text("Principal").tag("main")
                    Text("Onde está o ponteiro").tag("pointer")
                    ForEach(bridge.screens, id: \.id) { s in Text(s.name).tag(String(s.id)) }
                }
                .listRowBackground(Theme.card)
                Toggle("Mostrar sobre apps em tela cheia", isOn: $fullScreen).listRowBackground(Theme.card)
            }
            Text("⌃⌥P mostra ou esconde a aba, de qualquer app.").font(.footnote).foregroundStyle(Theme.textFaint).listRowBackground(Theme.card)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Mostrar na barra de menus", isOn: $menuBar)
                    .accessibilityIdentifier("mac-menu-bar")
                    .onChange(of: menuBar) { _, on in if !on, !enabled { enabled = true } }
                Text("Os pontinhos na barra de menus do macOS. Desligada, liga sozinha quando a aba da borda é escondida, para o Pier nunca ficar sem uma presença na tela.")
                    .font(.footnote).foregroundStyle(Theme.textFaint)
            }
            .listRowBackground(Theme.card)
            Toggle("Dois toques em ⌥ abrem Falar", isOn: $optionTap).listRowBackground(Theme.card)
                .accessibilityIdentifier("mac-option-tap")
                .onChange(of: optionTap) { _, on in
                    // The permission is asked only now, by the person's own choice; never at launch.
                    if on, !(bridge.permissions["optionTapGlobal"] ?? false) { bridge.requestPermission("inputMonitoring") }
                }
            if optionTap {
                permissionRow(granted: bridge.permissions["optionTapGlobal"] ?? false,
                              ok: "Funciona em qualquer app. ⌃⌥Espaço também abre Falar.",
                              missing: "Por enquanto só funciona com o Pier na frente (⌃⌥Espaço funciona em qualquer app). Para os dois toques valerem em qualquer app, permita o Monitoramento de Entrada do Pier.",
                              pane: "Privacy_ListenEvent", request: "inputMonitoring")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Apontar na tela", systemImage: "camera.viewfinder")
                    Spacer()
                    Button("Apontar agora…") { bridge.pointAt() }.font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("mac-point-now")
                }
                Text("⇧⌘A, o botão da câmera na barra ou o menu Ir: a tela escurece, você marca um pedaço dela e diz o que fazer; a imagem vai junto para o agente.")
                    .font(.footnote).foregroundStyle(Theme.textFaint)
            }
            .listRowBackground(Theme.card)
            permissionRow(granted: bridge.permissions["screenRecording"] ?? false,
                          ok: "Gravação de tela permitida.",
                          missing: "Na primeira vez o macOS pede a permissão de Gravação de Tela (depois, abra o Pier de novo).",
                          pane: "Privacy_ScreenCapture", request: nil)
        } header: { Text("Mac") } footer: {
            Text("A aba fica colada na borda da tela, sobre qualquer app: um indicador por agente; aberta, o Inbox com o que precisa de você (1, 2, 3 respondem; Esc desfaz), Falar, Ditar e Apontar. Arraste-a pela borda; o botão … tem mais opções.")
        }
        .task {
            // The person may flip the switch in System Settings while this screen is open.
            while !Task.isCancelled {
                bridge.refreshPermissions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Granted: a green check and a word; missing: the explanation, "Permitir…" (the system's dialog) and the pane.
    @ViewBuilder private func permissionRow(granted: Bool, ok: LocalizedStringKey, missing: LocalizedStringKey, pane: String, request: String?) -> some View {
        if granted {
            Label(ok, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.green).listRowBackground(Theme.card)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(missing, systemImage: "lock.shield").font(.footnote).foregroundStyle(Theme.orange)
                HStack(spacing: 8) {
                    if let request {
                        Button("Permitir…") { bridge.requestPermission(request) }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    Button("Abrir Ajustes do Sistema") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { UIApplication.shared.open(u) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .listRowBackground(Theme.card)
        }
    }
}
#endif

/// "Tempo para desfazer": how long answers and messages wait before they go out (`PendingActions`).
struct UndoSettingsSection: View {
    @AppStorage(PendingActions.secondsKey) private var seconds = PendingActions.defaultSeconds

    var body: some View {
        Section {
            Picker("Tempo para desfazer", selection: $seconds) {
                ForEach(PendingActions.choices, id: \.self) { s in
                    Text(s == 0 ? S("Desligado") : S("\(s) s")).tag(s)
                }
            }
            .accessibilityIdentifier("undo-seconds")
            .listRowBackground(Theme.card)
        } header: { Text("Respostas") } footer: {
            Text("Respostas e mensagens esperam esse tempo antes de sair, com “Desfazer” embaixo da tela (Esc ou ⌘Z no teclado).")
        }
    }
}

struct BoxSettingsRow: View {
    let conn: BoxConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                BoxChipDot(state: conn.state)
                Text(conn.name).font(.headline)
                Spacer()
                Text(label).font(.caption).foregroundStyle(Theme.textDim)
            }
            MonoText(conn.record.address, size: 12)
            MonoText("SHA \(conn.record.fingerprint.short)", size: 11, color: Theme.textFaint)
        }
        .padding(.vertical, 2)
    }
    private var label: LocalizedStringKey {
        switch conn.state {
        case .online: "online"
        case .connecting: "conectando…"
        case .offline: "offline"
        case .revoked: "acesso revogado"
        case .pinMismatch: "chave diferente"
        }
    }
}

struct BoxChipDot: View {
    let state: ConnState
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
    private var color: Color {
        switch state {
        case .online: Theme.green
        case .connecting: Theme.accent
        case .offline: Theme.red
        case .revoked, .pinMismatch: Theme.orange
        }
    }
}


/// "Push remoto": which events to push, the test button and the push status per box.
struct PushSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let push = model.push
        @Bindable var pushBindable = push
        Section("Push remoto") {
            Toggle("Precisa de você", isOn: $pushBindable.events.waiting).listRowBackground(Theme.card)
            Toggle("Concluído", isOn: $pushBindable.events.finished).listRowBackground(Theme.card)
            Toggle("Trabalhando", isOn: $pushBindable.events.working).listRowBackground(Theme.card)
            if let err = push.registrationError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.orange)
                    .listRowBackground(Theme.card)
            } else if push.deviceToken == nil {
                Label("Aguardando o token do aparelho…", systemImage: "hourglass").font(.footnote).foregroundStyle(Theme.textDim)
                    .listRowBackground(Theme.card)
            }
            ForEach(model.boxes) { conn in
                PushBoxRow(conn: conn).listRowBackground(Theme.card)
            }
            if model.boxes.isEmpty {
                Text("Pareie uma box para receber push.").font(.footnote).foregroundStyle(Theme.textFaint)
                    .listRowBackground(Color.clear)
            }
        }
    }
}

struct PushBoxRow: View {
    @Environment(AppModel.self) private var model
    let conn: BoxConnection

    var body: some View {
        let push = model.push
        let st = push.status[conn.name] ?? .unknown
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color(st)).frame(width: 9, height: 9)
                Text(conn.name).font(.headline)
                Spacer()
                Text(label(st)).font(.caption).foregroundStyle(Theme.textDim)
            }
            if st == .unreachable {
                Text("Esta box não respondeu às rotas de push. Configure o push no pierd da box (~/.config/pier/push.json com a chave da APNs) e abra o app de novo. Enquanto isso, o app avisa por conta própria, só com o app aberto ou quando o iOS atualiza em segundo plano.")
                    .font(.footnote).foregroundStyle(Theme.textFaint)
            } else if case .failed(let why) = st {
                Text(failText(why)).font(.footnote).foregroundStyle(Theme.textFaint)
            }
            HStack {
                Button {
                    Task { await push.sendTest(box: conn.name) }
                } label: {
                    if push.testing.contains(conn.name) { ProgressView() } else { Text("Enviar notificação de teste") }
                }
                .disabled(!st.isRegistered || push.testing.contains(conn.name))
                Spacer()
                switch push.testResult[conn.name] {
                case .sent: Label("Enviada", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.green)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(Theme.red).lineLimit(2)
                case nil: EmptyView()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func label(_ s: BoxPushStatus) -> LocalizedStringKey {
        switch s {
        case .unknown: "—"
        case .registering: "registrando…"
        case .registered: "registrado"
        case .unreachable: "push indisponível"
        case .failed: "erro"
        }
    }
    private func color(_ s: BoxPushStatus) -> Color {
        switch s {
        case .registered: Theme.green
        case .registering, .unknown: Theme.accent
        case .unreachable: Theme.orange
        case .failed: Theme.red
        }
    }
    private func failText(_ why: String) -> LocalizedStringKey {
        switch why {
        case "unauthorized": "O pierd não reconhece este aparelho. Pareie de novo com “pierd pair”."
        case "pin": "A chave do push não confere com a da box."
        default: "O pierd recusou o registro: \(why)"
        }
    }
}
