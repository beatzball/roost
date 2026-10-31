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
# Claude: the folder is the measured rule (/ and . -> -), dotted path.
stub_store_add "$U1" "$WT"
f1="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$WT" | tr '/.' '--')/$U1.jsonl"
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
  mkdir -p "$CL/claude-$1"; ln -s "$2 $3" "$CL/claude-$1/owner"; printf '%s\n' "$4" > "$CL/claude-$1/pane"
}
snap() { (cd "$CL/claude-$1" 2>/dev/null && for f in owner pane; do printf '%s=' "$f"; if [ -L "$f" ]; then readlink "$f"; else cat "$f" 2>/dev/null; fi; done); }
ME="$$ $(roost_shape__lstart "$$")"

roost_resume_claim "$CL" claude "$U1" "$PA"; rc=$?
assert_eq "$rc|$ROOST_RESUME_CLAIM" "0|$CL/claude-$U1" "a free conversation is claimed: claims/<boot>/<harness>-<id>"
assert_eq "$(readlink "$CL/claude-$U1/owner")" "$ME" "...its owner record is this run's pid and start time"
assert_eq "$(cat "$CL/claude-$U1/pane")" "$PA" "...and it names the target pane"
roost_resume_claim "$CL" claude "$U2" ""; rc=$?
assert_eq "$rc|$(cat "$CL/claude-$U2/pane" 2>/dev/null)" "0|" "a claim may name no pane yet (empty until the launcher knows it)"
roost_resume_claim_pane "$CL/claude-$U2" "$PB"
assert_eq "$(cat "$CL/claude-$U2/pane")" "$PB" "roost_resume_claim_pane fills it in once the pane exists"
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
assert_eq "$rc|$(readlink "$CL/claude-$U1/owner")|$(cat "$CL/claude-$U1/pane")" "0|$ME|$PA" "a GONE pane with a LIVE claimer: stale, taken over"
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

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
