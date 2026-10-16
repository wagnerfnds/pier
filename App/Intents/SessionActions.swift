import Foundation
import PierKit

/// Headless actions on a session (notification buttons, Shortcuts). Never blindly sends "1": the menu is read first.
enum SessionActions {
    enum Failure: Error, Equatable {
        /// The session no longer shows an Allow/Deny menu (answered elsewhere, changed, or it is a question).
        case menuChanged
        case failed(String)

        var message: String {
            switch self {
            case .menuChanged: String(localized: "O pedido mudou ou já foi respondido. Abra o Pier para ver.")
            case .failed(let m): m
            }
        }
    }

    /// Answers a permission menu with Allow / Deny through the shared `PermissionAnswer` (digit from a fresh screen, never a guess);
    /// retries a few times because the menu is drawn a moment after the event.
    static func answerPermission(box: String, session: String, _ answer: PermissionAnswer) async -> Result<Void, Failure> {
        var last: Error?
        for attempt in 0..<4 {
            do {
                _ = try await PermissionAnswer.send(answer, box: box, session: session)
                return .success(())
            } catch SessionIntentError.noMenu {
                last = SessionIntentError.noMenu
                if attempt < 3 { try? await Task.sleep(for: .milliseconds(600)) }
            } catch {
                return .failure(.failed(describe(error)))
            }
        }
        _ = last
        return .failure(.menuChanged)
    }

    /// Answers a question (or a plain menu) with one of its choices, from a notification's button: the box is read again first
    /// and the choice must still be there, under the same words. A structured answer when the transcript holds the question
    /// (`POST .../answer`, docs/API.md §5.4), else the digit of the row on screen, else the cursor keys of an unnumbered
    /// menu. A few tries, because the agent draws its question a moment after the event.
    static func answerChoice(box: String, session: String, label: String) async -> Result<Void, Failure> {
        let client: any PierBoxClient
        do { client = try HeadlessBoxes.box(box).client } catch { return .failure(.failed(describe(error))) }
        let wanted = InboxRules.cleanLabel(label)
        func same(_ l: String) -> Bool { l == label || InboxRules.cleanLabel(l) == wanted }
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
            guard let s = try? await client.sessions().first(where: { $0.name == session }) else { continue }
            guard s.needsYou else { return .failure(.menuChanged) }
            do {
                // The form the hook sent with the wait (Claude Code records the question only once answered).
                if let qs = s.ask?.questionItem?.questions, qs.count == 1, qs[0].multi != true,
                   let pick = qs[0].options.first(where: { same($0.label) })?.label,
                   (try? await client.answerQuestions(session: session, tool: "AskUserQuestion", answers: [.pick(pick)])) != nil {
                    await SessionActivityBridge.answered(box: box, session: session)
                    return .success(())
                }
                if Ask.classify(s.ask) == .question, let page = try? await client.transcript(session: session, since: 0, gen: nil),
                   let q = QuestionHelpers.openQuestion(in: page.items), let qs = q.questions, qs.count == 1, qs[0].multi != true,
                   let pick = qs[0].options.first(where: { same($0.label) })?.label {
                    do {
                        _ = try await client.answerQuestions(session: session, tool: q.tool ?? "AskUserQuestion", answers: [QuestionAnswer(picks: [pick])])
                        await SessionActivityBridge.answered(box: box, session: session)
                        return .success(())
                    } catch {
                        // The box could not drive the form (409) or the agent is Codex: the digit on screen, below.
                    }
                }
                let screen = try await client.screen(session: session, history: 0)
                if let c = MenuParser.choices(in: screen).first(where: { same($0.label) }) {
                    _ = try await client.send(session: session, .key(c.key))
                    await SessionActivityBridge.answered(box: box, session: session)
                    return .success(())
                }
                if let q = ScreenQuestion.make(screen: screen, ask: s.ask), let question = q.questions?.first,
                   let pick = question.options.first(where: { same($0.label) })?.label, let digit = QuestionHelpers.menuKey(forPick: pick, in: question) {
                    _ = try await client.send(session: session, .key(digit))
                    await SessionActivityBridge.answered(box: box, session: session)
                    return .success(())
                }
                if let menu = MenuParser.cursorMenu(in: screen), let i = menu.options.firstIndex(where: { same($0) }) {
                    try await client.keys(session: session, menu.keys(toPick: i))
                    await SessionActivityBridge.answered(box: box, session: session)
                    return .success(())
                }
            } catch {
                return .failure(.failed(describe(error)))
            }
        }
        return .failure(.menuChanged)
    }

    /// Queues a message for the agent: delivered once it is idle (`when: idle`), or at once with `now`.
    static func send(box: String, session: String, text: String, when: SendRequest.When = .idle) async -> Result<SendResult, Failure> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.failed(String(localized: "A mensagem está vazia."))) }
        do {
            let client = try HeadlessBoxes.box(box).client
            return .success(try await client.send(session: session, SendRequest(text: t, enter: true, when: when)))
        } catch {
            return .failure(.failed(describe(error)))
        }
    }

    /// A reply said to Siri (CarPlay, a notification's "Responder"), checked against the session first: an agent waiting
    /// on a permission menu takes only Permitir / Negar (no words are typed into a menu); one waiting on a question gets
    /// the words as its answer (the question's own form when the record holds it, else typed as an answer); anything
    /// else gets them as the next prompt, held until the agent is free (`when: idle`).
    static func reply(box: String, session: String, text: String) async -> Result<Void, Failure> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.failed(String(localized: "A mensagem está vazia."))) }
        do {
            let client = try HeadlessBoxes.box(box).client
            guard let s = try await client.sessions().first(where: { $0.name == session }) else {
                return .failure(.failed(HeadlessError.sessionNotFound(session).localizedDescription))
            }
            guard s.needsYou else {
                _ = try await client.send(session: session, SendRequest(text: t, enter: true, when: .idle))
                return .success(())
            }
            if Ask.classify(s.ask) == .permission {
                return .failure(.failed(String(localized: "Esse agente espera Permitir ou Negar: responda pelos botões.")))
            }
            // The open form: one question takes the words as its own-words answer; a form with steps is answered from
            // its choices (one answer for several questions would be a guess).
            if let qs = s.ask?.questionItem?.questions {
                guard qs.count == 1 else {
                    return .failure(.failed(String(localized: "Essa pergunta tem várias partes: responda pelas opções na tela.")))
                }
                if (try? await client.answerQuestions(session: session, tool: "AskUserQuestion", answers: [.other(t)])) != nil {
                    await SessionActivityBridge.answered(box: box, session: session)
                    return .success(())
                }
            }
            if let page = try? await client.transcript(session: session, since: 0, gen: nil),
               let q = QuestionHelpers.openQuestion(in: page.items), let qs = q.questions, qs.count == 1, qs[0].multi != true,
               (try? await client.answerQuestions(session: session, tool: q.tool ?? "AskUserQuestion", answers: [QuestionAnswer(other: t)])) != nil {
                await SessionActivityBridge.answered(box: box, session: session)
                return .success(())
            }
            // A question only on screen (Claude Code writes it to its record once answered): its "Type something." row,
            // then the words, as pierd answers in the person's own words. No such row, no typing into the menu.
            let screen = try await client.screen(session: session, history: 0)
            guard let key = MenuParser.typeSomethingKey(in: screen) else {
                return .failure(.failed(String(localized: "Essa pergunta só aceita uma das opções: escolha pelos botões.")))
            }
            _ = try await client.send(session: session, SendRequest(text: key, enter: false, when: .now, force: true))
            try? await Task.sleep(for: .milliseconds(400))   // the row opens its text field
            _ = try await client.send(session: session, SendRequest(text: t, enter: true, when: .now, force: true))
            await SessionActivityBridge.answered(box: box, session: session)
            return .success(())
        } catch {
            return .failure(.failed(describe(error)))
        }
    }

    /// A whole open form's answers (the car steps through it a question at a time): sent only while it is still that
    /// form, through the box (`POST .../answer` with the tool's name).
    static func answerForm(box: String, session: String, questions: [Question], answers: [QuestionAnswer]) async -> Result<Void, Failure> {
        do {
            let client = try HeadlessBoxes.box(box).client
            guard let s = try await client.sessions().first(where: { $0.name == session }), s.needsYou,
                  s.ask?.questionItem?.questions == questions else { return .failure(.menuChanged) }
            _ = try await client.answerQuestions(session: session, tool: "AskUserQuestion", answers: answers)
            await SessionActivityBridge.answered(box: box, session: session)
            return .success(())
        } catch {
            return .failure(.failed(describe(error)))
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? SessionIntentError { return String(localized: e.localizedStringResource) }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return error.localizedDescription
    }
}
