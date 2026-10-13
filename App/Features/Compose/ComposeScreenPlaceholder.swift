import SwiftUI
import PhotosUI
import PierKit

/// New task / start agent: a big prompt, the project, the agent; everything else folded under "Opções" with smart
/// defaults and a one-line summary of what will happen. (Type name kept from the placeholder; Destinations.swift maps
/// `ComposeRoute` to it.)
struct ComposeScreenPlaceholder: View {
    let route: ComposeRoute
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    @State private var vm: ComposeModel
    @State private var sheet: Sheet?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var savingPrompt = false
    @State private var newPromptTitle = ""
    @State private var customChoice: CustomChoice?
    @State private var customText = ""
    @State private var optionsOpen = false
    /// The prompt as it was when dictation started: what is heard is added after it.
    @State private var dictationBase = ""
    @FocusState private var promptFocused: Bool
    private var dictation: Dictation { TalkCenter.shared.dictation }

    /// The Mac starts from a button at the end of the form, as a dialog does; the iPhone and the iPad keep a bar above the
    /// on-screen keyboard, where it never hides behind it.
    private var inlineSubmit: Bool { Platform.isMac }
    /// The prompt's type: the body size (Dynamic Type) on iPhone and iPad, a size that reads well on the Mac.
    private var promptFont: Font { Platform.isMac ? .system(size: 15) : .body }

    enum Sheet: String, Identifiable { case project, worktree, base; var id: String { rawValue } }
    enum CustomChoice: String, Identifiable { case model, effort; var id: String { rawValue } }

    init(route: ComposeRoute) {
        self.route = route
        _vm = State(initialValue: ComposeModel(route: route))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if vm.canChat || vm.chat { kindPicker }
                editorCard
                if vm.chat { chatPlaceRow } else { projectRow }
                agentRow
                optionsCard
                if !vm.photos.isEmpty && !vm.chat { photosRow }
                if let e = vm.error { errorCard(e) }
                if inlineSubmit { inlineSubmitRow }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            // A form reads best in a column, not stretched across a wide window.
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .pierBackground()
        .navigationTitle(vm.chat ? "Nova conversa" : "Nova tarefa")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if !inlineSubmit { submitBar } }
        .onChange(of: dictation.transcript) { _, t in
            guard dictation.isListening, !t.isEmpty else { return }
            vm.prompt = Self.joined(dictationBase, t)
        }
        .onDisappear { if dictation.isListening { dictation.cancel() } }
        .sheet(item: $sheet) { s in
            switch s {
            case .project: ProjectPickerSheet(vm: vm).environment(app).environment(prefs)
            case .worktree: WorktreePickerSheet(vm: vm)
            case .base: BranchPickerSheet(branches: vm.branches, selected: vm.effectiveBase, defaultBranch: vm.defaultBranch) { vm.base = $0 }
            }
        }
        .alert("Salvar prompt", isPresented: $savingPrompt) {
            TextField("Nome", text: $newPromptTitle)
            Button("Salvar") {
                let t = newPromptTitle.trimmingCharacters(in: .whitespaces)
                prefs.addPrompt(title: t.isEmpty ? String(vm.prompt.prefix(30)) : t, text: vm.prompt)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Guarde este texto para reaproveitar em outras tarefas.") }
        .alert(customChoice == .model ? "Modelo" : "Esforço", isPresented: Binding(get: { customChoice != nil }, set: { if !$0 { customChoice = nil } })) {
            TextField(customChoice == .model ? "ex.: gpt-5" : "ex.: high", text: $customText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("OK") {
                let v = customText.trimmingCharacters(in: .whitespaces)
                if WorktreeNaming.isValidChoice(v) { if customChoice == .model { vm.model = v } else { vm.effort = v } }
                else if !v.isEmpty { vm.error = String(localized: "Valor inválido: use letras, números, ponto, dois-pontos ou hífen.") }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Digite o nome exato aceito pelo agente.") }
        .onAppear {
            vm.bind(app)
            if vm.prompt.isEmpty, !prefs.composeDraft.isEmpty { vm.prompt = prefs.composeDraft; vm.promptChanged() }
            if let b = app.connection(for: vm.box), b.info == nil || b.locations.isEmpty { Task { await b.connect(); vm.bind(app) } }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "composeNoFocus") { return }
                #endif
                promptFocused = true
            }
            #if DEBUG
            debugHooks()
            #endif
        }
        .task(id: "\(vm.box)/\(vm.location ?? "")") { await vm.loadBranches() }
        .onChange(of: vm.prompt) {
            vm.promptChanged()
            prefs.setComposeDraft(vm.prompt)
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await vm.addPhotos(items); photoItems = [] }
        }
    }

    #if DEBUG
    /// Test hooks: `-composePrompt`, `-composeSheet project|worktree|base`, `-composeSubmit 1`, `-composeProject`, `-composeAgent`, `-composeOptions 1`.
    private func debugHooks() {
        let d = UserDefaults.standard
        if let l = d.string(forKey: "composeProject") { vm.selectLocation(l) }
        if d.bool(forKey: "composeChat") { vm.selectChat(true) }
        if let a = d.string(forKey: "composeAgent") { vm.selectAgent(a) }
        if let p = d.string(forKey: "composePrompt") { vm.prompt = p; vm.promptChanged() }
        if d.bool(forKey: "composeOptions") { optionsOpen = true }
        if d.bool(forKey: "composeFakePhoto") {
            let img = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { c in
                UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
                ("TEST" as NSString).draw(at: CGPoint(x: 120, y: 120), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 60), .foregroundColor: UIColor.white])
            }
            if let data = img.pngData(), let p = ComposePhoto.make(from: data, index: 1) { vm.photos.append(p) }
        }
        if let s = d.string(forKey: "composeSheet") {
            Task { try? await Task.sleep(for: .seconds(1.5)); sheet = Sheet(rawValue: s) }
        }
        if d.bool(forKey: "composeSubmit") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if let s = await vm.submit() { router.replaceTop(with: SessionRoute(box: vm.box, session: s)) }
            }
        }
    }
    #endif

    // MARK: editor

    private var editorCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $vm.prompt)
                    .focused($promptFocused)
                    .accessibilityIdentifier("compose-prompt")
                    .font(promptFont)
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    // Capped: a longer prompt scrolls inside the editor, so the caret stays above the keyboard and the
                    // fields below stay reachable with the outer scroll.
                    .frame(minHeight: Platform.isMac ? 130 : 150, maxHeight: max(150, UIScreen.main.bounds.height * 0.26))
                    .padding(.horizontal, 10).padding(.top, 8)
                if vm.prompt.isEmpty {
                    Text(vm.chat ? "Sobre o que vamos conversar?\nUma pergunta, uma ideia, um plano…" : "O que o agente deve fazer?\nDescreva a tarefa, o bug ou a ideia…")
                        .font(promptFont).foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 15).padding(.top, 16).allowsHitTesting(false)
                }
            }
            dictationStatus
            Divider().overlay(Theme.stroke)
            HStack(spacing: 16) {
                if !vm.chat {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 6, matching: .images) {
                        Label("Foto", systemImage: "photo.on.rectangle.angled").font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                }
                templatesMenu
                Spacer()
                if vm.promptBytes > ComposeModel.promptLimit / 2 {
                    Text("\(vm.promptBytes / 1024) / 128 KB")
                        .font(.caption.monospacedDigit()).foregroundStyle(vm.promptTooLong ? Theme.red : Theme.textDim)
                }
                // The Mac has no on-screen keyboard to put away.
                if promptFocused, !Platform.isMac {
                    Button { promptFocused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Fechar teclado")
                }
                micButton
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14).padding(.vertical, Platform.isMac ? 8 : 10)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(dictation.isListening ? Theme.red.opacity(0.5) : promptFocused ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1))
    }

    // MARK: dictation

    /// Say the task instead of typing it: the same on-device dictation as Falar, written into the prompt as it is heard.
    private var micButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: dictation.isListening ? "stop.fill" : "mic.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(dictation.isListening ? .white : Theme.accent)
                .frame(width: 34, height: 34)
                .background(dictation.isListening ? Theme.red : Theme.accent.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.isListening ? "Parar de ditar" : "Ditar")
        .accessibilityIdentifier("compose-mic")
    }

    @ViewBuilder private var dictationStatus: some View {
        if dictation.isListening {
            HStack(spacing: 8) {
                TalkWaveform(level: dictation.level, color: Theme.red).frame(width: 34, height: 18)
                Text("Ouvindo… toque no microfone para parar").font(.caption).foregroundStyle(Theme.textDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
            .transition(.opacity)
            .accessibilityIdentifier("compose-listening")
        } else if dictation.state == .denied {
            VStack(alignment: .leading, spacing: 6) {
                Text("Para ditar, permita o microfone e o reconhecimento de fala nos Ajustes. Você também pode escrever o pedido.")
                    .font(.caption).foregroundStyle(Theme.orange)
                Button("Abrir Ajustes") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
                .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.bottom, 8)
        } else if dictation.state == .unavailable {
            Text("O ditado não está disponível agora. Escreva o pedido.").font(.caption).foregroundStyle(Theme.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    private func toggleDictation() {
        if dictation.isListening {
            finishDictation()
            Haptic.impact(.light)
        } else {
            promptFocused = false
            dictationBase = vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            Haptic.impact(.medium)
            Task { await dictation.start() }
        }
    }

    /// Stops listening and keeps what was heard.
    private func finishDictation() {
        guard dictation.isListening else { return }
        let heard = dictation.stop()
        if !heard.isEmpty { vm.prompt = Self.joined(dictationBase, heard) }
    }

    static func joined(_ base: String, _ heard: String) -> String { base.isEmpty ? heard : base + " " + heard }

    private var templatesMenu: some View {
        Menu {
            if prefs.prompts.isEmpty {
                Text("Nenhum prompt salvo")
            } else {
                ForEach(prefs.prompts) { p in
                    Button {
                        vm.prompt = vm.prompt.isEmpty ? p.text : vm.prompt + "\n\n" + p.text
                    } label: { Label(p.title, systemImage: "text.insert") }
                }
            }
            Divider()
            Button { newPromptTitle = ""; savingPrompt = true } label: { Label("Salvar prompt atual…", systemImage: "square.and.arrow.down") }
                .disabled(vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !prefs.prompts.isEmpty {
                Menu {
                    ForEach(prefs.prompts) { p in Button(p.title, role: .destructive) { prefs.removePrompt(p.id) } }
                } label: { Label("Remover salvo", systemImage: "trash") }
            }
        } label: { Label("Prompts", systemImage: "text.badge.plus").font(.subheadline.weight(.medium)) }
        .plainMenu()
    }

    // MARK: task or chat

    /// Tarefa (a project, today's flow) or Conversa (no project: the agent gets an empty folder of its own on the box).
    private var kindPicker: some View {
        Picker("Tipo", selection: Binding(get: { vm.chat }, set: { vm.selectChat($0); Haptic.selection() })) {
            Text("Tarefa").tag(false)
            Text("Conversa").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .accessibilityIdentifier("compose-kind")
    }

    /// In place of the project, for a chat: what it is, and the box when there are several.
    private var chatPlaceRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Theme.accent).frame(width: 36, height: 36)
                .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Sem projeto").font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                Text(vm.canChat || vm.conn?.info == nil ? "O agente roda numa pasta vazia, só desta conversa, na box."
                                                         : "Esta box ainda não tem conversas livres: atualize o pierd.")
                    .font(.caption).foregroundStyle(vm.canChat || vm.conn?.info == nil ? Theme.textDim : Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if app.boxes.count > 1 { boxMenu }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("compose-chat-place")
    }

    // MARK: project & agent

    private var projectRow: some View {
        Button { sheet = .project } label: {
            HStack(spacing: 12) {
                if let l = vm.location {
                    ProjectGlyph(name: prefs.displayName(box: vm.box, location: l), size: 36)
                } else {
                    Image(systemName: "folder").foregroundStyle(Theme.textDim).frame(width: 36, height: 36)
                        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projeto").font(.caption).foregroundStyle(Theme.textDim)
                    Text(vm.location.map { prefs.displayName(box: vm.box, location: $0) } ?? String(localized: "Escolher projeto"))
                        .font(.body.weight(.semibold)).foregroundStyle(vm.location == nil ? Theme.accent : Theme.text).lineLimit(1)
                }
                Spacer(minLength: 8)
                if app.boxes.count > 1 { boxMenu }
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Projeto: \(vm.location ?? String(localized: "nenhum"))")
        .accessibilityHint("Escolhe o projeto da tarefa")
    }

    private var boxMenu: some View {
        Menu {
            ForEach(app.boxes) { b in
                Button { vm.selectBox(b.name) } label: {
                    if b.name == vm.box { Label(b.name, systemImage: "checkmark") } else { Text(b.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "shippingbox").font(.caption2)
                Text(vm.box).font(.caption.weight(.medium))
            }
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.cardRaised, in: Capsule())
        }
        .plainMenu()
    }

    @ViewBuilder private var agentRow: some View {
        if vm.agents.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.orange)
                Text("Nenhum agente instalado nesta box.").font(.subheadline).foregroundStyle(Theme.textDim)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if vm.agents.count <= 3 {
            HStack(spacing: 8) {
                ForEach(vm.agents) { a in
                    let on = a.id == vm.agentID
                    Button { vm.selectAgent(a.id); Haptic.selection() } label: {
                        HStack(spacing: 7) {
                            AgentGlyph(agent: a.id, size: 22)
                            Text(agentName(a)).font(.subheadline.weight(.medium)).foregroundStyle(on ? Theme.text : Theme.textDim).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8).padding(.horizontal, 10)
                        .background(on ? Theme.cardRaised : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.accent.opacity(0.6) : Theme.stroke))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agent-chip-\(a.id)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        } else {
            Menu {
                ForEach(vm.agents) { a in
                    Button { vm.selectAgent(a.id) } label: {
                        if a.id == vm.agentID { Label(agentName(a), systemImage: "checkmark") } else { Text(agentName(a)) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    AgentGlyph(agent: vm.agentID, size: 28)
                    Text(vm.agent.map(agentName) ?? String(localized: "Agente")).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
            }
            .plainMenu()
        }
    }

    private func agentName(_ a: AgentPreset) -> String { a.name.isEmpty ? DisplayNames.agentLabel(a.id) : a.name }

    // MARK: options

    private var optionsCard: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.25)) { optionsOpen.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.textDim).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Opções").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(vm.summary).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(optionsOpen ? 90 : 0))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(optionsOpen ? "Recolhe as opções" : "Mostra worktree, branch, modelo, esforço e título")
            .accessibilityIdentifier("compose-options")
            if optionsOpen {
                Divider().overlay(Theme.stroke)
                VStack(spacing: 0) {
                    if vm.locationObject != nil && !vm.chat {
                        optionRow("arrow.triangle.branch", "Worktree",
                                  vm.isNew ? String(localized: "Nova") : (vm.existingWorktree?.name ?? "—")) { sheet = .worktree }
                        if vm.isNew {
                            optionRow("arrow.turn.down.right", "A partir de", vm.effectiveBase.isEmpty ? "—" : vm.effectiveBase) { sheet = .base }
                            nameRow
                        }
                    }
                    if let a = vm.agent {
                        if a.canPickModel {
                            choiceRow(symbol: "cpu", label: "Modelo", value: vm.model, options: a.models ?? [], kind: .model,
                                      name: ChoiceNames.model) { vm.model = $0 }
                        }
                        if a.canPickEffort {
                            choiceRow(symbol: "gauge.with.dots.needle.67percent", label: "Esforço", value: vm.effort, options: a.efforts ?? [],
                                      kind: .effort, name: ChoiceNames.effort) { vm.effort = $0 }
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "textformat").foregroundStyle(Theme.textDim).frame(width: 20)
                        Text("Título").font(.subheadline).foregroundStyle(Theme.textDim)
                        TextField("opcional", text: $vm.title).foregroundStyle(Theme.text).multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                }
                .transition(.opacity)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func optionRow(_ symbol: String, _ label: LocalizedStringKey, _ value: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(Theme.textDim).frame(width: 20)
                    Text(label).font(.subheadline).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().overlay(Theme.stroke).padding(.leading, 42)
        }
    }

    /// Model or effort as a row of chips, every choice in sight: "Padrão" (the agent's own default), the agent's names,
    /// a value typed by hand, and "Outro…" to type one.
    private func choiceRow(symbol: String, label: LocalizedStringKey, value: String?, options: [String], kind: CustomChoice,
                           name: @escaping (String) -> String, set: @escaping (String?) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Level with the first line of chips (a chip is its text plus ChoiceChip's padding).
                Image(systemName: symbol).foregroundStyle(Theme.textDim).frame(width: 20).padding(.top, ChoiceChip.vPad)
                Text(label).font(.subheadline).foregroundStyle(Theme.textDim)
                    .frame(minWidth: Platform.isMac ? 64 : 58, alignment: .leading)
                    .padding(.top, ChoiceChip.vPad)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ChoiceChip(title: String(localized: "Padrão"), selected: value == nil) { set(nil); Haptic.selection() }
                    ForEach(options, id: \.self) { o in
                        ChoiceChip(title: name(o), selected: value == o) { set(o); Haptic.selection() }
                    }
                    if let v = value, !options.contains(v) {
                        ChoiceChip(title: v, selected: true) { customText = v; customChoice = kind }
                    }
                    ChoiceChip(title: String(localized: "Outro…"), selected: false, quiet: true) { customText = value ?? ""; customChoice = kind }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(kind == .model ? "compose-model" : "compose-effort")
            Divider().overlay(Theme.stroke).padding(.leading, 42)
        }
    }

    private var nameRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tag").foregroundStyle(Theme.textDim).frame(width: 20)
                Text("Nome").font(.subheadline).foregroundStyle(Theme.textDim)
                TextField("nome-da-worktree", text: Binding(get: { vm.worktreeName }, set: { vm.worktreeName = $0; vm.nameEdited = true }))
                    .font(.mono(14)).textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing)
                    .foregroundStyle(vm.worktreeName.isEmpty || WorktreeNaming.isValid(vm.worktreeName) ? Theme.text : Theme.red)
                // Plain: the Mac would draw a grey bezel around each.
                if vm.nameEdited {
                    Button { vm.resetName() } label: { Image(systemName: "wand.and.stars") }.buttonStyle(.plain).accessibilityLabel("Gerar do prompt")
                }
                Button { vm.randomizeName() } label: { Image(systemName: "dice") }.buttonStyle(.plain).accessibilityLabel("Nome aleatório")
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).padding(.vertical, 11)
            Divider().overlay(Theme.stroke).padding(.leading, 42)
        }
    }

    private var photosRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(vm.photos) { p in
                    Image(uiImage: p.thumb).resizable().scaledToFill()
                        .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { vm.photos.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65))
                            }
                            .padding(3)
                            .accessibilityLabel("Remover foto")
                        }
                }
            }
        }
    }

    private func errorCard(_ e: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
            Text(e).font(.subheadline).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: submit

    private func start() {
        Task {
            promptFocused = false
            finishDictation()
            if let s = await vm.submit() {
                router.replaceTop(with: SessionRoute(box: vm.box, session: s))
            }
        }
    }

    private var startLabel: some View {
        HStack(spacing: 8) {
            if vm.stage.isBusy { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "sparkles") }
            Text(buttonTitle)
        }
    }

    /// iPhone and iPad: the start button in a bar above the keyboard, as wide as the form's column, on the screen's own
    /// background (a hairline over it), and, while it can't start yet, in quiet colors that still read.
    private var submitBar: some View {
        Button(action: start) { startLabel }
            .buttonStyle(PrimaryButtonStyle(color: vm.canSubmit || vm.stage.isBusy ? Theme.accent : Theme.cardRaised,
                                            foreground: vm.canSubmit || vm.stage.isBusy ? .white : Theme.textDim))
            .keyboardShortcut(.return, modifiers: .command)   // ⌘↩ starts the task from the keyboard
            .accessibilityIdentifier("compose-start")
            .disabled(!vm.canSubmit)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                Theme.bg.ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
            }
    }

    /// Mac: the start button where the form ends, its own size, with the shortcut beside it; what is still missing is said
    /// there too, instead of a dead full-width bar.
    private var inlineSubmitRow: some View {
        HStack(spacing: 12) {
            Text(missingHint ?? (Platform.isMac ? String(localized: "⌘↩ para iniciar") : ""))
                .font(.caption).foregroundStyle(missingHint == nil ? Theme.textFaint : Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button(action: start) { startLabel }
                .buttonStyle(CompactPrimaryButtonStyle(enabled: vm.canSubmit || vm.stage.isBusy))
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("compose-start")
                .disabled(!vm.canSubmit)
        }
        .padding(.top, 2)
    }

    /// Why Start is still off, in a few words (nil when it can start, or while it starts).
    private var missingHint: String? {
        guard !vm.canSubmit, !vm.stage.isBusy else { return nil }
        if vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return vm.chat ? String(localized: "Escreva a primeira mensagem") : String(localized: "Descreva a tarefa")
        }
        if vm.promptTooLong { return String(localized: "O texto passa de 128 KB") }
        if vm.agent == nil { return String(localized: "Escolha um agente") }
        if vm.chat { return vm.canChat ? nil : String(localized: "Esta box ainda não tem conversas livres") }
        if vm.locationObject == nil { return String(localized: "Escolha um projeto") }
        if vm.isNew, !WorktreeNaming.isValid(vm.worktreeName) { return String(localized: "Dê um nome válido à worktree") }
        return nil
    }

    private var buttonTitle: String {
        switch vm.stage {
        case .idle: vm.chat ? String(localized: "Iniciar conversa") : String(localized: "Iniciar tarefa")
        case .creatingWorktree: String(localized: "Criando worktree…")
        case .uploading(let i, let n): String(localized: "Enviando foto \(i) de \(n)…")
        case .starting: String(localized: "Iniciando agente…")
        }
    }
}
