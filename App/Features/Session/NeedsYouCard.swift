import SwiftUI
import PierKit

/// Pinned above the composer while the agent waits: what it wants, and the answers within thumb reach.
struct NeedsYouCard: View {
    let vm: SessionViewModel

    private var session: Session { vm.session }
    private var ask: Ask? { session.ask }
    private var agent: String { session.agentShortName }
    private var choices: [MenuChoice] { vm.analysis.choices }
    private var openQuestion: TranscriptItem? {
        guard ask?.isPlanApproval != true else { return nil }
        return vm.store.openQuestion ?? ScreenQuestion.make(screen: vm.screen, ask: ask)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if vm.answering {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Enviando resposta…").font(.subheadline).foregroundStyle(Theme.textDim) }
                    .padding(.vertical, 4)
            } else if session.needsYouKind == .question, let q = openQuestion {
                QuestionForm(vm: vm, item: q).id(q.id)
            } else if let perm = MenuParser.permissionChoices(choices) {
                PermissionButtons(vm: vm, choices: perm, all: choices)
            } else if !choices.isEmpty {
                GenericChoices(vm: vm, choices: choices)
            } else if let menu = vm.analysis.cursor {
                CursorChoices(vm: vm, menu: menu)
            } else if vm.analysis.keysOnly {
                TrustDialog(vm: vm)
            } else {
                Fallback(vm: vm)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.orange.opacity(0.45), lineWidth: 1))
        .compositingGroup()   // one shadow for the whole thing, not one per subview
        .shadow(color: Theme.shadow, radius: 14, y: -2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("needs-you-card")
    }

    // MARK: header

    private var isPermission: Bool { session.needsYouKind == .permission || ask?.isPlanApproval == true }

    private var header: some View {
        let wording = PermissionWording.headline(agent: agent, tool: ask?.tool)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Theme.orange).frame(width: 8, height: 8).offset(y: -1)
                Text(headline(wording.text)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 1)) { c in
                    Text(Fmt.elapsed(since: session.stateSince, now: c.date)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textFaint)
                }
            }
            if isPermission, let a = ask, let i = a.input, !i.isEmpty {
                if wording.mono {
                    Text(i).font(.mono(12.5)).foregroundStyle(Theme.text).lineLimit(5)
                        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .textSelection(.enabled)
                } else {
                    Text(i).font(.subheadline).foregroundStyle(Theme.text).lineLimit(5)
                }
            }
            if isPermission, let w = ask?.why, !w.isEmpty { Text(w).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(3) }
            if !session.needsYou, let prompt = screenPrompt {
                Text(prompt).font(.subheadline).foregroundStyle(Theme.text).lineLimit(6)
            }
        }
    }

    /// For a menu found on screen: the text above its options (what the dialog asks), borders and chrome removed.
    private var screenPrompt: String? {
        let lines = vm.analysis.tail
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│┃ ")) }
            .filter { !$0.isEmpty && !$0.allSatisfy { "╭╮╰╯─━".contains($0) } }
        let firstOption = vm.analysis.cursor.map { m in { (l: String) in m.options.contains { l.hasSuffix($0) } } }
            ?? { (l: String) in l.range(of: #"^(?:[❯›>]\s*)?1[.)]\s"#, options: .regularExpression) != nil }
        guard let first = lines.firstIndex(where: firstOption) else { return nil }
        let text = lines[..<first].suffix(4).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func headline(_ wording: String) -> String {
        if !session.needsYou { return S("\(agent) pergunta na tela") }
        if session.needsYouKind == .question, ask?.tool == "AskUserQuestion" || ask?.tool == "request_user_input" || ask?.tool == nil {
            return S("\(agent) tem uma pergunta")
        }
        return wording
    }
}

/// Allow / Deny within reach; "always" and the agent's other options under a quiet disclosure, in the agent's own words.
private struct PermissionButtons: View {
    let vm: SessionViewModel
    let choices: [PermissionChoice]
    var all: [MenuChoice]
    @State private var more = false

    var body: some View {
        let allow = choices.first { $0.label == "Allow" }
        let always = choices.first { $0.label == "Always allow" }
        let deny = choices.first { $0.label == "Deny" }
        let others = all.filter { c in c.key != allow?.key && c.key != deny?.key }
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let deny {
                    Button { vm.scheduleAnswer(key: deny.key, label: S("Negar")) } label: { Text("Negar").foregroundStyle(Theme.red) }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityHint(deny.title)
                        .accessibilityIdentifier("needs-deny")
                }
                if let allow {
                    Button { vm.scheduleAnswer(key: allow.key, label: S("Permitir")) } label: { Label("Permitir", systemImage: "checkmark") }
                        .buttonStyle(PrimaryButtonStyle(color: Theme.green))
                        .accessibilityHint(allow.title)
                        .accessibilityIdentifier("needs-allow")
                }
            }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button { withAnimation(.snappy) { more.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(more ? 90 : 0))
                            Text(always != nil && others.count == 1 ? "Permitir sempre…" : "Outras opções (\(others.count))").font(.footnote.weight(.medium))
                        }
                        .foregroundStyle(Theme.textDim).padding(.vertical, 2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if more {
                        ForEach(others, id: \.key) { c in
                            Button { vm.scheduleAnswer(key: c.key, label: c.label) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(c.key).font(.mono(12, weight: .bold)).foregroundStyle(Theme.accent)
                                    Text(c.label).font(.footnote).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct GenericChoices: View {
    let vm: SessionViewModel
    let choices: [MenuChoice]
    var body: some View {
        VStack(spacing: 6) {
            ForEach(choices, id: \.key) { c in
                Button { vm.scheduleAnswer(key: c.key, label: c.label) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(c.key).font(.mono(13, weight: .bold)).foregroundStyle(Theme.accent)
                        Text(c.label).font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// An unnumbered menu: each option is a button that moves the cursor there and confirms (arrows + Enter).
private struct CursorChoices: View {
    let vm: SessionViewModel
    let menu: CursorMenu
    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(menu.options.enumerated()), id: \.offset) { i, label in
                Button { vm.scheduleAnswer(keys: menu.keys(toPick: i), label: label) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: i == menu.selected ? "chevron.right.circle.fill" : "circle")
                            .font(.footnote).foregroundStyle(i == menu.selected ? Theme.accent : Theme.textFaint)
                        Text(label).font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
            }
        }
    }
}

private struct TrustDialog: View {
    let vm: SessionViewModel
    var body: some View {
        let screen = vm.screen.lowercased()
        let isTrust = screen.contains("trust")
        VStack(alignment: .leading, spacing: 10) {
            Text(isTrust ? "O agente pergunta se você confia nesta pasta." : "O agente mostra uma tela própria que só aceita teclas.")
                .font(.subheadline).foregroundStyle(Theme.text)
            if isTrust {
                Button {
                    // Claude starts on "No, exit": down+enter. Codex: enter.
                    vm.scheduleAnswer(keys: vm.session.agent == "codex" ? [.enter] : [.down, .enter], label: S("Confiar e continuar"))
                } label: { Label("Confiar e continuar", systemImage: "checkmark.shield") }
                    .buttonStyle(PrimaryButtonStyle(color: Theme.green))
            }
            QuickKeys(vm: vm)
        }
    }
}

private struct Fallback: View {
    let vm: SessionViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let tail = vm.analysis.tail.suffix(5).joined(separator: "\n")
            if !tail.isEmpty {
                Text(tail).font(.mono(11.5)).foregroundStyle(Theme.textDim).lineLimit(6)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Lendo as opções na tela…").font(.footnote).foregroundStyle(Theme.textDim) }
            }
            QuickKeys(vm: vm)
            Button { vm.setMode(.terminal) } label: { Label("Responder no terminal", systemImage: "terminal") }
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}

private struct QuickKeys: View {
    let vm: SessionViewModel
    var body: some View {
        HStack(spacing: 6) {
            ForEach([("1", ControlKey.k1), ("2", .k2), ("3", .k3), ("y", .y), ("n", .n), ("↵", .enter), ("Esc", .escape)], id: \.0) { l, k in
                Button { Task { await vm.answer(keys: [k]) } } label: {
                    Text(l).font(.mono(14, weight: .semibold)).foregroundStyle(Theme.text).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: structured questions

/// Options as tappable chips (one tap answers a single-choice question); several questions or a free answer get a Send.
private struct QuestionForm: View {
    let vm: SessionViewModel
    let item: TranscriptItem
    @State private var picks: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]
    @State private var otherOpen: Set<Int> = []
    @State private var contentHeight: CGFloat = 200
    @FocusState private var otherFocused: Int?

    private var questions: [Question] { item.questions ?? [] }
    private var immediate: Bool { questions.count == 1 && questions[0].multi != true }
    private var hasDescriptions: Bool { questions.contains { $0.options.contains { !($0.description ?? "").isEmpty } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            if let h = q.header, !h.isEmpty {
                                Text(h).font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.accent.opacity(0.14), in: Capsule())
                            }
                            if q.multi == true { Text("escolha várias").font(.caption2).foregroundStyle(Theme.textFaint) }
                        }
                        Text(q.question).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        if hasDescriptions {
                            VStack(spacing: 6) { ForEach(q.options, id: \.label) { o in optionRow(i, q, o) } }
                        } else {
                            FlowLayout(spacing: 8, lineSpacing: 8) { ForEach(q.options, id: \.label) { o in chip(i, q, o) } }
                        }
                        if otherOpen.contains(i) {
                            HStack(spacing: 8) {
                                TextField("Sua resposta", text: Binding(get: { other[i] ?? "" }, set: { other[i] = $0.replacingOccurrences(of: "\n", with: " ") }))
                                    .font(.subheadline).focused($otherFocused, equals: i)
                                    .submitLabel(immediate ? .send : .done)
                                    .onSubmit { if immediate, complete { Task { await submit() } } }
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Button { otherOpen.remove(i); other[i] = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint) }
                                    .accessibilityLabel("Fechar resposta livre")
                            }
                        } else {
                            Button { otherOpen.insert(i); otherFocused = i } label: {
                                Label("Outra resposta…", systemImage: "text.cursor").font(.footnote.weight(.medium)).foregroundStyle(Theme.textDim)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !immediate || !otherOpen.isEmpty {
                    Button { Task { await submit() } } label: { Label("Enviar resposta", systemImage: "paperplane.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!complete)
                        .opacity(complete ? 1 : 0.4)
                }
            }
            .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .frame(height: min(contentHeight, 320))
        .scrollBounceBehavior(.basedOnSize)
    }

    private func pick(_ i: Int, _ q: Question, _ o: QuestionOption) {
        Haptic.selection()
        if q.multi == true {
            var s = picks[i] ?? []
            if s.contains(o.label) { s.remove(o.label) } else { s.insert(o.label) }
            picks[i] = s
        } else {
            picks[i] = [o.label]; otherOpen.remove(i); other[i] = nil
            if immediate { Task { await submit() } }
        }
    }

    private func chip(_ i: Int, _ q: Question, _ o: QuestionOption) -> some View {
        let sel = picks[i]?.contains(o.label) == true
        return Button { pick(i, q, o) } label: {
            HStack(spacing: 5) {
                if q.multi == true { Image(systemName: sel ? "checkmark.circle.fill" : "circle").font(.caption) }
                Text(o.label).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
            }
            .foregroundStyle(sel ? Theme.accent : Theme.text)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(sel ? Theme.accent.opacity(0.16) : Theme.cardRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(sel ? Theme.accent.opacity(0.6) : Theme.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sel ? .isSelected : [])
    }

    private func optionRow(_ i: Int, _ q: Question, _ o: QuestionOption) -> some View {
        let sel = picks[i]?.contains(o.label) == true
        return Button { pick(i, q, o) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: q.multi == true ? (sel ? "checkmark.square.fill" : "square") : (sel ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(sel ? Theme.accent : Theme.textFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.label).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                    if let d = o.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(Theme.textDim).multilineTextAlignment(.leading) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(sel ? Theme.accent.opacity(0.14) : Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(sel ? Theme.accent.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sel ? .isSelected : [])
    }

    private var complete: Bool {
        questions.indices.allSatisfy { !(picks[$0] ?? []).isEmpty || !(other[$0]?.jsTrim ?? "").isEmpty }
    }

    private func submit() async {
        let answers: [QuestionAnswer] = questions.indices.map { i in
            let p = questions[i].options.map(\.label).filter { picks[i]?.contains($0) == true }
            let o = other[i]?.jsTrim ?? ""
            return QuestionAnswer(picks: p.isEmpty ? nil : p, other: o.isEmpty ? nil : o)
        }
        vm.scheduleAnswerQuestion(item: item, answers: answers)
    }
}

private extension String { var jsTrim: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
