import Testing

@testable import PierKit

private func kinds(_ code: String, _ l: SyntaxLanguage) -> [(String, SyntaxKind)] {
    let sc = Array(code.unicodeScalars)
    return SyntaxHighlighter.tokens(code, language: l).map { (String(String.UnicodeScalarView(sc[$0.start..<$0.end])), $0.kind) }
}
private func has(_ t: [(String, SyntaxKind)], _ s: String, _ k: SyntaxKind) -> Bool { t.contains { $0.0 == s && $0.1 == k } }

@Suite struct SyntaxHighlighterTests {
    @Test func labels() {
        #expect(SyntaxLanguage.resolve("ts") == .typescript)
        #expect(SyntaxLanguage.resolve("TSX") == .typescript)
        #expect(SyntaxLanguage.resolve("language-py") == .python)
        #expect(SyntaxLanguage.resolve("sh title=\"x\"") == .bash)
        #expect(SyntaxLanguage.resolve("$") == .bash)
        #expect(SyntaxLanguage.resolve("nonsense") == nil)
        #expect(SyntaxLanguage.forFile("/a/b/Foo.swift") == .swift)
        #expect(SyntaxLanguage.forFile("calc.py") == .python)
        #expect(SyntaxLanguage.forFile("README") == nil)
    }

    @Test func swift() {
        let t = kinds("""
        // hi
        struct Foo: Codable { let n = 42; func go() -> String { "a\\"b" } }
        """, .swift)
        #expect(has(t, "// hi", .comment))
        #expect(has(t, "struct", .keyword))
        #expect(has(t, "Foo", .type))
        #expect(has(t, "42", .number))
        #expect(has(t, "go", .function))
        #expect(has(t, "String", .type))
        #expect(has(t, "\"a\\\"b\"", .string))
    }

    @Test func typescriptAndJS() {
        let t = kinds("const x: number = 3.5; // t\nconst s = `a\nb`; async function f() { return null }", .typescript)
        #expect(has(t, "const", .keyword)); #expect(has(t, "number", .type)); #expect(has(t, "3.5", .number))
        #expect(has(t, "// t", .comment)); #expect(has(t, "`a\nb`", .string)); #expect(has(t, "null", .literal)); #expect(has(t, "f", .function))
    }

    @Test func python() {
        let t = kinds("@dec\ndef f(x):\n    \"\"\"doc\n    more\"\"\"\n    return x  # c\nclass A: pass", .python)
        #expect(has(t, "@dec", .attribute)); #expect(has(t, "def", .keyword)); #expect(has(t, "f", .function))
        #expect(has(t, "\"\"\"doc\n    more\"\"\"", .string)); #expect(has(t, "# c", .comment)); #expect(has(t, "A", .type))
    }

    @Test func goRust() {
        let g = kinds("func main() { x := 0x1F; fmt.Println(\"hi\") /* c */ }", .go)
        #expect(has(g, "func", .keyword)); #expect(has(g, "main", .function)); #expect(has(g, "0x1F", .number)); #expect(has(g, "Println", .function)); #expect(has(g, "/* c */", .comment))
        let r = kinds("#[derive(Debug)]\nfn f<'a>(x: &'a str) -> Option<u8> { let c = 'x'; }", .rust)
        #expect(has(r, "#[derive(Debug)]", .attribute)); #expect(has(r, "fn", .keyword)); #expect(has(r, "'a", .attribute)); #expect(has(r, "u8", .type)); #expect(has(r, "'x'", .string))
    }

    @Test func bash() {
        let t = kinds("git commit -m \"msg $USER\" && echo $(date) # note\nFOO=1 npm run build | tee out.log", .bash)
        #expect(has(t, "git", .function)); #expect(has(t, "-m", .attribute)); #expect(has(t, "\"msg $USER\"", .string))
        #expect(has(t, "echo", .function)); #expect(has(t, "# note", .comment)); #expect(has(t, "FOO", .variable)); #expect(has(t, "npm", .function)); #expect(has(t, "tee", .function))
        #expect(kinds("echo a#b", .bash).contains { $0.1 == .comment } == false)
    }

    @Test func jsonKeys() {
        let t = kinds("{\"a\": [1, -2.5e3, true, null], \"b\": \"x\"}", .json)
        #expect(has(t, "\"a\"", .property)); #expect(has(t, "\"b\"", .property)); #expect(has(t, "\"x\"", .string))
        #expect(has(t, "1", .number)); #expect(has(t, "2.5e3", .number)); #expect(has(t, "true", .literal)); #expect(has(t, "null", .literal))
    }

    @Test func yaml() {
        let t = kinds("# top\nname: app\nlist:\n  - id: 3\n  - \"q\" # c\nrun: |\n  echo 1\nflag: true", .yaml)
        #expect(has(t, "# top", .comment)); #expect(has(t, "name", .property)); #expect(has(t, "app", .string)); #expect(has(t, "3", .number))
        #expect(has(t, "\"q\"", .string)); #expect(has(t, "# c", .comment)); #expect(has(t, "echo 1", .string)); #expect(has(t, "true", .literal))
    }

    @Test func phpSqlHtmlCssDiff() {
        let p = kinds("<?php\n$a = 'x'; // c\nfunction f(int $n): string { return $n; }", .php)
        #expect(has(p, "<?php", .meta)); #expect(has(p, "$a", .variable)); #expect(has(p, "'x'", .string)); #expect(has(p, "function", .keyword)); #expect(has(p, "int", .type))
        let q = kinds("select id, count(*) from users where name = 'o''k' -- x", .sql)
        #expect(has(q, "select", .keyword)); #expect(has(q, "from", .keyword)); #expect(has(q, "'o''k'", .string)); #expect(has(q, "-- x", .comment)); #expect(has(q, "count", .function))
        let h = kinds("<!-- c --><div class=\"a\" id=x>t</div>", .html)
        #expect(has(h, "<!-- c -->", .comment)); #expect(has(h, "div", .tag)); #expect(has(h, "class", .property)); #expect(has(h, "\"a\"", .string))
        let c = kinds(".a > b { color: #fff; margin: 10px 2em; } /* c */", .css)
        #expect(has(c, ".a", .type)); #expect(has(c, "color", .property)); #expect(has(c, "#fff", .number)); #expect(has(c, "10px", .number)); #expect(has(c, "/* c */", .comment))
        let d = kinds("--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n ctx", .diff)
        #expect(has(d, "+new", .inserted)); #expect(has(d, "-old", .deleted)); #expect(has(d, "@@ -1 +1 @@", .meta)); #expect(has(d, "--- a", .meta))
    }

    @Test func runsCoverEverythingAndNeverOverlap() {
        let code = "let x = \"é😀\" // ok\nfunc f() {}"
        let runs = SyntaxHighlighter.runs(code, language: .swift)
        #expect(runs.first?.start == 0)
        #expect(runs.last?.end == code.unicodeScalars.count)
        for (a, b) in zip(runs, runs.dropFirst()) { #expect(a.end == b.start) }
    }

    @Test func brokenAndHugeInputIsSafe() {
        for l in SyntaxLanguage.allCases {
            _ = SyntaxHighlighter.tokens("\"unterminated /* open ' ` <div class=\" {{{ ((( ```", language: l)
            _ = SyntaxHighlighter.tokens("", language: l)
        }
        let big = String(repeating: "let a = \"x\" // c\n", count: 20_000)
        let runs = SyntaxHighlighter.runs(big, language: .swift)
        #expect(runs.last!.end == big.unicodeScalars.count)
    }

    /// Broken code from the agent's screen (cut mid-token, unterminated quotes, escapes at the very end) must never
    /// index past the text, in every language.
    @Test func edgeInputsNeverCrash() {
        let edges = [
            "", "\"", "'", "\"\"\"", "\"\"\"abc", "'''", "`", "\\", "\"\\", "'\\", "\"\"\"\\", "0x", "1e", "1e-", ".", "@", "#", "#[", "#![",
            "/*", "/*/", "//", "--", "<!--", "<", "<a", "<a b=\"", "&", "&amp", "$", "${", "$(", "${a", "a=", "-- x", "#!", "r\"",
            "\"\"\"\n\"\"", "'''\n''", "0b", "0o", "0X", "1_", "x.", "x..", "@x.", "f(", "{", "}", "[", "]", "\n", "\r\n", " \t",
            "key: \"", "key: '", "- \"", "\"\"\"\"\"\"", "''''''", "\u{FEFF}", "é", "日本語 = \"", "❯ 1. Yes", "🙂\"",
        ]
        for l in SyntaxLanguage.allCases {
            for e in edges {
                _ = SyntaxHighlighter.runs(e, language: l)
                _ = SyntaxHighlighter.runs(e + "\n" + e, language: l)
                _ = SyntaxHighlighter.runs("x " + e, language: l)
            }
        }
    }
}
