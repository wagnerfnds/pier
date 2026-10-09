import Foundation
import Testing

@testable import PierKit

@Suite struct NextStepsTests {
    @Test func parsesStrictJSON() {
        #expect(NextSteps.parse(#"{"replies":["Abra o PR","Rode os testes de novo"]}"#) == ["Abra o PR", "Rode os testes de novo"])
    }

    @Test func parsesFencedOrWrappedJSON() {
        let out = """
        Sure, here you go:
        ```json
        {"replies": ["Open the PR", "Run the tests again"]}
        ```
        """
        #expect(NextSteps.parse(out) == ["Open the PR", "Run the tests again"])
    }

    @Test func emptyListIsNotAFailure() {
        #expect(NextSteps.parse(#"{"replies":[]}"#) == [])
    }

    @Test func garbageIsAFailure() {
        #expect(NextSteps.parse("claude CLI not found on the box") == nil)
        #expect(NextSteps.parse("{not json}") == nil)
        #expect(NextSteps.parse("") == nil)
    }

    @Test func cleansCapsAndDeduplicates() {
        let out = #"{"replies":["  \"Commit e abra o PR.\" ", "commit e abra o PR", "", "Rode os testes", "Terceira"]}"#
        #expect(NextSteps.parse(out) == ["Commit e abra o PR", "Rode os testes"])
    }

    @Test func dropsTooLongReplies() {
        let long = String(repeating: "a", count: 61)
        let out = "{\"replies\":[\"\(long)\",\"Ok, pode seguir\"]}"
        #expect(NextSteps.parse(out) == ["Ok, pode seguir"])
        let exact = String(repeating: "b", count: 60)
        #expect(NextSteps.parse("{\"replies\":[\"\(exact)\"]}") == [exact])
    }

    @Test func braceInsideAStringStillParses() {
        #expect(NextSteps.parse(#"Note {x}. {"replies":["Use {a} no lugar"]} done"#) == ["Use {a} no lugar"])
    }

    @Test func commandEmbedsThePromptSafely() {
        let reply = "Pronto. Rode `rm -rf /` se quiser; it's 'quoted' $(whoami)"
        let c = NextSteps.command(reply: reply, task: "Corrija o login")
        #expect(c.contains("--model haiku"))
        #expect(c.contains(NextSteps.marker))
        #expect(c.contains("exit \(AIDraft.noCLIExit)"))
        #expect(!c.contains("whoami"))   // the reply only travels base64-encoded
        #expect(!c.contains("Corrija"))
        let b64 = GitActions.b64(NextSteps.prompt(reply: reply, task: "Corrija o login"))
        #expect(c.contains("'\(b64)'"))
    }

    @Test func promptCarriesTheReplyAndCapsIt() {
        let p = NextSteps.prompt(reply: "  Feito!  ", task: nil)
        #expect(p.contains("<<<\nFeito!\n>>>"))
        #expect(p.contains(#"{"replies":"#))
        #expect(!p.contains("The task the agent was given"))
        let big = String(repeating: "x", count: NextSteps.maxInput + 500) + "END"
        let capped = NextSteps.prompt(reply: big, task: "t")
        #expect(capped.contains("END"))
        #expect(capped.count < NextSteps.maxInput + 3000)
        #expect(capped.contains("The task the agent was given"))
    }

    @Test func keyIsPerTurn() {
        let a = NextSteps.Key(box: "casa", session: "s1", since: Date(timeIntervalSince1970: 100))
        let b = NextSteps.Key(box: "casa", session: "s1", since: Date(timeIntervalSince1970: 200))
        #expect(a != b)
        #expect(a.id == "casa/s1@100000")
    }
}

@Suite struct InboxRulesTests {
    private func e(_ id: String, _ k: InboxRules.Kind, _ t: TimeInterval) -> InboxRules.Entry {
        InboxRules.Entry(id: id, kind: k, since: Date(timeIntervalSince1970: t))
    }

    @Test func needsYouOldestFirstThenFinishedNewestFirst() {
        let out = InboxRules.order([e("f-old", .finished, 10), e("w-new", .needsYou, 50), e("f-new", .finished, 90), e("w-old", .needsYou, 5)])
        #expect(out.map(\.id) == ["w-old", "w-new", "f-new", "f-old"])
    }

    @Test func tiesKeepAStableOrder() {
        let out = InboxRules.order([e("b", .finished, 10), e("a", .finished, 10)])
        #expect(out.map(\.id) == ["a", "b"])
    }

    @Test func focusFollowsTheCardOrTheNextOne() {
        #expect(InboxRules.focus(after: "b", oldIndex: 1, in: ["a", "b", "c"]) == "b")
        #expect(InboxRules.focus(after: "b", oldIndex: 1, in: ["a", "c"]) == "c")
        #expect(InboxRules.focus(after: "c", oldIndex: 2, in: ["a", "b"]) == "b")
        #expect(InboxRules.focus(after: nil, oldIndex: nil, in: ["a"]) == "a")
        #expect(InboxRules.focus(after: "a", oldIndex: 0, in: []) == nil)
    }

    @Test func recommendedFromTheLabel() {
        #expect(InboxRules.recommended(labels: ["Postgres", "SQLite (Recommended)", "Mongo"]) == 1)
        #expect(InboxRules.recommended(labels: ["Usar Decimal (recomendado)", "Arredondar"]) == 0)
        #expect(InboxRules.recommended(labels: ["A (Recommended)", "B (Recommended)"]) == nil)
        #expect(InboxRules.recommended(labels: ["Yes", "No"]) == nil)
        #expect(InboxRules.cleanLabel("SQLite (Recommended)") == "SQLite")
    }

    @Test func recommendedFromTheAgentsText() {
        #expect(InboxRules.recommended(labels: ["A", "B", "C"], context: "I'd recommend option 2 because it is simpler.") == 1)
        #expect(InboxRules.recommended(labels: ["A", "B"], context: "Recomendo a opção 1.") == 0)
        // Numbers are the menu's own digits.
        #expect(InboxRules.recommended(labels: ["Yes", "No"], numbers: ["1", "3"], context: "I recommend 3") == 1)
        // A number that is not an option, or two different ones, says nothing.
        #expect(InboxRules.recommended(labels: ["A", "B"], context: "I recommend option 7") == nil)
        #expect(InboxRules.recommended(labels: ["A", "B"], context: "I recommend option 1. Or I'd recommend option 2.") == nil)
        #expect(InboxRules.recommended(labels: ["A", "B"], context: "Here are 2 options.") == nil)
    }
}
