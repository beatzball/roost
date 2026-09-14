#!/usr/bin/env bash
# Drive REAL Claude Code to a permission dialog, decline it, and check that
# roost can still prove the decline from Claude's own transcript (#38).
#
# NOT part of the suite: this directory is outside tests/'s test-*.sh glob, so
# tests/run.sh never runs it. Run it by hand AFTER EVERY CLAUDE CODE UPGRADE:
#
#   bash tests/live/claude-decline-smoke.sh
#
# WHY IT MUST BE RUN. A decline fires no Claude hook at all, so roost clears
# the 🛑 it leaves by reading three records Claude writes into its transcript
# (scripts/lib/roost-unblock.sh). That format is Claude's, not a published
# contract. If an upgrade changes it, recovery stops SILENTLY — the pane just
# stays blocked, as it did before #38. The suite cannot see that: its fixtures
# are old captures. This file is the only thing that can, and it is written to
# FAIL LOUDLY, printing the transcript's tail, when the shape moves.
#
# It uses your real Claude login (a few cheap haiku turns). It never writes
# under ~/.claude itself, and loads only this checkout's hooks:
# `--setting-sources local` skips your user and project settings, and
# `--settings` adds roost's hooks for this checkout.
#
# ONE THING IT CANNOT AVOID WRITING. The first time Claude runs in a directory
# it asks whether to trust the folder, and Claude records the answer in your
# own Claude config. So the project directory is fixed, not a fresh mktemp
# each run — otherwise every run would leave one more trust entry behind.
# Override it with ROOST_LIVE_CLAUDE_DIR; it must be a git repository or an
# empty directory this script may `git init`.
#
# Isolation: its own tmux socket, ending in /roost so the hooks act on it. The
# live -L roost server is never contacted.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
PROJ="${ROOST_LIVE_CLAUDE_DIR:-/tmp/roost-claude-decline-smoke}"
MODEL="${ROOST_LIVE_CLAUDE_MODEL:-haiku}"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }
command -v claude  >/dev/null 2>&1 || skip "claude not installed"
command -v python3 >/dev/null 2>&1 || command -v jq >/dev/null 2>&1 \
  || skip "neither python3 nor jq — roost cannot read a transcript here at all"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }
die() { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; printf '\n  %d passed, %d failed\n' "$pass" "$fail"; exit 1; }

mkdir -p "$PROJ" || die "cannot create $PROJ"
if [ ! -d "$PROJ/.git" ]; then
  git -C "$PROJ" init -q || die "cannot git init $PROJ"
fi

D="$(mktemp -d /tmp/amx.XXXX)"
S="$D/roost"
L="$(mktemp -d /tmp/amx-claude.XXXX)"
trap 'tmux -S "$S" kill-server 2>/dev/null; rm -rf "$D"; [ "$fail" -eq 0 ] && rm -rf "$L" || printf "  logs kept in %s\n" "$L"' EXIT

# This checkout's hooks, exactly as `roost hooks` prints them.
"$HERE/bin/roost" hooks claude | sed -n '/^{/,$p' > "$D/settings.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$D/settings.json" 2>/dev/null \
  || jq -e . "$D/settings.json" >/dev/null 2>&1 \
  || die "roost hooks claude did not produce loadable JSON"

tmux -S "$S" -f /dev/null new-session -d -s smoke -x 200 -y 50 -c "$PROJ"
. "$HERE/scripts/lib/roost-unblock.sh"
X()      { tmux -S "$S" "$@"; }
pstate() { X show-options -pqv -t "$1" @agent_state 2>/dev/null; }
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

# tail_types TRANSCRIPT — the last records' types, for the loud failure. Types
# and subtypes only, never content: a transcript holds the whole conversation.
tail_types() {
  python3 - "$1" <<'PY' 2>/dev/null || tail -n 12 "$1" | jq -c '{type, subtype, toolDenialKind, timestamp}' 2>/dev/null
import json, sys
for l in open(sys.argv[1]).readlines()[-12:]:
    try:
        r = json.loads(l)
    except ValueError:
        print("    <not json>"); continue
    c = (r.get("message") or {}).get("content")
    kinds = [b.get("type") for b in c] if isinstance(c, list) else type(c).__name__
    print("    %-22s %-16s %-14s %s %s" % (r.get("type"), r.get("subtype", ""), r.get("toolDenialKind", ""), r.get("timestamp", "-"), kinds))
PY
}

# start NAME -> sets PANE, a Claude window ready for a prompt.
PANE=""
start() {
  PANE="$(X new-window -d -P -F '#{pane_id}' -t smoke -n "$1" -c "$PROJ" \
    "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
     -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_PID -u CLAUDE_EFFORT \
     -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED \
     -u ROOST_SOCKET -u ROOST_HOME \
     claude --model $MODEL --setting-sources local --settings $D/settings.json; sleep 600")"
  wait_screen "$PANE" 'trust this folder|for shortcuts' 60 || { dump "$PANE"; die "claude never started ($1)"; }
  if screen "$PANE" | grep -q 'trust this folder'; then
    X send-keys -t "$PANE" Down Enter
    wait_screen "$PANE" 'for shortcuts' 60 || { dump "$PANE"; die "claude never reached its prompt ($1)"; }
  fi
}
ask() { X send-keys -t "$1" -l "$2"; sleep 1; X send-keys -t "$1" Enter; }

# transcript PANE -> the path the Notification hook recorded, or nothing.
transcript() { local r; r="$(X show-options -pqv -t "$1" @roost-transcript 2>/dev/null)"; printf '%s' "${r#* }"; }

# decline_case NAME KEYS — ask for a gated command, wait for 🛑, answer KEYS.
decline_case() {
  local name="$1" keys="$2" tp since
  printf '\n== %s ==\n' "$name"
  start "$name"; local p="$PANE"
  ask "$p" "Use the Bash tool to run exactly this command and nothing else: mkdir roost-smoke-$name-$$"
  wait_state "$p" blocked 120 || { dump "$p"; die "$name: the pane never badged blocked"; }
  ok "$name: the Notification hook badges blocked"
  tp="$(transcript "$p")"; since="$(X show-options -pqv -t "$p" @agent_since)"
  [ -n "$tp" ] && [ -f "$tp" ] && ok "$name: it records a transcript that exists" \
    || die "$name: no transcript recorded (got '$tp') — --notification-hook did not see transcript_path"
  R send "$p" "this must not be delivered" >/dev/null 2>&1
  [ "$?" = "3" ] && ok "$name: send refuses while the dialog is really open" \
    || no "$name: send did NOT refuse a pane with an open dialog"
  X send-keys -t "$p" $keys
  wait_screen "$p" 'Interrupted' 30 || { dump "$p"; no "$name: the dialog did not close"; }
  sleep 2
  if roost_claude_declined "$tp" "$since"; then
    ok "$name: Claude's decline records are still the shape roost reads"
  else
    no "$name: CLAUDE'S DECLINE RECORDS CHANGED SHAPE — recovery is dead after this upgrade. Last records:"
    tail_types "$tp"
    cp "$tp" "$L/$name.transcript.jsonl" 2>/dev/null
  fi
  R send "$p" "" >/dev/null 2>&1
  [ "$?" = "0" ] && ok "$name: send reaches the pane after the decline" \
    || no "$name: send still refuses after the decline (badge '$(pstate "$p")')"
  [ -z "$(pstate "$p")" ] && ok "$name: the badge was cleared, not set" \
    || no "$name: the badge reads '$(pstate "$p")' after recovery"
  LAST_PANE="$p"
}

LAST_PANE=""
decline_case no 3
decline_case esc Escape

# --- round 3: an old decline under a new, approved, still-running tool ------
printf '\n== round 3 ==\n'
p="$LAST_PANE"
ask "$p" "Use the Bash tool in the foreground (not background) to run exactly this command and nothing else: perl -e 'select(undef,undef,undef,40)'"
wait_state "$p" blocked 120 || { dump "$p"; die "round 3: the second dialog never badged blocked"; }
X send-keys -t "$p" 1
wait_screen "$p" 'Running' 30 || { dump "$p"; no "round 3: the approved tool was not seen running"; }
sleep 3
if [ "$(pstate "$p")" = "blocked" ]; then
  R send "$p" "this must not be delivered" >/dev/null 2>&1
  [ "$?" = "3" ] && ok "round 3: a live blocked over an old decline is NOT cleared" \
    || no "round 3: send cleared a live blocked because an older turn was declined"
  [ "$(pstate "$p")" = "blocked" ] && ok "round 3: the badge is untouched" \
    || no "round 3: the badge was changed to '$(pstate "$p")'"
else
  no "round 3: the badge left blocked while the approved tool ran (got '$(pstate "$p")') — PostToolUse timing changed; the case tested nothing"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
