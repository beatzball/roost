#!/usr/bin/env bash
# Drive REAL Claude Code into turns that fail on an API error, and check that
# the pane badges 💥 error with a reason, then recovers to ✅ done (#55).
#
# NOT part of the suite: this directory is outside tests/'s test-*.sh glob, so
# tests/run.sh never runs it. Run it by hand AFTER EVERY CLAUDE CODE UPGRADE:
#
#   bash tests/live/claude-stop-failure-smoke.sh
#
# WHY IT MUST BE RUN. roost learns that a Claude turn failed only from
# Claude's `StopFailure` hook, and learns which kind from its `error` field.
# Neither is something roost controls. If an upgrade renames the event, stops
# firing it, or moves the field, a failed turn goes back to reading ⏳ working
# forever, and the suite cannot see that: its payloads are old captures.
#
# NO REAL API ERROR IS EVER CAUSED, and no real model answers. Claude is
# pointed at a local fake API, and one pane runs three turns against it:
#
#   rate_limit    the fake answers 429. Retries are turned off for that one
#                 process, so the turn fails at once.
#   healthy       the fake answers a valid "PONG". The SAME pane must reach
#                 ✅ done, with the failed turn's reason gone.
#   server_error  the fake answers 500, so a pane that was done fails again.
#
# The fake logs method and path only, never headers, which carry your login.
#
# NEVER TYPE A SLASH COMMAND THAT SAVES ANYTHING into these panes: /model,
# /config, /login, /logout, /theme, /permissions, /terminal-setup, /vim. On
# 2.1.272, `/model haiku` answered "saved as your default for new sessions"
# and wrote "model" into the user's own ~/.claude/settings.json, even under
# `--setting-sources local`. An earlier draft of this file did exactly that and
# changed the author's default model. Choose a model with --model on the
# command line; a pane that needs another model is a new pane.
#
# As a guard against the next one, this script hashes ~/.claude/settings.json
# and ~/.codex/config.toml before it starts and again when it exits, and FAILS
# LOUDLY if either changed. It never repairs them: that is the owner's call.
#
# It loads only this checkout's hooks: `--setting-sources local` skips your
# user and project settings, and `--settings` adds roost's hooks for this
# checkout.
#
# ONE THING IT CANNOT AVOID WRITING. The first time Claude runs in a directory
# it asks whether to trust the folder, and Claude records the answer in your
# own Claude config. So the project directory is fixed, and it is the SAME one
# tests/live/claude-decline-smoke.sh uses, so running both leaves one trust
# entry, not two. Override it with ROOST_LIVE_CLAUDE_DIR; it must be a git
# repository or an empty directory this script may `git init`.
#
# Isolation: its own tmux socket, ending in /roost so the hooks act on it. The
# live -L roost server is never contacted.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
PROJ="${ROOST_LIVE_CLAUDE_DIR:-/tmp/roost-claude-decline-smoke}"
MODEL="${ROOST_LIVE_CLAUDE_MODEL:-haiku}"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }
command -v claude  >/dev/null 2>&1 || skip "claude not installed"
command -v python3 >/dev/null 2>&1 || skip "python3 is needed for the fake API"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }
die() { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; printf '\n  %d passed, %d failed\n' "$pass" "$fail"; exit 1; }

mkdir -p "$PROJ" || die "cannot create $PROJ"
if [ ! -d "$PROJ/.git" ]; then
  git -C "$PROJ" init -q || die "cannot git init $PROJ"
fi

# The user's own config files, hashed before anything runs. `-` stands for a
# file that is not there, so a file that APPEARS counts as a change too.
GUARDED="$HOME/.claude/settings.json ${CODEX_HOME:-$HOME/.codex}/config.toml"
guard_hash() {
  local f
  for f in $GUARDED; do
    if [ -e "$f" ]; then printf '%s %s\n' "$(shasum -a 256 < "$f" | cut -d' ' -f1)" "$f"
    else printf -- '- %s\n' "$f"; fi
  done
}
GUARD_BEFORE="$(guard_hash)"
guard_check() {
  [ "$(guard_hash)" = "$GUARD_BEFORE" ] && return 0
  printf '\n  FAIL: THIS RUN CHANGED YOUR OWN CONFIG. Not repaired. Before, then after:\n'
  printf '%s\n' "$GUARD_BEFORE" | sed 's/^/    /'
  guard_hash | sed 's/^/    /'
  return 1
}

D="$(mktemp -d /tmp/amx.XXXX)"
S="$D/roost"
FAKE_PID=""
trap 'tmux -S "$S" kill-server 2>/dev/null; [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$D"; guard_check || exit 1' EXIT

# This checkout's hooks, exactly as `roost hooks` prints them.
"$HERE/bin/roost" hooks claude | sed -n '/^{/,$p' > "$D/settings.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["hooks"]["StopFailure"]' "$D/settings.json" 2>/dev/null \
  || die "roost hooks claude has no StopFailure entry"

# The fake API: port 0, so the kernel picks a free one and the script writes
# it down. $D/mode says how it answers every request: `429` is a rate limit in
# the Anthropic error shape, `ok` is a finished "PONG" message — streamed when
# the request asks for a stream, plain JSON when it does not.
cat > "$D/fake.py" <<'PY'
import http.server, json, sys
log, portfile, modefile = sys.argv[1], sys.argv[2], sys.argv[3]
MSG = {"id": "msg_roostsmoke00000000000000", "type": "message", "role": "assistant",
       "model": "claude-haiku-4-5", "stop_reason": None, "stop_sequence": None,
       "usage": {"input_tokens": 1, "output_tokens": 1}}
def sse(events):
    return "".join("event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e)) for e in events).encode()
class H(http.server.BaseHTTPRequestHandler):
    def _go(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n) if n else b""
        mode = open(modefile).read().strip()
        with open(log, "a") as f:
            f.write("%s %s %s\n" % (self.command, self.path, mode))
        try:
            stream = bool(json.loads(raw or b"{}").get("stream"))
        except ValueError:
            stream = False
        if mode == "429":
            body = json.dumps({"type": "error", "error": {"type": "rate_limit_error",
                   "message": "roost smoke: fake rate limit"}}).encode()
            status, ctype = 429, "application/json"
        elif mode == "500":
            body = json.dumps({"type": "error", "error": {"type": "api_error",
                   "message": "roost smoke: fake server error"}}).encode()
            status, ctype = 500, "application/json"
        elif stream:
            body = sse([
                {"type": "message_start", "message": dict(MSG, content=[])},
                {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "PONG"}},
                {"type": "content_block_stop", "index": 0},
                {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                 "usage": {"output_tokens": 1}},
                {"type": "message_stop"}])
            status, ctype = 200, "text/event-stream"
        else:
            body = json.dumps(dict(MSG, content=[{"type": "text", "text": "PONG"}],
                                   stop_reason="end_turn")).encode()
            status, ctype = 200, "application/json"
        self.send_response(status)
        self.send_header("content-type", ctype)
        if status == 429:
            self.send_header("retry-after", "1")
        self.send_header("content-length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    do_POST = do_GET = do_HEAD = _go
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
: > "$D/api.log"
echo 429 > "$D/mode"
python3 "$D/fake.py" "$D/api.log" "$D/port" "$D/mode" >/dev/null 2>&1 &
FAKE_PID=$!
i=0; while [ ! -s "$D/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
PORT="$(cat "$D/port" 2>/dev/null)"
[ -n "$PORT" ] || die "the fake API did not start"

tmux -S "$S" -f /dev/null new-session -d -s smoke -x 200 -y 50 -c "$PROJ"
X()      { tmux -S "$S" "$@"; }
pstate() { X show-options -pqv -t "$1" @agent_state 2>/dev/null; }
reason() { X show-options -pqv -t "$1" @roost-error-reason 2>/dev/null; }
screen() { X capture-pane -p -t "$1" 2>/dev/null; }
R()      { ROOST_SOCKET="$S" "$HERE/bin/roost" "$@"; }
wait_screen() { # PANE REGEX SECONDS
  local i=0
  while [ "$i" -lt "$3" ]; do screen "$1" | grep -qE "$2" && return 0; sleep 1; i=$((i+1)); done
  return 1
}
wait_state() { # PANE STATE SECONDS
  local i=0
  while [ "$i" -lt "$3" ]; do [ "$(pstate "$1")" = "$2" ] && return 0; sleep 1; i=$((i+1)); done
  return 1
}
dump() { printf '    --- pane %s ---\n' "$1"; screen "$1" | grep -v '^$' | tail -20 | sed 's/^/    /'; }

# start NAME "ENV" MODEL -> sets PANE, a Claude window ready for a prompt. The
# footer under the prompt is not always the same line, so either is accepted.
READY='for shortcuts|to cycle'
PANE=""
start() {
  PANE="$(X new-window -d -P -F '#{pane_id}' -t smoke -n "$1" -c "$PROJ" \
    "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
     -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_PID -u CLAUDE_EFFORT \
     -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED \
     -u ROOST_SOCKET -u ROOST_HOME $2 \
     claude --model $3 --setting-sources local --settings $D/settings.json; sleep 600")"
  wait_screen "$PANE" "trust this folder|$READY" 60 || { dump "$PANE"; die "claude never started ($1)"; }
  if screen "$PANE" | grep -q 'trust this folder'; then
    X send-keys -t "$PANE" Down Enter
    wait_screen "$PANE" "$READY" 60 || { dump "$PANE"; die "claude never reached its prompt ($1)"; }
  fi
}
ask() { X send-keys -t "$1" -l "$2"; sleep 1; X send-keys -t "$1" Enter; }

# --- rate_limit, from the fake API -------------------------------------------
printf '\n== rate_limit ==\n'
start rate "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT CLAUDE_CODE_MAX_RETRIES=0" "$MODEL"
p="$PANE"
ask "$p" "Reply with exactly the word PONG and nothing else."
if wait_state "$p" error 60; then
  ok "rate_limit: a turn that fails on a 429 badges error"
else
  dump "$p"
  no "rate_limit: the pane reads '$(pstate "$p")', not error — did StopFailure stop firing?"
fi
# Proof the failure came from the fake, not from something else going wrong.
[ -s "$D/api.log" ] && ok "rate_limit: claude really reached the fake API" \
  || no "rate_limit: the fake API saw no request, so this case tested nothing"
case "$(reason "$p")" in
  *rate_limit*) ok "rate_limit: the reason names rate_limit" ;;
  *) no "rate_limit: the reason reads '$(reason "$p")' — did the StopFailure payload's error field move?" ;;
esac
werr="$(R wait-done "$p" 5 2>&1 >/dev/null)"; rc=$?
# Exit 1 alone is not enough: a timeout exits 1 too, and a pane stuck on
# working times out. Measured — with the StopFailure hook removed, the bare
# exit-code check passed. So it must be the error refusal, by its words.
case "$rc:$werr" in
  "1:"*"error state"*) ok "rate_limit: wait-done exits 1 because the pane is in error" ;;
  *) no "rate_limit: wait-done exited $rc without the error refusal: $werr" ;;
esac
case "$werr" in *rate_limit*) ok "rate_limit: wait-done prints the reason" ;;
  *) no "rate_limit: wait-done did not print the reason: $werr" ;; esac

# --- a healthy turn in the SAME pane ------------------------------------------
printf '\n== healthy, after the failure ==\n'
echo ok > "$D/mode"
ask "$p" "Reply with exactly the word PONG and nothing else."
if wait_state "$p" done 60; then
  ok "healthy: the turn after a failed one reaches done"
else
  dump "$p"
  no "healthy: the pane reads '$(pstate "$p")', not done"
fi
[ -z "$(reason "$p")" ] && ok "healthy: the failed turn's reason is gone" \
  || no "healthy: the reason '$(reason "$p")' is still on the pane"
R wait-done "$p" 5 >/dev/null 2>&1
[ "$?" = "0" ] && ok "healthy: wait-done exits 0" || no "healthy: wait-done did not exit 0"
# The reply must come from the Stop hook, not from read's screen fallback: the
# prompt on screen says PONG too, so stdout alone would pass on a screen scrape.
rout="$(R read "$p" 2>"$D/read.err")"
if [ "$rout" = "PONG" ] && ! grep -q "no recorded reply" "$D/read.err"; then
  ok "healthy: read returns the recorded reply"
else
  no "healthy: read did not return a recorded PONG (stdout '$(printf '%s' "$rout" | tail -1)', stderr '$(head -1 "$D/read.err")')"
fi

# --- server_error, on a pane that was done --------------------------------------
printf '\n== server_error, after a healthy turn ==\n'
echo 500 > "$D/mode"
ask "$p" "Reply with exactly the word PONG and nothing else."
if wait_state "$p" error 60; then
  ok "server_error: a done pane whose next turn fails on a 500 badges error"
else
  dump "$p"
  no "server_error: the pane reads '$(pstate "$p")', not error"
fi
case "$(reason "$p")" in
  *server_error*) ok "server_error: the reason names server_error" ;;
  *) no "server_error: the reason reads '$(reason "$p")'" ;;
esac
R read "$p" >/dev/null 2>"$D/read.err"
grep -q "no recorded reply" "$D/read.err" \
  && ok "server_error: the healthy turn's PONG is not served as this turn's reply" \
  || no "server_error: read still returned a recorded reply after a failed turn"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
