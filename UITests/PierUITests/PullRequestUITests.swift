import XCTest

/// Pull requests against the mock box (`-uiTestPRs 1`): open one from the Home widget, read it, open a file's diff, comment,
/// merge, and bring it into a worktree to continue with an agent.
final class PullRequestUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestPRs", "1", "-homeScrollTo", "prs", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 15), "home did not load")
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(_ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
    /// Swipes up until `e` can be tapped.
    private func reveal(_ e: XCUIElement, tries: Int = 8) {
        var n = 0
        while !(e.exists && e.isHittable), n < tries { app.swipeUp(); n += 1 }
    }

    private func openPR() {
        let row = element("pr-row-42")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no PR in the Home widget")
        shot("pr-home-widget")
        reveal(row)
        row.tap()
        XCTAssertTrue(element("pr-title").waitForExistence(timeout: 10), "PR screen did not open")
        XCTAssertTrue(element("pr-title").label.contains("Migrar a página de cobrança"))
    }

    func testOpenFromHomeReadAndDiff() {
        openPR()
        XCTAssertTrue(text("Migra a página de").waitForExistence(timeout: 5), "no description")
        XCTAssertTrue(text("feat/billing-api").exists, "no head branch")
        XCTAssertTrue(text("Trazer para uma worktree").exists)
        shot("pr-screen-top")
        let failing = text("test (billing)")
        reveal(failing)
        XCTAssertTrue(failing.exists, "no failing check")
        XCTAssertTrue(text("1 com falha").exists, "no checks summary")
        XCTAssertTrue(text("pediu mudanças").exists, "no review state")
        XCTAssertTrue(text("Aguardando: @joao-qa").exists, "no requested reviewer")
        shot("pr-screen-checks-reviews")
        let file = app.staticTexts["BillingPage.tsx"]
        reveal(file)
        XCTAssertTrue(file.exists, "no files")
        XCTAssertTrue(text("useBilling.ts").exists && text("legacyCache.ts").exists)
        shot("pr-screen-files")
        file.tap()
        XCTAssertTrue(app.navigationBars["BillingPage.tsx"].waitForExistence(timeout: 10), "diff did not open")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '@@'")).firstMatch.waitForExistence(timeout: 10), "no hunk in the diff")
        shot("pr-diff")
    }

    func testCommentThenMerge() {
        openPR()
        element("pr-more").tap()
        app.buttons["Comentar"].tap()
        let field = element("pr-review-text")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Testei no celular: o total bate. Falta só o teste do desconto.")
        shot("pr-comment-sheet")
        element("pr-review-send").tap()
        let publish = app.alerts.buttons["Publicar"]
        XCTAssertTrue(publish.waitForExistence(timeout: 5), "no confirmation")
        shot("pr-comment-confirm")
        publish.tap()
        XCTAssertTrue(text("Comentário publicado.").waitForExistence(timeout: 10), "no result banner")
        let posted = text("Falta só o teste do desconto")
        reveal(posted)
        XCTAssertTrue(posted.exists, "the comment is not in the conversation")
        shot("pr-comment-posted")

        element("pr-merge").tap()
        XCTAssertTrue(element("pr-merge-go").waitForExistence(timeout: 5))
        XCTAssertTrue(text("Um revisor pediu mudanças.").exists, "no warning before merging")
        shot("pr-merge-sheet")
        element("pr-merge-go").tap()
        let merge = app.alerts.buttons["Mesclar"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5), "no confirmation")
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS 'a branch feat/billing-api será apagada'")).firstMatch.exists)
        merge.tap()
        XCTAssertTrue(text("PR mesclado.").waitForExistence(timeout: 10), "no result banner")
        XCTAssertTrue(text("Mesclado").exists, "state did not change")
        XCTAssertFalse(element("pr-merge").exists, "merge still offered on a merged PR")
        shot("pr-merged")
    }

    func testBringToWorktreeAndStartAgent() {
        openPR()
        element("pr-bring").tap()
        let name = element("pr-worktree-name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "pr-42")
        XCTAssertTrue(text("um git push dali atualiza o PR").exists, "no push note")
        shot("pr-worktree-sheet")
        element("pr-worktree-create").tap()
        XCTAssertTrue(element("pr-worktree-ready").waitForExistence(timeout: 15), "worktree not created")
        let prompt = element("pr-agent-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let value = prompt.value as? String ?? ""
        XCTAssertTrue(value.contains("PR #42"), "prompt: \(value)")
        XCTAssertTrue(value.contains("Os revisores pediram mudanças:\n- @octocat: O total da fatura"), "prompt: \(value)")
        XCTAssertTrue(value.contains("`feat/billing-api`"), "prompt: \(value)")
        shot("pr-worktree-ready")
        let start = element("pr-agent-start")
        reveal(start)
        start.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 15), "session did not open")
        XCTAssertTrue(text("Vou trocar o arredondamento").waitForExistence(timeout: 15), "agent did not answer")
        shot("pr-agent-session")
    }
}
