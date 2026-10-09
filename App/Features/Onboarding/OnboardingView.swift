import SwiftUI
import PierKit

/// First run in three short steps: 1 "Oi, é o Pier" (what it does), 2 "Como funciona" (box runs the agents · the app shows
/// who needs you · answer from anywhere), 3 pair (scan the QR / paste the link; the Mac only pastes). The pairing sheet
/// (RootView, `router.pendingPair`) closes by itself when it works and the flow ends on "Tudo pronto!": what is connected,
/// notifications, the first task. From Ajustes ("Adicionar box", `embedded`) only the pairing step shows.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    var embedded = false          // true when shown from Settings
    @State private var step: Step = .hello
    @State private var forward = true
    @State private var showScanner = false
    @State private var showPaste = false
    @State private var showInstallHelp = false

    enum Step: Int, CaseIterable { case hello, how, pair, done }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded && step != .done { progress.padding(.top, 18) }
            ZStack {
                switch embedded ? .pair : step {
                case .hello: OnboardingHello().transition(slide)
                case .how: OnboardingHow().transition(slide)
                case .pair: OnboardingPair(embedded: embedded).transition(slide)
                case .done: OnboardingDone(finish: finish, newTask: firstTask).transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if step != .done || embedded { buttons.padding(.horizontal, 24).padding(.bottom, 28) }
        }
        .frame(maxWidth: 560)   // a readable column on iPad and Mac windows
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pierBackground()
        #if !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerScreen { text in
                showScanner = false
                if let link = PairingLink.find(in: text) { router.pendingPair = PendingPair(link: link) }
            }
        }
        #endif
        .sheet(isPresented: $showPaste) { PasteLinkSheet() }
        .sheet(isPresented: $showInstallHelp) { InstallHelpSheet() }
        #if DEBUG
        // Screenshot hook: `-openInstallHelp 1` lands on the pairing step with the help sheet up.
        .task {
            guard UserDefaults.standard.bool(forKey: "openInstallHelp") else { return }
            go(.pair)
            try? await Task.sleep(for: .milliseconds(600))
            showInstallHelp = true
        }
        #endif
        // A link opened from outside (another app, the camera) while the intro shows: jump to pairing, then end on "Tudo pronto!".
        .onChange(of: router.pendingPair?.id) { _, id in
            guard !embedded, id != nil, step != .done else { return }
            router.onboardingFinishing = true
            go(.pair)
        }
        .onChange(of: model.hasBoxes) { _, has in
            if has, !embedded, router.onboardingFinishing { go(.done) }
        }
    }

    // MARK: chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(i <= step.rawValue ? Theme.accent : Theme.cardRaised)
                    .frame(width: i == step.rawValue ? 26 : 8, height: 8)
            }
        }
        .animation(.snappy, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Passo \(step.rawValue + 1) de 3"))
        .accessibilityIdentifier("onboarding-progress")
    }

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 12) {
            switch embedded ? .pair : step {
            case .hello, .how:
                Button { go(Step(rawValue: step.rawValue + 1) ?? .pair) } label: { Text(step == .hello ? "Começar" : "Continuar") }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding-next")
            case .pair:
                // The Mac pairs by pasting the link (or opening it: the app handles pier://); no camera to scan with.
                #if targetEnvironment(macCatalyst)
                Button { showPaste = true } label: { Label("Colar link", systemImage: "doc.on.clipboard") }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding-paste")
                #else
                Button { showScanner = true } label: { Label("Escanear QR code", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding-scan")
                Button { showPaste = true } label: { Label("Colar link", systemImage: "doc.on.clipboard") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("onboarding-paste")
                #endif
                // A box with no pierd yet: the agent there can set it up, or the commands are a copy away.
                Button { showInstallHelp = true } label: { Text("Ainda sem pierd na box?") }
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("onboarding-install-help")
            case .done:
                EmptyView()
            }
            if !embedded, step == .how || step == .pair {
                Button { go(Step(rawValue: step.rawValue - 1) ?? .hello) } label: { Text("Voltar") }
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.textDim)
                    .padding(.top, 2)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("onboarding-back")
            }
        }
        .animation(.snappy, value: step)
    }

    private var slide: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(_ next: Step) {
        guard next != step else { return }
        forward = next.rawValue > step.rawValue
        if next == .pair { router.onboardingFinishing = true }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.88)) { step = next }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.3)) { router.onboardingFinishing = false }
    }

    private func firstTask() {
        finish()
        if let b = model.boxes.first(where: { $0.state.isOnline }) ?? model.boxes.first {
            Task { try? await Task.sleep(for: .milliseconds(350)); PaletteActions.newTask(router, box: b.name) }
        }
    }
}

// MARK: - step 1: hello

private struct OnboardingHello: View {
    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 12)
            AgentsToPhoneIllustration().frame(height: 150).padding(.horizontal, 12)
            VStack(spacing: 12) {
                Text("Oi, é o Pier").font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Os agentes da sua box de desenvolvimento, no seu bolso: veja quem está trabalhando, quem precisa de você e responda de onde estiver.")
                    .font(.body).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-step-1")
    }
}

/// A box with three agent dots sending little pulses to a phone that shows the same dots.
private struct AgentsToPhoneIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let colors = [Theme.orange, Theme.accent, Theme.green]

    var body: some View {
        HStack(spacing: 0) {
            // The box
            VStack(spacing: 10) {
                Image(systemName: "server.rack").font(.system(size: 30, weight: .medium)).foregroundStyle(Theme.textDim)
                HStack(spacing: 6) { ForEach(0..<3, id: \.self) { Circle().fill(colors[$0]).frame(width: 9, height: 9) } }
            }
            .frame(width: 92, height: 112)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
            // The pulses travelling to the phone
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
                Canvas { g, size in
                    let t = reduceMotion ? 0.5 : ctx.date.timeIntervalSinceReferenceDate
                    let y = size.height / 2
                    for x in stride(from: 6.0, through: size.width - 6, by: 10) {
                        g.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(Theme.textFaint.opacity(0.5)))
                    }
                    for i in 0..<3 {
                        let p = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        let x = 6 + p * (size.width - 12)
                        let fade = min(1, min(p, 1 - p) * 6)
                        g.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4 + Double(i - 1) * 9, width: 8, height: 8)),
                               with: .color(colors[i].opacity(fade)))
                    }
                }
            }
            .frame(maxWidth: 140)
            // The phone
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.textFaint.opacity(0.6), lineWidth: 2))
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<3, id: \.self) { i in
                        HStack(spacing: 6) {
                            Circle().fill(colors[i]).frame(width: 8, height: 8)
                            Capsule().fill(Theme.cardRaised).frame(width: [34, 26, 30][i], height: 6)
                        }
                    }
                }
            }
            .frame(width: 74, height: 132)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Os agentes da box chegam ao seu celular"))
    }
}

// MARK: - step 2: how it works

private struct OnboardingHow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer(minLength: 12)
            Text("Como funciona").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 22) {
                row(0, symbol: "server.rack", color: Theme.accent, title: "Sua box roda os agentes",
                    text: "Claude Code, Codex e outros trabalham na sua máquina de desenvolvimento, não no celular.")
                row(1, symbol: "circle.hexagongrid.fill", color: Theme.orange, title: "O app mostra quem precisa de você",
                    text: "Um ponto por agente: âmbar precisa de você, azul trabalhando, verde é sua vez.")
                row(2, symbol: "paperplane.fill", color: Theme.green, title: "Responda de qualquer lugar",
                    text: "Permita, responda ou mande a próxima tarefa, com uma notificação quando algo mudar.")
            }
            .padding(.horizontal, 6)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .onAppear { shown = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-step-2")
    }

    private func row(_ i: Int, symbol: String, color: Color, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(color)
                .frame(width: 48, height: 48)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(Theme.text)
                Text(text).font(.subheadline).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .opacity(shown || reduceMotion ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : 14)
        .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.08 + Double(i) * 0.09), value: shown)
    }
}

// MARK: - step 3: pair

private struct OnboardingPair: View {
    let embedded: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            Image(systemName: "qrcode.viewfinder").font(.system(size: 54, weight: .light)).foregroundStyle(Theme.accent)
                .frame(width: 104, height: 104)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.stroke))
                .accessibilityHidden(true)
            Text(embedded ? "Adicionar box" : "Conecte sua box").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                Step(n: 1, text: "Na box, rode  pierd pair  (ou abra “Levar para o iPhone” nos Ajustes de um aparelho já pareado).")
                #if targetEnvironment(macCatalyst)
                Step(n: 2, text: "Copie o link pier:// que aparece e cole aqui.")
                #else
                Step(n: 2, text: "Escaneie o QR code ou cole o link pier:// aqui.")
                #endif
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-step-3")
    }

    private struct Step: View {
        let n: Int
        let text: LocalizedStringKey
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Text("\(n)").font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
                    .frame(width: 24, height: 24).background(Theme.accent.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                Text(text).font(.subheadline).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - all set

private struct OnboardingDone: View {
    let finish: () -> Void
    let newTask: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.green)
                .scaleEffect(pop || reduceMotion ? 1 : 0.4).opacity(pop || reduceMotion ? 1 : 0)
                .accessibilityHidden(true)
            Text("Tudo pronto!").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(model.boxes) { b in
                    item(symbol: "checkmark.circle.fill", color: Theme.green, title: S("Box \(b.name) conectada"), detail: b.record.address)
                        .accessibilityElement(children: .combine)
                    Divider().overlay(Theme.stroke)
                }
                notificationsRow
                Divider().overlay(Theme.stroke)
                Button(action: newTask) {
                    item(symbol: "plus.bubble.fill", color: Theme.accent, title: S("Criar a primeira tarefa"), detail: S("Diga a um agente o que fazer"),
                         chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding-first-task")
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding-checklist")
            Spacer(minLength: 12)
            Button(action: finish) { Text("Ir para o início") }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, 24).padding(.bottom, 28)
                .accessibilityIdentifier("onboarding-finish")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-done")
        .task {
            Haptic.success()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.1)) { pop = true }
            await model.notifications.refreshStatus()
        }
    }

    @ViewBuilder private var notificationsRow: some View {
        switch model.notifications.status {
        case .authorized, .provisional, .ephemeral:
            item(symbol: "checkmark.circle.fill", color: Theme.green, title: S("Notificações ativadas"), detail: S("Avisamos quando um agente precisar de você"))
                .accessibilityElement(children: .combine)
        case .denied:
            Button {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            } label: {
                item(symbol: "bell.slash.fill", color: Theme.orange, title: S("Notificações desativadas"), detail: S("Ative nos Ajustes do sistema"), chevron: true)
            }
            .buttonStyle(.plain)
        default:
            Button { Task { await model.notifications.requestAuthorization() } } label: {
                item(symbol: "bell.badge.fill", color: Theme.orange, title: S("Permitir notificações"), detail: S("Para saber quando um agente precisar de você"),
                     action: S("Permitir"))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboarding-allow-notifications")
        }
    }

    private func item(symbol: String, color: Color, title: String, detail: String, chevron: Bool = false, action: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let action {
                Text(action).font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.accent, in: Capsule())
            } else if chevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct PasteLinkSheet: View {
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cole o link de pareamento (pier://…) gerado pela box.")
                    .font(.subheadline).foregroundStyle(Theme.textDim)
                TextEditor(text: $text)
                    .font(.mono(13)).scrollContentBackground(.hidden)
                    .padding(10).frame(height: 140)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.red) }
                Button {
                    if let s = UIPasteboard.general.string { text = s; submit() }
                } label: { Label("Colar da área de transferência", systemImage: "doc.on.clipboard") }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Parear") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(20)
            .pierBackground()
            .navigationTitle("Colar link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        if let link = PairingLink.find(in: text) {
            dismiss()
            // present after this sheet is gone
            Task { try? await Task.sleep(for: .milliseconds(350)); router.pendingPair = PendingPair(link: link) }
        } else {
            error = PairingErrorText.message(PierError.invalidLink("not found"))
        }
    }
}

/// Runs the pairing for a link and shows progress / success / error. A link that arrived from outside the app
/// (`PendingPair.confirm`) is shown first: pairing hands the box this device's name and push tokens and lists its
/// sessions here, so a tapped link must not do that on its own.
struct PairingProgressView: View {
    let link: PairingLink
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var phase: Phase

    enum Phase { case confirm, working, done(PairOutcome), failed(String) }

    init(link: PairingLink, confirm: Bool = false) {
        self.link = link
        _phase = State(initialValue: confirm ? .confirm : .working)
    }

    private var needsConfirmation: Bool { if case .confirm = phase { return true } else { return false } }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            switch phase {
            case .confirm:
                Image(systemName: "link.badge.plus").font(.system(size: 52)).foregroundStyle(Theme.accent)
                Text("Parear com esta box?").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                Text("Este link chegou de outro app. Pareie só se foi você quem o gerou, com “pierd pair” ou “Levar para o iPhone”.")
                    .font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).padding(.horizontal, 28)
                VStack(spacing: 8) {
                    ForEach(targets, id: \.self) { t in
                        Card { HStack { MonoText(t, size: 11); Spacer() } }
                    }
                }.padding(.horizontal, 24)
            case .working:
                ProgressView().controlSize(.large).tint(Theme.accent)
                Text("Pareando…").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                Text(target).font(.mono(12)).foregroundStyle(Theme.textDim)
            case .done(let out):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.green)
                Text(out.paired.count > 1 ? "Boxes pareadas" : "Box pareada").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                VStack(spacing: 8) {
                    ForEach(out.paired) { r in
                        Card { HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).font(.headline).foregroundStyle(Theme.text)
                                MonoText("\(r.address)  ·  \(r.fingerprint.short)", size: 11)
                            }
                            Spacer()
                        } }
                    }
                    ForEach(Array(out.failures.enumerated()), id: \.offset) { _, f in
                        Text("\(f.name): \(PairingErrorText.message(f.error))").font(.footnote).foregroundStyle(Theme.orange)
                    }
                }.padding(.horizontal, 24)
            case .failed(let msg):
                Image(systemName: "xmark.octagon.fill").font(.system(size: 52)).foregroundStyle(Theme.red)
                Text("Não foi possível parear").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                Text(msg).font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).padding(.horizontal, 28)
            }
            Spacer()
            switch phase {
            case .confirm:
                VStack(spacing: 10) {
                    Button("Parear") { Task { await run() } }.buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("pair-confirm")
                    Button("Cancelar") { router.pendingPair = nil }.buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("pair-cancel")
                }.padding(.horizontal, 24)
            case .working: EmptyView()
            case .done:
                Button("Concluir") { router.pendingPair = nil }.buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24)
            case .failed:
                VStack(spacing: 10) {
                    Button("Tentar novamente") { Task { await run() } }.buttonStyle(PrimaryButtonStyle())
                    Button("Fechar") { router.pendingPair = nil }.buttonStyle(SecondaryButtonStyle())
                }.padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pierBackground()
        .task { if !needsConfirmation { await run() } }
    }

    private var target: String {
        switch link {
        case .box(let l): l.address
        case .join(let j): j.boxes.map(\.name).joined(separator: ", ")
        }
    }

    /// One line per box the link pairs with: where it is and the key it pins (the code itself is never shown).
    private var targets: [String] {
        switch link {
        case .box(let l): ["\(l.address)  ·  \(l.fingerprint.short)"]
        case .join(let j): j.boxes.map { "\($0.name)  ·  \($0.addresses.first ?? "?")  ·  \($0.fingerprint.short)" }
        }
    }

    private func run() async {
        phase = .working
        do {
            let out = try await model.pair(link)
            // First run: the onboarding shows "Tudo pronto!" with what got connected, so this sheet just goes away.
            if router.onboardingFinishing, out.failures.isEmpty { router.pendingPair = nil; return }
            phase = .done(out)
        } catch { phase = .failed(PairingErrorText.message(error)) }
    }
}
