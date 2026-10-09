import XCTest

/// Against a real paired box (skipped unless `TEST_RUNNER_REAL_SESSION` names a session on it; pair the simulator first):
/// answers the session's Claude startup dialog with the card's button, then measures how long a reply takes to show up.
/// Timings go to `TEST_RUNNER_REAL_OUT/real-timings.txt`.
final class RealBoxUITests: XCTestCase {
    func testRealDialogAndChatLatency() throws {
        let env = ProcessInfo.processInfo.environment
        guard let session = env["REAL_SESSION"], !session.isEmpty else { throw XCTSkip("REAL_SESSION not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-openSession", session, "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "composer-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "session did not open")

        if let option = env["REAL_OPTION"] {
            let button = app.buttons[option].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 20), "dialog option '\(option)' is not a button")
            button.tap()
            let card = app.descendants(matching: .any).matching(identifier: "needs-you-card").firstMatch
            XCTAssertTrue(card.waitForNonExistence(timeout: 15), "the card stayed after answering the real dialog")
        }

        // Chat latency: ask for a number nobody typed, wait for it in the reply.
        let n = Int.random(in: 1000...8999)
        let prompt = "Responda apenas com o resultado de \(n) + 1111, sem mais nada."
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "keyboard did not come up")
        sleep(1)
        field.typeText(prompt)
        sleep(1)
        let typed = field.value as? String ?? ""
        let v = XCTAttachment(string: "field_after_typing=\(typed)"); v.name = "field-value"; v.lifetime = .keepAlways; add(v)
        XCTAssertEqual(typed, prompt, "the composer lost text while typing")
        let t0 = Date()
        app.descendants(matching: .any).matching(identifier: "composer-send").firstMatch.tap()
        let want = String(n + 1111)
        let reply = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label CONTAINS %@", want, " \(want)")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "the reply \(want) never showed up")
        let t1 = Date()
        let line = "answer=\(want) sent=\(t0.timeIntervalSince1970) shown=\(t1.timeIntervalSince1970) total=\(t1.timeIntervalSince(t0))\n"
        if let dir = env["REAL_OUT"] {
            try? line.write(toFile: dir + "/real-timings.txt", atomically: true, encoding: .utf8)
        }
        let timing = XCTAttachment(string: line); timing.name = "chat-latency"; timing.lifetime = .keepAlways; add(timing)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "real-chat"; a.lifetime = .keepAlways; add(a)
        if let dir = env["REAL_OUT"] { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/real-chat.png")) }
    }

    /// Revisar -> Aprovar on the real box: the commit message must come from the box's Haiku (not the session title).
    /// Cancels without committing.
    func testRealApproveDraft() throws {
        let env = ProcessInfo.processInfo.environment
        guard let session = env["REAL_SESSION"], !session.isEmpty, env["REAL_REVIEW"] != nil else { throw XCTSkip("REAL_REVIEW not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-openSession", session, "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer-field").firstMatch.waitForExistence(timeout: 30))
        sleep(3)
        let revisar = app.buttons["Revisar"].firstMatch
        if revisar.exists { revisar.tap() } else { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.855)).tap() }
        let approve = app.buttons["Aprovar"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 15), "no Aprovar")
        for _ in 0..<20 where !approve.isEnabled { sleep(1) }
        let t0 = Date()
        approve.tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Texto escrito pela IA'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 120), "the AI draft did not arrive")
        let took = Date().timeIntervalSince(t0)
        let message = app.textViews.firstMatch.value as? String ?? ""
        XCTAssertFalse(message.hasPrefix("Teste real do diálogo de MCP"), "still the session title: \(message)")
        let d = XCTAttachment(string: "draft_seconds=\(took)\n\(message)"); d.name = "ai-draft"; d.lifetime = .keepAlways; add(d)
        let shotD = XCTAttachment(screenshot: app.screenshot()); shotD.name = "ai-draft-screen"; shotD.lifetime = .keepAlways; add(shotD)
        if let dir = env["REAL_OUT"] {
            try? "draft_seconds=\(took)\n\(message)\n".write(toFile: dir + "/real-draft.txt", atomically: true, encoding: .utf8)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/real-draft.png"))
        }
        app.buttons["Cancelar"].tap()
    }

    /// Grants notification permission through the app (Ajustes -> Permitir notificações), so a push can be shown.
    func testGrantNotifications() throws {
        guard ProcessInfo.processInfo.environment["REAL_NOTIF"] != nil else { throw XCTSkip("REAL_NOTIF not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        app.buttons["Ajustes"].firstMatch.tap()
        let ask = app.buttons["Permitir notificações"].firstMatch
        var tries = 0
        while !ask.exists, tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "no Permitir notificações")
        ask.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN {'Allow', 'Permitir'}")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "no system permission alert")
        allow.tap()
        XCUIDevice.shared.press(.home)
    }

    /// The Home with real sessions (Sua vez vs Trabalhando agora / em segundo plano), as a screenshot attachment.
    func testRealHome() throws {
        guard ProcessInfo.processInfo.environment["REAL_HOME"] != nil else { throw XCTSkip("REAL_HOME not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Sua vez"].waitForExistence(timeout: 30))
        sleep(20)   // background signals refresh every 15 s
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "home"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Em segundo plano'")).firstMatch.exists,
                      "the session with background work is not shown as working")
    }

    /// Leaves the app in the background and waits for a real push banner (a session finishing on the box meanwhile);
    /// attaches the screen with the banner, so its icon can be checked, and counts banners for that session.
    func testRealNotificationBanner() throws {
        guard let title = ProcessInfo.processInfo.environment["REAL_NOTIFY"] else { throw XCTSkip("REAL_NOTIFY not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        sleep(6)                      // registers with the box for push
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 150), "no notification banner for '\(title)'")
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "banner"; a.lifetime = .keepAlways; add(a)
        sleep(8)
        // Notification Center: the notification stays there with its icon.
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.005))
        top.press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6)))
        sleep(2)
        let nc = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); nc.name = "notification-center"; nc.lifetime = .keepAlways; add(nc)
        let count = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).count
        let c = XCTAttachment(string: "banners_for_title=\(count)"); c.name = "banner-count"; c.lifetime = .keepAlways; add(c)
        let b = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); b.name = "banner-after"; b.lifetime = .keepAlways; add(b)
    }

    /// Opens Notification Center from the Home Screen and attaches it (notifications already delivered, with their icons).
    func testRealNotificationCenter() throws {
        guard ProcessInfo.processInfo.environment["REAL_NC"] != nil else { throw XCTSkip("REAL_NC not set") }
        XCUIDevice.shared.press(.home)
        sleep(1)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.005))
            .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6)))
        sleep(2)
        let nc = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); nc.name = "notification-center"; nc.lifetime = .keepAlways; add(nc)
    }

    /// Ends a real session with "Encerrar e limpar" (REAL_END = session name) and attaches the sheet and the result.
    func testRealEndSessionCleanup() throws {
        guard let session = ProcessInfo.processInfo.environment["REAL_END"] else { throw XCTSkip("REAL_END not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-openSession", session, "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer-field").firstMatch.waitForExistence(timeout: 30))
        app.buttons["Mais ações"].tap()
        app.buttons["Encerrar sessão"].tap()
        let run = app.descendants(matching: .any).matching(identifier: "end-session-run").firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 15))
        sleep(2)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "end-sheet"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(run.isEnabled, "cleanup is blocked (work not sent?)")
        run.tap()
        let done = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'serviços parados'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60), "no cleanup confirmation")
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "end-done"; b.lifetime = .keepAlways; add(b)
        let t = XCTAttachment(string: done.label); t.name = "end-toast"; t.lifetime = .keepAlways; add(t)
    }

    /// Opens the Faxina on the real box and attaches the plan (does not run it).
    func testRealFaxinaPlan() throws {
        guard ProcessInfo.processInfo.environment["REAL_FAXINA_PLAN"] != nil else { throw XCTSkip("REAL_FAXINA_PLAN not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        app.buttons["Projetos"].firstMatch.tap()
        app.buttons["Faxina"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "housekeeping-run").firstMatch.waitForExistence(timeout: 30))
        sleep(4)
        for i in 0..<3 {
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = "faxina-plan-\(i)"; a.lifetime = .keepAlways; add(a)
            app.swipeUp()
        }
    }

    /// Read-only look at a real PR (REAL_PR = owner/name#123) and the real board: screenshots only, no action is taken.
    func testRealPRAndBoardReadOnly() throws {
        guard let pr = ProcessInfo.processInfo.environment["REAL_PR"] else { throw XCTSkip("REAL_PR not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-openPR", pr, "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        let desc = app.staticTexts["DESCRIÇÃO"].exists ? app.staticTexts["DESCRIÇÃO"] : app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Descrição'")).firstMatch
        XCTAssertTrue(desc.waitForExistence(timeout: 40), "the PR did not load")
        sleep(2)
        func shot(_ n: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }
        shot("real-pr-top")
        app.swipeUp(); sleep(1); shot("real-pr-middle")
        app.swipeUp(); app.swipeUp(); sleep(1); shot("real-pr-files")
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS '.php' OR label CONTAINS '.ts' OR label CONTAINS '.vue' OR label CONTAINS '.md'")).firstMatch
        if file.waitForExistence(timeout: 5) {
            file.tap()
            sleep(8)
            shot("real-pr-diff")
        }
        app.terminate()
        app.launchArguments = ["-openBoard", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        sleep(20)
        shot("real-board")
    }
}
