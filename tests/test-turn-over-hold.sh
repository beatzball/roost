#!/usr/bin/env bash
# A Claude turn whose Stop lists background work still running in THIS pane
# holds the pane at ⏳ working until the Stop whose list is empty (#97, step 1
# of docs/airig/specs/2026-09-29-turn-over-design.md).
#
# Measured on Claude Code 2.1.310 (docs/known-gaps.md, "Step 1 measurements"):
# a `run_in_background` Bash, a background Agent and a Monitor all end the
# main turn with a Stop whose `background_tasks` lists them as `running`, the
# pane read ✅ done for the whole run of the work (30 s, 20 s, 25 s), and the
# work's end brought a turn Claude started by itself whose Stop carried `[]`.
# The fixtures under tests/fixtures/claude-stop-bg-*.json are those payloads,
# with ids and paths replaced.
#
# What the hook must do, and what this file pins:
#   - a Stop with a running item of ANY type holds `working`; an unknown type
#     is recorded in @roost-background-types for `roost doctor`
#   - `background_tasks` ABSENT keeps today's done (Q5); present but malformed
#     holds, with a count of `?` (Q5 limits)
#   - the main reply goes on the pane (final: false) and NOTHING on disk; the
#     releasing Stop appends ONE turn file (Q3 built as a deferral, §10 item 2)
#   - @roost-background is "<@agent_since> N", written above the unchanged-state
#     bail, so a pane that already reads working gets it (§10 item 1)
#   - read, read --json, status --json and doctor see a held pane as a main
#     reply, never as a stale one (§10 item 5)
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
FIX="$HERE/tests/fixtures"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available (this file edits its payloads with it)"
  exit 0
fi

# Records ON, in the test's own directory, so turn files can be counted. HOME
# and the XDG dirs are canaries nothing may write to (tests/test-send-turn.sh).
work="$(mktemp -d /tmp/amx.XXXX)"
s="$work/roost"
export ROOST_RECORD_DIR="$work/rec"
export HOME="$work/canary" XDG_CONFIG_HOME="$work/canary/config" \
       XDG_STATE_HOME="$work/canary/state" XDG_DATA_HOME="$work/canary/data"
mkdir -p "$work/canary"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$work"' EXIT
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
spid="$(tmux -S "$s" display -p '#{pid}')"
boot="$(tmux -S "$s" display -p '#{start_time}-#{pid}')"
export ROOST_SOCKET="$s"
unset TMUX TMUX_PANE

X() { tmux -S "$s" "$@"; }
newpane() { X new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh'; }
opt() { X show-options -pqv -t "$1" "$2" 2>/dev/null; }
# pane_has PANE OPTION -> 0 if OPTION is set at pane scope at all.
pane_has() { X show-options -p -t "$1" 2>/dev/null | grep -q "^$2 "; }
hook() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" "$@"; }
recdir() { printf '%s/%s/%s' "$ROOST_RECORD_DIR" "$boot" "${1#%}"; }
turns_in() { ls "$(recdir "$1")/replies" 2>/dev/null | grep -c '^[0-9][0-9]*$'; }
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

UPS='{"session_id":"00000000-0000-4000-8000-000000000001","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl","cwd":"/tmp/roost-fixture/proj","prompt_id":"00000000-0000-4000-8000-000000000002","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"BGBASH-30 run it in the background"}'
SHELL1="$(cat "$FIX/claude-stop-bg-shell.json")"
SUB1="$(cat "$FIX/claude-stop-bg-subagent.json")"
TWO="$(cat "$FIX/claude-stop-bg-two-shells.json")"
EMPTY="$(cat "$FIX/claude-stop-bg-empty.json")"
# edit FIXTURE PYEXPR -> the fixture with the expression applied to d.
edit() { python3 -c 'import json,sys
d=json.loads(sys.argv[1]); exec(sys.argv[2]); print(json.dumps(d))' "$1" "$2"; }

# --- 1. the hold, from a pane that already reads working -------------------------
p="$(newpane)"; require_pane "$p" hold
hook "$p" working <<< "$UPS"
since="$(opt "$p" @agent_since)"
assert_eq "$(opt "$p" @agent_state)" "working" "the prompt stamps working"
sleep 1
hook "$p" done --stop-hook <<< "$SHELL1"; rc=$?
assert_eq "$rc" "0" "a Stop with a running shell exits 0"
assert_eq "$(opt "$p" @agent_state)" "working" "...and HOLDS working: the work still runs in this pane"
assert_eq "$(opt "$p" @agent_since)" "$since" "...without moving the stamp (the unchanged-state bail still ran)"
assert_eq "$(opt "$p" @roost-background)" "$since 1" "@roost-background is '<@agent_since> 1' — written above the bail"
assert_eq "$(opt "$p" @roost-reply)" "AFTER-TOOL" "the main reply is on the pane"
assert_eq "$(turns_in "$p")" "0" "...and NOTHING is on disk: the deferral writes no turn file yet"
pane_has "$p" @roost-reply-turn; assert_eq "$?" "1" "@roost-reply-turn is unset on a held pane (no file to point at)"
pane_has "$p" @roost-background-types; assert_eq "$?" "1" "no unknown type, so no @roost-background-types"

# --- 2. the release: ONE turn file, the final reply --------------------------------
hook "$p" working <<< "$(edit "$UPS" 'd["prompt"]="<task-notification>..."')"
assert_eq "$(opt "$p" @agent_state)" "working" "the notification turn stamps working (a repeat)"
hook "$p" done --stop-hook <<< "$EMPTY"
assert_eq "$(opt "$p" @agent_state)" "done" "the Stop whose list is empty releases the pane"
assert_eq "$(turns_in "$p")" "1" "...and appends exactly ONE turn file for the two Stops"
assert_eq "$(cat "$(recdir "$p")/replies/000001")" "FINAL REPLY" "...holding the final reply"
assert_eq "$(opt "$p" @roost-reply)" "FINAL REPLY" "...which is now the pane's reply"
assert_eq "$(opt "$p" @roost-reply-turn)" "1" "...and @roost-reply-turn names it"
pane_has "$p" @roost-background; assert_eq "$?" "1" "@roost-background is cleared by the releasing Stop"
assert_eq "$("$ROOST" read "$p" 2>/dev/null)" "FINAL REPLY" "read serves the final reply"

# --- 3. the other shapes that hold -----------------------------------------------
p="$(newpane)"; require_pane "$p" subagent
hook "$p" working <<< "$UPS"; since="$(opt "$p" @agent_since)"
hook "$p" done --stop-hook <<< "$SUB1"
assert_eq "$(opt "$p" @agent_state)" "working" "a running subagent holds"
assert_eq "$(opt "$p" @roost-background)" "$since 1" "...count 1"

p="$(newpane)"; require_pane "$p" two
hook "$p" working <<< "$UPS"; since="$(opt "$p" @agent_since)"
hook "$p" done --stop-hook <<< "$TWO"
assert_eq "$(opt "$p" @agent_state)" "working" "two running shells (a Monitor is a shell) hold"
assert_eq "$(opt "$p" @roost-background)" "$since 2" "...count 2"
hook "$p" done --stop-hook <<< "$SHELL1"
assert_eq "$(opt "$p" @roost-background)" "$since 1" "a later Stop with one left updates the count to 1"
assert_eq "$(turns_in "$p")" "0" "...and still writes nothing"

p="$(newpane)"; require_pane "$p" unknown
hook "$p" working <<< "$UPS"; since="$(opt "$p" @agent_since)"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["background_tasks"][0]["type"]="teammate"')"
assert_eq "$(opt "$p" @agent_state)" "working" "an UNKNOWN type holds too (§3.1: not known to live elsewhere)"
assert_eq "$(opt "$p" @roost-background)" "$since 1" "...and counts"
assert_eq "$(opt "$p" @roost-background-types)" "$since teammate" "...and the type is recorded for roost doctor"
hook "$p" done --stop-hook <<< "$EMPTY"
pane_has "$p" @roost-background-types; assert_eq "$?" "1" "the release clears the recorded types too"

p="$(newpane)"; require_pane "$p" notype
hook "$p" working <<< "$UPS"; since="$(opt "$p" @agent_since)"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'del d["background_tasks"][0]["type"]')"
assert_eq "$(opt "$p" @agent_state)" "working" "an item with no type holds"
assert_eq "$(opt "$p" @roost-background-types)" "$since ?" "...recorded as ?"

p="$(newpane)"; require_pane "$p" badtype
hook "$p" working <<< "$UPS"; since="$(opt "$p" @agent_since)"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["background_tasks"][0]["type"]="x y;set-option -g @evil 1"')"
assert_eq "$(opt "$p" @agent_state)" "working" "a type that is not a word still holds"
assert_eq "$(opt "$p" @roost-background-types)" "$since ?" "...and is recorded as ?, never as text"
assert_eq "$(X show-options -gqv @evil)" "" "...nothing from the payload reached a tmux command"

# --- 4. Q5: absent keeps done; malformed holds ------------------------------------
p="$(newpane)"; require_pane "$p" absent
hook "$p" working <<< "$UPS"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'del d["background_tasks"]')"
assert_eq "$(opt "$p" @agent_state)" "done" "no background_tasks key at all: today's done (Q5, an older Claude)"
pane_has "$p" @roost-background; assert_eq "$?" "1" "...and no @roost-background: roost could not see"
assert_eq "$(turns_in "$p")" "1" "...and the turn is recorded as today"

for bad in 'd["background_tasks"]={}' 'd["background_tasks"]="running"' 'd["background_tasks"]=[{"id":"x","type":"shell"}]' 'd["background_tasks"]=[{"id":"x","type":"shell","status":7}]' 'd["background_tasks"]=["running"]'; do
  p="$(newpane)"; require_pane "$p" malformed
  hook "$p" working <<< "$UPS"; since="$(opt "$p" @agent_since)"
  hook "$p" done --stop-hook <<< "$(edit "$SHELL1" "$bad")"
  assert_eq "$(opt "$p" @agent_state)" "working" "present but malformed is could-not-tell: held [$bad]"
  assert_eq "$(opt "$p" @roost-background)" "$since ?" "...with a count of ? [$bad]"
  assert_eq "$(turns_in "$p")" "0" "...and nothing on disk [$bad]"
done

p="$(newpane)"; require_pane "$p" notrunning
hook "$p" working <<< "$UPS"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["background_tasks"][0]["status"]="completed"')"
assert_eq "$(opt "$p" @agent_state)" "done" "an item whose status is not running does not hold"
assert_eq "$(turns_in "$p")" "1" "...and the turn is recorded"

# --- 5. a held Stop from a pane that was NOT working ------------------------------
p="$(newpane)"; require_pane "$p" fromdone
hook "$p" working <<< "$UPS"
hook "$p" done --stop-hook <<< "$EMPTY"
assert_eq "$(opt "$p" @agent_state)" "done" "a finished pane"
sleep 1
hook "$p" done --stop-hook <<< "$SHELL1"
assert_eq "$(opt "$p" @agent_state)" "working" "a held Stop on a done pane stamps working"
assert_eq "$(opt "$p" @roost-background)" "$(opt "$p" @agent_since) 1" "...and @roost-background carries the NEW stamp"
assert_eq "$(turns_in "$p")" "1" "...and no second turn file"

# --- 6. an empty main reply while work runs -------------------------------------
p="$(newpane)"; require_pane "$p" emptyreply
hook "$p" working <<< "$UPS"; since="$(opt "$p" @agent_since)"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["last_assistant_message"]=""')"
assert_eq "$(opt "$p" @agent_state)" "working" "a held Stop with no reply text still holds"
assert_eq "$(opt "$p" @roost-background)" "$since 1" "...and records the count"
pane_has "$p" @roost-reply; assert_eq "$?" "1" "...with no reply on the pane"

# --- 7. the jq reader, on a PATH with no python3 ---------------------------------
if command -v jq >/dev/null 2>&1; then
  shim="$work/jq-only-bin"; mkdir -p "$shim"
  for c in tmux jq cat date dirname readlink sh bash env mktemp ln rm mkdir chmod ls sort tail head find mv; do
    real="$(command -v "$c")" || continue
    printf '#!/bin/sh\nexec %s "$@"\n' "$real" > "$shim/$c"; chmod +x "$shim/$c"
  done
  env PATH="$shim" sh -c 'command -v python3' >/dev/null 2>&1; jrc=$?
  [ "$jrc" -ne 0 ]; assert_true $? "the jq-only PATH really has no python3 (probe exit $jrc)"
  jhook() { local p="$1"; shift; env PATH="$shim" TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" "$@"; }
  p="$(newpane)"; require_pane "$p" jq
  jhook "$p" working <<< "$UPS"; since="$(opt "$p" @agent_since)"
  jhook "$p" done --stop-hook <<< "$TWO"
  assert_eq "$(opt "$p" @agent_state)" "working" "jq reader: two running shells hold"
  assert_eq "$(opt "$p" @roost-background)" "$since 2" "jq reader: ...count 2"
  assert_eq "$(opt "$p" @roost-reply)" "AFTER-TOOL" "jq reader: the main reply is on the pane"
  jhook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["background_tasks"][0]["type"]="teammate"')"
  assert_eq "$(opt "$p" @roost-background-types)" "$since teammate" "jq reader: an unknown type is recorded"
  jhook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["background_tasks"]=[{"id":"x"}]')"
  assert_eq "$(opt "$p" @roost-background)" "$since ?" "jq reader: malformed is ?"
  jhook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'del d["background_tasks"]')"
  assert_eq "$(opt "$p" @agent_state)" "done" "jq reader: absent is done"
  jhook "$p" working <<< "$UPS"
  jhook "$p" done --stop-hook <<< "$EMPTY"
  assert_eq "$(opt "$p" @agent_state)" "done" "jq reader: an empty list releases"
  assert_eq "$(turns_in "$p")" "2" "jq reader: ...two released turns, two files"
else
  echo "  SKIP: jq not available, so the jq reader is not run here"
fi

# --- 8. read, status --json and doctor on a held pane (step 1, §10 item 5) ---------
p="$(newpane)"; require_pane "$p" readheld
hook "$p" working <<< "$UPS"; since="$(opt "$p" @agent_since)"
hook "$p" done --stop-hook <<< "$SHELL1"
out="$("$ROOST" read "$p" 2>"$work/err")"; rc=$?
assert_eq "$rc" "0" "read on a held pane exits 0"
assert_eq "$out" "AFTER-TOOL" "...and prints the main reply"
assert_eq "$(wc -l < "$work/err" | tr -d ' ')" "1" "...with ONE stderr line"
assert_contains "$(cat "$work/err")" "main reply" "...that says it is the main reply"
assert_contains "$(cat "$work/err")" "1 task still running" "...and how many tasks still run"
case "$(cat "$work/err")" in *"previous turn"*) r=stale ;; *) r=fresh ;; esac
assert_eq "$r" "fresh" "...and never calls it the previous turn's"
"$ROOST" read --json "$p" > "$work/rj" 2>/dev/null
assert_eq "$(jget 'd["stale"]' < "$work/rj")" "False" "read --json: stale is false on a held pane"
assert_eq "$(jget 'd["final"]' < "$work/rj")" "False" "read --json: final is false"
assert_eq "$(jget 'd["background"]' < "$work/rj")" "1" "read --json: background is 1"
assert_eq "$(jget 'd["text"]' < "$work/rj")" "AFTER-TOOL" "read --json: the text is the main reply"
"$ROOST" status --json > "$work/sj" 2>/dev/null
assert_eq "$(jget '[x["background"] for x in d["panes"] if x["id"]=="'"$p"'"][0]' < "$work/sj")" "1" "status --json: background is 1 on the held pane"
assert_eq "$(jget 'sorted(set(str(x["background"]) for x in d["panes"] if x["id"]!="'"$p"'" and x["state"]!="working"))' < "$work/sj")" "['None']" "status --json: null on every pane that is not held"
# two tasks: plural
p2="$(newpane)"; require_pane "$p2" readheld2
hook "$p2" working <<< "$UPS"
hook "$p2" done --stop-hook <<< "$TWO"
"$ROOST" read "$p2" >/dev/null 2>"$work/err"
assert_contains "$(cat "$work/err")" "2 tasks still running" "read says '2 tasks' for two"
# a record from an OLDER stamp is not this turn's hold
p3="$(newpane)"; require_pane "$p3" oldrecord
hook "$p3" working <<< "$UPS"
X set-option -p -t "$p3" @roost-background "1 1"
X set-option -p -t "$p3" @roost-reply "OLD"
"$ROOST" read "$p3" >/dev/null 2>"$work/err"
assert_contains "$(cat "$work/err")" "previous turn" "a @roost-background from another stamp is ignored: the reply is stale"
"$ROOST" read --json "$p3" > "$work/rj" 2>/dev/null
assert_eq "$(jget 'd["final"]' < "$work/rj")" "True" "...final true"
assert_eq "$(jget 'd["background"]' < "$work/rj")" "None" "...background null"
X set-option -p -t "$p3" @roost-background "$(opt "$p3" @agent_since) ?"
"$ROOST" read --json "$p3" > "$work/rj" 2>/dev/null
assert_eq "$(jget 'd["stale"]' < "$work/rj")" "False" "a ? count is a hold roost could not count: not stale"
assert_eq "$(jget 'd["final"]' < "$work/rj")" "False" "...final false"
assert_eq "$(jget 'd["background"]' < "$work/rj")" "None" "...background null, never 0"
"$ROOST" status --json > "$work/sj" 2>/dev/null
assert_eq "$(jget '[x["background"] for x in d["panes"] if x["id"]=="'"$p3"'"][0]' < "$work/sj")" "None" "status --json: ? is null"
# the released pane: final true, background null
"$ROOST" read --json "$p" >/dev/null 2>&1
hook "$p" done --stop-hook <<< "$EMPTY"
"$ROOST" read --json "$p" > "$work/rj" 2>/dev/null
assert_eq "$(jget 'd["final"]' < "$work/rj")" "True" "after the release, read --json says final true"
assert_eq "$(jget 'd["background"]' < "$work/rj")" "None" "...and background null"
# doctor names a pane held by an unknown type
p4="$(newpane)"; require_pane "$p4" doctor
hook "$p4" working <<< "$UPS"
hook "$p4" done --stop-hook <<< "$(edit "$SHELL1" 'd["background_tasks"][0]["type"]="teammate"')"
dout="$(ROOST_CONFIG_SOCK="$s" "$ROOST" doctor 2>&1 || true)"
assert_contains "$dout" "$p4" "doctor names the pane held by an unknown kind of background work"
assert_contains "$dout" "teammate" "...and the kind"

# --- 9. the canaries ----------------------------------------------------------------
[ -z "$(find "$work/canary" -type f 2>/dev/null)" ]; assert_true $? "nothing was written under HOME or the XDG dirs"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
