import Foundation
import Testing

@testable import PierKit

/// The sidebar's ordering, the file tree's rules and the editor's text rules.
@Suite struct ProjectOrderTests {
    private let names = ["b/zeta": "zeta", "b/alpha": "Alpha", "b/app10": "app10", "b/app2": "app2", "b/beta": "beta"]
    private func name(_ k: String) -> String { names[k] ?? k }

    @Test func byName() {
        let keys = ["b/zeta", "b/app10", "b/beta", "b/alpha", "b/app2"]
        #expect(ProjectOrder.ordered(keys, sort: .name, name: name) == ["b/alpha", "b/app2", "b/app10", "b/beta", "b/zeta"])
    }

    @Test func byActivityNewestFirstThenByName() {
        let now = Date()
        let at: [String: Date] = ["b/beta": now.addingTimeInterval(-60), "b/zeta": now]
        let keys = ["b/alpha", "b/beta", "b/zeta", "b/app2"]
        #expect(ProjectOrder.ordered(keys, sort: .activity, name: name, activity: { at[$0] }) == ["b/zeta", "b/beta", "b/alpha", "b/app2"])
    }

    @Test func manualKeepsTheSavedOrderAndAppendsNewcomersByName() {
        let keys = ["b/alpha", "b/beta", "b/zeta", "b/app2"]
        #expect(ProjectOrder.ordered(keys, sort: .manual, manual: ["b/zeta", "gone/x", "b/beta"], name: name)
            == ["b/zeta", "b/beta", "b/alpha", "b/app2"])
    }

    @Test func moving() {
        let l = ["a", "b", "c", "d"]
        #expect(ProjectOrder.moving("d", before: "b", in: l) == ["a", "d", "b", "c"])
        #expect(ProjectOrder.moving("a", before: nil, in: l) == ["b", "c", "d", "a"])
        #expect(ProjectOrder.moving("b", before: "b", in: l) == l)
        #expect(ProjectOrder.moving("x", before: "c", in: l) == ["a", "b", "x", "c", "d"])
        #expect(ProjectOrder.moving("a", before: "missing", in: l) == ["b", "c", "d", "a"])
        #expect(ProjectOrder.moving("a", after: "c", in: l) == ["b", "c", "a", "d"])
        #expect(ProjectOrder.moving("d", after: "c", in: l) == l)
        #expect(ProjectOrder.moving("a", after: "d", in: l) == ["b", "c", "d", "a"])
        // A drop on itself, either way, changes nothing.
        #expect(ProjectOrder.moving("b", after: "b", in: l) == l)
        #expect(ProjectOrder.moving("a", after: "missing", in: l) == ["b", "c", "d", "a"])
    }

    @Test func sortDecodesTolerantly() throws {
        let s = try JSONDecoder().decode([ProjectSort].self, from: Data(#"["name","activity","manual","newer"]"#.utf8))
        #expect(s == [.name, .activity, .manual, .manual])
    }
}

@Suite struct FileTreeTests {
    @Test func paths() {
        #expect(FileTree.join("", "a") == "a" && FileTree.join("a/b", "c.txt") == "a/b/c.txt")
        #expect(FileTree.parent(of: "a/b/c.txt") == "a/b" && FileTree.parent(of: "c.txt") == "")
        #expect(FileTree.name(of: "a/b/c.txt") == "c.txt" && FileTree.name(of: "c") == "c")
        #expect(FileTree.ancestors(of: "a/b/c.txt") == ["a", "a/b"] && FileTree.ancestors(of: "top").isEmpty)
    }

    @Test func rowsFollowOpenFolders() {
        let listings: [String: [FileEntry]] = [
            "": [FileEntry(name: "src", type: .dir, changed: true), FileEntry(name: "node_modules", type: .dir, ignored: true),
                 FileEntry(name: "cfg", type: .link, target: "../cfg", points: .dir), FileEntry(name: "README.md", type: .file, size: 10)],
            "src": [FileEntry(name: "lib", type: .dir), FileEntry(name: "main.go", type: .file, status: " M")],
            "src/lib": [FileEntry(name: "x.go", type: .file)],
        ]
        let closed = FileTree.rows(listings: listings, open: [])
        #expect(closed.map(\.path) == ["src", "node_modules", "cfg", "README.md"])
        let open = FileTree.rows(listings: listings, open: ["src", "src/lib"])
        #expect(open.map(\.path) == ["src", "src/lib", "src/lib/x.go", "src/main.go", "node_modules", "cfg", "README.md"])
        #expect(open.map(\.depth) == [0, 1, 2, 1, 0, 0, 0])
        // An open folder whose listing has not arrived shows nothing under it yet; a closed parent hides open children.
        #expect(FileTree.rows(listings: listings, open: ["src/lib"]).count == 4)
        #expect(FileTree.rows(listings: listings, open: ["src"], hideIgnored: true).map(\.path) == ["src", "src/lib", "src/main.go", "cfg", "README.md"])
    }

    @Test func entryKinds() {
        #expect(FileEntry(name: "cfg", type: .link, points: .dir).isFolder)
        #expect(FileEntry(name: "f", type: .link, points: .file).isFile)
        #expect(!FileEntry(name: "out", type: .link).isFolder && !FileEntry(name: "out", type: .link).isFile)
        #expect(!FileEntry(name: "sock", type: .other).isFile)
    }

    @Test func badges() {
        #expect(FileTree.badge(" M") == .modified && FileTree.badge("M ") == .modified && FileTree.badge("MM") == .modified)
        #expect(FileTree.badge("??") == .untracked && FileTree.badge("A ") == .added && FileTree.badge("AM") == .added)
        #expect(FileTree.badge("R ") == .renamed && FileTree.badge("RM") == .renamed && FileTree.badge(" D") == .deleted)
        #expect(FileTree.badge("UU") == .conflict && FileTree.badge("AA") == .conflict)
        #expect(FileTree.badge(nil) == nil && FileTree.badge("!!") == nil && FileTree.badge("") == nil)
    }
}

@Suite struct EditorTextTests {
    @Test func lineAndColumn() {
        let t = "ab\ncdé\n\nx"
        #expect(EditorText.lineColumn(in: t, utf16Offset: 0) == (1, 1))
        #expect(EditorText.lineColumn(in: t, utf16Offset: 2) == (1, 3))
        #expect(EditorText.lineColumn(in: t, utf16Offset: 3) == (2, 1))
        #expect(EditorText.lineColumn(in: t, utf16Offset: 6) == (2, 4))
        #expect(EditorText.lineColumn(in: t, utf16Offset: 8) == (4, 1))
        #expect(EditorText.lineColumn(in: t, utf16Offset: 999) == (4, 2))
        #expect(EditorText.lineColumn(in: "👍🏽x", utf16Offset: 4) == (1, 2))
    }

    @Test func lineCounts() {
        #expect(EditorText.lineCount("") == 1 && EditorText.lineCount("a") == 1 && EditorText.lineCount("a\n") == 2 && EditorText.lineCount("a\nb\nc") == 3)
    }

    @Test func indentUnits() {
        #expect(EditorText.indentUnit(of: "func a() {\n\tb()\n\tif x {\n\t\tc()\n\t}\n}\n") == "\t")
        #expect(EditorText.indentUnit(of: "a:\n  b:\n    c: 1\n  d: 2\n") == "  ")
        #expect(EditorText.indentUnit(of: "def f():\n    return 1\n\nclass A:\n    def g(self):\n        pass\n") == "    ")
        #expect(EditorText.indentUnit(of: "no indentation at all\n") == "    ")
        // Windows line ends: "\r\n" is one Character.
        #expect(EditorText.indentUnit(of: "func a() {\r\n\tb()\r\n\tif x {\r\n\t\tc()\r\n\t}\r\n}\r\n") == "\t")
        #expect(EditorText.indentUnit(of: "a:\r\n  b:\r\n    c: 1\r\n  d: 2\r\n") == "  ")
    }

    @Test func newlines() {
        #expect(EditorText.newline(after: "    let x = 1", unit: "    ") == "\n    ")
        #expect(EditorText.newline(after: "\tif ok {", unit: "\t") == "\n\t\t")
        #expect(EditorText.newline(after: "foo(", unit: "  ") == "\n  ")
        #expect(EditorText.newline(after: "def f():", unit: "    ", language: .python) == "\n    ")
        #expect(EditorText.newline(after: "label:", unit: "    ", language: .go) == "\n")
    }

    @Test func lineEndings() {
        #expect(EditorText.lineEnding(of: "a\r\nb\r\nc\n") == "\r\n")
        #expect(EditorText.lineEnding(of: "a\nb\r\n") == "\n")
        #expect(EditorText.lineEnding(of: "") == "\n")
    }
}

@Suite struct FileSearchTests {
    @Test func command() {
        let top = #"cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && "#
        #expect(FileSearch.command == top + "git ls-files -co --exclude-standard -z | head -c 60000 # pier-files:list")
        // A repository too large to list: git narrows by the letters in order, any case.
        #expect(FileSearch.command(matching: "Calc py") == top + "git ls-files -co --exclude-standard -z -- ':(icase)*C*a*l*c*p*y*' | head -c 60000 # pier-files:match")
        #expect(FileSearch.command(matching: "it's") == top + #"git ls-files -co --exclude-standard -z -- ':(icase)*i*t*'\''*s*' | head -c 60000 # pier-files:match"#)
        #expect(FileSearch.command(matching: "*[") == nil && FileSearch.command(matching: "  ") == nil)
    }

    @Test func parsesAndDropsACutPath() {
        let (paths, cut) = FileSearch.parse("a.go\0src/b.go\0a.go\0")
        #expect(paths == ["a.go", "src/b.go"] && !cut)
        let long = String(repeating: "x/", count: 15_000) + "file.txt\0" + String(repeating: "y", count: 40_000)
        let (some, truncated) = FileSearch.parse(long)
        #expect(truncated && some.count == 1 && some[0].hasSuffix("file.txt"))
    }

    @Test func scoring() {
        #expect(FileSearch.score("calc", "src/calc.py") != nil)
        #expect(FileSearch.score("cpy", "src/calc.py") != nil)
        #expect(FileSearch.score("xyz", "src/calc.py") == nil)
        #expect(FileSearch.score("", "a") == 0)
        // The file's own name beats a folder with the same letters.
        #expect(FileSearch.score("calc", "calc/readme.md")! < FileSearch.score("calc", "src/calc.py")!)
        // Word starts and runs of letters beat scattered ones.
        #expect(FileSearch.score("ts", "src/test_setup.py")! > FileSearch.score("ts", "src/lists.py")!)
    }

    @Test func searchOrdersBestFirst() {
        let paths = ["docs/calc-guide.md", "src/calc.py", "src/lib/calculator/index.ts", "test_calc.py", "README.md"]
        let hits = FileSearch.search("calc", in: paths)
        #expect(hits.first == "src/calc.py")
        #expect(!hits.contains("README.md"))
        #expect(Set(hits) == Set(paths.filter { $0 != "README.md" }))
        #expect(FileSearch.search("calc", in: paths, limit: 2).count == 2)
        #expect(FileSearch.search("readme", in: paths) == ["README.md"])
    }
}
