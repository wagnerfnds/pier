#!/bin/zsh
# How closely the chat's Markdown reader (PierKit's MarkdownBlocks) agrees with a CommonMark + GFM parser
# (markdown-it 14, which passes the CommonMark spec) on the block structure of agents' replies: headings, paragraphs,
# lists and their nesting, code, quotes, tables, rules.
#
#   Tools/markdown-conformance/run.sh            # the edge cases in edge.json, plus the replies of this machine's
#                                                # Claude Code records (~/.claude/projects), read locally, never kept
#   Tools/markdown-conformance/run.sh --edge     # the edge cases only
#
# Needs swiftc, node and npm (markdown-it is installed into a temporary folder). Nothing it reads leaves the machine.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/ref"
(cd "$work/ref" && npm init -y >/dev/null 2>&1 && npm install markdown-it@14 --no-audit --no-fund >/dev/null 2>&1)
swiftc -O -o "$work/skeleton" "$repo/Packages/PierKit/Sources/PierKit/Support/MarkdownBlocks.swift" "$here/main.swift"

check() {
  local name=$1 corpus=$2
  node "$here/reference.js" "$work/ref" "$corpus" "$work/$name-ref.json"
  "$work/skeleton" "$corpus" "$work/$name-ours.json"
  echo "== $name"
  python3 -I "$here/compare.py" "$corpus" "$work/$name-ref.json" "$work/$name-ours.json"
}

check edge "$here/edge.json"
if [[ "${1:-}" != "--edge" && -d ~/.claude/projects ]]; then
  python3 -I "$here/extract.py" "$work/replies.json" 3000
  check replies "$work/replies.json"
fi
