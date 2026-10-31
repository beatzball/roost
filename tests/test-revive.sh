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

echo "== roost revive on a live pane, in place (§4.1, §8.1 test 6) =="
ROOST="$PWD/bin/roost"
# bin/roost from a person's shell, aimed at this file's server by name (its
# TMUX_TMPDIR makes `-L roost` this file's own socket). TMUX and TMUX_PANE are
# dropped: this file may itself run inside a roost pane.
R() { env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"
BOOT="$(TL display -p '#{start_time}-#{pid}')"
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
reset() { rm -rf "$SD/claims"; : > "$STUB_LOG"; }
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
assert_eq "$(readlink "$SD/claims/$BOOT/claude-$U4/owner" >/dev/null && cat "$SD/claims/$BOOT/claude-$U4/pane")" "$P" "...and its claim names the pane (kept: the launch succeeded)"

# working: untouched.
reset
P="$(stubpane claude)"; wait_cmd "$P" claude
setid "$P" claude "$U4" "$D1R"; TL set-option -p -t "$P" @agent_state working
pid0="$(ppid_of "$P")"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(ppid_of "$P")|$(popt "$P" @roost-session)" "1|$pid0|$U4" "a working pane: exit 1, untouched"
[ -e "$SD/claims/$BOOT/claude-$U4" ] && left=yes || left=no
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
out="$(R revive --force "$P" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "0|$P" "--force then launches"
wait_log "claude --resume $U4"; assert_true $? "...the conversation, in that pane"
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
mkdir -p "$SD/claims/$BOOT/claude-$U6"; ln -s "$LIVEPID $LIVELST" "$SD/claims/$BOOT/claude-$U6/owner"
printf '%s\n' "$Q" > "$SD/claims/$BOOT/claude-$U6/pane"
cl_before="$(readlink "$SD/claims/$BOOT/claude-$U6/owner")|$(cat "$SD/claims/$BOOT/claude-$U6/pane")"
P="$(stubpane claude)"; wait_cmd "$P" claude; setid "$P" claude "$U6" "$D1R"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "a live claim for $Q: a second pane carrying the key is refused (exit 13)"
assert_contains "$(cat "$SHAPE_TMP/err")" "already being launched in $Q" "...naming the claim's pane"
assert_eq "$(readlink "$SD/claims/$BOOT/claude-$U6/owner")|$(cat "$SD/claims/$BOOT/claude-$U6/pane")" "$cl_before" "...and the claim is left byte for byte"
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

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
