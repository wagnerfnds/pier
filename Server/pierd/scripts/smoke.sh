#!/usr/bin/env bash
# End-to-end smoke test: start pierd with a temporary PIER_HOME (and its own
# tmux server), pair a client with it the way the app does (TLS 1.3 mTLS,
# pinned key, exporter-bound proof), and call the main routes.
#
#   scripts/smoke.sh                 build ./cmd/pierd and test it
#   PIERD=/path/to/pierd scripts/smoke.sh
#   SMOKE_REPO=~/code/sandbox scripts/smoke.sh   use that repository (a
#                                    throwaway worktree is made and removed)
#
# Nothing outside the temporary folder is touched, except the worktree and
# branch it makes in SMOKE_REPO, which it removes again.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pierd-smoke.XXXXXX")
export PIER_HOME="$tmp/home" PIER_USER_DIR="$tmp/user" PIER_CLIENT_HOME="$tmp/client"
export PIER_TMUX_SOCKET="pier-smoke-$$"
pid=""
wt="smoke-$$"

cleanup() {
	set +e
	[ -n "$pid" ] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
	tmux -L "$PIER_TMUX_SOCKET" kill-server 2>/dev/null
	rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$PIER_TMUX_SOCKET"
	if [ -n "${repo:-}" ]; then
		git -C "$repo" worktree remove --force "$(dirname "$repo")/$(basename "$repo")-$wt" 2>/dev/null
		git -C "$repo" branch -D "$wt" >/dev/null 2>&1
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT

if [ -n "${PIERD:-}" ]; then
	pierd=$PIERD
else
	pierd="$tmp/pierd"
	(cd "$here" && go build -o "$pierd" ./cmd/pierd)
fi

if [ -n "${SMOKE_REPO:-}" ]; then
	repo=$(cd "$SMOKE_REPO" && pwd)
else
	repo="$tmp/repo"
	git init -q -b main "$repo"
	echo "print('hi')" > "$repo/calc.py"
	git -C "$repo" add . && git -C "$repo" -c user.email=smoke@pier -c user.name=smoke commit -q -m init
fi

"$pierd" serve --listen 127.0.0.1:0 >"$tmp/pierd.log" 2>&1 &
pid=$!
for _ in $(seq 100); do
	[ -S "$PIER_HOME/box/pierd.sock" ] && [ -s "$PIER_HOME/box/listen" ] && break
	sleep 0.1
done
[ -S "$PIER_HOME/box/pierd.sock" ] || { cat "$tmp/pierd.log"; echo "pierd did not start"; exit 1; }
addr=$(cat "$PIER_HOME/box/listen")
echo "pierd $("$pierd" version) on $addr"

fails=0
pass() { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# call EXPECTED METHOD PATH [BODY]: one request as the paired client; the
# answer is in $out.
call() {
	local want=$1 method=$2 path=$3 body=${4:-}
	local status
	if out=$("$pierd" client "$method" "$path" ${body:+"$body"} 2>"$tmp/status"); then :; fi
	status=$(awk '{print $2}' "$tmp/status" | head -1)
	if [ "$status" = "$want" ]; then pass "$method $path -> $status"; else fail "$method $path -> $status (want $want): $(head -c 300 <<<"$out")"; fi
}

link=$("$pierd" pair --address "$addr" --json | sed -E -e 's/.*"link":"([^"]+)".*/\1/' -e 's/\\u0026/\&/g')
case $link in pier://*) pass "pair link is pier://" ;; *) fail "pair link: $link" ;; esac
"$pierd" client pair "$link" --name smoke && pass "client paired" || fail "client pair"

"$pierd" location add sandbox "$repo" >/dev/null && pass "location add (local socket)" || fail "location add"

call 200 GET /v1/ping
call 200 GET /v1/info
grep -q '"pair.invite"' <<<"$out" && pass "info lists pair.invite" || fail "info capabilities: $out"
call 200 GET /v1/stats
call 200 GET /v1/doctor
call 200 GET /v1/agents
call 200 GET /v1/locations
call 200 GET /v1/locations/sandbox/branches
call 200 POST /v1/locations/sandbox/worktrees "{\"name\":\"$wt\"}"
call 200 GET "/v1/worktrees?location=sandbox"
grep -q "\"$wt\"" <<<"$out" && pass "worktree listed" || fail "worktree not in /v1/worktrees"
call 200 GET "/v1/locations/sandbox/worktrees/$wt/services"
call 200 GET "/v1/locations/sandbox/worktrees/$wt/touched"
call 200 POST "/v1/locations/sandbox/worktrees/$wt/attachments" '{"name":"note.txt","data":"aGVsbG8="}'
call 200 GET /v1/services
call 200 POST /v1/sessions "{\"location\":\"sandbox/$wt\",\"name\":\"smoke-sh\",\"command\":\"cat\"}"
call 200 GET /v1/sessions
call 200 POST /v1/sessions/smoke-sh/send '{"text":"hello-from-smoke","idem_key":"smoke-1"}'
seen=""
for _ in $(seq 30); do
	call 200 GET "/v1/sessions/smoke-sh/screen?history=20" >/dev/null
	grep -q hello-from-smoke <<<"$out" && { seen=1; break; }
	sleep 0.2
done
[ -n "$seen" ] && pass "screen shows what was sent" || fail "screen never showed the text: $out"
call 200 POST /v1/sessions/smoke-sh/keys '{"keys":["enter"]}'
call 200 GET /v1/sessions/smoke-sh/draft
call 200 GET /v1/sessions/smoke-sh/controls
call 200 GET /v1/sessions/smoke-sh/queue
call 200 GET "/v1/sessions/smoke-sh/turns?limit=5"
call 200 GET "/v1/sessions/smoke-sh/transcript?since=0"
call 200 GET "/v1/sessions/smoke-sh/wait?for=finished,waiting&timeout=1s"
call 200 PATCH /v1/sessions/smoke-sh '{"title":"Smoke test"}'
call 200 POST /v1/exec "{\"location\":\"sandbox/$wt\",\"command\":\"echo exec-ok && pwd\",\"timeout\":\"20s\"}"
grep -q exec-ok <<<"$out" && pass "exec ran in the worktree" || fail "exec output: $out"
call 200 GET "/v1/review?all=1"
call 404 GET /v1/sessions/nope/screen
grep -q '"code":"not_found"' <<<"$out" && pass "errors carry a code" || fail "error body: $out"
call 200 DELETE /v1/sessions/smoke-sh
call 200 POST /v1/pair/invite '{"for":"other-phone"}'
grep -q '"link":"pier://' <<<"$out" && pass "invite is a pier:// link" || fail "invite: $out"
call 404 GET /v1/push/info
call 200 DELETE "/v1/locations/sandbox/worktrees/$wt?force=1&delete_branch=1"

"$pierd" client --for 2s GET "/v1/events?since=0" >"$tmp/events" 2>/dev/null || true
for t in client.paired location.added worktree.created session.started session.stopped worktree.removed pairing.invited; do
	grep -q "\"type\":\"$t\"" "$tmp/events" && pass "event $t" || fail "event $t missing"
done
last=$(tail -1 "$tmp/events" | sed -E 's/.*"seq":([0-9]+).*/\1/')
"$pierd" client --for 1s GET "/v1/events?since=$last" >"$tmp/events2" 2>/dev/null || true
[ ! -s "$tmp/events2" ] && pass "resume from the last seq replays nothing" || fail "resume replayed: $(cat "$tmp/events2")"

echo
if [ "$fails" -eq 0 ]; then
	echo "smoke: all passed"
else
	echo "smoke: $fails FAILED (pierd log: $tmp/pierd.log)"
	cat "$tmp/pierd.log"
	exit 1
fi
