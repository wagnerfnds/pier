import Foundation

/// The mock box's terminals (`-uiTestMock 1`): a shell per session started without an agent, its pane as tmux hands it
/// over (`GET …/screen`): a prompt in the worktree's folder (`ubuntu@devbox:~/code/sandbox-subtract$`), each line typed
/// after it and what a shell would answer to `ls`, `pwd`, `git status`, `git log`, the tests, `echo`, `cd`, `clear`. A dev
/// server (`npm run dev` and the like) keeps running until ⌃C, `sleep` until its time is up, and `exit` ends the session;
/// anything else runs quietly, as most commands do. A session started with a command runs only that, and ends with it.
struct MockTerminals {
    private struct Shell {
        static let home = "/home/ubuntu"
        /// The worktree's branch (its name; "main" for a main checkout).
        let branch: String
        let main: Bool
        /// Started with a command: the session ends with it (pierd runs it through `$SHELL -lc`).
        let oneCommand: Bool
        var dir: String
        var lines: [String] = []
        /// A program in the foreground (a dev server, a `sleep`): what is typed goes to it, ⌃C stops it.
        var running: String?
        /// When the program in the foreground ends by itself.
        var until: Date?
        var exited = false

        var prompt: String {
            let shown = dir == Self.home ? "~" : dir.hasPrefix(Self.home + "/") ? "~" + dir.dropFirst(Self.home.count) : dir
            return "ubuntu@devbox:\(shown)$ "
        }
    }

    private var shells: [String: Shell] = [:]

    func has(_ name: String) -> Bool { shells[name] != nil }
    func exited(_ name: String) -> Bool { shells[name]?.exited == true }

    /// pierd's name for a session it names itself: `<location>-<program>-<seconds, base 36>`.
    static func defaultName(location: String, command: String?) -> String {
        let program = command?.split(separator: " ").first.map { String($0.split(separator: "/").last ?? $0) } ?? "shell"
        var name = (location + "-" + program).replacingOccurrences(of: #"[^A-Za-z0-9_-]+"#, with: "-", options: .regularExpression)
        if name.count > 48 { name = String(name.prefix(48)) }
        return name + "-" + String(Int(Date().timeIntervalSince1970) % 100_000, radix: 36)
    }

    /// A new shell for `ref` ("loc" or "loc/wt") in `dir`; with `command`, only that command, the session ending with it.
    mutating func start(_ name: String, ref: String, dir: String, command: String?) {
        let wt = ref.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init)
        var s = Shell(branch: wt ?? "main", main: wt == nil, oneCommand: command != nil, dir: dir)
        if let command { run(command, in: &s) }
        shells[name] = s
    }

    mutating func remove(_ name: String) { shells[name] = nil }

    /// The pane as `GET …/screen` gives it: what was printed (the last 300 lines), and the prompt when the shell waits.
    mutating func screen(_ name: String) -> String {
        guard var s = shells[name] else { return "" }
        settle(&s)
        shells[name] = s
        let tail = s.running == nil && !s.exited && !s.oneCommand ? [s.prompt] : []
        return (s.lines + tail).suffix(300).joined(separator: "\n")
    }

    /// A line typed (`send`): at the prompt the shell runs it; to a program in front it is only echoed.
    mutating func type(_ name: String, text: String, enter: Bool) {
        guard var s = shells[name], !s.exited else { return }
        settle(&s)
        // Pasted without Enter, the shell waits for the rest of the line (not drawn here).
        if enter {
            if s.running != nil || s.oneCommand {
                s.lines.append(text)
            } else {
                s.lines.append(s.prompt + text)
                run(text, in: &s)
            }
        }
        shells[name] = s
    }

    /// Keys (`POST …/keys`): ⌃C stops the program in front (or drops the line at the prompt), Enter is an empty line.
    mutating func press(_ name: String, keys: [String]) {
        guard var s = shells[name], !s.exited else { return }
        settle(&s)
        for key in keys {
            switch key.lowercased() {
            case "interrupt":
                if s.running != nil {
                    s.lines.append("^C")
                    s.running = nil
                    s.until = nil
                    if s.oneCommand { s.exited = true }
                } else if !s.oneCommand {
                    s.lines.append(s.prompt + "^C")
                }
            case "enter":
                s.lines.append(s.running != nil || s.oneCommand ? "" : s.prompt)
            default:
                break
            }
        }
        shells[name] = s
    }

    /// A program whose time is up ends: the prompt comes back (a command session ends with it).
    private func settle(_ s: inout Shell) {
        guard let until = s.until, Date() >= until else { return }
        s.running = nil
        s.until = nil
        if s.oneCommand { s.exited = true }
    }

    // MARK: the shell

    private func run(_ line: String, in s: inout Shell) {
        let command = line.trimmingCharacters(in: .whitespaces)
        let words = command.split(separator: " ").map(String.init)
        guard let first = words.first else { return }
        let rest = Array(words.dropFirst())
        switch first {
        case "clear": s.lines = []
        case "exit", "logout": s.lines.append("logout"); s.exited = true
        case "pwd": s.lines.append(s.dir)
        case "whoami": s.lines.append("ubuntu")
        case "echo": s.lines.append(rest.joined(separator: " ").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: ""))
        case "date": s.lines.append(Self.date())
        case "cd": cd(rest.first, in: &s)
        case "ls": s.lines.append(s.main ? "README.md  assets  calc.py  docs  node_modules  notes.txt  src  test_calc.py"
                                         : "README.md  assets  calc.py  docs  node_modules  probe_dir  src  test_calc.py")
        case "git": git(rest, in: &s)
        case "sleep":
            s.running = command
            s.until = Date().addingTimeInterval(Double(rest.first ?? "1") ?? 1)
        case "pytest": tests(in: &s)
        case "python", "python3":
            if rest.starts(with: ["-m", "pytest"]) { tests(in: &s) }
            if rest.starts(with: ["-m", "http.server"]) {
                let port = rest.count > 2 ? rest[2] : "8000"
                s.lines.append("Serving HTTP on 0.0.0.0 port \(port) (http://0.0.0.0:\(port)/) ...")
                s.running = command
            }
        case "npm", "pnpm", "yarn", "bun":
            switch (rest.first == "run" ? rest.dropFirst().first : rest.first) ?? "" {
            case "dev", "start", "serve": devServer(command, in: &s)
            case "test", "t": tests(in: &s)
            case "install", "i", "ci", "":
                s.lines += ["", "added 212 packages, and audited 213 packages in 3s", "", "38 packages are looking for funding",
                            "  run `npm fund` for details", "", "found 0 vulnerabilities"]
            default: break
            }
        default: break
        }
    }

    private func cd(_ to: String?, in s: inout Shell) {
        switch to {
        case nil, "~": s.dir = Shell.home
        case "..": s.dir = (s.dir as NSString).deletingLastPathComponent
        case let p? where p.hasPrefix("/"): s.dir = p
        case let p? where p.hasPrefix("~/"): s.dir = Shell.home + p.dropFirst()
        case let p?: s.dir = (s.dir as NSString).appendingPathComponent(p)
        }
    }

    private func git(_ args: [String], in s: inout Shell) {
        switch args.first {
        case "status":
            if args.contains("--short") || args.contains("-s") {
                s.lines += s.main ? ["?? notes.txt"] : [" M calc.py", "?? probe_dir/"]
            } else if s.main {
                s.lines += ["On branch main", "Your branch is behind 'origin/main' by 2 commits, and can be fast-forwarded.", "",
                            "Untracked files:", "  (use \"git add <file>...\" to include in what will be committed)", "\tnotes.txt", "",
                            "nothing added to commit but untracked files present (use \"git add\" to track)"]
            } else {
                s.lines += ["On branch \(s.branch)", "Changes not staged for commit:", "  (use \"git add <file>...\" to update what will be committed)",
                            "\tmodified:   calc.py", "", "Untracked files:", "\tprobe_dir/", "",
                            "no changes added to commit (use \"git add\" and/or \"git commit -a\")"]
            }
        case "log":
            if !s.main { s.lines.append("5337933 (HEAD -> \(s.branch)) Add subtract() to calc.py with a test") }
            s.lines += ["ae6d879 (\(s.main ? "HEAD -> main, " : "")origin/main, main) Format the totals with two decimals",
                        "1b2c3d4 (tag: v0.2.0) Add the guide and the logo", "1df1e2d Fix a typo in the README"]
        case "branch":
            s.lines += s.main ? ["* main", "  subtract"] : ["  main", "* \(s.branch)"]
        default: break
        }
    }

    private func tests(in s: inout Shell) {
        let n = s.main ? 1 : 2
        s.lines += ["============================= test session starts ==============================",
                    "platform linux -- Python 3.12.3, pytest-8.3.2, pluggy-1.5.0", "rootdir: \(s.dir)", "collected \(n) item\(n == 1 ? "" : "s")", "",
                    "test_calc.py \(String(repeating: ".", count: n))" + String(repeating: " ", count: 59 - n) + "[100%]", "",
                    "============================== \(n) passed in 0.02s ==============================="]
    }

    private func devServer(_ command: String, in s: inout Shell) {
        let package = (s.dir as NSString).lastPathComponent
        s.lines += ["", "> \(package)@0.1.0 dev", "> vite --port 41010", "", "",
                    "  VITE v5.4.2  ready in 312 ms", "", "  ➜  Local:   http://localhost:41010/", "  ➜  Network: use --host to expose"]
        s.running = command
    }

    /// `date`'s own words: "Wed Oct 14 09:12:03 UTC 2026".
    private static func date() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
        return f.string(from: Date())
    }
}
