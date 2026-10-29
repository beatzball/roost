#!/usr/bin/env bash
# Drive a REAL opencode 2 against a free cloud model and assert the pane badges
# the 2.x adapter (adapters/opencode/v2/tui.js) writes.
#
# NOT part of the suite: this directory is deliberately outside tests/'s flat
# test-*.sh glob, so tests/run.sh cannot pick it up. Run it by hand before any
# release that touches the 2.x adapter, and after any opencode 2 upgrade.
#
#   ROOST_OPENCODE2_BIN=/absolute/path/to/opencode bash tests/live/opencode2-smoke.sh
#
# This is the only script in the repository that runs a real opencode 2, and
# it never runs the `opencode` on PATH. On a machine that keeps 1.x, that is
# the wrong binary; on any machine its default data directory is the user's
# real one, and 1.x and 2.x cannot share a data directory: after 2.0.20 had run
# in a home, 1.18.30 there failed every command with "Database is not empty and
# has no session table" (#150). So the binary is named, it is started by
# absolute path in every pane, and every directory it writes is redirected into
# one temp directory that is checked with `debug paths` before anything starts.
#
# Needs no account: the opencode/* cloud models are built in and free, the
# same tier `roost validate --opencode-cloud` drives. Skips -- never fails --
# if the binary is not named, not executable, or not 2.x.
#
# Isolation: its own tmux socket. The live -L roost server is never contacted.
# And nothing is taken from the caller's environment that could name a real
# directory: a pane inside a roost server carries OPENCODE_CONFIG_DIR, set by
# roost's own wiring for 1.x, and opencode 2 honours it over XDG_CONFIG_HOME --
# so every call of the binary clears it (#150: run from such a pane, the
# `debug paths` check below saw the real wiring directory and refused).
#
# Override the model when the free list changes under you:
#   ROOST_LIVE_MODEL=opencode/<id> ROOST_OPENCODE2_BIN=... bash tests/live/opencode2-smoke.sh
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }

# --- refuse, before anything is created -------------------------------------
# Nothing below this block may run against a binary that has not been named.
# An unset variable is the normal case for anyone who did not ask for this run,
# so it is a SKIP, and it leaves nothing on disk.
[ -n "${ROOST_OPENCODE2_BIN:-}" ] \
  || skip "ROOST_OPENCODE2_BIN is not set; name an opencode 2 binary to drive (the opencode on PATH is never used)"
[ -f "$ROOST_OPENCODE2_BIN" ] && [ -x "$ROOST_OPENCODE2_BIN" ] \
  || skip "ROOST_OPENCODE2_BIN ($ROOST_OPENCODE2_BIN) is not an executable file"
# Absolute, because a pane resolves a relative name against its own directory
# and a bare name against its own PATH -- and a pane's PATH is not the one this
# script was started with (a split pane once lost the temp bin directory and
# ran the real 1.x against the 2.x test directories).
case "$ROOST_OPENCODE2_BIN" in
  /*) BIN="$ROOST_OPENCODE2_BIN" ;;
  *)  BIN="$(cd "$(dirname "$ROOST_OPENCODE2_BIN")" && pwd)/$(basename "$ROOST_OPENCODE2_BIN")" ;;
esac
# macOS ships no timeout(1). perl's alarm survives exec, so the bound reaches
# the binary itself rather than a wrapper around it.
command -v perl >/dev/null 2>&1 || skip "perl is needed to bound the binary's commands"

D="$(mktemp -d /tmp/amx.XXXX)"
# Saved shapes (#191) go under this run's temp dir: saving is always on for a
# real user, so a roost verb here would otherwise write the fleet shape into
# the real ~/.local/state/roost/shapes. Exported before the server starts, so
# its panes inherit it too.
export ROOST_SHAPE_DIR="$D/shapes"
# The socket path MUST end in /roost -- roost state is a no-op on any other
# socket, which is exactly what keeps it safe to wire into global hooks.
S="$D/roost"

# Two sets of the five homes: `main` for every case but one, and `dead` for the
# unreachable-provider case. The dead case needs its own configuration, and on
# 2.x the configuration is read by a background service shared by every
# terminal on the same directories (#150: `serve --service`, ppid 1) -- so a
# second opencode.json under the same homes may never be read by the service
# the first one started. A whole second set of homes gets a service of its own.
#
# But only one service runs at a time. Measured twice by hand on 2.0.22
# (#150): the service is ONE PER USER, not one per set of homes. With the main
# set's `serve --service` alive, a TUI started on the dead set sat at
# "Starting background server..." indefinitely, spawning `serve --service`
# processes that never took over; with no other service alive, the same TUI
# reached its home screen in under 10s. So case 7 stops the main set's service,
# and waits for its process to go, before it starts the dead pane.
HOMESETS="main dead"
homes_env() {  # homes_env SET -> the env assignments that redirect all five
  local h="$D/$1"
  printf 'HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_STATE_HOME=%s TMPDIR=%s' \
    "$h/home" "$h/config" "$h/data" "$h/cache" "$h/state" "$h/tmp"
}
oc() {  # oc SET SECONDS ARGS... -> run the binary on that set's homes, bounded
  local set="$1" t="$2"; shift 2
  # shellcheck disable=SC2046 # homes_env is word-split on purpose: no value holds a space
  # perl, not a shell function: env(1) execs its command and cannot see one.
  # From $D/proj, the directory every pane starts in, so `debug paths` is
  # checked against what the panes will see, not the caller's directory.
  # OPENCODE_CONFIG_DIR is cleared (see the header), not pointed at the set's
  # own config directory: unset is what a user outside roost has, and what the
  # adapter is meant to be proved against. A value of our own would be one more
  # setting no real install writes, whose effect on 2.x beyond `debug paths`
  # was never measured.
  ( cd "$D/proj" && env -u OPENCODE_CONFIG_DIR $(homes_env "$set") perl -e 'alarm shift; exec @ARGV' "$t" "$BIN" "$@" </dev/null )
}
for set in $HOMESETS; do
  for sub in home config/opencode/plugins data cache state tmp; do mkdir -p "$D/$set/$sub"; done
done
mkdir -p "$D/proj"

# Processes of this binary that were running before this script started are
# the human's own, and the leftover check at exit leaves them out.
before="$(pgrep -f -- "$BIN" 2>/dev/null | tr '\n' ' ')"

# Set once the binary has been asked anything that may start its background
# service. `--version` and `debug paths` start none (#150); `models` and the
# TUI do. Until then the trap has nothing to stop.
started=""
# The case-3 badge sampler, while it runs. cleanup kills it, so a die between
# its start and its stop cannot leave it polling a server that is gone.
sampler=""
pass=0; fail=0

# The screens live outside $D so a failure can leave them behind to read: the
# badge that came out is rarely enough to diagnose one, and re-running costs
# minutes of model time. Every case pane's screen is captured as the case closes
# it (close, below), and on a FAIL exit the screen of every pane still open is
# captured too -- so a FAIL in any case keeps that case's screen. A clean run
# deletes them. Made only once the binary is known to be 2.x, so a SKIP leaves
# nothing outside $D.
L=""
keep_logs() {
  [ -n "$L" ] || return 0
  if [ "$fail" -eq 0 ]; then rm -rf "$L"
  else printf '  pane screens kept in %s\n' "$L"; fi
}

# The order matters. The panes go first, because a TUI killed after its service
# would be one more client to reconnect; then the service of each home set;
# then the check that nothing of this binary is left that was not running
# before. That check REPORTS a survivor rather than killing it: the binary may
# be one the human also runs elsewhere on their own data, and a pid matched by
# path is not proof it is ours.
cleanup() {
  local rc=$? set left n=0
  [ -n "$sampler" ] && kill "$sampler" 2>/dev/null
  if [ -n "$L" ] && [ "$fail" -gt 0 ]; then
    for p in $(tmux -S "$S" list-panes -a -F '#{pane_id}' 2>/dev/null); do
      tmux -S "$S" capture-pane -p -t "$p" > "$L/screen-${p#%}.txt" 2>/dev/null
    done
  fi
  tmux -S "$S" kill-server 2>/dev/null
  if [ -n "$started" ]; then
    for set in $HOMESETS; do oc "$set" 20 service stop >/dev/null 2>&1; done
    # A process takes a moment to go after its server says it has stopped.
    ours() { local q; for q in $(pgrep -f -- "$BIN" 2>/dev/null); do
               case " $before " in *" $q "*) ;; *) printf '%s ' "$q" ;; esac; done; }
    while [ "$n" -lt 10 ] && [ -n "$(ours)" ]; do sleep 1; n=$((n+1)); done
    left="$(ours)"
    if [ -n "$left" ]; then
      fail=$((fail+1))
      printf '  FAIL: a process of %s outlived the run (pids: %s) -- left running; check them by hand\n' "$BIN" "$left"
      rc=1
    fi
  fi
  rm -rf "$D"
  keep_logs
  exit "$rc"
}
trap cleanup EXIT

# --- is it 2.x? -------------------------------------------------------------
# Asked with all five directories redirected, because opencode sets up its
# directories before it looks at its arguments: `--version` on 2.0.20 creates
# opencode/ under all four XDG directories and under $TMPDIR, and writes a log
# file (scripts/lib/roost-opencode.sh, roost_opencode_version). The number is
# taken from wherever the first digit is: 1.x prints `1.18.30`, 2.x prints
# `opencode v2.0.20`.
ver="$(oc main 10 --version 2>/dev/null | sed -n '1s/^[^0-9]*\([0-9][0-9.]*\).*/\1/p')"
case "${ver%%.*}" in
  ''|*[!0-9]*) skip "$BIN printed no version; this smoke test drives opencode 2 only" ;;
  0|1) skip "$BIN is opencode $ver; this is the opencode 2 smoke test (for 1.x run tests/live/opencode-smoke.sh)" ;;
esac

# --- does it write only under $D? -------------------------------------------
# `debug paths` prints the directories opencode will use, and starts nothing.
# Every absolute path it prints must be inside $D, in either spelling: macOS's
# /tmp is a symlink, and opencode may print the physical path behind it. No
# path printed at all is a refusal too -- an answer that cannot be checked is
# not a pass.
DP="$(cd "$D" && pwd -P)"
for set in $HOMESETS; do
  paths="$(oc "$set" 10 debug paths 2>/dev/null | grep -o '/[^[:space:]"]*')"
  [ -n "$paths" ] || { printf '  FAIL: `debug paths` printed no path for the %s homes; refusing to start opencode 2\n' "$set"; fail=1; exit 1; }
  outside="$(printf '%s\n' "$paths" | grep -v -e "^$D/" -e "^$DP/")"
  if [ -n "$outside" ]; then
    printf '  FAIL: `debug paths` names a directory outside %s; refusing to start opencode 2:\n' "$D"
    printf '    %s\n' $outside
    fail=1; exit 1
  fi
done

L="$(mktemp -d /tmp/amx-screens.XXXX)"

# --- the model --------------------------------------------------------------
# The first opencode/* model the binary lists, as the brief for this file says,
# unless one is named. The free list is NOT stable -- models come and go
# between runs (scripts/roost-validate, pick_cloud_model) -- so it is resolved
# here rather than pinned. `models` may start the background service.
started=1
if [ -n "${ROOST_LIVE_MODEL:-}" ]; then
  MODEL="$ROOST_LIVE_MODEL"
else
  # Asked up to three times. Measured on 2.0.22 in a fresh home (#150): the
  # FIRST `models` -- the one that starts the background service -- printed
  # nothing and exited 0, and a second call seconds later listed eight
  # opencode/* models. One empty answer is therefore not "no free model".
  # Each try is bounded like every other call, so the worst case is 3 x 60s.
  MODEL=""; try=0
  while [ -z "$MODEL" ] && [ "$try" -lt 3 ]; do
    [ "$try" -gt 0 ] && sleep 3
    MODEL="$(oc main 60 models 2>/dev/null | grep '^opencode/' | head -n 1)"
    try=$((try+1))
  done
fi
[ -n "$MODEL" ] || skip "$BIN lists no free opencode/* model (is the network up?); name one with ROOST_LIVE_MODEL"

# --- the configuration ------------------------------------------------------
# The shell rule is what makes a dialog at all: with no rule, 2.0.20 ran a shell
# command with no dialog, and it asked only after this rule was added under
# `permissions` (#150). Without it the blocked cases would never be set up.
write_config() {  # write_config SET MODEL [PROVIDER-BLOCK]
  cat > "$D/$1/config/opencode/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",${3:+
  $3,}
  "model": "$2",
  "permissions": [ { "action": "shell", "resource": "*", "effect": "ask" } ]
}
JSON
}
write_config main "$MODEL"

# The dead provider is a port picked by binding port 0 and closing it: the
# kernel naming a port that was free a moment ago. If something grabs it in the
# gap the error case fails loudly rather than passing for a wrong reason.
# Without python3, port 1 -- unbindable, therefore permanently dead.
if command -v python3 >/dev/null 2>&1; then
  DEADPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
else
  DEADPORT=1
fi
write_config dead "dead/nothing" '"provider": { "dead": { "npm": "@ai-sdk/openai-compatible", "name": "Nothing listens here", "options": { "baseURL": "http://127.0.0.1:'"$DEADPORT"'/v1" }, "models": { "nothing": { "name": "nothing" } } } }'

# A SYMLINK to the DIRECTORY, the shape roost install writes for 2.x: 2.0.20
# loads `<config>/opencode/plugins/<name>` as a symlink to a directory holding
# tui.js (#150). So this also proves opencode 2 still follows that symlink.
for set in $HOMESETS; do
  ln -s "$HERE/adapters/opencode/v2" "$D/$set/config/opencode/plugins/roost"
done

# --- the server -------------------------------------------------------------
# This script's own `roost` calls run on the main homes too. `roost read` finds
# a pane's kept turns under $XDG_STATE_HOME/roost/panes, where the adapter in
# the pane wrote them; on the real one it would read -- and could create --
# a directory in the human's own home.
# shellcheck disable=SC2046 # word-split on purpose, as in oc
export $(homes_env main)
tmux -S "$S" -f /dev/null new-session -d -x 160 -y 45
tmux -S "$S" source-file "$HERE/tmux/roost.conf"
tmux -S "$S" set-option -g @roost-home "$HERE"
# bin/roost takes its socket from $ROOST_SOCKET; `roost read` below needs it.
export ROOST_SOCKET="$S"

ok()  { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }
# A case the model refused to set up is not an adapter failure: the subagent
# case needs the model to call the subagent tool, and a model sometimes just
# answers instead. That must read as SKIP, not FAIL, or the run cries wolf
# about code that was never exercised.
skipped() { printf '  SKIP: %s\n' "$1"; }

# A readiness timeout is not a badge assertion, so it does not fit ok/no -- it
# means the harness itself could not get set up, and continuing would just send
# input at a TUI that was never listening. Fail loudly and stop.
die() { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; printf '\n  %d passed, %d failed\n' "$pass" "$fail"; exit 1; }

state() { tmux -S "$S" show-options -pqv -t "$1" @agent_state; }
since() { tmux -S "$S" show-options -pqv -t "$1" @agent_since; }
stored() { tmux -S "$S" show-options -pqv -t "$1" @roost-reply; }
screen() { tmux -S "$S" capture-pane -p -t "$1" 2>/dev/null; }
# close PANE -> keep the pane's screen in $L, then kill its window.
close() { screen "$1" > "$L/screen-${1#%}.txt"; tmux -S "$S" kill-window -t "$1" 2>/dev/null; }

# wait_state PANE WANT TIMEOUT -> 0 if the pane reaches WANT in time
wait_state() {
  local p="$1" want="$2" t="$3" n=0
  while [ "$n" -lt "$t" ]; do
    [ "$(state "$p")" = "$want" ] && return 0
    sleep 1; n=$((n+1))
  done
  return 1
}

# wait_dialog PANE TIMEOUT -> 0 once opencode's permission dialog is on screen,
# or once the badge reads blocked.
#
# The screen is a witness the badge cannot be: it is what tells "the adapter
# missed an open dialog" (dialog on screen, badge not blocked: FAIL) apart from
# "the model never made a call that asks" (no dialog at all: SKIP). On 2.0.20
# the dialog still reads `Permission required` (#150). The badge counts too, so
# a dialog whose wording has changed, with the adapter right about it, is not
# read as SKIP -- and left open for the next prompt's Enter to answer.
#
# A `done` gives up early only once the pane has been seen busy: the turn
# before this one left `done` on the badge, and the new prompt takes a moment
# to move it.
wait_dialog() {
  local p="$1" t="$2" n=0 busy="" s
  while [ "$n" -lt "$t" ]; do
    screen "$p" | grep -q 'Permission required' && return 0
    s="$(state "$p")"
    [ "$s" = blocked ] && return 0
    [ "$s" != done ] && busy=1
    [ "$s" = done ] && [ -n "$busy" ] && return 1
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

# wait_ready PANE TIMEOUT -> 0 once the adapter has loaded and the TUI has
# stopped drawing.
#
# The 1.x script waits for a footer string. The 2.x TUI's footer was never
# recorded, so this does not guess one. It waits instead for the adapter's own
# first write -- `setup` writes the pane in full, and on the home screen that
# is `idle` (design §3.3) -- and then for two captures a second apart to match,
# so the prompt is not typed at a TUI still rendering, where it is silently
# dropped. A pane that never reads idle is either an adapter that did not load
# or a TUI that never started; the die message says to read the screen.
wait_ready() {
  local p="$1" t="$2" n=0 a b
  wait_state "$p" idle "$t" || return 1
  a="$(screen "$p")"
  while [ "$n" -lt 30 ]; do
    sleep 1; n=$((n+1))
    b="$(screen "$p")"
    [ -n "$b" ] && [ "$a" = "$b" ] && return 0
    a="$b"
  done
  return 1
}

# watch_badges PANE FILE -> prints the pid of a sampler that appends every
# badge CHANGE to FILE, one per line.
#
# wait_state only proves the pane reached a state; it cannot prove the pane
# never showed a wrong one on the way. Sampling at 0.1s is a net, not a proof,
# but a wrong badge it does catch is real.
watch_badges() {
  ( last=""
    while :; do
      s="$(state "$1")"
      [ "$s" != "$last" ] && { printf '%s\n' "$s" >> "$2"; last="$s"; }
      sleep 0.1
    done ) >/dev/null 2>&1 &
  echo $!
}

# send PANE TEXT -> type a prompt and submit it. The pause before Enter keeps
# the TUI from treating the submit as part of a paste.
send() { tmux -S "$S" send-keys -t "$1" "$2"; sleep 1; tmux -S "$S" send-keys -t "$1" Enter; }

# launch SET -> prints the pane id.
#
# Every variable the binary and the adapter need is on the pane's own command
# line, not inherited: a pane created by a tmux client does not take the
# server's global PATH (a split pane once ran the real 1.x this way), and the
# same goes for anything else this script exported. roost must be on PATH
# inside opencode's process, exactly as it is for a real user whose shell has
# bin/ on PATH -- the adapter runs `roost` by name.
launch() {
  # OPENCODE_CONFIG_DIR is cleared here as in oc, and for the same reason: the
  # tmux server took this script's environment when it started, and a pane
  # may inherit it from there.
  tmux -S "$S" new-window -d -P -F '#{pane_id}' -c "$D/proj" \
    "env -u OPENCODE_CONFIG_DIR $(homes_env "$1") PATH='$HERE/bin:$PATH' ROOST_SOCKET=$S '$BIN'"
}

printf '  opencode %s, model %s\n' "$ver" "$MODEL"

# --- case 1: a plain turn -> done, and the reply via roost read --------------
pa="$(launch main)"
wait_ready "$pa" 90 || die "the pane never read idle and settled (case 1, 90s): the adapter did not load or the TUI never started -- read $L"
send "$pa" 'Reply with exactly this and nothing else: roost-smoke-plain'
if wait_state "$pa" done 120; then ok "a plain turn ends on done"
else no "a plain turn ends on done (got '$(state "$pa")')"; fi
out="$("$HERE/bin/roost" read "$pa" 2>/dev/null)"
case "$out" in
  *roost-smoke-plain*) ok "roost read returns the turn's reply" ;;
  *) no "roost read returns the turn's reply (got '$(printf '%s' "$out" | head -c 200)')" ;;
esac
nm="$(tmux -S "$S" show-options -pqv -t "$pa" @roost-name)"
[ "$nm" = "opencode" ] && ok "the adapter labels its pane opencode" || no "the adapter labels its pane opencode (got '$nm')"

# --- case 2: Esc Esc mid-turn -> done, and no reply -------------------------
# Same pane, right after an answered turn, on purpose: the case is that the
# first answer is not left behind as this turn's reply. On 2.0.20 the first Esc
# shows `esc again to interrupt`, the second ends the turn with
# session.execution.interrupted, reason "user" (#150), and the adapter writes
# an empty reply before done.
send "$pa" 'Write a 3000-word essay on the history of terminal multiplexers. Do not use any tools.'
if wait_state "$pa" working 60; then
  sleep 3
  tmux -S "$S" send-keys -t "$pa" Escape; sleep 0.5; tmux -S "$S" send-keys -t "$pa" Escape
  if wait_state "$pa" done 30; then ok "Esc Esc mid-turn ends the pane on done"
  else no "Esc Esc mid-turn ends the pane on done (got '$(state "$pa")')"; fi
  "$HERE/bin/roost" read "$pa" > "$L/esc.out" 2> "$L/esc.err"
  if grep -q "no recorded reply" "$L/esc.err"; then ok "after Esc Esc, roost read says there is no reply"
  else no "after Esc Esc, roost read says there is no reply (stderr '$(head -c 200 "$L/esc.err")', stored '$(stored "$pa" | head -c 80)')"; fi
else
  no "the essay turn reaches working (got '$(state "$pa")')"
fi

# --- case 3: two panes -> pane A's badge does not move while B runs ----------
# Every terminal hears every chat (#150, design §2.2): B's whole turn is
# delivered to A's plugin too. A must not badge it. The stamp and the stored
# reply are checked as well as the sampled badge, because a `done` re-stamped
# over `done` is a write the badge alone would not show.
# The sampler starts before B does: a terminal starting up is itself a burst of
# events every other terminal hears.
a_since="$(since "$pa")"; a_reply="$(stored "$pa")"
badges="$L/case3.badges"; : > "$badges"
sampler="$(watch_badges "$pa" "$badges")"
pb="$(launch main)"
wait_ready "$pb" 90 || die "the pane never read idle and settled (case 3, pane B, 90s) -- read $L"
send "$pb" 'Reply with exactly this and nothing else: roost-smoke-pane-b'
wait_state "$pb" done 120 || no "pane B's turn ends on done (got '$(state "$pb")')"
sleep 2   # past a timer tick in A, so a tick that wrongly writes has had its chance
kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null; sampler=""
seq3="$(tr '\n' ',' < "$badges")"
[ "$seq3" = "done," ] && ok "pane A's badge holds while pane B runs a turn" \
  || no "pane A's badge holds while pane B runs a turn (A's badges: $seq3)"
[ "$(since "$pa")" = "$a_since" ] && [ "$(stored "$pa")" = "$a_reply" ] \
  && ok "pane A is not re-stamped and its stored reply is untouched" \
  || no "pane A is not re-stamped and its stored reply is untouched (since $a_since -> $(since "$pa"))"
close "$pb"

# --- case 4: a shell call -> blocked while the dialog is up, done after Allow
send "$pa" 'Use the shell tool to run exactly: echo roost-smoke-shell'
if wait_dialog "$pa" 120; then
  if wait_state "$pa" blocked 5; then ok "the pane reads blocked while the permission dialog is up"
  else no "the pane reads blocked while the permission dialog is up (got '$(state "$pa")')"; fi
  tmux -S "$S" send-keys -t "$pa" Enter    # "Allow once" is the default
  if approve_until_done "$pa" 120; then ok "the pane reaches done after the dialog is allowed"
  else no "the pane reaches done after the dialog is allowed (got '$(state "$pa")')"; fi
else
  skipped "no permission dialog appeared, so the model never made a shell call that asks (badge '$(state "$pa")')"
  wait_state "$pa" done 60 >/dev/null
fi

# --- case 5: a subagent's shell call -> blocked, then done with the parent's reply
# The child is its own session; its dialog is drawn in the parent's terminal
# and its events carry the child's id (design §2.4). The adapter finds it
# through family(front), so the badge must read blocked all the same. The
# child's own prose and its execution.succeeded come before the parent's, and
# neither may end the pane's turn or become its reply -- the parent's closing
# line is what `roost read` must return.
send "$pa" "Use the subagent tool to start the 'general' subagent. Its prompt must be: Use the shell tool to run exactly: echo roost-smoke-child, then report its output. After the subagent finishes, reply with exactly: roost-smoke-parent followed by what it printed."
if wait_dialog "$pa" 180; then
  if wait_state "$pa" blocked 5; then ok "the pane reads blocked while a subagent's dialog is up"
  else no "the pane reads blocked while a subagent's dialog is up (got '$(state "$pa")')"; fi
  tmux -S "$S" send-keys -t "$pa" Enter
  if approve_until_done "$pa" 240; then ok "the pane reaches done when the parent's turn ends"
  else no "the pane reaches done when the parent's turn ends (got '$(state "$pa")')"; fi
  out="$("$HERE/bin/roost" read "$pa" 2>/dev/null)"
  case "$out" in
    *roost-smoke-parent*) ok "roost read returns the parent's reply, not the subagent's" ;;
    *) no "roost read returns the parent's reply, not the subagent's (got '$(printf '%s' "$out" | head -c 200)')" ;;
  esac
else
  skipped "no permission dialog appeared, so the model never had the subagent make a shell call (badge '$(state "$pa")')"
fi
close "$pa"

# --- case 6: one terminal, two finished chats, alt+down only ----------------
# The only live check of the adapter's 1-second timer. Switching the front tab
# emits no event at all on 2.0.20 (#150, design §2.2), so whatever changes on
# the pane after M-Down was written by a timer pass that noticed the route
# changed. Both chats have finished, so the state written is `done` either way:
# the change is the stamp (@agent_since, rewritten by every state write) and
# the stored reply, which a front change clears (design §3.3). The stamp is in
# whole seconds, hence the sleep before the switch.
pt="$(launch main)"
wait_ready "$pt" 90 || die "the pane never read idle and settled (case 6, 90s) -- read $L"
send "$pt" 'Reply with exactly this and nothing else: roost-smoke-alpha'
wait_state "$pt" done 120 || no "the first chat's turn ends on done (got '$(state "$pt")')"
# How a second chat is opened in one 2.x terminal was not recorded (the tabs
# recording starts the second chat from a prompt, the keys are not in it).
# `/new` is the 1.x command. The front leaving the first chat is the signal it
# worked: the adapter writes idle on the home screen.
send "$pt" '/new'
if ! wait_state "$pt" idle 15; then
  skipped "\`/new\` did not open a new chat in this opencode (badge '$(state "$pt")'), so there are not two chats to switch between"
else
  sleep 2
  send "$pt" 'Reply with exactly this and nothing else: roost-smoke-bravo'
  wait_state "$pt" done 120 || no "the second chat's turn ends on done (got '$(state "$pt")')"
  t_since="$(since "$pt")"; t_reply="$(stored "$pt")"; t_screen="$(screen "$pt")"
  sleep 2
  tmux -S "$S" send-keys -t "$pt" M-Down
  n=0; moved=""
  while [ "$n" -lt 30 ]; do   # 3 seconds, in tenths
    if [ "$(stored "$pt")" != "$t_reply" ] && [ "$(since "$pt")" != "$t_since" ]; then moved=1; break; fi
    sleep 0.1; n=$((n+1))
  done
  if [ -n "$moved" ]; then
    ok "after alt+down alone, the badge is re-stamped and the stored reply cleared within 3s"
  elif [ "$(screen "$pt")" = "$t_screen" ]; then
    skipped "alt+down did not change the chat on screen, so there was no switch to see"
  else
    no "after alt+down alone, the badge is re-stamped and the stored reply cleared within 3s (since $t_since -> $(since "$pt"), reply '$(printf '%s' "$t_reply" | head -c 40)' -> '$(stored "$pt" | head -c 40)')"
  fi
fi
close "$pt"

# --- case 7: a provider on a closed port -> error ---------------------------
# Its own homes and therefore its own service, once the main set's has gone
# (see HOMESETS). On 2.0.20 a dead
# provider gives retry.scheduled attempts 2..11 over about 87s, then
# execution.failed; the adapter reads error from attempt 3 (design §2.3).
#
# The main set's service is stopped first, because only one runs per user (see
# HOMESETS). The wait is for the process, not the command: a process takes a
# moment to go after its server says it has stopped, as in cleanup. Bounded at
# 30s, and nothing is killed -- if one remains, wait_ready below dies with the
# screen kept, which is the evidence. cleanup's own `service stop` for both
# sets still runs at exit.
oc main 30 service stop >/dev/null 2>&1
# Only pids not in $before, as in cleanup's ours(): a service that was running
# before this script started is the human's own, so it is neither waited on
# nor named in the line below -- that line must only ever name one of ours.
services() { local q; for q in $(pgrep -f -- "$BIN" 2>/dev/null); do
               case " $before " in *" $q "*) continue ;; esac
               case "$(ps -o args= -p "$q" 2>/dev/null)" in *"serve --service"*) printf '%s ' "$q" ;; esac; done; }
n=0
while [ "$n" -lt 30 ] && [ -n "$(services)" ]; do sleep 1; n=$((n+1)); done
[ -z "$(services)" ] || printf '  a serve --service of %s is still running after 30s (pids: %s); starting the dead pane anyway\n' "$BIN" "$(services)"
pd="$(launch dead)"
wait_ready "$pd" 90 || die "the pane never read idle and settled (case 7, 90s) -- read $L"
send "$pd" 'Write a haiku about tmux.'
if wait_state "$pd" error 120; then ok "an unreachable provider drives the pane to error"
else no "an unreachable provider drives the pane to error (got '$(state "$pd")')"; fi
close "$pd"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
