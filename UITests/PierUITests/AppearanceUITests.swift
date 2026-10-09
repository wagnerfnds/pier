import XCTest

/// Ajustes ⟶ Aparência against the mock box: Claro and Escuro repaint the app right away (checked on the screenshot's
/// pixels, not just the picker), with screenshots of the Home, a session and the Faxina in each. Ends on Sistema so the
/// other tests run with the default. `TEST_RUNNER_APPEARANCE_SHOTS=<dir>` also writes the screenshots as PNG.
final class AppearanceUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestExtras", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 15), "home did not load")
    }

    override func tearDownWithError() throws {
        // Back to the default even when the test failed halfway, so the choice does not leak into other tests.
        if app.state == .runningForeground { choose("Sistema", check: false) }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["APPEARANCE_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Average luminance (0...1) of a small patch between the status bar and the large title: the screen background.
    private func backgroundLuminance() -> Double {
        guard let cg = app.screenshot().image.cgImage else { return -1 }
        let w = cg.width, h = cg.height
        let rect = CGRect(x: w * 45 / 100, y: h * 75 / 1000, width: w / 10, height: h / 100)
        guard let crop = cg.cropping(to: rect) else { return -1 }
        var px = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let ctx = CGContext(data: &px, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            sum += (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
        }
        return sum / Double(px.count / 4)
    }

    /// Ajustes ⟶ Aparência ⟶ `option`.
    @discardableResult
    private func choose(_ option: String, check: Bool = true) -> Bool {
        app.buttons["Ajustes"].firstMatch.tap()
        let segment = element("appearance-picker").buttons[option]
        let found = segment.waitForExistence(timeout: 10)
        if check { XCTAssertTrue(found, "no '\(option)' in Aparência") }
        guard found else { return false }
        segment.tap()
        if check { XCTAssertTrue(segment.isSelected, "'\(option)' did not stay selected") }
        return true
    }

    /// The Home: its tab on iPhone, its sidebar row on iPad (whose label carries the count, "Início 1").
    private func goHome() {
        let row = element("sidebar-home")
        if row.exists { row.tap() } else { app.buttons["Início"].firstMatch.tap() }
    }

    /// Back from a pushed screen. On iPad the navigation bar's first button folds the sidebar away instead: there the
    /// sidebar takes the test on.
    private func back() {
        if element("sidebar-home").exists { goHome() } else { app.navigationBars.buttons.firstMatch.tap() }
    }

    private func openSession(titled prefix: String) {
        sleep(2)
        // The first one on screen: on iPad the title is also in places that are not (a folded card, the dots' labels).
        let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
        func visible() -> XCUIElement? { rows.allElementsBoundByIndex.first { $0.exists && $0.isHittable } }
        var tries = 0
        while visible() == nil, tries < 6 { app.swipeUp(); tries += 1 }
        guard let row = visible() else { shot("notfound"); return XCTFail("session row '\(prefix)' not found") }
        row.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "session screen did not open")
        sleep(2)
    }

    private func tour(_ mode: String, light: Bool) {
        choose(mode == "light" ? "Claro" : "Escuro")
        sleep(1)
        let l = backgroundLuminance()
        if light { XCTAssertGreaterThan(l, 0.85, "Claro: the background is not light (\(l))") }
        else { XCTAssertLessThan(l, 0.15, "Escuro: the background is not dark (\(l))") }
        shot("appearance-\(mode)-settings")

        let faxina = app.staticTexts["Faxina"].firstMatch
        if faxina.waitForExistence(timeout: 5) {
            faxina.tap()
            sleep(3)
            shot("appearance-\(mode)-faxina")
            back()
        }

        goHome()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 10))
        sleep(2)
        shot("appearance-\(mode)-home")
        app.swipeUp(); app.swipeUp(); sleep(1)
        shot("appearance-\(mode)-home-more")
        app.swipeDown(); app.swipeDown(); app.swipeDown()

        openSession(titled: "Add a subtract function")
        shot("appearance-\(mode)-session")
        back()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 10), "did not come back to the Home")
    }

    func testAppearanceLightAndDark() {
        tour("light", light: true)
        tour("dark", light: false)
        choose("Sistema")
    }
}
