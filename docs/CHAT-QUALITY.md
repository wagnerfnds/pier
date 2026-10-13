# The chat: quality targets and how to check them

What the conversation screen is held to, where each target comes from, and the command that measures it. Results are
from Debug builds on an M-series Mac and the iPhone 17 simulator (2026-10), unless the row says otherwise.

| Area | Target | How it is measured | Result |
|---|---|---|---|
| Own message on screen | ≤ 100 ms from Send (Nielsen's 0.1 s; any chat app) | `ChatQualityUITests.testOwnMessageShowsAtOnceAndStays`: the bubble is there while the undo window runs and never leaves | drawn in the frame of the tap (before: only after the 2 s undo window and the round trip; the test fails on the old code) |
| A reply drawn twice | never | `ChatQualityUITests.testStreamedReplyNeverShowsTwice` (the chat lab keeps a finished block on screen 2 s after the record has it, as Claude Code does) | 0 (before: 2 copies at the end of every turn; the test fails on the old code). The app (`DraftEcho`) and pierd (`/draft`) both check |
| Streaming cadence | draft updates ≤ 1 s apart while the words grow | `SessionViewModel.followDraft` | every 0.6 s, 1.5 s while nothing changes (before: 1.5 s, and a slow transcript, screen or review read held it back) |
| Sent exactly once | 0 lost, 0 doubled through retries | one `idem_key` per message, reused by the retry; pierd's `TestSendsWithoutATurnKeepTheirKeys`, `TestARetriedCommandIsTypedOnce` | a send that dies with its connection is sent again on a new one and typed once |
| A dead connection | found well inside the PING watchdog's 30–45 s | `LinkWatch` (PierKit, tested) | two polls failing on the connection (6 s deadlines, 4 s for the draft) drop it; the next request dials the address and, 0.6 s later, the relay (RFC 8305: 100 ms–2 s) |
| Scrolling | hitch time < 5 ms per second (Apple, WWDC20 "Eliminate animation hitches with XCTest") | `-chatPerfProbe 1` (frame pacing by CADisplayLink: scroll 6000 pt and back); on a device, `ChatQualityUITests.testScrollingTheLongConversation` (XCTOSSignpostMetric) | Mac: median 2.8 ms/s (0–5.6 over the runs, a browser using the GPU meanwhile); one run of the earlier build had a single 217 ms frame |
| While a reply streams | no hang (≥ 250 ms main thread, Apple) | the probe's second phase (`-sessionSend <text>`) | ~10 ms of main thread per update; 35–54 ms once at the send and at the turn's end; no hang |
| Cost of an agent at work | as little main thread as possible | Instruments, Time Profiler, the chat open on a working agent | Mac 21 % → 13 % (the working indicators run in Core Animation; the edge tab redraws only its turning rings) |
| Work per update | far below one frame (8.3 ms at 120 Hz) | `swift test -c release --filter ChatPerformanceTests` | a 32 KB reply's Markdown 1.9 ms, the fold of 300 items 0.22 ms, a poll merged 0.06 ms, the draft check 0.9 ms |
| Server time per poll | small next to the network | `go test -run '^$' -bench . -benchmem ./internal/transcript ./internal/box` | transcript poll ~4 ms (before ~12), draft ~8 ms (its parse 0.05 ms) |
| Markdown | CommonMark 0.31.2 + GFM block structure | `Tools/markdown-conformance/run.sh` (markdown-it 14 as the reference) | 100 % of 3,000 real replies (before 99.5 %; of the 405 with block Markdown, 96.0 % → 100 %), 49 of 50 edge cases (before 32; the one left is raw HTML, drawn as text on purpose) |
| Contrast | WCAG 2.2 AA: 4.5:1 text, 3:1 large text and controls | the theme's colors on the screen, card and raised backgrounds, light and dark | body 11.9–16.4:1, secondary 4.6–6.3:1, links 4.7–6.1:1, tertiary 3.1–3.8:1 (dark was 2.4–2.9:1); what must be read uses the secondary tone |
| Memory | no growth from reply to reply | `ChatQualityUITests.testStreamingCost` (XCTMemoryMetric) | peak ~77 MB with the 60-turn chat lab; −0.8 MB over three streamed replies |

The chat lab (`-uiTestMock 1 -uiTestChatLab 1 -openSession chatlab-claude-z9`, `-uiTestChatLabTail <n>` for which reply
ends the record) is the conversation these run against: 60 turns of what agents write and what breaks readers (wide
tables, code under list items, quotes holding lists, task lists, long links and paths, emoji, CJK, right to left).

Not measured here: hitch time on an iPhone (no device was attached; run `testScrollingTheLongConversation` on one), and
end-to-end latency against a real box (`RealBoxUITests` measures send-to-reply with `TEST_RUNNER_REAL_SESSION`).
