import XCTest

/// Projects coming and going, against the mock box (compact width, an iPhone simulator): the GitHub account's
/// repositories downloaded with a tap, a repository cloned by its link, a project removed from the disk (with its
/// unsaved work in the way first), and a worktree's details (its preview link and services). Skipped on regular width.
final class ProjectsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-startTab", "projects", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
    }

    private func launch() throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Projetos"].waitForExistence(timeout: 15), "Projetos did not open")
        if element("sidebar-home").exists { throw XCTSkip("regular width: covered on the iPhone") }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(_ s: String) -> XCUIElement { app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    func testDownloadFromGitHubAndCloneByLink() throws {
        try launch()
        element("projects-add").tap()
        app.buttons["Repositórios do GitHub"].tap()
        let notes = element("github-repo-notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "the account's repositories did not load")
        XCTAssertTrue(text("Na box").exists, "repositories already on the box are not marked")
        shot("github-repos")
        notes.tap()
        // The mock clones in about 3 s; then notes is on the box.
        let onBox = notes.staticTexts["Na box"]
        XCTAssertTrue(onBox.waitForExistence(timeout: 15), "the downloaded repository did not reach the box")
        shot("github-downloaded")

        element("clone-by-link").tap()
        let field = element("clone-link-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://github.com/octocat/hello-world")
        element("clone-start").tap()
        XCTAssertTrue(text("Pronto").waitForExistence(timeout: 15), "the clone by link did not finish")
        shot("clone-by-link-ready")
        element("clone-open").tap()
        XCTAssertTrue(app.navigationBars["hello-world"].waitForExistence(timeout: 10), "Abrir projeto did not open the clone")
    }

    func testRemoveProjectNeedsDiscardForUnsavedWork() throws {
        try launch()
        let project = app.staticTexts["sandbox"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        let remove = element("project-remove")
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "no Remover projeto do disco")
        remove.tap()
        XCTAssertTrue(text("Ocupa").waitForExistence(timeout: 10), "the project's size was not measured")
        XCTAssertTrue(text("commit(s) que nenhum remoto tem").exists, "unpushed commits are not listed")
        let run = element("purge-run")
        if !run.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(run.waitForExistence(timeout: 5), "no Remover do disco button")
        XCTAssertFalse(run.isEnabled, "removal is allowed with unsaved work and no Descartar")
        shot("remove-project-unsaved")
        element("purge-force").switches.firstMatch.tap()
        XCTAssertTrue(run.isEnabled)
        run.tap()
        XCTAssertTrue(app.navigationBars["Projetos"].waitForExistence(timeout: 10), "did not go back to Projetos")
        XCTAssertTrue(text("removido da box").waitForExistence(timeout: 5), "no confirmation")
        XCTAssertFalse(app.staticTexts["sandbox"].exists, "the removed project is still listed")
    }

    func testWorktreeDetailsShowPreviewAndServices() throws {
        try launch()
        let project = app.staticTexts["sandbox"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        // The list opens a project with agents at work into its worktrees (as the sidebar does): close it, so the
        // worktree found below is the project screen's, not the list's (which stays under it in the stack).
        if element("projects-worktree-sandbox/subtract").exists { element("projects-disclosure-sandbox").tap() }
        XCTAssertTrue(element("projects-worktree-sandbox/subtract").waitForNonExistence(timeout: 5))
        project.tap()
        let worktree = app.staticTexts["subtract"].firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 10))
        worktree.tap()
        let details = element("worktree-details")
        XCTAssertTrue(details.waitForExistence(timeout: 10), "no Detalhes on the worktree")
        details.tap()
        XCTAssertTrue(element("service-dev").waitForExistence(timeout: 10), "the worktree's services did not load")
        XCTAssertTrue(text("HOST=0.0.0.0 npm run dev").exists, "the service's command is not shown")
        XCTAssertTrue(text("rodando").exists)
        XCTAssertTrue(text("Portas").exists, "no ports in Ambiente")
        shot("worktree-details")
        app.buttons["Parar dev"].tap()
        XCTAssertTrue(text("parado").waitForExistence(timeout: 10), "stopping the service did not show")
    }

    func testProjectsFolderSpacesAndEnvironment() throws {
        app.launchArguments = ["-uiTestMock", "1", "-startTab", "settings", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        if element("sidebar-home").exists { throw XCTSkip("regular width: covered on the iPhone") }
        let link = app.buttons["Pasta dos projetos e espaços"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), "no projects folder in Ajustes")
        link.tap()
        let field = element("projects-root-field")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("~/code")
        element("projects-root-save").tap()
        XCTAssertTrue(element("space-clientes").waitForExistence(timeout: 10), "the spaces did not show once the folder was set")
        XCTAssertTrue(text("Docker 27.3.1").exists, "Docker's state is not shown")
        element("space-add").tap()
        app.textFields["nome"].typeText("pessoal")
        app.buttons["Criar"].tap()
        XCTAssertTrue(element("space-pessoal").waitForExistence(timeout: 10), "the new space is not listed")
        shot("projects-folder")
        app.navigationBars.buttons.firstMatch.tap()

        // A project's environment: PHP 8.4 and MySQL 8.0.
        XCTAssertTrue(app.tabBars.buttons["Projetos"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Projetos"].tap()
        let project = app.staticTexts["sandbox"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        let env = element("project-environment")
        XCTAssertTrue(env.waitForExistence(timeout: 10), "no Ambiente on the project")
        env.tap()
        XCTAssertTrue(element("env-state-none").waitForExistence(timeout: 10), "the environment did not load")
        element("env-runtime-mode").tap()
        app.buttons["Versão escolhida"].tap()
        element("env-add-container").tap()
        app.buttons["MySQL"].tap()
        app.buttons["MySQL 8.0"].tap()
        XCTAssertTrue(element("env-container-mysql").waitForExistence(timeout: 5), "the container was not added")
        element("env-apply").tap()
        XCTAssertTrue(element("env-state-ready").waitForExistence(timeout: 15), "the environment did not get ready")
        XCTAssertTrue(text("PHP 8.4 · MySQL 8.0").exists, "the summary is wrong")
        app.swipeUp()
        XCTAssertTrue(text("DB_HOST").waitForExistence(timeout: 5), "the worktrees' variables are not shown")
        shot("project-environment")
    }

    func testLimitsAccountsVariablesAndPublicLink() throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Projetos"].waitForExistence(timeout: 15))
        if element("sidebar-home").exists { throw XCTSkip("regular width: covered on the iPhone") }

        // Home: the limits, Claude's to be turned on.
        app.tabBars.buttons["Início"].tap()
        let enable = element("limits-enable")
        for _ in 0..<6 where !enable.exists { app.swipeUp() }
        XCTAssertTrue(enable.waitForExistence(timeout: 10), "no limits widget with Claude's to turn on")
        XCTAssertTrue(text("12%").exists, "Codex's limits are not shown")
        enable.tap()
        XCTAssertTrue(text("81%").waitForExistence(timeout: 10), "Claude's limits did not show once turned on")
        shot("home-limits")

        // Ajustes: a second Claude account, signed in from a terminal.
        app.tabBars.buttons["Ajustes"].tap()
        let accounts = element("settings-accounts-devbox")
        for _ in 0..<4 where !accounts.isHittable { app.swipeUp() }
        accounts.tap()
        element("account-add-claude").tap()
        app.textFields.firstMatch.typeText("Trabalho")
        app.buttons["Criar e entrar"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(text("Trabalho").waitForExistence(timeout: 10), "the new account is not listed")
        shot("accounts")
        app.navigationBars.buttons.firstMatch.tap()

        // The box's variables, with a note.
        let vars = element("settings-vars-devbox")
        for _ in 0..<4 where !vars.isHittable { app.swipeUp() }
        vars.tap()
        XCTAssertTrue(element("var-value-STAGING_URL").waitForExistence(timeout: 10), "the variables did not load")
        let key = element("var-new-key")
        key.tap()
        key.typeText("REGION")
        element("var-add").tap()
        element("var-value-REGION").tap()
        element("var-value-REGION").typeText("sa-east-1")
        element("vars-save").tap()
        XCTAssertTrue(text("Variáveis salvas").waitForExistence(timeout: 10), "saving did not confirm")
        XCTAssertTrue(element("skill-pier-box").exists, "no skills")
        shot("variables")
        app.navigationBars.buttons.firstMatch.tap()

        // A worktree's dev server gets a public link; the project picks the new account.
        XCTAssertTrue(app.tabBars.buttons["Projetos"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Projetos"].tap()
        app.staticTexts["sandbox"].firstMatch.tap()
        let picker = element("project-account-claude")
        for _ in 0..<4 where !picker.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no account picker on the project")
        picker.tap()
        app.buttons["Trabalho"].firstMatch.tap()
        let details = app.buttons["Detalhes: serviços e visualização"].firstMatch
        for _ in 0..<4 where !details.isHittable { app.swipeDown() }
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        let create = element("public-link-create-41000")
        XCTAssertTrue(create.waitForExistence(timeout: 10), "no public link button on the dev server")
        create.tap()
        XCTAssertTrue(element("public-link-41000").waitForExistence(timeout: 10), "the public link did not show")
        XCTAssertTrue(text("docktopier.com").exists)
        shot("public-link")
    }
}
