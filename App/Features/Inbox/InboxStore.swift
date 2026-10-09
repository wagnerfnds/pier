import SwiftUI
import PierKit

/// One Inbox card: an agent that waits for the person, or a finished turn they have not archived ("Sua vez").
struct InboxItem: Identifiable, Hashable {
    enum Kind: Hashable { case needsYou, finished }
    let kind: Kind
    let item: BoxSession
    var id: String { item.id }
    var since: Date { item.session.stateSince ?? item.session.created }
}

/// An answer the Inbox offers for a waiting agent, numbered as shown (the key that picks it).
struct InboxOption: Identifiable {
    enum Role { case allow, always, deny, plain }
    enum Answer {
        /// A menu digit; the label is what the menu said next to it (checked again on a fresh screen before sending).
        case key(String, label: String)
        /// An unnumbered menu: move the cursor to `index` and confirm (keys computed again from a fresh screen).
        case cursor(index: Int, label: String)
        /// A single-choice question (AskUserQuestion): the structured answer, digits as the fallback.
        case pick(question: TranscriptItem, label: String)
    }
    let number: Int
    let title: String
    /// The agent's own words, when the title is ours ("Permitir" ⟵ "Yes, and don't ask again for mkdir").
    let detail: String?
    let role: Role
    let answer: Answer
    var recommended = false
    var id: Int { number }
}

/// What the Inbox does: every answer and every message it sends goes through `perform`, one function, so an undo window
/// (or anything else) can wrap all of them in one place.
enum InboxAction {
    case option(InboxOption)
    /// A typed reply or a suggested next step: the composer's send, with `when: idle`.
    case send(String)
}

/// The Inbox's live state. The cards come from the sessions store (no polling of its own); the waiting agents' screens and
/// the finished turns' replies come from `SessionSignals`, which the Inbox ticks like the board does. Answers and replies go
/// through a `SessionViewModel` per card, the session screen's own code (`answer(key:)`, `answer(keys:)`,
/// `answerQuestion`, `send`).
@MainActor @Observable
final class InboxStore {
    static let shared = InboxStore()

    /// Cards answered, replied to, archived or dismissed from here, hidden until the box reports the new state or the mark is
    /// written ("box/session" -> `state_since`); "Desfazer" brings them back.
    private(set) var handled: [String: Date] = [:]
    /// Cards with an answer on its way.
    private(set) var busy: Set<String> = []
    @ObservationIgnored private var vms: [String: SessionViewModel] = [:]
    /// Boxes to re-read sessions from for a moment after an answer or a reply (box -> until when), so the card that left
    /// comes back as soon as the agent is done even when an event is late.
    @ObservationIgnored private var followUps: [String: Date] = [:]
    private let signals = SessionSignals.shared

    // MARK: cards

    /// Needs-you first (oldest first), then finished turns not archived and not still running background work (newest first).
    func items(model: AppModel) -> [InboxItem] {
        let prefs = model.prefs
        var all: [InboxItem] = []
        for s in model.sessionsStore.group(.needsYou) where !prefs.isDismissed(box: s.box, session: s.session) {
            all.append(InboxItem(kind: .needsYou, item: s))
        }
        for s in model.sessionsStore.group(.done) where !prefs.isClosed(box: s.box, session: s.session) && signals.background[s.id] == nil {
            all.append(InboxItem(kind: .finished, item: s))
        }
        all.removeAll { i in handled[i.id] == i.since }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Cards that left (answered, archived, the agent moved on) drop their models, unless an answer is still on its way.
        for id in vms.keys where byID[id] == nil && !busy.contains(id) { vms[id] = nil }
        let order = InboxRules.order(all.map { InboxRules.Entry(id: $0.id, kind: $0.kind == .needsYou ? .needsYou : .finished, since: $0.since) })
        return order.compactMap { byID[$0.id] }
    }

    /// What the badge says: the agents waiting, plus the finished turns the person has not looked at yet. A turn read in
    /// the session (or opened on its card) stays listed until archived but no longer counts: the badge means "unseen".
    func unseenCount(model: AppModel) -> Int {
        items(model: model).filter { $0.kind == .needsYou || !model.prefs.isSeen(box: $0.item.box, session: $0.item.session) }.count
    }

    /// Hides a question until the agent asks again. Waits the undo window like an answer; the card comes back on "Desfazer".
    func dismiss(_ i: InboxItem, model: AppModel) {
        withAnimation(.snappy) { handled[i.id] = i.since }
        PendingActions.shared.schedule(label: S("Dispensar · \(i.item.session.displayTitle)"), symbol: "eye.slash", perform: { [weak self] in
            model.prefs.setDismissed(true, box: i.item.box, session: i.item.session)
            self?.handled[i.id] = nil
        }, onUndo: { [weak self] in
            withAnimation(.snappy) { self?.handled[i.id] = nil }
        })
    }

    /// Archives a finished turn ("terminei aqui"), with the undo window: the card leaves at once and comes back on "Desfazer".
    func archive(_ i: InboxItem, model: AppModel) {
        Haptic.impact(.light)
        withAnimation(.snappy) { handled[i.id] = i.since }
        PendingActions.shared.schedule(label: S("Arquivar · \(i.item.session.displayTitle)"), symbol: "archivebox", perform: { [weak self] in
            model.prefs.setClosed(true, box: i.item.box, session: i.item.session.name)
            self?.handled[i.id] = nil
        }, onUndo: { [weak self] in
            withAnimation(.snappy) { self?.handled[i.id] = nil }
        })
    }

    /// Something acted on a box outside the Inbox's own path (a notification button): read it again for a moment.
    func noteActed(box: String) { followUps[box] = Date().addingTimeInterval(20) }

    /// The session screen's model for a card (created once, kept while the card exists).
    func vm(_ i: InboxItem, model: AppModel) -> SessionViewModel? {
        if let v = vms[i.id] { return v }
        guard let client = model.client(for: i.item.box) else { return nil }
        let v = SessionViewModel(box: i.item.box, session: i.item.session, client: client, model: model)
        vms[i.id] = v
        return v
    }

    // MARK: options

    /// The answers for a waiting agent, read from its screen like the needs-you card does: a single-choice question, a
    /// numbered menu (permission or not), or an unnumbered cursor menu. Empty when nothing is parsable (open the session).
    static func options(for s: Session, screen: String?) -> [InboxOption] {
        guard let screen, !screen.isEmpty else { return [] }
        let ask = s.ask
        var out: [InboxOption] = []
        if s.needsYouKind == .question, ask?.isPlanApproval != true, let q = ScreenQuestion.make(screen: screen, ask: ask),
           let question = q.questions?.first, q.questions?.count == 1, question.multi != true {
            for (i, o) in question.options.enumerated() {
                out.append(InboxOption(number: i + 1, title: InboxRules.cleanLabel(o.label), detail: o.description, role: .plain,
                                       answer: .pick(question: q, label: o.label)))
            }
        } else {
            let choices = MenuParser.choices(in: screen)
            if !choices.isEmpty {
                let (allow, always, deny) = MenuParser.permissionActions(choices)
                let isPermission = allow != nil && deny != nil
                for (i, c) in choices.enumerated() {
                    let role: InboxOption.Role = !isPermission ? .plain : c == allow ? .allow : c == always ? .always : c == deny ? .deny : .plain
                    let title: String = switch role {
                    case .allow: S("Permitir")
                    case .always: S("Permitir sempre")
                    case .deny: S("Negar")
                    case .plain: InboxRules.cleanLabel(c.label)
                    }
                    out.append(InboxOption(number: i + 1, title: title, detail: role == .plain ? nil : c.label, role: role,
                                           answer: .key(c.key, label: c.label)))
                }
            } else if let menu = MenuParser.cursorMenu(in: screen) {
                for (i, label) in menu.options.enumerated() {
                    out.append(InboxOption(number: i + 1, title: InboxRules.cleanLabel(label), detail: nil, role: .plain,
                                           answer: .cursor(index: i, label: label)))
                }
            }
        }
        // "Recomendado": the option the agent marks, or names in its own words.
        let labels = out.map { o -> String in
            switch o.answer {
            case .key(_, let l), .cursor(_, let l), .pick(_, let l): l
            }
        }
        let context = [ask?.why, ask?.message].compactMap { $0 }.joined(separator: "\n")
        if let r = InboxRules.recommended(labels: labels, context: context) { out[r].recommended = true }
        return Array(out.prefix(9))
    }

    // MARK: acting

    /// Every answer and reply of the Inbox. The card leaves at once and the answer waits the undo window
    /// (`PendingActions`): "Desfazer" brings the card back and nothing is sent. The window's token when it was scheduled
    /// (the Mac's Inbox card follows it to show "Enviando…" and then the receipt), nil when nothing happened.
    @discardableResult
    func perform(_ action: InboxAction, on i: InboxItem, model: AppModel) async -> PendingActions.Token? {
        guard vm(i, model: model) != nil, !busy.contains(i.id) else { return nil }
        let label: String
        switch action {
        case .option(let o): label = o.title
        case .send(let text): label = text
        }
        withAnimation(.snappy) { handled[i.id] = i.since }
        return PendingActions.shared.schedule(label: label, perform: { [weak self] in
            guard let self else { return }
            if !(await self.execute(action, on: i, model: model)) { withAnimation(.snappy) { self.handled[i.id] = nil } }
        }, onUndo: { [weak self] in
            withAnimation(.snappy) { self?.handled[i.id] = nil }
        })
    }

    /// Sends the answer (after the undo window). `true` when it reached the box.
    private func execute(_ action: InboxAction, on i: InboxItem, model: AppModel) async -> Bool {
        guard let vm = vm(i, model: model), !busy.contains(i.id) else { return false }
        busy.insert(i.id)
        defer { busy.remove(i.id) }
        var ok = false
        switch action {
        case .option(let o):
            ok = await answer(o, vm: vm, model: model)
        case .send(let text):
            ok = await vm.send(text, when: .idle)
        }
        if let e = vm.actionError {
            vm.actionError = nil
            model.showToast(e, symbol: "exclamationmark.triangle")
            ok = false
        }
        if ok {
            withAnimation(.snappy) { handled[i.id] = i.since }
            signals.invalidate()
            model.connection(for: i.item.box)?.scheduleRefresh(sessions: true)
            noteActed(box: i.item.box)
        }
        return ok
    }

    /// The Inbox's tick: sessions of the boxes just acted on (bounded, see `followUps`).
    func followUp(model: AppModel) async {
        let now = Date()
        followUps = followUps.filter { $0.value > now }
        for box in followUps.keys { await model.connection(for: box)?.refreshSessions() }
    }

    /// Reads the screen again and answers only when the option is still there, the way the session screen answers it.
    private func answer(_ o: InboxOption, vm: SessionViewModel, model: AppModel) async -> Bool {
        let name = vm.name
        let fresh: String
        do { fresh = try await vm.client.screen(session: name, history: 0) } catch {
            model.showToast(SessionActions.describe(error), symbol: "exclamationmark.triangle")
            return false
        }
        vm.screen = fresh
        switch o.answer {
        case .key(let key, let label):
            guard MenuParser.choices(in: fresh).contains(MenuChoice(key: key, label: label)) else { return changed(model) }
            await vm.answer(key: key)
        case .cursor(let index, let label):
            guard let menu = MenuParser.cursorMenu(in: fresh), menu.options.indices.contains(index), menu.options[index] == label else {
                return changed(model)
            }
            await vm.answer(keys: menu.keys(toPick: index))
        case .pick(_, let label):
            // The question is rebuilt from the fresh screen (the card's came from an older read): the option must still be there.
            guard let question = ScreenQuestion.make(screen: fresh, ask: vm.session.ask),
                  question.questions?.first?.options.contains(where: { $0.label == label }) == true else { return changed(model) }
            await vm.answerQuestion(item: question, answers: [QuestionAnswer(picks: [label])])
        }
        return vm.actionError == nil
    }

    private func changed(_ model: AppModel) -> Bool {
        model.showToast(S("O pedido mudou ou já foi respondido."), symbol: "exclamationmark.triangle")
        signals.invalidate()
        return false
    }
}
