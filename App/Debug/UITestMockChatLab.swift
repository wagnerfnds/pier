import Foundation

/// `-uiTestChatLab 1` (with the mock): a chat built to strain the conversation screen, for measuring it and catching
/// glitches. Its record is long (60 turns) and its replies are what agents really write and what breaks renderers: wide
/// tables with long cells, nested lists with code under an item, quotes holding lists, task lists, long links and
/// paths without spaces, emoji, CJK and right-to-left text. A message sent to it streams a reply the way Claude Code
/// does: words growing in the draft, then the record has the block while the screen still shows it for a moment (the
/// overlap a chat must not draw twice), then the turn ends. The reply carries a marker (`streamMarker`) a test can count.
struct MockChatLab {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "uiTestChatLab") }
    static let name = "chatlab-claude-z9"
    static let title = "Chat lab: rendering and streaming"
    static let streamMarker = "streamcheck-7f3a"

    /// The reply being written, as `GET .../draft` answers it (nil when the agent writes nothing).
    var draft: String?
    /// Sends to the lab, to vary the streamed reply's first line.
    var sent = 0

    // MARK: the record

    static func transcript(firstOffset: Int) -> [[String: Any]] {
        var off = firstOffset
        func item(_ kind: String, _ extra: [String: Any]) -> [String: Any] {
            off += 1000
            var it: [String: Any] = ["id": "cl@\(off).1", "kind": kind, "off": off]
            for (k, v) in extra { it[k] = v }
            return it
        }
        var out: [[String: Any]] = []
        // `-uiTestChatLabTail <n>`: the record ends with reply n (screenshots of each kind of reply at the bottom).
        let tail = UserDefaults.standard.string(forKey: "uiTestChatLabTail").flatMap { Int($0) } ?? 59 % replies.count
        let shift = (tail - 59 % replies.count + replies.count) % replies.count
        for turn in 0..<60 {
            let pick = (turn + shift) % replies.count
            let reply = replies[pick]
            out.append(item("user", ["text": prompts[pick] + (turn >= prompts.count ? " (\(turn / prompts.count + 1))" : "")]))
            out.append(item("tools", ["verb": "Read", "done": true, "items": [
                ["id": "toolu_lab_\(off)_0", "verb": "Read", "target": "src/billing/totals.ts", "at": 1_791_408_804_607],
                ["id": "toolu_lab_\(off)_1", "verb": "Read", "target": "src/billing/discounts.ts", "at": 1_791_408_804_907],
            ]]))
            if turn % 3 == 0 {
                out.append(item("text", ["text": "Let me check how the totals are rounded before changing anything."]))
                out.append(item("tools", ["verb": "Run", "done": true, "items": [
                    ["id": "toolu_lab_\(off)_r", "verb": "Run", "target": "pnpm test --filter billing", "at": 1_791_408_805_607],
                ]]))
            }
            if turn % 4 == 1 { out.append(item("edit", ["file": "src/billing/totals.ts", "added": 12, "removed": 3, "tool": "toolu_lab_edit_\(off)"])) }
            out.append(item("text", ["text": reply]))
        }
        return out
    }

    static let prompts = [
        "Compare the three ways we could store the invoice totals",
        "Why does the discount round wrong? Explain step by step",
        "Write the migration and tell me how to run it",
        "Summarize what changed in this branch",
        "List what is left before we can ship",
        "Show me the error and where it comes from",
        "Give me the links and paths I need",
        "Explain it in Portuguese and Japanese for the team",
    ]

    static let replies = [
        """
        ## Three ways to store the totals

        | Option | How it works | What it costs | When to pick it |
        |---|---|---|---|
        | `Decimal` in Swift and `NUMERIC(12,2)` in Postgres | Exact base-10 arithmetic end to end; the API sends strings like `"19.90"` so no client ever sees a binary float | A little more code at the edges (parsing, formatting) and slower math, which does not matter at this volume | The default for money: nothing rounds behind your back |
        | Integer cents (`Int64`) | Store `1990` for R$ 19,90 and divide only for display | Every currency needs its minor unit; percent discounts still need a rounding rule | When you sum a lot of values and want it fast |
        | `Double` | Binary floating point | 0.1 + 0.2 ≠ 0.3: the bug you are seeing | Never for money |

        I'd go with **`Decimal`**: it matches what the accountants expect and the change is local to `BillingTotals`.
        """,
        """
        The discount rounds wrong because it is applied **after** the tax on a `Double`:

        1. The cart sums the items: `19.90 + 5.10 = 25.000000000000004`.
        2. The tax is added on that value, so the error grows:
           ```swift
           let taxed = subtotal * 1.0925   // 27.312500000000004
           ```
        3. The 10% discount is taken from the taxed value and rounded *half-even*:
           - expected: R$ 24,58
           - got: R$ 24,59
             - because `24.585000000000004` is just above the midpoint
        4. Fix: compute in `Decimal`, apply the discount first, round once at the end with `.plain`.

        > **Note:** the receipts already sent keep their old totals; only new invoices change.
        > - 3 invoices this month are affected
        > - none of them is paid yet
        """,
        """
        Migration:

        ```sql
        ALTER TABLE invoices ALTER COLUMN total TYPE NUMERIC(12,2) USING round(total::numeric, 2);
        ALTER TABLE invoices ADD COLUMN discount NUMERIC(12,2) NOT NULL DEFAULT 0; -- applied before tax from now on
        ```

        Run it with:

            pnpm db:migrate --env staging

        Then check the totals:

        ~~~bash
        psql "$DATABASE_URL" -c "select id, total from invoices order by id desc limit 5"
        ~~~
        """,
        """
        What changed in `feat/billing-api`:

        - **Totals** now use `Decimal` (`BillingTotals.swift`, `totals.ts`)
        - **Discounts** apply before tax
          - percent discounts round once, at the end
          - fixed discounts can't take a total below zero
        - **Migration** `0042_numeric_totals.sql`
        - **Tests**: 18 new cases in `BillingTotalsTests`, all green

        ---

        Nothing was pushed yet.
        """,
        """
        Before we ship:

        - [x] Totals in `Decimal`
        - [x] Migration on staging
        - [ ] Backfill the 3 open invoices
        - [ ] Update the receipt template (the discount line moves above the tax)
        - [ ] Tell support about the new rounding

        1. Backfill first
        2. Then the template
        3. Then announce it
        """,
        """
        The error:

        ```
        TypeError: Cannot read properties of undefined (reading 'amount')
            at applyDiscount (src/billing/discounts.ts:42:31)
            at computeTotals (src/billing/totals.ts:88:14)
            at async POST /api/invoices (src/routes/invoices.ts:23:5)
        ```

        It comes from `applyDiscount` when a coupon has no `amount` (percent coupons only have `percent`). A one-line guard fixes it, and a test covers both kinds.
        """,
        """
        Links and paths:

        - Dashboard: https://dashboard.example.com/projects/acme-web/billing/invoices?status=open&sort=-created_at&page=1&per_page=50
        - Spec: <https://example.com/docs/billing/rounding-and-discounts-for-invoices-and-receipts>
        - The file with the bug: `/home/ubuntu/code/acme-web/src/billing/discounts/percentage/applyPercentageDiscountToInvoiceLineItems.ts`
        - A commit: `9f3c2a1b7e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b`
        - A token-like id with no spaces: q8ZfT3vK9mWb2XpL7nR4sY6uH1jC5dE0aG3iO8kN2tV7wQ9zB4xM6yS1rU5eF0hJq8ZfT3vK9mWb2XpL7nR4

        Every link opens in the browser.
        """,
        """
        **Português:** o desconto agora é aplicado antes do imposto, e o total é arredondado uma vez só, no fim. 🎉

        **日本語:** 割引は税金の前に適用され、合計は最後に一度だけ丸められます。

        **עברית:** ההנחה מוחלת לפני המס, והסכום מעוגל פעם אחת בסוף.

        **Emoji:** ✅ testes · 💸 totais · 🧾 recibos · 👩🏽‍💻 equipe
        """,
    ]

    // MARK: the reply streamed after a send

    static func streamedReply(_ n: Int) -> String {
        """
        ## Reply \(n): the plan (\(streamMarker))

        I read the billing module and the failing test. Here is what I will do, in order:

        1. Move the totals to `Decimal`, so nothing rounds behind our back.
        2. Apply the discount **before** the tax, and round once at the end.
        3. Add the migration for the existing invoices:
           ```sql
           ALTER TABLE invoices ALTER COLUMN total TYPE NUMERIC(12,2);
           ```
        4. Cover both coupon kinds with tests.

        | Step | File | Risk |
        |---|---|---|
        | Totals | `BillingTotals.swift` | Low: the API already sends strings |
        | Discounts | `discounts.ts` | Medium: receipts show a new line order |

        Tell me if you want the receipts changed in the same PR.
        """
    }
}
