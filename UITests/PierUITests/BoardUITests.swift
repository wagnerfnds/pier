import XCTest

/// The agents board (its own section, "Quadro") against the mock box with `-uiTestExtras 1`: one session per column (waiting,
/// running + a finished turn with background work, finished, idle, exited), filters, archiving by menu and by drag, and
/// opening a session from a card. Runs on iPhone (paged columns with a bar) and iPad (columns side by side).
/// Screenshots go to the xcresult and, with `TEST_RUNNER_KBD_SHOTS=<dir>`, to that folder as `board-*.png`.
final class BoardUITests: XCTestCase {
    var app: XCUIApplication!

    private let waiting = "sandbox-claude-w9q"
    private let running = "acme-web-claude-a1b"
    private let finished = "sandbox-subtract-claude-6s1"
    private let idle = "sandbox-mcp-claude-m1"
    private let background = "sandbox-verify-claude-b2"
    private let exited = "sandbox-old-claude-x3"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Archive and answers wait the undo window elsewhere (UndoAndTitleUITests): here they go out at once.
        app.launchArguments = ["-uiTestMock", "1", "-uiTestExtras", "1", "-undoSeconds", "0", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        // iPad: landscape, so the columns sit side by side (portrait pages two lanes at a time, like the iPhone).
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        app.launch()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 15), "home did not load")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func card(_ column: String, _ session: String) -> XCUIElement { element("board-card-\(column)-\(session)") }
    private var compact: Bool { element("board-tab-needsYou").exists }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(name)-\(device)"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("board-\(name)-\(device).png"))
        }
    }

    private func openBoard() {
        // Its sidebar row on iPad, its tab on iPhone.
        let row = element("sidebar-board")
        let button = row.exists ? row : app.buttons["Quadro"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Quadro section")
        button.tap()
        XCTAssertTrue(element("board-column-needsYou").waitForExistence(timeout: 10), "board did not open")
        // The background work arrives with the first signals read: wait until that card settled in Trabalhando.
        XCTAssertTrue(card("working", background).waitForExistence(timeout: 20), "the finished turn with background work is not in Trabalhando")
        // Archive marks live on the phone (prefs file) and outlive a launch: undo one a failed earlier run left behind.
        if !compact { shot("folded"); show("closed") }   // iPad: unfold Encerradas so its cards are there
        if card("closed", finished).exists {
            show("closed")
            let back = app.buttons["Voltar para “Sua vez”"].firstMatch
            if openMenu(card("closed", finished), until: back) { back.tap() }
            XCTAssertTrue(card("yourTurn", finished).waitForExistence(timeout: 5), "could not undo an archive left by an earlier run")
        }
    }

    /// Brings a column on screen (iPhone: its page via the bar; iPad: Encerradas unfolds).
    private func show(_ column: String) {
        if compact {
            element("board-tab-\(column)").tap()
            sleep(1)
        } else if column == "closed", !element("board-empty-closed").exists, !card("closed", exited).exists {
            element("board-column-closed").tap()
            sleep(1)
        }
    }

    /// Where a card is dropped to land in `column`: the bar's chip on iPhone, the column itself on iPad.
    private func dropTarget(_ column: String) -> XCUIElement {
        compact ? element("board-tab-\(column)") : element("board-column-\(column)")
    }

    /// Long-presses a card until its context menu shows `item` (a busy simulator sometimes turns the first press into a lift).
    private func openMenu(_ card: XCUIElement, until item: XCUIElement) -> Bool {
        for _ in 0..<3 {
            card.press(forDuration: 1.2)
            if item.waitForExistence(timeout: 6) { return true }
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()   // dismiss whatever opened
            sleep(1)
        }
        return false
    }

    private func drag(_ from: XCUIElement, to: XCUIElement) {
        from.press(forDuration: 0.8, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.6)
    }

    func testColumnsHoldTheRightCards() {
        openBoard()
        XCTAssertTrue(card("needsYou", waiting).exists, "waiting agent not in Precisa de você")
        XCTAssertTrue(card("working", running).exists, "running agent not in Trabalhando")
        XCTAssertTrue(card("yourTurn", finished).exists, "finished turn not in Sua vez")
        XCTAssertTrue(card("ready", idle).exists, "idle agent not in Pronto")
        // No card shows up twice.
        XCTAssertFalse(card("yourTurn", background).exists, "background work also listed in Sua vez")
        XCTAssertFalse(card("needsYou", running).exists)
        // The ask, the background line and the last reply are on the cards.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'mkdir probe_dir'")).firstMatch.exists, "the ask is not on the card")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Em segundo plano'")).firstMatch.exists, "no background line")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Nothing was committed yet'")).firstMatch.waitForExistence(timeout: 10),
                      "the last reply is not on the Sua vez card")
        shot("columns")
        if compact {
            show("working"); shot("working")
            show("yourTurn"); shot("your-turn")
            show("ready"); shot("ready")
        }
        show("closed")
        XCTAssertTrue(card("closed", exited).waitForExistence(timeout: 5), "exited session not in Encerradas")
        shot("closed")
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Portrait iPad: two lanes per page with the bar on top.
            XCUIDevice.shared.orientation = .portrait
            sleep(2)
            XCTAssertTrue(element("board-tab-needsYou").waitForExistence(timeout: 5), "portrait iPad does not page the lanes")
            show("yourTurn")
            XCTAssertTrue(card("yourTurn", finished).exists)
            shot("portrait")
        }
    }

    func testFiltersAndSearch() {
        openBoard()
        element("board-filter").tap()
        let project = app.buttons["Projeto"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5), "no project filter")
        project.tap()
        let rv3 = app.buttons["acme-web"].firstMatch
        XCTAssertTrue(rv3.waitForExistence(timeout: 5), "acme-web not in the project filter")
        rv3.tap()
        XCTAssertTrue(card("needsYou", waiting).waitForNonExistence(timeout: 5), "the project filter did not hide sandbox")
        shot("filter-project")
        XCTAssertTrue(card("working", running).waitForExistence(timeout: 5), "the filtered project's card is gone")
        XCTAssertTrue(element("board-empty-needsYou").exists, "no empty state in a filtered column")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'acme-web'")).firstMatch.tap()   // the chip clears it
        XCTAssertTrue(card("needsYou", waiting).waitForExistence(timeout: 5), "clearing the filter did not bring sandbox back")

        // The board's own field, by its prompt: on iPad the sidebar has a search field too (and it comes first).
        let search = app.searchFields.matching(NSPredicate(format: "placeholderValue == 'Buscar agentes'")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no Buscar agentes field on the board")
        search.tap()
        search.typeText("subtract")
        XCTAssertTrue(card("needsYou", waiting).waitForNonExistence(timeout: 5), "search did not filter")
        XCTAssertTrue(card("yourTurn", finished).exists, "search hid the match")
        XCTAssertFalse(card("working", running).exists)
        shot("search")
    }

    func testArchiveByMenuAndBack() {
        openBoard()
        show("yourTurn")
        let c = card("yourTurn", finished)
        XCTAssertTrue(c.waitForExistence(timeout: 5))
        let archive = app.buttons["Arquivar (terminei aqui)"].firstMatch
        XCTAssertTrue(openMenu(c, until: archive), "no archive in the card's menu")
        shot("menu")
        archive.tap()
        // Checked where it lands: the context menu's lifted copy of the card (same identifier) can linger in the
        // simulator while its dismissal settles, so "gone from Sua vez" is not a reliable signal.
        show("closed")
        let closed = card("closed", finished)
        XCTAssertTrue(closed.waitForExistence(timeout: 10), "archived card not in Encerradas")
        shot("archived")
        let back = app.buttons["Voltar para “Sua vez”"].firstMatch
        XCTAssertTrue(openMenu(closed, until: back), "no way back in the archived card's menu")
        back.tap()
        XCTAssertTrue(card("yourTurn", finished).waitForExistence(timeout: 5), "card did not come back to Sua vez")
    }

    func testArchiveByDragAndBack() {
        openBoard()
        show("yourTurn")
        let c = card("yourTurn", finished)
        XCTAssertTrue(c.waitForExistence(timeout: 5))
        drag(c, to: dropTarget("closed"))
        XCTAssertTrue(card("closed", finished).waitForExistence(timeout: 5), "dragging to Encerradas did not archive")
        XCTAssertFalse(card("yourTurn", finished).exists)
        show("closed")
        shot("dragged")
        drag(card("closed", finished), to: dropTarget("yourTurn"))
        XCTAssertTrue(card("yourTurn", finished).waitForExistence(timeout: 5), "dragging back did not un-archive")
        // A drop between active columns means nothing: the running agent stays where it is.
        show("working")
        drag(card("working", running), to: dropTarget("closed"))
        XCTAssertTrue(card("working", running).waitForExistence(timeout: 3))
        XCTAssertFalse(card("closed", running).exists, "a running agent was archived")
    }

    func testCardOpensTheSession() {
        openBoard()
        show("yourTurn")
        let c = card("yourTurn", finished)
        XCTAssertTrue(c.waitForExistence(timeout: 5))
        c.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "the card did not open the session")
        shot("opened")
    }
}
