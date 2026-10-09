import Foundation

/// What a piece of code is, for coloring. The app maps each kind to a palette color.
public enum SyntaxKind: UInt8, Sendable, CaseIterable {
    case plain, keyword, string, comment, number, type, literal, function, variable, property, attribute, tag, inserted, deleted, meta
}

public struct SyntaxRun: Equatable, Sendable {
    /// Half-open range in Unicode scalar offsets of the source text.
    public var start: Int
    public var end: Int
    public var kind: SyntaxKind
    public init(start: Int, end: Int, kind: SyntaxKind) { (self.start, self.end, self.kind) = (start, end, kind) }
}

public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case swift, javascript, typescript, python, go, rust, bash, json, yaml, php, sql, html, css, diff, c, cpp, java, kotlin

    /// Fence label (```ts, ```py, ```sh ...) to language. Unknown labels give nil (plain text).
    public static func resolve(_ label: String) -> SyntaxLanguage? {
        var l = label.lowercased().trimmingCharacters(in: .whitespaces)
        if let sp = l.firstIndex(where: { $0 == " " || $0 == "{" || $0 == "," }) { l = String(l[..<sp]) }
        if l.hasPrefix("language-") { l.removeFirst(9) }
        if l == "$" || l == "#" { return .bash }
        switch l {
        case "swift": return .swift
        case "js", "javascript", "jsx", "mjs", "cjs", "node": return .javascript
        case "ts", "typescript", "tsx", "mts": return .typescript
        case "py", "python", "python3", "py3": return .python
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "sh", "bash", "zsh", "shell", "console", "terminal", "shellscript", "fish": return .bash
        case "json", "jsonc", "json5", "jsonl", "geojson": return .json
        case "yaml", "yml": return .yaml
        case "php": return .php
        case "sql", "mysql", "postgres", "postgresql", "pgsql", "sqlite", "plsql": return .sql
        case "html", "htm", "xml", "svg", "xhtml", "vue", "plist": return .html
        case "css", "scss", "less": return .css
        case "diff", "patch", "udiff": return .diff
        case "c", "h": return .c
        case "cpp", "c++", "cc", "cxx", "hpp", "objc", "objective-c": return .cpp
        case "java": return .java
        case "kotlin", "kt", "kts": return .kotlin
        default: return nil
        }
    }

    /// Language by file name (for tool details and diffs).
    public static func forFile(_ path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" || name == "makefile" { return .bash }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : resolve(ext == "h" ? "c" : ext)
    }
}

/// A small, dependency-free tokenizer for code in chat. Not a parser: it recognizes comments, strings, numbers,
/// keywords, types and a few language specifics, and is forgiving (broken code still gets sensible colors).
public enum SyntaxHighlighter {
    /// Longer text is left plain beyond this many scalars (keeps worst cases bounded).
    public static let maxScalars = 60_000

    /// Non-plain tokens only, in order, never overlapping.
    public static func tokens(_ text: String, language: SyntaxLanguage) -> [SyntaxRun] {
        var sc = Scanner(Array(text.unicodeScalars.prefix(maxScalars)))
        sc.run(language)
        return sc.out
    }

    /// Runs covering the whole text (plain gaps filled), for rendering.
    public static func runs(_ text: String, language: SyntaxLanguage) -> [SyntaxRun] {
        let total = text.unicodeScalars.count
        var out: [SyntaxRun] = []
        var pos = 0
        for t in tokens(text, language: language) where t.end > t.start && t.start >= pos {
            if t.start > pos { out.append(SyntaxRun(start: pos, end: t.start, kind: .plain)) }
            out.append(t)
            pos = t.end
        }
        if pos < total { out.append(SyntaxRun(start: pos, end: total, kind: .plain)) }
        return out
    }
}

// MARK: - rules

private typealias S = Unicode.Scalar

private func scalars(_ s: String) -> [S] { Array(s.unicodeScalars) }
private func words(_ s: String) -> Set<String> { Set(s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)) }

private struct Rules {
    var keywords: Set<String> = []
    var literals: Set<String> = []
    var types: Set<String> = []
    var lineComments: [[S]] = []
    var blockComment: ([S], [S])?
    var nestedBlock = false
    var quotes: Set<S> = []
    var multilineQuotes: Set<S> = []
    var triple = false
    var caseInsensitive = false
    var dollarVars = false
    var atAttributes = false
    var swiftDirectives = false
    var rustAttrs = false
    var rustLifetimes = false
    var capitalTypes = true
    var keyStrings = false
    var hashCommentNeedsSpace = false
    var bash = false
    var phpTags = false
    var identExtra: Set<S> = []
}

private let cLikeLiterals = words("true false null nil undefined NaN Infinity this self super None True False")

private func rules(_ l: SyntaxLanguage) -> Rules {
    var r = Rules()
    r.literals = cLikeLiterals
    switch l {
    case .swift:
        r.keywords = words("""
        associatedtype actor any as async await break case catch class continue convenience default defer deinit didSet do else enum \
        extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is lazy let mutating \
        nonisolated nonmutating open operator optional override postfix precedence prefix private protocol public repeat required rethrows \
        return set some static struct subscript switch throw throws try typealias unowned var weak where while willSet macro borrowing consuming
        """)
        r.literals = words("true false nil self Self super")
        r.types = words("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Float Double Bool String Character Void Any AnyObject Array Dictionary Set Optional Result Data Date URL")
        r.lineComments = [scalars("//")]; r.blockComment = (scalars("/*"), scalars("*/")); r.nestedBlock = true
        r.quotes = ["\""]; r.triple = true
        r.atAttributes = true; r.swiftDirectives = true
        r.identExtra = ["$"]
    case .javascript, .typescript:
        r.keywords = words("""
        async await break case catch class const continue debugger default delete do else export extends finally for from function if import \
        in instanceof let new of return static switch throw try typeof var void while with yield get set
        """)
        if l == .typescript {
            r.keywords.formUnion(words("abstract as declare enum implements interface is keyof namespace private protected public readonly satisfies type unique infer override module"))
            r.types = words("string number boolean any unknown never void object symbol bigint Array Promise Record Partial Readonly Map Set")
        }
        r.lineComments = [scalars("//")]; r.blockComment = (scalars("/*"), scalars("*/"))
        r.quotes = ["\"", "'", "`"]; r.multilineQuotes = ["`"]
        r.atAttributes = true
        r.identExtra = ["$"]
    case .python:
        r.keywords = words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case")
        r.literals = words("True False None self cls")
        r.types = words("int str float bool list dict set tuple bytes object type")
        r.lineComments = [scalars("#")]
        r.quotes = ["\"", "'"]; r.triple = true
        r.atAttributes = true
    case .go:
        r.keywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
        r.literals = words("true false nil iota")
        r.types = words("int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 string bool byte rune error any complex64 complex128")
        r.lineComments = [scalars("//")]; r.blockComment = (scalars("/*"), scalars("*/"))
        r.quotes = ["\"", "'", "`"]; r.multilineQuotes = ["`"]
    case .rust:
        r.keywords = words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while macro_rules")
        r.literals = words("true false self Self None Some Ok Err")
        r.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box")
        r.lineComments = [scalars("//")]; r.blockComment = (scalars("/*"), scalars("*/")); r.nestedBlock = true
        r.quotes = ["\"", "'"]; r.multilineQuotes = ["\""]
        r.rustAttrs = true; r.rustLifetimes = true
    case .bash:
        r.keywords = words("if then else elif fi for while until do done case esac in function select time return exit break continue export local readonly declare unset source alias set shift trap eval exec")
        r.literals = words("true false")
        r.lineComments = [scalars("#")]; r.hashCommentNeedsSpace = true
        r.quotes = ["\"", "'"]; r.multilineQuotes = ["\"", "'"]
        r.dollarVars = true; r.capitalTypes = false; r.bash = true
    case .json:
        r.literals = words("true false null")
        r.lineComments = [scalars("//")]; r.blockComment = (scalars("/*"), scalars("*/"))
        r.quotes = ["\""]; r.keyStrings = true; r.capitalTypes = false
    case .yaml:
        r.literals = words("true false null yes no on off True False Null ~")
        r.lineComments = [scalars("#")]; r.hashCommentNeedsSpace = true
        r.quotes = ["\"", "'"]; r.capitalTypes = false
    case .php:
        r.keywords = words("""
        abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor \
        endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once \
        instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return \
        static switch throw trait try unset use var while xor yield
        """)
        r.literals = words("true false null TRUE FALSE NULL self parent")
        r.types = words("int float string bool array object mixed void iterable callable never")
        r.lineComments = [scalars("//"), scalars("#")]; r.blockComment = (scalars("/*"), scalars("*/"))
        r.quotes = ["\"", "'"]; r.multilineQuotes = ["\"", "'"]
        r.dollarVars = true; r.rustAttrs = true; r.phpTags = true
    case .sql:
        r.keywords = words("""
        select from where and or not in is null like ilike between exists insert into values update set delete create alter drop table index view \
        database schema column add constraint primary key foreign references unique default check join inner outer left right full cross on using \
        group by order having limit offset union all distinct as case when then else end asc desc with recursive returning begin commit rollback \
        transaction grant revoke truncate explain analyze over partition cascade if replace function trigger procedure returns language
        """)
        r.literals = words("true false null")
        r.types = words("int integer bigint smallint tinyint serial bigserial varchar char text boolean bool date time timestamp timestamptz datetime decimal numeric float double real json jsonb uuid blob bytea")
        r.caseInsensitive = true
        r.lineComments = [scalars("--")]; r.blockComment = (scalars("/*"), scalars("*/"))
        r.quotes = ["'", "\""]; r.multilineQuotes = ["'"]
        r.capitalTypes = false
    case .c, .cpp:
        r.keywords = words("""
        auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch \
        typedef union volatile while
        """)
        if l == .cpp {
            r.keywords.formUnion(words("catch class constexpr delete explicit friend mutable namespace new noexcept operator override private protected public template this throw try typename using virtual final nullptr"))
        }
        r.literals = words("true false NULL nullptr")
        r.types = words("int long short char float double void unsigned signed bool size_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t string vector map")
        r.lineComments = [scalars("//")]; r.blockComment = (scalars("/*"), scalars("*/"))
        r.quotes = ["\"", "'"]
        r.swiftDirectives = true
    case .java, .kotlin:
        r.keywords = words("""
        abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof \
        interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try \
        volatile while fun val var when object companion data sealed override open suspend internal lateinit by in is as typealias init constructor
        """)
        r.literals = words("true false null this super")
        r.types = words("int long short byte char float double boolean void String Int Long Double Float Boolean Unit Any")
        r.lineComments = [scalars("//")]; r.blockComment = (scalars("/*"), scalars("*/"))
        r.quotes = ["\"", "'"]; r.triple = true
        r.atAttributes = true
    case .html, .css, .diff:
        break
    }
    return r
}

// MARK: - scanner

private struct Scanner {
    let s: [S]
    var out: [SyntaxRun] = []
    init(_ s: [S]) { self.s = s }

    mutating func run(_ l: SyntaxLanguage) {
        switch l {
        case .diff: diff()
        case .yaml: yaml()
        case .html: html()
        case .css: css()
        default: general(rules(l), 0, s.count)
        }
    }

    // helpers
    mutating func add(_ a: Int, _ b: Int, _ k: SyntaxKind) {
        guard b > a, k != .plain else { return }
        out.append(SyntaxRun(start: a, end: min(b, s.count), kind: k))
    }
    func has(_ p: [S], at i: Int, limit: Int) -> Bool {
        guard !p.isEmpty, i + p.count <= limit else { return false }
        for k in 0..<p.count where s[i + k] != p[k] { return false }
        return true
    }
    func hasCI(_ p: [S], at i: Int, limit: Int) -> Bool { has(p, at: i, limit: limit) }
    static func isIdentStart(_ c: S) -> Bool {
        if c.value < 128 { return (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) || c == "_" }
        return c.properties.isAlphabetic
    }
    static func isIdentPart(_ c: S) -> Bool {
        if c.value < 128 { return isIdentStart(c) || (c.value >= 48 && c.value <= 57) }
        return c.properties.isAlphabetic || c.properties.numericType != nil
    }
    static func isDigit(_ c: S) -> Bool { c.value >= 48 && c.value <= 57 }
    static func isSpace(_ c: S) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }
    func lineEnd(_ i: Int, _ limit: Int) -> Int {
        var j = i
        while j < limit, s[j] != "\n" { j += 1 }
        return j
    }
    func nextNonSpace(_ i: Int, _ limit: Int, sameLine: Bool = true) -> S? {
        var j = i
        while j < limit {
            let c = s[j]
            if c == " " || c == "\t" || (!sameLine && (c == "\n" || c == "\r")) { j += 1; continue }
            return c
        }
        return nil
    }

    func stringEnd(_ i: Int, _ q: S, _ r: Rules, _ limit: Int) -> Int {
        if r.triple, i + 2 < limit, s[i + 1] == q, s[i + 2] == q {
            var j = i + 3
            while j + 2 < limit + 0 {
                if s[j] == "\\" { j += 2; continue }
                if s[j] == q, s[j + 1] == q, s[j + 2] == q { return j + 3 }
                j += 1
            }
            return limit
        }
        let multi = r.multilineQuotes.contains(q)
        var j = i + 1
        while j < limit {
            let c = s[j]
            if c == "\\" && !(r.bash && q == "'") { j += 2; continue }
            if c == q {
                if r.caseInsensitive, j + 1 < limit, s[j + 1] == q { j += 2; continue }  // SQL '' escape
                return j + 1
            }
            if c == "\n" && !multi { return j }
            j += 1
        }
        return min(j, limit)
    }

    func numberEnd(_ i: Int, _ limit: Int) -> Int {
        var j = i
        if s[j] == "0", j + 1 < limit, s[j + 1] == "x" || s[j + 1] == "X" || s[j + 1] == "b" || s[j + 1] == "o" {
            j += 2
            while j < limit, Self.isIdentPart(s[j]) { j += 1 }
            return j
        }
        while j < limit {
            let c = s[j]
            if Self.isDigit(c) || c == "_" { j += 1; continue }
            if c == ".", j + 1 < limit, Self.isDigit(s[j + 1]) { j += 1; continue }
            if (c == "e" || c == "E"), j + 1 < limit, Self.isDigit(s[j + 1]) || ((s[j + 1] == "-" || s[j + 1] == "+") && j + 2 < limit && Self.isDigit(s[j + 2])) { j += 2; continue }
            if Self.isIdentStart(c) { j += 1; continue }  // suffixes: 12px, 3.0f, 10_u8
            break
        }
        return j
    }

    // MARK: generic C-family / script scanner

    mutating func general(_ r: Rules, _ from: Int, _ limit: Int) {
        var i = from
        var cmdPos = true            // bash: a command word is expected
        var declarator: SyntaxKind?  // the next identifier names a function/type
        var lineStart = true
        var afterAssign = false      // bash: just saw NAME= (the value follows, then the command)
        if r.phpTags { i = phpOpen(i, limit) }
        while i < limit {
            let c = s[i]
            if c == "\n" { lineStart = true; if r.bash { cmdPos = true }; i += 1; continue }
            if c == " " || c == "\t" || c == "\r" { i += 1; continue }
            defer { lineStart = false }

            // comments
            if let lc = r.lineComments.first(where: { has($0, at: i, limit: limit) }) {
                let ok = !r.hashCommentNeedsSpace || lc != [S("#")] || i == from || Self.isSpace(s[i - 1]) || s[i - 1] == ";"
                let rustAttr = r.rustAttrs && lc == [S("#")] && i + 1 < limit && s[i + 1] == "["
                if ok && !rustAttr {
                    let e = lineEnd(i, limit); add(i, e, .comment); i = e; continue
                }
            }
            if let (o, cl) = r.blockComment, has(o, at: i, limit: limit) {
                var j = i + o.count, depth = 1
                while j < limit {
                    if r.nestedBlock, has(o, at: j, limit: limit) { depth += 1; j += o.count; continue }
                    if has(cl, at: j, limit: limit) { depth -= 1; j += cl.count; if depth == 0 { break }; continue }
                    j += 1
                }
                add(i, min(j, limit), .comment); i = min(j, limit); continue
            }

            // strings
            if r.quotes.contains(c) {
                if r.rustLifetimes, c == "'" {
                    // 'a' / '\n' are chars; 'a (no closing quote right after) is a lifetime
                    if i + 2 < limit, s[i + 1] != "\\", s[i + 2] == "'" { add(i, i + 3, .string); i += 3; continue }
                    if i + 1 < limit, s[i + 1] == "\\" { let e = stringEnd(i, c, r, limit); add(i, e, .string); i = e; continue }
                    var j = i + 1
                    while j < limit, Self.isIdentPart(s[j]) { j += 1 }
                    add(i, j, .attribute); i = max(j, i + 1); continue
                }
                let e = stringEnd(i, c, r, limit)
                var kind = SyntaxKind.string
                if r.keyStrings, nextNonSpace(e, limit) == ":" { kind = .property }
                add(i, e, kind); i = e; cmdPos = afterAssign; afterAssign = false; continue
            }

            // numbers
            if Self.isDigit(c) || (c == "." && i + 1 < limit && Self.isDigit(s[i + 1]) && !(i > 0 && Self.isIdentPart(s[i - 1]))) {
                let e = numberEnd(i, limit); add(i, max(e, i + 1), .number); i = max(e, i + 1); cmdPos = afterAssign; afterAssign = false; continue
            }

            // variables
            if r.dollarVars, c == "$" {
                var j = i + 1
                if j < limit, s[j] == "{" {
                    while j < limit, s[j] != "}", s[j] != "\n" { j += 1 }
                    j = min(j + 1, limit)
                } else if j < limit, s[j] == "(" {
                    // $( ... ): leave the command substitution to the scanner, color only the sigil
                    add(i, i + 1, .variable); i += 1; cmdPos = true; continue
                } else if j < limit, Self.isIdentPart(s[j]) {
                    while j < limit, Self.isIdentPart(s[j]) { j += 1 }
                } else if j < limit, "@*#?$!-0123456789".unicodeScalars.contains(s[j]) { j += 1 }
                add(i, j, .variable); i = max(j, i + 1); cmdPos = false; continue
            }
            // attributes / directives
            if r.atAttributes, c == "@", i + 1 < limit, Self.isIdentStart(s[i + 1]) {
                var j = i + 1
                while j < limit, Self.isIdentPart(s[j]) || s[j] == "." { j += 1 }
                add(i, j, .attribute); i = j; continue
            }
            if r.rustAttrs, c == "#", i + 1 < limit, s[i + 1] == "[" || (s[i + 1] == "!" && i + 2 < limit && s[i + 2] == "[") {
                var j = i + 1, depth = 0
                while j < limit {
                    if s[j] == "[" { depth += 1 } else if s[j] == "]" { depth -= 1; if depth == 0 { j += 1; break } }
                    j += 1
                }
                add(i, min(j, limit), .attribute); i = min(j, limit); continue
            }
            if r.swiftDirectives, c == "#", lineStart || r.atAttributes, i + 1 < limit, Self.isIdentStart(s[i + 1]) {
                var j = i + 1
                while j < limit, Self.isIdentPart(s[j]) { j += 1 }
                add(i, j, .keyword); i = j; continue
            }

            // bash words
            if r.bash, c != "|", c != "&", c != ";", c != "(", c != ")", c != "{", c != "}", c != "<", c != ">", c != "`", c != "=" {
                var j = i
                while j < limit, !Self.isSpace(s[j]), !"|&;()<>$\"'`=".unicodeScalars.contains(s[j]) { j += 1 }
                if j == i { j = i + 1 }
                let word = String(String.UnicodeScalarView(s[i..<j]))
                let isAssign = j < limit && s[j] == "=" && word.unicodeScalars.allSatisfy(Self.isIdentPart)
                if r.keywords.contains(word) { add(i, j, .keyword); cmdPos = ["then", "else", "elif", "do", "if", "while", "until", "time"].contains(word) }
                else if r.literals.contains(word) { add(i, j, .literal); cmdPos = false }
                else if isAssign { add(i, j, .variable); afterAssign = true }
                else if afterAssign { afterAssign = false; cmdPos = true; if word.unicodeScalars.allSatisfy({ Self.isDigit($0) }) { add(i, j, .number) } }
                else if word.hasPrefix("-"), word.count > 1 { add(i, j, .attribute); cmdPos = false }
                else if cmdPos { add(i, j, .function); cmdPos = false }
                else if word.unicodeScalars.allSatisfy({ Self.isDigit($0) }) { add(i, j, .number) }
                i = j; continue
            }
            if r.bash {
                if c == "|" || c == "&" || c == ";" || c == "(" || c == "`" { cmdPos = true } else if (c == "<" || c == ">") || (c == "=" && !afterAssign) { cmdPos = false }
                i += 1; continue
            }

            // identifiers
            if Self.isIdentStart(c) || r.identExtra.contains(c) {
                var j = i + 1
                while j < limit, Self.isIdentPart(s[j]) || r.identExtra.contains(s[j]) { j += 1 }
                let word = String(String.UnicodeScalarView(s[i..<j]))
                let key = r.caseInsensitive ? word.lowercased() : word
                let afterDot = prevSignificant(i) == "." && !r.caseInsensitive
                var kind = SyntaxKind.plain
                if afterDot {
                    kind = nextNonSpace(j, limit) == "(" ? .function : .plain
                } else if let d = declarator, !r.keywords.contains(key) {
                    kind = d
                } else if r.keywords.contains(key) {
                    kind = .keyword
                } else if r.literals.contains(word) {
                    kind = .literal
                } else if r.types.contains(word) || r.types.contains(key) && r.caseInsensitive {
                    kind = .type
                } else if r.capitalTypes, let f = word.unicodeScalars.first, f.value >= 65, f.value <= 90, word.unicodeScalars.contains(where: { $0.value >= 97 && $0.value <= 122 }) {
                    kind = .type
                } else if nextNonSpace(j, limit) == "(" {
                    kind = .function
                }
                declarator = nil
                if kind == .keyword {
                    switch key {
                    case "def", "func", "fn", "function", "fun": declarator = .function
                    case "class", "struct", "enum", "protocol", "extension", "interface", "trait", "impl", "actor", "object", "namespace", "typealias", "type":
                        declarator = .type
                    default: break
                    }
                    if r.caseInsensitive { declarator = nil }
                }
                add(i, j, kind); i = j; continue
            }
            declarator = nil
            i += 1
        }
    }

    func prevSignificant(_ i: Int) -> S? {
        var j = i - 1
        while j >= 0 {
            if s[j] == " " || s[j] == "\t" { j -= 1; continue }
            return s[j]
        }
        return nil
    }

    /// PHP: color `<?php` / `?>` as meta; anything before the first tag is HTML we leave plain.
    mutating func phpOpen(_ i: Int, _ limit: Int) -> Int {
        let tag = scalars("<?php")
        var j = i
        while j < limit {
            if has(tag, at: j, limit: limit) { add(j, j + 5, .meta); return j + 5 }
            if has(scalars("<?="), at: j, limit: limit) { add(j, j + 3, .meta); return j + 3 }
            j += 1
        }
        return i  // fragment without a tag: treat all as PHP
    }

    // MARK: diff

    mutating func diff() {
        var i = 0
        while i < s.count {
            let e = lineEnd(i, s.count)
            let c = s[i]
            let next: S? = i + 1 < e ? s[i + 1] : nil
            if has(scalars("+++"), at: i, limit: e) || has(scalars("---"), at: i, limit: e) || has(scalars("diff "), at: i, limit: e) || has(scalars("index "), at: i, limit: e) {
                add(i, e, .meta)
            } else if c == "@" && next == "@" {
                add(i, e, .meta)
            } else if c == "+" {
                add(i, e, .inserted)
            } else if c == "-" {
                add(i, e, .deleted)
            }
            i = e + 1
        }
    }

    // MARK: yaml

    mutating func yaml() {
        var r = rules(.yaml)
        r.capitalTypes = false
        var i = 0
        var blockIndent: Int?   // inside a | or > block scalar: lines indented deeper than this are text
        while i < s.count {
            let e = lineEnd(i, s.count)
            var j = i
            while j < e, s[j] == " " { j += 1 }
            let indent = j - i
            if let b = blockIndent {
                if j == e || indent > b { if j < e { add(j, e, .string) }; i = e + 1; continue }
                blockIndent = nil
            }
            if j < e, s[j] == "#" { add(j, e, .comment); i = e + 1; continue }
            if has(scalars("---"), at: j, limit: e) || has(scalars("..."), at: j, limit: e) { add(j, min(j + 3, e), .meta); i = e + 1; continue }
            // list dashes
            var k = j
            while k + 1 < e, s[k] == "-", s[k + 1] == " " { k += 2; while k < e, s[k] == " " { k += 1 } }
            // key:
            var keyEnd: Int?
            if k < e, s[k] != "\"", s[k] != "'", s[k] != "#", s[k] != "[", s[k] != "{" {
                var m = k
                while m < e {
                    if s[m] == ":", m + 1 == e || s[m + 1] == " " { keyEnd = m; break }
                    if s[m] == " ", m + 1 < e, s[m + 1] == "#" { break }
                    m += 1
                }
            } else if k < e, s[k] == "\"" || s[k] == "'" {
                let q = s[k]
                let se = stringEnd(k, q, r, e)
                if se < e, s[se] == ":" { add(k, se, .property); keyEnd = se; k = e }
            }
            var valueStart = k
            if let ke = keyEnd {
                if k < ke { add(k, ke, .property) }
                valueStart = ke + 1
            }
            // value
            var v = valueStart
            while v < e, s[v] == " " { v += 1 }
            if v < e {
                if s[v] == "|" || s[v] == ">" {
                    add(v, min(v + 2, e), .meta)
                    blockIndent = indent
                } else if s[v] == "&" || s[v] == "*" || s[v] == "!" {
                    var m = v + 1
                    while m < e, !Self.isSpace(s[m]) { m += 1 }
                    add(v, m, .attribute)
                    general(r, m, e)
                } else if keyEnd == nil, k == j, !(s[v] == "\"" || s[v] == "'" || s[v] == "[" || s[v] == "{") {
                    // bare scalar in a sequence
                    scalar(v, e, r)
                } else if keyEnd != nil, !(s[v] == "\"" || s[v] == "'" || s[v] == "[" || s[v] == "{" || s[v] == "#") {
                    scalar(v, e, r)
                } else {
                    general(r, v, e)
                }
            }
            i = e + 1
        }
    }

    /// A plain YAML scalar up to an optional ` #comment`.
    mutating func scalar(_ a: Int, _ e: Int, _ r: Rules) {
        var end = e
        var m = a
        while m + 1 < e { if s[m] == " ", s[m + 1] == "#" { end = m; break }; m += 1 }
        var b = end
        while b > a, s[b - 1] == " " { b -= 1 }
        let word = String(String.UnicodeScalarView(s[a..<b]))
        if r.literals.contains(word) { add(a, b, .literal) }
        else if Double(word.replacingOccurrences(of: "_", with: "")) != nil || word.hasPrefix("0x") { add(a, b, .number) }
        else if b > a { add(a, b, .string) }
        if end < e { add(end + 1, e, .comment) }
    }

    // MARK: html / xml

    mutating func html() {
        var i = 0
        let n = s.count
        let open = scalars("<!--"), close = scalars("-->")
        while i < n {
            if has(open, at: i, limit: n) {
                var j = i + 4
                while j < n, !has(close, at: j, limit: n) { j += 1 }
                let e = min(j + 3, n); add(i, e, .comment); i = e; continue
            }
            if s[i] == "<", i + 1 < n, s[i + 1] == "!" || s[i + 1] == "?" {
                let e = min(lineEndOr(i, ">"), n); add(i, e, .meta); i = e; continue
            }
            if s[i] == "<", i + 1 < n, Self.isIdentStart(s[i + 1]) || s[i + 1] == "/" {
                var j = i + 1
                if s[j] == "/" { j += 1 }
                let nameStart = j
                while j < n, Self.isIdentPart(s[j]) || s[j] == "-" || s[j] == ":" || s[j] == "." { j += 1 }
                add(nameStart, j, .tag)
                // attributes up to >
                while j < n, s[j] != ">" {
                    let c = s[j]
                    if c == "\"" || c == "'" {
                        var m = j + 1
                        while m < n, s[m] != c { m += 1 }
                        add(j, min(m + 1, n), .string); j = min(m + 1, n); continue
                    }
                    if Self.isIdentStart(c) || c == "@" || c == ":" || c == "#" {
                        var m = j + 1
                        while m < n, Self.isIdentPart(s[m]) || s[m] == "-" || s[m] == ":" || s[m] == "." { m += 1 }
                        add(j, m, .property); j = m; continue
                    }
                    j += 1
                }
                i = min(j + 1, n); continue
            }
            if s[i] == "&" {
                var j = i + 1
                while j < n, Self.isIdentPart(s[j]) || s[j] == "#" { j += 1 }
                if j < n, s[j] == ";" { add(i, j + 1, .number); i = j + 1; continue }
            }
            i += 1
        }
    }

    func lineEndOr(_ i: Int, _ ch: S) -> Int {
        var j = i
        while j < s.count, s[j] != ch { j += 1 }
        return j + 1
    }

    // MARK: css

    mutating func css() {
        var i = 0
        let n = s.count
        var depth = 0
        var stmtStart = true
        var inValue = false
        while i < n {
            let c = s[i]
            if Self.isSpace(c) { i += 1; continue }
            if has(scalars("/*"), at: i, limit: n) {
                var j = i + 2
                while j < n, !has(scalars("*/"), at: j, limit: n) { j += 1 }
                let e = min(j + 2, n); add(i, e, .comment); i = e; continue
            }
            if c == "\"" || c == "'" {
                var r = Rules(); r.quotes = [c]
                let e = stringEnd(i, c, r, n); add(i, e, .string); i = e; continue
            }
            if c == "{" { depth += 1; stmtStart = true; inValue = false; i += 1; continue }
            if c == "}" { depth = max(0, depth - 1); stmtStart = true; inValue = false; i += 1; continue }
            if c == ";" { stmtStart = true; inValue = false; i += 1; continue }
            if c == "@" {
                var j = i + 1
                while j < n, Self.isIdentPart(s[j]) || s[j] == "-" { j += 1 }
                add(i, j, .keyword); i += max(1, j - i); continue
            }
            if c == "#", i + 1 < n, depth > 0 || inValue, Self.isIdentPart(s[i + 1]) {
                var j = i + 1
                while j < n, Self.isIdentPart(s[j]) { j += 1 }
                add(i, j, .number); i = j; continue
            }
            if Self.isDigit(c) || (c == "-" || c == ".") && i + 1 < n && Self.isDigit(s[i + 1]) {
                let e = numberEnd(i + ((c == "-") ? 1 : 0), n)
                var j = e
                if j < n, s[j] == "%" { j += 1 }
                add(i, j, .number); i = j; continue
            }
            if Self.isIdentStart(c) || c == "-" || c == "." || c == "#" || c == ":" || c == "*" {
                var j = i
                if c == "." || c == "#" || c == ":" { j += 1; while j < n, s[j] == ":" { j += 1 } }
                while j < n, Self.isIdentPart(s[j]) || s[j] == "-" { j += 1 }
                if j == i { i += 1; continue }
                if depth > 0, stmtStart, nextNonSpace(j, n) == ":", c != ":" {
                    add(i, j, .property); stmtStart = false; inValue = true; i = j; continue
                }
                stmtStart = false
                if depth == 0 || (!inValue && stmtStart) {
                    add(i, j, c == ":" ? .keyword : .type)
                } else if j < n, s[j] == "(" {
                    add(i, j, .function)
                } else if c == "!" || css(word: i, j) { add(i, j, .keyword) }
                i = j; continue
            }
            if c == "!" {
                var j = i + 1
                while j < n, Self.isIdentPart(s[j]) { j += 1 }
                add(i, j, .keyword); i = j; continue
            }
            if c == ":" && depth > 0 { inValue = true }
            i += 1
        }
    }

    func css(word a: Int, _ b: Int) -> Bool {
        let w = String(String.UnicodeScalarView(s[a..<b]))
        return ["inherit", "initial", "unset", "none", "auto", "important"].contains(w)
    }
}

private extension Unicode.Scalar {
    init(_ c: Character) { self = c.unicodeScalars.first! }
}
