#if os(iOS) && !targetEnvironment(macCatalyst)
import CarPlay
import PierKit

/// Pier on the car's screen (CarPlay, communication category): the agents that need the person, the turns that ended,
/// and the agents at work, from every paired box. Made for a glance and the voice:
/// - a waiting agent opens its answers as big rows (Permitir / Negar, or its question's choices, checked against the box
///   before they are sent, as from a notification), plus "Responder por voz";
/// - an ended turn is a conversation: picking it has Siri read the reply aloud and take a spoken answer
///   (`CPMessageListItem` → `MessageIntentHandler`), with no typing and no reading while driving;
/// - an agent at work only says so.
/// Runs without the app's window (the phone locked in a pocket): `CarFeed` reads the boxes headlessly, every few seconds
/// while the car shows it. Needs the CarPlay communication entitlement (`com.apple.developer.carplay-communication`):
/// simulator builds carry it; a device build gets it once Apple grants it (docs/CARPLAY.md).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        let c = CarPlayController(interface: interfaceController)
        controller = c
        c.start()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller?.stop()
        controller = nil
    }
}

@MainActor
final class CarPlayController {
    /// nil only for the Debug self-test, which builds the list without a car (`CarPlaySelfTest`).
    private let interface: CPInterfaceController?
    private let root: CPListTemplate
    private var loop: Task<Void, Never>?
    /// What the list shows now (kind, id, since, age in minutes): redrawn only when it changes, so nothing flickers.
    private var shown: [String] = []
    /// Each box's sessions as last read: a box that does not answer this time keeps its rows (marked out of reach)
    /// instead of the list emptying into a false "nothing waiting".
    private var lastGood: [String: [Session]] = [:]
    /// A waiting agent's answers being read (a second tap meanwhile opens nothing more).
    private var opening = false
    /// How often the boxes are read while the car shows Pier.
    private static let interval: Duration = .seconds(5)

    init(interface: CPInterfaceController?) {
        self.interface = interface
        root = CPListTemplate(title: "Pier", sections: [])
        root.emptyViewTitleVariants = [String(localized: "Nada esperando por você")]
        root.emptyViewSubtitleVariants = [String(localized: "Os agentes que precisarem de você aparecem aqui.")]
        root.tabTitle = "Pier"
        root.tabImage = UIImage(systemName: "bubble.left.and.bubble.right.fill")
    }

    func start() {
        interface?.setRootTemplate(root, animated: false, completion: nil)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: the list

    func refresh() async {
        let report = await CarFeed.report()
        if !report.paired {
            root.emptyViewTitleVariants = [String(localized: "Nenhuma box pareada")]
            root.emptyViewSubtitleVariants = [String(localized: "Pareie uma box no Pier do iPhone.")]
        } else {
            root.emptyViewTitleVariants = [String(localized: "Nada esperando por você")]
            root.emptyViewSubtitleVariants = [String(localized: "Os agentes que precisarem de você aparecem aqui.")]
        }
        for (box, s) in report.sessions { lastGood[box] = s }
        var sessions = report.sessions
        for box in report.offline { sessions[box] = lastGood[box] ?? [] }
        let rows = await CarFeed.rows(sessions, limit: max(1, min(8, CPListTemplate.maximumItemCount / 3)))
        let minute = Int(Date().timeIntervalSince1970 / 60)
        let signature = report.offline.map { "offline|\($0)" } + ["paired|\(report.paired)"] + rows.map {
            "\($0.kind.rawValue)|\($0.id)|\($0.since.timeIntervalSince1970)|\(CarDigest.title($0.session))|\(minute - Int($0.since.timeIntervalSince1970 / 60))"
        }
        guard signature != shown else { return }
        shown = signature
        root.updateSections(sections(rows, offline: report.offline))
    }

    func sections(_ rows: [CarDigest.Row], offline: [String] = []) -> [CPListSection] {
        var out: [CPListSection] = []
        if !offline.isEmpty {
            let items = offline.map { box in
                let item = CPListItem(text: String(localized: "Sem conexão com \(box)"), detailText: String(localized: "Tentando de novo…"),
                                      image: Self.symbol("wifi.slash", .systemGray))
                item.handler = { _, done in done() }
                return item
            }
            out.append(CPListSection(items: items, header: String(localized: "Fora de alcance"), sectionIndexTitle: nil))
        }
        let waiting = rows.filter { $0.kind == .needsYou }
        if !waiting.isEmpty {
            out.append(CPListSection(items: waiting.map(waitingItem), header: String(localized: "Precisa de você"), sectionIndexTitle: nil))
        }
        let ended = rows.filter { $0.kind == .yourTurn }
        if !ended.isEmpty {
            out.append(CPListSection(items: ended.map(endedItem), header: String(localized: "Sua vez"), sectionIndexTitle: nil))
        }
        let working = rows.filter { $0.kind == .working }
        if !working.isEmpty {
            out.append(CPListSection(items: working.map(workingItem), header: String(localized: "Trabalhando"), sectionIndexTitle: nil))
        }
        return out
    }

    private func waitingItem(_ row: CarDigest.Row) -> CPListItem {
        let item = CPListItem(text: CarDigest.title(row.session), detailText: CarFeed.ask(row.session),
                              image: Self.symbol("hand.raised.fill", .systemOrange))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                guard let self, !self.opening else { done(); return }
                self.opening = true
                await self.openAnswers(row)
                self.opening = false
                done()
            }
        }
        return item
    }

    /// A conversation Siri reads and answers: unread until the person looked at it on a screen.
    private func endedItem(_ row: CarDigest.Row) -> CPMessageListItem {
        let lead = CPMessageListItemLeadingConfiguration(leadingItem: .none, leadingImage: Self.avatar(row), unread: true)
        let trail = CPMessageListItemTrailingConfiguration(trailingItem: .none, trailingImage: nil)
        return CPMessageListItem(conversationIdentifier: row.id, text: CarDigest.title(row.session), leadingConfiguration: lead,
                                 trailingConfiguration: trail,
                                 detailText: String(localized: "\(CarDigest.agentName(row.session)) terminou · toque para ouvir"),
                                 trailingText: Self.age(row.since))
    }

    private func workingItem(_ row: CarDigest.Row) -> CPListItem {
        let item = CPListItem(text: CarDigest.title(row.session),
                              detailText: String(localized: "\(CarDigest.agentName(row.session)) trabalhando · \(Self.age(row.since))"),
                              image: Self.symbol("ellipsis.circle.fill", .systemBlue))
        item.handler = { _, done in done() }
        return item
    }

    // MARK: answering

    /// A waiting agent's answers, read from its box now: Permitir / Negar for a permission menu; its question's choices
    /// (the form the hook sent, a question at a time when it has several); "Responder por voz" (Siri takes the words);
    /// and the last of the conversation, so the person knows what it is about.
    private func openAnswers(_ row: CarDigest.Row) async {
        interface?.pushTemplate(await answerTemplate(row), animated: true, completion: nil)
    }

    /// The screen `openAnswers` shows (the self-test reads it without a car).
    func answerTemplate(_ row: CarDigest.Row) async -> CPListTemplate {
        let s = row.session
        var items: [CPListTemplateItem] = []
        let permission = Ask.classify(s.ask) == .permission
        let form = s.ask?.questionItem?.questions
        if permission {
            items.append(answerItem(String(localized: "Permitir"), "checkmark.circle.fill", .systemGreen, row: row) {
                await SessionActions.answerPermission(box: row.box, session: s.name, .allow)
            })
            items.append(answerItem(String(localized: "Negar"), "xmark.circle.fill", .systemRed, row: row) {
                await SessionActions.answerPermission(box: row.box, session: s.name, .deny)
            })
        } else if let form, QuestionSteps.needed(for: form) {
            // A form with steps: its first question now, the next ones as each is answered.
            return stepTemplate(QuestionSteps(questions: form), row: row)
        } else if let labels = form?.first?.options.map(\.label), labels.count > 1 {
            for (i, label) in labels.prefix(8).enumerated() {
                items.append(answerItem("\(i + 1). \(label)", "\(min(i + 1, 50)).circle.fill", .systemBlue, row: row) {
                    await SessionActions.answerChoice(box: row.box, session: s.name, label: label)
                })
            }
        } else if let client = try? HeadlessBoxes.box(row.box).client,
                  let options = await ChoiceOptions.fetch(client: client, session: s) {
            for (i, label) in options.enumerated() {
                items.append(answerItem("\(i + 1). \(label)", "\(i + 1).circle.fill", .systemBlue, row: row) {
                    await SessionActions.answerChoice(box: row.box, session: s.name, label: label)
                })
            }
        }
        // A permission takes only Permitir / Negar (`SessionActions.reply` would refuse the words anyway).
        if !permission { items.append(voiceItem(row)) }
        var sections = [CPListSection(items: items, header: CarFeed.ask(s), sectionIndexTitle: nil)]
        if let talk = await conversation(row) { sections.append(talk) }
        return CPListTemplate(title: CarDigest.title(s), sections: sections)
    }

    /// One question of a form with steps: a single choice answers it and moves on; a multiple choice ticks its rows and
    /// moves on with Continuar. The last answer sends the whole form (`SessionActions.answerForm`).
    private func pushStep(_ steps: QuestionSteps, row: CarDigest.Row) {
        interface?.pushTemplate(stepTemplate(steps, row: row), animated: true, completion: nil)
    }

    func stepTemplate(_ steps: QuestionSteps, row: CarDigest.Row) -> CPListTemplate {
        let q = steps.current ?? Question(question: "")
        let multi = q.multi == true
        var items: [CPListTemplateItem] = []
        var state = steps
        for (i, o) in q.options.prefix(8).enumerated() {
            let ticked = state.ticked.contains(o.label)
            let item = CPListItem(text: "\(i + 1). \(o.label)", detailText: o.description,
                                  image: Self.symbol(multi ? (ticked ? "checkmark.circle.fill" : "circle") : "\(i + 1).circle.fill",
                                                     multi && !ticked ? .systemGray : .systemBlue))
            item.handler = { [weak self] _, done in
                Task { @MainActor in
                    guard let self else { done(); return }
                    state.choose(o.label)
                    done()
                    if multi {
                        // The same question, its ticks redrawn.
                        self.interface?.popTemplate(animated: false, completion: nil)
                        self.pushStep(state, row: row)
                    } else {
                        await self.advance(state, row: row)
                    }
                }
            }
            items.append(item)
        }
        if multi {
            let next = CPListItem(text: steps.isLast ? String(localized: "Enviar") : String(localized: "Continuar"),
                                  detailText: steps.ticked.isEmpty ? String(localized: "Marque uma ou mais opções") : steps.ticked.joined(separator: ", "),
                                  image: Self.symbol("arrow.right.circle.fill", .systemOrange))
            next.handler = { [weak self] _, done in
                Task { @MainActor in
                    guard let self else { done(); return }
                    guard state.next() else { done(); return }
                    done()
                    await self.advance(state, row: row)
                }
            }
            items.append(next)
        }
        let header = steps.questions.count > 1 ? "\(q.question) (\(steps.index + 1)/\(steps.questions.count))" : q.question
        return CPListTemplate(title: CarDigest.title(row.session), sections: [CPListSection(items: items, header: header, sectionIndexTitle: nil)])
    }

    /// After an answer: the next question, or the whole form sent and back to the list.
    private func advance(_ state: QuestionSteps, row: CarDigest.Row) async {
        guard state.isComplete else { pushStep(state, row: row); return }
        let result = await SessionActions.answerForm(box: row.box, session: row.session.name, questions: state.questions, answers: state.answers)
        switch result {
        case .success:
            interface?.popToRootTemplate(animated: true, completion: nil)
            shown = []
            await refresh()
        case .failure(let f):
            alert(f.message)
        }
    }

    private func voiceItem(_ row: CarDigest.Row) -> CPMessageListItem {
        CPMessageListItem(conversationIdentifier: row.id, text: String(localized: "Responder por voz"),
                          leadingConfiguration: CPMessageListItemLeadingConfiguration(
                            leadingItem: .none, leadingImage: Self.symbol("mic.fill", .systemBlue), unread: false),
                          trailingConfiguration: CPMessageListItemTrailingConfiguration(trailingItem: .none, trailingImage: nil),
                          detailText: String(localized: "Diga a resposta para o Siri"), trailingText: nil)
    }

    /// The last few messages of the conversation (the person's and the agent's), a line each: what the question is
    /// about, at a glance.
    private func conversation(_ row: CarDigest.Row) async -> CPListSection? {
        guard let client = try? HeadlessBoxes.box(row.box).client else { return nil }
        let name = row.session.name
        let page: TranscriptPage? = await BoxAccess.withTimeout(.seconds(4)) { try await client.transcriptBefore(session: name, before: 0, limit: 30) } ?? nil
        let said = (page?.items ?? []).filter { ($0.kind == "user" || $0.kind == "text") && !($0.text ?? "").isEmpty }.suffix(4)
        guard !said.isEmpty else { return nil }
        let agent = CarDigest.agentName(row.session)
        let items = said.map { it -> CPListItem in
            let mine = it.kind == "user"
            let text = CarDigest.spoken(it.text ?? "", limit: 160, codePlaceholder: String(localized: "(código)"))
            let item = CPListItem(text: text, detailText: mine ? String(localized: "Você") : agent,
                                  image: mine ? Self.symbol("person.crop.circle.fill", .systemGray) : Self.avatar(row))
            item.handler = { _, done in done() }
            return item
        }
        return CPListSection(items: Array(items), header: String(localized: "Conversa"), sectionIndexTitle: nil)
    }

    /// A row that answers the agent, then goes back to the list (or says why it could not).
    /// Before it acts, the session is read again: the answer goes only to the request this screen showed (the agent may
    /// have moved on to another one, Permitir must not approve that).
    private func answerItem(_ title: String, _ symbol: String, _ color: UIColor, row: CarDigest.Row,
                            _ act: @escaping @MainActor () async -> Result<Void, SessionActions.Failure>) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil, image: Self.symbol(symbol, color))
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                let now = await CarFeed.row(for: row.id)
                let same = now.map { $0.kind == .needsYou && $0.session.ask == row.session.ask && $0.since == row.since } ?? false
                let result = same ? await act() : .failure(.menuChanged)
                done()
                guard let self else { return }
                switch result {
                case .success:
                    self.interface?.popToRootTemplate(animated: true, completion: nil)
                    self.shown = []
                    await self.refresh()
                case .failure(let f):
                    self.alert(f.message)
                }
            }
        }
        return item
    }

    private func alert(_ message: String) {
        let ok = CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak self] _ in
            self?.interface?.dismissTemplate(animated: true, completion: nil)
        }
        let show = { [weak self] in
            self?.interface?.presentTemplate(CPAlertTemplate(titleVariants: [message], actions: [ok]), animated: true, completion: nil)
        }
        // One alert at a time: an older one goes first.
        if interface?.presentedTemplate != nil { interface?.dismissTemplate(animated: false) { _, _ in show() } } else { show() }
    }

    // MARK: drawing

    private static func symbol(_ name: String, _ color: UIColor) -> UIImage? {
        UIImage(systemName: name)?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    private static func avatar(_ row: CarDigest.Row) -> UIImage? {
        CommunicationNotification.avatarImage(for: CarDigest.agentName(row.session))
    }

    /// "agora", "5 min", "2 h": how long ago, short enough for the car's trailing text.
    private static func age(_ since: Date) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 1
        f.allowedUnits = [.day, .hour, .minute]
        let interval = Date().timeIntervalSince(since)
        return interval < 60 ? String(localized: "agora") : (f.string(from: interval) ?? "")
    }
}

#endif
