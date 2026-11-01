#!/usr/bin/env bash
# Drive REAL Claude Code through `roost revive` (#57, #191 Part 2): one prompt,
# `/exit`, `roost revive %N` — the pane must come back in the SAME %N, with the
# old prompt on screen, re-identified under the SAME session id (spec §2.1:
# `SessionStart` fires again with the same id on a resume). Then the
# transcript is deleted and a second `revive` must refuse (exit 13) without
# touching the pane — the store check of spec §5.1a, before anything is killed.
#
# NOT part of the suite: this directory is outside tests/'s test-*.sh glob, so
# tests/run.sh never runs it. Run it by hand AFTER EVERY CLAUDE CODE UPGRADE:
#
#   bash tests/live/revive-smoke.sh
#
# WHY IT MUST BE RUN. tests/test-revive.sh drives stub harnesses: it proves
# what roost launches and where, not that Claude Code still resumes from
# `claude --resume ID` in the transcript's directory, still fires SessionStart
# with the same id, or still keeps the transcript where the store check looks
# (`${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/<id>.jsonl`). None of that is a
# contract. If one moves, `revive` either refuses every pane or launches into
# a conversation it did not check. This file sees both, and FAILS LOUDLY,
# printing the pane.
#
# NO REAL MODEL ANSWERS. Claude is pointed at a local fake Messages API that
# answers every request with one text block, "SMOKE REPLY", and logs only
# what it answered, never a header.
#
# ISOLATION. The rig of tests/live/claude-background-smoke.sh: HOME,
# XDG_CONFIG_HOME and XDG_STATE_HOME point at a temp directory, with a fake API
# key and the project trust seeded in that HOME's .claude.json, so this run
# never touches your login and never adds a trust entry to your own
# ~/.claude.json. It hashes ~/.claude/settings.json and lists the project keys
# of ~/.claude.json before and after, and FAILS if either changed. It never
# repairs them.
#
# ONE DIFFERENCE FROM THAT RIG, and why. `revive` respawns the pane with the
# resume command alone — `claude --resume ID`, no `--settings` — exactly as a
# user's pane gets it. So this checkout's hooks go into the THROWAWAY home's
# own ~/.claude/settings.json (which is what `roost install` does for a real
# user), not into a `--settings` file, or the resumed Claude would load no
# hooks and never re-identify. The resume also inherits its environment from
# the tmux server, not from this shell, so the throwaway HOME, the fake API
# and the rest are set in the throwaway server's GLOBAL environment as well.
#
# NEVER TYPE A SLASH COMMAND THAT SAVES ANYTHING into the pane: /model,
# /config, /login, /logout, /theme, /permissions. The model is chosen with
# --model; --permission-mode default because from 2.1.307 Claude starts in
# auto mode, whose classifier asks the same fake API. Probe 2.1
# (docs/airig/probes/persist-2-resume-flags.md) measured that a flag-less
# `--resume` keeps both.
#
# Its own tmux socket, ending in /roost so the hooks act on it. The live
# -L roost server is never contacted.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
MODEL="${ROOST_LIVE_CLAUDE_MODEL:-haiku}"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }
command -v claude  >/dev/null 2>&1 || skip "claude not installed"
command -v python3 >/dev/null 2>&1 || skip "python3 is needed for the fake API"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }
die() { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; printf '\n  %d passed, %d failed\n' "$pass" "$fail"; exit 1; }

GUARDED="$HOME/.claude/settings.json ${CODEX_HOME:-$HOME/.codex}/config.toml"
guard_hash() {
  local f
  for f in $GUARDED; do
    if [ -e "$f" ]; then printf '%s %s\n' "$(shasum -a 256 < "$f" | cut -d' ' -f1)" "$f"
    else printf -- '- %s\n' "$f"; fi
  done
}
project_keys() {
  python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sorted((d.get("projects") or {}).keys()):
    print(k)' "$HOME/.claude.json" 2>/dev/null
}
GUARD_BEFORE="$(guard_hash)"
KEYS_BEFORE="$(project_keys)"
guard_check() {
  local bad=0 new
  if [ "$(guard_hash)" != "$GUARD_BEFORE" ]; then
    printf '\n  FAIL: THIS RUN CHANGED YOUR OWN CONFIG. Not repaired. Before, then after:\n'
    printf '%s\n' "$GUARD_BEFORE" | sed 's/^/    /'
    guard_hash | sed 's/^/    /'
    bad=1
  fi
  new="$(project_keys | comm -13 <(printf '%s\n' "$KEYS_BEFORE") - 2>/dev/null)"
  if [ -n "$new" ]; then
    printf '\n  FAIL: THIS RUN ADDED A TRUSTED PROJECT to ~/.claude.json. Not repaired:\n'
    printf '%s\n' "$new" | sed 's/^/    /'
    bad=1
  fi
  return "$bad"
}

D="$(mktemp -d /tmp/amx.XXXX)"
S="$D/roost"
PROJ="$D/proj"; mkdir -p "$PROJ" "$D/home/.claude" "$D/xdg" "$D/xdgstate"
git -C "$PROJ" init -q || die "cannot git init $PROJ"
PROJR="$(cd -P "$PROJ" && pwd)"
FAKE_PID=""
cleanup() {
  tmux -S "$S" kill-server 2>/dev/null
  if [ -n "$FAKE_PID" ]; then kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; fi
  rm -rf "$D"
  if guard_check; then
    printf '  guard: ~/.claude/settings.json unchanged, and no project key was added to ~/.claude.json\n'
  else
    exit 1
  fi
}
trap cleanup EXIT

KEY="sk-ant-api03-roost-smoke-000000000000000000000000000000000000000000000000000000000000000000000AA"
python3 - "$D/home/.claude.json" "$KEY" "$PROJR" <<'PY'
import json, sys
p, key, proj = sys.argv[1:4]
json.dump({"hasCompletedOnboarding": True, "theme": "dark", "numStartups": 5,
           "customApiKeyResponses": {"approved": [key, key[-20:]], "rejected": []},
           "projects": {proj: {"hasTrustDialogAccepted": True, "allowedTools": [], "hasCompletedProjectOnboarding": True}}},
          open(p, "w"))
PY
# This checkout's hooks, as `roost hooks` prints them, in the THROWAWAY home's
# user settings (see the header).
"$HERE/bin/roost" hooks claude | sed -n '/^{/,$p' > "$D/home/.claude/settings.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))["hooks"]["SessionStart"]' "$D/home/.claude/settings.json" \
  || die "roost hooks claude has no SessionStart entry"

cat > "$D/fake.py" <<'PY'
import http.server, json, sys
log, portfile = sys.argv[1], sys.argv[2]
def sse(events):
    return "".join("event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e)) for e in events).encode()
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def _go(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            req = json.loads(raw or b"{}")
        except ValueError:
            req = {}
        msgs = req.get("messages") or []
        with open(log, "a") as f:
            f.write("REQ messages=%d\n" % len(msgs))
        if req.get("stream"):
            ev = [{"type": "message_start", "message": {"id": "msg_roostrv1", "type": "message", "role": "assistant",
                   "model": "claude-haiku-4-5", "content": [], "stop_reason": None, "stop_sequence": None,
                   "usage": {"input_tokens": 1, "output_tokens": 1}}},
                  {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
                  {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "SMOKE REPLY"}},
                  {"type": "content_block_stop", "index": 0},
                  {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}},
                  {"type": "message_stop"}]
            body, ctype = sse(ev), "text/event-stream"
        else:
            body = json.dumps({"id": "msg_roostrvplain", "type": "message", "role": "assistant",
                               "model": "claude-haiku-4-5", "content": [{"type": "text", "text": "SMOKE REPLY"}],
                               "stop_reason": "end_turn", "stop_sequence": None,
                               "usage": {"input_tokens": 1, "output_tokens": 1}}).encode()
            ctype = "application/json"
        self.send_response(200)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers(); self.wfile.write(body)
    do_POST = do_GET = do_HEAD = _go
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
: > "$D/api.log"
python3 "$D/fake.py" "$D/api.log" "$D/port" >/dev/null 2>&1 &
FAKE_PID=$!
i=0; while [ ! -s "$D/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
PORT="$(cat "$D/port" 2>/dev/null)"
[ -n "$PORT" ] || die "the fake API did not start"

# The environment every pane on the throwaway server gets — including the one
# `revive` respawns, which takes it from the server, not from this shell.
PANE_ENV="HOME=$D/home XDG_CONFIG_HOME=$D/xdg XDG_STATE_HOME=$D/xdgstate ROOST_NO_SHIM=1
ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT ANTHROPIC_API_KEY=$KEY CLAUDE_CODE_MAX_RETRIES=0
DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
PANE_UNSET="CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION
CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_EXECPATH CLAUDE_PID CLAUDE_EFFORT CLAUDE_CODE_MESSAGING_SOCKET
CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SESSION_ATTENDED ROOST_SOCKET ROOST_HOME CLAUDE_CONFIG_DIR
ROOST_RECORD_DIR ROOST_SHAPE_DIR"

tmux -S "$S" -f /dev/null new-session -d -s smoke -x 200 -y 50 -c "$PROJR"
X()      { tmux -S "$S" "$@"; }
for kv in $PANE_ENV; do X set-environment -g "${kv%%=*}" "${kv#*=}"; done
for k in $PANE_UNSET; do X set-environment -gu "$k" 2>/dev/null; X set-environment -g -r "$k" 2>/dev/null; done
popt()   { X show-options -pqv -t "$1" "$2" 2>/dev/null; }
screen() { X capture-pane -p -S -200 -t "$1" 2>/dev/null; }
# bin/roost from a person's shell, aimed at the throwaway server and at the
# throwaway state directory (its claims and the pane records live there).
# Its environment matches the panes', so a pane it starts is the same either
# way.
R() {
  local -a e=() u=()
  local kv k
  for kv in $PANE_ENV; do e+=("$kv"); done
  for k in $PANE_UNSET; do u+=(-u "$k"); done
  env "${u[@]}" -u TMUX -u TMUX_PANE "${e[@]}" ROOST_SOCKET="$S" "$HERE/bin/roost" "$@"
}
wait_screen() { # PANE REGEX SECONDS
  local i=0
  while [ "$i" -lt "$3" ]; do screen "$1" | grep -qE "$2" && return 0; sleep 1; i=$((i+1)); done
  return 1
}
wait_cmd() { # PANE NAME SECONDS
  local i=0
  while [ "$i" -lt "$3" ]; do [ "$(X display -p -t "$1" '#{pane_current_command}')" = "$2" ] && return 0; sleep 1; i=$((i+1)); done
  return 1
}
wait_opt() { # PANE OPTION VALUE SECONDS
  local i=0
  while [ "$i" -lt "$4" ]; do [ "$(popt "$1" "$2")" = "$3" ] && return 0; sleep 1; i=$((i+1)); done
  return 1
}
dump() { printf '    --- pane %s ---\n' "$1"; screen "$1" | grep -v '^$' | tail -20 | sed 's/^/    /'; }

READY='for shortcuts|to cycle|\? for'
# A bash pane, so the shell is there after /exit: #57's everyday case is a
# Claude that left (or crashed) with its identity still on the pane.
P="$(X new-window -d -P -F '#{pane_id}' -t smoke -n claude -c "$PROJR" '/bin/bash --norc --noprofile')"
sleep 1
X send-keys -t "$P" -l "claude --model $MODEL --permission-mode default"; X send-keys -t "$P" Enter
wait_screen "$P" "trust this folder|$READY" 60 || { dump "$P"; die "claude never started"; }
if screen "$P" | grep -q 'trust this folder'; then
  X send-keys -t "$P" Down Enter
  wait_screen "$P" "$READY" 60 || { dump "$P"; die "claude never reached its prompt"; }
fi

printf '\n== one prompt, /exit ==\n'
X send-keys -t "$P" -l "ROOST-REVIVE-SMOKE first prompt"; sleep 1; X send-keys -t "$P" Enter
wait_screen "$P" 'SMOKE REPLY' 30 || { dump "$P"; die "the fake API's reply never showed"; }
ID="$(popt "$P" @roost-session)"
case "$ID" in
  ????????-????-????-????-????????????) ok "SessionStart identified the pane: $ID" ;;
  *) dump "$P"; die "no session id on the pane after the first prompt (got '$ID') — did SessionStart's hook move?" ;;
esac
TRF="$(find "$D/home/.claude/projects" -name "$ID.jsonl" 2>/dev/null | head -n 1)"
[ -n "$TRF" ] && ok "the transcript is under projects/*/<id>.jsonl" || die "no projects/*/$ID.jsonl — the store check would refuse every pane"
X send-keys -t "$P" -l "/exit"; sleep 1; X send-keys -t "$P" Enter
wait_cmd "$P" bash 20 || { dump "$P"; die "claude did not leave on /exit"; }
[ "$(popt "$P" @roost-session)" = "$ID" ] && ok "after /exit the shell is back and the identity is still on the pane (exited)" \
  || no "after /exit the identity reads '$(popt "$P" @roost-session)'"

printf '\n== roost revive %s ==\n' "$P"
out="$(R revive "$P" 2>"$D/revive.err")"; rc=$?
[ "$rc:$out" = "0:$P" ] && ok "revive exits 0 and prints the same %N ($P)" \
  || { no "revive exited $rc, printed '$out': $(cat "$D/revive.err")"; }
wait_screen "$P" "$READY" 60 || { dump "$P"; no "the resumed claude never reached its prompt"; }
screen "$P" | grep -q 'ROOST-REVIVE-SMOKE first prompt' && ok "the old prompt is on screen" \
  || { dump "$P"; no "the old prompt is not on screen — did it resume a different conversation?"; }
if wait_opt "$P" @roost-session "$ID" 30; then
  ok "the pane re-identified under the SAME id"
else
  dump "$P"; no "the pane reads @roost-session '$(popt "$P" @roost-session)', not $ID"
fi
[ "$(X display -p -t "$P" '#{pane_id}')" = "$P" ] && ok "...in the same pane" || no "the pane $P is gone"

printf '\n== the transcript deleted: revive refuses, the pane untouched ==\n'
X send-keys -t "$P" -l "/exit"; sleep 1; X send-keys -t "$P" Enter
# The pane's process IS the resumed claude now (respawn-pane), so /exit with
# remain-on-exit failed and exit 0 ends the pane. Make a fresh shell pane that
# carries the same identity — what a person sees after a crash — instead.
sleep 3
X display -p -t "$P" '#{pane_id}' >/dev/null 2>&1 && X kill-pane -t "$P" 2>/dev/null
Q="$(X new-window -d -P -F '#{pane_id}' -t smoke -c "$PROJR" '/bin/bash --norc --noprofile')"
sleep 1
X set-option -p -t "$Q" @roost-harness claude \; set-option -p -t "$Q" @roost-session "$ID" \
  \; set-option -p -t "$Q" @roost-cwd "$PROJR" \; set-option -p -t "$Q" @roost-transcript-path "$TRF"
find "$D/home/.claude/projects" -name "$ID.jsonl" -exec rm -f {} + 2>/dev/null
[ -z "$(find "$D/home/.claude/projects" -name "$ID.jsonl" 2>/dev/null)" ] || die "could not delete the transcript"
pid0="$(X display -p -t "$Q" '#{pane_pid}')"
R revive "$Q" >/dev/null 2>"$D/revive.err"; rc=$?
[ "$rc" = 13 ] && ok "revive exits 13" || no "revive exited $rc: $(cat "$D/revive.err")"
grep -q "no longer holds $ID" "$D/revive.err" && ok "...saying claude no longer holds the id" || no "...stderr: $(cat "$D/revive.err")"
[ "$(X display -p -t "$Q" '#{pane_pid}')" = "$pid0" ] && ok "...and the pane is untouched (same pane_pid)" || no "the pane was respawned"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
