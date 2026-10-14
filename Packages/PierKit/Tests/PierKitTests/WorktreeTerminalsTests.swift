import Foundation
import Testing

@testable import PierKit

/// The session screen's terminal tabs: which sessions are a worktree's terminals, what their tabs say, what runs in one.
@Suite struct WorktreeTerminalsTests {
    private func s(_ name: String, location: String? = "sandbox/subtract", dir: String = "/home/ubuntu/code/sandbox-subtract",
                   agent: String? = nil, command: String? = nil, title: String? = nil, service: String? = nil, chat: Bool = false,
                   exited: Bool = false, at: TimeInterval = 1_000) -> Session {
        Session(name: name, location: location, dir: dir, command: command, created: Date(timeIntervalSince1970: at), exited: exited,
                agent: agent, title: title, service: service, chat: chat)
    }

    private let paths = ["/home/ubuntu/code/sandbox", "/home/ubuntu/code/sandbox-subtract", "/home/ubuntu/code/sandbox/.worktrees/nested"]

    @Test func terminalsAreShellsAndCommandsOnly() {
        #expect(WorktreeTerminals.isTerminal(s("sh")))
        #expect(WorktreeTerminals.isTerminal(s("dev", command: "npm run dev")))
        #expect(!WorktreeTerminals.isTerminal(s("agent", agent: "claude", command: "claude --model opus")))
        // An agent started as a bare command (an older box), a service's terminal, a chat: not terminals.
        #expect(!WorktreeTerminals.isTerminal(s("bare", command: "/usr/local/bin/codex")))
        #expect(!WorktreeTerminals.isTerminal(s("svc", command: "npm run dev", service: "dev")))
        #expect(!WorktreeTerminals.isTerminal(s("chat", location: nil, dir: "/home/ubuntu/pier/chats/x", agent: "claude", chat: true)))
    }

    @Test func aWorktreesTerminalsOldestFirst() {
        let all = [
            s("newer", at: 3_000),
            s("older", at: 1_000),
            s("agent", agent: "claude", at: 500),
            s("main", location: "sandbox", dir: "/home/ubuntu/code/sandbox"),
            s("other", location: "acme-web", dir: "/home/ubuntu/code/acme-web"),
            s("same-time-b", at: 2_000),
            s("same-time-a", at: 2_000),
        ]
        let got = WorktreeTerminals.sessions(all, ref: "sandbox/subtract", path: "/home/ubuntu/code/sandbox-subtract", paths: paths)
        #expect(got.map(\.name) == ["older", "same-time-a", "same-time-b", "newer"])
        let main = WorktreeTerminals.sessions(all, ref: "sandbox", path: "/home/ubuntu/code/sandbox", paths: paths)
        #expect(main.map(\.name) == ["main"])
    }

    @Test func noLocationGoesByTheClosestFolder() {
        let all = [
            s("in-sub", location: nil, dir: "/home/ubuntu/code/sandbox-subtract/web"),
            s("in-main", location: "", dir: "/home/ubuntu/code/sandbox/"),
            s("in-nested", location: nil, dir: "/home/ubuntu/code/sandbox/.worktrees/nested/src"),
            s("home", location: "", dir: "/home/ubuntu"),
        ]
        // "sandbox-subtract" is not inside "sandbox"; the nested worktree holds its folder more closely than the main one.
        #expect(WorktreeTerminals.sessions(all, ref: "sandbox", path: "/home/ubuntu/code/sandbox", paths: paths).map(\.name) == ["in-main"])
        #expect(WorktreeTerminals.sessions(all, ref: "sandbox/subtract", path: "/home/ubuntu/code/sandbox-subtract", paths: paths).map(\.name) == ["in-sub"])
        #expect(WorktreeTerminals.sessions(all, ref: "sandbox/nested", path: "/home/ubuntu/code/sandbox/.worktrees/nested/", paths: paths).map(\.name) == ["in-nested"])
    }

    @Test func labels() {
        let shell = WorktreeTerminals.runningCommand(in: "ubuntu@devbox:~/code/sandbox-subtract$ ls\ncalc.py\nubuntu@devbox:~/code/sandbox-subtract$ ")
        let serving = WorktreeTerminals.runningCommand(in: "ubuntu@devbox:~/code/sandbox-subtract$ npm run dev\n\n  VITE v5.4.2  ready in 312 ms\n\n  ➜  Local:   http://localhost:41010/\n")
        #expect(shell == nil && serving == "npm run dev")
        // A name of the person's wins over what runs.
        #expect(WorktreeTerminals.label(s("a", title: "API"), position: 1, running: serving) == .named("API"))
        // The app's own title gives way to what runs, and comes back when the prompt does.
        #expect(WorktreeTerminals.label(s("a", title: "Terminal 2"), position: 1, running: serving) == .command("npm run dev"))
        #expect(WorktreeTerminals.label(s("a", title: "Terminal 2"), position: 1, running: shell) == .numbered(2))
        // Untitled: its place; started with a command: the command.
        #expect(WorktreeTerminals.label(s("a"), position: 3, running: nil) == .numbered(3))
        #expect(WorktreeTerminals.label(s("a", command: "npm run build"), position: 1, running: nil) == .command("npm run build"))
        #expect(WorktreeTerminals.label(s("a", command: "npm run build"), position: 1, running: "") == .command("npm run build"))
        // An exited one runs nothing, whatever its last screen showed.
        #expect(WorktreeTerminals.label(s("a", title: "Terminal 1", exited: true), position: 1, running: serving) == .numbered(1))
    }

    @Test func defaultTitles() {
        #expect(WorktreeTerminals.defaultTitle(3) == "Terminal 3")
        #expect(WorktreeTerminals.number(inTitle: "Terminal 3") == 3)
        #expect(WorktreeTerminals.number(inTitle: " Terminal 12 ") == 12)
        #expect(WorktreeTerminals.number(inTitle: "Terminal") == nil)
        #expect(WorktreeTerminals.number(inTitle: "Terminal 0") == nil)
        #expect(WorktreeTerminals.number(inTitle: "Terminal two") == nil)
        #expect(WorktreeTerminals.number(inTitle: "API server") == nil)
        #expect(WorktreeTerminals.number(inTitle: nil) == nil)
    }

    @Test func nextNumberTakesTheFirstFree() {
        #expect(WorktreeTerminals.nextNumber([]) == 1)
        #expect(WorktreeTerminals.nextNumber([s("a", title: "Terminal 1"), s("b", title: "Terminal 3")]) == 2)
        // An untitled one shows its place; a named one or one with a command shows no number.
        #expect(WorktreeTerminals.nextNumber([s("a"), s("b", title: "Terminal 2"), s("c", title: "API"), s("d", command: "top")]) == 3)
    }

    @Test func sessionNameWhenTheBoxsIsTaken() {
        #expect(WorktreeTerminals.sessionName(location: "sandbox/subtract", suffix: "k3x9") == "sandbox-subtract-shell-k3x9")
        #expect(WorktreeTerminals.sessionName(location: ".dotfiles", suffix: "a") == "dotfiles-shell-a")
        #expect(WorktreeTerminals.sessionName(location: "", suffix: "a") == "term-shell-a")
        let long = WorktreeTerminals.sessionName(location: String(repeating: "x", count: 90), suffix: "abc")
        #expect(long.count <= 63 && long.hasSuffix("-shell-abc"))
    }

    @Test func runningCommandFromTheScreen() throws {
        // Captured from pierd (a shell after `echo hi`): back at the prompt.
        #expect(WorktreeTerminals.runningCommand(in: try Fixture.screen("screen_shell.json")) == nil)
        let dev = """
        ubuntu@devbox:~/code/sandbox-subtract$ git status --short
         M calc.py
        ubuntu@devbox:~/code/sandbox-subtract$ npm run dev

        > sandbox@0.1.0 dev
        > vite --port 41010

          VITE v5.4.2  ready in 312 ms
          ➜  Local:   http://localhost:41010/


        """
        #expect(WorktreeTerminals.runningCommand(in: dev) == "npm run dev")
        // Typed and not answered yet (the command's first output still to come).
        #expect(WorktreeTerminals.runningCommand(in: "ubuntu@devbox:~$ sleep 30") == "sleep 30")
        // Stopped with ⌃C: the prompt is back.
        #expect(WorktreeTerminals.runningCommand(in: dev + "^C\nubuntu@devbox:~/code/sandbox-subtract$ \n") == nil)
        // Output without a line break at its end, then the prompt on the same line.
        #expect(WorktreeTerminals.runningCommand(in: "ubuntu@devbox:~$ printf done\ndoneubuntu@devbox:~$ ") == nil)
        // Nothing that reads as a prompt (a full-screen program): no guess.
        #expect(WorktreeTerminals.runningCommand(in: "  PID USER      PR  NI    VIRT    RES\n 1201 ubuntu    20   0  1.2g  88m") == nil)
        #expect(WorktreeTerminals.runningCommand(in: "") == nil)
        #expect(WorktreeTerminals.runningCommand(in: "\n\n  \n") == nil)
    }

    @Test func promptShapes() {
        let cases: [(String, String?)] = [
            ("ubuntu@devbox:~/code/sandbox$ npm test", "npm test"),
            ("ubuntu@devbox:~/code/sandbox$", ""),
            ("ubuntu@devbox:~/code/sandbox$   ", ""),
            ("root@devbox:/srv/app# systemctl status nginx", "systemctl status nginx"),
            ("[ubuntu@devbox sandbox]$ make", "make"),
            ("ubuntu@devbox ~/code/sandbox> cargo run", "cargo run"),
            ("ubuntu@devbox ~ % ls -la", "ls -la"),
            ("devbox% ls", "ls"),
            ("$ echo \"a > b\"", "echo \"a > b\""),
            ("❯ pnpm dev", "pnpm dev"),
            ("❯", ""),
            ("➜  sandbox git:(main) ✗ go run .", "go run ."),
            ("➜  sandbox git:(main)", ""),
            ("➜  sandbox python3 -m http.server", "python3 -m http.server"),
            // Not prompts: output that only looks a little like one.
            ("100% done", nil),
            ("  ➜  Local:   http://localhost:41010/", nil),
            (" ❯ 1. Yes", nil),
            ("git@github.com: Permission denied (publickey).", nil),
            ("# Title", nil),
            ("> vite --port 41010", nil),
        ]
        for (line, want) in cases {
            #expect(WorktreeTerminals.promptInput(line) == want, "\(line)")
        }
    }
}
