# Block-structure agreement of a parser's skeletons with the reference (markdown-it, CommonMark + GFM tables).
import json, sys, collections
corpus = json.load(open(sys.argv[1])); ref = json.load(open(sys.argv[2])); ours = json.load(open(sys.argv[3]))
show = int(sys.argv[4]) if len(sys.argv) > 4 else 0
def kind(b): return b.split("(")[0].rstrip("0123456789x") if not b.startswith("h") else "heading"
total = len(corpus); rich = [i for i in range(total) if any(b != "p" for b in ref[i])]
ok_all = sum(ref[i] == ours[i] for i in range(total)); ok_rich = sum(ref[i] == ours[i] for i in rich)
print(f"exact block-structure agreement: all {ok_all}/{total} = {100*ok_all/total:.1f}%   rich (any non-paragraph block) {ok_rich}/{len(rich)} = {100*ok_rich/len(rich):.1f}%")
# Per feature: documents whose reference has the feature, and how many of those match exactly.
feat = collections.defaultdict(lambda: [0, 0])
for i in range(total):
    kinds = {kind(b) for b in ref[i]}
    for k in kinds:
        feat[k][0] += 1; feat[k][1] += ref[i] == ours[i]
print("per feature (docs with it in the reference: exact matches):", {k: f"{v[1]}/{v[0]}" for k, v in sorted(feat.items())})
# First difference, by kind of the reference block there
first = collections.Counter(); examples = collections.defaultdict(list)
for i in range(total):
    a, b = ref[i], ours[i]
    if a == b: continue
    j = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
    key = (a[j] if j < len(a) else "<end>") + " vs " + (b[j] if j < len(b) else "<end>")
    key = key.split("(")[0] + "…" if "list(" in key else key
    first[key] += 1; examples[key].append(i)
print("first differences:", first.most_common(15))
if show:
    for key, idx in list(examples.items())[:show]:
        i = idx[0]
        print("\n=====", key, "doc", i, "\nref:", ref[i], "\nours:", ours[i], "\n---\n", corpus[i][:1500])
