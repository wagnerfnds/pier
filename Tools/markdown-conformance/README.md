# Markdown conformance

How closely the chat's Markdown reader (`MarkdownBlocks`, PierKit) agrees with markdown-it 14 (CommonMark 0.31.2, which
it passes, plus GFM tables) on the **block structure** of agents' replies: headings, paragraphs, lists and their nesting,
fenced and indented code, quotes, tables (rows × columns), rules. Inline Markdown is Foundation's
`AttributedString(markdown:)` and is not compared here.

```sh
Tools/markdown-conformance/run.sh          # edge.json, then the replies in this machine's Claude Code records
Tools/markdown-conformance/run.sh --edge   # edge.json only
```

- `edge.json`: 50 cases where readers differ (setext headings, closing `#`s, fences inside list items, tables without
  outer pipes or with escaped pipes, lazy continuations, CommonMark list numbering, tabs, nested quotes).
- The replies are read from `~/.claude/projects` into a temporary folder and removed afterwards; only the counts are
  printed. Adjacent lists of one kind count as one (a blank line between items).
- Raw HTML blocks are drawn as text on purpose: the only expected difference.

Needs `swiftc`, `node` and `npm` (markdown-it goes into a temporary folder).
