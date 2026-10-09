import Foundation
import Testing

@testable import PierKit

@Suite struct MenuParserTests {
    /// Claude Code's startup dialog for a project's MCP servers, drawn in a box, before any hook marks the agent as waiting.
    @Test func boxedMcpDialog() {
        let screen = """
        ╭──────────────────────────────────────────────────────────────────────────────╮
        │ New MCP server found in .mcp.json: notes                                     │
        │                                                                              │
        │ MCP servers may execute code or access system resources. All tool calls      │
        │ require approval. Learn more in the MCP documentation.                       │
        │                                                                              │
        │ ❯ 1. Use this and all future MCP servers in this project                      │
        │   2. Use this MCP server                                                     │
        │   3. Continue without using this MCP server                                  │
        │                                                                              │
        ╰──────────────────────────────────────────────────────────────────────────────╯
           Enter to confirm · Esc to reject
        """
        let menu = parseMenu(screen)
        #expect(menu.map(\.key) == ["1", "2", "3"])
        #expect(menu.map(\.label) == ["Use this and all future MCP servers in this project", "Use this MCP server", "Continue without using this MCP server"])
        #expect(MenuParser.screenAt(agent: "claude", screen) == .interactive)
    }

    /// The real screen of Claude Code 2.1.294 for a project's new MCP server: no numbers, cursor on the last option.
    @Test func realUnnumberedMcpDialog() throws {
        let screen = try Fixture.screen("screen_mcp_dialog.json")
        #expect(parseMenu(screen).isEmpty)
        let m = try #require(MenuParser.cursorMenu(in: screen))
        #expect(m.options == ["Use this MCP server", "Use this and all future MCP servers in this project", "Continue without using this MCP server"])
        #expect(m.selected == 2)
        #expect(m.keys(toPick: 0) == [.up, .up, .enter])
        #expect(m.keys(toPick: 2) == [.enter])
        #expect(MenuParser.screenAt(agent: "claude", screen) == .interactive)
    }

    @Test func promptIsNotACursorMenu() throws {
        #expect(MenuParser.cursorMenu(in: try Fixture.screen("screen_permission.json")) == nil)
        let prompt = "──────────\n❯ fix the login\n──────────\n  ? for shortcuts"
        #expect(MenuParser.cursorMenu(in: prompt) == nil)
    }

    @Test func narrowBoxedMenuKeepsLabelsClean() {
        let screen = "│ Pick │\n│ ❯ 1. Yes │\n│   2. No  │\n"
        #expect(parseMenu(screen).map(\.label) == ["Yes", "No"])
    }

    @Test func realClaudePermissionScreen() throws {
        let screen = try Fixture.screen("screen_permission.json")
        let menu = parseMenu(screen)
        #expect(menu.count == 4)
        #expect(menu.map(\.key) == ["1", "2", "3", "4"])
        // the box's side pane (" │ ...") never leaks into a label
        #expect(menu.allSatisfy { !$0.label.contains("│") })
        #expect(menu[2].label.hasPrefix("Yes, and switch to auto mode"))
        let p = try #require(MenuParser.permissionChoices(menu))
        #expect(p.map(\.label) == ["Allow", "Always allow", "Deny"])
        #expect(p.map(\.key) == ["1", "2", "4"])
        #expect(MenuParser.screenAt(agent: "claude", screen) == .interactive)
        #expect(!MenuParser.keysOnly(screen))
    }

    /// The choices a notification shows as buttons: a question's rows without the agent's own "Type something" ones
    /// (pierd's push engine reads the same, `menu.OptionLabels`).
    @Test func optionLabelsDropTheQuestionsOwnRows() throws {
        let question = """
        ● Which layout for the pricing page?

         ❯ 1. Three tiers
              Starter, Pro and Team side by side
           2. One plan
           3. A table
           4. Type something.
           5. Chat about this
        """
        #expect(MenuParser.optionLabels(in: question) == ["Three tiers", "One plan", "A table"])
        let plan = "Ready to code?\n\n ❯ 1. Yes, and auto-accept edits\n   2. Yes, and manually approve edits\n   3. No, keep planning\n"
        #expect(MenuParser.optionLabels(in: plan) == ["Yes, and auto-accept edits", "Yes, and manually approve edits", "No, keep planning"])
        #expect(MenuParser.optionLabels(in: try Fixture.screen("screen_finished.json")).isEmpty)
        // A permission menu keeps every row: the caller decides whether Permitir / Negar buttons serve better.
        #expect(MenuParser.optionLabels(in: try Fixture.screen("screen_permission.json")).count == 4)
    }

    @Test func rawScreenWithTrailingPanelLines() throws {
        // 20 trailing lines holding only the side panel's " │" used to push the options out of the 14-line window
        let screen = try Fixture.screen("synthetic/screen_permission_tall_panel.json")
        #expect(screen.contains("│"))
        #expect(parseMenu(screen).map(\.key) == ["1", "2", "3", "4"])
        #expect(MenuParser.actions(in: screen) == [.allow(key: "1"), .alwaysAllow(key: "2"), .deny(key: "4")])
        #expect(MenuParser.screenAt(agent: "claude", screen) == .interactive)
        #expect(!MenuParser.stripPanel(screen).contains("│"))
        #expect(MenuParser.stripPanel(MenuParser.stripPanel(screen)) == MenuParser.stripPanel(screen))
    }

    @Test func claudeExtraPermissionOptions() throws {
        let screen = try Fixture.screen("synthetic/screen_permission_read_project.json")
        let menu = parseMenu(screen)
        #expect(menu.map(\.key) == ["1", "2", "3", "4"])
        #expect(menu[1].label.hasPrefix("Yes, allow reading from"))
        #expect(MenuParser.actions(in: screen) == [.allow(key: "1"), .alwaysAllow(key: "2"), .deny(key: "4")])
        func c(_ labels: [String]) -> [MenuChoice] { labels.enumerated().map { MenuChoice(key: String($0.offset + 1), label: $0.element) } }
        // auto-mode offer stands in as the extra when "don't ask again" is absent; "don't ask again" wins when both exist
        let auto = permissionActions(c(["Yes", "Yes, and switch to auto mode · handles these prompts", "No"]))
        #expect(auto.allow?.key == "1" && auto.always?.key == "2" && auto.deny?.key == "3")
        let both = permissionActions(c(["Yes", "Yes, and switch to auto mode", "Yes, and don't ask again for ls commands", "No"]))
        #expect(both.allow?.key == "1" && both.always?.key == "3" && both.deny?.key == "4")
        let reading = permissionActions(c(["Yes", "Yes, allow reading from src/ from this project", "No"]))
        #expect(reading.always?.key == "2")
    }

    @Test func stripPanelLeavesPlainScreensAlone() {
        #expect(MenuParser.stripPanel("a │ b\nc\n\n") == "a │ b\nc")
    }

    @Test func realClaudeQuestionScreenIsNotAPermission() throws {
        let screen = try Fixture.screen("screen_question.json")
        let menu = parseMenu(screen)
        #expect(menu.map(\.label).prefix(2) == ["Red", "Blue"])
        #expect(menu.map(\.key) == ["1", "2", "3", "4"])
        #expect(MenuParser.permissionChoices(menu) == nil)
        #expect(QuestionHelpers.menuKey(forPick: "Blue", in: Question(question: "Which colour?", options: [QuestionOption(label: "Red"), QuestionOption(label: "Blue")])) == "2")
    }

    @Test func realClaudeTrustDialogNeedsKeys() throws {
        let screen = try Fixture.screen("screen_claude_trust.json")
        #expect(parseMenu(screen).isEmpty)  // "❯ No, exit / Yes, I trust this folder" carries no numbers
        #expect(MenuParser.screenAt(agent: "claude", screen) == .interactive)
        #expect(MenuParser.keysOnly(screen))
    }

    @Test func realCodexTrustDialog() throws {
        let screen = try Fixture.screen("screen_codex_trust.json")
        let menu = parseMenu(screen)
        #expect(menu == [MenuChoice(key: "1", label: "Trust and continue"), MenuChoice(key: "2", label: "Back to Agent Command Center")])
        // "Trust and continue" matches no Allow/Deny words: show the screen + keys instead of buttons
        #expect(MenuParser.permissionChoices(menu) == nil)
        // Same as the desktop: Codex's "›" selection marker reads as its prompt line (its footer has no recognised key hint),
        // so look at `choices(in:)` first and only then at `screenAt`.
        #expect(MenuParser.screenAt(agent: "codex", screen) == .prompt)
        #expect(!MenuParser.choices(in: screen).isEmpty)
    }

    @Test func realFinishedScreenShowsPromptNotMenu() throws {
        let screen = try Fixture.screen("screen_finished.json")
        #expect(parseMenu(screen).isEmpty)
        #expect(!screen.isEmpty)
    }

    @Test func borderlessClassicMenu() throws {
        let screen = try Fixture.text("synthetic/screen_permission_borderless.txt")
        let menu = parseMenu(screen)
        #expect(menu.map(\.key) == ["1", "2", "3"])
        #expect(menu[1].label == "Yes, and don't ask again for rm commands in /home/me/shop")
        let acts = permissionActions(menu)
        #expect(acts.allow?.key == "1" && acts.always?.key == "2" && acts.deny?.key == "3")
        #expect(MenuParser.actions(in: screen) == [.allow(key: "1"), .alwaysAllow(key: "2"), .deny(key: "3")])
    }

    @Test func menuRules() {
        // needs two options counting up from 1
        #expect(parseMenu("  2. a\n  3. b\n").isEmpty)
        #expect(parseMenu("  1. only one\n").isEmpty)
        // first of each digit wins, at most 4 options, `)` and `›` / `>` markers work
        let screen = "› 1) one\n  2) two\n  2) dup\n  3) three\n  4) four\n  5) five\n"
        #expect(parseMenu(screen).map(\.label) == ["one", "two", "three", "four"])
        // only the last 14 lines are read
        let long = "  1. old\n  2. older\n" + String(repeating: "x\n", count: 14)
        #expect(parseMenu(long).isEmpty)
        // trailing blank lines (a taller pane) are ignored
        #expect(parseMenu("  1. a\n  2. b\n" + String(repeating: "\n", count: 30)).count == 2)
        // labels are trimmed; text without a digit never matches
        #expect(parseMenu(">   1.   spaced   \n 2. b\n").first?.label == "spaced")
        #expect(parseMenu("Step 1. do it\n").isEmpty)
    }

    @Test func questionFormIsNotAMenu() {
        let form = " ←  ☐ Colour  ☐ Toppings  ✔ Submit  →\n\n Which colour?\n ❯ 1. Red\n   2. Blue\n"
        #expect(MenuParser.questionForm(in: form))
        #expect(parseMenu(form).isEmpty)
        #expect(MenuParser.questionForm(in: " ☐ Drink   ✔ Submit\n"))
        #expect(!MenuParser.questionForm(in: " ☐ Drink\n ❯ 1. Tea\n   2. Coffee\n"))
        #expect(parseMenu(" ☐ Drink\n ❯ 1. Tea\n   2. Coffee\n").count == 2)
    }

    @Test func permissionMapping() {
        func c(_ labels: [String]) -> [MenuChoice] { labels.enumerated().map { MenuChoice(key: String($0.offset + 1), label: $0.element) } }
        // Codex-style wording
        let codex = permissionActions(c(["Yes, proceed", "Yes, and don't ask again for this command", "No, and tell Codex what to do differently"]))
        #expect(codex.allow?.key == "1" && codex.always?.key == "2" && codex.deny?.key == "3")
        // "always" wording
        let always = permissionActions(c(["Allow once", "Always allow for this session", "Deny"]))
        #expect(always.allow?.key == "1" && always.always?.key == "2" && always.deny?.key == "3")
        // allow must differ from the always option
        let only = permissionActions(c(["Yes, always", "No"]))
        #expect(only.allow == nil && only.always?.key == "1")
        #expect(MenuParser.permissionChoices(c(["Yes, always", "No"])) == nil)
        // reject / approve
        #expect(permissionActions(c(["Approve", "Reject"])).deny?.key == "2")
        #expect(MenuParser.permissionChoices(c(["Approve", "Reject"]))?.map(\.label) == ["Allow", "Deny"])
        // not a permission
        #expect(MenuParser.permissionChoices(c(["Red", "Blue"])) == nil)
        // "Yes" must start the label: "Nothing" is not "No"
        #expect(permissionActions(c(["Nothing here", "Yesterday"])).deny == nil)
        // A refusal that also says "don't ask again" / "this session" is Deny, never "Always allow"
        let refusal = permissionActions(c(["Yes", "No, and don't ask again this session", "No, and tell Claude what to do differently"]))
        #expect(refusal.allow?.key == "1" && refusal.always == nil && refusal.deny?.key == "2")
        #expect(MenuParser.permissionChoices(c(["Yes", "No, and don't ask again this session"]))?.map(\.key) == ["1", "2"])
        let noProject = permissionActions(c(["Yes", "No, not for this project", "No"]))
        #expect(noProject.always == nil && noProject.allow?.key == "1" && noProject.deny?.key == "2")
    }

    @Test func screenAtPromptDetection() {
        let rule = String(repeating: "─", count: 40)
        let claude = "● Done.\n\n\(rule)\n❯ \n\(rule)\n  ⏵⏵ auto mode on (shift+tab to cycle)\n"
        #expect(MenuParser.screenAt(agent: "claude", claude) == .prompt)
        // the prompt line with a no-break space after the caret
        #expect(MenuParser.screenAt(agent: "claude", "x\n\(rule)\n❯\u{00A0}\n\(rule)\n") == .prompt)
        let codex = "• Done\n\n› Ask Codex to do anything\n\n  GPT default · ~/code/x\n"
        #expect(MenuParser.screenAt(agent: "codex", codex) == .prompt)
        #expect(MenuParser.screenAt(agent: "codex", "› 1. Trust\n  2. Back\n  Press enter to continue\n") == .interactive)
        #expect(MenuParser.screenAt(agent: nil, "$ ls\nfile\n") == .unknown)
        #expect(MenuParser.screenAt(agent: nil, "Pick a model\n  ↑/↓ to navigate · Enter to select\n") == .interactive)
    }

    @Test func meaningfulTailAndLastMessage() throws {
        let screen = "  ● Added the function.\n    It returns a - b.\n\n✻ Brewed for 1s · done 7:14 PM\n\(String(repeating: "─", count: 30))\n❯ \n\(String(repeating: "─", count: 30))\n  ⏵⏵ auto mode on\n"
        #expect(MenuParser.meaningfulTail(screen, 5) == ["  ● Added the function.", "    It returns a - b.", "✻ Brewed for 1s · done 7:14 PM"])
        #expect(MenuParser.lastMessage(screen) == ["Added the function.", "It returns a - b."])
        let real = try Fixture.screen("screen_finished.json")
        #expect(!MenuParser.meaningfulTail(real, 10).isEmpty)
    }
}

@Suite struct ANSITests {
    @Test func stripsEscapes() {
        #expect(ANSI.strip("\u{1B}[31mred\u{1B}[0m plain") == "red plain")
        #expect(ANSI.strip("\u{1B}[1;38;5;208mbold\u{1B}[m!") == "bold!")
        #expect(ANSI.strip("a\u{1B}[2K\u{1B}[1Gb") == "ab")
        #expect(ANSI.strip("\u{1B}]0;title\u{07}text") == "text")
        #expect(ANSI.strip("\u{1B}]8;;https://x.y\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
        #expect(ANSI.strip("\u{1B}(Bok\u{1B}=") == "ok")
        #expect(ANSI.strip("line1\r\nline2\ttab\u{07}") == "line1\nline2\ttab")
        #expect(ANSI.strip("❯ 1. Yes") == "❯ 1. Yes")
        #expect("\u{1B}[32mgreen\u{1B}[0m".strippingANSI == "green")
        #expect(ANSI.strip("trailing \u{1B}") == "trailing ")
    }
}
