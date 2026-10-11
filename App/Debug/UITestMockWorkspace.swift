import CryptoKit
import Foundation
import PierKit

/// The mock box's worktree files and history (`-uiTestMock 1`): an in-memory tree per worktree answering
/// `GET …/files`, `GET`/`PUT …/file` like pierd (sha checks, `create`, 409 `file_changed`), and the workspace's exec
/// commands (`GitLog`, `FileSearch`) with a small history. A save marks the file changed, as git would.
struct MockWorkspace {
    typealias JSON = [String: Any]

    private struct File {
        var data: Data
        /// git's porcelain code, nil when clean.
        var status: String?
        var modified = Date().addingTimeInterval(-3600)
    }

    private var trees: [String: [String: File]] = [:]

    /// Paths git ignores in every worktree (shown faint, never searched).
    private static let ignored = ["node_modules", "__pycache__", ".env"]

    /// `GET/PUT /v1/locations/{l}/worktrees/{w}/files|file`; nil for any other path.
    mutating func route(_ method: BoxClient.Method, _ p: [String], _ query: [String: String], _ body: Data?) -> (Int, Data)? {
        guard p.count == 6, p[1] == "locations", p[3] == "worktrees", p[5] == "files" || p[5] == "file" else { return nil }
        let key = "\(p[2])/\(p[4])"
        seed(key, location: p[2], worktree: p[4])
        let path = (query["path"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // As pierd: a ".." or a ".git" component (".gitignore" and ".github/" are files like any other).
        if path.split(separator: "/").contains(where: { $0 == ".." || $0 == ".git" }) {
            return (400, Self.json(["error": "\(path) is not in this worktree", "code": "bad_request"]))
        }
        switch (method, p[5]) {
        case (.get, "files"): return list(key, dir: path == "." ? "" : path)
        case (.get, "file"): return read(key, path: path, stat: query["stat"] == "1")
        case (.put, "file"): return write(key, path: path, body: body)
        default: return (404, Self.json(["error": "not found", "code": "not_found"]))
        }
    }

    private func list(_ key: String, dir: String) -> (Int, Data) {
        let files = trees[key] ?? [:]
        let prefix = dir.isEmpty ? "" : dir + "/"
        guard dir.isEmpty || files.keys.contains(where: { $0.hasPrefix(prefix) }) else {
            if files[dir] != nil { return (400, Self.json(["error": "\(dir) is a file, not a folder", "code": "bad_request"])) }
            return (404, Self.json(["error": "\(dir) not found", "code": "not_found"]))
        }
        var dirs: [String: Bool] = [:]   // name -> changed
        var entries: [JSON] = []
        for (path, f) in files where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                let name = String(rest[..<slash])
                dirs[name] = (dirs[name] ?? false) || (f.status != nil && !Self.isIgnored(path))
            } else {
                var e: JSON = ["name": String(rest), "type": "file", "size": f.data.count]
                if let s = f.status { e["status"] = s }
                if Self.isIgnored(path) { e["ignored"] = true }
                entries.append(e)
            }
        }
        var out: [JSON] = dirs.keys.sorted { $0.lowercased() < $1.lowercased() }.map { name in
            var e: JSON = ["name": name, "type": "dir"]
            if dirs[name] == true { e["changed"] = true }
            if Self.isIgnored(prefix + name) { e["ignored"] = true }
            return e
        }
        out += entries.sorted { ($0["name"] as! String).lowercased() < ($1["name"] as! String).lowercased() }
        return (200, Self.json(["path": dir, "entries": out, "truncated": false]))
    }

    private func read(_ key: String, path: String, stat: Bool) -> (Int, Data) {
        guard let f = trees[key]?[path] else {
            if trees[key]?.keys.contains(where: { $0.hasPrefix(path + "/") }) == true {
                return (400, Self.json(["error": "\(path) is a folder", "code": "bad_request"]))
            }
            return (404, Self.json(["error": "\(path) not found", "code": "not_found"]))
        }
        return (200, Self.json(Self.meta(path, f, content: !stat)))
    }

    private mutating func write(_ key: String, path: String, body: Data?) -> (Int, Data) {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        let text = req["content"] as? String ?? ""
        let data = req["encoding"] as? String == "base64" ? (Data(base64Encoded: text) ?? Data()) : Data(text.utf8)
        let force = req["force"] as? Bool == true
        let create = req["create"] as? Bool == true
        var files = trees[key] ?? [:]
        if let f = files[path] {
            if create && !force { return (409, Self.json(["error": "\(path) already exists", "code": "file_exists"])) }
            if !force && !create && (req["sha"] as? String) != Self.sha(f.data) {
                return (409, Self.json(["error": "the file changed on the box since you opened it", "code": "file_changed"]))
            }
        } else if !create && !force && (req["sha"] as? String).map({ !$0.isEmpty }) == true {
            return (409, Self.json(["error": "the file changed on the box since you opened it: it was deleted on the box", "code": "file_changed"]))
        }
        let was = files[path]
        let status = was == nil ? "??" : (was?.status ?? " M")
        files[path] = File(data: data, status: status, modified: Date())
        trees[key] = files
        return (200, Self.json(Self.meta(path, files[path]!, content: false)))
    }

    private static func meta(_ path: String, _ f: File, content: Bool) -> JSON {
        let binary = String(data: f.data, encoding: .utf8) == nil || f.data.contains(0)
        var m: JSON = ["path": path, "size": f.data.count, "modified": ISO8601DateFormatter().string(from: f.modified),
                       "sha": sha(f.data), "binary": binary]
        if content {
            m["encoding"] = binary ? "base64" : "utf8"
            m["content"] = binary ? f.data.base64EncodedString() : String(decoding: f.data, as: UTF8.self)
        }
        return m
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isIgnored(_ path: String) -> Bool {
        path.split(separator: "/").contains { ignored.contains(String($0)) }
    }

    // MARK: exec (history, quick open)

    /// The workspace's exec commands; nil for any other command.
    mutating func exec(_ command: String, location: String) -> (Int, Data)? {
        let loc = location.split(separator: "/", maxSplits: 1).map(String.init)
        let key = loc.count == 2 ? "\(loc[0])/\(loc[1])" : "\(location)/\(location)"
        if command.contains("# pier-files:list") {
            seed(key, location: loc[0], worktree: loc.count == 2 ? loc[1] : location)
            let paths = (trees[key] ?? [:]).keys.filter { !Self.isIgnored($0) }.sorted()
            return (200, Self.json(["exit_code": 0, "output": paths.joined(separator: "\0") + "\0"]))
        }
        if command.contains("# pier-log:log") {
            let skip = Int(command.components(separatedBy: "--skip ").last?.split(separator: " ").first ?? "0") ?? 0
            let all = Self.history(worktree: loc.count == 2 ? loc[1] : nil)
            let page = all.dropFirst(skip).prefix(GitLog.pageSize + 1)
            let unpushed = all.prefix(loc.count == 2 ? 1 : 0).map(\.sha).joined(separator: "\n")
            let log = page.map { c in
                "\u{1e}\(c.sha)\u{1f}\(c.sha.prefix(7))\u{1f}\(c.parents)\u{1f}\(c.author)\u{1f}\(c.email)\u{1f}\(c.date)\u{1f}\(c.refs)\u{1f}\(c.subject)\n"
            }.joined()
            return (200, Self.json(["exit_code": 0, "output": unpushed + "\n--pier-log--\n" + log]))
        }
        if command.contains("# pier-log:show") {
            let all = Self.history(worktree: loc.count == 2 ? loc[1] : nil)
            guard let c = all.first(where: { command.contains("'\($0.sha)'") }) else { return (200, Self.json(["exit_code": 128, "output": "fatal: bad object"])) }
            let head = [c.sha, String(c.sha.prefix(7)), c.parents, c.author, c.email, c.date, c.author, c.date, c.refs, c.subject + (c.body.isEmpty ? "" : "\n\n" + c.body) + "\n"]
                .joined(separator: "\u{1f}")
            let names = c.files.map { "\($0.status)\0\($0.path)\0" }.joined()
            let counts = c.files.map { "\($0.added)\t\($0.removed)\t\($0.path)\0" }.joined()
            return (200, Self.json(["exit_code": 0, "output": head + "\n\n--pier-files--\n" + names + "\n--pier-numstat--\n" + counts]))
        }
        if command.contains("# pier-log:diff") {
            let all = Self.history(worktree: loc.count == 2 ? loc[1] : nil)
            let c = all.first { command.contains("'\($0.sha)'") }
            let f = c?.files.first { command.contains("'\($0.path)'") }
            return (200, Self.json(["exit_code": 0, "output": f?.patch ?? ""]))
        }
        return nil
    }

    private struct Commit {
        let sha, parents, author, email, date, refs, subject: String
        var body = ""
        var files: [(status: String, path: String, added: Int, removed: Int, patch: String)] = []
    }

    private static func history(worktree: String?) -> [Commit] {
        var out: [Commit] = []
        if let worktree {
            out.append(Commit(sha: "5337933256f547a1f3068c9e9bf81d2e4d6b0e2c", parents: "ae6d87978ce613d68d039e0d63b5c672001bb409", author: "Claude",
                              email: "claude@example.com", date: "2026-10-10T18:40:12-03:00", refs: "HEAD -> refs/heads/\(worktree)",
                              subject: "Add subtract() to calc.py with a test", body: "subtract(a, b) returns a - b; test_calc.py covers it.",
                              files: [("M", "calc.py", 3, 0, "diff --git a/calc.py b/calc.py\n--- a/calc.py\n+++ b/calc.py\n@@ -1,2 +1,5 @@\n def add(a, b):\n     return a + b\n+\n+def subtract(a, b):\n+    return a - b\n"),
                                      ("M", "test_calc.py", 4, 1, "diff --git a/test_calc.py b/test_calc.py\n--- a/test_calc.py\n+++ b/test_calc.py\n@@ -1,5 +1,8 @@\n-from calc import add\n+from calc import add, subtract\n \n \n def test_add():\n     assert add(2, 3) == 5\n+\n+def test_subtract():\n+    assert subtract(3, 2) == 1\n")]))
        }
        out.append(Commit(sha: "ae6d87978ce613d68d039e0d63b5c672001bb409", parents: "1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e", author: "Mona Octocat",
                          email: "mona@example.com", date: "2026-10-09T15:12:40-03:00", refs: worktree == nil ? "HEAD -> refs/heads/main, refs/remotes/origin/main" : "refs/remotes/origin/main, refs/heads/main",
                          subject: "Format the totals with two decimals", body: "Money shows as 12.50, never 12.5.",
                          files: [("M", "src/lib/format.ts", 6, 2, "diff --git a/src/lib/format.ts b/src/lib/format.ts\n--- a/src/lib/format.ts\n+++ b/src/lib/format.ts\n@@ -1,4 +1,8 @@\n-export function money(n: number) {\n-  return `$${n}`\n+export function money(n: number): string {\n+  return new Intl.NumberFormat(\"en-US\", {\n+    style: \"currency\",\n+    currency: \"USD\",\n+    minimumFractionDigits: 2,\n+  }).format(n)\n }\n")]))
        out.append(Commit(sha: "1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e", parents: "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d", author: "Mona Octocat",
                          email: "mona@example.com", date: "2026-10-08T11:03:09-03:00", refs: "tag: refs/tags/v0.2.0",
                          subject: "Add the guide and the logo", files: [("A", "docs/guide.md", 12, 0, "diff --git a/docs/guide.md b/docs/guide.md\nnew file mode 100644\n--- /dev/null\n+++ b/docs/guide.md\n@@ -0,0 +1,3 @@\n+# Guide\n+\n+Run `pytest` to check the calculator.\n"), ("A", "assets/logo.png", 0, 0, "Binary files /dev/null and b/assets/logo.png differ\n")]))
        for i in 0..<9 {
            let sha = String(format: "%02x", 0x10 + i) + "f1e2d3c4b5a69788796a5b4c3d2e1f0a1b2c3d"
            out.append(Commit(sha: String(sha.prefix(40)), parents: "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d", author: i % 2 == 0 ? "Mona Octocat" : "Hubot",
                              email: "dev@example.com", date: "2026-10-0\(7 - i / 3)T0\(i % 9):15:00-03:00", refs: "",
                              subject: ["Set up the project", "Add pytest", "Add calc.add", "Write the README", "Configure CI", "Ignore node_modules",
                                        "Add the app shell", "Bump dependencies", "Fix a typo in the README"][i],
                              files: [("M", "README.md", 1, 1, "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-# sandbox\n+# Sandbox\n")]))
        }
        return out
    }

    // MARK: seed

    private mutating func seed(_ key: String, location: String, worktree: String) {
        guard trees[key] == nil else { return }
        func t(_ s: String, _ status: String? = nil) -> File { File(data: Data(s.utf8), status: status) }
        var files: [String: File] = [
            ".gitignore": t("node_modules/\n__pycache__/\n.env\n"),
            "README.md": t("# \(location)\n\nA small playground for the agents: `calc.py` and its tests.\n\n## Run\n\n```sh\npytest -q\n```\n"),
            "docs/guide.md": t("# Guide\n\nRun `pytest` to check the calculator.\n"),
            "assets/logo.png": File(data: Data(base64Encoded: Self.logo) ?? Data(), status: nil),
            "node_modules/left-pad/index.js": t("module.exports = (s, n) => String(s).padStart(n)\n"),
            "src/app.ts": t("""
                import { money } from "./lib/format"

                type Line = { label: string; amount: number }

                // Renders the totals of an invoice.
                export function totals(lines: Line[]): string {
                  const sum = lines.reduce((acc, l) => acc + l.amount, 0)
                  return `Total: ${money(sum)}`
                }

                console.log(totals([{ label: "Plan", amount: 12.5 }]))

                """),
            "src/lib/format.ts": t("""
                export function money(n: number): string {
                  return new Intl.NumberFormat("en-US", {
                    style: "currency",
                    currency: "USD",
                    minimumFractionDigits: 2,
                  }).format(n)
                }

                """),
        ]
        if worktree == location {
            files["calc.py"] = t("def add(a, b):\n    return a + b\n")
            files["test_calc.py"] = t("from calc import add\n\n\ndef test_add():\n    assert add(2, 3) == 5\n")
            files["notes.txt"] = t("remember to add subtract\n", "??")
        } else {
            files["calc.py"] = t("def add(a, b):\n    return a + b\n\n\ndef subtract(a, b):\n    \"\"\"a minus b.\"\"\"\n    return a - b\n", " M")
            files["test_calc.py"] = t("from calc import add, subtract\n\n\ndef test_add():\n    assert add(2, 3) == 5\n\n\ndef test_subtract():\n    assert subtract(3, 2) == 1\n")
            files["probe_dir/x.txt"] = t("", "??")
        }
        trees[key] = files
    }

    private static let logo = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAABQklEQVR42u3X0SoFQRwG8PMC+1ZzNQ9gkqQkZSQlKWlSkpJkk2eZd5gSkYhIREQi4vbzbe3d7jl79uz850KmfjfTTN+0Ozv7n17vv7Vs+uAnI0WWXMmWfZlc8P63IU9oUIwx8YL3vhQFQkvFHNUtfPfTETpyo4XvfOSESPJ24dvvjhDZcE9Cb70pgpDmPaE3XwNBSBgcvvFiCML6f6J6/dkThPn6cPeUERKpnph67VEREqluRr36YAmJ2OoCVu4dIZHqmaCX7xwhkZoFLN1aQiI1r2DxRhESqdmEC9cZIZH6wkXPX3mCMN//JJy7NARhg6slPXsRCEJC899w5lwRhAxXounpM0eIrF1ppqdOc0Ik+Wh14eSJI3TkulXGE8eKAqGlYo6Kdz8YPzLkCQ2KMUbuhjR2mJEiS65kyz65q9mfbb+brCUJQmECPQAAAABJRU5ErkJggg=="

    private static func json(_ any: Any) -> Data { (try? JSONSerialization.data(withJSONObject: any)) ?? Data("{}".utf8) }
}
