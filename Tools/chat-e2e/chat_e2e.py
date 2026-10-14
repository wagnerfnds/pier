# End-to-end check of a real chat on a box, through pierd's local API socket: run it on the box, as pierd's user
# (python3 chat_e2e.py [model] [--long], haiku by default; --long asks for a reply of some 150 words, to time the first
# words drawn while it streams). It starts a chat with Claude Code, sends a follow-up the way the app
# does (when: idle, an idem key, then the same request again, as a retry after a lost answer), follows /draft and
# /transcript as the app does, times what a person waits for, checks that the chat never stopped to ask the person
# anything and that a finished block never comes back as a draft, then ends the chat. It prints timings and checks
# only, never the agent's words. A chat that waits for a person sends that box's devices a push, as a real one would.
import http.client
import json
import os
import socket
import sys
import time
import uuid

SOCK = os.path.join(os.environ.get("PIER_HOME") or os.path.expanduser("~/.config/pier"), "box", "pierd.sock")


class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(SOCK)


def call(method, path, body=None, timeout=30):
    c = Unix("localhost", timeout=timeout)
    data = json.dumps(body).encode() if body is not None else None
    c.request(method, path, body=data, headers={"Content-Type": "application/json", "X-Pier-Origin": "e2e"})
    r = c.getresponse()
    raw = r.read()
    c.close()
    try:
        return r.status, json.loads(raw or b"null")
    except ValueError:
        return r.status, raw.decode(errors="replace")


def session(name):
    _, all_ = call("GET", "/v1/sessions")
    return next((s for s in all_ or [] if s.get("name") == name), None)


def letters(s):
    return "".join(ch.lower() for ch in s if ch.isalnum())


def turn_state(name, turn):
    _, turns = call("GET", f"/v1/sessions/{name}/turns?limit=20")
    return next((t.get("state") for t in turns or [] if isinstance(t, dict) and t.get("id") == turn), None)


def follow(name, turn, started, cursor, timeout=120):
    """Polls as the app does while a turn runs (the draft, then the record from cursor on, then the state) until the
    turn ends. Answers the timings and checks, and the record's cursor for the next turn."""
    first_draft = recorded = finished = None
    (since, gen), texts, doubled, asked, polls = cursor, [], 0, False, []
    end = time.time() + timeout
    while time.time() < end:
        t0 = time.time()
        _, d = call("GET", f"/v1/sessions/{name}/draft")
        polls.append(time.time() - t0)
        draft = (d or {}).get("text") or "" if isinstance(d, dict) else ""
        if draft and first_draft is None:
            first_draft = time.time() - started
        t0 = time.time()
        _, p = call("GET", f"/v1/sessions/{name}/transcript?since={since}" + (f"&gen={gen}" if gen else ""))
        polls.append(time.time() - t0)
        if isinstance(p, dict):
            for it in p.get("items") or []:
                if it.get("kind") == "text" and it.get("text"):
                    texts.append(it["text"])
                    if recorded is None:
                        recorded = time.time() - started
            since, gen = p.get("next", since), p.get("gen", gen)
        # A block the record has must not come back as a draft (the app would draw it twice).
        if draft and texts and letters(texts[-1]).endswith(letters(draft)):
            doubled += 1
        state = turn_state(name, turn)
        asked = asked or state == "waiting" or (session(name) or {}).get("agent_state") == "waiting"
        if state == "finished" and texts:
            finished = time.time() - started
            break
        time.sleep(0.3)
    polls.sort()
    secs = lambda v: round(v, 2) if v is not None else None
    return {
        "first_draft_s": secs(first_draft),
        "recorded_s": secs(recorded),
        "finished_s": secs(finished),
        "asked_person": asked,
        "draft_repeating_record": doubled,
        "server_poll_ms_p50": round(polls[len(polls) // 2] * 1000, 1) if polls else None,
        "server_poll_ms_p95": round(polls[int(len(polls) * 0.95)] * 1000, 1) if polls else None,
    }, (since, gen)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    model = args[0] if args else "haiku"
    prompt = "Reply with one short sentence: what is 2 + 2?"
    if "--long" in sys.argv:
        prompt = "In three short paragraphs of plain prose, about 150 words, explain how a hash map finds a key."
    out = {}
    started = time.time()
    st, s = call("POST", "/v1/sessions", {"chat": True, "agent": "claude", "model": model, "prompt": prompt}, timeout=60)
    if st >= 300:
        print(json.dumps({"error": f"start {st}", "body": str(s)[:200]}))
        sys.exit(1)
    name = s["name"]
    out["started_s"] = round(time.time() - started, 2)
    try:
        out["first"], cursor = follow(name, s.get("turn"), started, (0, None))
        key = "e2e-" + uuid.uuid4().hex
        body = {"text": "Now say it in Portuguese, in one sentence.", "enter": True, "when": "idle", "idem_key": key}
        sent = time.time()
        st1, r1 = call("POST", f"/v1/sessions/{name}/send", body)
        acked = time.time()
        st2, r2 = call("POST", f"/v1/sessions/{name}/send", body)
        out["send"] = {"status": st1, "ack_ms": round((acked - sent) * 1000, 1),
                       "retry_ms": round((time.time() - acked) * 1000, 1),
                       "retry_duplicate": isinstance(r2, dict) and r2.get("duplicate") is True,
                       "same_turn": isinstance(r1, dict) and isinstance(r2, dict) and r1.get("turn") == r2.get("turn")}
        out["second"], _ = follow(name, r1.get("turn") if isinstance(r1, dict) else None, sent, cursor)
        _, turns = call("GET", f"/v1/sessions/{name}/turns?limit=10")
        out["turns_finished"] = len([t for t in turns or [] if isinstance(t, dict) and t.get("state") == "finished"])
    finally:
        st, _ = call("DELETE", f"/v1/sessions/{name}")
        out["ended"] = st
    ok = (out.get("turns_finished") == 2 and not out["first"]["asked_person"] and not out["second"]["asked_person"]
          and out["send"]["retry_duplicate"] and out["send"]["same_turn"]
          and out["first"]["draft_repeating_record"] == 0 and out["second"]["draft_repeating_record"] == 0)
    out["ok"] = ok
    print(json.dumps(out, indent=1))
    sys.exit(0 if ok else 1)


main()
