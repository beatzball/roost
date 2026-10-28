#!/usr/bin/env bash
# Drive REAL Claude Code through a turn whose work outlives it -- a Bash run
# with `run_in_background` -- and check that the pane stays ⏳ working until
# Claude's own final Stop, then reads ✅ done with ONE recorded turn (#97, step
# 1 of docs/airig/specs/2026-09-29-turn-over-design.md).
#
# NOT part of the suite: this directory is outside tests/'s test-*.sh glob, so
# tests/run.sh never runs it. Run it by hand AFTER EVERY CLAUDE CODE UPGRADE:
#
#   bash tests/live/claude-background-smoke.sh
#
# WHY IT MUST BE RUN. roost holds the pane only because Claude's Stop payload
# lists the work still running in `background_tasks`, and releases it only
# because Claude starts a turn of its own when that work ends, whose Stop
# carries an empty list (measured on 2.1.283 and 2.1.310). Neither is a
# contract. If an upgrade renames the key, the hold silently goes back to the
# measured 30 s false ✅ (the design's Q5 keeps `done` for an absent key, on
# purpose); if the notification turn stops coming, a held pane reads ⏳ for
# ever. The suite cannot see either: its payloads are captures. This file can,
# and it FAILS LOUDLY, printing the pane, when the shape moves.
#
# NO REAL MODEL ANSWERS. Claude is pointed at a local fake Messages API that
# scripts the turn: the prompt gets `Bash {command: "sleep N",
# run_in_background: true}`, the tool result gets "MAIN REPLY", and the
# `<task-notification>` turn Claude starts when the sleep ends gets "FINAL
# REPLY". The fake logs what it decided, never a header.
#
# ISOLATION. HOME, XDG_CONFIG_HOME and XDG_STATE_HOME point at a temp
# directory, with a fake API key and the project trust seeded in that HOME's
# .claude.json, so this run never touches your login and never adds a trust
# entry to your own ~/.claude.json. It still hashes ~/.claude/settings.json and
# lists the project keys of ~/.claude.json before and after, and FAILS if
# either changed -- the measurement behind this test saw one auto-mode run
# write the real ~/.claude.json with HOME redirected. It never repairs them.
# Only this checkout's hooks load: `--setting-sources local --settings <file>`.
#
# NEVER TYPE A SLASH COMMAND THAT SAVES ANYTHING into the pane: /model,
# /config, /login, /logout, /theme, /permissions. The model is chosen with
# --model, and --permission-mode default because from 2.1.307 Claude starts in
# auto mode, whose classifier asks the same fake API; the settings file allows
# `Bash(sleep:*)` so no dialog opens.
#
# Its own tmux socket, ending in /roost so the hooks act on it. The live
# -L roost server is never contacted.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
MODEL="${ROOST_LIVE_CLAUDE_MODEL:-haiku}"
SLEEP="${ROOST_LIVE_BG_SECONDS:-12}"

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
  [ "$fail" -eq 0 ] || cp "$D/api.log" "${ROOST_SMOKE_KEEP_LOG:-/dev/null}" 2>/dev/null
  rm -rf "$D"
  if guard_check; then
    printf '  guard: ~/.claude/settings.json unchanged, and no project key was added to ~/.claude.json\n'
  else
    exit 1
  fi
}
trap cleanup EXIT

# The throwaway HOME: onboarding done, the fake key approved, the project
# trusted, so the TUI opens on its prompt and asks nothing.
KEY="sk-ant-api03-roost-smoke-000000000000000000000000000000000000000000000000000000000000000000000AA"
python3 - "$D/home/.claude.json" "$KEY" "$PROJR" <<'PY'
import json, sys
p, key, proj = sys.argv[1:4]
json.dump({"hasCompletedOnboarding": True, "theme": "dark", "numStartups": 5,
           "customApiKeyResponses": {"approved": [key, key[-20:]], "rejected": []},
           "projects": {proj: {"hasTrustDialogAccepted": True, "allowedTools": [], "hasCompletedProjectOnboarding": True}}},
          open(p, "w"))
PY

# This checkout's hooks, exactly as `roost hooks` prints them, plus the one
# allow rule the scripted command needs.
"$HERE/bin/roost" hooks claude | sed -n '/^{/,$p' > "$D/hooks.json"
python3 - "$D/hooks.json" "$D/settings.json" <<'PY' || die "roost hooks claude has no Stop entry"
import json, sys
d = json.load(open(sys.argv[1])); d["hooks"]["Stop"]
d["permissions"] = {"allow": ["Bash(sleep:*)"]}
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY

cat > "$D/fake.py" <<'PY'
import http.server, json, sys, itertools
log, portfile, secs = sys.argv[1], sys.argv[2], sys.argv[3]
ids = itertools.count(1)
def say(s):
    with open(log, "a") as f:
        f.write(s + "\n")
def sse(events):
    return "".join("event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e)) for e in events).encode()
def message(blocks, stop):
    mid = "msg_roostbg%012d" % next(ids)
    ev = [{"type": "message_start", "message": {"id": mid, "type": "message", "role": "assistant",
           "model": "claude-haiku-4-5", "content": [], "stop_reason": None, "stop_sequence": None,
           "usage": {"input_tokens": 1, "output_tokens": 1}}}]
    for i, b in enumerate(blocks):
        if b["type"] == "text":
            ev.append({"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}})
            ev.append({"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": b["text"]}})
        else:
            ev.append({"type": "content_block_start", "index": i,
                       "content_block": {"type": "tool_use", "id": b["id"], "name": b["name"], "input": {}}})
            ev.append({"type": "content_block_delta", "index": i,
                       "delta": {"type": "input_json_delta", "partial_json": json.dumps(b["input"])}})
        ev.append({"type": "content_block_stop", "index": i})
    ev.append({"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 1}})
    ev.append({"type": "message_stop"})
    return sse(ev)
def text_of(content):
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict):
            if b.get("type") == "text":
                out.append(b.get("text", ""))
            elif b.get("type") == "tool_result":
                c = b.get("content")
                out.append("TOOL_RESULT:" + (c if isinstance(c, str) else json.dumps(c)))
    return "\n".join(out)
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def _go(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            req = json.loads(raw or b"{}")
        except ValueError:
            req = {}
        tools = {t.get("name") for t in req.get("tools") or [] if isinstance(t, dict)}
        msgs = [x for x in req.get("messages") or [] if isinstance(x, dict)]
        texts = [text_of(x.get("content")) for x in msgs if x.get("role") == "user"]
        blocks, stop, what = [{"type": "text", "text": "ok"}], "end_turn", "side"
        for t in reversed(texts):
            if "<task-notification>" in t:
                blocks, what = [{"type": "text", "text": "FINAL REPLY"}], "final"
                break
            if "TOOL_RESULT:" in t:
                blocks, what = [{"type": "text", "text": "MAIN REPLY"}], "main"
                break
            if "ROOST-SMOKE-BG" in t and "Bash" in tools:
                blocks = [{"type": "tool_use", "id": "toolu_roostbg%010d" % next(ids), "name": "Bash",
                           "input": {"command": "sleep " + secs, "description": "smoke background sleep", "run_in_background": True}}]
                stop, what = "tool_use", "bgbash"
                break
        say("REQ %s messages=%d" % (what, len(msgs)))
        if req.get("stream"):
            body, ctype = message(blocks, stop), "text/event-stream"
        else:
            body = json.dumps({"id": "msg_roostbgplain", "type": "message", "role": "assistant",
                               "model": "claude-haiku-4-5", "content": blocks, "stop_reason": stop,
                               "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}).encode()
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
python3 "$D/fake.py" "$D/api.log" "$D/port" "$SLEEP" >/dev/null 2>&1 &
FAKE_PID=$!
i=0; while [ ! -s "$D/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
PORT="$(cat "$D/port" 2>/dev/null)"
[ -n "$PORT" ] || die "the fake API did not start"

tmux -S "$S" -f /dev/null new-session -d -s smoke -x 200 -y 50 -c "$PROJR"
X()      { tmux -S "$S" "$@"; }
pstate() { X show-options -pqv -t "$1" @agent_state 2>/dev/null; }
popt()   { X show-options -pqv -t "$1" "$2" 2>/dev/null; }
screen() { X capture-pane -p -t "$1" 2>/dev/null; }
# bin/roost from a person's shell, aimed at the throwaway server AND at the
# throwaway state directory the pane's hook files its turns in: a `read` that
# looked in the real one would find no record and print `turn` null.
# ROOST_SHAPE_DIR is cleared with it, here and in the pane's environment, so
# a saved shape (#191) defaults under that same throwaway state directory and
# never under the real ~/.local/state/roost/shapes.
R()      { env -u ROOST_RECORD_DIR -u ROOST_SHAPE_DIR XDG_STATE_HOME="$D/xdgstate" ROOST_SOCKET="$S" "$HERE/bin/roost" "$@"; }
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
# The pane's record directory, where the Stop hook files each turn: the hook
# reads XDG_STATE_HOME, which the pane's environment points into $D.
recdir() { printf '%s/roost/panes/%s/%s' "$D/xdgstate" "$(X display -p '#{start_time}-#{pid}')" "${1#%}"; }
turns_in() { ls "$(recdir "$1")/replies" 2>/dev/null | grep -c '^[0-9][0-9]*$'; }

READY='for shortcuts|to cycle|\? for'
PANE="$(X new-window -d -P -F '#{pane_id}' -t smoke -n claude -c "$PROJR" \
  "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
   -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_PID -u CLAUDE_EFFORT \
   -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED \
   -u ROOST_SOCKET -u ROOST_HOME -u CLAUDE_CONFIG_DIR -u ROOST_RECORD_DIR -u ROOST_SHAPE_DIR \
   HOME=$D/home XDG_CONFIG_HOME=$D/xdg XDG_STATE_HOME=$D/xdgstate ROOST_NO_SHIM=1 \
   ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT ANTHROPIC_API_KEY=$KEY CLAUDE_CODE_MAX_RETRIES=0 \
   DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
   claude --model $MODEL --permission-mode default --setting-sources local --settings $D/settings.json; sleep 600")"
wait_screen "$PANE" "trust this folder|$READY" 60 || { dump "$PANE"; die "claude never started"; }
if screen "$PANE" | grep -q 'trust this folder'; then
  X send-keys -t "$PANE" Down Enter
  wait_screen "$PANE" "$READY" 60 || { dump "$PANE"; die "claude never reached its prompt"; }
fi
p="$PANE"

printf '\n== a background shell of %s s ==\n' "$SLEEP"
X send-keys -t "$p" -l "ROOST-SMOKE-BG please"; sleep 1; X send-keys -t "$p" Enter
# The main reply lands when the fake has answered the tool result.
i=0; while [ "$i" -lt 30 ] && ! grep -q 'REQ main' "$D/api.log"; do sleep 1; i=$((i+1)); done
grep -q 'REQ bgbash' "$D/api.log" && ok "claude asked the fake API, which scripted the background Bash" \
  || { dump "$p"; die "the fake API never scripted a background Bash — nothing below tests anything"; }
grep -q 'REQ main' "$D/api.log" && ok "the main reply was answered" || { dump "$p"; die "the main reply never came"; }
sleep 2
case "$(pstate "$p")" in
  working) ok "2 s after the main reply the pane still reads working: the work runs in this pane" ;;
  *) dump "$p"; no "2 s after the main reply the pane reads '$(pstate "$p")', not working — did background_tasks move or lose its shape?" ;;
esac
bg="$(popt "$p" @roost-background)"
case "$bg" in
  "$(popt "$p" @agent_since) 1") ok "@roost-background is '<stamp> 1'" ;;
  *) no "@roost-background reads '$bg'" ;;
esac
rout="$(R read "$p" 2>"$D/read.err")"
[ "$rout" = "MAIN REPLY" ] && ok "read prints the main reply" || no "read printed '$rout'"
grep -q "main reply" "$D/read.err" && ok "...and says on stderr it is the main reply, with the work still running" \
  || no "...but stderr said: $(cat "$D/read.err")"
R wait-done "$p" 3 >/dev/null 2>"$D/wd.err"; rc=$?
case "$rc:$(cat "$D/wd.err")" in
  "1:"*"timed out"*) ok "a 3 s wait-done times out (exit 1) instead of a false 0" ;;
  *) no "wait-done exited $rc: $(cat "$D/wd.err")" ;;
esac
[ "$(turns_in "$p")" = 0 ] && ok "nothing is on disk while the pane is held" || no "$(turns_in "$p") turn file(s) exist while held"

printf '\n== the release ==\n'
if wait_state "$p" done $((SLEEP + 30)); then
  ok "the pane reaches done once the work ends (Claude's own notification turn)"
else
  dump "$p"; no "the pane reads '$(pstate "$p")' $((SLEEP + 30)) s later — did the <task-notification> turn stop coming?"
fi
grep -q 'REQ final' "$D/api.log" && ok "the notification turn asked the fake API" || no "no notification turn reached the fake API"
R wait-done "$p" 5 >/dev/null 2>&1; [ "$?" = 0 ] && ok "wait-done exits 0" || no "wait-done did not exit 0"
rout="$(R read "$p" 2>"$D/read.err")"
[ "$rout" = "FINAL REPLY" ] && ok "read prints the final reply" || no "read printed '$rout' ($(head -1 "$D/read.err"))"
[ -z "$(cat "$D/read.err")" ] && ok "...with nothing on stderr" || no "...with stderr: $(cat "$D/read.err")"
[ -z "$(popt "$p" @roost-background)" ] && ok "@roost-background is cleared" || no "@roost-background still reads '$(popt "$p" @roost-background)'"
[ "$(turns_in "$p")" = 1 ] && ok "exactly ONE turn file for the prompt (the notification turn was folded in)" \
  || no "$(turns_in "$p") turn files for one prompt"
R read --json "$p" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("final") is True and d.get("background") is None and d.get("turn") == 1 else 1)' \
  && ok "read --json: final true, background null, turn 1" || no "read --json did not say final true / background null / turn 1"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
