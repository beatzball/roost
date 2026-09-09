#!/usr/bin/env bash
# Drive REAL opencode against a local model and assert the pane badges.
#
# NOT part of the suite: this directory is deliberately outside tests/'s flat
# test-*.sh glob, so tests/run.sh cannot pick it up. Run it by hand before
# merging adapter changes, and after any opencode upgrade.
#
#   bash tests/live/opencode-smoke.sh
#
# Needs opencode and a local ollama serving a tool-capable model. No account
# and no quota: every XDG home is redirected to a scratch directory, so no
# stored credential is even reachable. Skips -- never fails -- if either is
# missing.
#
# Isolation: its own tmux socket. The live -L roost server is never contacted.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
# Default picked for SIZE, then checked for fitness: granite4.2:3b is 2.2 GB and
# loads cold in ~3s, against ornith:35b's 21.2 GB and ~11s. That matters here
# because this file is the one test a contributor has to pull a model to run at
# all, and a 21 GB pull is most of the reason not to bother.
#
# It is not merely small. Driven through real opencode panes it echoed exact
# text 3 runs out of 3, reported its own pane id with the `%` intact, relayed
# another pane's reply verbatim, and sent to a peer that received the message —
# and it passes every assertion below, subagent interleaving included. Models
# that failed that bar: ministral-3:8b invented an error rather than relay,
# ornith-1.5:9b dropped the `%` from a pane id, and everything else at 3b or
# below mangled a two-line echo.
#
# Override for a bigger model when the ANSWER matters rather than the plumbing:
#   ROOST_LIVE_MODEL=ornith-1.5:35b bash tests/live/opencode-smoke.sh
MODEL="${ROOST_LIVE_MODEL:-granite4.2:3b}"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }
command -v opencode >/dev/null 2>&1 || skip "opencode not installed"
command -v ollama   >/dev/null 2>&1 || skip "ollama not installed"
curl -s -m 5 http://localhost:11434/api/tags >/dev/null 2>&1 \
  || skip "ollama is not responding on :11434"
ollama list 2>/dev/null | grep -q "^${MODEL} " \
  || skip "model $MODEL not pulled (override with ROOST_LIVE_MODEL)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }
# A case the local model refused to set up is not a plugin failure. The
# subagent case needs the model to actually call the task tool, and a small
# local model sometimes just answers instead; that must read as SKIP, not FAIL,
# or the suite cries wolf about code that was never exercised.
skipped() { printf '  SKIP: %s\n' "$1"; }
# An observation from the event log that this test deliberately does not turn
# into an assertion -- see the post-error idle note in case 2.
note() { printf '  NOTE: %s\n' "$1"; }

# A readiness timeout is not a badge assertion, so it does not fit ok/no --
# it means the harness itself could not get set up, and continuing would just
# send input at a TUI that was never listening. Fail loudly and stop instead
# of letting that read as a plugin regression (it has, and cost a manual
# reproduction to rule out).
die() { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; printf '\n  %d passed, %d failed\n' "$pass" "$fail"; exit 1; }

D="$(mktemp -d /tmp/amx.XXXX)"
# The socket path MUST end in /roost -- roost state is a no-op on any other
# socket, which is exactly what keeps it safe to wire into global hooks.
S="$D/roost"
# The event logs live outside $D so a failure can leave them behind to read:
# the badge that came out is rarely enough to diagnose one, and re-running
# costs another few minutes of model time. A clean run deletes them.
L="$(mktemp -d /tmp/amx-events.XXXX)"
keep_logs() {
  if [ "$fail" -eq 0 ]; then rm -rf "$L"
  else printf '  event logs kept in %s\n' "$L"; fi
}
trap 'tmux -S "$S" kill-server 2>/dev/null; rm -rf "$D"; keep_logs' EXIT

export XDG_CONFIG_HOME="$D/config" XDG_DATA_HOME="$D/data" XDG_CACHE_HOME="$D/cache"
mkdir -p "$XDG_CONFIG_HOME/opencode/plugin" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$D/proj"

# A SYMLINK, matching how a user installs it -- so this also proves opencode
# still follows symlinks when discovering plugins.
ln -s "$HERE/adapters/opencode/roost.js" "$XDG_CONFIG_HOME/opencode/plugin/roost.js"
# Second plugin: records the raw event stream the adapter is reacting to, one
# JSON object a line, into $ROOST_EVENT_LOG. The badge assertions say WHAT the
# pane showed; the log is the only thing that says why, and it is what answers
# the two questions in docs/known-gaps.md -- which session an event came from,
# and whether opencode counts retries for us.
ln -s "$HERE/tests/live/event-log.js" "$XDG_CONFIG_HOME/opencode/plugin/event-log.js"

# Reading the log needs python3, the same interpreter tests/test-contrast.py
# already requires in CI. Without it the badge assertions still run and the raw
# log is left behind to read by hand.
report() {  # report <mode> <log>
  if command -v python3 >/dev/null 2>&1; then
    python3 "$HERE/tests/live/event-report.py" "$1" "$2"
  else
    printf '    (no python3 -- raw log at %s)\n' "$2"
    # 3, distinct from the script's own 0/1/2, so a caller can tell "the log
    # says no" from "nothing read the log".
    return 3
  fi
}

write_config() {  # write_config <baseURL>
  cat > "$XDG_CONFIG_HOME/opencode/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama local",
      "options": { "baseURL": "$1" },
      "models": { "$MODEL": { "name": "$MODEL" } }
    }
  },
  "model": "ollama/$MODEL",
  "permission": { "bash": "ask" }
}
JSON
}

tmux -S "$S" -f /dev/null new-session -d -x 160 -y 45
tmux -S "$S" source-file "$HERE/tmux/roost.conf"
tmux -S "$S" set-option -g @roost-home "$HERE"

state() { tmux -S "$S" show-options -pqv -t "$1" @agent_state; }

# wait_state PANE WANT TIMEOUT -> 0 if the pane reaches WANT in time
wait_state() {
  local p="$1" want="$2" t="$3" n=0
  while [ "$n" -lt "$t" ]; do
    [ "$(state "$p")" = "$want" ] && return 0
    sleep 1; n=$((n+1))
  done
  return 1
}

# approve_until_done PANE TIMEOUT -> 0 once the turn ends, answering every
# permission dialog on the way with the default choice ("Allow once").
#
# How many dialogs a turn raises is the model's decision, not ours, so a fixed
# number of Enters makes the case flaky against a chattier one. The 2s pause
# after an Enter lets the badge leave blocked before the next look, so one
# dialog cannot collect several Enters -- the extra ones would land in the
# prompt box of the next turn.
approve_until_done() {
  local p="$1" t="$2" n=0
  while [ "$n" -lt "$t" ]; do
    case "$(state "$p")" in
      done) return 0 ;;
      blocked) tmux -S "$S" send-keys -t "$p" Enter; sleep 2; n=$((n+2)); continue ;;
    esac
    sleep 1; n=$((n+1))
  done
  return 1
}

# wait_ready PANE TIMEOUT -> 0 once opencode's TUI is actually accepting
# input. A fixed sleep before the first send-keys is long enough on an idle
# machine and not on one loaded by repeated 21GB model runs -- the prompt
# gets typed at a TUI that has not rendered yet and is silently dropped, so
# the pane never leaves its empty state and the failure reads as a plugin
# regression. "ctrl+p commands" is part of the TUI's footer and is present
# once (and only once) the prompt box is live; verified by capturing a real
# pane and grepping for it before wiring this in.
wait_ready() {
  local p="$1" t="$2" n=0
  while [ "$n" -lt "$t" ]; do
    tmux -S "$S" capture-pane -p -t "$p" 2>/dev/null | grep -q "ctrl+p commands" && return 0
    sleep 1; n=$((n+1))
  done
  return 1
}

# watch_badges PANE FILE -> prints the pid of a sampler that appends every
# badge CHANGE to FILE, one per line.
#
# wait_state only proves the pane reached a state; it cannot prove the pane
# never showed a wrong one on the way. The subagent bug is exactly that shape:
# a `done` that is corrected 34ms later by the parent's next busy. Sampling at
# 0.1s cannot catch every such window -- it is a net, not a proof -- but a
# `done` it does catch mid-turn is real, and the fix makes the net stay empty.
watch_badges() {
  ( last=""
    while :; do
      s="$(state "$1")"
      [ "$s" != "$last" ] && { printf '%s\n' "$s" >> "$2"; last="$s"; }
      sleep 0.1
    done ) >/dev/null 2>&1 &
  echo $!
}

# roost must be on PATH inside opencode's process, exactly as it is for a real
# user whose shell has bin/ on PATH.
#
# ROOST_EVENT_LOG turns on tests/live/event-log.js for this pane. One log per
# case, named by the caller, so a case's stream can be read on its own.
launch() {  # launch <logname> -> prints the pane id
  tmux -S "$S" new-window -d -P -F '#{pane_id}' -c "$D/proj" \
    "PATH=$HERE/bin:$PATH ROOST_EVENT_LOG=$L/$1.jsonl opencode"
}

# --- case 1: a normal turn that must ask permission ---
write_config "http://localhost:11434/v1"
p="$(launch case1)"

wait_ready "$p" 60 || die "opencode's TUI never became interactive (case 1, waited 60s for the ctrl+p commands footer)"
tmux -S "$S" send-keys -t "$p" 'Use the bash tool to run: echo hello'
sleep 1
tmux -S "$S" send-keys -t "$p" Enter

if wait_state "$p" working 90; then ok "pane reaches working when the turn starts"
else no "pane reaches working when the turn starts (got '$(state "$p")')"; fi

if wait_state "$p" blocked 180; then ok "pane reaches blocked at the permission prompt"
else no "pane reaches blocked at the permission prompt (got '$(state "$p")')"; fi

tmux -S "$S" send-keys -t "$p" Enter    # approve: "Allow once" is the default

# One Enter is not enough. A local model decides for itself how many tool calls
# a one-line request needs, and an observed run asked a SECOND time (a second
# permission.asked 3s after the first was replied to); the pane then sat on
# blocked until the case timed out, which reads as a plugin regression and is
# nothing of the kind. Answer every dialog until the turn actually ends.
# approve_until_done only presses Enter while the badge says blocked, so the
# Enter above is not doubled up on the dialog it already answered.
if approve_until_done "$p" 240; then ok "pane reaches done when the turn ends"
else no "pane reaches done when the turn ends (got '$(state "$p")')"; fi

# the adapter must also label the pane, so the border stops showing a version
# string -- same gap the Claude hook fills. It must read "opencode", not
# roost-agent-state's Claude-flavoured "claude" default: the adapter passes
# ROOST_AGENT_NAME=opencode precisely so this doesn't happen.
nm="$(tmux -S "$S" show-options -pqv -t "$p" @roost-name)"
[ "$nm" = "opencode" ] && ok "the adapter labels its pane opencode" || no "the adapter labels its pane opencode (got '$nm')"
tmux -S "$S" kill-window -t "$p" 2>/dev/null

printf '  case 1 event stream:\n'
report summary "$L/case1.jsonl"

# --- case 1b: a turn that spawns a subagent must not badge done early ---
# opencode runs a task/subagent in a CHILD session on the same process-global
# bus, and the child goes idle while the parent's turn is still running. This
# case is the evidence behind the filter in adapters/opencode/roost.js: without
# it, the child's session.idle stamps `done` on a pane that is still working.
#
# The model has to co-operate by actually calling the task tool. A small local
# model sometimes answers directly instead, which is a SKIP -- nothing about
# the adapter was exercised -- not a failure.
p1b="$(launch case1b)"
wait_ready "$p1b" 60 || die "opencode's TUI never became interactive (case 1b, waited 60s for the ctrl+p commands footer)"
badges="$L/case1b.badges"
: > "$badges"
sampler="$(watch_badges "$p1b" "$badges")"
# The subagent is told to run bash so the child session raises a permission
# dialog of its own. That covers the other half of the filter: the child's
# start and end are not this pane's, but the dialog IS -- the human answering
# it is sitting here.
tmux -S "$S" send-keys -t "$p1b" "Use the task tool to start the 'general' subagent with this description: 'run echo'. The subagent's prompt must be: Use the bash tool to run exactly: echo hello-from-subagent, then report its output. After the subagent finishes, tell me what it printed."
sleep 1
tmux -S "$S" send-keys -t "$p1b" Enter

# 420s: the subagent turn is two model turns end to end, and the first one on a
# cold 21GB model took 77s of that on the machine this was written on.
turn_ended=1
if approve_until_done "$p1b" 420; then turn_ended=0; fi
kill "$sampler" 2>/dev/null
wait "$sampler" 2>/dev/null

report subagent "$L/case1b.jsonl"
case "$?" in
  0)
    # The stream contains the hazard, so the badge assertion below means
    # something. Everything the pane showed before the last change must be a
    # working state: a `done` anywhere but the end is the child's idle leaking
    # through the filter.
    early="$(sed '$d' "$badges" | grep -c '^done$')"
    [ "$early" -eq 0 ] \
      && ok "a subagent's idle never badges the pane done mid-turn" \
      || no "a subagent's idle badged the pane done mid-turn ($early time(s); badges: $(tr '\n' ',' < "$badges"))"
    [ "$turn_ended" -eq 0 ] \
      && ok "the pane still reaches done when the parent's turn ends" \
      || no "the pane still reaches done when the parent's turn ends (got '$(state "$p1b")')"
    ;;
  1) skipped "a subagent ran but did not idle before its parent -- nothing to assert" ;;
  2) skipped "the model never called the task tool, so the subagent path was not exercised" ;;
  *) skipped "no python3, so the event log went unread" ;;
esac

# The mirror of the filter: a child's permission dialog must NOT be filtered,
# because the human answering it is sitting at this pane. It is a NOTE and not
# an assertion on the badge, because the badge cannot be caught here: measured
# on 1.18.20, a subagent's bash dialog was replied `once` 40ms after it was
# asked, with nobody touching the keyboard. A 40ms `blocked` is below what a
# 0.1s sampler can see, and asserting it would be a coin flip.
#
# tests/opencode-plugin-harness.mjs holds the mapping assertion. What this line
# is for is noticing the day opencode stops emitting the child's dialog at all.
if report childperm "$L/case1b.jsonl"; then
  note "the badges sampled during the subagent turn: $(tr '\n' ',' < "$badges")"
else
  skipped "the subagent never asked for permission, so nothing to report about it"
fi
tmux -S "$S" kill-window -t "$p1b" 2>/dev/null

# --- case 2: an unreachable provider must reach error ---
# This is the retry path. It is the only way to produce `error` on demand.
#
# It used to be that opencode never emitted session.error for a provider it
# could not reach and retried forever (opencode#17648). Measured again on
# 1.18.20: it now gives up after 5 attempts, emitting session.error and then
# session.idle. The pane reaches error long before that -- two retries is the
# adapter's threshold -- so this case is unchanged, but the run no longer hangs
# in a retry loop, and the second turn below is only possible because of it.
#
# The dead address is a port we picked rather than the fixed 127.0.0.1:1 it used
# to be, and the reason is case 2b: it has to make this SAME opencode process
# see the provider come back, and the only lever for that is moving a listener
# onto an address opencode already knows (see tests/live/tcp-forward.py for the
# measurement that ruled out rewriting the config). An unbound port refuses a
# connection exactly the way port 1 did, so case 2 itself is unchanged.
#
# Binding port 0 and closing it is the kernel telling us a port that was free a
# moment ago. Nothing can reserve it in the gap, so if something else does grab
# it the dead-provider case fails loudly rather than passing for a wrong reason.
# Without python3 there is nothing to pick a port with and nothing to forward
# with either, so it falls back to port 1 -- unbindable, therefore permanently
# dead -- and case 2b skips.
if command -v python3 >/dev/null 2>&1; then
  DEADPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
else
  DEADPORT=1
fi
write_config "http://127.0.0.1:$DEADPORT/v1"
p2="$(launch case2)"
wait_ready "$p2" 60 || die "opencode's TUI never became interactive (case 2, waited 60s for the ctrl+p commands footer)"
tmux -S "$S" send-keys -t "$p2" 'Write a haiku about tmux.'
sleep 1
tmux -S "$S" send-keys -t "$p2" Enter

if wait_state "$p2" error 120; then ok "an unreachable provider drives the pane to error"
else no "an unreachable provider drives the pane to error (got '$(state "$p2")')"; fi

# Second turn, same pane, same dead provider. The adapter counts retries
# itself; opencode's session.status also carries its own `attempt`. Whether
# ours can be replaced by theirs depends on the numbering starting again in a
# new turn, which is what this second prompt measures. `attempts` prints one
# line per finished turn per session.
#
# The first turn must be OVER before the prompt is typed, and reaching `error`
# is not over: error fires at the second retry, ~6s in, while opencode keeps
# retrying to ~66s. A prompt sent into that window is accepted by the TUI, is
# drawn in the transcript, and then never runs -- observed exactly once, and it
# reads as "opencode ignored us" rather than as a test that asked too early.
wait_turns() {  # wait_turns COUNT TIMEOUT -> 0 once COUNT turns have ended
  local want="$1" t="$2" n=0
  while [ "$n" -lt "$t" ]; do
    [ "$(report attempts "$L/case2.jsonl" 2>/dev/null | grep -c 'turn ended')" -ge "$want" ] && return 0
    sleep 2; n=$((n+2))
  done
  return 1
}
# 240s per turn: five attempts with exponential backoff took 66s here, and the
# backoff is nearly all of it.
wait_turns 1 240 || no "the first dead-provider turn never finished retrying"
tmux -S "$S" send-keys -t "$p2" 'Write another haiku about tmux.'
sleep 1
tmux -S "$S" send-keys -t "$p2" Enter
wait_turns 2 240 || no "the second dead-provider turn never finished retrying"
printf '  case 2 retry attempts per turn:\n'
report attempts "$L/case2.jsonl"

# A turn that died on an unreachable provider ends with session.error followed
# by session.idle, and the adapter used to map that trailing idle to `done` --
# a failed turn finishing as "finished, go look". This was a NOTE: line for one
# release, printing the badge so a run showed the behaviour without claiming it
# was right; the mapping now suppresses that idle, so it is an assertion.
#
# Both turns above died, and no turn has started since, so nothing can have
# released the suppression. The pane must still read error.
b2="$(state "$p2")"
[ "$b2" = "error" ] \
  && ok "a dead turn's trailing session.idle does not end the pane on done" \
  || no "a dead turn's trailing session.idle does not end the pane on done (final badge '$b2')"

# --- case 2b: the pane must still reach done on the next healthy turn ---
# The other half of the fix, and the half worth the model time: a badge stuck on
# error forever is worse than the wrong done it replaced. Same pane and same
# opencode process, so the plugin instance holding the suppression is the one
# that just badged error -- a fresh pane would prove nothing about it.
#
# The provider comes back by putting a forwarder on the port opencode is already
# pointed at, NOT by rewriting the config. That distinction was measured, not
# assumed: a run that rewrote opencode.json between turns had the next turn retry
# the dead address five times anyway. tests/live/tcp-forward.py carries the
# detail.
if [ "$DEADPORT" = "1" ]; then
  skipped "no python3, so the dead provider could not be brought back"
else
  python3 "$HERE/tests/live/tcp-forward.py" "$DEADPORT" 11434 >/dev/null 2>&1 &
  fwd=$!
  # Killed here as well as in the trap: the trap is the safety net for an early
  # exit, and leaving a forwarder alive past the case it serves would let a
  # later change quietly depend on it.
  trap 'kill '"$fwd"' 2>/dev/null; tmux -S "$S" kill-server 2>/dev/null; rm -rf "$D"; keep_logs' EXIT
  # A listen() that has not happened yet refuses connections, which would just
  # look like another dead turn. One second is generous for a python process
  # that binds before it does anything else.
  sleep 1

  # The 0.1s sampler, not wait_state, and the reason is a measurement. This turn
  # is SHORT: the provider is local, the model is resident after case 2 kept
  # ollama warm, and the recovery turn ran busy at 130747ms to session.idle at
  # 133972ms -- 3.2 seconds for the whole thing. An earlier revision asked for
  # one word instead, which took 937ms, and wait_state's one-second poll read
  # the badge only after done and reported a working that had genuinely
  # happened as missing.
  #
  # A longer prompt widened that to 3.2s, which wait_state does catch, but a
  # badge assertion whose margin is the model's mood is a flake waiting for a
  # faster machine. watch_badges samples ten times a second and records every
  # CHANGE, so the evidence does not depend on how fast the turn is at all.
  badges2="$L/case2b.badges"
  : > "$badges2"
  sampler2="$(watch_badges "$p2" "$badges2")"

  tmux -S "$S" send-keys -t "$p2" 'Write a haiku about tmux, then explain each line in a sentence.'
  sleep 1
  tmux -S "$S" send-keys -t "$p2" Enter

  # approve_until_done rather than wait_state for the end: the model may decide
  # it wants a tool for this, and a dialog nobody answers would stall the case.
  turn2_ended=1
  if approve_until_done "$p2" 240; then turn2_ended=0; fi
  kill "$sampler2" 2>/dev/null
  wait "$sampler2" 2>/dev/null
  kill "$fwd" 2>/dev/null
  wait "$fwd" 2>/dev/null

  # The sampler's first line is the badge it found on arrival, which is the
  # error left by the two dead turns. So the sequence must OPEN with
  # error,working: the very next change out of error is the release, happening
  # where it was designed to, at the start of the next turn. A `blocked` from a
  # tool the model chose to call would come after that and is not excluded.
  seq2="$(tr '\n' ',' < "$badges2")"
  case "$seq2" in
    error,working*) ok "the next turn releases the error and the pane reports working" ;;
    *) no "the next turn releases the error and the pane reports working (badges: $seq2)" ;;
  esac

  # The other direction, and the one that says the suppression is not a one-way
  # door: the case above already proved it was applied, so a done here can only
  # mean it released.
  [ "$turn2_ended" -eq 0 ] \
    && ok "the pane still reaches done on the healthy turn after a dead one" \
    || no "the pane still reaches done on the healthy turn after a dead one (got '$(state "$p2")')"
fi
tmux -S "$S" kill-window -t "$p2" 2>/dev/null

# Printed last, not between the cases, so the one stream covers all three turns
# on this pane: the two that died and the one that recovered. The two
# session.error/session.idle pairs and the busy that follows the second of them
# are the whole state machine this fix added, in the order it really arrives.
printf '  case 2 event stream:\n'
report summary "$L/case2.jsonl"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
