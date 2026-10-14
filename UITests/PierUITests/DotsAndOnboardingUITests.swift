import XCTest

/// Status dots (the Home), the 3-step onboarding and "Levar para o iPhone", against the mock box.
/// Runs on iPhone and iPad; the ⌥ labels test needs the iPad sidebar (skipped on compact width).
final class DotsAndOnboardingUITests: XCTestCase {
    var app: XCUIApplication!

    static let waiting = "sandbox-claude-w9q"
    static let running = "acme-web-claude-a1b"
    static let finished = "sandbox-subtract-claude-6s1"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func dot(_ session: String) -> XCUIElement { app.buttons.matching(identifier: "agent-dot-\(session)").firstMatch }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("dots-\(idiom)-\(name).png"))
        }
    }

    // MARK: dots

    func testDotsShowStatesInOrderAndOpenTheSession() {
        app.launch()
        XCTAssertTrue(dot(Self.waiting).waitForExistence(timeout: 15), "no dot for the waiting agent")
        XCTAssertTrue(dot(Self.running).exists && dot(Self.finished).exists, "a live agent has no dot")
        // One dot per live agent: the mock has three (an exited or archived one has none).
        let all = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agent-dot-'"))
        // One strip on screen: the Home's (the sidebar lists the live work under "Trabalhando" instead).
        XCTAssertEqual(all.count, 3, "expected one strip with a dot per live agent")
        // Colors as states: amber needs you, blue working, green your turn.
        XCTAssertTrue((dot(Self.waiting).value as? String)?.hasPrefix("Precisa de você") == true)
        XCTAssertTrue((dot(Self.running).value as? String)?.hasPrefix("Trabalhando") == true)
        XCTAssertTrue((dot(Self.finished).value as? String)?.hasPrefix("Sua vez") == true)
        // Needs-you first, then working, then your turn.
        XCTAssertLessThan(dot(Self.waiting).frame.minX, dot(Self.running).frame.minX)
        XCTAssertLessThan(dot(Self.running).frame.minX, dot(Self.finished).frame.minX)
        XCTAssertTrue(element("agent-dots-summary").label.contains("1 precisa de você"))
        shot("home")

        dot(Self.waiting).tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "the dot did not open its session")
        XCTAssertTrue(element("needs-you-card").waitForExistence(timeout: 10), "opened the wrong session")
        shot("opened")
    }

    func testLongPressShowsLabels() {
        app.launch()
        let strip = element("agent-dots")
        XCTAssertTrue(dot(Self.waiting).waitForExistence(timeout: 15))
        strip.press(forDuration: 0.8)
        let label = element("agent-label-\(Self.waiting)")
        XCTAssertTrue(label.waitForExistence(timeout: 3), "a long press did not show the labels")
        XCTAssertTrue(label.label.contains("Create a probe directory"), "the label has no title: \(label.label)")
        XCTAssertTrue((label.value as? String)?.contains("sandbox") == true, "the label has no project")
        shot("labels")
        label.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "a label did not open its session")
    }

    /// iPad hardware keyboard: ⌥ reaches the dots' key watcher, and once it is let go the labels are hidden again. The
    /// simulator cannot hold a modifier for XCUITest (`perform(withKeyModifiers:)` times out), so ⌥ is pressed and released
    /// and a Debug marker says the app saw it held; a key pressed without ⌥ then counts as letting it go.
    func testOptionKeyReachesTheDots() throws {
        app.launch()
        XCTAssertTrue(dot(Self.waiting).waitForExistence(timeout: 15))
        guard element("sidebar-home").exists else { throw XCTSkip("⌥ labels are checked on the iPad (regular width)") }
        app.typeKey("a", modifierFlags: .option)   // a bare ⌥ is not synthesized by XCUITest
        XCTAssertTrue(element("agent-dots-option-seen").waitForExistence(timeout: 3), "the app never saw ⌥ held")
        // The iOS 27 simulator releases ⌥ right after its key: the labels show and go before a query can see them, so a
        // Debug marker says they were drawn.
        XCTAssertTrue(element("agent-label-\(Self.running)").waitForExistence(timeout: 3) || element("agent-dots-labels-seen").exists,
                      "⌥ held did not show the labels")
        // The simulator sends ⌥ only as a flag on the key, never its own release: a key without ⌥ stands in for letting go.
        app.typeKey("b", modifierFlags: [])
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element("agent-label-\(Self.running)"))
        wait(for: [gone], timeout: 3)
        XCTAssertTrue(dot(Self.running).exists)
    }

    // MARK: onboarding

    func testOnboardingStepsGoForwardAndBackAndPair() {
        app.launchArguments += ["-uiTestOnboarding", "1"]
        app.launch()
        XCTAssertTrue(element("onboarding-step-1").waitForExistence(timeout: 10), "the onboarding did not open on step 1")
        XCTAssertTrue(app.staticTexts["Oi, é o Pier"].exists)
        shot("onboarding-1")
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(element("onboarding-step-2").waitForExistence(timeout: 3), "Começar did not go to step 2")
        XCTAssertTrue(app.staticTexts["Como funciona"].exists)
        XCTAssertTrue(app.staticTexts["Sua box roda os agentes"].exists)
        shot("onboarding-2")
        app.buttons["onboarding-back"].tap()
        XCTAssertTrue(element("onboarding-step-1").waitForExistence(timeout: 3), "Voltar did not go back to step 1")
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(element("onboarding-step-2").waitForExistence(timeout: 3))
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(element("onboarding-step-3").waitForExistence(timeout: 3), "Continuar did not reach pairing")
        // On a phone the agents run on "my Mac" first: the code its "Levar para o iPhone" shows.
        XCTAssertTrue(app.buttons["onboarding-scan"].exists, "no QR scanner on the iPhone/iPad")
        XCTAssertFalse(app.buttons["onboarding-install-help"].exists)
        shot("onboarding-3")
        // On a server: the one command to run there, a copy away, then its QR code.
        app.segmentedControls["onboarding-place"].buttons["Num servidor"].tap()
        let copyCommand = app.buttons["command-copy"]
        XCTAssertTrue(copyCommand.waitForExistence(timeout: 3), "the server's command has no Copiar")
        copyCommand.tap()
        let end = Date().addingTimeInterval(3)
        while Date() < end, (copyCommand.value as? String)?.contains("install.sh | sh") != true { usleep(250_000) }
        XCTAssertTrue((copyCommand.value as? String)?.contains("install.sh | sh") == true, "the install command was not copied")
        XCTAssertTrue(app.buttons["onboarding-scan"].exists, "no QR scanner for the server")
        XCTAssertTrue(app.buttons["onboarding-install-help"].exists, "no other ways to install")
        shot("onboarding-3-server")

        app.buttons["onboarding-paste"].tap()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no paste sheet")
        field.tap()
        field.typeText("pier://192.0.2.10:7444?code=\(String(repeating: "a", count: 52))&fp=\(String(repeating: "a", count: 52))")
        app.buttons["Parear"].tap()

        let done = element("onboarding-done").waitForExistence(timeout: 10)
        if !done { shot("onboarding-pair-failed") }
        XCTAssertTrue(done, "pairing did not end on Tudo pronto")
        XCTAssertTrue(app.staticTexts["Tudo pronto!"].exists)
        let checklist = element("onboarding-checklist")
        XCTAssertTrue(checklist.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Box devbox conectada'")).firstMatch.exists,
                      "the checklist does not list the box")
        XCTAssertTrue(element("onboarding-first-task").exists)
        shot("onboarding-done")
        app.buttons["onboarding-finish"].tap()
        XCTAssertTrue(dot(Self.waiting).waitForExistence(timeout: 10), "Ir para o início did not show the Home")
    }

    /// "Outros jeitos de instalar": the prompt for the agent on the server, and the commands (the installer, npm, Homebrew),
    /// each a copy away.
    func testInstallHelpOffersThePromptAndTheCommands() {
        app.launchArguments += ["-uiTestOnboarding", "1"]
        app.launch()
        XCTAssertTrue(element("onboarding-step-1").waitForExistence(timeout: 10))
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(element("onboarding-step-2").waitForExistence(timeout: 3))
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(element("onboarding-step-3").waitForExistence(timeout: 3))
        app.segmentedControls["onboarding-place"].buttons["Num servidor"].tap()
        app.buttons["onboarding-install-help"].tap()
        XCTAssertTrue(element("install-help-prompt").waitForExistence(timeout: 5), "the help sheet did not open")
        XCTAssertTrue(app.staticTexts["Peça ao seu agente"].exists)
        XCTAssertTrue(element("install-help-prompt").label.contains("install.sh | sh"), "the prompt does not run the installer")
        XCTAssertTrue(app.staticTexts["npm install -g pierd && pierd setup"].exists, "no npm command")
        XCTAssertTrue(app.staticTexts["brew install wagnerfnds/tap/pierd && pierd setup"].exists, "no Homebrew command")
        shot("install-help")
        let copy = app.buttons["install-help-copy-prompt"]
        copy.tap()
        // The button says so, and carries what it copied (the test runner may not read the clipboard).
        XCTAssertTrue(app.staticTexts["Copiado"].waitForExistence(timeout: 3))
        let end = Date().addingTimeInterval(3)
        while Date() < end, (copy.value as? String)?.contains("install.sh | sh") != true { usleep(250_000) }
        XCTAssertTrue((copy.value as? String)?.contains("install.sh | sh") == true, "the prompt was not copied")
        app.buttons["Fechar"].tap()
        XCTAssertTrue(element("onboarding-step-3").waitForExistence(timeout: 3), "closing the help did not return to pairing")
    }

    // MARK: demo

    /// "Explorar com dados de exemplo" from a fresh onboarding. No mock: the app's own start, as in a Release build.
    private func enterDemo() {
        app.launchArguments = ["-uiTestDemoReset", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        let demo = element("onboarding-demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 15), "the onboarding offers no demo")
        // The launch animation is still scaling the window up when the button exists: a tap then lands on Começar.
        // Tap once the button stays where it is.
        var last = CGRect.null
        let settle = Date().addingTimeInterval(5)
        while Date() < settle { let f = demo.frame; if f == last { break }; last = f; usleep(300_000) }
        shot("demo-offer")
        demo.tap()
        XCTAssertTrue(element("home-demo-banner").waitForExistence(timeout: 15), "the demo's Home has no banner")
    }

    private func bubble(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(identifier == 'outgoing-message' OR identifier == 'user-message') AND label CONTAINS %@", s)).firstMatch
    }

    private func words(_ s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    /// No box yet: "Explorar com dados de exemplo" opens the demo's made-up box (the showcase's projects and agents), it
    /// comes back after a relaunch, and leaving it in Ajustes brings the onboarding back.
    func testDemoFromTheOnboarding() {
        enterDemo()
        let stripe = "storefront-stripe-checkout-claude-7f2a"
        XCTAssertTrue(app.buttons.matching(identifier: "agent-dot-\(stripe)").firstMatch.waitForExistence(timeout: 15),
                      "the demo box's agents are not on the Home")
        shot("demo-home")

        // Still the demo after a relaunch.
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(element("home-demo-banner").waitForExistence(timeout: 15), "the demo did not come back after a relaunch")

        // The banner's button leaves it: the onboarding again.
        element("home-leave-demo").tap()
        XCTAssertTrue(element("onboarding-demo").waitForExistence(timeout: 15), "leaving the demo did not bring the onboarding back")
        XCTAssertFalse(element("home-demo-banner").exists)
    }

    /// What is said in the demo lands after its conversation: the agent's reply after Permitir (a key in the menu, as
    /// on pierd, not a "1" in the conversation), then a message and its answer, each below the one before. Before, they
    /// landed above everything: the showcase's record starts at offsets far above the ones the demo's box hands out,
    /// and the app orders a record by offset.
    func testDemoRepliesLandAfterTheConversation() {
        enterDemo()
        dot("storefront-stripe-checkout-claude-7f2a").tap()
        let allow = element("needs-allow")
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "the demo's permission card did not show")
        let request = bubble(containing: "checkout do Stripe")
        XCTAssertTrue(request.exists, "the demo's conversation is not shown")
        allow.tap()
        let reply = words("Instalei o")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "no reply after Permitir")
        XCTAssertGreaterThan(reply.frame.minY, request.frame.maxY, "the reply after Permitir landed above the conversation")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
            format: "(identifier == 'outgoing-message' OR identifier == 'user-message') AND label ENDSWITH ': 1'")).firstMatch.exists,
                       "Permitir showed up as a message")

        let field = element("composer-field")
        field.tap()
        field.typeText("E os testes?")
        element("composer-send").tap()
        let mine = bubble(containing: "E os testes?")
        XCTAssertTrue(mine.waitForExistence(timeout: 2), "the message is not in the conversation")
        let answer = words("Isto é a demonstração")
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the demo's agent did not answer")
        XCTAssertGreaterThan(mine.frame.minY, reply.frame.maxY, "the message landed above the reply")
        XCTAssertGreaterThan(answer.frame.minY, mine.frame.maxY, "the answer landed above the message")
        shot("demo-replies-in-order")
    }

    // MARK: Levar para o iPhone

    func testInviteShowsAQRCode() {
        app.launchArguments += ["-startTab", "settings"]
        app.launch()
        let entry = element("settings-invite-device")
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Ajustes has no invite entry")
        entry.tap()
        XCTAssertTrue(element("invite-qr").waitForExistence(timeout: 10), "no QR code")
        XCTAssertTrue(element("invite-link").label.hasPrefix("pier://"), "no pier:// link under the code")
        shot("invite")
    }

    func testInviteFallbackWhenTheBoxHasNoRoute() {
        app.launchArguments += ["-startTab", "settings", "-openInvite", "1", "-uiTestNoInvite", "1"]
        app.launch()
        XCTAssertTrue(element("invite-unsupported").waitForExistence(timeout: 15), "no fallback for a box without invites")
        XCTAssertFalse(element("invite-qr").exists)
        shot("invite-unsupported")
    }
}
