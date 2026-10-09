import Foundation
import Testing

@testable import PierKit

@Suite struct TalkRouterTests {
    private let context = TalkRouter.Context(
        sessions: [
            .init(box: "devbox", name: "acme-web-login-claude-1a", title: "Corrigir login", location: "acme-web/login",
                  state: "your_turn", agent: "claude", lastReply: "Pronto: o login agora aceita e-mail.\nDetalhes abaixo"),
            .init(box: "devbox", name: "sandbox-claude-w9q", title: "Create a probe directory", location: "sandbox", state: "needs_you"),
            .init(box: "mini", name: "shop-claude-2b", title: "Checkout | retries", location: "shop/checkout", state: "working"),
            .init(box: "mini", name: "dup", title: "Same title", location: "shop", state: "ready"),
            .init(box: "devbox", name: "dup", title: "Same title", location: "sandbox", state: "ready"),
        ],
        projects: [
            .init(box: "devbox", location: "acme-web", displayName: "Acme", worktrees: ["login"]),
            .init(box: "devbox", location: "sandbox"),
            .init(box: "mini", location: "shop", worktrees: ["checkout"]),
        ])

    private func parse(_ s: String) -> Result<TalkRouter.Decision, TalkRouter.Failure> { TalkRouter.parse(s, context: context) }

    @Test func sendToAKnownSession() {
        let r = parse(#"{"action":"send","box":"devbox","session":"acme-web-login-claude-1a","text":"Adicione um teste para senha vazia"}"#)
        #expect(r == .success(.send(box: "devbox", session: "acme-web-login-claude-1a", text: "Adicione um teste para senha vazia")))
    }

    @Test func newTaskInAKnownProject() {
        let r = parse(#"{"action":"new_task","box":"devbox","location":"sandbox","prompt":"Write a README","title":"README"}"#)
        #expect(r == .success(.newTask(box: "devbox", location: "sandbox", prompt: "Write a README", title: "README")))
    }

    @Test func askCarriesTheQuestion() {
        #expect(parse(#"{"action":"ask","question":"Qual projeto?"}"#) == .success(.ask(question: "Qual projeto?")))
    }

    @Test func toleratesFencesProseAndBracesInStrings() {
        let out = """
        Sure! Here is the routing:
        ```json
        {"action": "send", "box": "mini", "session": "shop-claude-2b", "text": "use {retries: 3} and say \\"ok\\""}
        ```
        """
        #expect(parse(out) == .success(.send(box: "mini", session: "shop-claude-2b", text: "use {retries: 3} and say \"ok\"")))
    }

    @Test func fillsAMissingBoxAndAcceptsAUniqueTitle() {
        #expect(parse(#"{"action":"send","session":"shop-claude-2b","text":"x"}"#) == .success(.send(box: "mini", session: "shop-claude-2b", text: "x")))
        #expect(parse(#"{"action":"send","session":"corrigir login","text":"x"}"#)
                == .success(.send(box: "devbox", session: "acme-web-login-claude-1a", text: "x")))
        #expect(parse(#"{"action":"new_task","location":"Acme","prompt":"p"}"#)
                == .success(.newTask(box: "devbox", location: "acme-web", prompt: "p", title: nil)))
        #expect(parse(#"{"action":"new-task","box":"mini","location":"shop","prompt":"p","title":"  "}"#)
                == .success(.newTask(box: "mini", location: "shop", prompt: "p", title: nil)))
    }

    @Test func rejectsUnknownSessionsAndProjects() {
        #expect(parse(#"{"action":"send","box":"devbox","session":"nope-claude-9","text":"x"}"#) == .failure(.unknownSession("nope-claude-9")))
        // Right id, wrong box.
        #expect(parse(#"{"action":"send","box":"devbox","session":"shop-claude-2b","text":"x"}"#) == .failure(.unknownSession("shop-claude-2b")))
        // Same id on two boxes and no box: ambiguous, rejected.
        #expect(parse(#"{"action":"send","session":"dup","text":"x"}"#) == .failure(.unknownSession("dup")))
        #expect(parse(#"{"action":"send","box":"mini","session":"dup","text":"x"}"#) == .success(.send(box: "mini", session: "dup", text: "x")))
        // A worktree is not a project.
        #expect(parse(#"{"action":"new_task","box":"devbox","location":"acme-web/login","prompt":"p"}"#) == .failure(.unknownProject("acme-web/login")))
        #expect(parse(#"{"action":"new_task","box":"devbox","location":"shop","prompt":"p"}"#) == .failure(.unknownProject("shop")))
        #expect(parse(#"{"action":"send","box":"devbox","text":"x"}"#) == .failure(.unknownSession("")))
    }

    @Test func rejectsMalformedEmptyAndUnknownActions() {
        #expect(parse("") == .failure(.malformed))
        #expect(parse("I think you should send it to the login agent.") == .failure(.malformed))
        #expect(parse(#"{"action":"send","box":"devbox","session":"#) == .failure(.malformed))
        #expect(parse(#"{"action": send}"#) == .failure(.malformed))
        #expect(parse(#"{"action":"delete","session":"sandbox-claude-w9q"}"#) == .failure(.unknownAction("delete")))
        #expect(parse(#"{"session":"sandbox-claude-w9q","text":"x"}"#) == .failure(.unknownAction("")))
        #expect(parse(#"{"action":"send","box":"devbox","session":"sandbox-claude-w9q","text":"   "}"#) == .failure(.empty))
        #expect(parse(#"{"action":"ask","question":""}"#) == .failure(.empty))
        #expect(parse(#"{"action":"new_task","box":"devbox","location":"sandbox"}"#) == .failure(.empty))
        // A non-object first brace pair is skipped for the real one.
        #expect(parse(#"{oops} {"action":"ask","question":"Which?"}"#) == .success(.ask(question: "Which?")))
    }

    @Test func promptListsSessionsAndProjectsCompactly() {
        let p = TalkRouter.prompt(request: "  adiciona um teste no login  ", context: context, language: "Brazilian Portuguese")
        #expect(p.contains("<<<\nadiciona um teste no login\n>>>"))
        #expect(p.contains("- acme-web-login-claude-1a | devbox | Corrigir login | acme-web/login | your_turn | Pronto: o login agora aceita e-mail.\n"))
        // Column separators inside a title are neutralised.
        #expect(p.contains("| Checkout / retries |"))
        #expect(p.contains("- acme-web | devbox | Acme | login\n"))
        #expect(p.contains("- sandbox | devbox | sandbox | -\n"))
        #expect(p.contains("Brazilian Portuguese"))
        let empty = TalkRouter.prompt(request: "x", context: .init(sessions: [], projects: []), language: "English")
        #expect(empty.components(separatedBy: "(none)").count == 3)
    }

    @Test func commandShipsThePromptBase64AndUsesHaiku() throws {
        let prompt = "it's \"quoted\" $(rm -rf /) `x`"
        let cmd = TalkRouter.command(prompt: prompt)
        #expect(cmd.hasPrefix(": pier-talk;"))
        #expect(cmd.contains("-p --model haiku"))
        #expect(!cmd.contains("rm -rf"))
        let b64 = try #require(cmd.range(of: "printf %s '").map { cmd[$0.upperBound...] }?.prefix { $0 != "'" })
        #expect(String(decoding: Data(base64Encoded: String(b64)) ?? Data(), as: UTF8.self) == prompt)
        #expect(cmd.contains("exit \(TalkRouter.noCLIExit)"))
    }
}
