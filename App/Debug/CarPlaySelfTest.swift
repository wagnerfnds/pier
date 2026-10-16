#if DEBUG && os(iOS) && !targetEnvironment(macCatalyst)
import CarPlay
import Intents
import PierKit

/// `-carPlaySelfTest 1` (with `-uiTestMock 1`, or real boxes): what the car and Siri would do, run in the app without a
/// car or a voice, one line each on stderr ("CARPLAY-TEST ..."):
/// 1. the car's rows (`CarFeed.rows`) and the CarPlay list built from them (`CarPlayController.sections`);
/// 2. Siri reading the conversations (`INSearchForMessagesIntent` through `MessageIntentHandler`);
/// 3. Siri resolving a spoken name and sending a reply to an ended turn (`INSendMessageIntent`), then the box's record
///    read back to see the reply arrived.
/// Simulator's CarPlay screen aside (Xcode 27's Device Hub has none), this is how CarPlay's logic is checked.
@MainActor
enum CarPlaySelfTest {
    /// An intent's answer carried out of its completion handler (the system's types are not Sendable; read once, here).
    private struct Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "carPlaySelfTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            func say(_ s: String) { FileHandle.standardError.write(Data("CARPLAY-TEST \(s)\n".utf8)) }

            let rows = await CarFeed.rows()
            say("rows \(rows.map { "\($0.kind)|\(CarDigest.title($0.session))" })")
            let sections = CarPlayController(interface: nil).sections(rows)
            for sec in sections {
                let items = sec.items.map { item -> String in
                    if let m = item as? CPMessageListItem { return "msg[\(m.text ?? "")|\(m.detailText ?? "")|\(m.conversationIdentifier ?? "")]" }
                    if let l = item as? CPListItem { return "item[\(l.text ?? "")|\(l.detailText ?? "")]" }
                    return "?"
                }
                say("section \(sec.header ?? "") \(items)")
            }
            // What a waiting agent opens: its answers (a form a question at a time), the voice reply, the conversation.
            let car = CarPlayController(interface: nil)
            func show(_ t: CPListTemplate, _ name: String) {
                for sec in t.sections {
                    let items = sec.items.map { ($0 as? CPListItem)?.text ?? ($0 as? CPMessageListItem)?.text ?? "?" }
                    say("\(name) [\(sec.header ?? "")] \(items)")
                }
            }
            for row in rows where row.kind == .needsYou {
                show(await car.answerTemplate(row), "answers \(CarDigest.title(row.session))")
                if let qs = row.session.ask?.questionItem?.questions, QuestionSteps.needed(for: qs), let first = qs.first?.options.first?.label {
                    var st = QuestionSteps(questions: qs)
                    st.choose(first)
                    show(car.stepTemplate(st, row: row), "step2 \(CarDigest.title(row.session))")
                }
            }

            let handler = MessageIntentHandler()
            let search = INSearchForMessagesIntent(recipients: nil, senders: nil, searchTerms: nil, attributes: .unread,
                                                   dateTime: nil, identifiers: nil, notificationIdentifiers: nil,
                                                   speakableGroupNames: nil, conversationIdentifiers: nil)
            let read = await withCheckedContinuation { (c: CheckedContinuation<Box<INSearchForMessagesIntentResponse>, Never>) in
                handler.handle(intent: search) { c.resume(returning: Box($0)) }
            }.value
            for m in read.messages ?? [] {
                say("read \(m.sender?.displayName ?? "?"): \(m.content ?? "")")
            }

            guard let ended = rows.first(where: { $0.kind == .yourTurn }) else { say("send skipped: no ended turn"); return }
            let spoken = INPerson(personHandle: INPersonHandle(value: nil, type: .unknown), nameComponents: nil, displayName: CarDigest.title(ended.session), image: nil,
                                  contactIdentifier: nil, customIdentifier: nil)
            let send = INSendMessageIntent(recipients: [spoken], outgoingMessageType: .outgoingMessageText,
                                           content: "Pode seguir com os testes", speakableGroupName: nil,
                                           conversationIdentifier: nil, serviceName: nil, sender: nil, attachments: nil)
            let resolved = await withCheckedContinuation { (c: CheckedContinuation<Box<[INSendMessageRecipientResolutionResult]>, Never>) in
                handler.resolveRecipients(for: send) { c.resume(returning: Box($0)) }
            }.value
            say("resolve '\(CarDigest.title(ended.session))' -> \(resolved.map { String(describing: type(of: $0)) }) \(resolved.count)")
            // What Siri sends after resolving: the conversation it picked.
            let reply = INSendMessageIntent(recipients: [MessageIntentHandler.person(ended)], outgoingMessageType: .outgoingMessageText,
                                            content: "Pode seguir com os testes", speakableGroupName: nil,
                                            conversationIdentifier: ended.id, serviceName: nil, sender: nil, attachments: nil)
            let sent = await withCheckedContinuation { (c: CheckedContinuation<Box<INSendMessageIntentResponse>, Never>) in
                handler.handle(intent: reply) { c.resume(returning: Box($0)) }
            }.value
            say("send code=\(sent.code.rawValue) (success=\(INSendMessageIntentResponseCode.success.rawValue))")
            if let client = try? HeadlessBoxes.box(ended.box).client,
               let page = try? await client.transcriptBefore(session: ended.session.name, before: 0, limit: 10) {
                let arrived = page.items.contains { $0.kind == "user" && $0.text == "Pode seguir com os testes" }
                say("arrived \(arrived)")
            }
            // A spoken reply to agents that wait: a question takes the words as its answer, a permission refuses them.
            for row in rows where row.kind == .needsYou {
                let r = await SessionActions.reply(box: row.box, session: row.session.name, text: "Use a opção mais simples")
                let kind = Ask.classify(row.session.ask) == .permission ? "permission" : "question"
                switch r {
                case .success:
                    try? await Task.sleep(for: .seconds(2))
                    let page = try? await HeadlessBoxes.box(row.box).client.transcriptBefore(session: row.session.name, before: 0, limit: 10)
                    let got = page?.items.contains { ($0.text ?? "").contains("Use a opção mais simples") } ?? false
                    say("reply \(kind) -> answered, in the record: \(got)")
                case .failure(let f): say("reply \(kind) -> refused: \(f.message)")
                }
            }
            say("siri \(INPreferences.siriAuthorizationStatus().rawValue)")
            say("done")
        }
    }
}
#endif
