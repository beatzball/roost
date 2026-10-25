#!/usr/bin/env bash
# The report filter (#105, step 4 of docs/airig/specs/2026-09-29-turn-over-
# design.md): a state report counts only when it comes from inside the pane's
# own process tree.
#
# Pinned here, each against the real sink and a real pane:
#
#   1. a report from inside the pane is ACCEPTED and marked verified, through
#      a walk of zero levels (the pane's shell is the parent) and of one
#   2. a report from a process OUTSIDE the pane is REFUSED, by the §4.3 rule:
#      a busy badge stays, a done or idle badge is unset by a refused working
#      or blocked, an error badge stays; nothing above the unchanged-state
#      bail (the reply, the hold) is written; @roost-refused names it, and so
#      do `state --json`, `status --json` and `roost doctor`
#   3. a walk that CANNOT RUN (`ps` fails) accepts the report and marks it
#      unverified, visible in `status --json`, `state --json` and doctor
#      (the human's Q4 and its limits)
#   4. the unchanged-state hot path does not walk at all
#   5. a SessionEnd from outside the pane does not release a held pane
#
# tests/lib.sh exports ROOST_TEST_SKIP_ANCESTRY=1 for every other file in the
# suite, which report from the test's own shell -- outside every pane. This
# file is the one that must see the filter work, so it unsets it, and starts
# its server without it so no pane inherits it.
set -u
. "$(dirname "$0")/lib.sh"
unset ROOST_TEST_SKIP_ANCESTRY
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
SINK="$HERE/scripts/roost-agent-state"
DOC="$HERE/scripts/roost-doctor"

if ! command -v python3 >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then
    printf '  FAIL: python3 is the JSON oracle for tests/test-report-filter.sh and CI must provide it\n'
    exit 1
  fi
  printf '  SKIP: tests/test-report-filter.sh needs python3 as its JSON oracle (roost itself does not)\n'
  exit 0
fi

# The sink acts only on a socket whose path ends in /roost, so the server is
# built here, as tests/test-agent-state.sh builds its own.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
work="$sdir/w"; mkdir -p "$work"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
env -u ROOST_TEST_SKIP_ANCESTRY tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
T() { tmux -S "$s" "$@"; }
spid="$(T display-message -p '#{pid}')"
export ROOST_SOCKET="$s"   # bin/roost talks to this server
unset TMUX TMUX_PANE

opt() { T show-options -pqv -t "$1" "$2"; }
pstate() { opt "$1" @agent_state; }
since_of() { opt "$1" @agent_since; }
# out PANE ARGS... -- the sink run from THIS shell, with the pane's TMUX_PANE:
# the "copied environment" case, a process outside the pane's tree.
out() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$SINK" "$@"; }
out_roost() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$ROOST" "$@"; }
wait_state() { # PANE STATE -- up to ~5s
  local n=50; while [ "$(pstate "$1")" != "$2" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
  [ "$(pstate "$1")" = "$2" ]
}
# jfield JSON KEY [PANE] -- one field of a document; with PANE, of that pane
# in status --json's `panes`. Prints JSON (true, false, null, a number, or a
# quoted string), so "null" and a missing key can be told apart.
jfield() {
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if len(sys.argv) > 3:
    d = [p for p in d["panes"] if p["id"] == sys.argv[3]][0]
print(json.dumps(d[sys.argv[2]]) if sys.argv[2] in d else "MISSING")' "$@"
}

# The in-pane reporter: a script the pane runs as a CHILD of its shell, which
# runs the sink as ITS child -- so the walk is one level, the shape of a
# harness's hook (hook -> agent -> pane, M8). `$1` is the state.
cat > "$work/reporter" <<EOF
#!/bin/sh
"$SINK" "\$1" </dev/null
EOF
chmod +x "$work/reporter"

# --- 1. inside the pane: accepted, verified ---------------------------------------
# Zero levels: the pane's shell runs the sink itself, so the sink's parent IS
# the pane's process.
p="$(T new-window -d -P -F '#{pane_id}' "sh -c '\"$SINK\" working </dev/null; exec sleep 600'")"
require_pane "$p" inpane0
wait_state "$p" working; assert_true $? "a report from the pane's own shell is accepted"
assert_eq "$(opt "$p" @roost-verified)" "$(since_of "$p") 1" "...and marked verified, tied to its stamp"
assert_eq "$(opt "$p" @roost-refused)" "" "...and nothing is refused"

# One level: the shape every harness's hook has.
p1="$(T new-window -d -P -F '#{pane_id}' "sh -c '\"$work/reporter\" blocked; exec sleep 600'")"
require_pane "$p1" inpane1
wait_state "$p1" blocked; assert_true $? "a report one process below the pane's shell is accepted"
assert_eq "$(opt "$p1" @roost-verified)" "$(since_of "$p1") 1" "...and marked verified"
st="$("$ROOST" status --json)"
assert_eq "$(jfield "$st" verified "$p1")" "true" "status --json: verified is true for it"
assert_eq "$(jfield "$st" refused "$p1")" "null" "status --json: refused is null for it"

# --- 2. outside the pane: refused --------------------------------------------------
# The pane is busy (blocked): a refused `done` keeps it busy. The safe
# direction (§4.3).
b4="$(since_of "$p1")"
out "$p1" done
assert_eq "$(pstate "$p1")" "blocked" "outside: a refused done keeps a busy badge"
assert_eq "$(since_of "$p1")" "$b4" "...and its stamp"
ref="$(opt "$p1" @roost-refused)"
case "$ref" in [0-9]*" done "[0-9]*) r=0 ;; *) r=1 ;; esac
assert_true "$r" "...and @roost-refused records '<epoch> done <pid>' [$ref]"

# A Stop from outside writes NOTHING, not even above the unchanged-state bail:
# the reply and the hold record are the report too.
T set-option -p -t "$p1" @roost-reply "the pane's own answer"
bg4="$(opt "$p1" @roost-background)"
printf '%s' '{"last_assistant_message":"A STRANGER WROTE THIS","background_tasks":[{"type":"shell","status":"running"}]}' \
  | out "$p1" done --stop-hook
assert_eq "$(opt "$p1" @roost-reply)" "the pane's own answer" "outside: a refused Stop records no reply"
assert_eq "$(opt "$p1" @roost-background)" "$bg4" "...and no hold record"

# The pane reads done: a refused working or blocked UNSETS it, because an old
# ✅ must not stand while something claims work is going on (§4.3).
T set-option -p -t "$p1" @agent_state done
out "$p1" working
assert_eq "$(pstate "$p1")" "" "outside: a refused working unsets a done badge"
T set-option -p -t "$p1" @agent_state idle
out "$p1" blocked
assert_eq "$(pstate "$p1")" "" "outside: a refused blocked unsets an idle badge"
# A refused done on a done pane changes nothing (the stamp keeps its second).
T set-option -p -t "$p1" @agent_state done
T set-option -p -t "$p1" @agent_since 1000
out "$p1" idle
assert_eq "$(pstate "$p1")" "done" "outside: a refused idle leaves a done badge"
assert_eq "$(since_of "$p1")" "1000" "...and its stamp"
# An error badge stays: unsetting it would turn wait-done's exit 1 into the 0
# an unbadged pane gives, a false "finished" made from "could not tell".
T set-option -p -t "$p1" @agent_state error
out "$p1" working
assert_eq "$(pstate "$p1")" "error" "outside: a refused working leaves an error badge"
# A pane with no badge has nothing to unset or keep.
T set-option -pu -t "$p1" @agent_state
out "$p1" working
assert_eq "$(pstate "$p1")" "" "outside: a refused working on an unbadged pane leaves it unbadged"

# state --json says why, and says nothing landed.
T set-option -p -t "$p1" @agent_state done
sj="$(out_roost "$p1" state working --json)"
assert_eq "$(jfield "$sj" recorded)" "false" "state --json from outside: recorded is false"
assert_eq "$(jfield "$sj" refused)" '"not in this pane'"'"'s process tree"' "state --json from outside: refused says why"
assert_eq "$(jfield "$sj" verified)" "null" "state --json from outside: verified is null (nothing was accepted)"
assert_eq "$(jfield "$sj" state)" "null" "state --json from outside: no state landed"
# Even when the badge already reads what was asked: the report itself was not
# accepted, and `recorded` must not read a coincidence as a write.
T set-option -p -t "$p1" @agent_state working
sj="$(out_roost "$p1" state working --json)"
assert_eq "$(jfield "$sj" recorded)" "false" "state --json from outside: recorded is false even when the badge matches"

st="$("$ROOST" status --json)"
rf="$(jfield "$st" refused "$p1")"
case "$rf" in [1-9]*) r=0 ;; *) r=1 ;; esac
assert_true "$r" "status --json: refused is the refusal's epoch [$rf]"

# --- 3. the walk cannot run: accepted, unverified ----------------------------------
# `ps` that fails, first on PATH. The walk needs it from the first level up
# (this shell is not the pane), so it cannot reach a verdict.
mkdir -p "$work/noprs"
printf '#!/bin/sh\nexit 1\n' > "$work/noprs/ps"; chmod +x "$work/noprs/ps"
pu="$(T new-window -d -P -F '#{pane_id}' 'exec sleep 600')"
require_pane "$pu" unverified
T set-option -p -t "$pu" @agent_state done
env PATH="$work/noprs:$PATH" TMUX="$s,$spid,0" TMUX_PANE="$pu" "$SINK" working
assert_eq "$(pstate "$pu")" "working" "ps fails: the report is accepted (Q4)"
assert_eq "$(opt "$pu" @roost-verified)" "$(since_of "$pu") 0" "...and marked unverified, tied to its stamp"
assert_eq "$(opt "$pu" @roost-refused)" "" "...and not refused"
st="$("$ROOST" status --json)"
assert_eq "$(jfield "$st" verified "$pu")" "false" "status --json: verified is false for it"
sj="$(env PATH="$work/noprs:$PATH" TMUX="$s,$spid,0" TMUX_PANE="$pu" "$ROOST" state blocked --json)"
assert_eq "$(jfield "$sj" verified)" "false" "state --json: verified is false when the walk cannot run"
assert_eq "$(jfield "$sj" recorded)" "true" "state --json: ...and the badge is recorded"
assert_eq "$(jfield "$sj" refused)" "null" "state --json: ...and nothing is refused"
# A verified stamp later retires the mark: it belongs to the stamp.
T set-option -p -t "$pu" @agent_since 1
st="$("$ROOST" status --json)"
assert_eq "$(jfield "$st" verified "$pu")" "null" "status --json: a mark from another stamp reads null"
T set-option -p -t "$pu" @agent_since "$(opt "$pu" @roost-verified | cut -d' ' -f1)"

# The suite's own switch is the same "unknown", never a silent pass.
pk="$(T new-window -d -P -F '#{pane_id}' 'exec sleep 600')"
require_pane "$pk" switch
env ROOST_TEST_SKIP_ANCESTRY=1 TMUX="$s,$spid,0" TMUX_PANE="$pk" "$SINK" working
assert_eq "$(pstate "$pk")" "working" "ROOST_TEST_SKIP_ANCESTRY: the report is accepted"
assert_eq "$(opt "$pk" @roost-verified)" "$(since_of "$pk") 0" "...and marked unverified, never verified"

# --- doctor names both ----------------------------------------------------------------
# Every home doctor can be steered by goes under one throwaway directory, as
# tests/test-doctor.sh's run_doctor pins them, and an opencode stub stands in
# for a real one: doctor asks the opencode on PATH for its version.
dh="$work/home"; mkdir -p "$dh" "$work/ocstub"
printf '#!/bin/sh\necho "1.18.30"\n' > "$work/ocstub/opencode"; chmod +x "$work/ocstub/opencode"
doc="$(cd "$work" && env -u TMUX -u TMUX_PANE HOME="$dh" XDG_CONFIG_HOME="$dh/.config" XDG_DATA_HOME="$dh/.local/share" \
  XDG_STATE_HOME="$dh/.local/state" COPILOT_HOME="$dh/.copilot" PI_CODING_AGENT_DIR="$dh/.pi/agent" \
  CODEX_HOME="$dh/.codex" CLAUDE_SETTINGS="$dh/.claude/settings.json" ZDOTDIR="$dh" \
  ROOST_CONFIG_SOCK="$s" ROOST_NOTIFY_SOCK=/nonexistent/sock PATH="$work/ocstub:$PATH" "$DOC" 2>&1)"
assert_contains "$doc" "$p1" "doctor names the pane that refused a report"
assert_contains "$doc" "not in its process tree" "...and says why"
assert_contains "$doc" "$pu" "doctor names the pane whose report is unverified"
assert_contains "$doc" "could not be checked" "...and says it could not be checked"
case "$doc" in *"$p "*) r=1 ;; *) r=0 ;; esac
assert_true "$r" "doctor does not name a pane whose reports were all verified"
assert_eq "$(find "$dh" -mindepth 1 2>/dev/null | head -1)" "" "doctor wrote nothing under its home"

# --- 4. the hot path does not walk -------------------------------------------------------
# An unchanged state bails before the filter: a stranger's repeat changes
# nothing anyway (§4.2, cost row), and PostToolUse pays no `ps`.
mkdir -p "$work/logps"
# The shim must exec the REAL ps, never itself.
realps="$(command -v ps)"
printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$work/ps.log" "$realps" > "$work/logps/ps"; chmod +x "$work/logps/ps"
T set-option -p -t "$pu" @agent_state working
: > "$work/ps.log"
env PATH="$work/logps:$PATH" TMUX="$s,$spid,0" TMUX_PANE="$pu" "$SINK" working --tool-hook </dev/null
assert_eq "$(wc -l < "$work/ps.log" | tr -d ' ')" "0" "an unchanged state runs no ps (the hot path)"
assert_eq "$(opt "$pu" @roost-refused)" "" "...and records no refusal"
# The control: the same shim does see the walk on a transition.
T set-option -p -t "$pu" @agent_state done
env PATH="$work/logps:$PATH" TMUX="$s,$spid,0" TMUX_PANE="$pu" "$SINK" working --tool-hook </dev/null
n="$(wc -l < "$work/ps.log" | tr -d ' ')"
[ "$n" -ge 1 ]; assert_true $? "control: a transition does run the walk's ps ($n calls)"

# --- 5. SessionEnd from outside does not release a held pane ------------------------
ph="$(T new-window -d -P -F '#{pane_id}' 'exec sleep 600')"
require_pane "$ph" held
hold() { # PANE -- held at working by one task, owned by session sid-1
  T set-option -p -t "$1" @agent_state working \; set-option -p -t "$1" @agent_since 2000 \; \
    set-option -p -t "$1" @roost-background "2000 1" \; set-option -p -t "$1" @roost-background-session "2000 sid-1"
}
hold "$ph"
printf '%s' '{"session_id":"sid-1","reason":"other"}' | out "$ph" --session-end-hook
assert_eq "$(pstate "$ph")" "working" "outside: a SessionEnd does not release a held pane"
assert_eq "$(opt "$ph" @roost-ended)" "" "...and records no outcome"
ref="$(opt "$ph" @roost-refused)"
case "$ref" in [0-9]*" died "[0-9]*) r=0 ;; *) r=1 ;; esac
assert_true "$r" "...and @roost-refused records it [$ref]"
# The control: the same payload through the suite's switch does release it, so
# the refusal above is the filter's and not a payload the block ignored.
printf '%s' '{"session_id":"sid-1","reason":"other"}' \
  | env ROOST_TEST_SKIP_ANCESTRY=1 TMUX="$s,$spid,0" TMUX_PANE="$ph" "$SINK" --session-end-hook
assert_eq "$(pstate "$ph")" "" "control: the same SessionEnd, unchecked, releases the pane"
assert_eq "$(opt "$ph" @roost-ended)" "2000 died" "control: ...as died"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
