#!/usr/bin/env bash
# `roost revive` (#57, #191 Part 2): bring one pane's conversation back.
# Design: docs/airig/specs/2026-10-24-persistent-sessions-design.md §4.1 (the
# verb), §2.8 (the resume table), §5.1 (which directory), §5.1a (the store
# check before anything is killed). Plan: Tasks 2.4–2.7.
#
# The library cases source scripts/lib/roost-resume.sh directly. The verb's
# cases drive bin/roost against this file's own named server (tests/lib-shape.sh
# says why it is `-L roost` under a guarded TMUX_TMPDIR) with stub harnesses.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
LIVEPID=""
shape_test_setup; trap '[ -n "$LIVEPID" ] && kill "$LIVEPID" 2>/dev/null; shape_test_teardown' EXIT

# The stub stores. lib-shape.sh points the harness homes at the canary, which
# nothing may write to; a revive test READS a store, so each harness gets a
# temp home of its own here, and the canary still guards CLAUDE_SETTINGS and
# the XDG pair. CLAUDE_CONFIG_DIR is already a temp dir (stub_store_add).
export CODEX_HOME="$SHAPE_TMP/h-codex"
export COPILOT_HOME="$SHAPE_TMP/h-copilot"
export PI_CODING_AGENT_DIR="$SHAPE_TMP/h-pi/agent"
mkdir -p "$CODEX_HOME" "$COPILOT_HOME" "$PI_CODING_AGENT_DIR"

. scripts/lib/roost-resume.sh

U1=3fa3c0de-1111-4abc-8def-000000000001
U2=3fa3c0de-2222-4abc-8def-000000000002
U3=3fa3c0de-3333-4abc-8def-000000000003
CX=019a0f0f-6a8b-7c71-9d2e-0000000000c1
CP=6b1e2f30-4c5d-4e6f-8a9b-0000000000c2
PI=019a0f0f-6a8b-7c71-9d2e-0000000000f1
# Every directory dotted, the shape of every roost worktree (§2.1).
WT="$SHAPE_TMP/work/repo/.claude/worktrees/w1"
mkdir -p "$WT"

lines() { tr '\n' ' ' | sed 's/ $//'; }

echo "== roost_resume_command: the resume table (§2.8) =="
got="$(roost_resume_command claude "$U1" "" | lines)"; rc=$?
assert_eq "$got" "claude --resume $U1" "claude: claude --resume ID"
got="$(roost_resume_command claude "$U1" "")"
assert_eq "$(printf '%s\n' "$got" | wc -l | tr -d ' ')" "3" "...printed one word per line (an argv, never a string)"
assert_eq "$(roost_resume_command codex "$CX" "" | lines)" "codex resume $CX" "codex: codex resume ID"
assert_eq "$(roost_resume_command copilot "$CP" "" | lines)" "copilot --resume=$CP" "copilot: copilot --resume=ID, one word"
assert_eq "$(roost_resume_command pi "$PI" "/p/s/2026_$PI.jsonl" | lines)" "pi --session /p/s/2026_$PI.jsonl" "pi with a session file: pi --session PATH"
assert_eq "$(roost_resume_command pi "$PI" "" | lines)" "pi --session $PI" "pi with no session file: pi --session ID"
got="$(roost_resume_command opencode ses_abc123 "")"; rc=$?
assert_eq "$rc|$(printf '%s' "$got" | lines)" "3|opencode -s ses_abc123" "opencode: returns 3, the command printed, not to be run"
roost_resume_command claude "not-a-uuid" "" >/dev/null; rc=$?
assert_eq "$rc" "1" "a claude id that is not a UUID is refused"
roost_resume_command claude "${U1%?}*" "" >/dev/null; rc=$?
assert_eq "$rc" "1" "an id holding a glob character is refused"
roost_resume_command codex "rollout-2026-$CX" "" >/dev/null; rc=$?
assert_eq "$rc" "1" "codex: a rollout file name is not its uuid, refused"
roost_resume_command copilot "../$CP" "" >/dev/null; rc=$?
assert_eq "$rc" "1" "copilot: a path-shaped id is refused"
roost_resume_command pi "$PI-x" "" >/dev/null; rc=$?
assert_eq "$rc" "1" "pi: a long id is refused"
roost_resume_command opencode "-s" "" >/dev/null; rc=$?
assert_eq "$rc" "1" "opencode: an id starting with - is refused"
roost_resume_command vim "$U1" "" >/dev/null; rc=$?
assert_eq "$rc|$ROOST_RESUME_WHY" "1|no resume command for harness 'vim'" "a harness with no row is refused, by name"

echo "== roost_resume_dir: the directory rule (§5.1) =="
T="$SHAPE_TMP/t"; mkdir -p "$T"
printf '{"type":"summary"}\n{"type":"user","cwd":"%s","x":1}\n{"cwd":"/elsewhere"}\n' "$WT" > "$T/one.jsonl"
assert_eq "$(roost_resume_dir claude "$T/one.jsonl" /scwd /pcwd)" "$WT" "claude: the transcript's first cwd, a dotted path"
assert_eq "$(roost_resume_dir claude "$T/one.jsonl" "" "")" "$WT" "...whatever session_cwd and cwd say (not required to equal either)"
printf '{"cwd":"/first/one","parent":{"cwd":"/second/one"}}\n' > "$T/two.jsonl"
assert_eq "$(roost_resume_dir claude "$T/two.jsonl" "" "")" "/first/one" "claude: the first of two cwd values on one line"
printf '{"cwd":"/a\\\\b"}\n' > "$T/bs.jsonl"
roost_resume_dir claude "$T/bs.jsonl" /scwd /pcwd >/dev/null; rc=$?
assert_eq "$rc" "1" "claude: a cwd holding a backslash (a JSON escape) is refused, not decoded"
printf '{"cwd":"/a\\"q"}\n' > "$T/q.jsonl"
roost_resume_dir claude "$T/q.jsonl" /scwd /pcwd >/dev/null; rc=$?
assert_eq "$rc" "1" "claude: an escaped quote is refused too"
printf '{"type":"user"}\n' > "$T/none.jsonl"
roost_resume_dir claude "$T/none.jsonl" /scwd /pcwd >/dev/null; rc=$?
assert_eq "$rc" "1" "claude: a transcript with no cwd line is refused (no fallback to session_cwd)"
roost_resume_dir claude "" /scwd /pcwd >/dev/null; rc=$?
assert_eq "$rc" "1" "claude: no transcript is refused (no fallback)"
roost_resume_dir claude "$T/missing.jsonl" /scwd /pcwd >/dev/null; rc=$?
assert_eq "$rc" "1" "claude: a transcript that does not exist is refused"
printf '{"cwd":"rel/dir"}\n' > "$T/rel.jsonl"
roost_resume_dir claude "$T/rel.jsonl" /scwd /pcwd >/dev/null; rc=$?
assert_eq "$rc" "1" "claude: a relative cwd is refused"
assert_eq "$(roost_resume_dir pi "/p/t.jsonl" /scwd /pcwd)" "/scwd" "pi: session_cwd"
assert_eq "$(roost_resume_dir pi "/p/t.jsonl" "" /pcwd)" "/pcwd" "pi: else cwd"
for h in codex copilot opencode; do
  assert_eq "$(roost_resume_dir "$h" "" /scwd /pcwd)" "/scwd" "$h: session_cwd"
  assert_eq "$(roost_resume_dir "$h" "" "" /pcwd)" "/pcwd" "$h: else cwd"
done
roost_resume_dir codex "" "" "" >/dev/null; rc=$?
assert_eq "$rc" "1" "codex: neither directory: refused"

echo "== roost_resume_store_check and the exact-id lookup (§5.1a, §2.8) =="
# Claude: the folder is the measured rule (every byte not a letter or digit,
# `/` and `.` among them, as `-`: Probe 6.1), dotted path, built by
# stub_store_folder — a `_` in the runner's temp directory is `-` too.
stub_store_add "$U1" "$WT"
f1="$CLAUDE_CONFIG_DIR/projects/$(stub_store_folder "$WT")/$U1.jsonl"
[ -f "$f1" ]; assert_true $? "(fixture) the stub store has $U1 in a dotted-path folder"
roost_resume_store_check claude "$U1" ""; rc=$?
assert_eq "$rc|$ROOST_RESUME_FILE" "0|$f1" "claude, no recorded file: exactly one projects/*/<id>.jsonl is found"
assert_eq "$(roost_resume_exact_id claude "$U1")" "$f1" "roost_resume_exact_id returns that one file"
roost_resume_store_check claude "$U1" "$T/one.jsonl"; rc=$?
assert_eq "$rc|$ROOST_RESUME_FILE" "0|$T/one.jsonl" "claude: a recorded transcript that exists is used, not searched for"
roost_resume_store_check claude "$U2" "$T/one.jsonl"; rc=$?
assert_eq "$rc" "0" "...even when the store has no file under the id (the record names it)"
roost_resume_store_check claude "$U2" ""; rc=$?
assert_eq "$rc" "1" "claude: no recorded file and none in the store: a miss"
roost_resume_store_check claude "$U2" "$T/gone.jsonl"; rc=$?
assert_eq "$rc" "1" "claude: a recorded file that is gone, none in the store: a miss"
stub_store_add "$U3" "/one/place"; stub_store_add "$U3" "/other/place"
roost_resume_store_check claude "$U3" ""; rc=$?
assert_eq "$rc" "1" "claude: two files carrying one id: a miss, never a guess"
roost_resume_exact_id claude "$U3" >/dev/null; rc=$?
assert_eq "$rc" "1" "roost_resume_exact_id refuses two"
roost_resume_exact_id claude "$U2" >/dev/null; rc=$?
assert_eq "$rc" "1" "roost_resume_exact_id refuses none"
roost_resume_store_check claude "not-a-uuid" ""; rc=$?
assert_eq "$rc" "1" "claude: a malformed id is a miss (never globbed)"

# codex: the rollout is dated three folders deep.
mkdir -p "$CODEX_HOME/sessions/2026/10/31"
: > "$CODEX_HOME/sessions/2026/10/31/rollout-2026-10-31T08-00-00-$CX.jsonl"
roost_resume_store_check codex "$CX" ""; rc=$?
assert_eq "$rc|$ROOST_RESUME_FILE" "0|$CODEX_HOME/sessions/2026/10/31/rollout-2026-10-31T08-00-00-$CX.jsonl" "codex: the rollout is found under sessions/**/ by find"
roost_resume_store_check codex "${CX%?}9" ""; rc=$?
assert_eq "$rc" "1" "codex: another id: a miss"
mkdir -p "$CODEX_HOME/sessions/2026/11/01"
: > "$CODEX_HOME/sessions/2026/11/01/rollout-2026-11-01T08-00-00-$CX.jsonl"
roost_resume_store_check codex "$CX" ""; rc=$?
assert_eq "$rc" "1" "codex: two rollouts carrying one id: a miss"

# copilot: a directory per session.
mkdir -p "$COPILOT_HOME/session-state/$CP"
roost_resume_store_check copilot "$CP" ""; rc=$?
assert_eq "$rc" "0" "copilot: session-state/<id>/ exists"
roost_resume_store_check copilot "${CP%?}9" ""; rc=$?
assert_eq "$rc" "1" "copilot: another id: a miss"
: > "$COPILOT_HOME/session-state/${CP%?}8"
roost_resume_store_check copilot "${CP%?}8" ""; rc=$?
assert_eq "$rc" "1" "copilot: a FILE of that name is not a session: a miss"

# pi: <timestamp>_<id>.jsonl under a folder per directory.
pf="$PI_CODING_AGENT_DIR/sessions/--work--repo--/2026-10-31T08-00-00-000Z_$PI.jsonl"
mkdir -p "${pf%/*}"; : > "$pf"
roost_resume_store_check pi "$PI" ""; rc=$?
assert_eq "$rc|$ROOST_RESUME_FILE" "0|$pf" "pi, no recorded file: exactly one sessions/*/*_<id>.jsonl"
assert_eq "$(roost_resume_exact_id pi "$PI")" "$pf" "roost_resume_exact_id finds pi's file"
roost_resume_store_check pi "$PI" "$T/one.jsonl"; rc=$?
assert_eq "$rc|$ROOST_RESUME_FILE" "0|$T/one.jsonl" "pi: the recorded file is used when it exists"
pf2="$PI_CODING_AGENT_DIR/sessions/--other--/2026-10-31T09-00-00-000Z_$PI.jsonl"
mkdir -p "${pf2%/*}"; : > "$pf2"
roost_resume_store_check pi "$PI" ""; rc=$?
assert_eq "$rc" "1" "pi: two files carrying one id: a miss"

# A home holding a space, or a `[` (a glob character), is a path like any
# other: only the pattern part is globbed (review round 1, Codex B6).
for odd in "claude home" "cl[aude] home"; do
  CH="$SHAPE_TMP/$odd"
  mkdir -p "$CH/projects/-p"; : > "$CH/projects/-p/$U1.jsonl"
  got="$(CLAUDE_CONFIG_DIR="$CH" roost_resume_exact_id claude "$U1")"; rc=$?
  assert_eq "$rc|$got" "0|$CH/projects/-p/$U1.jsonl" "claude exact-id lookup in a home named '$odd'"
  PH="$SHAPE_TMP/pi $odd"
  mkdir -p "$PH/sessions/--p--"; : > "$PH/sessions/--p--/2026-10-31T08-00-00-000Z_$PI.jsonl"
  got="$(PI_CODING_AGENT_DIR="$PH" roost_resume_exact_id pi "$PI")"; rc=$?
  assert_eq "$rc|$got" "0|$PH/sessions/--p--/2026-10-31T08-00-00-000Z_$PI.jsonl" "pi exact-id lookup in a home named 'pi $odd'"
done

roost_resume_store_check opencode ses_abc ""; rc=$?
assert_eq "$rc" "3" "opencode: not checked (returns 3)"

echo "== claims: one per conversation, released only by its taker (§4.1 step 5a) =="
. scripts/lib/roost-shape.sh
ROOST_RESUME_TFLAG=-S ROOST_RESUME_TSOCK="$SHAPE_SOCK"
export ROOST_RESUME_TFLAG ROOST_RESUME_TSOCK
CL="$SHAPE_TMP/claims/boot-1"
# Two live panes on the test server, and one that is gone.
PA="$(TL new-window -d -P -F '#{pane_id}' -t shp: 'exec sleep 600')"
PB="$(TL new-window -d -P -F '#{pane_id}' -t shp: 'exec sleep 600')"
PG="$(TL new-window -d -P -F '#{pane_id}' -t shp: 'exec sleep 600')"; TL kill-pane -t "$PG"
# A dead claimer: a process that has exited, so its pid is not running with
# its recorded start time. A live one: a sleep of this file's own.
sleep 0.1 >/dev/null 2>&1 & DEADPID=$!; DEADLST="$(roost_shape__lstart "$DEADPID")"; wait "$DEADPID" 2>/dev/null
# Its fds go to /dev/null, and the EXIT trap kills it: a background sleep
# holding this file's stdout keeps a `| grep` reader waiting for 600 s.
sleep 600 >/dev/null 2>&1 & LIVEPID=$!; LIVELST="$(roost_shape__lstart "$LIVEPID")"
plant() { # ID PID LSTART PANE — a claim another launcher left
  mkdir -p "$CL/claude-$1"; ln -s "$2 $3" "$CL/claude-$1/owner"; printf '%s\n%s\n' "$4" "$2 $3" > "$CL/claude-$1/pane"
}
snap() { (cd "$CL/claude-$1" 2>/dev/null && for f in owner pane; do printf '%s=' "$f"; if [ -L "$f" ]; then readlink "$f"; else cat "$f" 2>/dev/null; fi; done); }
ME="$$ $(roost_shape__lstart "$$")"

roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc|$ROOST_RESUME_CLAIM" "0|$CL/claude-$U1" "a free conversation is claimed: claims/<boot>/<harness>-<id>"
assert_eq "$(readlink "$CL/claude-$U1/owner")" "$ME" "...its owner record is this run's pid and start time"
assert_eq "$(head -n 1 "$CL/claude-$U1/pane")" "$PA" "...and it names the target pane"
roost_resume_claim "$CL" claude "$U2" ""; rc=$?
assert_eq "$rc|$(head -n 1 "$CL/claude-$U2/pane" 2>/dev/null)" "0|" "a claim may name no pane yet (empty until the launcher knows it)"
roost_resume_claim_pane "$CL/claude-$U2" "$PB"
assert_eq "$(head -n 1 "$CL/claude-$U2/pane")" "$PB" "roost_resume_claim_pane fills it in once the pane exists"
rm -rf "$CL"

plant "$U1" "$DEADPID" "$DEADLST" "$PB"; before="$(snap "$U1")"
roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc|$ROOST_RESUME_HOLDER" "1|$PB" "another EXISTING pane, a DEAD claimer: refused, naming the pane"
assert_eq "$(snap "$U1")" "$before" "...and the refused claim is left byte for byte"
rm -rf "$CL"
plant "$U1" "$LIVEPID" "$LIVELST" "$PB"
roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc|$ROOST_RESUME_HOLDER" "1|$PB" "another existing pane, a live claimer: refused"
rm -rf "$CL"
plant "$U1" "$LIVEPID" "$LIVELST" "$PA"
roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc|$(readlink "$CL/claude-$U1/owner")" "0|$ME" "the SAME pane as this claim: taken over (an in-place revive whose launch never identified)"
rm -rf "$CL"
plant "$U1" "$LIVEPID" "$LIVELST" "$PG"
roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc|$(readlink "$CL/claude-$U1/owner")|$(head -n 1 "$CL/claude-$U1/pane")" "0|$ME|$PA" "a GONE pane with a LIVE claimer: stale, taken over"
rm -rf "$CL"
plant "$U1" "$DEADPID" "$DEADLST" ""
roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc|$(readlink "$CL/claude-$U1/owner")" "0|$ME" "no pane and a DEAD claimer: taken over"
rm -rf "$CL"
plant "$U1" "$LIVEPID" "$LIVELST" ""; before="$(snap "$U1")"
roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc|$ROOST_RESUME_HOLDER" "1|pid $LIVEPID" "no pane and a LIVE claimer: refused, naming the claimer"
assert_eq "$(snap "$U1")" "$before" "...the refused claim left byte for byte"
rm -rf "$CL"
# A pane file written under ANOTHER owner record (a previous holder's
# leftover) names nothing: the live owner beside it is judged by its liveness,
# and refused — never "stale, take it over" (review round 1, B1).
mkdir -p "$CL/claude-$U1"; ln -s "$LIVEPID $LIVELST" "$CL/claude-$U1/owner"
printf '%s\n%s\n' "$PG" "$DEADPID $DEADLST" > "$CL/claude-$U1/pane"
roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc|$ROOST_RESUME_HOLDER|$(readlink "$CL/claude-$U1/owner")" "1|pid $LIVEPID|$LIVEPID $LIVELST" "a gone pane in a pane file of ANOTHER owner: not a pane — the live owner is refused, not taken over"
rm -rf "$CL"
# A reused pid: the pid runs, but not with the recorded start time.
plant "$U1" "$LIVEPID" "Thu Jan  1 00:00:00 1970" ""
roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc" "0" "no pane and the claimer's pid reused (other start time): taken over"
rm -rf "$CL"

echo "== release: only what this run took =="
plant "$U1" "$LIVEPID" "$LIVELST" "$PB"; before="$(snap "$U1")"
roost_resume_release "$CL/claude-$U1"
assert_eq "$(snap "$U1")" "$before" "a claim this run did not take is never removed"
rm -rf "$CL"
roost_resume_claim "$CL" claude "$U1" "$PA"
roost_resume_release "$CL/claude-$U1"
[ -e "$CL/claude-$U1" ] && left=yes || left=no
assert_eq "$left" "no" "a claim this run took is removed"
plant "$U1" "$LIVEPID" "$LIVELST" "$PB"; before="$(snap "$U1")"
roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
roost_resume_release "$CL/claude-$U1"
assert_eq "$rc|$(snap "$U1")" "1|$before" "a refused claim, then release: left byte for byte"
rm -rf "$CL"
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null

echo "== roost revive on a live pane, in place (§4.1, §8.1 test 6) =="
ROOST="$PWD/bin/roost"
# bin/roost from a person's shell, aimed at this file's server by name (its
# TMUX_TMPDIR makes `-L roost` this file's own socket). TMUX and TMUX_PANE are
# dropped: this file may itself run inside a roost pane.
R() { env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"
BOOT="$(TL display -p '#{start_time}-#{pid}')"
# Every claim, saving on or off (review round 2): launch-claims/<server>/claims/<boot>/.
CLB="$XDG_STATE_HOME/roost/launch-claims/roost/claims/$BOOT"
popt() { TL show-options -pqv -t "$1" "$2" 2>/dev/null; }
ppid_of() { TL display -p -t "$1" '#{pane_pid}'; }
# setid PANE HARNESS ID CWD [TRANSCRIPT] — the identity a harness's adapter
# writes at session start, set directly: these cases are about revive, not
# about identify.
setid() {
  TL set-option -p -t "$1" @roost-harness "$2" \; set-option -p -t "$1" @roost-session "$3" \
    \; set-option -p -t "$1" @roost-cwd "$4"
  [ -n "${5:-}" ] && TL set-option -p -t "$1" @roost-transcript-path "$5"
  return 0
}
four() { printf '%s|%s|%s|%s' "$(popt "$1" @roost-session)" "$(popt "$1" @roost-cwd)" "$(popt "$1" @roost-harness)" "$(popt "$1" @roost-transcript-path)"; }
# A live stub pane: the compiled stub ITSELF (named claude), so its own start
# writes nothing to the stub log and the log holds only what revive launched.
stubpane() { TL new-window -d -P -F '#{pane_id}' -t shp: -c "${2:-$SHAPE_TMP}" "$STUB_BIN/${1:-claude} 600"; }
shpane() { TL new-window -d -P -F '#{pane_id}' -t shp: -c "${1:-$SHAPE_TMP}" 'ENV= exec /bin/sh'; }
reset() { rm -rf "$XDG_STATE_HOME/roost/launch-claims"; : > "$STUB_LOG"; }
wait_log() { # PATTERN — up to 5 s for a launch line
  local i=0
  while [ "$i" -lt 50 ]; do grep -q -- "$1" "$STUB_LOG" 2>/dev/null && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
wait_cmd() { # PANE NAME — up to 5 s for the pane's foreground to be NAME
  local i=0
  while [ "$i" -lt 50 ]; do [ "$(TL display -p -t "$1" '#{pane_current_command}')" = "$2" ] && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
D1="$SHAPE_TMP/work/one"; mkdir -p "$D1"
D1R="$(cd -P "$D1" && pwd)"
U4=3fa3c0de-4444-4abc-8def-000000000004
U5=3fa3c0de-5555-4abc-8def-000000000005
stub_store_add "$U4" "$D1R"
stub_store_add "$U5" "$D1R"

# An idle agent: resumed in the transcript's own cwd, same %N.
reset
P="$(stubpane claude)"; wait_cmd "$P" claude
setid "$P" claude "$U4" /some/old/worktree; TL set-option -p -t "$P" @agent_state idle
pid0="$(ppid_of "$P")"
out="$(R revive "$P" 2>"$SHAPE_TMP/err")"; rc=$?
assert_eq "$rc|$out" "0|$P" "an idle agent pane: exit 0, and the SAME %N printed"
wait_log "claude --resume $U4"; assert_true $? "...the stub was launched with --resume <id>"
assert_eq "$(awk '{print $2}' "$STUB_LOG" | head -n 1)" "$D1R" "...in the transcript's own cwd (not @roost-cwd)"
[ "$(ppid_of "$P")" != "$pid0" ]; assert_true $? "...the pane was respawned (its process changed)"
assert_eq "$(four "$P")|$(popt "$P" @agent_state)" "||||" "...@agent_state and the identity four were cleared before it"
assert_eq "$(popt "$P" remain-on-exit)" "failed" "...remain-on-exit failed is set on the pane"
assert_contains "$(cat "$SHAPE_TMP/err")" "launched claude --resume $U4" "...one stderr line names the command"
assert_eq "$(readlink "$CLB/claude-$U4/owner" >/dev/null && head -n 1 "$CLB/claude-$U4/pane")" "$P" "...and its claim names the pane (kept: the launch succeeded)"

# working: untouched.
reset
P="$(stubpane claude)"; wait_cmd "$P" claude
setid "$P" claude "$U4" "$D1R"; TL set-option -p -t "$P" @agent_state working
pid0="$(ppid_of "$P")"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(ppid_of "$P")|$(popt "$P" @roost-session)" "1|$pid0|$U4" "a working pane: exit 1, untouched"
[ -e "$CLB/claude-$U4" ] && left=yes || left=no
assert_eq "$left" "no" "...and the claim it took is released"
TL kill-pane -t "$P"

# The badge turns working AFTER revive first read it — while it checked the
# store and took its claim. The busy check must see the pane as it is at the
# respawn, not as it was at the start (review round 1, Codex B3).
reset
P="$(stubpane claude)"; wait_cmd "$P" claude
setid "$P" claude "$U4" "$D1R"; TL set-option -p -t "$P" @agent_state idle
pid0="$(ppid_of "$P")"
HOLD="$SHAPE_TMP/hold-revive"; rm -f "$HOLD" "$HOLD".at.*
( ROOST_TEST_REVIVE_HOLD="$HOLD" R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; echo $? > "$SHAPE_TMP/h.rc" ) &
HPID=$!
i=0; while [ "$i" -lt 100 ] && ! ls "$HOLD".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
ls "$HOLD".at.* >/dev/null 2>&1; assert_true $? "(seam) revive is held after its claim"
TL set-option -p -t "$P" @agent_state working
: > "$HOLD"; wait "$HPID"
assert_eq "$(cat "$SHAPE_TMP/h.rc")|$(ppid_of "$P")|$(popt "$P" @agent_state)|$(popt "$P" @roost-session)" "1|$pid0|working|$U4" "a pane that went working after revive first read it: exit 1, untouched (badge and identity kept)"
[ -e "$CLB/claude-$U4" ] && left=yes || left=no
assert_eq "$left" "no" "...and the claim it took is released"
TL kill-pane -t "$P"

# No key.
reset
P="$(stubpane claude)"; wait_cmd "$P" claude
TL set-option -p -t "$P" @roost-harness claude
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "no session id: exit 13"
assert_contains "$(cat "$SHAPE_TMP/err")" "has no recorded conversation (harness claude, no session id)" "...says so"
P2="$(stubpane claude)"; wait_cmd "$P2" claude
R revive "$P2" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "no identity at all: exit 13"
TL kill-pane -t "$P"; TL kill-pane -t "$P2"

# The harness off PATH: a PATH holding tmux and the system tools only. The
# check is skipped, and said, if copilot is in a system directory here.
MINBIN="$SHAPE_TMP/minbin"; mkdir -p "$MINBIN"
ln -s "$(command -v tmux)" "$MINBIN/tmux"
reset
P="$(shpane)"; wait_cmd "$P" sh
setid "$P" copilot "$CP" "$D1R"
if env PATH="$MINBIN:/usr/bin:/bin" sh -c 'command -v copilot' >/dev/null 2>&1; then
  printf '  SKIP: copilot is in /usr/bin or /bin here; the off-PATH case is not checked\n'
else
  env PATH="$MINBIN:/usr/bin:/bin" ROOST_SOCKET=roost /bin/bash "$ROOST" revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
  assert_eq "$rc" "14" "the harness is not on PATH: exit 14"
  assert_contains "$(cat "$SHAPE_TMP/err")" "copilot is not on PATH" "...naming it"
fi
TL kill-pane -t "$P"

# The directory is gone.
reset
P="$(shpane)"; wait_cmd "$P" sh
setid "$P" codex "$CX" "$SHAPE_TMP/gone/dir"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "15" "the directory is gone: exit 15"
assert_contains "$(cat "$SHAPE_TMP/err")" "no longer exists; not resuming elsewhere" "...not resumed elsewhere"
TL kill-pane -t "$P"

# The store does not hold it: nothing is killed.
reset
P="$(stubpane claude)"; wait_cmd "$P" claude
setid "$P" claude "$U2" "$D1R"
pid0="$(ppid_of "$P")"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(ppid_of "$P")" "13|$pid0" "a store miss: exit 13, and the same pane_pid (nothing killed)"
assert_contains "$(cat "$SHAPE_TMP/err")" "claude no longer holds $U2; the pane is untouched" "...says the harness no longer holds it"
assert_eq "$(cat "$STUB_LOG")" "" "...and nothing was launched"
TL kill-pane -t "$P"

# A store miss for a harness whose directory does not come from its store
# (codex, copilot): the store check is the ONLY thing between this revive and
# a resume that exits 1 at once and takes the pane with it (§5.1a).
# A copilot stub first on PATH: should this check ever be skipped (a mutant
# does exactly that), the launch must reach a stub, never a real copilot.
CPB="$SHAPE_TMP/cp-bin"; mkdir -p "$CPB"
printf '#!/bin/sh\nprintf "%%s %%s %%s\\n" "$(date +%%s)" "$PWD" "copilot $*" >> "$STUB_LOG"\nexec sleep 600\n' > "$CPB/copilot"
chmod +x "$CPB/copilot"
for h in codex copilot; do
  id="${CX%?}9"; [ "$h" = copilot ] && id="${CP%?}9"
  reset
  P="$(shpane "$D1R")"; wait_cmd "$P" sh
  setid "$P" "$h" "$id" "$D1R"
  pid0="$(ppid_of "$P")"
  env PATH="$CPB:$PATH" ROOST_SOCKET=roost "$ROOST" revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
  assert_eq "$rc|$(ppid_of "$P")|$(cat "$STUB_LOG")" "13|$pid0|" "$h, an id its store does not hold: exit 13, the pane untouched, nothing launched"
  assert_contains "$(cat "$SHAPE_TMP/err")" "$h no longer holds $id" "...said as a store miss"
  TL kill-pane -t "$P"
done

# The store revive checked is the store the harness is launched with (review
# round 1, Codex B5): the harness takes its environment from the tmux server,
# which may name another home than the caller's. A codex stub that logs the
# CODEX_HOME and HOME it was given.
CXB="$SHAPE_TMP/cx-bin"; mkdir -p "$CXB"
printf '#!/bin/sh\nprintf "%%s %%s codex-home=[%%s] home=[%%s]\\n" "$(date +%%s)" "$PWD" "${CODEX_HOME-unset}" "$HOME" >> "$STUB_LOG"\nexec sleep 600\n' > "$CXB/codex"; chmod +x "$CXB/codex"
CXA="$SHAPE_TMP/cx-checked"; CXS="$SHAPE_TMP/cx-server"
mkdir -p "$CXA/sessions/2026/10/31" "$CXS/sessions"
CX3=019a0f0f-6a8b-7c71-9d2e-0000000000c3
: > "$CXA/sessions/2026/10/31/rollout-2026-10-31T09-00-00-$CX3.jsonl"
TL set-environment -g CODEX_HOME "$CXS"
reset
P="$(shpane "$D1R")"; wait_cmd "$P" sh
setid "$P" codex "$CX3" "$D1R"
env PATH="$CXB:$PATH" CODEX_HOME="$CXA" ROOST_SOCKET=roost "$ROOST" revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
wait_log "codex-home="
assert_eq "$rc|$(grep -o 'codex-home=\[[^]]*\]' "$STUB_LOG" | head -n 1)" "0|codex-home=[$CXA]" "codex: the caller's CODEX_HOME (the one checked) reaches the harness, not the server's"
TL kill-pane -t "$P"
# The caller has none: the harness must not get the server's either — it
# reads the default under HOME, which is where the check looked.
reset
mkdir -p "$HOME/.codex/sessions/2026/10/31"
: > "$HOME/.codex/sessions/2026/10/31/rollout-2026-10-31T09-00-00-$CX3.jsonl"
P="$(shpane "$D1R")"; wait_cmd "$P" sh
setid "$P" codex "$CX3" "$D1R"
env -u CODEX_HOME PATH="$CXB:$PATH" ROOST_SOCKET=roost "$ROOST" revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
wait_log "codex-home="
assert_eq "$rc|$(grep -o 'codex-home=\[[^]]*\] home=\[[^]]*\]' "$STUB_LOG" | head -n 1)" "0|codex-home=[unset] home=[$HOME]" "codex, the caller has no CODEX_HOME: the harness gets none (not the server's), and the caller's HOME"
TL kill-pane -t "$P"
TL set-environment -gu CODEX_HOME
# The rollout under the sandbox HOME stays: no later case reads a codex store
# there (CODEX_HOME is exported), and the file's sandbox is removed at exit.

# The recorded transcript was deleted (Claude's 30-day cleanup, or a person):
# the store miss, said as one, not a directory the transcript cannot name.
reset
P="$(stubpane claude)"; wait_cmd "$P" claude
setid "$P" claude "$U2" "$D1R" "$SHAPE_TMP/deleted/$U2.jsonl"
pid0="$(ppid_of "$P")"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(ppid_of "$P")" "13|$pid0" "a recorded transcript that was deleted, none in the store: exit 13, untouched"
assert_contains "$(cat "$SHAPE_TMP/err")" "claude no longer holds $U2" "...said as the store miss it is"
TL kill-pane -t "$P"
# ...and when the store still has the id under another folder, that file is used.
reset
P="$(stubpane claude)"; wait_cmd "$P" claude
setid "$P" claude "$U4" "$D1R" "$SHAPE_TMP/deleted/$U4.jsonl"
out="$(R revive "$P" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "0|$P" "a recorded transcript gone, but the store holds the id: the exact-id lookup finds it (exit 0)"
wait_log "claude --resume $U4"; assert_eq "$(awk '{print $2}' "$STUB_LOG" | head -n 1)" "$D1R" "...resumed in the found transcript's cwd"
TL kill-pane -t "$P"

# Another live pane carries the id.
reset
P="$(stubpane claude)"; wait_cmd "$P" claude; setid "$P" claude "$U5" "$D1R"
Q="$(stubpane claude)"; wait_cmd "$Q" claude; setid "$Q" claude "$U5" "$D1R"
pid0="$(ppid_of "$P")"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(ppid_of "$P")" "13|$pid0" "an id another live pane carries: exit 13, untouched"
assert_contains "$(cat "$SHAPE_TMP/err")" "is open in $Q" "...naming that pane"
TL kill-pane -t "$P"; TL kill-pane -t "$Q"

# A resume that exits non-zero at once leaves a dead pane, not a hole.
reset
X1="$SHAPE_TMP/exit1-bin"; mkdir -p "$X1"; cp "$STUB_WRAP/claude-exit1" "$X1/claude"
W="$(TL new-window -d -P -F '#{window_id}' -t shp: "$STUB_BIN/claude 600")"
P="$(TL display -p -t "$W" '#{pane_id}')"
TL split-window -d -t "$P" "$STUB_BIN/claude 600"
wait_cmd "$P" claude; setid "$P" claude "$U4" "$D1R"
env PATH="$X1:$PATH" ROOST_SOCKET=roost "$ROOST" revive "$P" >/dev/null 2>&1; rc=$?
i=0; while [ "$i" -lt 50 ] && [ "$(TL display -p -t "$P" '#{pane_dead}')" != 1 ]; do sleep 0.1; i=$((i+1)); done
assert_eq "$rc|$(TL display -p -t "$P" '#{pane_dead}')|$(TL display -p -t "$W" '#{window_panes}')" "0|1|2" "a resume that exits 1 at once: exit 0 (launched), the pane dead, the window still 2 panes"
TL kill-window -t "$W"

echo "== exited: the agent left, its identity stayed (#57's everyday case) =="
reset
P="$(shpane "$D1R")"; wait_cmd "$P" sh
setid "$P" claude "$U4" "$D1R"
out="$(R revive "$P" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "0|$P" "a shell pane with the identity still on it: exit 0, the same %N"
wait_log "claude --resume $U4"; assert_true $? "...and the conversation launched"
TL kill-pane -t "$P"
reset
P="$(shpane "$D1R")"; wait_cmd "$P" sh
setid "$P" claude "$U4" "$D1R"
TL send-keys -t "$P" 'sleep 60' Enter; wait_cmd "$P" sleep
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(TL display -p -t "$P" '#{pane_current_command}')" "1|sleep" "a shell running a job (sleep 60): exit 1, the sleep alive"
assert_contains "$(cat "$SHAPE_TMP/err")" "person's work" "...says it is a person's work"
assert_eq "$(cat "$STUB_LOG")" "" "...nothing launched"
# One agreement table for save and revive (Part 3's header, from Part 2's
# review round 1, Fable N3): the same pane, saved now, is `exited` too —
# never `other`, which a restore would refuse while revive resumes it.
assert_eq "$(roost_shape_agree_pane claude sleep "$(ppid_of "$P")")" "exited" \
  "roost_shape_agree_pane: a shell pane whose foreground is sleep is exited"
assert_eq "$(roost_shape_agree_pane claude sleep "")" "other" \
  "...and with no pane process to ask, the table alone: other"
R save >/dev/null 2>&1
sv="$(awk -v RS= -v want="id $P" '{ s = $0 "\n"; if (index(s, "\n" want "\n")) print }' "$SD/shape")"
assert_eq "$(printf '%s\n' "$sv" | sed -n 's/^stale_reason //p')" "exited" \
  "save calls the same pane exited, as revive does (one agreement table)"
out="$(R revive --force "$P" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "0|$P" "--force then launches"
wait_log "claude --resume $U4"; assert_true $? "...the conversation, in that pane"
TL kill-pane -t "$P"

# The same for a harness the agreement table admits on presence alone (pi
# reads `node`, so the table says `ok` for anything): the shell is the pane's
# own process and its job is a person's (review round 1, Codex B2).
reset
PI2=019a0f0f-6a8b-7c71-9d2e-0000000000f2
pf3="$PI_CODING_AGENT_DIR/sessions/--work--three--/2026-10-31T10-00-00-000Z_$PI2.jsonl"
mkdir -p "${pf3%/*}"; : > "$pf3"
PIB="$SHAPE_TMP/pi-bin"; mkdir -p "$PIB"
printf '#!/bin/sh\nprintf "%%s %%s %%s\\n" "$(date +%%s)" "$PWD" "pi $*" >> "$STUB_LOG"\nexec sleep 600\n' > "$PIB/pi"; chmod +x "$PIB/pi"
P="$(shpane "$D1R")"; wait_cmd "$P" sh
setid "$P" pi "$PI2" "$D1R" "$pf3"
TL send-keys -t "$P" 'sleep 600' Enter; wait_cmd "$P" sleep
pid0="$(ppid_of "$P")"
env PATH="$PIB:$PATH" PI_CODING_AGENT_DIR="$PI_CODING_AGENT_DIR" ROOST_SOCKET=roost "$ROOST" revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(ppid_of "$P")|$(TL display -p -t "$P" '#{pane_current_command}')|$(cat "$STUB_LOG")" "1|$pid0|sleep|" "a pi identity on a shell running a job (sleep 600): exit 1, the shell and its job untouched, nothing launched"
TL kill-pane -t "$P"

echo "== nested and other: a key the pane is not running =="
reset
P="$(stubpane claude)"; wait_cmd "$P" claude
setid "$P" codex "$CX" "$D1R"
pid0="$(ppid_of "$P")"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(ppid_of "$P")" "13|$pid0" "nested (a claude pane carrying a codex key): exit 13, untouched"
assert_contains "$(cat "$SHAPE_TMP/err")" "is stale" "...the key printed as stale"
TL kill-pane -t "$P"
P="$(TL new-window -d -P -F '#{pane_id}' -t shp: 'exec sleep 600')"; wait_cmd "$P" sleep
setid "$P" claude "$U4" "$D1R"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(TL display -p -t "$P" '#{pane_current_command}')" "13|sleep" "other (sleep in the foreground, identity set): exit 13, untouched"
TL kill-pane -t "$P"

echo "== a refused revive releases only its own claim =="
reset
U6=3fa3c0de-6666-4abc-8def-000000000006
stub_store_add "$U6" "$D1R"
Q="$(shpane)"; wait_cmd "$Q" sh
sleep 600 >/dev/null 2>&1 & LIVEPID=$!; LIVELST="$(roost_shape__lstart "$LIVEPID")"
mkdir -p "$CLB/claude-$U6"; ln -s "$LIVEPID $LIVELST" "$CLB/claude-$U6/owner"
printf '%s\n%s\n' "$Q" "$LIVEPID $LIVELST" > "$CLB/claude-$U6/pane"
cl_before="$(readlink "$CLB/claude-$U6/owner")|$(head -n 1 "$CLB/claude-$U6/pane")"
P="$(stubpane claude)"; wait_cmd "$P" claude; setid "$P" claude "$U6" "$D1R"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "a live claim for $Q: a second pane carrying the key is refused (exit 13)"
assert_contains "$(cat "$SHAPE_TMP/err")" "already being launched in $Q" "...naming the claim's pane"
assert_eq "$(readlink "$CLB/claude-$U6/owner")|$(head -n 1 "$CLB/claude-$U6/pane")" "$cl_before" "...and the claim is left byte for byte"
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null; LIVEPID=""
TL kill-pane -t "$P"; TL kill-pane -t "$Q"

echo "== --json, a window target, a wired server, opencode =="
reset
P="$(stubpane claude)"; wait_cmd "$P" claude; setid "$P" claude "$U4" "$D1R"
out="$(R revive --json "$P" 2>/dev/null)"; rc=$?
got="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("|".join(str(d[k]) for k in ("pane","was","harness","session_id","command","cwd")))' 2>&1)"
assert_eq "$rc|$got" "0|$P|$P|claude|$U4|claude --resume $U4|$D1R" "--json: {pane, was, harness, session_id, command, cwd}"
reset
W="$(TL display -p -t "$P" '#{window_id}')"; setid "$P" claude "$U4" "$D1R"
out="$(R revive "$W" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "0|$P" "a window target with one pane revives that pane"
TL split-window -d -t "$P" 'exec sleep 600'
R revive "$W" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "a window of two panes is refused (pass the %N)"
TL kill-window -t "$W"
reset
TL set-option -g @roost-wiring-active on
P="$(stubpane claude)"; wait_cmd "$P" claude; setid "$P" claude "$U4" "$D1R"
R revive "$P" >/dev/null 2>&1
wait_log "claude --resume $U4"
assert_contains "$(TL display -p -t "$P" '#{pane_start_command}')" "scripts/roost-pane-shell" "on a wired server the resume goes through roost-pane-shell"
TL set-option -gu @roost-wiring-active
TL kill-pane -t "$P"
reset
P="$(shpane "$D1R")"; wait_cmd "$P" sh
setid "$P" opencode ses_abc123 "$D1R"
mkdir -p "$SHAPE_TMP/oc-bin"; printf '#!/bin/sh\nexit 0\n' > "$SHAPE_TMP/oc-bin/opencode"; chmod +x "$SHAPE_TMP/oc-bin/opencode"
pid0="$(ppid_of "$P")"
env PATH="$SHAPE_TMP/oc-bin:$PATH" ROOST_SOCKET=roost "$ROOST" revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(ppid_of "$P")" "13|$pid0" "opencode: exit 13, nothing run"
assert_contains "$(cat "$SHAPE_TMP/err")" "opencode -s ses_abc123" "...the command printed for a person"
TL kill-pane -t "$P"
R revive >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "no target: usage, exit 2"
R revive %1 %2 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "two targets: usage, exit 2"

echo "== a gone pane comes back in a new window, from its record (§4.1 step 1, step 7) =="
# Records on, for this section: tests/lib.sh turns them off for the suite.
REC="$SHAPE_TMP/records"; mkdir -p "$REC"; export ROOST_RECORD_DIR="$REC"
# gone_pane — a %N that existed on this boot and is gone now.
gone_pane() { local g; g="$(TL new-window -d -P -F '#{pane_id}' -t shp: 'exec sleep 600')"; TL kill-pane -t "$g"; printf '%s\n' "$g"; }
# plant_record %N HARNESS ID CWD [TRANSCRIPT] — the record identity writes.
plant_record() {
  local d="$REC/$BOOT/${1#%}"
  mkdir -p "$d"; printf '1\n' > "$d/schema"; printf '%s\n' "$SHAPE_SOCK" > "$d/socket"
  printf '%s\n' "$2" > "$d/harness"; printf '%s\n' "$3" > "$d/session_id"; printf '%s\n' "$4" > "$d/cwd"
  [ -n "${5:-}" ] && printf '%s\n' "$5" > "$d/transcript"
  return 0
}
nwin() { TL list-windows -a | wc -l | tr -d ' '; }
U7=3fa3c0de-7777-4abc-8def-000000000007
U8=3fa3c0de-8888-4abc-8def-000000000008

# A record with its transcript: used, and the store not searched — the store
# is moved away to prove it.
reset
TRF="$SHAPE_TMP/kept/$U8.jsonl"; mkdir -p "${TRF%/*}"
printf '{"type":"user","cwd":"%s"}\n' "$WT" > "$TRF"
G="$(gone_pane)"; plant_record "$G" claude "$U8" /old/identity/cwd "$TRF"
mv "$CLAUDE_CONFIG_DIR/projects" "$SHAPE_TMP/projects.away"
out="$(R revive "$G" 2>"$SHAPE_TMP/err")"; rc=$?
mv "$SHAPE_TMP/projects.away" "$CLAUDE_CONFIG_DIR/projects"
case "$out" in %[0-9]*) [ "$out" != "$G" ]; okn=$? ;; *) okn=1 ;; esac
assert_eq "$rc|$okn" "0|0" "a gone %N with a record: exit 0, a NEW %N printed"
assert_eq "$(popt "$out" @roost-was)" "$G" "...@roost-was names the old pane"
assert_eq "$(TL display -p -t "$out" '#{session_name}')" "shp" "...in the caller's session (no record session, no main: the first session)"
wait_log "claude --resume $U8"; assert_true $? "...the stub launched"
assert_eq "$(awk '{print $2}' "$STUB_LOG" | head -n 1)" "$WT" "...in the recorded transcript's cwd, with the store emptied (the record's transcript was used, not searched for)"
assert_contains "$(cat "$SHAPE_TMP/err")" "(was $G)" "...stderr names both panes"
TL kill-pane -t "$out"

# No transcript in the record: the exact-id lookup, one file in a dotted folder.
reset
stub_store_add "$U7" "$WT"
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
out="$(R revive "$G" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "gone, no transcript in the record, one <id>.jsonl in a dotted-path folder: exit 0"
wait_log "claude --resume $U7"; assert_eq "$(awk '{print $2}' "$STUB_LOG" | head -n 1)" "$WT" "...resumed in that transcript's cwd"
TL kill-pane -t "$out" 2>/dev/null
reset
G="$(gone_pane)"; plant_record "$G" claude "$U3" /old/cwd
n0="$(nwin)"
R revive "$G" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(nwin)|$(cat "$STUB_LOG")" "13|$n0|" "gone, two <id>.jsonl files: exit 13, no window, nothing launched"

# Two revives of one gone record; the stub never identifies.
reset
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
first="$(R revive "$G" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "two revives of one gone record: the first launches (exit 0)"
assert_eq "$(head -n 1 "$CLB/claude-$U7/pane" 2>/dev/null)" "$first" "...its claim names the new pane"
wait_log "claude --resume $U7"
n0="$(nwin)"
R revive "$G" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(nwin)" "13|$n0" "...the second is refused (exit 13), no window"
assert_contains "$(cat "$SHAPE_TMP/err")" "$first" "...naming the first pane"
assert_eq "$(grep -c "claude --resume $U7" "$STUB_LOG")" "1" "...one launch in the stub log"
TL kill-pane -t "$first"
third="$(R revive "$G" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "...the first new pane killed, a third launches (a claim naming a gone pane is stale)"
i=0; while [ "$i" -lt 50 ] && [ "$(grep -c "claude --resume $U7" "$STUB_LOG")" != 2 ]; do sleep 0.1; i=$((i+1)); done
assert_eq "$(grep -c "claude --resume $U7" "$STUB_LOG")|$(head -n 1 "$CLB/claude-$U7/pane" 2>/dev/null)" "2|$third" "...a second launch, and the claim now names the third's pane"
TL kill-pane -t "$third" 2>/dev/null

# Two launchers overlap on a STALE claim (it names a gone pane): exactly one
# may launch (review round 1, B1). Launcher A is held right after it links its
# owner record, before it writes its pane, while B runs to the end.
reset
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
G2="$(gone_pane)"
sleep 600 >/dev/null 2>&1 & LIVEPID=$!; LIVELST="$(roost_shape__lstart "$LIVEPID")"
mkdir -p "$CLB/claude-$U7"
ln -s "$LIVEPID $LIVELST" "$CLB/claude-$U7/owner"
printf '%s\n%s\n' "$G2" "$LIVEPID $LIVELST" > "$CLB/claude-$U7/pane"
HOLD="$SHAPE_TMP/hold-link"; rm -f "$HOLD" "$HOLD".at.*
( ROOST_TEST_CLAIM_HOLD_AFTER_LINK="$HOLD" R revive "$G" > "$SHAPE_TMP/a.out" 2>"$SHAPE_TMP/a.err"; echo $? > "$SHAPE_TMP/a.rc" ) &
APID=$!
i=0; while [ "$i" -lt 100 ] && ! ls "$HOLD".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
ls "$HOLD".at.* >/dev/null 2>&1; assert_true $? "(seam) launcher A is held after linking its owner record"
R revive "$G" > "$SHAPE_TMP/b.out" 2>"$SHAPE_TMP/b.err"; rcB=$?
: > "$HOLD"; wait "$APID"; rcA="$(cat "$SHAPE_TMP/a.rc")"
sleep 1
n0=0; [ "$rcA" = 0 ] && n0=$((n0+1)); [ "$rcB" = 0 ] && n0=$((n0+1))
assert_eq "$n0|$(grep -c "claude --resume $U7" "$STUB_LOG")" "1|1" "two launchers overlapping on a stale claim: exactly one exits 0, and one launch (A $rcA, B $rcB)"
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null; LIVEPID=""
for o in "$SHAPE_TMP/a.out" "$SHAPE_TMP/b.out"; do [ -s "$o" ] && TL kill-pane -t "$(cat "$o")" 2>/dev/null; done

# Three launchers of one stale claim (review round 2, Opus R2-B1): the
# first version moved the owner link aside BEFORE it knew whose link it was,
# so a third launcher in that gap found no owner, linked and launched — two
# launches. B is held after it judged the dead record stale; C runs to the
# end; then B goes on, and if it removes a link (the old code did, C's) it is
# held again while D runs to the end. Exactly one launch.
reset
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
G2="$(gone_pane)"
mkdir -p "$CLB/claude-$U7"
ln -s "999999 Thu Jan  1 00:00:00 1970" "$CLB/claude-$U7/owner"
printf '%s\n%s\n' "$G2" "999999 Thu Jan  1 00:00:00 1970" > "$CLB/claude-$U7/pane"
HS="$SHAPE_TMP/hold-stale"; HT="$SHAPE_TMP/hold-taken"; rm -f "$HS" "$HS".at.* "$HT" "$HT".at.* "$SHAPE_TMP/b.rc"
( ROOST_TEST_CLAIM_PAUSE_STALE="$HS" ROOST_TEST_CLAIM_PAUSE_TAKEN="$HT" R revive "$G" > "$SHAPE_TMP/b.out" 2>"$SHAPE_TMP/b.err"; echo $? > "$SHAPE_TMP/b.rc" ) &
BPID=$!
i=0; while [ "$i" -lt 100 ] && ! ls "$HS".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
ls "$HS".at.* >/dev/null 2>&1; assert_true $? "(seam) launcher B is held after judging the dead record stale"
R revive "$G" > "$SHAPE_TMP/c.out" 2>"$SHAPE_TMP/c.err"; rcC=$?
: > "$HS"
# B either removes a link (then it is held at the second seam) or finishes.
i=0; while [ "$i" -lt 100 ] && ! ls "$HT".at.* >/dev/null 2>&1 && [ ! -s "$SHAPE_TMP/b.rc" ]; do sleep 0.1; i=$((i+1)); done
R revive "$G" > "$SHAPE_TMP/d.out" 2>"$SHAPE_TMP/d.err"; rcD=$?
: > "$HT"; wait "$BPID"; rcB="$(cat "$SHAPE_TMP/b.rc")"
sleep 1
n0=0; for x in "$rcB" "$rcC" "$rcD"; do [ "$x" = 0 ] && n0=$((n0+1)); done
assert_eq "$n0|$(grep -c "claude --resume $U7" "$STUB_LOG")" "1|1" "three launchers of one stale claim: exactly one exits 0, and one launch (B $rcB, C $rcC, D $rcD)"
for o in "$SHAPE_TMP/b.out" "$SHAPE_TMP/c.out" "$SHAPE_TMP/d.out"; do [ -s "$o" ] && TL kill-pane -t "$(cat "$o")" 2>/dev/null; done
# The one gap left is safe: B removed the judged record and is held before it
# links its own; D links first and launches, and B, whose link then fails,
# launches nothing.
reset
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
G2="$(gone_pane)"
mkdir -p "$CLB/claude-$U7"
ln -s "999999 Thu Jan  1 00:00:00 1970" "$CLB/claude-$U7/owner"
printf '%s\n%s\n' "$G2" "999999 Thu Jan  1 00:00:00 1970" > "$CLB/claude-$U7/pane"
rm -f "$HT" "$HT".at.* "$SHAPE_TMP/b.rc"
( ROOST_TEST_CLAIM_PAUSE_TAKEN="$HT" R revive "$G" > "$SHAPE_TMP/b.out" 2>"$SHAPE_TMP/b.err"; echo $? > "$SHAPE_TMP/b.rc" ) &
BPID=$!
i=0; while [ "$i" -lt 100 ] && ! ls "$HT".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
ls "$HT".at.* >/dev/null 2>&1; assert_true $? "(seam) launcher B is held after removing the stale record, before it links its own"
R revive "$G" > "$SHAPE_TMP/d.out" 2>"$SHAPE_TMP/d.err"; rcD=$?
: > "$HT"; wait "$BPID"; rcB="$(cat "$SHAPE_TMP/b.rc")"
sleep 1
assert_eq "$rcD|$rcB|$(grep -c "claude --resume $U7" "$STUB_LOG")" "0|13|1" "...a launcher that links in that gap wins; the held one is refused, one launch"
for o in "$SHAPE_TMP/b.out" "$SHAPE_TMP/d.out"; do [ -s "$o" ] && TL kill-pane -t "$(cat "$o")" 2>/dev/null; done

# Another live launcher holds the takeover of the same stale record for too
# long: refused (13), in a plain sentence (review round 2, Fable N3).
reset
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
G2="$(gone_pane)"
sleep 600 >/dev/null 2>&1 & LIVEPID=$!; LIVELST="$(roost_shape__lstart "$LIVEPID")"
mkdir -p "$CLB/claude-$U7"
ln -s "999999 Thu Jan  1 00:00:00 1970" "$CLB/claude-$U7/owner"
printf '%s\n%s\n' "$G2" "999999 Thu Jan  1 00:00:00 1970" > "$CLB/claude-$U7/pane"
ln -s "$LIVEPID $LIVELST" "$(roost_shape__takeover "$CLB/claude-$U7/owner" "999999 Thu Jan  1 00:00:00 1970")"
R revive "$G" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(cat "$STUB_LOG")" "13|" "a takeover another live launcher holds: exit 13, nothing launched"
assert_eq "$(cat "$SHAPE_TMP/err")" "roost revive: claude $U7 is being taken over by another launcher right now. Nothing was resumed; try again." "...said as a plain sentence"
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null; LIVEPID=""

# Saving off (ROOST_SHAPE_DIR empty) still claims (review round 1, Codex B4),
# in the same directory as with saving on (round 2), so two revives of one
# gone record still launch once.
reset
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
first="$(ROOST_SHAPE_DIR="" R revive "$G" 2>"$SHAPE_TMP/err")"; rc=$?
assert_eq "$rc" "0" "saving off: the first revive of a gone record launches"
assert_eq "$(head -n 1 "$CLB/claude-$U7/pane" 2>/dev/null)" "$first" "...its claim is under the state directory's launch-claims/<server>/claims/<boot>/"
wait_log "claude --resume $U7"
ROOST_SHAPE_DIR="" R revive "$G" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(grep -c "claude --resume $U7" "$STUB_LOG")" "13|1" "...the second is refused (13), one launch"
TL kill-pane -t "$first" 2>/dev/null
# Saving on, then off, for one gone record (review round 2, Opus R2-N1 and
# Fable N2): claims live in ONE place whatever the saving setting, so the
# second revive sees the first's claim. Before, saving on put it in the shape
# directory and saving off under launch-claims/, and both launched.
reset
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
first="$(R revive "$G" 2>/dev/null)"; rc=$?
wait_log "claude --resume $U7"
ROOST_SHAPE_DIR="" R revive "$G" >/dev/null 2>"$SHAPE_TMP/err"; rc2=$?
assert_eq "$rc|$rc2|$(grep -c "claude --resume $U7" "$STUB_LOG")" "0|13|1" "saving on, then off, one gone record: the second is refused (13), one launch"
assert_contains "$(cat "$SHAPE_TMP/err")" "$first" "...naming the first pane"
TL kill-pane -t "$first" 2>/dev/null
# A shape directory that cannot be made does not stop a claim: claims never
# live there (review round 2).
reset
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
: > "$SHAPE_TMP/not-a-dir"
out="$(ROOST_SHAPE_DIR="$SHAPE_TMP/not-a-dir/shapes" R revive "$G" 2>"$SHAPE_TMP/err")"; rc=$?
assert_eq "$rc|$(head -n 1 "$CLB/claude-$U7/pane" 2>/dev/null)" "0|$out" "saving on, its directory cannot be made: the claim is under launch-claims/ all the same, and it launches"
TL kill-pane -t "$out" 2>/dev/null
# No claim directory at all: refused, naming the storage error, nothing run —
# saving on or off.
reset
n0="$(nwin)"
XDG_STATE_HOME="$SHAPE_TMP/not-a-dir" R revive "$G" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(nwin)|$(cat "$STUB_LOG")" "1|$n0|" "saving on, launch-claims/ cannot be made: exit 1, no window, nothing launched"
assert_contains "$(cat "$SHAPE_TMP/err")" "not-a-dir/roost/launch-claims" "...naming the directory"
case "$(cat "$SHAPE_TMP/err")" in *"saving is off"*) said=yes ;; *) said=no ;; esac
assert_eq "$said" "no" "...and not calling it saving off"
ROOST_SHAPE_DIR="" XDG_STATE_HOME="$SHAPE_TMP/not-a-dir" R revive "$G" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(nwin)|$(cat "$STUB_LOG")" "1|$n0|" "saving off, the same: exit 1, nothing launched"
assert_contains "$(cat "$SHAPE_TMP/err")" "not-a-dir/roost/launch-claims" "...naming the directory"

# The caller's session is believed only when the caller is a pane of THIS
# server (review round 1, Fable N5): the user's everyday tmux sets TMUX and
# TMUX_PANE too, and a %N from there may exist here as another pane.
TL new-session -d -s zz-other 'ENV= exec /bin/sh'
QO="$(TL display -p -t '=zz-other:' '#{pane_id}')"
SPID="$(TL display -p '#{pid}')"
reset
G="$(gone_pane)"; plant_record "$G" claude "$U7" /old/cwd
out="$(env TMUX="/tmp/not-this-server/default,999999,0" TMUX_PANE="$QO" ROOST_SOCKET=roost "$ROOST" revive "$G" 2>/dev/null)"; rc=$?
assert_eq "$rc|$(TL display -p -t "$out" '#{session_name}' 2>/dev/null)" "0|shp" "a TMUX_PANE from another tmux server is not the caller's session here (the window goes to the fallback)"
TL kill-pane -t "$out" 2>/dev/null
reset
out="$(env TMUX="$SHAPE_SOCK,$SPID,0" TMUX_PANE="$QO" ROOST_SOCKET=roost "$ROOST" revive "$G" 2>/dev/null)"; rc=$?
assert_eq "$rc|$(TL display -p -t "$out" '#{session_name}' 2>/dev/null)" "0|zz-other" "(control) a caller that IS a pane of this server: its session"
TL kill-pane -t "$out" 2>/dev/null
TL kill-session -t '=zz-other'

# --new-window of a live pane that carries its own key: no exemption.
reset
P="$(stubpane claude)"; wait_cmd "$P" claude; setid "$P" claude "$U4" "$D1R"
n0="$(nwin)"; pid0="$(ppid_of "$P")"
R revive --new-window "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(nwin)|$(ppid_of "$P")" "13|$n0|$pid0" "--new-window of a live pane with its own key: exit 13, no new window, the pane untouched"
assert_contains "$(cat "$SHAPE_TMP/err")" "is open in $P" "...naming the pane itself"
TL kill-pane -t "$P"

# A dead pane left by a resume that exited non-zero can be revived again in
# place (review round 2, Fable N1; §4.1 step 7: "the next revive ... on it
# clears it"). Revive cleared the pane's identity before the respawn, so the
# dead pane has no key: the pane's own record on this boot supplies it, as for
# a gone pane.
reset
X1="$SHAPE_TMP/exit1-bin"; mkdir -p "$X1"; cp "$STUB_WRAP/claude-exit1" "$X1/claude"
W="$(TL new-window -d -P -F '#{window_id}' -t shp: "$STUB_BIN/claude 600")"
P="$(TL display -p -t "$W" '#{pane_id}')"
TL split-window -d -t "$P" "$STUB_BIN/claude 600"
wait_cmd "$P" claude; setid "$P" claude "$U4" "$D1R"; plant_record "$P" claude "$U4" "$D1R"
env PATH="$X1:$PATH" ROOST_SOCKET=roost "$ROOST" revive "$P" >/dev/null 2>&1; rc=$?
i=0; while [ "$i" -lt 50 ] && [ "$(TL display -p -t "$P" '#{pane_dead}')" != 1 ]; do sleep 0.1; i=$((i+1)); done
assert_eq "$rc|$(TL display -p -t "$P" '#{pane_dead}')|$(popt "$P" @roost-session)" "0|1|" "(setup) a resume that exits 1 leaves a dead pane with no key"
: > "$STUB_LOG"
out="$(R revive "$P" 2>"$SHAPE_TMP/err")"; rc=$?
assert_eq "$rc|$out" "0|$P" "the dead pane revived again: exit 0, the same %N (its key from its record)"
wait_log "claude --resume $U4"; assert_true $? "...and the conversation launched"
TL kill-window -t "$W"
# A dead pane with no key and no record: nothing to go on, as before.
W="$(TL new-window -d -P -F '#{window_id}' -t shp: "$STUB_BIN/claude 600")"
P="$(TL display -p -t "$W" '#{pane_id}')"
TL split-window -d -t "$P" "$STUB_BIN/claude 600"
TL set-option -p -t "$P" remain-on-exit on; TL respawn-pane -k -t "$P" 'exit 1'
i=0; while [ "$i" -lt 50 ] && [ "$(TL display -p -t "$P" '#{pane_dead}')" != 1 ]; do sleep 0.1; i=$((i+1)); done
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "a dead pane with no key and no record: exit 13"
assert_contains "$(cat "$SHAPE_TMP/err")" "has no recorded conversation" "...says so"
TL kill-window -t "$W"

# Gone with nothing to go on.
reset
G="$(gone_pane)"
R revive "$G" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "2" "a gone %N with no record: exit 2"
G="$(gone_pane)"; plant_record "$G" claude "" /old/cwd
R revive "$G" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "a gone %N whose record has no session id: exit 13"
assert_contains "$(cat "$SHAPE_TMP/err")" "has no recorded conversation" "...says so"
unset ROOST_RECORD_DIR; export ROOST_RECORD_DIR=""

# --- revive meets the pending states (#191 Part 3, Task 3.8) ------------------
# A pane a restore placed and has not resumed: a placeholder by its own path,
# watching pending/<boot>/%P (planted here, the block roost_pending_write
# writes). The worker is `roost restore --resume`, run directly (worker-only:
# Part 5's hook is not covered).
PH="$PWD/scripts/roost-placeholder"
PEND="$SD/pending/$BOOT"; mkdir -p "$PEND"
V1=3fa3c0de-0001-4abc-8def-0000000000a1
V2=3fa3c0de-0002-4abc-8def-0000000000a2
V3=3fa3c0de-0003-4abc-8def-0000000000a3
V4=3fa3c0de-0004-4abc-8def-0000000000a4
V5=3fa3c0de-0005-4abc-8def-0000000000a5
V6=3fa3c0de-0006-4abc-8def-0000000000a6
V7=3fa3c0de-0007-4abc-8def-0000000000a7
for v in "$V1" "$V2" "$V3" "$V4" "$V5" "$V6"; do stub_store_add "$v" "$D1R"; done
RB=(env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST")
wait_screen() { local i=0; while [ "$i" -lt "${3:-30}" ]; do TL capture-pane -p -t "$1" 2>/dev/null | grep -qF -- "$2" && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
wait_f() { local i=0; while [ "$i" -lt "${2:-50}" ]; do [ -e "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
shells_wait() { local i=0; while [ "$i" -lt 30 ]; do [ -n "$(shells_for "$1")" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
# waiting ID [TRANSCRIPT] -> a new waiting placeholder pane for conversation ID
waiting() {
  local p tr="${2-}"
  p="$(TL new-window -d -P -F '#{pane_id}' -t shp: -c "$D1R" 'sleep 600')"
  { printf 'was %%900\nharness claude\nsession_id %s\n' "$1"
    [ -n "$tr" ] && printf 'transcript %s\n' "$tr"
    printf 'cwd %s\nsession shp\nwindow 1\norder 1\n' "$D1R"; } > "$PEND/$p"
  TL set -p -t "$p" remain-on-exit failed
  TL respawn-pane -k -t "$p" "$PH" "$PEND/$p" claude
  wait_screen "$p" "waiting to resume claude" >/dev/null
  printf '%s\n' "$p"
}
phline() { TL display -p -t "$1" '#{pane_start_command}' | tr -d '"\\'; }
claimed() { [ -L "$CLB/claude-$1/owner" ] && echo held; }
taken_with_sleep() { # PANE — a key, then `sleep 60` in the shell it hands over
  TL send-keys -t "$1" x; wait_f "$PEND/$1.taken"; shells_wait "$1"
  TL send-keys -t "$1" 'sleep 60' Enter; wait_cmd "$1" sleep
}

echo "== revive against a waiting pane: T5, then the worker launches nothing for it =="
reset
P="$(waiting "$V1")"
assert_eq "$(phline "$P")" "$PH $PEND/$P claude" "(before) the pane runs its placeholder line"
out="$(R revive "$P" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out|$(ls "$PEND" | grep "^$P")" "0|$P|$P.launching" "revive a waiting pane: exit 0, the same %N, its file %P.launching"
assert_eq "$(tail -1 "$PEND/$P.launching")" "origin waiting" "...with its origin line"
wait_log "claude --resume $V1"; assert_true $? "...launched"
R restore --resume >/dev/null 2>&1
assert_eq "$(grep -c "$V1" "$STUB_LOG")" "1" "a worker run after it launches nothing more for %P"
TL kill-pane -t "$P"; rm -f "$PEND/$P".*

echo "== overlapping the worker: revive %Q, then restore --resume =="
reset
Q="$(shpane "$D1R")"; wait_cmd "$Q" sh; setid "$Q" claude "$V2" "$D1R"
P="$(waiting "$V2")"
R revive "$Q" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "(fixture) revive %Q launched its conversation"
R restore --resume >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(head -1 "$PEND/$P.failed" 2>/dev/null)|$(grep -c "$V2" "$STUB_LOG")" "13|duplicate of $Q|1" \
  "the worker then finds the key claimed: %P.failed duplicate of %Q, one launch"
TL kill-pane -t "$Q"; TL kill-pane -t "$P"; rm -f "$PEND/$P".*

echo "== a taken pane: the shell checks (T17, T8) =="
reset
P="$(waiting "$V3")"; taken_with_sleep "$P"; pid0="$(ppid_of "$P")"
assert_eq "$(phline "$P")" "$PH $PEND/$P claude" "(before) the start command still reads the placeholder line (it survives the exec)"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(TL display -p -t "$P" '#{pane_current_command}')|$(ls "$PEND" | grep "^$P")|$(claimed "$V3")" "1|sleep|$P.taken|" \
  "a taken pane in use: exit 1, the sleep alive, %P.taken again, no claim"
assert_contains "$(cat "$SHAPE_TMP/err")" "person's work" "...and says why"
assert_eq "$(grep -c '^origin' "$PEND/$P.taken")" "0" "...with no origin line left"
out="$(R revive --force "$P" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "0|$P" "--force: launched"
wait_log "claude --resume $V3"; assert_true $? "...the conversation"
TL kill-pane -t "$P"; rm -f "$PEND/$P".*
reset
P="$(waiting "$V4")"; TL send-keys -t "$P" x; wait_f "$PEND/$P.taken"; shells_wait "$P"; sleep 0.3
assert_eq "$(phline "$P")" "$PH $PEND/$P claude" "(before) an idle taken shell: still the placeholder line"
out="$(R revive "$P" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "0|$P" "an idle taken shell: exit 0, the same %P"
wait_log "claude --resume $V4"; assert_true $? "...launched"
TL kill-pane -t "$P"; rm -f "$PEND/$P".*

echo "== a revive of a taken shell, interrupted (T8b by origin taken) =="
reset
P="$(waiting "$V5")"; taken_with_sleep "$P"; pid0="$(ppid_of "$P")"
H="$SHAPE_TMP/rv.hold"; rm -f "$H" "$H".at.*
ROOST_TEST_REVIVE_HOLD="$H" "${RB[@]}" revive "$P" >/dev/null 2>&1 &
RV=$!
i=0; while [ "$i" -lt 50 ] && ! ls "$H".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
kill -9 "$RV" 2>/dev/null; wait "$RV" 2>/dev/null
[ -e "$PEND/$P.launching" ]; assert_true $? "(fixture) the killed revive left %P.launching and its claim"
R restore --resume >/dev/null 2>&1
assert_eq "$(ls "$PEND" | grep "^$P")|$(claimed "$V5")|$(TL display -p -t "$P" '#{pane_current_command}')|$(ppid_of "$P")|$(grep -c "$V5" "$STUB_LOG")" \
  "$P.taken||sleep|$pid0|0" "a worker run: %P.taken again, the claim gone, the sleep and pane_pid alive, nothing launched"
TL kill-pane -t "$P"; rm -f "$PEND/$P".*

echo "== no origin line: failed, interrupted, never retried =="
reset
P="$(waiting "$V6")"; mv "$PEND/$P" "$PEND/$P.launching"
wait_screen "$P" "resuming claude now" 70 >/dev/null
R restore --resume >/dev/null 2>&1
assert_eq "$(head -1 "$PEND/$P.failed" 2>/dev/null)" "interrupted" "a planted %P.launching with no origin line and no launcher: %P.failed interrupted"
R restore --resume --retry >/dev/null 2>&1
assert_eq "$(grep -c "$V6" "$STUB_LOG")" "0" "...and --retry launches nothing"
TL kill-pane -t "$P"; rm -f "$PEND/$P".*

echo "== an inherited origin: a store miss, a key, then a revive killed before its origin =="
reset
P="$(waiting "$V7")"
R restore --resume >/dev/null 2>&1
assert_eq "$(head -1 "$PEND/$P.failed")|$(grep -c '^origin' "$PEND/$P.failed")" "store miss|0" "a store miss: %P.failed, no origin line"
wait_screen "$P" "claude was not resumed" 70 >/dev/null
TL send-keys -t "$P" x; wait_f "$PEND/$P.taken"; shells_wait "$P"
assert_eq "$(grep -c '^origin' "$PEND/$P.taken")" "0" "T15: %P.taken, no origin line"
stub_store_add "$V7" "$D1R"
H="$SHAPE_TMP/rvo.hold"; rm -f "$H" "$H".at.*
ROOST_TEST_REVIVE_HOLD_BEFORE_ORIGIN="$H" "${RB[@]}" revive "$P" >/dev/null 2>&1 &
RV=$!
i=0; while [ "$i" -lt 50 ] && ! ls "$H".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
kill -9 "$RV" 2>/dev/null; wait "$RV" 2>/dev/null
R restore --resume >/dev/null 2>&1
assert_eq "$(head -1 "$PEND/$P.failed" 2>/dev/null)|$(grep -c "$V7" "$STUB_LOG")" "interrupted|0" \
  "a worker run: %P.failed interrupted (no origin proves nothing), nothing launched"
TL kill-pane -t "$P"; rm -f "$PEND/$P".*

echo "== a worker during a live revive's rename-to-claim window (review round 1, Opus N1) =="
# Three actors: revive renames the pane's file and holds right after its
# claim's owner link (before the claim names the pane); a worker runs; then
# the revive goes on. The worker must see a LIVE launcher and leave the file.
reset
V8=3fa3c0de-0008-4abc-8def-0000000000a8; stub_store_add "$V8" "$D1R"
P="$(waiting "$V8")"
H="$SHAPE_TMP/link.hold"; rm -f "$H" "$H".at.*
ROOST_TEST_CLAIM_HOLD_AFTER_LINK="$H" "${RB[@]}" revive "$P" >/dev/null 2>"$SHAPE_TMP/rverr" &
RV=$!
i=0; while [ "$i" -lt 50 ] && ! ls "$H".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
assert_eq "$(ls "$PEND" | grep "^$P")" "$P.launching" "(fixture) the revive renamed the file and holds before its claim names the pane"
R restore --resume >/dev/null 2>"$SHAPE_TMP/werr"; wrc=$?
assert_eq "$wrc|$(ls "$PEND" | grep "^$P")" "0|$P.launching" "the worker leaves a live launcher's file alone (no T8b, no T7)"
touch "$H"; wait "$RV"; rc=$?
wait_log "claude --resume $V8"
assert_eq "$rc|$(grep -c "$V8" "$STUB_LOG")|$(ls "$PEND" | grep "^$P")" "0|1|$P.launching" "the revive goes on: one launch, the file still %P.launching"
R send "$P" "x" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "3" "send agrees: refused (exit 3)"
assert_contains "$(cat "$SHAPE_TMP/err")" "is launched" "...as launched"
TL kill-pane -t "$P"; rm -f "$PEND/$P".* "$PEND"/.*"$P"* 2>/dev/null

echo "== a worker while a revive holds before its origin line (review round 1, Opus N2) =="
reset
V9=3fa3c0de-0009-4abc-8def-0000000000a9; stub_store_add "$V9" "$D1R"
TL set-environment -g STUB_IDENTIFY 1
P="$(waiting "$V9")"
H="$SHAPE_TMP/orig.hold"; rm -f "$H" "$H".at.*
ROOST_TEST_REVIVE_HOLD_BEFORE_ORIGIN="$H" "${RB[@]}" revive "$P" >/dev/null 2>&1 &
RV=$!
i=0; while [ "$i" -lt 50 ] && ! ls "$H".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
R restore --resume >/dev/null 2>&1
touch "$H"; wait "$RV"; rc=$?
wait_log "claude --resume $V9"
assert_eq "$rc|$(grep -c "$V9" "$STUB_LOG")" "0|1" "the revive goes on and launches, once"
i=0; while [ "$i" -lt 50 ] && ls "$PEND" | grep -q "^$P"; do sleep 0.1; i=$((i+1)); done
assert_eq "$(ls "$PEND" | grep -c "^$P")|$(TL show -pqv -t "$P" @roost-session)" "0|$V9" \
  "identity lands: no pending file left for the pane (never two, never a stray), the key on the pane"
TL set-environment -gu STUB_IDENTIFY
TL kill-pane -t "$P"; rm -f "$PEND/$P".* 2>/dev/null

echo "== --new-window from a pending file =="
reset
P="$(waiting "$V1")"
R revive --new-window "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(ls "$PEND" | grep "^$P")" "13|$P" "--new-window: exit 13, the file still %P"
assert_contains "$(cat "$SHAPE_TMP/err")" "revive it in place" "...saying revive it in place"
TL kill-pane -t "$P"; rm -f "$PEND/$P"

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
