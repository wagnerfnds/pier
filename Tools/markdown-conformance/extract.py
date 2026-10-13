# Extracts assistant text blocks (Markdown replies) from local Claude Code transcripts into a corpus (kept local).
import json, os, sys, random, hashlib
root = os.path.expanduser("~/.claude/projects")
out_path = sys.argv[1]
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
seen, texts = set(), []
for dirpath, _, files in os.walk(root):
    for f in files:
        if not f.endswith(".jsonl"):
            continue
        try:
            with open(os.path.join(dirpath, f), encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if '"assistant"' not in line or '"text"' not in line:
                        continue
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    if o.get("type") != "assistant":
                        continue
                    content = (o.get("message") or {}).get("content")
                    if not isinstance(content, list):
                        continue
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "text":
                            t = b.get("text") or ""
                            if len(t) < 40:
                                continue
                            h = hashlib.sha1(t.encode()).hexdigest()
                            if h in seen:
                                continue
                            seen.add(h)
                            texts.append(t)
        except Exception:
            continue
random.seed(7)
random.shuffle(texts)
texts = texts[:limit]
json.dump(texts, open(out_path, "w"), ensure_ascii=False)
md_feats = {"table": sum("\n|" in t for t in texts), "fence": sum("```" in t for t in texts),
            "heading": sum("\n#" in t or t.startswith("#") for t in texts), "list": sum("\n- " in t or "\n1. " in t for t in texts),
            "quote": sum("\n>" in t for t in texts)}
print(len(seen), "unique replies;", len(texts), "kept;", "features:", md_feats)
