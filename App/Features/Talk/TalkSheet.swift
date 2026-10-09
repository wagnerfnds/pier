import SwiftUI
import PierKit

/// Falar: say or type what you need; a small model on the box picks the agent (or a new task), the card shows the decision,
/// and nothing goes out until the person taps Enviar (unless "Enviar direto" is on in Ajustes).
struct TalkSheet: View {
    let request: TalkCenter.Request

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TalkCenter.sendDirectKey) private var sendDirect = false
    @State private var talk = TalkModel()
    @State private var editing = false
    @State private var picking = false
    @State private var sendError: String?
    /// The field's text when dictation started: the transcript is appended to it.
    @State private var dictationBase = ""
    @FocusState private var fieldFocused: Bool
    @FocusState private var editFocused: Bool
    /// Medium while typing or speaking; large once there is a decision to read.
    @State private var detent: PresentationDetent = .medium

    private var center: TalkCenter { .shared }
    private var dictation: Dictation { TalkCenter.shared.dictation }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    inputCard
                    switch talk.phase {
                    case .input: examples
                    case .routing: routingRow
                    case .decided, .sending: if let plan = talk.plan { decisionCard(plan) }
                    case .asking(let q): questionCard(q)
                    case .failed(let m): failureCard(m)
                    }
                }
                .padding(16)
                .animation(.snappy, value: talk.phase)
            }
            .scrollDismissesKeyboard(.interactively)
            .pierBackground()
            .navigationTitle("Falar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }.accessibilityIdentifier("talk-close")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .onChange(of: talk.phase) { _, p in
            switch p {
            case .decided, .asking, .failed: withAnimation(.snappy) { detent = .large }
            default: break
            }
        }
        .presentationBackground(Theme.bg)
        .presentationCornerRadius(20)
        .sheet(isPresented: $picking) {
            TalkTargetPicker(context: TalkModel.context(model: model)) { target in
                picking = false
                editing = false
                talk.choose(target)
            }
            .environment(model)
            .environment(model.prefs)
        }
        .onAppear(perform: start)
        .onDisappear {
            talk.cancelRouting()
            dictation.cancel()
        }
        .onChange(of: dictation.transcript) { _, t in
            guard dictation.isListening || !t.isEmpty, !t.isEmpty else { return }
            talk.text = dictationBase.isEmpty ? t : dictationBase + " " + t
        }
    }

    // MARK: input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $talk.text, axis: .vertical)
                .font(.body)
                .lineLimit(2...8)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(route)
                .disabled(talk.phase == .sending)
                .accessibilityIdentifier("talk-field")
            if let image = talk.image { imageChip(image) }
            if dictation.isListening {
                HStack(spacing: 8) {
                    TalkWaveform(level: dictation.level, color: Theme.red).frame(width: 34, height: 18)
                    Text("Ouvindo… toque no microfone para parar").font(.caption).foregroundStyle(Theme.textDim)
                }
                .transition(.opacity)
            } else if dictation.state == .denied {
                deniedHint
            } else if dictation.state == .unavailable {
                Text("O ditado não está disponível agora. Escreva o pedido.").font(.caption).foregroundStyle(Theme.orange)
            }
            HStack(spacing: 10) {
                Button(action: toggleDictation) {
                    Image(systemName: dictation.isListening ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(dictation.isListening ? .white : Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(dictation.isListening ? Theme.red : Theme.accent.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictation.isListening ? "Parar de ditar" : "Ditar")
                .accessibilityIdentifier("talk-mic")
                Spacer()
                Button(action: route) {
                    HStack(spacing: 6) {
                        Text("Encaminhar")
                        Image(systemName: "arrow.up")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(talk.canRoute ? .white : Theme.textFaint)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(talk.canRoute ? Theme.accent : Theme.cardRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!talk.canRoute)
                .keyboardShortcut(talk.plan == nil ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .accessibilityHint("Escolhe o agente certo para o pedido")
                .accessibilityIdentifier("talk-route")
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(dictation.isListening ? Theme.red.opacity(0.5) : Theme.stroke, lineWidth: 1))
    }

    private var placeholder: String {
        if case .asking = talk.phase { return S("Sua resposta…") }
        if talk.image != nil { return S("O que fazer com isso?") }
        return S("Diga ou escreva o que você precisa…")
    }

    /// "Point at it": the part of the screen that goes with the words, with a way to drop it.
    private func imageChip(_ image: TalkImage) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: image.thumb).resizable().scaledToFill()
                .frame(width: 56, height: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
            VStack(alignment: .leading, spacing: 2) {
                Text("Parte da tela").font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                Text("Vai junto com o pedido").font(.caption2).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
            Button {
                talk.image = nil
                talk.plan?.image = nil
            } label: {
                Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remover a imagem")
            .accessibilityIdentifier("talk-image-remove")
        }
        .padding(8)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk-image")
    }

    private var deniedHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Para ditar, permita o microfone e o reconhecimento de fala nos Ajustes. Você também pode escrever o pedido.")
                .font(.caption).foregroundStyle(Theme.orange)
            Button("Abrir Ajustes") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            .font(.caption.weight(.semibold))
        }
        .accessibilityIdentifier("talk-denied")
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Por exemplo").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint).textCase(.uppercase)
                .padding(.horizontal, 4)
            ForEach(exampleTexts, id: \.self) { ex in
                Button { talk.text = ex; fieldFocused = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "text.bubble").font(.caption).foregroundStyle(Theme.textFaint)
                        Text(ex).font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text(sendDirect
                 ? "O Pier escolhe o agente certo ou começa uma tarefa nova e envia na hora, com alguns segundos para desfazer."
                 : "O Pier escolhe o agente certo ou começa uma tarefa nova, e mostra antes de enviar.")
                .font(.caption).foregroundStyle(Theme.textFaint).padding(.horizontal, 4).padding(.top, 2)
        }
    }

    private var exampleTexts: [String] {
        [S("Pede para o agente do login adicionar um teste de senha vazia"),
         S("Nova tarefa no sandbox: escrever o README")]
    }

    private var routingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.accent)
            Text("Procurando o agente certo…").font(.subheadline).foregroundStyle(Theme.textDim)
            Spacer()
            Button("Escolher") { picking = true }.font(.subheadline.weight(.medium))
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk-routing")
    }

    // MARK: decision

    private func decisionCard(_ plan: TalkPlan) -> some View {
        let info = describe(plan.target)
        let sending = talk.phase == .sending
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if case .session = plan.target {
                    AgentGlyph(agent: info.agent, size: 40)
                } else {
                    Image(systemName: "plus.bubble.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.kicker).font(.caption.weight(.medium)).foregroundStyle(Theme.textDim)
                    Text(info.title).font(.headline).foregroundStyle(Theme.text).lineLimit(2)
                        .accessibilityIdentifier("talk-decision-title")
                    if let sub = info.subtitle { Text(sub).font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if let st = info.state { StateBadge(state: st, compact: true) }
            }
            if editing {
                TextField("Mensagem", text: Binding(get: { talk.plan?.text ?? "" }, set: { talk.plan?.text = $0 }), axis: .vertical)
                    .font(.callout)
                    .lineLimit(3...10)
                    .focused($editFocused)
                    .padding(12)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("talk-edit-field")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.6)).frame(width: 3)
                    Text(plan.text).font(.callout).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("talk-decision-text")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let t = plan.title, case .newTask = plan.target {
                Label(t, systemImage: "tag").font(.caption).foregroundStyle(Theme.textDim)
            }
            alternativesRow(plan)
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.red)
                    .accessibilityIdentifier("talk-send-error")
            }
            Button { confirm(plan) } label: {
                HStack(spacing: 8) {
                    if sending { ProgressView().tint(.white) }
                    Text(info.isNew ? "Criar tarefa" : "Enviar")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(sending || plan.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("talk-send")
            HStack(spacing: 10) {
                Button {
                    editing.toggle()
                    editFocused = editing
                } label: { Label(editing ? "Pronto" : "Editar", systemImage: editing ? "checkmark" : "pencil") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("talk-edit")
                Button { picking = true } label: { Label("Outro agente", systemImage: "arrow.triangle.swap") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("talk-pick")
            }
            .disabled(sending)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk-decision")
    }

    private struct Described {
        var kicker: String
        var title: String
        var subtitle: String?
        var agent: String?
        var state: DashState?
        var isNew: Bool
    }

    private func describe(_ target: TalkPlan.Target) -> Described {
        let multi = model.boxes.count > 1
        switch target {
        case .session(let box, let name):
            let conn = model.boxes.first { $0.name == box }
            let s = conn?.sessions.first { $0.name == name }
            var sub: [String] = []
            if let s {
                let bs = BoxSession(box: box, session: s)
                sub.append([model.prefs.displayName(box: box, location: bs.location), bs.worktree].compactMap { $0 }.joined(separator: "/"))
            }
            if multi { sub.append(box) }
            return Described(kicker: S("Mandar para"), title: s.map { DisplayNames.sessionName($0, among: conn?.sessions ?? []) } ?? name,
                             subtitle: sub.isEmpty ? nil : sub.joined(separator: " · "), agent: s?.agent, state: s.flatMap(DashState.init), isNew: false)
        case .newTask(let box, let location):
            return Described(kicker: S("Nova tarefa em"), title: model.prefs.displayName(box: box, location: location),
                             subtitle: multi ? box : S("Numa worktree nova"), agent: nil, state: nil, isNew: true)
        }
    }

    private func questionCard(_ q: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "questionmark.bubble.fill").font(.title3).foregroundStyle(Theme.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(q).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                        .accessibilityIdentifier("talk-question")
                    Text("Responda no campo acima e toque em Encaminhar, ou escolha o agente.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
            }
            Button { picking = true } label: { Label("Escolher agente", systemImage: "list.bullet") }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("talk-pick")
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.orange.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk-ask")
    }

    private func failureCard(_ m: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(m, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(Theme.text)
                .labelStyle(TintedIconLabel(tint: Theme.orange))
                .accessibilityIdentifier("talk-error")
            HStack(spacing: 10) {
                Button("Tentar de novo", action: route).buttonStyle(SecondaryButtonStyle())
                Button("Escolher agente") { picking = true }.buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("talk-pick")
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: actions

    private func start() {
        talk.text = request.text
        talk.image = request.image
        if request.autoRoute {
            route()
        } else if request.listen {
            toggleDictation()
        } else {
            fieldFocused = true
        }
    }

    private func toggleDictation() {
        if dictation.isListening {
            let heard = dictation.stop()
            if !heard.isEmpty { talk.text = dictationBase.isEmpty ? heard : dictationBase + " " + heard }
            Haptic.impact(.light)
        } else {
            fieldFocused = false
            dictationBase = talk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Haptic.impact(.medium)
            Task { await dictation.start() }
        }
    }

    private func route() {
        if dictation.isListening {
            let heard = dictation.stop()
            if !heard.isEmpty { talk.text = dictationBase.isEmpty ? heard : dictationBase + " " + heard }
        }
        guard talk.canRoute else { return }
        fieldFocused = false
        editing = false
        sendError = nil
        talk.route(model: model, sendDirect: sendDirect) { plan in confirm(plan) }
    }

    /// The one place a confirmed plan is carried out (`TalkActions.perform`).
    private func confirm(_ plan: TalkPlan) {
        guard talk.phase != .sending else { return }
        editing = false
        sendError = nil
        // The sheet closes and the plan waits the undo window ("Desfazer" cancels it); the receipt shows once it went out.
        // Undone, the request comes back in the sheet with its words, to be edited or pointed at another agent.
        let center = center, model = model
        dismiss()
        PendingActions.shared.schedule(label: plan.text, perform: {
            switch await TalkActions.perform(plan, model: model) {
            case .success(let receipt): center.show(receipt)
            case .failure(let f): model.showToast(f.message, symbol: "exclamationmark.triangle"); Haptic.warning()
            }
        }, onUndo: { center.open(text: plan.text, image: plan.image) })
    }

    // MARK: other candidates

    /// The agents the request could have gone to instead, next to the decision: the ones on the same project first, then
    /// whoever waits for the person or just finished. A tap re-targets the plan without the picker.
    private func alternatives(to plan: TalkPlan) -> [TalkRouter.SessionInfo] {
        let context = TalkModel.context(model: model)
        var chosenLocation: String?
        if case .session(let box, let name) = plan.target, let s = context.sessions.first(where: { $0.box == box && $0.name == name }) {
            chosenLocation = s.location
        } else if case .newTask(_, let location) = plan.target { chosenLocation = location }
        let others = context.sessions.filter { s in
            if case .session(let box, let name) = plan.target { return !(s.box == box && s.name == name) }
            return true
        }
        let rank = ["needs_you": 0, "your_turn": 1, "working": 2, "ready": 3]
        return Array(others.sorted { a, b in
            let sa = a.location.split(separator: "/").first == chosenLocation?.split(separator: "/").first
            let sb = b.location.split(separator: "/").first == chosenLocation?.split(separator: "/").first
            if sa != sb { return sa }
            return (rank[a.state] ?? 9) < (rank[b.state] ?? 9)
        }.prefix(3))
    }

    @ViewBuilder private func alternativesRow(_ plan: TalkPlan) -> some View {
        let others = alternatives(to: plan)
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ou mandar para").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint).textCase(.uppercase).tracking(0.5)
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(others, id: \.self) { s in
                        Button { talk.choose(.session(box: s.box, name: s.name)) } label: {
                            HStack(spacing: 6) {
                                AgentGlyph(agent: s.agent, size: 18)
                                Text(s.title).font(.caption.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                            }
                            .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
                            .background(Theme.cardRaised, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.stroke))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Manda o pedido para este agente")
                        .accessibilityIdentifier("talk-alt-\(s.name)")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("talk-alternatives")
        }
    }
}

/// A label whose icon keeps its own colour.
private struct TintedIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// "Outro agente": every live agent session, then "Nova tarefa em …" for each project.
struct TalkTargetPicker: View {
    let context: TalkRouter.Context
    let onPick: (TalkPlan.Target) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let sessions = context.sessions.filter { matches($0.title) || matches($0.location) }
                if !sessions.isEmpty {
                    Section("Agentes") {
                        ForEach(sessions, id: \.self) { s in
                            Button { onPick(.session(box: s.box, name: s.name)) } label: { sessionRow(s) }
                                .listRowBackground(Theme.card)
                                .accessibilityIdentifier("talk-target-session-\(s.name)")
                        }
                    }
                }
                let projects = context.projects.filter { matches($0.displayName ?? $0.location) }
                if !projects.isEmpty {
                    Section("Nova tarefa em") {
                        ForEach(projects, id: \.self) { p in
                            Button { onPick(.newTask(box: p.box, location: p.location)) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "plus.bubble").foregroundStyle(Theme.accent).frame(width: 26)
                                    Text(p.displayName ?? p.location).foregroundStyle(Theme.text)
                                    Spacer()
                                    if model.boxes.count > 1 { Text(p.box).font(.caption).foregroundStyle(Theme.textFaint) }
                                }
                            }
                            .listRowBackground(Theme.card)
                            .accessibilityIdentifier("talk-target-project-\(p.location)")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .pierBackground()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Buscar"))
            .navigationTitle("Escolher agente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func matches(_ s: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || PaletteMatch.score(q, s) > 0
    }

    private func sessionRow(_ s: TalkRouter.SessionInfo) -> some View {
        let state: DashState = switch s.state { case "needs_you": .needsYou; case "working": .working; case "your_turn": .done; default: .ready }
        return HStack(spacing: 12) {
            AgentGlyph(agent: s.agent, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).foregroundStyle(Theme.text).lineLimit(1)
                Text(model.boxes.count > 1 ? "\(s.location) · \(s.box)" : s.location).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            Spacer(minLength: 6)
            StateBadge(state: state, compact: true)
        }
    }
}
