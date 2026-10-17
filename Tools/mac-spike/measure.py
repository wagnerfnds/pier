"""Track 7 spike: launch one build of the app on the mock box the way a person would (LaunchServices, fresh, in front)
and measure it: time to the first window, CPU through the first seconds, idle CPU and memory over a window of time,
optionally the accessibility tree as a client walks it (`axprobe`), a `sample` of the idle main thread, and the
probes' lines (NAV-PERF, CHAT-PERF). The same for the Catalyst app and PierMac, so the two compare.

With AeroSpace (a tiling window manager) running, set MAC_SPIKE_WORKSPACE to an empty workspace: the window goes there
alone and fills it, so every build gets the same size; MAC_SPIKE_HOME_WORKSPACE is where to go back after.

usage: python3 -I measure.py <App.app> <label> <out.json> [--settle S] [--idle S] [--ax] [--sample]
                             [--wait-for MARK] [--wait-timeout S] -- <app args>
Build axprobe first: xcrun swiftc -O -o Tools/mac-spike/axprobe Tools/mac-spike/axprobe.swift
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

AXPROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "axprobe")
WORKSPACE = os.environ.get("MAC_SPIKE_WORKSPACE") if shutil.which("aerospace") else None
HOME_WORKSPACE = os.environ.get("MAC_SPIKE_HOME_WORKSPACE")


def sh(*cmd, timeout=60):
    return subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout)


def cputime(pid):
    """The process's CPU time (user + system), in seconds."""
    out = sh("ps", "-o", "cputime=", "-p", str(pid)).stdout.strip()
    if not out:
        return None
    secs = 0.0
    for p in out.split(":"):
        secs = secs * 60 + float(p)
    return secs


def rss_mb(pid):
    out = sh("ps", "-o", "rss=", "-p", str(pid)).stdout.strip()
    return round(int(out) / 1024, 1) if out else None


def footprint_mb(pid):
    out = sh("footprint", "-p", str(pid)).stdout
    m = re.search(r"Footprint:\s*([\d.]+)\s*([KMG]B)", out) or re.search(r"phys_footprint:\s*([\d.]+)\s*([KMG]B)", out)
    if not m:
        return None
    v, unit = float(m.group(1)), m.group(2)
    return round(v / 1024 if unit == "KB" else v * 1024 if unit == "GB" else v, 1)


def threads(pid):
    return max(0, len(sh("ps", "-M", "-p", str(pid)).stdout.strip().splitlines()) - 1)


def windows(pid):
    try:
        return json.loads(sh(AXPROBE, "windows", str(pid)).stdout)["windows"]
    except Exception:
        return []


def aerospace_window(pid):
    r = sh("aerospace", "list-windows", "--all", "--json", "--format", "%{window-id} %{app-pid} %{app-name}")
    try:
        for w in json.loads(r.stdout):
            if int(w.get("app-pid", -1)) == pid:
                return w["window-id"]
    except Exception:
        pass
    return None


def front_pid():
    asn = sh("lsappinfo", "front").stdout.strip()
    out = sh("lsappinfo", "info", "-only", "pid", asn).stdout
    m = re.search(r"pid\s*=\s*(\d+)", out)
    return int(m.group(1)) if m else None


def find_pid(exe, since):
    """The newest process running `exe` (started by `open`)."""
    for _ in range(100):
        out = sh("pgrep", "-n", "-f", exe).stdout.strip()
        if out:
            return int(out)
        time.sleep(0.05)
    return None


def main():
    argv = sys.argv[1:]
    sep = argv.index("--")
    opts, app_args = argv[:sep], argv[sep + 1:]
    app, label, out_path = opts[0], opts[1], opts[2]
    settle, idle, do_ax, do_sample, wait_for, wait_timeout = 20.0, 60.0, False, False, None, 150.0
    i = 3
    while i < len(opts):
        if opts[i] == "--settle": settle = float(opts[i + 1]); i += 2
        elif opts[i] == "--idle": idle = float(opts[i + 1]); i += 2
        elif opts[i] == "--ax": do_ax = True; i += 1
        elif opts[i] == "--sample": do_sample = True; i += 1
        elif opts[i] == "--wait-for": wait_for = opts[i + 1]; i += 2
        elif opts[i] == "--wait-timeout": wait_timeout = float(opts[i + 1]); i += 2
        else: raise SystemExit("unknown option " + opts[i])

    name = os.path.splitext(os.path.basename(app))[0]
    exe = os.path.join(app, "Contents", "MacOS", name)
    out_log, err_log = out_path.replace(".json", ".out.log"), out_path.replace(".json", ".err.log")
    for p in (out_log, err_log):
        open(p, "w").close()
    # No window restored from an earlier run: every run starts the same.
    app_args = app_args + ["-ApplePersistenceIgnoreState", "YES"]
    result = {"label": label, "args": app_args}
    t_launch = time.monotonic()
    sh("open", "-n", "-F", "-a", app, "--stdout", out_log, "--stderr", err_log, "--args", *app_args)
    pid = find_pid(exe, t_launch)
    result["pid"] = pid
    try:
        if not pid:
            raise RuntimeError("the app did not start")
        win = None
        while time.monotonic() - t_launch < 30:
            ws = [w for w in windows(pid) if w["layer"] == 0 and w["w"] > 300]
            if ws:
                win = ws[0]
                break
            time.sleep(0.1)
        result["first_window_s"] = round(time.monotonic() - t_launch, 2) if win else None
        wid = None
        for _ in range(50 if WORKSPACE else 0):
            wid = aerospace_window(pid)
            if wid: break
            time.sleep(0.1)
        if wid:
            sh("aerospace", "move-node-to-workspace", "--window-id", str(wid), WORKSPACE)
            sh("aerospace", "workspace", WORKSPACE)
            sh("aerospace", "focus", "--window-id", str(wid))
        result["aerospace_window"] = wid
        # In front, as a person using it has it (`open` again brings the running copy forward).
        for _ in range(10):
            time.sleep(0.5)
            if front_pid() == pid:
                break
            sh("open", "-a", app)
        time.sleep(settle)
        result["front_is_app"] = front_pid() == pid
        result["cpu_s_through_settle"] = cputime(pid)
        result["window"] = [w for w in windows(pid) if w["layer"] == 0]
        if result["window"]:
            shot = out_path.replace(".json", ".png")
            sh("screencapture", "-x", "-o", "-l", str(result["window"][0]["id"]), shot)
            result["screenshot"] = shot

        if idle > 0:
            c0, w0 = cputime(pid), time.monotonic()
            rss = []
            while time.monotonic() - w0 < idle:
                time.sleep(5)
                rss.append(rss_mb(pid))
            c1, w1 = cputime(pid), time.monotonic()
            result["idle"] = {"seconds": round(w1 - w0, 1), "cpu_percent": round((c1 - c0) / (w1 - w0) * 100, 2),
                              "rss_mb_min": min(rss), "rss_mb_max": max(rss), "rss_mb_end": rss[-1],
                              "footprint_mb": footprint_mb(pid), "threads": threads(pid),
                              "front_is_app": front_pid() == pid}

        if do_sample:
            path = out_path.replace(".json", ".sample.txt")
            sh("sample", str(pid), "10", "-file", path, timeout=120)
            result["sample"] = path

        if do_ax:
            c0 = cputime(pid)
            r = sh(AXPROBE, "walk", str(pid), timeout=900)
            c1 = cputime(pid)
            walk = json.loads(r.stdout) if r.stdout.strip() else {"error": r.stderr}
            walk["app_cpu_s"] = round(c1 - c0, 3)
            # Again: the tree is built now (what a client polling it again costs).
            c0 = cputime(pid)
            r2 = sh(AXPROBE, "walk", str(pid), timeout=900)
            c1 = cputime(pid)
            walk2 = json.loads(r2.stdout) if r2.stdout.strip() else {"error": r2.stderr}
            walk2["app_cpu_s"] = round(c1 - c0, 3)
            q = sh(AXPROBE, "query", str(pid), "100", timeout=600)
            result["ax"] = {"walk_first": walk, "walk_second": walk2,
                            "window_queries": json.loads(q.stdout) if q.stdout.strip() else {"error": q.stderr}}
            # What the walks left behind: memory, and idle CPU once a client has been through the tree.
            c0, w0 = cputime(pid), time.monotonic()
            time.sleep(20)
            c1, w1 = cputime(pid), time.monotonic()
            result["after_ax"] = {"cpu_percent_20s": round((c1 - c0) / (w1 - w0) * 100, 2),
                                  "footprint_mb": footprint_mb(pid), "rss_mb": rss_mb(pid)}

        if wait_for:
            w0 = time.monotonic()
            while time.monotonic() - w0 < wait_timeout:
                if wait_for in open(err_log, errors="replace").read() + open(out_log, errors="replace").read():
                    break
                time.sleep(1)
            time.sleep(1)
        result["cpu_s_total"] = cputime(pid)
        result["footprint_mb_end"] = footprint_mb(pid)
    finally:
        if pid:
            sh("kill", str(pid))
            for _ in range(50):
                if sh("ps", "-p", str(pid)).returncode != 0:
                    break
                time.sleep(0.1)
            sh("kill", "-9", str(pid))
        if WORKSPACE and HOME_WORKSPACE:
            sh("aerospace", "workspace", HOME_WORKSPACE)
    text = open(err_log, errors="replace").read() + "\n" + open(out_log, errors="replace").read()
    lines = text.splitlines()
    result["nav_perf"] = [json.loads(l.split(" ", 1)[1]) for l in lines if l.startswith("NAV-PERF {")]
    summ = [l for l in lines if l.startswith("NAV-PERF-SUMMARY ")]
    result["nav_perf_summary"] = json.loads(summ[-1].split(" ", 1)[1]) if summ else None
    result["nav_perf_loops"] = [l for l in lines if l.startswith("NAV-PERF-LOOP ")]
    chat = [l for l in lines if l.startswith("CHAT-PERF ")]
    result["chat_perf"] = json.loads(chat[-1].split(" ", 1)[1]) if chat else None
    with open(out_path, "w") as f:
        json.dump(result, f, indent=1, sort_keys=True)
    print(json.dumps({k: result.get(k) for k in ["label", "first_window_s", "front_is_app", "window", "idle", "ax",
                                                  "after_ax", "nav_perf_summary", "nav_perf_loops", "chat_perf",
                                                  "cpu_s_through_settle"]}, indent=1))


if __name__ == "__main__":
    main()
