#!/usr/bin/env bash
# Drive REAL Claude Code to real dialogs and answer them with `roost answer`
# (#142): approve and deny a permission prompt, refuse a stale fingerprint
# with nothing sent, approve an Edit, and pick option 2 of a question.
#
# NOT part of the suite: this directory is outside tests/'s test-*.sh glob, so
# tests/run.sh never runs it. Run it by hand AFTER EVERY CLAUDE CODE UPGRADE:
#
#   bash tests/live/answer-smoke.sh
#
# WHY IT MUST BE RUN. `roost answer` sends keys from a measured map
# (scripts/lib/roost-answer.sh) and checks for the dialog's marker text on the
# screen before it sends. Both are Claude's, not a contract: the day a dialog
# is reworded every answer is refused with exit 6 (safe, and reported as a
# roost bug), and the day a key changes meaning the map is wrong. The suite's
# dialogs are stand-ins and cannot see either. This file is the only thing
# that can, and it FAILS LOUDLY, printing the pane, when the shape moves.
# docs/airig/specs/2026-09-30-roost-answer-design.md §5 is the map it checks.
#
# NO REAL MODEL ANSWERS. Claude is pointed at a local fake Messages API that
# scripts each reply: a prompt carrying a ROOST-SMOKE word gets the one tool
# call that word names, and a tool result gets a short final answer. A request
# that offers no tools (Claude's own side requests) gets a plain "ok". The fake
# logs what it decided and the text of each tool result, never headers, which
# carry your login.
#
# NEVER TYPE A SLASH COMMAND THAT SAVES ANYTHING into these panes: /model,
# /config, /login, /logout, /theme, /permissions, /terminal-setup, /vim. On
# 2.1.272 `/model haiku` saved a new default into the user's own
# ~/.claude/settings.json even under `--setting-sources local`. The model is
# chosen with --model on the command line, and the permission mode with
# --permission-mode default: from 2.1.307 Claude starts in auto mode, whose
# classifier asks the same fake API and never opens a dialog.
#
# As a guard against the next one, this script hashes ~/.claude/settings.json
# and ~/.codex/config.toml before it starts and again when it exits, and lists
# the project keys of ~/.claude.json (keys only, never values) to fail if one
# appeared. It never repairs anything: that is the owner's call.
#
# It loads only this checkout's hooks: `--setting-sources local` skips your
# user and project settings, `--settings` adds roost's hooks for this
# checkout, and ROOST_NO_SHIM=1 keeps roost's own claude shim (#58), which a
# pane would otherwise inherit from the shell this runs in, from adding a
# second settings file.
#
# ONE THING IT CANNOT AVOID WRITING. The first time Claude runs in a directory
# it asks whether to trust the folder, and Claude records the answer in your
# own Claude config. So the project directory is fixed, and it is the SAME one
# tests/live/claude-decline-smoke.sh uses, so running both leaves one trust
# entry, not two. Override it with ROOST_LIVE_CLAUDE_DIR; it must be a git
# repository or an empty directory this script may `git init`.
#
# Isolation: its own tmux socket, ending in /roost so the hooks act on it. The
# live -L roost server is never contacted. Every `roost answer` runs with
# TMUX and TMUX_PANE removed, the way a person's own terminal calls it.
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
# ~/.claude.json changes on every Claude run (counters, tips), so it cannot be
# hashed. What must not change is the set of projects it trusts.
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
  local bad=0 resolved
  if [ "$(guard_hash)" != "$GUARD_BEFORE" ]; then
    printf '\n  FAIL: THIS RUN CHANGED YOUR OWN CONFIG. Not repaired. Before, then after:\n'
    printf '%s\n' "$GUARD_BEFORE" | sed 's/^/    /'
    guard_hash | sed 's/^/    /'
    bad=1
  fi
  # The one project key this run may add is the fixed project directory's.
  resolved="$(cd -P "$PROJ" 2>/dev/null && pwd)"
  new="$(project_keys | grep -vxF -e "$PROJ" -e "$resolved" | comm -13 <(printf '%s\n' "$KEYS_BEFORE") - 2>/dev/null)"
  if [ -n "$new" ]; then
    printf '\n  FAIL: THIS RUN ADDED A TRUSTED PROJECT to ~/.claude.json. Not repaired:\n'
    printf '%s\n' "$new" | sed 's/^/    /'
    bad=1
  fi
  return "$bad"
}

D="$(mktemp -d /tmp/amx.XXXX)"
# Saved shapes (#191) go under this run's temp dir: saving is always on for a
# real user, so a roost verb here would otherwise write the fleet shape into
# the real ~/.local/state/roost/shapes. Exported before the server starts, so
# its panes inherit it too.
export ROOST_SHAPE_DIR="$D/shapes"
S="$D/roost"
FAKE_PID=""
# On a failure the fake API's log -- what it decided for each request, and the
# text of each tool result -- is copied to $ROOST_SMOKE_KEEP_LOG when that is
# set, so a changed request shape can be read after the run's directory is gone.
trap 'tmux -S "$S" kill-server 2>/dev/null; [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; [ "$fail" -eq 0 ] || cp "$D/api.log" "${ROOST_SMOKE_KEEP_LOG:-/dev/null}" 2>/dev/null; rm -rf "$D"; guard_check || exit 1' EXIT

# This checkout's hooks, exactly as `roost hooks` prints them.
"$HERE/bin/roost" hooks claude | sed -n '/^{/,$p' > "$D/settings.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["hooks"]["PermissionRequest"]' "$D/settings.json" 2>/dev/null \
  || die "roost hooks claude has no PermissionRequest entry"

# The fake API. Port 0, so the kernel picks a free one and the script writes it
# down. Every response closes its connection, or the client waits on a stream
# with no length.
cat > "$D/fake.py" <<'PY'
import http.server, json, re, sys, itertools
log, portfile, PROJ = sys.argv[1], sys.argv[2], sys.argv[3]
ids = itertools.count(1)
def say(s):
    with open(log, "a") as f:
        f.write(s + "\n")
def sse(events):
    return "".join("event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e)) for e in events).encode()
def message(blocks, stop):
    mid = "msg_roostanswer%012d" % next(ids)
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
    ev.append({"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
               "usage": {"output_tokens": 1}})
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
def tool(name, inp):
    return {"type": "tool_use", "id": "toolu_roostanswer%010d" % next(ids), "name": name, "input": inp}
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
        # Claude sends the prompt, a tool's result and its own reminders as
        # separate user messages, so neither the prompt nor the result is
        # always the last one. Walking back from the newest user message, the
        # first of the two found says where the turn is: a tool result means
        # the scripted tool call already happened, a marker means the prompt
        # that asks for it.
        texts = [text_of(x.get("content")) for x in msgs if x.get("role") == "user"]
        blocks, stop, what = [{"type": "text", "text": "ok"}], "end_turn", "side"
        m = None
        for t in reversed(texts):
            if "TOOL_RESULT:" in t:
                say("RESULT " + " ".join(t.split())[:400])
                blocks, what = [{"type": "text", "text": "SMOKE DONE"}], "final"
                break
            found = re.findall(r"ROOST-SMOKE-(BASH|ASK|READ|EDIT)-([a-z0-9]+)", t)
            if found:
                m = re.match(r"(BASH|ASK|READ|EDIT)-(.*)", "%s-%s" % found[-1])
                break
        if m:
            if m.group(1) == "BASH" and "Bash" in tools:
                blocks = [tool("Bash", {"command": "mkdir answer-smoke-" + m.group(2),
                                        "description": "Make the smoke directory"})]
                stop, what = "tool_use", "bash " + m.group(2)
            elif m.group(1) == "READ" and "Read" in tools:
                # Claude refuses an Edit of a file it has not read, so the
                # Edit case reads first, in a turn of its own.
                blocks = [tool("Read", {"file_path": PROJ + "/answer-smoke-edit.txt"})]
                stop, what = "tool_use", "read " + m.group(2)
            elif m.group(1) == "EDIT" and "Edit" in tools:
                blocks = [tool("Edit", {"file_path": PROJ + "/answer-smoke-edit.txt",
                                        "old_string": "alpha", "new_string": "beta"})]
                stop, what = "tool_use", "edit " + m.group(2)
            elif m.group(1) == "ASK" and "AskUserQuestion" in tools:
                blocks = [tool("AskUserQuestion", {"questions": [{
                    "question": "Which color do you want?", "header": "Color", "multiSelect": False,
                    "options": [{"label": "Red", "description": "red"},
                                {"label": "Green", "description": "green"},
                                {"label": "Blue", "description": "blue"}]}]})]
                stop, what = "tool_use", "ask " + m.group(2)
        say("REQ " + self.path.split("?")[0] + " " + what + " messages=" + str(len(msgs)))
        if req.get("stream"):
            body, ctype = message(blocks, stop), "text/event-stream"
        else:
            body = json.dumps({"id": "msg_roostanswerplain", "type": "message", "role": "assistant",
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
python3 "$D/fake.py" "$D/api.log" "$D/port" "$(cd -P "$PROJ" && pwd)" >/dev/null 2>&1 &
FAKE_PID=$!
i=0; while [ ! -s "$D/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
PORT="$(cat "$D/port" 2>/dev/null)"
[ -n "$PORT" ] || die "the fake API did not start"

tmux -S "$S" -f /dev/null new-session -d -s smoke -x 200 -y 50 -c "$PROJ"
X()      { tmux -S "$S" "$@"; }
pstate() { X show-options -pqv -t "$1" @agent_state 2>/dev/null; }
screen() { X capture-pane -p -t "$1" 2>/dev/null; }
R()      { ROOST_SOCKET="$S" "$HERE/bin/roost" "$@"; }
# A person's terminal: no TMUX, no TMUX_PANE, stdin not this script's.
A()      { env -u TMUX -u TMUX_PANE ROOST_SOCKET="$S" "$HERE/bin/roost" answer "$@" </dev/null; }
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
# dialog PANE FIELD -> one field of the pane's `dialog` in status --json.
dialog() {
  R status --json | python3 -c 'import json,sys
d = json.load(sys.stdin)
p = [x for x in d["panes"] if x["id"] == sys.argv[1]]
dl = p[0]["dialog"] if p else None
print("" if dl is None else dl.get(sys.argv[2]))' "$1" "$2"
}

READY='for shortcuts|to cycle'
PANE=""
start() {
  PANE="$(X new-window -d -P -F '#{pane_id}' -t smoke -n "$1" -c "$PROJ" \
    "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
     -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_PID -u CLAUDE_EFFORT \
     -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED \
     -u ROOST_SOCKET -u ROOST_HOME ROOST_NO_SHIM=1 ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT \
     claude --model $MODEL --permission-mode default --setting-sources local --settings $D/settings.json; sleep 600")"
  wait_screen "$PANE" "trust this folder|$READY" 60 || { dump "$PANE"; die "claude never started ($1)"; }
  if screen "$PANE" | grep -q 'trust this folder'; then
    X send-keys -t "$PANE" Down Enter
    wait_screen "$PANE" "$READY" 60 || { dump "$PANE"; die "claude never reached its prompt ($1)"; }
  fi
}
ask() { X send-keys -t "$1" -l "$2"; sleep 1; X send-keys -t "$1" Enter; }
# open_bash PANE WORD -> a permission dialog for `mkdir answer-smoke-WORD`.
open_bash() {
  rm -rf "$PROJ/answer-smoke-$2"
  ask "$1" "ROOST-SMOKE-BASH-$2 please"
  wait_state "$1" blocked 60 || { dump "$1"; die "$2: the pane never badged blocked"; }
  wait_screen "$1" 'Do you want to' 10 || { dump "$1"; die "$2: no permission dialog on screen"; }
}

# --- approve -----------------------------------------------------------------
printf '\n== approve ==\n'
start approve; p="$PANE"
open_bash "$p" a1
[ "$(dialog "$p" kind)" = permission ] && ok "approve: status --json says a permission dialog is open" \
  || { dump "$p"; no "approve: dialog.kind is '$(dialog "$p" kind)', not permission"; }
fp="$(dialog "$p" fingerprint)"
out="$(A --expect "$fp" "$p" --approve 2>"$D/err")"; rc=$?
[ "$rc" = 0 ] && ok "approve: roost answer exits 0" \
  || { dump "$p"; no "approve: roost answer exited $rc: $(cat "$D/err")"; }
[ "$out" = "$p approve $fp" ] && ok "approve: it prints the pane, the action and the fingerprint" \
  || no "approve: it printed '$out'"
wait_state "$p" done 30 || { dump "$p"; no "approve: the turn did not finish"; }
[ -d "$PROJ/answer-smoke-a1" ] && ok "approve: the approved command really ran" \
  || no "approve: the directory the command makes is not there — the key did not approve"
rm -rf "$PROJ/answer-smoke-a1"

# --- a stale fingerprint, then a deny ------------------------------------------
printf '\n== stale, then deny ==\n'
open_bash "$p" d1
fp="$(dialog "$p" fingerprint)"
A --expect 000000000000 "$p" --approve >/dev/null 2>"$D/err"; rc=$?
[ "$rc" = 7 ] && ok "stale: a fingerprint that is not this dialog's is exit 7" \
  || no "stale: exit $rc: $(cat "$D/err")"
sleep 1
screen "$p" | grep -q 'Do you want to' && [ "$(pstate "$p")" = blocked ] \
  && ok "stale: the dialog is still open, so nothing was sent" \
  || { dump "$p"; no "stale: the dialog is gone after a refusal"; }
out="$(A "$p" --deny 2>"$D/err")"; rc=$?
[ "$rc" = 0 ] && ok "deny: roost answer --deny exits 0" \
  || { dump "$p"; no "deny: exit $rc: $(cat "$D/err")"; }
grep -q "denying '$p': Bash: mkdir answer-smoke-d1" "$D/err" \
  && ok "deny: it said on stderr what it was denying" || no "deny: stderr was: $(cat "$D/err")"
[ -z "$(pstate "$p")" ] && ok "deny: the badge was cleared from Claude's transcript" \
  || no "deny: the badge reads '$(pstate "$p")'"
[ ! -d "$PROJ/answer-smoke-d1" ] && ok "deny: the denied command did not run" \
  || no "deny: the directory exists — the deny approved it"

# --- approve an Edit (measured on 2.1.309 for this verb) ------------------------
printf '\n== approve an edit ==\n'
printf 'alpha\n' > "$PROJ/answer-smoke-edit.txt"
ask "$p" "ROOST-SMOKE-READ-r1 please"
wait_state "$p" done 60 || { dump "$p"; no "edit: the Read turn did not finish"; }
ask "$p" "ROOST-SMOKE-EDIT-e1 please"
wait_state "$p" blocked 60 || { dump "$p"; die "edit: the pane never badged blocked"; }
wait_screen "$p" 'Do you want to' 10 || { dump "$p"; die "edit: no permission dialog on screen"; }
[ "$(dialog "$p" kind)" = permission ] && ok "edit: status --json says a permission dialog is open" \
  || no "edit: dialog.kind is '$(dialog "$p" kind)'"
fp="$(dialog "$p" fingerprint)"
A --expect "$fp" "$p" --approve >/dev/null 2>"$D/err"; rc=$?
[ "$rc" = 0 ] && ok "edit: roost answer --approve exits 0" \
  || { dump "$p"; no "edit: exit $rc: $(cat "$D/err")"; }
wait_state "$p" done 30 || { dump "$p"; no "edit: the turn did not finish"; }
[ "$(cat "$PROJ/answer-smoke-edit.txt" 2>/dev/null)" = beta ] && ok "edit: the approved edit was made" \
  || no "edit: the file reads '$(cat "$PROJ/answer-smoke-edit.txt" 2>/dev/null)', not beta"
rm -f "$PROJ/answer-smoke-edit.txt"

# --- a question, --option 2 -----------------------------------------------------
printf '\n== a question ==\n'
ask "$p" "ROOST-SMOKE-ASK-q1 please"
wait_state "$p" blocked 60 || { dump "$p"; die "question: the pane never badged blocked"; }
wait_screen "$p" 'Enter to select' 10 || { dump "$p"; die "question: no question on screen"; }
[ "$(dialog "$p" kind)" = question ] && [ "$(dialog "$p" options)" = 3 ] \
  && ok "question: status --json says a question with 3 options is open" \
  || no "question: dialog.kind/options are '$(dialog "$p" kind)'/'$(dialog "$p" options)'"
fp="$(dialog "$p" fingerprint)"
A --expect "$fp" "$p" --option 4 >/dev/null 2>"$D/err"; rc=$?
[ "$rc" = 8 ] && ok "question: --option 4, Claude's own 'Type something.' row, is refused with exit 8" \
  || no "question: --option 4 exited $rc: $(cat "$D/err")"
out="$(A --expect "$fp" "$p" --option 2 2>"$D/err")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "$p option 2 $fp" ] && ok "question: roost answer --option 2 exits 0" \
  || { dump "$p"; no "question: exit $rc, '$out': $(cat "$D/err")"; }
wait_state "$p" done 30 || { dump "$p"; no "question: the turn did not finish"; }
grep '^RESULT ' "$D/api.log" | grep -q 'Green' && ok "question: Claude sent the model the answer Green" \
  || no "question: no tool result named Green: $(grep '^RESULT ' "$D/api.log" | tail -1)"

# --- what Claude received -------------------------------------------------------
grep -q '^REQ .* bash a1' "$D/api.log" && ok "the fake API scripted the dialogs (so this tested Claude, not nothing)" \
  || no "the fake API never scripted a Bash call"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
