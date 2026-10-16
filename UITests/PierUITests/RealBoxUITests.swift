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

    /// A real open question with several steps (skipped unless `TEST_RUNNER_REAL_FORM` names a session on the paired box
    /// waiting at one, and `TEST_RUNNER_REAL_PICKS` lists the options to tap, `|`-separated): the chat's card shows the
    /// whole form (Claude Code records the call only once answered), the picks go out with Enviar resposta, and the
    /// agent's reply names them.
    func testRealQuestionForm() throws {
        let env = ProcessInfo.processInfo.environment
        guard let session = env["REAL_FORM"], !session.isEmpty, let picks = env["REAL_PICKS"]?.split(separator: "|").map(String.init),
              !picks.isEmpty else { throw XCTSkip("REAL_FORM / REAL_PICKS not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-openSession", session, "-undoSeconds", "0", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        let card = app.descendants(matching: .any).matching(identifier: "needs-you-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 40), "no card for the real question")
        let shot = { (name: String) in
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; self.add(a)
            if let dir = env["REAL_OUT"] { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/\(name).png")) }
        }
        shot("real-form")
        for p in picks {
            let b = card.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", p)).firstMatch
            XCTAssertTrue(b.waitForExistence(timeout: 10), "option '\(p)' is not on the card")
            var tries = 0
            while !b.isHittable, tries < 4 { card.swipeUp(); tries += 1 }
            b.tap()
        }
        let send = card.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Enviar resposta")).firstMatch
        var tries = 0
        while !(send.exists && send.isHittable), tries < 4 { card.swipeUp(); tries += 1 }
        XCTAssertTrue(send.isEnabled, "the form is complete but cannot be sent")
        shot("real-form-picked")
        send.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 30), "the card stayed after answering the real question")
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", picks[0])).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60), "the agent's reply never named the answer")
        sleep(2)
        shot("real-form-answered")
    }

    /// A real push opens the chat at its question (skipped unless `TEST_RUNNER_REAL_PUSH` holds words of a question the
    /// paired box will ask within a few minutes, and `TEST_RUNNER_REAL_PICKS` the options to tap): the app goes to the
    /// background, the "Needs you" notification arrives (banner or Notification Center), a tap on it opens the session
    /// with the whole form on its card, and the answers reach the agent.
    func testRealNotificationOpensTheForm() throws {
        let env = ProcessInfo.processInfo.environment
        guard let words = env["REAL_PUSH"], !words.isEmpty, let picks = env["REAL_PICKS"]?.split(separator: "|").map(String.init),
              !picks.isEmpty else { throw XCTSkip("REAL_PUSH / REAL_PICKS not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-undoSeconds", "0", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        sleep(4)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let shot = { (name: String, of: XCUIApplication) in
            let a = XCTAttachment(screenshot: of.screenshot()); a.name = name; a.lifetime = .keepAlways; self.add(a)
        }
        var note = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
        if !note.waitForExistence(timeout: 300) {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.01))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
            note = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
            XCTAssertTrue(note.waitForExistence(timeout: 10), "the push never arrived")
        }
        shot("real-push", springboard)
        note.tap()
        let card = app.descendants(matching: .any).matching(identifier: "needs-you-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 40), "the notification opened no card")
        shot("real-push-opened", app)
        for p in picks {
            let b = card.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", p)).firstMatch
            XCTAssertTrue(b.waitForExistence(timeout: 10), "option '\(p)' is not on the card")
            var tries = 0
            while !b.isHittable, tries < 4 { card.swipeUp(); tries += 1 }
            b.tap()
        }
        let send = card.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Enviar resposta")).firstMatch
        var tries = 0
        while !(send.exists && send.isHittable), tries < 4 { card.swipeUp(); tries += 1 }
        send.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 30), "the card stayed after answering")
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", picks[0])).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60), "the agent's reply never named the answer")
        shot("real-push-answered", app)
    }

    /// A real shell through pierd's terminal stream (skipped unless `TEST_RUNNER_REAL_TERMINAL` names a shell session on
    /// the paired box, as `<box>/<session>`): a line typed runs, ⌃C from the keyboard stops `sleep`, and the shell answers
    /// the next line. The screen is the terminal's accessibility value.
    func testRealLiveTerminal() throws {
        let env = ProcessInfo.processInfo.environment
        guard let session = env["REAL_TERMINAL"], !session.isEmpty else { throw XCTSkip("REAL_TERMINAL not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-openSession", session, "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        let term = app.descendants(matching: .any).matching(identifier: "live-terminal").firstMatch
        XCTAssertTrue(term.waitForExistence(timeout: 30), "the live terminal did not open")
        func waitFor(_ text: String, _ timeout: TimeInterval = 10) -> Bool {
            let found = NSPredicate { _, _ in (term.value as? String)?.contains(text) == true }
            return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: found, object: nil)], timeout: timeout) == .completed
        }
        term.tap()
        sleep(1)
        let n = Int.random(in: 100...899)
        app.typeText("echo pier-$((\(n)+1))\n")
        XCTAssertTrue(waitFor("pier-\(n + 1)"), "the line's answer never showed: \(term.value as? String ?? "")")
        app.typeText("sleep 30\n")
        sleep(1)
        let t0 = Date()
        app.typeKey("c", modifierFlags: .control)
        // The answer differs from the line typed: only the shell, back at its prompt, prints it.
        app.typeText("echo after-$((\(n)+2))\n")
        XCTAssertTrue(waitFor("after-\(n + 2)"), "⌃C did not stop sleep: \(term.value as? String ?? "")")
        let line = "ctrl-c-and-echo=\(Date().timeIntervalSince(t0))\n"
        let timing = XCTAttachment(string: line); timing.name = "terminal-latency"; timing.lifetime = .keepAlways; add(timing)
        if let dir = env["REAL_OUT"] {
            try? line.write(toFile: dir + "/real-terminal.txt", atomically: true, encoding: .utf8)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/real-terminal.png"))
        }
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
