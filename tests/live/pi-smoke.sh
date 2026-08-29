#!/usr/bin/env bash
# Drive REAL pi against a local model and assert the pane badges.
#
# NOT part of the suite: this directory is deliberately outside tests/'s flat
# test-*.sh glob, so tests/run.sh cannot pick it up. Run it by hand before
# merging adapter changes, and after any pi upgrade.
#
#   bash tests/live/pi-smoke.sh
#
# Needs pi and a local ollama serving a tool-capable model. NO account and no
# quota: PI_CODING_AGENT_DIR points pi at a scratch config directory holding a
# single ollama provider, so the real ~/.pi is neither read nor written and no
# stored credential is reachable. PI_OFFLINE and PI_SKIP_VERSION_CHECK turn off
# the remaining network paths. Skips -- never fails -- if pi or the model is
# missing.
#
# Isolation: its own tmux socket. The live -L roost server is never contacted.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
# Same default, and the same reasoning, as tests/live/opencode-smoke.sh:
# granite4.2:3b is 2.2 GB, and this is the one test a contributor has to pull a
# model to run at all. Checked for fitness here too -- it echoes exact text and
# it calls the bash tool.
#
# Override for a bigger model when the ANSWER matters rather than the plumbing:
#   ROOST_LIVE_MODEL=ornith-1.5:35b bash tests/live/pi-smoke.sh
MODEL="${ROOST_LIVE_MODEL:-granite4.2:3b}"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }
command -v pi     >/dev/null 2>&1 || skip "pi not installed"
command -v ollama >/dev/null 2>&1 || skip "ollama not installed"
curl -s -m 5 http://localhost:11434/api/tags >/dev/null 2>&1 \
  || skip "ollama is not responding on :11434"
ollama list 2>/dev/null | grep -q "^${MODEL} " \
  || skip "model $MODEL not pulled (override with ROOST_LIVE_MODEL)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }
# A case the local model refused to set up is not an adapter failure. The
# permission case needs the model to actually call the bash tool; a small local
# model sometimes answers directly instead. That must read as SKIP, not FAIL, or
# the suite cries wolf about code that was never exercised.
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
cleanup() {
  [ -n "$FWD" ] && kill "$FWD" 2>/dev/null
  tmux -S "$S" kill-server 2>/dev/null
  # pi writes session files under PI_CODING_AGENT_DIR right up to the moment it
  # dies, so tearing the server down and deleting the tree in the same breath
  # races it: rm walks a directory, pi writes one more file into it, and rm
  # exits "Directory not empty" on a run where every assertion passed.
  sleep 1
  rm -rf "$D"
  keep_logs
}
trap cleanup EXIT

# pi does NOT use the XDG directories. PI_CODING_AGENT_DIR is the one override
# (docs/usage.md's environment table), defaulting to ~/.pi/agent, and it covers
# settings, provider config, auth and the extension directory this test installs
# into. AGENTS.md 8's rule -- find the harness's OWN home variable, do not
# assume the XDG one -- applies here exactly as it does to copilot's
# COPILOT_HOME.
#
# Two config dirs: one healthy, one pointed at a port with nothing on it. They
# have to be separate directories rather than one edited in place, because pi
# resolves its provider at startup.
mk_home() {  # mk_home <dir> <baseUrl>
  mkdir -p "$1/extensions"
  cat > "$1/models.json" <<JSON
{ "providers": { "ollama": {
    "baseUrl": "$2", "api": "openai-completions", "apiKey": "ollama",
    "models": [{ "id": "$MODEL" }] } } }
JSON
  printf '{ "defaultProvider": "ollama", "defaultModel": "%s" }\n' "$MODEL" > "$1/settings.json"
  # SYMLINKS, matching how a user installs the adapter -- so this also proves pi
  # still follows one when discovering extensions.
  ln -s "$HERE/adapters/pi/roost.ts"        "$1/extensions/roost.ts"
  # Second extension: records the raw event stream the adapter is reacting to.
  # The badge assertions say WHAT the pane showed; the log is the only thing
  # that says why.
  ln -s "$HERE/tests/live/pi-event-log.ts"  "$1/extensions/zz-event-log.ts"
}

# The gate is installed only where `blocked` is being exercised. pi ships no
# permission prompts of its own, so without one there is no dialog anywhere in
# this file -- and installing it everywhere would put a confirm in front of
# every bash call in every case, including the ones about `error`.
#
# It is named a*.ts so pi loads it BEFORE roost.ts: that is the harder ordering,
# and the one that proves the adapter sees a dialog raised by an extension that
# was already there rather than one that arrived after it.
add_gate() { ln -s "$HERE/tests/live/pi-gate.ts" "$1/extensions/a-gate.ts"; }

mkdir -p "$D/proj"
mk_home "$D/pi-ok"   "http://localhost:11434/v1"
add_gate "$D/pi-ok"

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

# watch_badges PANE FILE -> prints the pid of a sampler that appends every badge
# CHANGE to FILE, one per line.
#
# wait_state only proves the pane reached a state; it cannot prove the pane
# never showed a wrong one on the way. The retry bug is exactly that shape: an
# adapter wired to agent_end stamps `done` between attempts and corrects it a
# second later. Sampling at 0.1s cannot catch every such window -- it is a net,
# not a proof -- but a `done` it does catch mid-turn is real, and the fix makes
# the net stay empty.
watch_badges() {
  ( last=""
    while :; do
      s="$(state "$1")"
      [ "$s" != "$last" ] && { printf '%s\n' "$s" >> "$2"; last="$s"; }
      sleep 0.1
    done ) >/dev/null 2>&1 &
  echo $!
}

# ROOST_SOCKET is belt AND braces here, and it is still not something a real
# user sets: $S ends in /roost, so scripts/lib/roost-socket.sh resolves this
# server on its own for both halves of the contract. It stays because an
# explicit seam is what the rest of the suite uses --
# tests/test-reply-socket.sh is what holds the unset case honest.
launch() {  # launch <logname> <pihome> -> prints the pane id
  tmux -S "$S" new-window -d -P -F '#{pane_id}' -c "$D/proj" \
    "PATH=$HERE/bin:\$PATH ROOST_SOCKET=$S ROOST_EVENT_LOG=$L/$1.jsonl \
     PI_CODING_AGENT_DIR=$2 PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 pi"
}

# Sets the global PANE rather than printing the id, so that `die` inside it
# actually stops the script. Called through $( ), every die would run in a
# subshell: the script would carry on with an EMPTY pane id, and every command
# after it would fail with tmux's own "can't find session:" against a target
# that is the empty string.
PANE=""
start_pane() {  # start_pane <logname> <pihome> -> sets PANE
  PANE="$(launch "$1" "$2" 2>&1)"
  case "$PANE" in
    %[0-9]*) : ;;
    *) die "could not open a pi window ($1): ${PANE:-tmux printed nothing}" ;;
  esac
  # pi asks to trust a project only when it finds project-local config to load.
  # $D/proj is empty, so it normally does not -- but answering it if it appears
  # costs one screen check and stops a future pi default silently hanging every
  # case after this one.
  if wait_screen "$PANE" "Trust" 5; then
    tmux -S "$S" send-keys -t "$PANE" Enter; sleep 2
  fi
  # Then wait for the prompt box itself. A fixed sleep is long enough on an idle
  # machine and not on one loaded by repeated model runs: the prompt gets typed
  # at a TUI that has not rendered yet and is silently dropped, so the pane never
  # leaves its empty state and the failure reads as an adapter regression.
  # "ctrl+o more" is part of pi's header and is present once the TUI is live.
  wait_screen "$PANE" "ctrl+o" 60 || die "pi's TUI never became interactive ($1, waited 60s for the ctrl+o header line)"
}

ask() {  # ask <pane> <prompt>
  tmux -S "$S" send-keys -t "$1" "$2"; sleep 1
  tmux -S "$S" send-keys -t "$1" Enter
}

# --- case 1: a plain turn, and the reply channel -----------------------------
start_pane case1 "$D/pi-ok"; p="$PANE"

# session_start reports nothing on purpose: `idle` is a default, not a report,
# and an unstamped pane already renders as idle. A pane that badged itself at
# startup would also be a pane `roost wait-done` could block on before its first
# turn.
[ -z "$(state "$p")" ] \
  && ok "a pane that has not been asked to do anything stays unbadged" \
  || no "a pane that has not been asked to do anything stays unbadged (got '$(state "$p")')"

ask "$p" 'Say exactly: PLUM-ONE'
if wait_state "$p" working 90; then ok "pane reaches working when the turn starts"
else no "pane reaches working when the turn starts (got '$(state "$p")')"; fi
if wait_state "$p" done 240; then ok "pane reaches done when the turn ends"
else no "pane reaches done when the turn ends (got '$(state "$p")')"; fi

# The point of the whole reply channel: `roost read` returns what the agent
# SAID, not what is on its screen. pi is a full-screen TUI whose last lines are
# an input box, a cwd line and a token counter, so a scrape returns furniture.
case "$(reply "$p")" in
  *PLUM-ONE*) ok "the agent's answer is published to @roost-reply" ;;
  "")         no "the agent's answer is published to @roost-reply (nothing was recorded)" ;;
  *)          no "the agent's answer is published to @roost-reply (got '$(reply "$p")')" ;;
esac

# The model's reasoning arrives in the same parts array as its answer, as a
# `thinking` part -- granite4.2:3b produces one on every turn. Publishing it
# would post the model's thinking as its answer.
case "$(reply "$p")" in
  *"The user"*|*"I need to"*|*"Let me"*)
    no "the model's thinking was published as its answer (got '$(reply "$p")')" ;;
  *)  ok "the model's thinking part is not in the published reply" ;;
esac

# The adapter must also label the pane, so the border stops showing a version
# string -- same gap the Claude hook fills. It must read "pi", not
# roost-agent-state's Claude-flavoured "claude" default. pi has no better
# fallback of its own: its process name is `node`.
nm="$(tmux -S "$S" show-options -pqv -t "$p" @roost-name)"
[ "$nm" = "pi" ] && ok "the adapter labels its pane pi" || no "the adapter labels its pane pi (got '$nm')"

# --- case 1p: a permission dialog must badge blocked -------------------------
# pi ships NO permission prompts, so this case only exists because
# tests/live/pi-gate.ts is installed in this pi home -- a stand-in for the gate
# a user would bring themselves. That is the honest shape of the claim: roost
# can see a dialog, and on a stock pi there is none to see.
#
# The gate is a SEPARATE extension, loaded before the adapter. What is being
# proved is that pi hands every extension the same ctx.ui object, so the
# adapter's wrap catches a dialog it did not raise.
badges1p="$L/case1p.badges"; : > "$badges1p"
sampler1p="$(watch_badges "$p" "$badges1p")"
ask "$p" 'Use the bash tool to run exactly: echo MANGO'
if wait_state "$p" blocked 240; then
  ok "pane reaches blocked at another extension's permission dialog"
  # And the dialog is still the human's to answer. The adapter wraps ctx.ui and
  # returns whatever the original returned; if roost had answered it, this text
  # would already be gone.
  tmux -S "$S" capture-pane -p -t "$p" | grep -q "Run bash?" \
    && ok "the dialog is still on screen for the human to answer -- roost observed it, it did not decide it" \
    || no "the dialog is still on screen for the human to answer -- roost observed it, it did not decide it"
  tmux -S "$S" send-keys -t "$p" Enter
  if wait_state "$p" done 300; then ok "answering the dialog releases the pane to done"
  else no "answering the dialog releases the pane to done (got '$(state "$p")')"; fi
else
  # The model answered instead of calling bash, so no dialog was raised and
  # nothing about `blocked` was exercised. Not a failure.
  skipped "the model never called the bash tool, so no permission dialog appeared"
  wait_state "$p" done 180 >/dev/null 2>&1
fi
kill "$sampler1p" 2>/dev/null; wait "$sampler1p" 2>/dev/null
# The release goes back to working, never straight to done: a dialog is answered
# in the middle of a turn that still has a tool to run and an answer to give.
case "$(tr '\n' ',' < "$badges1p")" in
  *blocked,working*) ok "answering the dialog puts the pane back on working, not straight on done" ;;
  *blocked*)         no "the pane left blocked for something other than working (badges: $(tr '\n' ',' < "$badges1p"))" ;;
  *)                 skipped "no dialog was raised, so the release path was not exercised" ;;
esac

# --- case 1r: /reload must not leave the badge to a dead instance ------------
# pi's ctx.ui is ONE object shared by every extension AND reused across a
# /reload, while the extension instances themselves are rebuilt. Measured on
# 0.81.1: a naive wrap stacks, so one dialog produces two `roost state blocked`
# calls, and the mirror bug -- a plain "already wrapped, skip" flag -- leaves
# the surviving wrapper talking to the SHUT-DOWN instance, after which `blocked`
# never fires again. The offline harness pins both directions; this proves the
# live one still walks the whole cycle after a reload.
#
# There is no screen marker to wait on here: pi's header scrolls off once a turn
# has run, so the "ctrl+o" line start_pane waits for is in the scrollback rather
# than on screen. Reaching `working` IS the readiness check, and it is a real
# assertion rather than a preamble -- a reload that left the badge to the
# shut-down instance would stop here.
ask "$p" '/reload'
sleep 10
ask "$p" 'Use the bash tool to run exactly: echo PLUM-TWO'
if wait_state "$p" working 180; then
  ok "the pane still badges working after a /reload"
  if wait_state "$p" blocked 240; then
    ok "the dialog still badges blocked after a /reload -- the wrap talks to the live instance, not the shut-down one"
    tmux -S "$S" send-keys -t "$p" Enter
    if wait_state "$p" done 300; then ok "and the pane still reaches done after a /reload"
    else no "and the pane still reaches done after a /reload (got '$(state "$p")')"; fi
  else
    # Only the model's choice of tool is a skip. Everything above it was
    # asserted.
    skipped "the model never called the bash tool after the reload, so the dialog path was not re-exercised"
    wait_state "$p" done 180 >/dev/null 2>&1
  fi
else
  no "the pane stopped badging after a /reload (got '$(state "$p")')"
fi

# --- case 1s: a sub-agent's own pi process must not badge this pane ----------
# pi has no built-in sub-agents, but its shipped examples/extensions/subagent/
# implements them by spawning `pi --mode json -p --no-session`. A child inherits
# $TMUX_PANE and loads the same GLOBAL extensions, so an ungated adapter badges
# its PARENT'S pane -- working when the child starts, done when it finishes,
# while the parent is still working -- and publishes the child's answer as the
# pane's reply. That is spec 5 T1, in two OS processes instead of one.
#
# Running the child by hand rather than through the example extension is
# deliberate: it is the same command that example runs, with none of its
# scaffolding, so what is being tested is the adapter and not the example.
before_state="$(state "$p")"
before_reply="$(reply "$p")"
( cd "$D/proj" && PATH="$HERE/bin:$PATH" ROOST_SOCKET="$S" ROOST_EVENT_LOG="$L/child.jsonl" \
  PI_CODING_AGENT_DIR="$D/pi-ok" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 \
  pi --mode json -p --no-session 'Say exactly: CHILD-ANSWER' >"$L/child.out" 2>&1 )
if grep -q '"hasUI":false' "$L/child.jsonl" 2>/dev/null; then
  [ "$(state "$p")" = "$before_state" ] \
    && ok "a sub-agent's own pi process leaves the parent pane's badge alone" \
    || no "a sub-agent's own pi process changed the parent pane's badge ('$before_state' -> '$(state "$p")')"
  [ "$(reply "$p")" = "$before_reply" ] \
    && ok "...and does not publish its own answer as the pane's reply" \
    || no "...and does not publish its own answer as the pane's reply (got '$(reply "$p")')"
else
  skipped "the child pi never started, so the sub-agent guard was not exercised"
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
# No gate on this home: `error` is about the provider, and a confirm in the way
# would only add a dialog for the model to never reach.
mk_home "$D/pi-dead" "http://127.0.0.1:$DEADPORT/v1"
start_pane case2 "$D/pi-dead"; p2="$PANE"

badges2="$L/case2.badges"; : > "$badges2"
sampler2="$(watch_badges "$p2" "$badges2")"
ask "$p2" 'Write a haiku about tmux.'
if wait_state "$p2" error 180; then ok "an unreachable provider drives the pane to error"
else no "an unreachable provider drives the pane to error (got '$(state "$p2")')"; fi

# pi retries a dead provider four times, and each attempt is a full
# agent_start/turn_start/message_end/agent_end cycle -- measured on 0.81.1. Only
# agent_settled fires once, at the true end. An adapter wired to agent_end would
# have stamped `done` three times on the way here, each corrected a second
# later, and a wrong `done` is the worst wrong badge there is: every other one
# makes you look, and this one makes you stop looking.
#
# Give it a moment to be overwritten before checking, or a fix that does not
# work still passes because the wrong write has not landed yet.
sleep 15
kill "$sampler2" 2>/dev/null; wait "$sampler2" 2>/dev/null
b2="$(state "$p2")"
[ "$b2" = "error" ] \
  && ok "the pane is still on error after the retries have finished" \
  || no "the pane is still on error after the retries have finished (final badge '$b2'; badges: $(tr '\n' ',' < "$badges2"))"
case "$(tr '\n' ',' < "$badges2")" in
  *done*) no "the pane flashed done during a turn that died (badges: $(tr '\n' ',' < "$badges2"))" ;;
  *)      ok "the pane never showed done at any point in the dead turn" ;;
esac
# The retries must be ONE working, not four. Anything wired per attempt shows up
# here as working,error,working,error,...
case "$(tr '\n' ',' < "$badges2")" in
  *working,error,working*) no "the badge flapped between attempts (badges: $(tr '\n' ',' < "$badges2"))" ;;
  *)                       ok "four provider retries produced one working and one error, not four of each" ;;
esac

# --- case 2b: the pane must still reach done on the next healthy turn --------
# The other half, and the half worth the model time: a badge stuck on error
# forever is worse than the wrong done it replaced. Same pane and same pi
# process, so the adapter instance holding the state is the one that just badged
# error -- a fresh pane would prove nothing about it.
#
# The provider comes back by putting a forwarder on the port pi is already
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
  wait_state "$p2" done 300 && turn2_ended=0
  kill "$sampler3" 2>/dev/null; wait "$sampler3" 2>/dev/null
  kill "$FWD" 2>/dev/null; wait "$FWD" 2>/dev/null; FWD=""

  # The sampler's first line is the badge it found on arrival, which is the
  # error left by the dead turn. So the sequence must OPEN with error,working:
  # the very next change out of error is the next turn's own agent_start.
  seq2="$(tr '\n' ',' < "$badges2b")"
  case "$seq2" in
    error,working*) ok "the next turn leaves the error behind and the pane reports working" ;;
    *)              no "the next turn leaves the error behind and the pane reports working (badges: $seq2)" ;;
  esac
  [ "$turn2_ended" -eq 0 ] \
    && ok "the pane still reaches done on the healthy turn after a dead one" \
    || no "the pane still reaches done on the healthy turn after a dead one (got '$(state "$p2")')"
  case "$(reply "$p2")" in
    *RECOVERED-OK*) ok "the reply channel still works after a dead turn" ;;
    *)              no "the reply channel still works after a dead turn (got '$(reply "$p2")')" ;;
  esac
fi

# --- case 3: the human pressing Esc is not a crash ---------------------------
# stopReason "aborted" arrives in the same field as "error". Badging it error
# fires a desktop notification about someone's own keystroke and calls it a
# crash; spec 1 settles this the same way for opencode's MessageAbortedError.
badges3="$L/case3.badges"; : > "$badges3"
sampler4="$(watch_badges "$p" "$badges3")"
ask "$p" 'Write a very long essay about tmux, at least 2000 words.'
if wait_state "$p" working 90; then
  sleep 6
  tmux -S "$S" send-keys -t "$p" Escape
  if wait_state "$p" done 120; then ok "pressing Esc mid-turn ends the pane on done"
  else no "pressing Esc mid-turn ends the pane on done (got '$(state "$p")')"; fi
  kill "$sampler4" 2>/dev/null; wait "$sampler4" 2>/dev/null
  case "$(tr '\n' ',' < "$badges3")" in
    *error*) no "the pane badged error for a turn the human ended themselves (badges: $(tr '\n' ',' < "$badges3"))" ;;
    *)       ok "the pane never badged error for a turn the human ended themselves" ;;
  esac
else
  kill "$sampler4" 2>/dev/null; wait "$sampler4" 2>/dev/null
  skipped "the abort turn never started, so the abort path was not exercised"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
