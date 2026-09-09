#!/usr/bin/env bash
# Drive REAL GitHub Copilot CLI against a local model and assert the pane badges.
#
# NOT part of the suite: this directory is deliberately outside tests/'s flat
# test-*.sh glob, so tests/run.sh cannot pick it up. Run it by hand before
# merging adapter changes, and after any copilot upgrade.
#
#   bash tests/live/copilot-smoke.sh
#
# Needs copilot and a local ollama serving a tool-capable model. NO GitHub
# account and no Copilot quota: COPILOT_PROVIDER_BASE_URL puts the CLI in BYOK
# mode, which its own `copilot help providers` states does not require GitHub
# authentication, and COPILOT_HOME is redirected to a scratch directory so no
# stored credential is even reachable. COPILOT_OFFLINE=true then turns off every
# remaining network path (auth, telemetry, web tools, the GitHub MCP server,
# auto-update). Skips -- never fails -- if copilot or the model is missing.
#
# Isolation: its own tmux socket. The live -L roost server is never contacted.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
# Same default, and the same reasoning, as tests/live/opencode-smoke.sh:
# granite4.2:3b is 2.2 GB, and this is the one test a contributor has to pull a
# model to run at all. Checked for fitness here too -- it echoes exact text, it
# calls the bash tool, and it calls the task tool when asked for a sub-agent.
#
# Override for a bigger model when the ANSWER matters rather than the plumbing:
#   ROOST_LIVE_MODEL=ornith-1.5:35b bash tests/live/copilot-smoke.sh
MODEL="${ROOST_LIVE_MODEL:-granite4.2:3b}"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }
command -v copilot >/dev/null 2>&1 || skip "copilot not installed"
command -v ollama  >/dev/null 2>&1 || skip "ollama not installed"
curl -s -m 5 http://localhost:11434/api/tags >/dev/null 2>&1 \
  || skip "ollama is not responding on :11434"
ollama list 2>/dev/null | grep -q "^${MODEL} " \
  || skip "model $MODEL not pulled (override with ROOST_LIVE_MODEL)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }
# A case the local model refused to set up is not an adapter failure. The
# sub-agent case needs the model to actually call the task tool, and the
# permission case needs it to choose a command copilot gates; a small local
# model sometimes does neither. That must read as SKIP, not FAIL, or the suite
# cries wolf about code that was never exercised.
skipped() { printf '  SKIP: %s\n' "$1"; }

# A readiness or dialog timeout is not a badge assertion, so it does not fit
# ok/no -- it means the harness itself could not get set up, and continuing
# would just send input at a TUI that was never listening. Fail loudly and stop
# instead of letting that read as an adapter regression.
die() { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; printf '\n  %d passed, %d failed\n' "$pass" "$fail"; exit 1; }

D="$(mktemp -d /tmp/amx.XXXX)"
# The socket path MUST end in /roost -- roost state is a no-op on any other
# socket, which is exactly what keeps it safe to wire into a global config.
S="$D/roost"
# The event logs live outside $D so a failure can leave them behind to read: the
# badge that came out is rarely enough to diagnose one, and re-running costs
# another few minutes of model time. A clean run deletes them.
L="$(mktemp -d /tmp/amx-events.XXXX)"
FWD=""
keep_logs() {
  if [ "$fail" -eq 0 ]; then rm -rf "$L"
  else printf '  event logs kept in %s\n' "$L"; fi
}
# The sleep is not padding. Copilot keeps writing session history and logs under
# $COPILOT_HOME right up to the moment it dies, so tearing the server down and
# deleting the tree in the same breath races it: rm walks a directory, copilot
# writes one more file into it, and rm exits with "Directory not empty" on a run
# where every assertion passed. One second is enough for the processes the
# server just killed to be reaped.
cleanup() {
  [ -n "$FWD" ] && kill "$FWD" 2>/dev/null
  tmux -S "$S" kill-server 2>/dev/null
  sleep 1
  rm -rf "$D"
  keep_logs
}
trap cleanup EXIT

# Copilot does NOT use the XDG directories. Everything -- credentials, settings,
# session history, logs and the extension directory this test installs into --
# lives under COPILOT_HOME, which `copilot help environment` documents as
# defaulting to $HOME/.copilot. One variable isolates the lot.
export COPILOT_HOME="$D/copilot"
mkdir -p "$COPILOT_HOME/extensions/roost" "$COPILOT_HOME/extensions/spy" "$D/proj"

# SYMLINKS, matching how a user installs the adapter -- so this also proves
# copilot still follows one when discovering extensions. The directory name is
# free; the file name is not, and `extension.mjs` is the only name copilot
# looks for.
ln -s "$HERE/adapters/copilot/extension.mjs"    "$COPILOT_HOME/extensions/roost/extension.mjs"
# Second extension: records the raw event stream the adapter is reacting to, one
# JSON object a line, into $ROOST_EVENT_LOG. The badge assertions say WHAT the
# pane showed; the log is the only thing that says why. It registers no handlers
# of its own -- see the comment in that file for why that matters here.
ln -s "$HERE/tests/live/copilot-event-log.mjs" "$COPILOT_HOME/extensions/spy/extension.mjs"

# Extensions are behind a feature flag that is OFF by default; without it
# copilot does not read the first line of the adapter and every badge assertion
# below fails for a reason that has nothing to do with the adapter. Two ways to
# turn it on, both verified on 1.0.81 -- `copilot --experimental`, or this file.
# This file is used here so the launch command stays the one a user would type.
printf '{"enabledFeatureFlags":{"EXTENSIONS":true}}\n' > "$COPILOT_HOME/settings.json"

tmux -S "$S" -f /dev/null new-session -d -x 200 -y 50
tmux -S "$S" source-file "$HERE/tmux/roost.conf"
tmux -S "$S" set-option -g @roost-home "$HERE"

state() { tmux -S "$S" show-options -pqv -t "$1" @agent_state; }
reply() { tmux -S "$S" show-options -p -t "$1" -qv @roost-reply; }

# wait_state PANE WANT TIMEOUT -> 0 if the pane reaches WANT in time
wait_state() {
  local p="$1" want="$2" t="$3" n=0
  while [ "$n" -lt "$t" ]; do
    [ "$(state "$p")" = "$want" ] && return 0
    sleep 1; n=$((n+1))
  done
  return 1
}

# wait_screen PANE TEXT TIMEOUT -> 0 once TEXT appears in the pane
wait_screen() {
  local p="$1" text="$2" t="$3" n=0
  while [ "$n" -lt "$t" ]; do
    tmux -S "$S" capture-pane -p -t "$p" 2>/dev/null | grep -q "$text" && return 0
    sleep 1; n=$((n+1))
  done
  return 1
}

# approve_until_done PANE TIMEOUT -> 0 once the turn ends, answering every
# permission dialog on the way with the default choice ("1. Yes", this time
# only -- never "and don't ask again", which would persist into $COPILOT_HOME
# and quietly disarm the permission case on a re-run).
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

# watch_badges PANE FILE -> prints the pid of a sampler that appends every badge
# CHANGE to FILE, one per line.
#
# wait_state only proves the pane reached a state; it cannot prove the pane
# never showed a wrong one on the way. The dead-turn bug is exactly that shape:
# an `error` corrected to `done` one millisecond later. Sampling at 0.1s cannot
# catch every such window -- it is a net, not a proof -- but a `done` it does
# catch mid-turn is real, and the fix makes the net stay empty.
watch_badges() {
  ( last=""
    while :; do
      s="$(state "$1")"
      [ "$s" != "$last" ] && { printf '%s\n' "$s" >> "$2"; last="$s"; }
      sleep 0.1
    done ) >/dev/null 2>&1 &
  echo $!
}

# launch <logname> <baseURL> -> prints the pane id
#
# ROOST_SOCKET is belt AND braces here, and it is still not something a real
# user sets. It used to be load-bearing: `roost state` reached this server on
# its own -- it goes through scripts/roost-agent-state, which finds the server
# from $TMUX -- while `roost reply` resolved the socket from $ROOST_SOCKET,
# defaulted to `-L roost`, and then refused to write because the server pid it
# found there was not the pid in this pane's $TMUX. Without the variable every
# badge assertion below passed and every reply assertion failed, with nothing
# printed to say why. Measured, and recorded as a live risk until it was fixed.
#
# bin/roost now resolves the server the same way roost-agent-state does (see
# scripts/lib/roost-socket.sh), and $S ends in /roost, so this would work
# without it. It stays because an explicit seam is what the rest of the suite
# uses and it does not depend on the socket keeping that name --
# tests/test-reply-socket.sh is what holds the unset case honest.
launch() {
  tmux -S "$S" new-window -d -P -F '#{pane_id}' -c "$D/proj" \
    "PATH=$HERE/bin:\$PATH ROOST_SOCKET=$S ROOST_EVENT_LOG=$L/$1.jsonl \
     COPILOT_PROVIDER_BASE_URL=$2 COPILOT_MODEL=$MODEL COPILOT_OFFLINE=true \
     copilot --banner"
}

# Copilot opens two blocking dialogs before its prompt box is usable, and both
# are answered with the FIRST choice, which is the one-session-only option:
#
#   "Do you trust the files in this folder?"          -- 1. Yes
#   'Extension "user:roost" wants elevated permissions'
#     "This extension wants to: handle permission requests."   -- 1. Yes
#
# The second one is copilot asking about the adapter's onPermissionRequest
# handler, and it recurs per directory; there is no global pre-approval. Denying
# it prevents the extension from loading at all, which is why this is a `die`
# and not a badge assertion -- everything after it would fail for the wrong
# reason.
#
# Then wait for the prompt box itself. A fixed sleep is long enough on an idle
# machine and not on one loaded by repeated model runs: the prompt gets typed at
# a TUI that has not rendered yet and is silently dropped, so the pane never
# leaves its empty state and the failure reads as an adapter regression. "open
# sidebar" is part of the TUI footer and is present once (and only once) the
# prompt box is live.
# Sets the global PANE rather than printing the id, so that `die` inside it
# actually stops the script. Called through $( ), every die would run in a
# subshell: the script would carry on with an EMPTY pane id, and every command
# after it would fail with tmux's own "can't find session:" against a target
# that is the empty string. That is a much worse failure than the one being
# reported, and it has happened here.
PANE=""
start_pane() {  # start_pane <logname> <baseURL> -> sets PANE
  PANE="$(launch "$1" "$2" 2>&1)"
  case "$PANE" in
    %[0-9]*) : ;;
    *) die "could not open a copilot window ($1): ${PANE:-tmux printed nothing}" ;;
  esac
  wait_screen "$PANE" "Do you trust" 60 || die "copilot never asked to trust the folder ($1)"
  tmux -S "$S" send-keys -t "$PANE" Enter; sleep 3
  wait_screen "$PANE" "wants elevated" 60 || die "copilot never asked to approve the roost extension ($1) -- is the EXTENSIONS feature flag on?"
  tmux -S "$S" send-keys -t "$PANE" Enter; sleep 3
  wait_screen "$PANE" "open sidebar" 60 || die "copilot's TUI never became interactive ($1, waited 60s for the open sidebar footer)"
}

ask() {  # ask <pane> <prompt>
  tmux -S "$S" send-keys -t "$1" "$2"; sleep 1
  tmux -S "$S" send-keys -t "$1" Enter
}

# --- case 1: a plain turn, and the reply channel -----------------------------
start_pane case1 http://localhost:11434/v1; p="$PANE"

# The startup consent the human just answered is announced on the event bus as a
# permission.completed, in the same millisecond as the extension joins and
# before any turn exists. An adapter that clears `blocked` unconditionally
# badges `working` here, and `working` is the badge roost wait-done blocks on --
# so a fresh pane would hang a waiter until its first real turn ended.
[ -z "$(state "$p")" ] \
  && ok "a pane that has not been asked to do anything stays unbadged" \
  || no "a pane that has not been asked to do anything stays unbadged (got '$(state "$p")')"

ask "$p" 'Say exactly: PLUM-ONE'
if wait_state "$p" working 90; then ok "pane reaches working when the turn starts"
else no "pane reaches working when the turn starts (got '$(state "$p")')"; fi
if wait_state "$p" done 240; then ok "pane reaches done when the turn ends"
else no "pane reaches done when the turn ends (got '$(state "$p")')"; fi

# The point of the whole reply channel: `roost read` returns what the agent
# SAID, not what is on its screen. Copilot is a full-screen alt-screen TUI whose
# last lines are an input box and a footer, so a scrape returns furniture.
case "$(reply "$p")" in
  *PLUM-ONE*) ok "the agent's answer is published to @roost-reply" ;;
  "")         no "the agent's answer is published to @roost-reply (nothing was recorded)" ;;
  *)          no "the agent's answer is published to @roost-reply (got '$(reply "$p")')" ;;
esac

# the adapter must also label the pane, so the border stops showing a version
# string -- same gap the Claude hook fills. It must read "copilot", not
# roost-agent-state's Claude-flavoured "claude" default: the adapter passes
# ROOST_AGENT_NAME=copilot precisely so this doesn't happen.
nm="$(tmux -S "$S" show-options -pqv -t "$p" @roost-name)"
[ "$nm" = "copilot" ] && ok "the adapter labels its pane copilot" || no "the adapter labels its pane copilot (got '$nm')"

# --- case 1p: a permission dialog must badge blocked -------------------------
# This is the case the whole adapter is shaped around. `blocked` is reachable
# only because the adapter registers an onPermissionRequest handler: copilot's
# permission.requested EVENT does not fire without one, and the spy extension
# next door -- which registers no handler -- proves that on every run, since it
# never records a permission.requested even while the dialog is on screen.
#
# `rm` rather than `echo`: copilot's sandbox auto-approves a plain echo, and an
# auto-approved call raises no dialog at all.
ask "$p" 'Use the bash tool to run exactly: rm -f deleteme.txt . Then tell me it is done.'
if wait_state "$p" blocked 240; then
  ok "pane reaches blocked at the permission prompt"
  # And the dialog is still the human's to answer. The adapter returns the SDK's
  # {kind:"no-result"} pass-through, so copilot draws its normal dialog and
  # waits; if roost had answered it, this text would already be gone.
  tmux -S "$S" capture-pane -p -t "$p" | grep -q "Do you want to run this command" \
    && ok "the dialog is still on screen for the human to answer -- roost observed it, it did not decide it" \
    || no "the dialog is still on screen for the human to answer -- roost observed it, it did not decide it"
  if approve_until_done "$p" 300; then ok "answering the dialog releases the pane to done"
  else no "answering the dialog releases the pane to done (got '$(state "$p")')"; fi
else
  # The model chose a command copilot did not gate, so nothing about `blocked`
  # was exercised. Not a failure.
  skipped "the model's command was auto-approved, so no permission dialog appeared"
  approve_until_done "$p" 120 >/dev/null 2>&1
fi

# --- case 1b: a sub-agent's answer must not become the pane's reply ----------
# Copilot runs the task tool's sub-agent on the SAME session, so its events --
# including a perfectly well-formed assistant.message carrying its own answer --
# arrive on the same bus as the pane's own. They are told apart by one envelope
# key, agentId, and this case is what proves the pane publishes the PARENT.
#
# The model has to co-operate by actually calling the task tool. A small local
# model sometimes answers directly instead, which is a SKIP -- nothing about the
# filter was exercised -- not a failure.
badges1b="$L/case1b.badges"; : > "$badges1b"
sampler="$(watch_badges "$p" "$badges1b")"
ask "$p" "Use the task tool to start a sub-agent whose prompt is exactly: reply with the single word BANANA and nothing else. When it finishes, tell me: the sub-agent said <its word>, and I am the parent."
turn_ended=1
approve_until_done "$p" 420 && turn_ended=0
kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null

if grep -q '"subagent.started"' "$L/case1.jsonl" 2>/dev/null; then
  case "$(reply "$p")" in
    *"I am the parent"*) ok "the pane publishes the parent's answer, not the sub-agent's" ;;
    BANANA|*BANANA)      no "the pane published the SUB-AGENT's answer as its reply (got '$(reply "$p")')" ;;
    *)                   no "the pane publishes the parent's answer, not the sub-agent's (got '$(reply "$p")')" ;;
  esac
  # Copilot's sub-agent emits no session.idle of its own -- measured -- so
  # unlike opencode there is no early `done` to guard against. This asserts that
  # stays true rather than assuming it: a `done` anywhere but at the end would
  # mean a sub-agent had started ending the pane's turns.
  early="$(sed '$d' "$badges1b" | grep -c '^done$')"
  [ "$early" -eq 0 ] \
    && ok "a sub-agent never badges the pane done mid-turn" \
    || no "a sub-agent badged the pane done mid-turn ($early time(s); badges: $(tr '\n' ',' < "$badges1b"))"
  [ "$turn_ended" -eq 0 ] \
    && ok "the pane still reaches done when the parent's turn ends" \
    || no "the pane still reaches done when the parent's turn ends (got '$(state "$p")')"
else
  skipped "the model never called the task tool, so the sub-agent path was not exercised"
fi
# The window is deliberately NOT killed here. The trap tears the whole server
# down, and while the run is alive a failing case's scrollback is the only place
# the TUI's own side of the story survives.

# --- case 2: an unreachable provider must reach error ------------------------
# The only way to produce `error` on demand. Binding port 0 and closing it is
# the kernel naming a port that was free a moment ago; nothing can reserve it in
# the gap, so if something else does grab it this case fails loudly rather than
# passing for a wrong reason. Without python3 there is nothing to pick a port
# with and nothing to forward with either, so it falls back to port 1 --
# unbindable, therefore permanently dead -- and case 2b skips.
if command -v python3 >/dev/null 2>&1; then
  DEADPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
else
  DEADPORT=1
fi
start_pane case2 "http://127.0.0.1:$DEADPORT/v1"; p2="$PANE"

badges2="$L/case2.badges"; : > "$badges2"
sampler2="$(watch_badges "$p2" "$badges2")"
ask "$p2" 'Write a haiku about tmux.'
if wait_state "$p2" error 180; then ok "an unreachable provider drives the pane to error"
else no "an unreachable provider drives the pane to error (got '$(state "$p2")')"; fi

# A turn that dies on the provider still ENDS, so copilot fires assistant.idle
# and session.idle straight after session.error -- measured in the same
# millisecond. An adapter that maps that trailing idle to `done` reports a dead
# turn as finished, which is the worst wrong badge there is: every other one
# makes you look, and this one makes you stop looking.
#
# Give it a moment to be overwritten before checking, or a fix that does not
# work still passes because the wrong write has not landed yet.
sleep 15
kill "$sampler2" 2>/dev/null; wait "$sampler2" 2>/dev/null
b2="$(state "$p2")"
[ "$b2" = "error" ] \
  && ok "a dead turn's trailing session.idle does not end the pane on done" \
  || no "a dead turn's trailing session.idle does not end the pane on done (final badge '$b2'; badges: $(tr '\n' ',' < "$badges2"))"
case "$(tr '\n' ',' < "$badges2")" in
  *done*) no "the pane flashed done during a turn that died (badges: $(tr '\n' ',' < "$badges2"))" ;;
  *)      ok "the pane never showed done at any point in the dead turn" ;;
esac

# --- case 2b: the pane must still reach done on the next healthy turn --------
# The other half of the fix, and the half worth the model time: a badge stuck on
# error forever is worse than the wrong done it replaced. Same pane and same
# copilot process, so the adapter instance holding the suppression is the one
# that just badged error -- a fresh pane would prove nothing about it.
#
# The provider comes back by putting a forwarder on the port copilot is already
# pointed at, NOT by restarting it against a live one, for the same reason
# tests/live/tcp-forward.py records for opencode: the process has already
# resolved its provider.
if [ "$DEADPORT" = "1" ]; then
  skipped "no python3, so the dead provider could not be brought back"
else
  python3 "$HERE/tests/live/tcp-forward.py" "$DEADPORT" 11434 >/dev/null 2>&1 &
  FWD=$!
  # A listen() that has not happened yet refuses connections, which would just
  # look like another dead turn.
  sleep 1
  badges2b="$L/case2b.badges"; : > "$badges2b"
  sampler3="$(watch_badges "$p2" "$badges2b")"
  ask "$p2" 'Say exactly: RECOVERED-OK'
  turn2_ended=1
  approve_until_done "$p2" 300 && turn2_ended=0
  kill "$sampler3" 2>/dev/null; wait "$sampler3" 2>/dev/null
  kill "$FWD" 2>/dev/null; wait "$FWD" 2>/dev/null; FWD=""

  # The sampler's first line is the badge it found on arrival, which is the
  # error left by the dead turn. So the sequence must OPEN with error,working:
  # the very next change out of error is the release, happening where it was
  # designed to, at the start of the next turn.
  seq2="$(tr '\n' ',' < "$badges2b")"
  case "$seq2" in
    error,working*) ok "the next turn releases the error and the pane reports working" ;;
    *)              no "the next turn releases the error and the pane reports working (badges: $seq2)" ;;
  esac
  [ "$turn2_ended" -eq 0 ] \
    && ok "the pane still reaches done on the healthy turn after a dead one" \
    || no "the pane still reaches done on the healthy turn after a dead one (got '$(state "$p2")')"
  case "$(reply "$p2")" in
    *RECOVERED-OK*) ok "the reply channel still works after a dead turn" ;;
    *)              no "the reply channel still works after a dead turn (got '$(reply "$p2")')" ;;
  esac
fi
printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
