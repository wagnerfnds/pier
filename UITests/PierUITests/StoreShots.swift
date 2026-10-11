import XCTest

/// The App Store's screenshots, raw: the app's screens against the mock box's showcase dataset (`-uiTestShowcase 1`),
/// the iPhone upright and the iPad on its side, saved as `<device>-<n>-<screen>.png` for the framing script to put under
/// their captions. Skipped unless `TEST_RUNNER_STORE_SHOTS=<dir>` names a folder; `TEST_RUNNER_STORE_LANG=pt-BR` shoots in
/// Brazilian Portuguese (the dataset follows). Not a test of behaviour: a screen that does not show is just missing.
final class StoreShots: XCTestCase {
    private var dir: URL!
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var portuguese: Bool { ProcessInfo.processInfo.environment["STORE_LANG"]?.lowercased().hasPrefix("pt") ?? false }

    private let question = "storefront-pricing-page-claude-c41e"
    private let finished = "billing-api-webhook-retries-claude-9b1d"

    override func setUpWithError() throws {
        guard let d = ProcessInfo.processInfo.environment["STORE_SHOTS"], !d.isEmpty else { throw XCTSkip("STORE_SHOTS not set") }
        dir = URL(fileURLWithPath: d)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        continueAfterFailure = true
        XCUIDevice.shared.orientation = pad ? .landscapeLeft : .portrait
    }

    private func launch(_ extra: [String], appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestShowcase", "1", "-appearance", appearance,
                               "-AppleLanguages", portuguese ? "(pt-BR)" : "(en)", "-AppleLocale", portuguese ? "pt_BR" : "en_US"] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func save(_ name: String) {
        let device = pad ? "ipad" : "iphone"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(device)-\(name).png"))
    }

    /// The Home: who needs you, who is working, pull requests, CI and git activity.
    func test1Home() {
        let app = launch([])
        _ = element(app, "agent-dots").waitForExistence(timeout: 20)
        sleep(pad ? 12 : 8)   // the remote cards (pull requests, CI, git) arrive a few seconds after the sessions
        save("1-home")
        app.terminate()
    }

    /// A session waiting on a question: the conversation, and the choices as buttons.
    func test2Question() {
        let app = launch(["-openSession", question])
        _ = element(app, "needs-you-card").waitForExistence(timeout: 20)
        sleep(4)
        save("2-question")
        app.terminate()
    }

    /// The Inbox: every agent's questions and finished work in one list.
    func test3Inbox() {
        let app = launch(["-startTab", "inbox"])
        sleep(10)
        save("3-inbox")
        app.terminate()
    }

    /// The workspace on the iPad (files, the editor); on the iPhone a finished turn: its diff and the next steps.
    func test4Workspace() {
        let app: XCUIApplication
        if pad {
            app = launch(["-openProject", "storefront", "-workspaceTab", "files", "-openFile", "src/app.ts"])
            sleep(10)
        } else {
            app = launch(["-openSession", finished])
            sleep(10)
        }
        save("4-workspace")
        app.terminate()
    }

    /// The board: every agent by its state.
    func test5Board() {
        let app = launch(["-openBoard", "1"], appearance: "dark")
        sleep(10)
        save("5-board")
        app.terminate()
    }

    /// Talk: a request said or typed, routed to the agent already on that work.
    func test6Talk() {
        let request = portuguese ? "Coloca o plano anual na página de preços" : "Add the yearly plan to the pricing page"
        let app = launch(["-openTalk", "1", "-talkText", request, "-talkRoute", "1"])
        sleep(12)
        save("6-talk")
        app.terminate()
    }

    /// The iPad's changes: a worktree's patches beside its files, ready to commit.
    func test7Changes() throws {
        guard pad else { throw XCTSkip("iPad only") }
        let app = launch(["-openProject", "billing-api/webhook-retries", "-workspaceTab", "changes"])
        sleep(10)
        save("7-changes")
        app.terminate()
    }
}
