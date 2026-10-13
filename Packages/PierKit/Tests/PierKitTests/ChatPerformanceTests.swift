import Foundation
import Testing

@testable import PierKit

/// What the conversation screen computes on the main actor, timed against a frame (16.7 ms at 60 Hz, 8.3 ms at 120 Hz):
/// the Markdown of a long reply, the fold of a full transcript window, a poll merged into the store, the draft check.
/// The bounds are loose (a debug build on a shared machine) and catch a regression of an order of magnitude; the
/// numbers themselves go to the log (`swift test -c release --filter ChatPerformanceTests` for the real ones).
@Suite struct ChatPerformanceTests {
    /// Median of `runs` timings, in milliseconds.
    private func median(_ runs: Int = 15, _ work: () -> Void) -> Double {
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<runs {
            let d = clock.measure(work)
            times.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        return times.sorted()[runs / 2]
    }

    /// A 32 KB reply (pierd's cap for a text item) of what agents write: headings, lists, a table, code.
    private static let longReply: String = {
        let unit = """
        ## Step

        Some words about the change, with `inline code`, **bold** and a [link](https://example.com/a/b).

        1. First item
           - nested item with `code`
           ```swift
           let total = items.reduce(Decimal(0)) { $0 + $1.price }
           ```
        2. Second item

        | File | Change | Risk |
        |---|---|---|
        | totals.ts | Decimal math | Low |
        | discounts.ts | order of tax and discount | Medium |

        > A note that matters.

        """
        var s = ""
        while s.utf8.count < 32 << 10 { s += unit }
        return s
    }()

    private static func window() -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var off: Int64 = 0
        for turn in 0..<75 {
            off += 1; items.append(TranscriptItem(kind: "user", id: "cl@\(off).1", off: off, text: "prompt \(turn)"))
            off += 1; items.append(TranscriptItem(kind: "tools", id: "cl@\(off).1", off: off, verb: "Read",
                                                  items: [.init(verb: "Read", target: "a.swift", id: "t\(off)")], done: true))
            off += 1; items.append(TranscriptItem(kind: "text", id: "cl@\(off).1", off: off, text: "a note \(turn)"))
            off += 1; items.append(TranscriptItem(kind: "text", id: "cl@\(off).1", off: off, text: longReply.prefix(2000).description))
        }
        return items
    }

    @Test func markdownOfALongReply() {
        let ms = median { _ = MarkdownBlocks.parse(Self.longReply) }
        print("CHAT-BENCH markdown_parse_32KB_ms=\(String(format: "%.2f", ms))")
        #expect(ms < 250)
    }

    @Test func foldOfAFullWindow() {
        let items = Self.window()
        let ms = median { _ = ConversationFold.blocks(items, live: true) }
        print("CHAT-BENCH fold_300_items_ms=\(String(format: "%.3f", ms))")
        #expect(ms < 50)
    }

    @Test func pollMergedIntoTheStore() {
        let items = Self.window()
        var base = TranscriptStore()
        base.apply(TranscriptPage(source: "claude", items: items, next: items.count, gen: "g", file: "f"))
        let fresh = [TranscriptItem(kind: "text", id: "cl@9999.1", off: 9999, text: "new words")]
        let ms = median {
            var s = base
            s.apply(TranscriptPage(source: "claude", items: fresh, next: items.count + 1, gen: "g", file: "f"))
        }
        print("CHAT-BENCH poll_apply_300_items_ms=\(String(format: "%.3f", ms))")
        #expect(ms < 50)
    }

    @Test func draftCheckAgainstTheRecord() {
        let items = Self.window() + [TranscriptItem(kind: "user", id: "u", off: 99_999, text: "go"),
                                     TranscriptItem(kind: "text", id: "x", off: 100_000, text: Self.longReply)]
        let draft = String(Self.longReply.suffix(3000))
        let ms = median { _ = DraftEcho.isRecorded(draft, in: items) }
        print("CHAT-BENCH draft_echo_32KB_ms=\(String(format: "%.3f", ms))")
        #expect(ms < 100)
    }
}
