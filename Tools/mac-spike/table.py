"""Track 7 spike: the table of the PR, the medians per build of `run.sh measure`.

usage: python3 -I table.py <runs dir>
"""
import glob
import json
import os
import statistics
import sys

d = sys.argv[1]
runs = {}
for p in glob.glob(os.path.join(d, "*.json")):
    r = json.load(open(p))
    scen = os.path.basename(p).split("-")[0]
    runs.setdefault((scen, r["label"]), []).append(r)


def get(r, *path):
    for k in path:
        if not isinstance(r, dict):
            return None
        r = r.get(k)
    return r


def med(scen, label, *path, fmt="{:.2f}"):
    vals = [get(r, *path) for r in runs.get((scen, label), [])]
    vals = [v for v in vals if isinstance(v, (int, float))]
    if not vals:
        return "–"
    return fmt.format(statistics.median(vals))


def nav_kind(label, kind):
    vals = []
    for r in runs.get(("nav", label), []):
        for s in r.get("nav_perf", []):
            k = "session" if s["step"].startswith("session") else s["step"].rstrip("0123456789")
            if k == kind:
                vals.append(s["first_frame_ms"])
    return f"{statistics.median(vals):.0f}" if vals else "–"


def nav_max(label, kind):
    vals = []
    for r in runs.get(("nav", label), []):
        for s in r.get("nav_perf", []):
            k = "session" if s["step"].startswith("session") else s["step"].rstrip("0123456789")
            if k == kind:
                vals.append(s["first_frame_ms"])
    return f"{max(vals):.0f}" if vals else "–"


def loops(label):
    out = []
    for r in runs.get(("nav", label), []):
        fp = [l.split("footprint_mb=")[1] for l in r.get("nav_perf_loops", [])]
        out.append("→".join(fp) + (f"→{r.get('footprint_mb_end'):.0f}" if r.get("footprint_mb_end") else ""))
    return " / ".join(out) or "–"


labels = ["cat-full", "native-surface", "cat-noplugin", "native"]
print("| | " + " | ".join(labels) + " |")
print("|---|" + "---|" * len(labels))
rows = [
    ("First window after launch (s)", lambda l: med("idle", l, "first_window_s")),
    ("CPU in the first ~22 s, launch + long chat (s)", lambda l: med("idle", l, "cpu_s_through_settle", fmt="{:.1f}")),
    ("Idle CPU, long chat open, 60 s (%)", lambda l: med("idle", l, "idle", "cpu_percent")),
    ("Memory, physical footprint (MB)", lambda l: med("idle", l, "idle", "footprint_mb", fmt="{:.0f}")),
    ("Threads", lambda l: med("idle", l, "idle", "threads", fmt="{:.0f}")),
    ("AX: first full walk, wall (s)", lambda l: med("idle", l, "ax", "walk_first", "seconds")),
    ("AX: first full walk, app CPU (s)", lambda l: med("idle", l, "ax", "walk_first", "app_cpu_s")),
    ("AX: first walk, slowest single call (ms)", lambda l: med("idle", l, "ax", "walk_first", "slowest_node_ms", fmt="{:.0f}")),
    ("AX: second walk, nodes", lambda l: med("idle", l, "ax", "walk_second", "nodes", fmt="{:.0f}")),
    ("AX: second walk, wall (s)", lambda l: med("idle", l, "ax", "walk_second", "seconds", fmt="{:.3f}")),
    ("AX: window query like a window manager, median / p95 (ms)",
     lambda l: med("idle", l, "ax", "window_queries", "median_ms") + " / " + med("idle", l, "ax", "window_queries", "p95_ms")),
    ("Idle CPU after the AX walks, 20 s (%)", lambda l: med("idle", l, "after_ax", "cpu_percent_20s")),
    ("Navigation: open a session, median first frame (ms)", lambda l: nav_kind(l, "session")),
    ("Navigation: open a session, worst (ms)", lambda l: nav_max(l, "session")),
    ("Navigation: back to Home, median (ms)", lambda l: nav_kind(l, "home")),
    ("Navigation: Inbox / Board / Projetos (ms)", lambda l: f"{nav_kind(l, 'inbox')} / {nav_kind(l, 'board')} / {nav_kind(l, 'projects')}"),
    ("Navigation: project / worktree (ms)", lambda l: f"{nav_kind(l, 'project')} / {nav_kind(l, 'worktree')}"),
    ("Navigation: median hitch per step (ms)", lambda l: med("nav", l, "nav_perf_summary", "median_hitch_ms", fmt="{:.0f}")),
    ("Navigation: footprint after each walk (MB)", lambda l: loops(l)),
    ("Long chat, fling scroll: hitch time (ms/s)", lambda l: med("chat", l, "chat_perf", "scroll", "hitch_ms_per_s", fmt="{:.1f}")),
    ("Long chat, fling scroll: longest frame (ms)", lambda l: med("chat", l, "chat_perf", "scroll", "longest_frame_ms", fmt="{:.0f}")),
    ("Long chat, reply streaming: hitch time (ms/s)", lambda l: med("chat", l, "chat_perf", "stream", "hitch_ms_per_s", fmt="{:.1f}")),
    ("Long chat, reply streaming: longest frame (ms)", lambda l: med("chat", l, "chat_perf", "stream", "longest_frame_ms", fmt="{:.0f}")),
    ("Idle CPU with the indicators animating, 60 s (%)", lambda l: med("chat", l, "idle", "cpu_percent")),
]
for name, f in rows:
    print(f"| {name} | " + " | ".join(f(l) for l in labels) + " |")
