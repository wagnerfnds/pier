import XCTest

/// Projects coming and going, against the mock box (compact width, an iPhone simulator): the GitHub account's
/// repositories downloaded with a tap, a repository cloned by its link, a project removed from the disk (with its
/// unsaved work in the way first), and a worktree's details (its preview with the public link and test login, its
/// services). Skipped on regular width.
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
        shot("worktree-details")
        app.buttons["Parar dev"].tap()
        XCTAssertTrue(text("parado").waitForExistence(timeout: 10), "stopping the service did not show")
        // Ambiente is the last section, below the preparation and the preview.
        let ports = text("Portas")
        for _ in 0..<4 where !ports.exists { app.swipeUp() }
        XCTAssertTrue(ports.exists, "no ports in Ambiente")
    }

    /// What a setup agent left in the mock's main checkout of sandbox: the public link first, then the test login
    /// with its password hidden until asked for.
    func testWorktreeDetailsShowPublicLinkAndTestLogin() throws {
        try launch()
        let project = app.staticTexts["sandbox"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        if element("projects-worktree-sandbox/subtract").exists { element("projects-disclosure-sandbox").tap() }
        XCTAssertTrue(element("projects-worktree-sandbox/subtract").waitForNonExistence(timeout: 5))
        project.tap()
        let details = app.buttons["Detalhes: serviços e visualização"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10), "the project offers no Detalhes for its main checkout")
        details.tap()
        let link = element("preview-public-link")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the preview's public link is not shown")
        // The public address, at the page the setup agent recorded.
        XCTAssertTrue(link.label.hasPrefix("https://p-") && link.label.hasSuffix(".docktopier.com/login"), "not the preview's public link: \(link.label)")
        XCTAssertTrue(element("preview-copy-link").exists, "no Copiar beside the public link")
        XCTAssertEqual(element("preview-login-user").label, "demo@example.com", "the test login's user is not shown")
        let password = element("preview-login-password")
        XCTAssertEqual(password.label, "Senha escondida", "the password shows before it is asked for")
        XCTAssertFalse(text("demo-pass-123").exists, "the password is on screen before it is asked for")
        shot("worktree-preview")
        element("preview-reveal-password").tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "demo-pass-123"), object: password)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, "Mostrar senha did not show it")
    }

    /// sandbox's base in the mock: the team's, published hours ago, with its .env (keys, never values) and auth.json, the
    /// folders carried from the main checkout (instantly on this disk) and the team's recipe.
    func testProjectBaseShowsWhatEveryWorktreeGets() throws {
        try launch()
        let project = app.staticTexts["sandbox"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        if element("projects-worktree-sandbox/subtract").exists { element("projects-disclosure-sandbox").tap() }
        project.tap()
        let base = element("project-base")
        XCTAssertTrue(base.waitForExistence(timeout: 10), "no Base do projeto on the project")
        base.tap()
        XCTAssertTrue(element("base-team").waitForExistence(timeout: 10), "the team's base is not shown")
        XCTAssertTrue(element("base-file-.env").exists && element("base-file-auth.json").exists, "the base's files are not listed")
        XCTAssertTrue(text("4 chaves").exists, "the .env's keys are not counted")
        XCTAssertTrue(text("da equipe").exists && text("desta box").exists, "whose each file is is not shown")
        let vendor = element("base-carry-vendor")
        for _ in 0..<3 where !vendor.exists { app.swipeUp() }
        XCTAssertTrue(vendor.exists && element("base-carry-node_modules").exists, "the carried folders are not listed")
        XCTAssertTrue(text("divide os blocos").exists, "the instant copy is not explained")
        shot("project-base")
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
        element("space-add").tap()
        app.textFields["nome"].typeText("pessoal")
        app.buttons["Criar"].tap()
        XCTAssertTrue(element("space-pessoal").waitForExistence(timeout: 10), "the new space is not listed")
        shot("projects-folder")
        // Below the spaces: the projects setup agents may prepare, the box's preparation, and Docker's state.
        XCTAssertTrue(element("setup-agent-sandbox").waitForExistence(timeout: 5), "sandbox's setup agent consent is not listed")
        let docker = text("Docker 27.3.1")
        for _ in 0..<4 where !docker.exists { app.swipeUp() }
        XCTAssertTrue(docker.exists, "Docker's state is not shown")
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

        // Previews get no public link by themselves: the setup agent's page in sandbox is published by hand below.
        let folder = element("settings-projects-devbox")
        for _ in 0..<4 where !folder.isHittable { app.swipeDown() }
        folder.tap()
        let autoShare = element("auto-share-toggle")
        for _ in 0..<4 where !(autoShare.exists && autoShare.isHittable) { app.swipeUp() }
        XCTAssertTrue(autoShare.waitForExistence(timeout: 10), "no automatic public link switch")
        autoShare.switches.firstMatch.tap()
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: autoShare)
        XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 5), .completed, "the automatic public link did not turn off")
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
