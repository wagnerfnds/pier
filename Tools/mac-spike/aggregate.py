"""Track 7 spike: every run of `run.sh measure`, per build and scenario (the median and each run's value).

usage: python3 -I aggregate.py <runs dir> [...]
"""
import glob
import json
import os
import statistics
import sys

rows = {}
for d in sys.argv[1:]:
    for p in sorted(glob.glob(os.path.join(d, "*.json"))):
        r = json.load(open(p))
        scen = os.path.basename(p).split("-")[0]
        rows.setdefault((scen, r["label"]), []).append(r)


def med(vals):
    vals = [v for v in vals if isinstance(v, (int, float))]
    if not vals:
        return "-"
    m = statistics.median(vals)
    return f"{m:g}" + (f" ({', '.join(f'{v:g}' for v in vals)})" if len(vals) > 1 else "")


def get(r, *path):
    for k in path:
        if not isinstance(r, dict):
            return None
        r = r.get(k)
    return r


for (scen, label), rs in sorted(rows.items()):
    print(f"== {scen} / {label}: {len(rs)} run(s); in front: {[r.get('front_is_app') for r in rs]}")
    if scen in ("idle", "home", "empty"):
        print("  first window s     ", med([r.get("first_window_s") for r in rs]))
        print("  cpu s by settle    ", med([r.get("cpu_s_through_settle") for r in rs]))
        print("  idle cpu %         ", med([get(r, "idle", "cpu_percent") for r in rs]))
        print("  idle rss MB        ", med([get(r, "idle", "rss_mb_end") for r in rs]))
        print("  idle footprint MB  ", med([get(r, "idle", "footprint_mb") for r in rs]))
        print("  threads            ", med([get(r, "idle", "threads") for r in rs]))
        print("  ax nodes           ", med([get(r, "ax", "walk_first", "nodes") for r in rs]))
        print("  ax walk1 s         ", med([get(r, "ax", "walk_first", "seconds") for r in rs]))
        print("  ax walk1 app cpu s ", med([get(r, "ax", "walk_first", "app_cpu_s") for r in rs]))
        print("  ax walk2 s         ", med([get(r, "ax", "walk_second", "seconds") for r in rs]))
        print("  ax walk2 app cpu s ", med([get(r, "ax", "walk_second", "app_cpu_s") for r in rs]))
        print("  ax ms/node (walk2) ", med([get(r, "ax", "walk_second", "ms_per_node") for r in rs]))
        print("  ax window query ms ", med([get(r, "ax", "window_queries", "median_ms") for r in rs]),
              " p95", med([get(r, "ax", "window_queries", "p95_ms") for r in rs]))
        print("  after ax cpu %     ", med([get(r, "after_ax", "cpu_percent_20s") for r in rs]))
        print("  after ax footprint ", med([get(r, "after_ax", "footprint_mb") for r in rs]))
        for r in rs:
            print("    roles:", get(r, "ax", "walk_first", "roles"), "errors:", get(r, "ax", "walk_first", "errors"),
                  "capped:", get(r, "ax", "walk_first", "capped"))
    elif scen == "nav":
        print("  median first frame ms", med([get(r, "nav_perf_summary", "median_first_frame_ms") for r in rs]))
        print("  max first frame ms   ", med([get(r, "nav_perf_summary", "max_first_frame_ms") for r in rs]))
        print("  median hitch ms      ", med([get(r, "nav_perf_summary", "median_hitch_ms") for r in rs]))
        print("  footprint end MB     ", med([r.get("footprint_mb_end") for r in rs]))
        for r in rs:
            steps = {}
            for s in r.get("nav_perf", []):
                k = "session" if s["step"].startswith("session") else s["step"].rstrip("0123456789")
                steps.setdefault(k, []).append(s["first_frame_ms"])
            print("    per kind (median first frame ms):",
                  {k: round(statistics.median(v), 1) for k, v in sorted(steps.items())})
            print("    session steps:", [ (s["step"], s["first_frame_ms"], s["hitch_ms"]) for s in r.get("nav_perf", []) if s["step"].startswith("session")])
            print("    loops:", r.get("nav_perf_loops"))
    elif scen == "chat":
        for phase in ("scroll", "stream"):
            print(f"  {phase}: hitch ms/s", med([get(r, "chat_perf", phase, "hitch_ms_per_s") for r in rs]),
                  " longest ms", med([get(r, "chat_perf", phase, "longest_frame_ms") for r in rs]),
                  " >50ms", med([get(r, "chat_perf", phase, "frames_over_50ms") for r in rs]),
                  " frames", med([get(r, "chat_perf", phase, "frames") for r in rs]),
                  " hz", med([get(r, "chat_perf", phase, "refresh_hz") for r in rs]))
        print("  animated idle cpu %", med([get(r, "idle", "cpu_percent") for r in rs]))
        print("  footprint MB       ", med([get(r, "idle", "footprint_mb") for r in rs]))
        for r in rs:
            if get(r, "chat_perf", "scroll", "error"):
                print("    scroll error:", get(r, "chat_perf", "scroll", "error"))
