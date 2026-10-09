#if DEBUG
import Foundation
import PierKit

/// `-uiTestMock 1 -uiTestShowcase 1`: the mock box answers with a showcase dataset in English, for screenshots (the
/// README, the App Store, a magazine): four projects, agents at realistic work — a permission to answer, a question with
/// three choices, a finished turn with a diff and suggested next steps, two agents working (one with a job in the
/// background), a chat with no project, a closed session — plus pull requests, a CI failure, two weeks of git activity,
/// dev servers, and the answers the AI touches would give (titles, next steps, commit messages, Talk's routing).
/// Everything is fictional: no real people, companies, addresses or data. `MockBox` consults it first and falls through
/// to its generic routes for the rest (see the showcase block at the end of UITestMock.swift). Off, nothing changes.
/// The dataset follows the app's language: with Portuguese first in the preferred languages (`-AppleLanguages "(pt-BR)"`)
/// the titles, prompts, replies, questions, recaps and pull requests are in Brazilian Portuguese (`t(en, pt)`); project
/// names, branches, commands and code stay as they are. Claude Code's own terminal chrome stays in English, as it is.
enum UITestShowcase {
    typealias JSON = [String: Any]

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "uiTestShowcase") }

    /// Portuguese first in the preferred languages: the showcase speaks Brazilian Portuguese.
    static var portuguese: Bool { Locale.preferredLanguages.first?.lowercased().hasPrefix("pt") ?? false }

    /// The English text, or its Brazilian Portuguese edition when the app runs in Portuguese.
    static func t(_ en: String, _ pt: String) -> String { portuguese ? pt : en }

    // MARK: sessions

    static let permission = "storefront-stripe-checkout-claude-7f2a"
    static let question = "storefront-pricing-page-claude-c41e"
    static let finished = "billing-api-webhook-retries-claude-9b1d"
    static let passkeys = "mobile-app-passkeys-claude-3e8c"
    static let docs = "docs-site-release-notes-codex-a0f3"
    static let chat = "chat-claude-q4on"
    static let exited = "storefront-claude-5d77"

    static var questionChoices: [String] { portuguese ? ["Três planos", "Um plano só", "Uma tabela"] : ["Three tiers", "One plan", "A table"] }
    static var permissionReply: String {
        t("Installed `stripe` 17.4. Next: a server action that opens a Checkout Session per plan, then the webhook.",
          "Instalei o `stripe` 17.4. Agora: uma server action que abre uma Checkout Session por plano e, depois, o webhook.")
    }
    static func questionReply(_ pick: String) -> String {
        t("Going with **\(pick)**. Building the pricing page now.", "Vamos de **\(pick)**. Já estou montando a página de preços.")
    }

    /// The session titles (also the widgets' and the Live Activities').
    static var titlePermission: String { t("Add Stripe checkout to the pricing page", "Adicionar o checkout do Stripe à página de preços") }
    static var titleQuestion: String { t("Build the pricing page", "Montar a página de preços") }
    static var titleFinished: String { t("Fix webhook retries with exponential backoff", "Corrigir os retries de webhook com backoff exponencial") }
    static var titlePasskeys: String { t("Migrate auth to passkeys", "Migrar o login para passkeys") }
    static var titleDocs: String { t("Write release notes for 2.4", "Escrever as notas da versão 2.4") }
    static var titleChat: String { t("Plan the Q4 onboarding revamp", "Planejar o novo onboarding do 4º tri") }
    static var questionText: String { t("Which layout for the pricing page?", "Qual layout para a página de preços?") }
    static var permissionWhy: String { t("Install the Stripe SDK for the checkout session", "Instalar o SDK do Stripe para a sessão de checkout") }

    static func iso(ago: TimeInterval) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(-ago))
    }

    private static func session(_ name: String, location: String?, dir: String, agent: String = "claude", state: String, title: String,
                                since: TimeInterval, created: TimeInterval, ask: JSON? = nil, chat: Bool = false, exited: Bool = false) -> JSON {
        var s: JSON = [
            "agent": agent, "agent_state": state, "attached": 0, "command": agent == "codex" ? "codex" : "claude --model opus",
            "created": iso(ago: created), "dir": dir, "exited": exited, "fidelity": "hooks", "name": name, "preset": agent,
            "state_seq": 250, "state_since": iso(ago: since), "title": title, "turn": "\(name)#3",
        ]
        if let location { s["location"] = location }
        if let ask { s["ask"] = ask }
        if chat { s["chat"] = true }
        return s
    }

    static func sessions() -> [JSON] {
        [
            session(permission, location: "storefront/stripe-checkout", dir: "/home/ubuntu/code/storefront-stripe-checkout", state: "waiting",
                    title: titlePermission, since: 180, created: 1500,
                    ask: ["tool": "Bash", "input": "npm install stripe", "why": permissionWhy]),
            session(question, location: "storefront/pricing-page", dir: "/home/ubuntu/code/storefront-pricing-page", state: "waiting",
                    title: titleQuestion, since: 60, created: 900,
                    ask: ["tool": "AskUserQuestion", "input": questionText, "message": t("Claude has a question", "Claude tem uma pergunta"),
                          "why": t("I'd recommend option 1: three tiers keep the page scannable.",
                                   "Recomendo a opção 1: três planos deixam a página fácil de comparar.")]),
            session(finished, location: "billing-api/webhook-retries", dir: "/home/ubuntu/code/billing-api-webhook-retries", state: "finished",
                    title: titleFinished, since: 240, created: 2400),
            session(passkeys, location: "mobile-app/passkeys", dir: "/home/ubuntu/code/mobile-app-passkeys", state: "running",
                    title: titlePasskeys, since: 720, created: 3300),
            session(docs, location: "docs-site/release-notes", dir: "/home/ubuntu/code/docs-site-release-notes", agent: "codex", state: "running",
                    title: titleDocs, since: 360, created: 1100),
            session(chat, location: nil, dir: "/home/ubuntu/pier/chats/\(chat)", state: "finished",
                    title: titleChat, since: 1500, created: 2000, chat: true),
            session(exited, location: "storefront", dir: "/home/ubuntu/code/storefront", state: "finished",
                    title: t("Bump Next.js to 15.4", "Atualizar o Next.js para a 15.4"), since: 7200, created: 10800, exited: true),
        ]
    }

    /// Transcript items shaped like pierd's (`kind`, `id`, `off`…), with offsets far above the ones MockBox hands out.
    private struct Items {
        var off = 100_000
        var out: [JSON] = []
        private mutating func next() -> Int { off += 1000; return off }
        mutating func user(_ text: String) { add("user", ["text": text]) }
        mutating func text(_ text: String) { add("text", ["text": text]) }
        mutating func edit(_ file: String, _ added: Int, _ removed: Int = 0) { add("edit", ["file": file, "added": added, "removed": removed, "tool": "toolu_\(off + 1)"]) }
        mutating func tools(_ verb: String, _ targets: [String], file: Bool = false) {
            let calls: [JSON] = targets.enumerated().map { i, t in
                var c: JSON = ["id": "toolu_\(off + 1)_\(i)", "verb": verb, "target": t, "at": 1_791_408_804_607 + i]
                if file { c["file"] = true }
                return c
            }
            add("tools", ["verb": verb, "done": true, "items": calls])
        }
        private mutating func add(_ kind: String, _ extra: JSON) {
            let o = next()
            var it: JSON = ["id": "cl@\(o).1", "kind": kind, "off": o]
            for (k, v) in extra { it[k] = v }
            out.append(it)
        }
    }

    static func transcripts() -> [String: [JSON]] {
        var out: [String: [JSON]] = [:]
        var i = Items()
        i.user(t("Add Stripe checkout to the pricing page: a Checkout Session per plan, success and cancel pages, and the webhook that marks the workspace as paid.",
                 "Adicione o checkout do Stripe à página de preços: uma Checkout Session por plano, as páginas de sucesso e de cancelamento, e o webhook que marca o workspace como pago."))
        i.tools("Read", ["app/pricing/page.tsx", "lib/plans.ts"], file: true)
        i.text(t("I'll create a Checkout Session per plan from a server action and handle `checkout.session.completed` in the webhook. First, the Stripe SDK.",
                 "Vou criar uma Checkout Session por plano a partir de uma server action e tratar o `checkout.session.completed` no webhook. Primeiro, o SDK do Stripe."))
        out[permission] = i.out

        i = Items()
        i.user(t("Build the pricing page from the plans in lib/plans.ts, with a monthly / yearly toggle.",
                 "Monte a página de preços a partir dos planos em lib/plans.ts, com um seletor mensal / anual."))
        i.tools("Read", ["lib/plans.ts", "app/pricing/page.tsx"], file: true)
        i.text(t("Before I build it: which layout do you want? I'd recommend option 1 — three tiers keep the page scannable.",
                 "Antes de começar: qual layout você prefere? Recomendo a opção 1 — três planos deixam a página fácil de comparar."))
        out[question] = i.out

        i = Items()
        i.user(t("Fix webhook retries with exponential backoff. Retries fire every 2 s forever and hammer a customer's endpoint while it is down.",
                 "Corrija os retries de webhook com backoff exponencial. Hoje eles disparam a cada 2 s, sem fim, e martelam o endpoint do cliente enquanto ele está fora do ar."))
        i.tools("Read", ["internal/webhooks/dispatch.go", "internal/webhooks/dispatch_test.go"], file: true)
        i.tools("Run", ["go test ./internal/webhooks/..."])
        i.edit("internal/webhooks/dispatch.go", 64, 31)
        i.edit("internal/webhooks/backoff.go", 33)
        i.edit("internal/webhooks/dispatch_test.go", 16, 6)
        i.tools("Run", ["go test ./..."])
        i.text(portuguese ? """
        Os retries agora usam backoff exponencial em vez de disparar a cada 2 s.

        - **`backoff.go`**: `Next(attempt)` dobra de 1 s até um teto de 10 min, com ±20 % de jitter; um endpoint fora do ar recebe 8 tentativas em cerca de 20 minutos e depois a entrega fica estacionada.
        - **`dispatch.go`**: o agendador lê o intervalo de `Next`, grava `attempts` e `next_at` na linha da entrega e desiste com um evento `webhook.exhausted` em vez de ficar em loop.
        - **`dispatch_test.go`**: cobre o agendamento, os limites do jitter e a desistência.

        `go test ./...` passa (41 testes). Nada foi commitado ainda — é só pedir que eu abro um pull request.
        """ : """
        Retries now back off exponentially instead of firing every 2 s.

        - **`backoff.go`**: `Next(attempt)` doubles from 1 s to a 10 min cap with ±20 % jitter, so a down endpoint is retried 8 times over about 20 minutes and then parked.
        - **`dispatch.go`**: the scheduler reads the delay from `Next`, records `attempts` and `next_at` on the delivery row, and gives up with a `webhook.exhausted` event instead of looping.
        - **`dispatch_test.go`**: covers the schedule, the jitter bounds and the give-up path.

        `go test ./...` passes (41 tests). Nothing is committed yet — say the word and I'll open a pull request.
        """)
        out[finished] = i.out

        i = Items()
        i.user(t("Migrate auth to passkeys: registration and sign-in with ASAuthorization, keep password sign-in as a fallback behind a flag, and update the tests.",
                 "Migre o login para passkeys: cadastro e entrada com ASAuthorization, mantenha o login com senha como alternativa atrás de uma flag e atualize os testes."))
        i.tools("Read", ["MobileApp/Auth/AuthViewModel.swift", "MobileApp/Auth/LoginView.swift", "MobileApp/Auth/Keychain.swift"], file: true)
        i.tools("Search", ["ASAuthorizationController", "signIn(password:"])
        i.edit("MobileApp/Auth/AuthViewModel.swift", 92, 40)
        i.edit("MobileApp/Auth/PasskeyCoordinator.swift", 118)
        i.text(t("Registration and sign-in go through `PasskeyCoordinator` now. Running the auth test plan in the background while I wire the password fallback.",
                 "Cadastro e entrada agora passam pelo `PasskeyCoordinator`. Estou rodando os testes de autenticação em segundo plano enquanto ligo a alternativa com senha."))
        out[passkeys] = i.out

        i = Items()
        i.user(t("Write the release notes for 2.4 from the pull requests merged since 2.3. Keep the tone of the previous notes.",
                 "Escreva as notas da versão 2.4 a partir dos pull requests mesclados desde a 2.3. Mantenha o tom das notas anteriores."))
        i.tools("Run", ["gh pr list --state merged --base main --search \"merged:>=2026-09-12\" --json number,title,labels"])
        i.tools("Read", ["docs/releases/2.3.md", "mkdocs.yml"], file: true)
        i.edit("docs/releases/2.4.md", 74)
        out[docs] = i.out

        i = Items()
        i.user(t("Plan the Q4 onboarding revamp. We lose half of new users before they connect a data source.",
                 "Planeje o novo onboarding do 4º tri. Perdemos metade dos novos usuários antes de eles conectarem uma fonte de dados."))
        i.text(portuguese ? """
        Um primeiro plano, em três movimentos:

        1. **Medir a queda** — eventos de funil para *cadastro → viu a tela de conexão → conectou → primeiro gráfico*. Uma semana de dados mostra onde a metade se perde.
        2. **Encurtar o caminho** — uma fonte de dados de exemplo já selecionada, para o primeiro gráfico aparecer antes de qualquer conexão. Conectar vira o segundo passo, não a porta de entrada.
        3. **Lembrar sem insistir** — um e-mail no 2º dia com o gráfico que a pessoa viu e um card no Slack do workspace.

        Quer que eu escreva os eventos do funil como especificação ou que eu esboce primeiro a nova tela de conexão?
        """ : """
        Here is a first plan, in three moves:

        1. **Measure the drop** — add funnel events for *signed up → saw the connect screen → connected → first chart*. One week of data tells us where the half goes.
        2. **Shorten the path** — a sample data source selected by default, so the first chart appears before anyone connects anything. Connecting becomes the second step, not the gate.
        3. **Nudge, don't nag** — one email on day 2 with the chart they saw, and a card in the workspace's Slack.

        Want me to draft the funnel events as a spec, or sketch the new connect screen first?
        """)
        out[chat] = i.out

        i = Items()
        i.user(t("Bump Next.js to 15.4 and fix whatever breaks.", "Atualize o Next.js para a 15.4 e corrija o que quebrar."))
        i.edit("package.json", 3, 3)
        i.text(t("Done: Next.js 15.4, every page renders, `pnpm test` is green.", "Pronto: Next.js 15.4, todas as páginas renderizam e o `pnpm test` está verde."))
        out[exited] = i.out
        return out
    }

    /// Extra keys on a transcript page: the agent's `source`, and a job running in the background.
    static func transcriptExtras(name: String) -> JSON? {
        switch name {
        case docs: return ["source": "codex"]
        case passkeys:
            let since = Int64(Date().addingTimeInterval(-150).timeIntervalSince1970 * 1000)
            return ["signals": ["mode": "auto", "background": [["tool": "toolu_bg1", "task": "b1", "kind": "shell",
                "command": "xcodebuild test -scheme MobileApp -only-testing:AuthTests", "state": "running", "since": since]]]]
        default: return nil
        }
    }

    // MARK: screens (what the raw terminal shows; the menus the cards read)

    static func screen(name: String, waiting: Bool) -> String? {
        switch name {
        case permission where waiting: return permissionScreen
        case question where waiting: return questionScreen
        case finished: return finishedScreen
        case passkeys: return passkeysScreen
        case docs: return docsScreen
        default: return nil
        }
    }

    // The screens in the app's language: the person's prompts and the agent's words translated, Claude Code's and
    // Codex's own chrome ("Do you want to proceed?", "Type something.", the status lines) as the tools print it.
    static var permissionScreen: String { portuguese ? permissionScreenPT : permissionScreenEN }
    static var questionScreen: String { portuguese ? questionScreenPT : questionScreenEN }
    static var finishedScreen: String { portuguese ? finishedScreenPT : finishedScreenEN }
    static var passkeysScreen: String { portuguese ? passkeysScreenPT : passkeysScreenEN }
    static var docsScreen: String { portuguese ? docsScreenPT : docsScreenEN }

    static let permissionScreenPT = """
     ▐▛███▛█   Claude Code v2.1.293
    ▝▜██████▀  Opus 5.5 · Claude Max
     ▝▝   ▝▝   ~/code/storefront-stripe-checkout

    ❯ Adicione o checkout do Stripe à página de preços: uma Checkout Session por
      plano, as páginas de sucesso e de cancelamento, e o webhook que marca o
      workspace como pago.

      Read 2 files, listed 1 directory

    ● Vou criar uma Checkout Session por plano a partir de uma server action e tratar
      o checkout.session.completed no webhook. Primeiro, o SDK do Stripe.

    ● Bash(npm install stripe)
      ⎿  Instalar o SDK do Stripe para a sessão de checkout

    ──────────────────────────────────────────────────────────────────────────────
     Bash command
     Instalar o SDK do Stripe para a sessão de checkout
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     npm install stripe
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for npm install commands in
          /home/ubuntu/code/storefront-stripe-checkout
       3. No, and tell Claude what to do differently (esc)

     Esc to cancel · Tab to amend
    """

    static let questionScreenPT = """
    ● Qual layout para a página de preços?

     ❯ 1. Três planos
          Starter, Pro e Team lado a lado
       2. Um plano só
          Um preço, com os recursos listados abaixo
       3. Uma tabela
          Cada recurso comparado em todos os planos
       4. Type something.
       5. Chat about this

      Enter to select · ↑↓ to move
    """

    static let finishedScreenPT = """
     ▐▛███▛█   Claude Code v2.1.293
    ▝▜██████▀  Opus 5.5 · Claude Max
     ▝▝   ▝▝   ~/code/billing-api-webhook-retries

    ❯ Corrija os retries de webhook com backoff exponencial. Hoje eles disparam a
      cada 2 s, sem fim, e martelam o endpoint do cliente enquanto ele está fora
      do ar.

      Read 2 files, ran 2 shell commands

    ● Update(internal/webhooks/dispatch.go)
      ⎿  Added 64 lines, removed 31 lines

    ● Write(internal/webhooks/backoff.go)
      ⎿  Wrote 33 lines to internal/webhooks/backoff.go
          package webhooks

          import (
              "math/rand"
              "time"
          )
          …

    ● Update(internal/webhooks/dispatch_test.go)
      ⎿  Added 16 lines, removed 6 lines

    ● Bash(go test ./...)
      ⎿  ok   billing-api/internal/webhooks   2.41s
         ok   billing-api/internal/invoices   0.87s
         ok   billing-api/internal/api        1.12s

    ● Os retries agora usam backoff exponencial em vez de disparar a cada 2 s.

      - backoff.go: Next(attempt) dobra de 1 s até um teto de 10 min, com ±20 % de
        jitter; um endpoint fora do ar recebe 8 tentativas em cerca de 20 minutos
        e depois a entrega fica estacionada.
      - dispatch.go: o agendador lê o intervalo de Next, grava attempts e next_at
        na linha da entrega e desiste com um evento webhook.exhausted.
      - dispatch_test.go: cobre o agendamento, os limites do jitter e a desistência.

      go test ./... passa (41 testes). Nada foi commitado ainda — é só pedir que
      eu abro um pull request.

    ✻ Worked for 2m 14s · done 9:37 AM

    ────────────────────────────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle)
    """

    static let passkeysScreenPT = """
    ❯ Migre o login para passkeys: cadastro e entrada com ASAuthorization, mantenha
      o login com senha como alternativa atrás de uma flag e atualize os testes.

      Read 3 files, searched 2 patterns

    ● Update(MobileApp/Auth/AuthViewModel.swift)
      ⎿  Added 92 lines, removed 40 lines

    ● Write(MobileApp/Auth/PasskeyCoordinator.swift)
      ⎿  Wrote 118 lines to MobileApp/Auth/PasskeyCoordinator.swift

    ● Cadastro e entrada agora passam pelo PasskeyCoordinator. Estou rodando os
      testes de autenticação em segundo plano enquanto ligo a alternativa com senha.

    ● Bash(xcodebuild test -scheme MobileApp -only-testing:AuthTests)
    ✻ Simmering… (1m 12s · ↑ 3.1k tokens · esc to interrupt)
    """

    static let docsScreenPT = """
    › Escreva as notas da versão 2.4 a partir dos pull requests mesclados desde a
      2.3. Mantenha o tom das notas anteriores.

    • Ran gh pr list --state merged --base main --search "merged:>=2026-09-12"
      └ 23 pull requests
    • Read docs/releases/2.3.md
    • Editing docs/releases/2.4.md
    """

    static let permissionScreenEN = """
     ▐▛███▛█   Claude Code v2.1.293
    ▝▜██████▀  Opus 5.5 · Claude Max
     ▝▝   ▝▝   ~/code/storefront-stripe-checkout

    ❯ Add Stripe checkout to the pricing page: a Checkout Session per plan, success
      and cancel pages, and the webhook that marks the workspace as paid.

      Read 2 files, listed 1 directory

    ● I'll create a Checkout Session per plan from a server action and handle
      checkout.session.completed in the webhook. First, the Stripe SDK.

    ● Bash(npm install stripe)
      ⎿  Install the Stripe SDK for the checkout session

    ──────────────────────────────────────────────────────────────────────────────
     Bash command
     Install the Stripe SDK for the checkout session
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     npm install stripe
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for npm install commands in
          /home/ubuntu/code/storefront-stripe-checkout
       3. No, and tell Claude what to do differently (esc)

     Esc to cancel · Tab to amend
    """

    static let questionScreenEN = """
    ● Which layout for the pricing page?

     ❯ 1. Three tiers
          Starter, Pro and Team side by side
       2. One plan
          One price, the features listed below
       3. A table
          Every feature against every plan
       4. Type something.
       5. Chat about this

      Enter to select · ↑↓ to move
    """

    static let finishedScreenEN = """
     ▐▛███▛█   Claude Code v2.1.293
    ▝▜██████▀  Opus 5.5 · Claude Max
     ▝▝   ▝▝   ~/code/billing-api-webhook-retries

    ❯ Fix webhook retries with exponential backoff. Retries fire every 2 s forever and
      hammer a customer's endpoint while it is down.

      Read 2 files, ran 2 shell commands

    ● Update(internal/webhooks/dispatch.go)
      ⎿  Added 64 lines, removed 31 lines

    ● Write(internal/webhooks/backoff.go)
      ⎿  Wrote 33 lines to internal/webhooks/backoff.go
          package webhooks

          import (
              "math/rand"
              "time"
          )
          …

    ● Update(internal/webhooks/dispatch_test.go)
      ⎿  Added 16 lines, removed 6 lines

    ● Bash(go test ./...)
      ⎿  ok   billing-api/internal/webhooks   2.41s
         ok   billing-api/internal/invoices   0.87s
         ok   billing-api/internal/api        1.12s

    ● Retries now back off exponentially instead of firing every 2 s.

      - backoff.go: Next(attempt) doubles from 1 s to a 10 min cap with ±20 % jitter,
        so a down endpoint is retried 8 times over about 20 minutes and then parked.
      - dispatch.go: the scheduler reads the delay from Next, records attempts and
        next_at on the delivery row, and gives up with a webhook.exhausted event.
      - dispatch_test.go: covers the schedule, the jitter bounds and the give-up path.

      go test ./... passes (41 tests). Nothing is committed yet — say the word and
      I'll open a pull request.

    ✻ Worked for 2m 14s · done 9:37 AM

    ────────────────────────────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle)
    """

    static let passkeysScreenEN = """
    ❯ Migrate auth to passkeys: registration and sign-in with ASAuthorization, keep
      password sign-in as a fallback behind a flag, and update the tests.

      Read 3 files, searched 2 patterns

    ● Update(MobileApp/Auth/AuthViewModel.swift)
      ⎿  Added 92 lines, removed 40 lines

    ● Write(MobileApp/Auth/PasskeyCoordinator.swift)
      ⎿  Wrote 118 lines to MobileApp/Auth/PasskeyCoordinator.swift

    ● Registration and sign-in go through PasskeyCoordinator now. Running the auth
      test plan in the background while I wire the password fallback.

    ● Bash(xcodebuild test -scheme MobileApp -only-testing:AuthTests)
    ✻ Simmering… (1m 12s · ↑ 3.1k tokens · esc to interrupt)
    """

    static let docsScreenEN = """
    › Write the release notes for 2.4 from the pull requests merged since 2.3. Keep the
      tone of the previous notes.

    • Ran gh pr list --state merged --base main --search "merged:>=2026-09-12"
      └ 23 pull requests
    • Read docs/releases/2.3.md
    • Editing docs/releases/2.4.md
    """

    // MARK: projects and worktrees

    static let locations = #"""
    [
     {"check": "pnpm test", "check_from": "detected", "default_branch": "main", "name": "storefront", "path": "/home/ubuntu/code/storefront",
      "remote": "https://github.com/acme/storefront.git", "repo": true, "repo_trust": "none", "scripts": {}, "slug": "acme/storefront",
      "worktrees": [
       {"branch": "main", "head": "9c2e41ab07", "main": true, "name": "storefront", "path": "/home/ubuntu/code/storefront", "port": 41010},
       {"branch": "feat/stripe-checkout", "head": "1b7d0c3e52", "name": "stripe-checkout", "path": "/home/ubuntu/code/storefront-stripe-checkout", "port": 41011},
       {"branch": "feat/pricing-page", "head": "7e55a1d9c0", "name": "pricing-page", "path": "/home/ubuntu/code/storefront-pricing-page", "port": 41012}
      ]},
     {"check": "go test ./...", "check_from": "detected", "default_branch": "main", "name": "billing-api", "path": "/home/ubuntu/code/billing-api",
      "remote": "https://github.com/acme/billing-api.git", "repo": true, "repo_trust": "none", "scripts": {}, "slug": "acme/billing-api",
      "worktrees": [
       {"branch": "main", "head": "4d0f8b2a61", "main": true, "name": "billing-api", "path": "/home/ubuntu/code/billing-api", "port": 41020},
       {"branch": "fix/webhook-retries", "head": "c3a9e7f014", "name": "webhook-retries", "path": "/home/ubuntu/code/billing-api-webhook-retries", "port": 41021}
      ]},
     {"check": "xcodebuild test -scheme MobileApp", "check_from": "detected", "default_branch": "main", "name": "mobile-app", "path": "/home/ubuntu/code/mobile-app",
      "remote": "https://github.com/acme/mobile-app.git", "repo": true, "repo_trust": "none", "scripts": {}, "slug": "acme/mobile-app",
      "worktrees": [
       {"branch": "main", "head": "e81b5c7d23", "main": true, "name": "mobile-app", "path": "/home/ubuntu/code/mobile-app", "port": 41030},
       {"branch": "feat/passkeys", "head": "5f6a2d8e90", "name": "passkeys", "path": "/home/ubuntu/code/mobile-app-passkeys", "port": 41031}
      ]},
     {"default_branch": "main", "name": "docs-site", "path": "/home/ubuntu/code/docs-site",
      "remote": "https://github.com/acme/docs-site.git", "repo": true, "repo_trust": "none", "scripts": {}, "slug": "acme/docs-site",
      "worktrees": [
       {"branch": "main", "head": "2a9c6e1f45", "main": true, "name": "docs-site", "path": "/home/ubuntu/code/docs-site", "port": 41040},
       {"branch": "docs/release-notes-2-4", "head": "b4e8d1a076", "name": "release-notes", "path": "/home/ubuntu/code/docs-site-release-notes", "port": 41041}
      ]}
    ]
    """#

    /// `GET /v1/worktrees`: every worktree with its git status (the finished worktree has the agent's uncommitted files).
    static func worktrees(location: String?) -> [JSON] {
        var out: [JSON] = []
        let locs = (try? JSONSerialization.jsonObject(with: Data(locations.utf8))) as? [JSON] ?? []
        for l in locs where location == nil || l["name"] as? String == location {
            for w in l["worktrees"] as? [JSON] ?? [] {
                let main = (w["main"] as? Bool) == true
                let name = w["name"] as? String ?? ""
                let branch = w["branch"] as? String ?? "main"
                var changed = 0, untracked = 0, sessions = 0
                switch name {
                case "webhook-retries": changed = 2; untracked = 1; sessions = 1
                case "passkeys": changed = 1; untracked = 1; sessions = 1
                case "release-notes": untracked = 1; sessions = 1
                case "stripe-checkout", "pricing-page": sessions = 1
                default: break
                }
                out.append(["ahead": 0, "behind": main ? 0 : 1, "branch": branch, "changed": changed, "location": l["name"] ?? "", "main": main,
                            "base": main ? "origin/main" : "main", "name": name, "path": w["path"] ?? "", "port": w["port"] ?? 0,
                            "sessions": sessions, "untracked": untracked])
            }
        }
        return out
    }

    static let services = #"""
    [
     {"location": "storefront", "worktree": "stripe-checkout", "path": "/home/ubuntu/code/storefront-stripe-checkout", "port": 41011, "process": "next dev", "main": false},
     {"location": "docs-site", "worktree": null, "path": "/home/ubuntu/code/docs-site", "port": 41040, "process": "mkdocs serve", "main": true}
    ]
    """#

    // MARK: review (changed files, diffs)

    static var review: String {
        let since = iso(ago: 240)
        return #"""
        [
         {"added": 113, "agent": "claude", "agent_state": "finished", "ahead": 0, "base": "main", "base_ahead": 0, "behind": 0, "branch": "fix/webhook-retries",
          "commits": [], "committed": [],
          "files": [
           {"added": 64, "code": " M", "path": "internal/webhooks/dispatch.go", "removed": 31},
           {"added": 33, "code": "??", "path": "internal/webhooks/backoff.go", "removed": 0},
           {"added": 16, "code": " M", "path": "internal/webhooks/dispatch_test.go", "removed": 6}
          ],
          "head": "c3a9e7f0143b9a2d0e7f1c5b6a8d9e0f1a2b3c4d", "location": "billing-api", "path": "/home/ubuntu/code/billing-api-webhook-retries",
          "removed": 37, "session": "\#(finished)", "state_since": "\#(since)", "worktree": "webhook-retries"},
         {"added": 210, "agent": "claude", "agent_state": "running", "ahead": 0, "base": "main", "base_ahead": 0, "behind": 0, "branch": "feat/passkeys",
          "commits": [], "committed": [],
          "files": [
           {"added": 92, "code": " M", "path": "MobileApp/Auth/AuthViewModel.swift", "removed": 40},
           {"added": 118, "code": "??", "path": "MobileApp/Auth/PasskeyCoordinator.swift", "removed": 0}
          ],
          "head": "5f6a2d8e90aa1b2c3d4e5f6a7b8c9d0e1f2a3b4c", "location": "mobile-app", "path": "/home/ubuntu/code/mobile-app-passkeys",
          "removed": 40, "session": "\#(passkeys)", "state_since": "\#(iso(ago: 720))", "worktree": "passkeys"},
         {"added": 74, "agent": "codex", "agent_state": "running", "ahead": 0, "base": "main", "base_ahead": 0, "behind": 0, "branch": "docs/release-notes-2-4",
          "commits": [], "committed": [],
          "files": [{"added": 74, "code": "??", "path": "docs/releases/2.4.md", "removed": 0}],
          "head": "b4e8d1a076bb1c2d3e4f5a6b7c8d9e0f1a2b3c4d", "location": "docs-site", "path": "/home/ubuntu/code/docs-site-release-notes",
          "removed": 0, "session": "\#(docs)", "state_since": "\#(iso(ago: 360))", "worktree": "release-notes"}
        ]
        """#
    }

    static func touched(location: String, worktree: String) -> JSON {
        guard location == "billing-api", worktree == "webhook-retries" else { return ["files": []] }
        let at = Int64(Date().addingTimeInterval(-250).timeIntervalSince1970 * 1000)
        return ["files": [
            ["added": 64, "agent": "claude", "at": at, "base": "turn", "path": "internal/webhooks/dispatch.go", "removed": 31, "session": finished],
            ["added": 33, "agent": "claude", "at": at + 1, "base": "turn", "created": true, "path": "internal/webhooks/backoff.go", "removed": 0, "session": finished],
            ["added": 16, "agent": "claude", "at": at + 2, "base": "turn", "path": "internal/webhooks/dispatch_test.go", "removed": 6, "session": finished],
        ]]
    }

    static let backoffLines: [String] = [
        "package webhooks", "", "import (", "\t\"math/rand\"", "\t\"time\"", ")", "", "const (", "\tbaseDelay = time.Second",
        "\tmaxDelay  = 10 * time.Minute", "\tmaxTries  = 8", "\tjitter    = 0.2", ")", "",
        "// Next returns how long to wait before attempt n (1-based), or false once",
        "// the delivery should be parked instead of retried again.",
        "func Next(attempt int) (time.Duration, bool) {", "\tif attempt < 1 || attempt > maxTries {", "\t\treturn 0, false", "\t}",
        "\td := baseDelay << uint(attempt-1)", "\tif d > maxDelay {", "\t\td = maxDelay", "\t}", "\treturn withJitter(d), true", "}", "",
        "// withJitter spreads retries so a fleet never hits an endpoint in lockstep.",
        "func withJitter(d time.Duration) time.Duration {", "\tspread := float64(d) * jitter",
        "\tdelta := (rand.Float64()*2 - 1) * spread", "\treturn time.Duration(float64(d) + delta)", "}",
    ]

    static var backoffDiff: String {
        "diff --git a/internal/webhooks/backoff.go b/internal/webhooks/backoff.go\nnew file mode 100644\nindex 0000000..3f1c2aa\n--- /dev/null\n+++ b/internal/webhooks/backoff.go\n@@ -0,0 +1,\(backoffLines.count) @@\n"
            + backoffLines.map { "+" + $0 }.joined(separator: "\n") + "\n"
    }

    static let dispatchDiff = """
    diff --git a/internal/webhooks/dispatch.go b/internal/webhooks/dispatch.go
    index 8a41c0e..b72e9d1 100644
    --- a/internal/webhooks/dispatch.go
    +++ b/internal/webhooks/dispatch.go
    @@ -41,11 +41,23 @@ func (d *Dispatcher) deliver(ctx context.Context, w Delivery) error {
     \tresp, err := d.client.Do(req)
     \tif err != nil || resp.StatusCode >= 500 {
    -\t\t// Try again in a moment.
    -\t\ttime.AfterFunc(2*time.Second, func() { d.queue <- w })
    -\t\treturn err
    +\t\tw.Attempts++
    +\t\tdelay, ok := Next(w.Attempts)
    +\t\tif !ok {
    +\t\t\td.events.Emit("webhook.exhausted", w.ID)
    +\t\t\treturn d.store.Park(ctx, w.ID, err)
    +\t\t}
    +\t\tw.NextAt = time.Now().Add(delay)
    +\t\tif err := d.store.Reschedule(ctx, w); err != nil {
    +\t\t\treturn err
    +\t\t}
    +\t\td.log.Info("webhook retry scheduled", "id", w.ID, "attempt", w.Attempts, "in", delay)
    +\t\treturn nil
     \t}
     \tdefer resp.Body.Close()
    -\treturn nil
    +\treturn d.store.MarkDelivered(ctx, w.ID, resp.StatusCode)
     }

    """

    static let testDiff = """
    diff --git a/internal/webhooks/dispatch_test.go b/internal/webhooks/dispatch_test.go
    index 1f3b7a9..9d2c4e8 100644
    --- a/internal/webhooks/dispatch_test.go
    +++ b/internal/webhooks/dispatch_test.go
    @@ -88,9 +88,19 @@ func TestDeliverRetries(t *testing.T) {
     \tsrv := failingServer(t, 3)
     \td := newDispatcher(t, srv.URL)
    -\td.deliver(ctx, delivery)
    -\tif got := srv.hits(); got != 4 {
    -\t\tt.Fatalf("hits = %d, want 4", got)
    -\t}
    +\tfor i := 0; i < 4; i++ {
    +\t\td.deliver(ctx, delivery)
    +\t\tclock.Advance(nextDelay(i + 1))
    +\t}
    +\tif got := srv.hits(); got != 4 {
    +\t\tt.Fatalf("hits = %d, want 4", got)
    +\t}
    +\tif got := d.store.attempts(delivery.ID); got != 3 {
    +\t\tt.Fatalf("attempts = %d, want 3", got)
    +\t}
    +\tif ev := d.events.last(); ev != "" {
    +\t\tt.Fatalf("unexpected event %q", ev)
    +\t}
     }

    """

    /// The diff for a file named in a request (a query, an `exec` command); dispatch.go when none is.
    static func diff(for request: String) -> String {
        if request.contains("backoff") { return backoffDiff }
        if request.contains("dispatch_test") { return testDiff }
        return dispatchDiff
    }

    static var prDiff: String { dispatchDiff + backoffDiff + testDiff }

    /// A tool's detail (`GET …/transcript/{id}/…`): the new file, as pierd describes an edit.
    static func toolDetail(name: String) -> JSON {
        ["file": "internal/webhooks/backoff.go", "id": "toolu_showcase_backoff", "name": "Write", "old": "",
         "new": backoffLines.joined(separator: "\n") + "\n",
         "hunks": [["lines": backoffLines.map { "+" + $0 }, "newLines": backoffLines.count, "newStart": 1, "oldLines": 0, "oldStart": 0]],
         "output": "The file /home/ubuntu/code/billing-api-webhook-retries/internal/webhooks/backoff.go has been created."]
    }

    // MARK: pull requests, CI, git activity (the Home's widgets and the pull request screen)

    static let repoBilling = "acme/billing-api"

    static func homePRs() -> JSON {
        func pr(_ n: Int, _ title: String, _ repo: String, _ author: String, _ decision: String, _ check: String, _ add: Int, _ del: Int, _ ago: TimeInterval) -> JSON {
            ["number": n, "title": title, "url": "https://github.com/\(repo)/pull/\(n)", "isDraft": false, "updatedAt": iso(ago: ago),
             "additions": add, "deletions": del, "reviewDecision": decision, "repository": ["nameWithOwner": repo], "author": ["login": author],
             "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": check]]]]]]
        }
        return ["viewer": "jordan",
                "review": [pr(184, prTitle, repoBilling, "mara", "REVIEW_REQUIRED", "SUCCESS", 222, 43, 2400)],
                "mine": [pr(171, t("Dark mode for the docs site", "Modo escuro no site de documentação"), "acme/docs-site", "jordan", "APPROVED", "SUCCESS", 310, 122, 10800)],
                "reviewCount": 1, "mineCount": 1]
    }

    static var prTitle: String { t("Paginate the invoices list", "Paginar a lista de faturas") }

    static var prBody: String { portuguese ? prBodyPT : prBodyEN }

    static let prBodyPT = """
    As faturas agora são paginadas no servidor, com um cursor opaco.

    ## O que muda
    - `GET /v2/invoices` aceita `limit` (padrão 50, máximo 200) e `cursor`
    - `next_cursor` volta enquanto houver mais linhas
    - O painel de admin carrega a próxima página conforme você rola

    ## Como testar
    1. Crie 1.000 faturas com `make seed-invoices`
    2. Abra **Cobrança → Faturas** e role a lista

    ```go
    page, err := invoices.List(ctx, invoices.Query{Limit: 50, Cursor: cur})
    ```
    """

    static let prBodyEN = """
    Invoices are paginated on the server now, with an opaque cursor.

    ## What changes
    - `GET /v2/invoices` takes `limit` (default 50, max 200) and `cursor`
    - `next_cursor` comes back while there are more rows
    - The admin UI loads the next page as you scroll

    ## How to test
    1. Seed 1,000 invoices with `make seed-invoices`
    2. Open **Billing → Invoices** and scroll

    ```go
    page, err := invoices.List(ctx, invoices.Query{Limit: 50, Cursor: cur})
    ```
    """

    static func prView(number: Int) -> JSON {
        let files: [JSON] = [
            ["path": "internal/invoices/list.go", "additions": 120, "deletions": 41, "changeType": "MODIFIED"],
            ["path": "internal/invoices/list_test.go", "additions": 88, "deletions": 0, "changeType": "ADDED"],
            ["path": "api/openapi.yaml", "additions": 14, "deletions": 2, "changeType": "MODIFIED"],
        ]
        let checks: [JSON] = [
            ["__typename": "CheckRun", "name": "lint", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://github.com/\(repoBilling)/actions/runs/1/job/1"],
            ["__typename": "CheckRun", "name": "test", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://github.com/\(repoBilling)/actions/runs/1/job/2"],
            ["__typename": "CheckRun", "name": "integration", "workflowName": "CI", "status": "IN_PROGRESS", "conclusion": "", "detailsUrl": "https://github.com/\(repoBilling)/actions/runs/1/job/3"],
            ["__typename": "StatusContext", "context": "deploy-preview", "state": "SUCCESS", "targetUrl": "https://preview.example.com/184"],
        ]
        return [
            "number": number, "title": prTitle, "body": prBody, "url": "https://github.com/\(repoBilling)/pull/\(number)",
            "state": "OPEN", "isDraft": false, "author": ["login": "mara", "name": "Mara", "is_bot": false],
            "baseRefName": "main", "headRefName": "feat/invoices-pagination",
            "headRepository": ["name": "billing-api", "nameWithOwner": repoBilling], "headRepositoryOwner": ["login": "acme"],
            "isCrossRepository": false, "maintainerCanModify": true, "createdAt": iso(ago: 86400), "updatedAt": iso(ago: 2400),
            "mergedAt": NSNull(), "closedAt": NSNull(), "additions": 222, "deletions": 43, "changedFiles": 3, "files": files, "statusCheckRollup": checks,
            "reviewDecision": "APPROVED",
            "reviews": [
                ["id": "PRR_1", "author": ["login": "theo"], "state": "APPROVED", "submittedAt": iso(ago: 1500),
                 "body": t("Nice — the opaque cursor is the right call. One nit: a `limit` over 200 should answer 400 rather than clamp (non-blocking).",
                          "Boa — o cursor opaco é a escolha certa. Um detalhe: um `limit` acima de 200 deveria responder 400 em vez de truncar (não bloqueia).")],
            ],
            "reviewRequests": [], "comments": [
                ["id": "IC_1", "author": ["login": "mara"], "createdAt": iso(ago: 2400), "body": t("Rebased on main and added the OpenAPI entry.", "Fiz rebase na main e adicionei a entrada no OpenAPI.")],
            ],
            "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
            "labels": [["name": "api", "color": "1D76DB"], ["name": t("performance", "desempenho"), "color": "0E8A16"]],
        ]
    }

    /// `# pier-home:ci`: one JSON line per repo; the mobile app's test workflow failed on the passkeys branch.
    static func ciOutput() -> String {
        let fail: JSON = ["repo": "acme/mobile-app", "runs": [[
            "databaseId": 9_182_736, "workflowName": t("iOS tests", "Testes iOS"), "displayTitle": titlePasskeys, "headBranch": "feat/passkeys",
            "status": "completed", "conclusion": "failure", "createdAt": iso(ago: 1200), "url": "https://github.com/acme/mobile-app/actions/runs/9182736"]]]
        let lines: [JSON] = [["repo": "acme/storefront", "runs": []], ["repo": "acme/billing-api", "runs": []], fail, ["repo": "acme/docs-site", "runs": []]]
        return lines.map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0)) ?? Data(), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }

    /// `# pier-home:git`: `projectIndex dayNumber commits added removed`, the last two weeks, quiet weekends.
    static func gitActivity(command: String) -> String {
        var offset = 0
        if let r = command.range(of: #"off=(-?\d+)"#, options: .regularExpression) {
            offset = Int(command[r].dropFirst(4)) ?? 0
        }
        let today = Int((Date().timeIntervalSince1970 + Double(offset)) / 86400)
        let commits: [[Int]] = [
            [3, 5, 2, 0, 0, 6, 4, 7, 3, 1, 0, 0, 5, 8],
            [1, 2, 4, 0, 0, 2, 3, 2, 5, 2, 0, 0, 3, 4],
            [0, 1, 3, 0, 0, 4, 2, 1, 2, 4, 0, 0, 2, 3],
            [2, 0, 1, 0, 0, 1, 2, 0, 1, 1, 0, 0, 1, 2],
        ]
        var lines: [String] = []
        for (p, days) in commits.enumerated() {
            for (k, c) in days.enumerated() where c > 0 {
                let day = today - (days.count - 1 - k)
                lines.append("\(p) \(day) \(c) \(c * 37 + p * 11) \(c * 14 + p * 3)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: the AI touches (what `claude -p --model haiku` would answer on the box)

    static var nextSteps: String {
        portuguese ? #"{"replies":["Abrir um pull request","Mostrar o diff"]}"# : #"{"replies":["Open a pull request","Show me the diff"]}"#
    }

    static var aiDraft: String { portuguese ? aiDraftPT : aiDraftEN }

    static let aiDraftPT = """
    <<<COMMIT
    Retentar webhooks com backoff exponencial

    - Next(attempt) dobra de 1 s até um teto de 10 min, com jitter
    - Entregas ficam estacionadas após 8 tentativas, com um evento webhook.exhausted
    - Testes para o agendamento, os limites do jitter e a desistência
    >>>
    <<<TITLE
    Retentar webhooks com backoff exponencial
    >>>
    <<<BODY
    ## Resumo
    - Troca o loop fixo de retry a cada 2 s por backoff exponencial com jitter
    - Estaciona a entrega após 8 tentativas e emite `webhook.exhausted`

    ## Plano de testes
    - `go test ./...` (41 testes)
    >>>
    """

    static let aiDraftEN = """
    <<<COMMIT
    Retry webhooks with exponential backoff

    - Next(attempt) doubles from 1 s to a 10 min cap, with jitter
    - Deliveries park after 8 attempts with a webhook.exhausted event
    - Tests for the schedule, the jitter bounds and the give-up path
    >>>
    <<<TITLE
    Retry webhooks with exponential backoff
    >>>
    <<<BODY
    ## Summary
    - Replaces the fixed 2 s retry loop with exponential backoff and jitter
    - Parks a delivery after 8 attempts and emits `webhook.exhausted`

    ## Test plan
    - `go test ./...` (41 tests)
    >>>
    """

    /// A title for a new task: its first words, as the model would shorten them.
    static func aiTitle(prompt: String) -> String {
        var task = prompt
        if let r = prompt.range(of: "The task:") { task = String(prompt[r.upperBound...]) }
        let words = task.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(6).map(String.init)
        var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        if let f = title.first { title = f.uppercased() + title.dropFirst() }
        return title.isEmpty ? t("New task", "Nova tarefa") : title
    }

    /// Talk's routing: the agent already on that work, a new task, or a question back.
    static func talkDecision(prompt: String) -> JSON {
        var request = prompt
        if let a = prompt.range(of: "<<<\n"), let b = prompt.range(of: "\n>>>", range: a.upperBound..<prompt.endIndex) {
            request = String(prompt[a.upperBound..<b.lowerBound])
        }
        let r = request.lowercased()
        func send(_ session: String) -> JSON { ["action": "send", "box": "devbox", "session": session, "text": request.trimmingCharacters(in: .whitespacesAndNewlines)] }
        if r.contains("pricing") || r.contains("plan") && r.contains("page") || r.contains("preço") || r.contains("página de planos") { return send(question) }
        if r.contains("stripe") || r.contains("checkout") { return send(permission) }
        if r.contains("webhook") || r.contains("retr") { return send(finished) }
        if r.contains("passkey") || r.contains("sign-in") || r.contains("sign in") || r.contains("auth") || r.contains("login") { return send(passkeys) }
        if r.contains("release") || r.contains("docs") || r.contains("notes") || r.contains("notas") || r.contains("versão") { return send(docs) }
        if r.contains("onboarding") { return send(chat) }
        if r.hasPrefix("start ") || r.hasPrefix("new ") || r.hasPrefix("create ") || r.contains("new task")
            || r.hasPrefix("comece ") || r.hasPrefix("crie ") || r.contains("nova tarefa") {
            return ["action": "new_task", "box": "devbox", "location": "storefront", "prompt": request, "title": aiTitle(prompt: request)]
        }
        return ["action": "ask", "question": t("Which project is that for: storefront, billing-api, mobile-app or docs-site?",
                                               "Para qual projeto é isso: storefront, billing-api, mobile-app ou docs-site?")]
    }
}

// MARK: - Widgets and Live Activities (the debug gallery, in the showcase's language)

extension WidgetSnapshot {
    static var showcase: WidgetSnapshot {
        let now = Date()
        func s(_ name: String, _ title: String, _ project: String, _ agent: String, _ st: WState, _ ago: TimeInterval, ask: String? = nil) -> WSession {
            WSession(box: "devbox", name: name, title: title, project: project, agent: agent, state: st, since: now.addingTimeInterval(-ago), ask: ask)
        }
        typealias U = UITestShowcase
        return WidgetSnapshot(updated: now, boxes: [WBox(name: "devbox", online: true)], sessions: [
            s(U.permission, U.titlePermission, "storefront · stripe-checkout", "claude", .needsYou, 180, ask: "Bash  npm install stripe"),
            s(U.question, U.titleQuestion, "storefront · pricing-page", "claude", .needsYou, 60, ask: "AskUserQuestion  " + U.questionText),
            s(U.passkeys, U.titlePasskeys, "mobile-app · passkeys", "claude", .working, 720),
            s(U.docs, U.titleDocs, "docs-site · release-notes", "codex", .working, 360),
            s(U.finished, U.titleFinished, "billing-api · webhook-retries", "claude", .done, 240),
            s(U.chat, U.titleChat, U.t("Chat", "Conversa"), "claude", .done, 1500),
            s("storefront-search-claude-2b9e", U.t("Speed up product search", "Acelerar a busca de produtos"), "storefront · search", "claude", .done, 5400),
        ])
    }
}

extension SessionActivityAttributes {
    static func showcase(_ session: String, _ title: String, _ project: String, agent: String = "claude") -> SessionActivityAttributes {
        .init(box: "devbox", session: session, title: title, project: project, agent: agent)
    }
}

/// The Live Activity states the gallery renders, each with the session it belongs to.
struct ActivitySamples {
    typealias Sample = (attrs: SessionActivityAttributes, state: ActivityContentState)
    var running: Sample
    var waiting: Sample
    var question: Sample
    var finished: Sample

    static var standard: ActivitySamples {
        let a = SessionActivityAttributes.sample
        return .init(running: (a, .sampleRunning), waiting: (a, .sampleWaiting), question: (a, .sampleQuestion), finished: (a, .sampleFinished))
    }

    static var showcase: ActivitySamples {
        typealias U = UITestShowcase
        return .init(
            running: (.showcase(U.passkeys, U.titlePasskeys, "mobile-app · passkeys"),
                      .init(phase: .running, since: Date().addingTimeInterval(-754), step: U.t("Running xcodebuild test -scheme MobileApp…", "Rodando xcodebuild test -scheme MobileApp…"),
                            ask: nil, hasMenu: false)),
            waiting: (.showcase(U.permission, U.titlePermission, "storefront · stripe-checkout"),
                      .init(phase: .waiting, since: Date().addingTimeInterval(-42), step: nil, ask: "Bash  npm install stripe", hasMenu: true)),
            question: (.showcase(U.question, U.titleQuestion, "storefront · pricing-page"),
                       .init(phase: .waiting, since: Date().addingTimeInterval(-20), step: nil, ask: U.questionText, hasMenu: false, choices: 3)),
            finished: (.showcase(U.finished, U.titleFinished, "billing-api · webhook-retries"),
                       .init(phase: .finished, since: Date().addingTimeInterval(-60), step: nil, ask: nil, hasMenu: false, added: 113, removed: 37,
                             reply: U.t("Retries back off exponentially now — 1 s to 10 min with jitter, parked after 8 attempts. 41 tests pass.",
                                        "Os retries agora usam backoff exponencial — de 1 s a 10 min, com jitter, e param após 8 tentativas. 41 testes passam.")))
        )
    }
}
#endif
