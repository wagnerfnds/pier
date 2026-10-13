import Foundation
import Testing

@testable import PierKit

/// The block shapes, compact: "h2", "p", "code(js)", "quote[p]", "list(•[p], 2.[p,code])", "table 2x3", "hr".
private func shape(_ blocks: [MarkdownBlock]) -> [String] {
    blocks.map { b in
        switch b {
        case .heading(let level, _): "h\(level)"
        case .paragraph: "p"
        case .code(let lang, _): "code(\(lang))"
        case .quote(let inner): "quote[\(shape(inner).joined(separator: ","))]"
        case .list(let items):
            "list(" + items.map { "\($0.marker)\($0.checked.map { $0 ? "x" : "_" } ?? "")[\(shape($0.blocks).joined(separator: ","))]" }.joined(separator: " ") + ")"
        case .table(let header, _, let rows): "table \(rows.count)x\(header.count)"
        case .rule: "hr"
        }
    }
}

private func parse(_ s: String) -> [MarkdownBlock] { MarkdownBlocks.parse(s) }

@Suite struct MarkdownBlocksTests {
    @Test func headings() {
        #expect(parse("# Title ##\n\nText") == [.heading(level: 1, text: "Title"), .paragraph("Text")])
        #expect(parse("Title\n=====") == [.heading(level: 1, text: "Title")])
        #expect(shape(parse("Sub\n---\nmore")) == ["h2", "p"])
        #expect(shape(parse("#hashtag")) == ["p"])
        #expect(shape(parse("####### seven")) == ["p"])
        #expect(parse("## C# and F#") == [.heading(level: 2, text: "C# and F#")])
    }

    @Test func rulesAreNotListsOrHeadings() {
        #expect(shape(parse("para\n\n---\n\nnext")) == ["p", "hr", "p"])
        #expect(shape(parse("- - -")) == ["hr"])
        #expect(shape(parse("a\n***\nb")) == ["p", "hr", "p"])
    }

    @Test func paragraphsKeepTheirLineBreaks() {
        #expect(parse("Line one\nLine two\n  Line three") == [.paragraph("Line one\nLine two\nLine three")])
        #expect(parse("a\r\nb") == [.paragraph("a\nb")])
    }

    @Test func fences() {
        #expect(parse("```swift\nlet a = 1\n\n  b\n```") == [.code(language: "swift", text: "let a = 1\n\n  b")])
        // A longer fence holds a shorter one; tildes hold backticks.
        #expect(parse("````md\n```js\nx\n```\n````\nafter") == [.code(language: "md", text: "```js\nx\n```"), .paragraph("after")])
        #expect(parse("~~~\ncode ~~~ here\n~~~") == [.code(language: "", text: "code ~~~ here")])
        // Streaming: an open fence runs to the end.
        #expect(parse("```\nstill\ncode") == [.code(language: "", text: "still\ncode")])
        // A fence interrupts a paragraph.
        #expect(shape(parse("Run this:\n```bash\nnpm test\n```")) == ["p", "code(bash)"])
        #expect(parse("    indented\n    code") == [.code(language: "", text: "indented\ncode")])
        #expect(shape(parse("para\n    continuation, not code")) == ["p"])
    }

    @Test func tables() {
        guard case .table(let header, let align, let rows)? = parse("| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 |").first else {
            Issue.record("expected a table"); return
        }
        #expect(header == ["a", "b"])
        #expect(align == [.leading, .center])
        #expect(rows == [["1", "2"], ["3", ""]])
        // Outer pipes are optional; an escaped pipe stays in its cell.
        #expect(shape(parse("a | b\n--|--\n1 | 2")) == ["table 1x2"])
        guard case .table(_, _, let r2)? = parse("| a | b |\n|---|---|\n| x \\| y | `z` |").first else { Issue.record("table"); return }
        #expect(r2 == [["x | y", "`z`"]])
        // A table right under a line of text, and one that is not (no delimiter row, or other cell counts).
        #expect(shape(parse("Intro:\n| a | b |\n|---|---|\n| 1 | 2 |")) == ["p", "table 1x2"])
        #expect(shape(parse("| not | a table |\n| no delimiter |")) == ["p"])
        #expect(shape(parse("| a | b |\n|---|")) == ["p"])
    }

    @Test func listsNumberLikeCommonMark() {
        guard case .list(let items)? = parse("1. one\n1. two\n1. three").first else { Issue.record("list"); return }
        #expect(items.map(\.marker) == ["1.", "2.", "3."])
        guard case .list(let from3)? = parse("3) three\n4) four").first else { Issue.record("list"); return }
        #expect(from3.map(\.marker) == ["3)", "4)"])
        // Only a list starting at 1 interrupts a paragraph.
        #expect(shape(parse("text\n2. not a list")) == ["p"])
        #expect(shape(parse("text\n- a list")) == ["p", "list(•[p])"])
    }

    @Test func nestingFollowsTheItemsColumn() {
        #expect(shape(parse("- a\n  - b\n    - c\n- d")) == ["list(•[p,list(•[p,list(•[p])])] •[p])"])
        // Under "1." the content column is 3; four spaces still nest once.
        #expect(shape(parse("1. step\n   - sub\n2. step")) == ["list(1.[p,list(•[p])] 2.[p])"])
        #expect(shape(parse("- a\n    - four-space nested\n- b")) == ["list(•[p,list(•[p])] •[p])"])
    }

    @Test func itemsHoldCodeAndParagraphs() {
        let blocks = parse("1. Run:\n   ```bash\n   npm test\n   ```\n2. Then deploy")
        #expect(shape(blocks) == ["list(1.[p,code(bash)] 2.[p])"])
        guard case .list(let items)? = blocks.first, case .code(_, let code)? = items[0].blocks.last else { Issue.record("code"); return }
        #expect(code == "npm test")
        #expect(shape(parse("- item\n\n  continued paragraph\n- next")) == ["list(•[p,p] •[p])"])
        #expect(shape(parse("- item\nlazy continuation\n- next")) == ["list(•[p] •[p])"])
        guard case .list(let lazy)? = parse("- item\nlazy").first else { Issue.record("lazy"); return }
        #expect(lazy[0].blocks == [.paragraph("item\nlazy")])
        // A blank line between items keeps one list; text after a blank line at the margin ends it.
        #expect(shape(parse("- a\n\n\n- b")) == ["list(•[p] •[p])"])
        #expect(shape(parse("- a\n\nafter")) == ["list(•[p])", "p"])
    }

    @Test func taskLists() {
        guard case .list(let items)? = parse("- [ ] todo\n- [x] done\n- [X] done too").first else { Issue.record("list"); return }
        #expect(items.map(\.checked) == [false, true, true])
        #expect(items.map(\.blocks) == [[.paragraph("todo")], [.paragraph("done")], [.paragraph("done too")]])
    }

    @Test func quotesHoldBlocks() {
        #expect(shape(parse("> quote line\n> > nested\n> - list in quote")) == ["quote[p,quote[p],list(•[p])]"])
        #expect(parse("> quote\nlazy") == [.quote([.paragraph("quote\nlazy")])])
        #expect(shape(parse("> ```\n> code in quote\n> ```")) == ["quote[code()]"])
        // An empty nested quote does not swallow the next paragraph.
        #expect(shape(parse(">>>\ntext")) == ["quote[quote[quote[]]]", "p"])
    }

    @Test func hostileNestingStaysShallow() {
        let deep = String(repeating: ">", count: 5000) + " x"
        #expect(!parse(deep).isEmpty)
        let list = (0..<300).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n")
        #expect(!parse(list).isEmpty)
    }

    @Test func htmlCommentsAreNotShown() {
        #expect(parse("<!-- ccr -->\n## Copilot review\n\nLooks fine.") == [.heading(level: 2, text: "Copilot review"), .paragraph("Looks fine.")])
        #expect(shape(parse("Before\n<!--\nPlease describe\nthe change\n-->\nAfter")) == ["p", "p"])
        // Unclosed: nothing after it is shown, as a page would not show it either.
        #expect(parse("Text\n\n<!-- open") == [.paragraph("Text")])
    }

    @Test func tabsAreFourColumns() {
        #expect(shape(parse("- item\n\t- tab nested")) == ["list(•[p,list(•[p])])"])
        #expect(parse("\tcode") == [.code(language: "", text: "code")])
    }

    @Test func plainTextDropsTheSyntax() {
        let text = MarkdownBlocks.plainText(parse("## Done\n\n- **one**\n- two\n\n```\nx\n```"))
        #expect(text == "Done\n**one**\ntwo\nx")
    }
}
