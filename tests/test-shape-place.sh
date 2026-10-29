#!/usr/bin/env bash
# Placement (#51, #191): the placeholder a placed pane runs, and `roost
# restore` putting a saved shape back as shells. Design:
# docs/airig/specs/2026-10-24-persistent-sessions-design.md §4.3 (placement),
# §4.7 (the placeholder and who owns a pane), §2.10 (what it rests on).
#
# "A shell started in this pane" is read from $HOME/shells.log, which the
# redirected HOME's .bash_profile and .bashrc append to (tests/lib-shape.sh),
# never from #{pane_current_command}: on macOS that reads `bash` for the
# placeholder too (§2.10).
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
shape_test_setup; trap shape_test_teardown EXIT
HERE="$PWD"
PH="$HERE/scripts/roost-placeholder"
# A bash the handover can start, so the rc files above run in it. The server's
# default-shell otherwise comes from the developer's $SHELL (zsh here), which
# reads neither file.
BASH_BIN="$(command -v bash)"
TL set -g default-shell "$BASH_BIN"
# A server restore starts takes its default-shell from $SHELL; bash, so a
# shell it hands over reads the rc files above too.
export SHELL="$BASH_BIN"

# wait_screen PANE TEXT [TENTHS] — until TEXT is on the pane's screen.
wait_screen() {
  local i=0 n="${3:-20}"
  while [ "$i" -lt "$n" ]; do
    TL capture-pane -p -t "$1" 2>/dev/null | grep -qF -- "$2" && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}
# boot_file [SUFFIX] -> the run's bootstrap file with SUFFIX (.used, .taken),
# or nothing. Each run's names carry its own token (bootstrap.<run>), so the
# tests find them by pattern.
boot_file() { ls -d "$SD/restoring/"bootstrap.*"${1:-}" 2>/dev/null | head -1; }
# wait_boot SUFFIX [TENTHS] — until boot_file SUFFIX exists.
wait_boot() { local i=0 n="${2:-30}"; while [ "$i" -lt "$n" ]; do [ -n "$(boot_file "$1")" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
# wait_file PATH [TENTHS] — until PATH exists.
wait_file() { local i=0 n="${2:-30}"; while [ "$i" -lt "$n" ]; do [ -e "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
# shells_wait PANE — until shells.log has a line for PANE (3 s).
shells_wait() { local i=0; while [ "$i" -lt 30 ]; do [ -n "$(shells_for "$1")" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
PLACING='roost restore is placing this session - press any key for a shell'
CLAIMED='roost restore is placing this pane'
RD="$SHAPE_TMP/restoring"; mkdir -p "$RD"
# placeholder FILE -> a new pane running the placeholder by its own path, as argv.
placeholder() {
  local p
  p="$(TL new-window -d -P -F '#{pane_id}' -t shp: 'sleep 600')"
  TL set -p -t "$p" remain-on-exit failed
  TL respawn-pane -k -t "$p" "$PH" "$1" --placing
  printf '%s\n' "$p"
}

echo "== the placing placeholder (Task 1.11) =="
F="$RD/place.1"; : > "$F"
p="$(placeholder "$F")"
wait_screen "$p" "$PLACING"; assert_true $? "within 2 s the screen shows the placing line"
assert_eq "$(shells_for "$p")" "" "no shell has started in it"
pid="$(TL display -p -t "$p" '#{pane_pid}')"
TL send-keys -t "$p" x
wait_file "$F.taken"; assert_true $? "one key: the placeholder wins F -> F.taken"
[ ! -e "$F" ]; assert_true $? "...F is gone"
shells_wait "$p"; assert_eq "$(shells_for "$p" | wc -l | tr -d ' ')" "1" "...and a shell started in the pane (one shells.log line)"
assert_eq "$(TL display -p -t "$p" '#{pane_pid}')" "$pid" "...in the same process: the placeholder exec'd it"
assert_eq "$(TL show -pqv -t "$p" remain-on-exit)" "" "remain-on-exit is unset on the pane after a winning key"

F="$RD/place.2"; : > "$F"
p="$(placeholder "$F")"
wait_screen "$p" "$PLACING"
mv "$F" "$F.used"     # restore won T2 first
TL send-keys -t "$p" x
wait_screen "$p" "$CLAIMED"; assert_true $? "F.used first, then a key: the screen says restore is placing this pane"
sleep 1
assert_eq "$(shells_for "$p")" "" "...no shell started (never a shell after a lost rename)"
[ -e "$F.used" ] && [ ! -e "$F.taken" ]; assert_true $? "...and F.used is still there"

F="$RD/place.3"; : > "$F"
p="$(placeholder "$F")"
wait_screen "$p" "$PLACING"
TL send-keys -t "$p" -l 'echo keep-me'; TL send-keys -t "$p" C-a
shells_wait "$p"; sleep 0.5
TL send-keys -t "$p" -l 'echo LINE-WAS-['; TL send-keys -t "$p" C-e; TL send-keys -t "$p" -l ']'; TL send-keys -t "$p" Enter
wait_screen "$p" 'LINE-WAS-[]' 30; assert_true $? "typed text then C-a: the first byte ends the wait and the rest is thrown away (an empty line)"
TL capture-pane -p -t "$p" | grep -q 'keep-me'; assert_eq "$?" "1" "...keep-me never reached the shell"

F="$RD/place.4"; : > "$F"
TL set -g default-command 'exec /bin/sh'
p="$(placeholder "$F")"
wait_screen "$p" "$PLACING"
TL send-keys -t "$p" x
wait_file "$F.taken"; sleep 0.5
assert_eq "$(ps -o args= -p "$(TL display -p -t "$p" '#{pane_pid}')" | sed 's/^ *//')" "/bin/sh" \
  "a user's own default-command: the key hands over to it (exec, read at that moment)"
TL set -gu default-command

# --- restore: server, sessions, the bootstrap (Task 1.12) ---------------------
# `roost wiring apply` runs when restore starts a server, and writes under
# XDG_CONFIG_HOME: a temp dir here, not the canary (tests/lib-shape.sh points
# it at the canary only because no earlier case starts a roost server).
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
ROOST="$HERE/bin/roost"
R() { ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"; mkdir -p "$SD"
# mkshape NAME:CWD ... -> a shape at $SD/shape with one session per argument,
# each one window (index 1) of one pane (index 0) in CWD, 200x50.
mkshape() {
  local a n=0
  { printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" 'boot 1-1' \
      'saved 2026-10-28T12:00:00Z' 'gen 1' 'trigger save' 'roost 0.10.0' 'tmux 3.6' 'host h' ''
    for a in "$@"; do
      printf '%s\n' "session ${a%%:*}" "id \$$n" '' "window ${a%%:*}:1" "id @$n" \
        "layout b25d,200x50,0,0,$n" 'active 1' '' "pane ${a%%:*}:1.0" "id %$n" "cwd ${a#*:}" ''
      n=$((n+1))
    done; } > "$SD/shape"
}
# server_pid — the test server's pid, empty when it is not running.
server_pid() { TL display -p '#{pid}' 2>/dev/null; }
stop_server() { TL kill-server 2>/dev/null; local i=0; while [ "$i" -lt 30 ] && [ -n "$(server_pid)" ]; do sleep 0.1; i=$((i+1)); done; }
# first_pane SESSION -> the pane id of the session's first window's first pane
first_pane() { TL list-panes -s -t "=$1:" -F '#{pane_id}' 2>/dev/null | head -1; }
# A second throwaway server whose pane runs a REAL client of the test server
# (the tests/test-notify-osc.sh way, through a pty): an attach is not a key.
OUTER="$SHAPE_TMP/outer.sock"
OT() { tmux -S "$OUTER" "$@"; }
attach_client() { # SESSION WIDTH HEIGHT -> the outer pane
  OT -f /dev/null new-session -d -x "$2" -y "$3" -s outer \
    "env -u TMUX TMUX_TMPDIR=$TMUX_TMPDIR tmux -S $SHAPE_SOCK attach -t =$1"
  local i=0; while [ "$i" -lt 30 ] && [ -z "$(TL list-clients 2>/dev/null)" ]; do sleep 0.1; i=$((i+1)); done
  OT display -p -t outer: '#{pane_id}'
}
detach_client() { OT kill-server 2>/dev/null; }
mkdir -p "$SHAPE_TMP/d1" "$SHAPE_TMP/d2" "$SHAPE_TMP/d3"

echo "== a saved session that exists is skipped; the others placed (§8.1 test 2 base) =="
TL new-session -d -s keep -c "$SHAPE_TMP" 'ENV= exec /bin/sh'
kp="$(first_pane keep)"; TL set -p -t "$kp" @roost-name keeper
mkshape "keep:$SHAPE_TMP/d1" "s2:$SHAPE_TMP/d2"
R restore >"$SHAPE_TMP/out" 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "12" "exit 12 when a session was skipped as existing"
assert_contains "$(cat "$SHAPE_TMP/err")" "session 'keep' exists — skipped, 1 panes not restored" "...and it is named"
assert_eq "$(TL list-panes -s -t '=keep:' -F x | wc -l | tr -d ' '):$(TL show -pqv -t "$kp" @roost-name)" "1:keeper" "nothing was added to the live session"
s2p="$(first_pane s2)"
assert_eq "$(TL display -p -t "$s2p" '#{pane_current_path}')" "$SHAPE_TMP/d2" "the other session is placed, its pane in the saved directory"
shells_wait "$s2p"; assert_eq "$(shells_for "$s2p" | wc -l | tr -d ' ')" "1" "...as a shell (one shells.log line)"
[ ! -e "$SD/restoring" ]; assert_true $? "restoring/ is removed once restore is done (§3.5 step 4)"
TL kill-session -t '=s2'

echo "== sessions a person made are never replaced (§8.1 test 2 a-e) =="
# Each case: a server running, the saved session's name taken by a session a
# person uses; restore skips it, exit 12, its pane's process untouched.
mkshape "ca:$SHAPE_TMP/d1" "cb:$SHAPE_TMP/d1" "cc:$SHAPE_TMP/d1" "cd:$SHAPE_TMP/d1" "ce:$SHAPE_TMP/d1"
TL new-session -d -s ca -c "$SHAPE_TMP" "$BASH_BIN"; TL send-keys -t '=ca:' 'sleep 60 &' Enter
TL new-session -d -s cb -c "$SHAPE_TMP" "$BASH_BIN"
TL new-session -d -s cc -c "$SHAPE_TMP" "$BASH_BIN"; TL send-keys -t '=cc:' 'sleep 60' Enter
TL new-session -d -s cd -c "$SHAPE_TMP" "$BASH_BIN"; TL send-keys -t '=cd:' -l 'echo keep-me'; TL send-keys -t '=cd:' C-a
TL new-session -d -s ce -c "$SHAPE_TMP" "$BASH_BIN"; TL send-keys -t '=ce:' 'cd /tmp' Enter; TL send-keys -t '=ce:' 'true' Enter
sleep 1
for s in ca cb cc cd ce; do eval "pid_$s=\$(TL display -p -t \"\$(first_pane $s)\" '#{pane_pid}')"; done
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "12" "(a)-(e) exit 12"
for s in ca cb cc cd ce; do
  eval "want=\$pid_$s"
  assert_eq "$(TL display -p -t "$(first_pane $s)" '#{pane_pid}')" "$want" "($s) skipped, its pane_pid unchanged"
done
TL capture-pane -p -t '=cd:' | grep -q 'echo keep-me'; assert_true $? "(d) the screen still shows the pending echo keep-me"
for s in ca cb cc cd ce; do TL kill-session -t "=$s" 2>/dev/null; done

echo "== a stopped server: restore's own bootstrap is placed into =="
mkshape "first:$SHAPE_TMP/d1" "second:$SHAPE_TMP/d2"
stop_server
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "exit 0 (the bootstrap was replaceable)"
fp="$(first_pane first)"
assert_eq "$(TL display -p -t "$fp" '#{pane_current_path}')" "$SHAPE_TMP/d1" "the first pane's cwd is the saved first pane's"
assert_eq "$(TL list-sessions -F '#{session_name}' | sort | tr '\n' ' ')" "first second " "every saved session exists, none twice"
assert_eq "$(TL display -p -t "$fp" '#{window_width}x#{window_height}')" "200x50" "the server was made at the saved size, not 80x24"
assert_eq "$(TL show -gqv @roost-home)" "$HERE" "the server got ensure_session's globals"
# bootstrap.used is asserted while restore is held, in case (h) below: §3.5
# step 4 removes restoring/ with its files when restore ends.
[ ! -e "$SD/restoring" ]; assert_true $? "...and restoring/ is gone afterwards"

echo "== (f) a key in the held bootstrap: taken, the saved session skipped =="
# Pane ids restart at %0 with every server, so a line an earlier server's %0
# left in shells.log would count for this one: start the log empty.
stop_server; rm -rf "$SD/restoring"; : > "$HOME/shells.log"
H="$SHAPE_TMP/hold"; rm -f "$H"
ROOST_TEST_RESTORE_HOLD="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
wait_boot "" 50
i=0; while [ "$i" -lt 50 ] && [ -z "$(first_pane first)" ]; do sleep 0.1; i=$((i+1)); done
bp="$(first_pane first)"
wait_screen "$bp" "$PLACING" 30
attach_client first 80 20 >/dev/null
TL send-keys -t "$bp" x
wait_boot .taken; assert_true $? "the key won: bootstrap.taken"
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "12" "...the saved session of that name is skipped, exit 12"
assert_contains "$(cat "$SHAPE_TMP/err")" "the bootstrap pane was taken by a key" "...and the reason is named"
shells_wait "$bp"; assert_eq "$(shells_for "$bp" | wc -l | tr -d ' ')" "1" "...the pane is the person's shell"
detach_client

echo "== (g) a held bootstrap with a client attached at another size, no key: placed =="
stop_server; rm -rf "$SD/restoring"; rm -f "$H"
ROOST_TEST_RESTORE_HOLD="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
i=0; while [ "$i" -lt 50 ] && [ -z "$(first_pane first)" ]; do sleep 0.1; i=$((i+1)); done
attach_client first 80 20 >/dev/null
sleep 0.5; : > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "0" "an attach is not a key: exit 0, the bootstrap placed into"
detach_client

echo "== (h) a key after restore has won the bootstrap =="
stop_server; rm -rf "$SD/restoring"; rm -f "$H"; : > "$HOME/shells.log"
ROOST_TEST_PLACE_HOLD_AFTER_USED="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
wait_boot .used 50
bp="$(first_pane first)"
attach_client first 100 30 >/dev/null
TL send-keys -t "$bp" x
wait_screen "$bp" "$CLAIMED"; assert_true $? "while held: the screen says restore is placing this pane"
sleep 0.5
assert_eq "$(shells_for "$bp")" "" "...no shell started"
[ -n "$(boot_file .used)" ]; assert_true $? "...the file is still bootstrap.used"
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "0" "released: exit 0, the session placed into"
shells_wait "$bp"; assert_eq "$(shells_for "$bp" | wc -l | tr -d ' ')" "1" "...one shell, started by restore's own respawn"
detach_client

echo "== a first block that cannot start the server stops the run (review round 1, Fable B1) =="
stop_server; rm -rf "$SD/restoring"
mkshape "s2:$SHAPE_TMP/d1"
{ head -11 "$SD/shape"; printf '%s\n' 'session empty' 'id $9' ''; sed '1,11d' "$SD/shape"; } > "$SHAPE_TMP/nowin.shape"
cp "$SHAPE_TMP/nowin.shape" "$SD/shape"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "16" "a session block with no windows, server stopped: refused whole, exit 16"
TL ls >/dev/null 2>&1; assert_eq "$?" "1" "...and no server was started"
mkshape "huge:$SHAPE_TMP/d1" "s2:$SHAPE_TMP/d2"
sed -i.bak 's/^layout b25d,200x50,0,0,0$/layout b25d,99999x99999,0,0,0/' "$SD/shape"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "1" "a bootstrap new-session tmux refuses: the whole run stops, exit 1"
assert_contains "$(cat "$SHAPE_TMP/err")" "could not start the tmux server" "...with its error"
TL ls >/dev/null 2>&1; assert_eq "$?" "1" "...and nothing was placed on a server roost did not start (none is running)"
[ ! -e "$SD/restoring" ]; assert_true $? "...and restoring/ is removed"

echo "== the restored server survives a resize storm from a real client =="
# Another tool's users crashed tmux this way on a server made by
# `new-session -x -y`: a client attached at a different size, then resized fast.
stop_server; rm -rf "$SD/restoring"
mkshape "first:$SHAPE_TMP/d1" "second:$SHAPE_TMP/d2"
R restore >/dev/null 2>&1
op="$(attach_client first 80 20)"
for i in 1 2 3 4 5 6 7 8 9 10; do
  OT resize-window -t outer: -x 100 -y 30 2>/dev/null; sleep 0.025
  OT resize-window -t outer: -x 80 -y 20 2>/dev/null; sleep 0.025
done
sleep 0.5
TL ls >/dev/null 2>&1; assert_true $? "20 resizes in one second: the restored server is still running"
detach_client

echo "== the claimed bootstrap, changed by hand before its respawn, is left alone (review round 1, Codex B1) =="
# The bootstrap is claimed BEFORE its window is built (its session's
# replaceability rests on that rename), so a person can respawn it in the gap;
# the respawn must look again.
stop_server; rm -rf "$SD/restoring"; rm -f "$H"
mkshape "first:$SHAPE_TMP/d1"
ROOST_TEST_PLACE_HOLD="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
wait_boot .used 50; sleep 1
bp="$(first_pane first)"
TL respawn-pane -k -t "$bp" 'sleep 600'; sleep 0.3
bpid="$(TL display -p -t "$bp" '#{pane_pid}')"
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$(TL display -p -t "$bp" '#{pane_pid}:#{pane_current_command}')" "$bpid:sleep" "the person's process survives: same pane_pid, still sleep"
assert_contains "$(cat "$SHAPE_TMP/err")" "pane first:1.0 ($bp) was changed by hand during placement; left as it is" "...and restore says it left the pane"

echo "== a bootstrap split by a person during placement is not left stuck (review round 1, Fable N1) =="
stop_server; rm -rf "$SD/restoring"; rm -f "$H"; : > "$HOME/shells.log"
mkshape "first:$SHAPE_TMP/d1"
ROOST_TEST_PLACE_HOLD_AFTER_USED="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
wait_boot .used 50
bp="$(first_pane first)"
TL split-window -d -t "$bp" "$BASH_BIN"; sleep 0.3
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "12" "the session is skipped: it no longer holds the one pane restore made"
shells_wait "$bp"; assert_eq "$(shells_for "$bp" | wc -l | tr -d ' ')" "1" "...and the bootstrap pane is a shell, not a placeholder no key can free"
TL display -p -t "$bp" '#{pane_start_command}' | grep -q roost-placeholder; assert_eq "$?" "1" "...no longer running the placeholder"

echo "== a bootstrap replaced and split after its claim is left alone (review round 2, Codex R2-B2) =="
# The split-session fallback respawned the bootstrap with no second look. A
# person who replaced it (and split the session) after the claim's check
# lost that process. ROOST_TEST_BOOT_HOLD_AFTER_CLAIM holds restore right
# after the claim returned, before it counts the session's panes.
stop_server; rm -rf "$SD/restoring"; rm -f "$H"
mkshape "first:$SHAPE_TMP/d1"
ROOST_TEST_BOOT_HOLD_AFTER_CLAIM="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
wait_boot .used 50; sleep 1
bp="$(first_pane first)"
TL respawn-pane -k -t "$bp" 'sleep 600'; TL split-window -d -t "$bp" 'sleep 600'; sleep 0.3
bpid="$(TL display -p -t "$bp" '#{pane_pid}')"
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "12" "the session is skipped: it no longer holds the one pane restore made"
assert_eq "$(TL display -p -t "$bp" '#{pane_pid}:#{pane_current_command}')" "$bpid:sleep" \
  "...and the person's process in the bootstrap pane survives: same pane_pid, still sleep"

echo "== a pane a person took in one restore is left alone by the next (review round 2, Codex R2-B1) =="
# A shell a key took keeps the placeholder's start command, which names its
# placing file. Every run used to count from place.1 again, so the next
# run's own place.1 made its final sweep take the old pane for one of its
# own and respawn it, killing what the person ran there. A real foreground
# process (sleep 600) is in the taken shell, as a person's would be.
stop_server; rm -rf "$SD/restoring"; rm -f "$H"; : > "$HOME/shells.log"
TL -f /dev/null new-session -d -s keep -c "$SHAPE_TMP/d1" 'sleep 600'
TL set -g default-shell "$BASH_BIN"
mkshape "first:$SHAPE_TMP/d1"
ROOST_TEST_PLACE_HOLD="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
i=0; while [ "$i" -lt 50 ] && [ -z "$(first_pane first)" ]; do sleep 0.1; i=$((i+1)); done
tp="$(first_pane first)"; wait_screen "$tp" "$PLACING" 30
TL send-keys -t "$tp" x
i=0; while [ "$i" -lt 50 ] && ! ls "$SD/restoring/"place.*.taken >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
shells_wait "$tp"
TL send-keys -t "$tp" 'sleep 600' Enter
i=0; while [ "$i" -lt 50 ] && [ "$(TL display -p -t "$tp" '#{pane_current_command}')" != sleep ]; do sleep 0.1; i=$((i+1)); done
tpid="$(TL display -p -t "$tp" '#{pane_pid}')"; spid="$(pgrep -P "$tpid" -x sleep)"
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "0" "the first restore exits 0, the pane left to the person"
kill -0 "$spid" 2>/dev/null; assert_true $? "...and the person's sleep is running"
mkshape "second:$SHAPE_TMP/d2"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "a second restore, of another session, exits 0"
assert_eq "$(TL display -p -t "$tp" '#{pane_pid}')" "$tpid" "...the taken pane is not respawned: same pane_pid"
kill -0 "$spid" 2>/dev/null; assert_true $? "...and the person's sleep is still running, same pid"
kill "$spid" 2>/dev/null

echo "== a group whose first member has spaces round its name (review round 1, Codex B6) =="
stop_server; rm -rf "$SD/restoring"
TL -f /dev/null new-session -d -s ' lead ' -x 200 -y 50 -c "$SHAPE_TMP/d1" 'ENV= exec /bin/sh'
TL new-session -d -t '= lead ' -s view
R save >/dev/null 2>&1; stop_server
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "restore exits 0"
assert_eq "$(TL list-sessions -F '[#{session_name}] [#{session_group}]' | sort | tr '\n' ',')" "[ lead ] [ lead ],[view] [ lead ]," \
  "...the member joins ' lead ', its name kept byte for byte"

echo "== a default-command with \$ in it runs as the person wrote it (review round 1, Codex B7) =="
# tmux 3.4 prints `$` as `\$` (R6), in default-command too: read back raw, a
# person's `"$HOME/x"` became `"\$HOME/x"` and stopped expanding. Red on 3.4
# only; 3.2a and 3.6 print `$` bare.
stop_server; rm -rf "$SD/restoring"; rm -f "$HOME/landed-restore" "$HOME/landed-key"
TL -f /dev/null new-session -d -s other -c "$SHAPE_TMP/d1" 'sleep 600'
TL new-session -d -s shp 'sleep 600'      # where the placeholder helper opens its window
TL set -g default-shell "$BASH_BIN"
TL new-session -d -s victim -c "$SHAPE_TMP/d1" 'sleep 600'
R save >/dev/null 2>&1; TL kill-session -t '=victim'
TL set -g default-command 'printf landed > "$HOME/landed-restore"; exec '"$BASH_BIN"' -l'
R restore --only victim >/dev/null 2>&1
i=0; while [ "$i" -lt 30 ] && [ ! -e "$HOME/landed-restore" ]; do sleep 0.1; i=$((i+1)); done
[ -e "$HOME/landed-restore" ]; assert_true $? "restore's shell runs the person's default-command with its \$HOME ($(TL display -p '#{version}'))"
TL set -g default-command 'printf landed > "$HOME/landed-key"; exec '"$BASH_BIN"' -l'
F="$RD/place.dollar"; : > "$F"
p="$(placeholder "$F")"; wait_screen "$p" "$PLACING"; TL send-keys -t "$p" x
i=0; while [ "$i" -lt 30 ] && [ ! -e "$HOME/landed-key" ]; do sleep 0.1; i=$((i+1)); done
[ -e "$HOME/landed-key" ]; assert_true $? "...and so does the shell a placeholder hands over at a key"
TL set -gu default-command

echo "== a default-shell with \$ in its path runs as the person set it (review round 2, Codex R2-B3) =="
# The same R6 correction, for default-shell: read back raw on 3.4, its path
# named a file that does not exist, the respawned pane died at once and the
# pane was gone. Red on 3.4 only. The shell marks $HOME/dollar-shell when it
# runs: the fallback for a shell that cannot run (the next case) also keeps
# the pane, so only the mark shows that THIS shell was the one started.
stop_server; rm -rf "$SD/restoring"; : > "$HOME/shells.log"; rm -f "$HOME/dollar-shell"
SHD="$SHAPE_TMP/sh\$ell"; mkdir -p "$SHD"
printf '#!/bin/sh\n: > "$HOME/dollar-shell"\nexec "%s" "$@"\n' "$BASH_BIN" > "$SHD/bash"; chmod +x "$SHD/bash"
TL -f /dev/null new-session -d -s other -c "$SHAPE_TMP/d1" 'sleep 600'
TL new-session -d -s victim -c "$SHAPE_TMP/d1" 'sleep 600'
R save >/dev/null 2>&1; TL kill-session -t '=victim'
TL set -g default-shell "$SHD/bash"; TL set -gu default-command
R restore --only victim >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
vp="$(first_pane victim)"
assert_eq "$rc:$([ -n "$vp" ] && echo kept)" "0:kept" "restore exits 0 and the victim's pane is there ($(TL display -p '#{version}'))"
shells_wait "$vp"; assert_eq "$(shells_for "$vp" | wc -l | tr -d ' ')" "1" "...running a shell"
[ -e "$HOME/dollar-shell" ]; assert_true $? "...started through that default-shell, with no fallback"
assert_eq "$(grep -c 'cannot be run' "$SHAPE_TMP/err")" "0" "...and no line saying it cannot be run"

echo "== a default-shell that cannot be run is said, and the pane kept (review round 2, Codex R2-B3) =="
# A pane whose shell cannot start dies at once, and restore said nothing and
# exited 0. tmux checks default-shell only when it is set, so a shell removed
# since is the way to reach this on every build.
stop_server; rm -rf "$SD/restoring"; : > "$HOME/shells.log"
cp "$SHD/bash" "$SHAPE_TMP/gone-shell"
TL -f /dev/null new-session -d -s other -c "$SHAPE_TMP/d1" 'sleep 600'
TL new-session -d -s victim -c "$SHAPE_TMP/d1" 'sleep 600'
R save >/dev/null 2>&1; TL kill-session -t '=victim'
TL set -g default-shell "$SHAPE_TMP/gone-shell"; TL set -gu default-command
rm -f "$SHAPE_TMP/gone-shell"
R restore --only victim >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_contains "$(cat "$SHAPE_TMP/err")" "default-shell $SHAPE_TMP/gone-shell cannot be run" "restore says the default-shell cannot be run"
vp="$(first_pane victim)"
assert_eq "$rc:$([ -n "$vp" ] && echo kept)" "0:kept" "...and the pane is kept, a shell from \$SHELL instead"
TL set -g default-shell "$BASH_BIN"

echo "== the owner rule (§3.5): restoring/ held by a live restore =="
# A running server with the saved session in it, so a run that is let through
# skips it (exit 12) and one that is refused says so (exit 1).
stop_server; rm -rf "$SD/restoring"
TL -f /dev/null new-session -d -s first -c "$SHAPE_TMP/d1" 'sleep 600'
mkshape "first:$SHAPE_TMP/d1"
# The owner record is a symbolic link whose target is "PID LSTART"
# (scripts/lib/roost-shape.sh, the owner rule).
mkdir -p "$SD/restoring"; ln -s "$$ $(ps -o lstart= -p $$ | sed 's/^ *//;s/ *$//')" "$SD/restoring/owner"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "1" "a live owner: a second restore refuses, exit 1"
assert_contains "$(cat "$SHAPE_TMP/err")" "pid $$" "...naming the pid"
rm -f "$SD/restoring/owner"; ln -s "$$ Thu Jan  1 00:00:00 1970" "$SD/restoring/owner"
R restore >/dev/null 2>&1; rc=$?
assert_eq "$rc" "12" "a live pid with another start time is a reused pid: taken over (first exists: exit 12)"
[ ! -e "$SD/restoring" ]; assert_true $? "...and restoring/ is removed at the end"
echo "== T2b: a dead run's bootstrap is settled into a shell =="
stop_server; mkshape "first:$SHAPE_TMP/d1" "second:$SHAPE_TMP/d2"
mkdir -p "$SD/restoring"; : > "$SD/restoring/bootstrap.1-1-1"
sh -c 'exit 0' & dead=$!; wait "$dead"
ln -s "$dead Thu Jan  1 00:00:00 1970" "$SD/restoring/owner"
TL -f /dev/null new-session -d -s first -c "$SHAPE_TMP/d3" -x 200 -y 50 "$PH" "$SD/restoring/bootstrap.1-1-1" --placing
TL set -g default-shell "$BASH_BIN"
bp="$(first_pane first)"; wait_screen "$bp" "$PLACING" 30
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "12" "a dead owner: taken over; the dead run's session exists, so it is skipped (exit 12)"
shells_wait "$bp"; assert_eq "$(TL display -p -t "$bp" '#{pane_current_path}')" "$SHAPE_TMP/d3" "...its bootstrap is now a shell in that pane's directory"
assert_eq "$(TL list-sessions -F '#{session_name}' | sort | tr '\n' ' ')" "first second " "...and the other saved session is placed"

echo "== dotted and numeric session names (probe 1.4) =="
TL new-session -d -s v3.69-x 'ENV= exec /bin/sh'
mkshape "v3_69-x:$SHAPE_TMP/d1" "v3.69-x:$SHAPE_TMP/d1" "1:$SHAPE_TMP/d2" 2>/dev/null
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "12" "a saved v3_69-x that exists is skipped (exit 12)"
assert_eq "$(TL list-sessions -F '#{session_name}' | grep -c '^v3_69-x$')" "1" "...never made twice (the dotted saved name is the same session)"
assert_eq "$(grep -cF "session 'v3.69-x' exists — skipped" "$SHAPE_TMP/err")" "1" \
  "...and restore knew it existed (not a new-session that tmux happened to refuse)"
assert_eq "$(TL display -p -t "$(first_pane 1)" '#{pane_current_path}')" "$SHAPE_TMP/d2" "a session named 1 is placed, its pane in its saved directory"
TL kill-session -t '=v3_69-x'; TL kill-session -t '=1'
mkshape "v3.69-x:$SHAPE_TMP/d1"
R restore >/dev/null 2>&1; rc=$?
assert_eq "$rc:$(TL display -p -t "$(first_pane v3_69-x)" '#{pane_current_path}')" "0:$SHAPE_TMP/d1" \
  "a saved dotted name that does not exist is placed (tmux stores it with _)"

echo "== session names with a backslash or \$ do not drift (R8.3) =="
stop_server
TL -f /dev/null new-session -d -s 'a\b' -c "$SHAPE_TMP/d1" 'ENV= exec /bin/sh'
TL new-session -d -s 'a$b' -c "$SHAPE_TMP/d1" 'ENV= exec /bin/sh'
before="$(TL list-sessions -F '#{session_name}' | sort)"
for cycle in 1 2; do
  R save >/dev/null 2>&1; stop_server; R restore >/dev/null 2>&1
  assert_eq "$(TL list-sessions -F '#{session_name}' | sort)" "$before" "cycle $cycle: the session names a person sees are the same, not grown ($(TL display -p '#{version}'))"
done

echo "== a session group comes back as a group (R7) =="
stop_server
TL -f /dev/null new-session -d -s gm -c "$SHAPE_TMP/d1" -x 200 -y 50 'ENV= exec /bin/sh'
TL new-session -d -t '=gm' -s gv
TL new-session -d -t '=gm' -s gw
R save >/dev/null 2>&1; npanes="$(grep -c '^pane ' "$SD/shape")"
stop_server; R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "a three-member group restores, exit 0"
assert_eq "$(TL list-sessions -F '#{session_name} #{session_group}' | sort | tr '\n' ',')" "gm gm,gv gm,gw gm," "every member is back, in one group"
assert_eq "$(TL list-panes -a -F '#{pane_id}' | sort -u | wc -l | tr -d ' ')" "$npanes" "one copy of each saved pane, not one per member"
TL new-window -d -t '=gm:'
assert_eq "$(TL list-windows -t '=gv:' -F x | wc -l | tr -d ' ')" "2" "a window made in one member is visible in another"
stop_server

# --- restore: windows, splits, the saved layout (Task 1.13) -------------------
# strip LAYOUT -> the layout with its checksum and every pane id removed, so a
# layout compares by its cells alone (§8.1 test 1).
strip() { printf '%s\n' "$1" | sed -E 's/^[0-9a-f]{4},//; s/([0-9]+x[0-9]+,[0-9]+,[0-9]+),[0-9]+/\1/g'; }
# fleet -> one line per pane: session|window index|window name|pane index|@roost-name|directory
fleet() { TL list-panes -a -F '#{session_name}|#{window_index}|#{window_name}|#{pane_index}|#{@roost-name}|#{pane_current_path}' | sort; }
layouts() { TL list-windows -a -F '#{session_name}:#{window_index} #{window_layout} #{window_zoomed_flag}' | while read -r w l z; do printf '%s %s %s\n' "$w" "$(strip "$l")" "$z"; done | sort; }
# json5 -> session, window_name, window_index, pane_index, name of every pane, from status --json
json5() { R status --json 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin)
for p in sorted(d.get("panes", []), key=lambda p: (p.get("session"), p.get("window_index"), p.get("pane_index"))):
    print(p.get("session"), p.get("window_name"), p.get("window_index"), p.get("pane_index"), p.get("name"))'; }
# fresh_server: a stopped server, then a new one with the restored conf's
# indices, so a fixture's indices are what restore's conf gives back.
fresh_server() {
  stop_server; rm -rf "$SD/restoring"
  TL -f /dev/null new-session -d -s scratch -x 200 -y 50 'sleep 600'
  TL set -g base-index 1; TL setw -g pane-base-index 1; TL set -g default-shell "$BASH_BIN"
  # roost.conf names a window after its pane's directory; the restored server
  # runs roost.conf, so the fixture's automatic names must follow the same rule.
  TL setw -g automatic-rename-format '#{b:pane_current_path}'
}
for d in d1 d2 d3 d4 d5 d6; do mkdir -p "$SHAPE_TMP/$d"; done

echo "== placement: sessions, windows, splits, layouts, zoom (§8.1 test 1) =="
fresh_server
TL new-session -d -s alpha -x 200 -y 50 -c "$SHAPE_TMP/d1" "$BASH_BIN"
TL kill-session -t '=scratch'
TL rename-window -t '=alpha:1' left-right
a1="$(first_pane alpha)"; TL set -p -t "$a1" @roost-name left
a2="$(TL split-window -h -d -P -F '#{pane_id}' -t "$a1" -c "$SHAPE_TMP/d2" "$BASH_BIN")"; TL set -p -t "$a2" @roost-name right
z1="$(TL new-window -d -P -F '#{pane_id}' -t '=alpha:5' -n zoomy -c "$SHAPE_TMP/d3" "$BASH_BIN")"
TL split-window -v -d -t "$z1" -c "$SHAPE_TMP/d4" "$BASH_BIN"
TL resize-pane -Z -t "$z1"
TL new-session -d -s beta -x 200 -y 50 -c "$SHAPE_TMP/d1" "$BASH_BIN"
TL rename-window -t '=beta:1' stacked
b1="$(first_pane beta)"
for d in d2 d3 d4 d5 d6; do TL split-window -v -d -t "$b1" -c "$SHAPE_TMP/$d" "$BASH_BIN"; TL select-layout -t '=beta:1' even-vertical; done
k="$(TL list-panes -t '=beta:1' -F '#{pane_id}' | tail -1)"
TL respawn-pane -k -t "$k" -c "$SHAPE_TMP/d6" -e STUB_IDENTIFY=1 "claude --resume 3fa32375-68cd-43c9-8bcf-fbb876b2db1e"
TL new-session -d -s gamma -x 200 -y 10 -c "$SHAPE_TMP/d1" "$BASH_BIN"
TL rename-window -t '=gamma:1' wide
g1="$(first_pane gamma)"
for d in d2 d3 d4 d5 d6; do TL split-window -h -d -t "$g1" -c "$SHAPE_TMP/$d" "$BASH_BIN"; TL select-layout -t '=gamma:1' even-horizontal; done
TL link-window -s '=alpha:1' -t '=gamma:9'
sleep 1
F1="$(fleet)"; L1="$(layouts)"; J1="$(json5)"
R save >/dev/null 2>&1
stop_server; : > "$HOME/shells.log"; : > "$HOME/env.log"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "restore exits 0"
sleep 1
F2="$(fleet)"
assert_eq "$(printf '%s\n' "$F2" | grep -v '^gamma|9|')" "$(printf '%s\n' "$F1" | grep -v '^gamma|9|')" \
  "every pane is back: session, window index and name, pane index, name, directory (the first pane's included)"
# The linked window (alpha:1, linked as gamma:9) is left out of THIS compare
# under both names: before restore its panes are listed twice, and status
# --json files each pane once, under whichever context it read — under a C
# locale tmux 3.4 prints a tab as `_` (docs/known-gaps.md), status falls back
# to reading each pane by id, and the two copies land under gamma:9. The tmux
# listing compare above covers those panes byte for byte.
assert_eq "$(json5 | grep -v ' left-right ')" "$(printf '%s\n' "$J1" | grep -v ' left-right ')" "status --json agrees on session, window_name, window_index, pane_index, name"
L2="$(layouts)"
assert_eq "$(printf '%s\n' "$L2" | grep -v '^gamma:9 ')" "$(printf '%s\n' "$L1" | grep -v '^gamma:9 ')" \
  "every layout is the saved one (checksum and pane ids stripped); the zoomed window is zoomed"
assert_eq "$(TL list-panes -t '=beta:1' -F x | wc -l | tr -d ' ')" "6" "six stacked panes in a 200x50 window"
assert_eq "$(TL list-panes -t '=gamma:1' -F x | wc -l | tr -d ' ')" "6" "six side-by-side panes in a 200x10 window (the largest side, across it)"
zl="$(TL display -p -t '=alpha:5' '#{window_layout}')"
TL resize-pane -Z -t '=alpha:5'
assert_eq "$(strip "$(TL display -p -t '=alpha:5' '#{window_layout}')")" "$(strip "$(sed -n '/^window alpha:5$/,/^$/s/^layout //p' "$SD/shape")")" \
  "unzoomed after restore, the zoomed window's layout is the saved one (probe 1.1)"
assert_eq "$(TL display -p -t "$(first_pane alpha)" '#{window_width}x#{window_height}')" "200x50" "the first window is 200x50"
assert_eq "$(TL list-panes -t '=gamma:9' -F x | wc -l | tr -d ' '):$(TL display -p -t '=gamma:9' '#{window_linked}')" "2:0" \
  "a window linked into two sessions comes back as two windows (§3.2)"
assert_eq "$(TL display -p -t "$(TL list-panes -t '=beta:1' -F '#{pane_id}' | tail -1)" '#{pane_current_path}')" "$SHAPE_TMP/d6" \
  "a keyed pane is a shell in its directory (agents are not resumed in this part)"
npl="$(TL list-panes -a -F x | wc -l | tr -d ' ')"
assert_eq "$(cut -d' ' -f1 "$HOME/shells.log" | sort -u | wc -l | tr -d ' ')" "$npl" "every pane, the first included, started a shell"
assert_eq "$(grep -c ' wired$' "$HOME/env.log")" "$npl" "...and every one of them is wired (ROOST_TMUX set)"
assert_eq "$(TL list-panes -a -F '#{pane_start_command}' | grep -vc roost-pane-shell)" "0" "every pane's start command is roost-pane-shell (§8.1 test 1, wired)"

echo "== odd names come back exactly, twice (probe 1.3, R8.3) =="
fresh_server
ODDN=('sp ace' 'a$b' "a'b" 'a"b' 'a#b' 'trail ' 'a🐓b' 'a\b')
TL new-session -d -s v3.69-x -x 200 -y 50 -c "$SHAPE_TMP/d1" "$BASH_BIN"
TL new-session -d -s 1 -x 200 -y 50 -c "$SHAPE_TMP/d1" "$BASH_BIN"
TL kill-session -t '=scratch'
for v in "${ODDN[@]}"; do
  mkdir -p "$SHAPE_TMP/o/$v"
  w="$(TL new-window -d -P -F '#{window_id}' -t '=1:' -c "$SHAPE_TMP/o/$v" "$BASH_BIN")"
  TL rename-window -t "$w" "$v"
done
sleep 1
before="$(fleet)"
for cycle in 1 2; do
  R save >/dev/null 2>&1; stop_server; R restore >/dev/null 2>&1; sleep 1
  assert_eq "$(fleet)" "$before" "cycle $cycle: window names and directories with odd characters are the same, none grown ($(TL display -p '#{version}'))"
done

echo "== (i) a pane placement made, used during placement (§8.1 test 2 i, unkeyed) =="
fresh_server
# The two-pane session comes FIRST: ROOST_TEST_PLACE_HOLD holds at the first
# window restore builds, and this case needs that window held.
mkshape "two:$SHAPE_TMP/d1" "keepme:$SHAPE_TMP/d1"
python3 - "$SD/shape" "$SHAPE_TMP/d2" <<'PYS'
import sys
p, d = sys.argv[1], sys.argv[2]
s = open(p).read()
s = s.replace("window two:1\nid @0\nlayout b25d,200x50,0,0,0",
              "window two:1\nid @0\nlayout 9d6f,200x50,0,0{100x50,0,0,0,99x50,101,0,9}")
s += "pane two:1.1\nid %9\ncwd %s\n\n" % d
open(p, "w").write(s)
PYS
TL kill-session -t '=scratch' 2>/dev/null; TL -f /dev/null new-session -d -s other 'sleep 600'; TL set -g default-shell "$BASH_BIN"
rm -f "$H"
ROOST_TEST_PLACE_HOLD="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
i=0; while [ "$i" -lt 50 ] && [ "$(TL list-panes -t '=two:' -F x 2>/dev/null | wc -l | tr -d ' ')" != 2 ]; do sleep 0.1; i=$((i+1)); done
sleep 0.5
tp="$(TL list-panes -t '=two:' -F '#{pane_id}' | tail -1)"
TL send-keys -t "$tp" x; shells_wait "$tp"; sleep 0.3
TL send-keys -t "$tp" 'sleep 60' Enter; sleep 0.5
tpid="$(TL display -p -t "$tp" '#{pane_pid}')"; spid="$(pgrep -P "$tpid" sleep | head -1)"
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "0" "released: exit 0"
assert_eq "$(TL display -p -t "$tp" '#{pane_pid}')" "$tpid" "the used pane is the person's: its pane_pid unchanged"
kill -0 "$spid" 2>/dev/null; assert_true $? "...and the sleep started in it still runs"
assert_contains "$(cat "$SHAPE_TMP/err")" "($tp) was taken by a key during placement; left as it is" "...and restore says it left that pane to the person"
assert_eq "$(TL display -p -t "$(TL list-panes -t '=two:' -F '#{pane_id}' | head -1)" '#{pane_current_path}')" "$SHAPE_TMP/d1" "every other pane is placed as saved"

echo "== (j) won, then changed by hand: the person's (§8.1 test 2 j) =="
fresh_server
mkshape "solo:$SHAPE_TMP/d1"
TL kill-session -t '=scratch' 2>/dev/null; TL -f /dev/null new-session -d -s other 'sleep 600'; TL set -g default-shell "$BASH_BIN"
rm -f "$H"
ROOST_TEST_PLACE_HOLD_AFTER_USED="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
i=0; while [ "$i" -lt 50 ] && ! ls "$SD/restoring/"place.*.used >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
jp="$(first_pane solo)"; used="$(ls "$SD/restoring/"place.*.used)"
TL respawn-pane -k -t "$jp" 'sleep 60'; sleep 0.3
jpid="$(TL display -p -t "$jp" '#{pane_pid}')"
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "0" "released: exit 0"
# The file's own .taken rename is gone with restoring/ (§3.5 step 4), so the
# person-owned row is read from what restore says it did.
assert_contains "$(cat "$SHAPE_TMP/err")" "pane solo:1.0 ($jp) was changed by hand during placement; left as it is" \
  "restore names the pane it left to the person (T2: the person-owned row)"
assert_eq "$(TL display -p -t "$jp" '#{pane_pid}:#{pane_current_command}')" "$jpid:sleep" "...and the sleep is alive, the pane untouched"

echo "== hand-edited copies (§8.1 test 5, the restore half) =="
fresh_server
TL new-session -d -s hand -x 200 -y 50 -c "$SHAPE_TMP/d1" "$BASH_BIN"
TL kill-session -t '=scratch'
TL split-window -h -d -t '=hand:1' -c "$SHAPE_TMP/d2" "$BASH_BIN"
R save >/dev/null 2>&1
cp "$SD/shape" "$SHAPE_TMP/hand.shape"
stop_server
awk -v RS= -v ORS='\n\n' '!/^pane hand:1\.2\n/' "$SHAPE_TMP/hand.shape" > "$SD/shape"
R restore >/dev/null 2>"$SHAPE_TMP/err"
assert_eq "$(TL list-panes -t '=hand:1' -F x | wc -l | tr -d ' ')" "1" "a copy with a deleted pane block does not restore that pane"
stop_server
sed 's/hand/renamed/' "$SHAPE_TMP/hand.shape" > "$SD/shape"
R restore >/dev/null 2>&1; rc=$?
assert_eq "$rc:$(TL list-sessions -F '#{session_name}')" "0:renamed" "a session renamed with its addresses is created under the new name"

echo "== the K-pane fallback names every block it could not place =="
# A 4x2 window: with the largest-side rule a 20x6 one still holds six panes,
# so the case needs a window that really cannot.
fresh_server
TL kill-session -t '=scratch' 2>/dev/null; TL -f /dev/null new-session -d -s other 'sleep 600'; TL set -g default-shell "$BASH_BIN"
{ printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" 'boot 1-1' 'saved 2026-10-28T12:00:00Z' \
    'gen 1' 'trigger save' 'roost 0.10.0' 'tmux 3.6' 'host h' '' 'session tiny' 'id $0' '' \
    'window tiny:1' 'id @0' 'layout 0000,4x2,0,0[4x1,0,0,0,4x0,0,1,1]' '' 
  for n in 0 1 2 3 4 5; do
    printf '%s\n' "pane tiny:1.$n" "id %$n" "cwd $SHAPE_TMP/d1"
    case $n in 4) printf '%s\n' 'harness claude' 'session_id 3fa32375-68cd-43c9-8bcf-fbb876b2db1e' ;;
               5) printf '%s\n' 'harness codex' 'session_id 0b5e1c2a-7d4f-4e61-9a3b-5c2d1e0f9a87' ;; esac
    printf '\n'
  done; } > "$SD/shape"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
placed="$(TL list-panes -t '=tiny:1' -F x | wc -l | tr -d ' ')"
assert_eq "$rc" "13" "a window that cannot hold every saved pane: exit 13"
[ "$placed" -ge 1 ] && [ "$placed" -lt 6 ]; assert_true $? "...the panes that fit are placed ($placed)"
assert_contains "$(cat "$SHAPE_TMP/err")" "pane tiny:1.5 not placed" "...and every block not placed is named"
assert_contains "$(cat "$SHAPE_TMP/err")" "codex 0b5e1c2a-7d4f-4e61-9a3b-5c2d1e0f9a87" "...with its key"
assert_contains "$(cat "$SHAPE_TMP/err")" "roost revive" "...and how to bring it back"
stop_server

# --- restore: --dry-run, --list, --from, --only, directories (Task 1.14) -------
echo "== --dry-run: the plan as one tree, nothing started (§4.3) =="
fresh_server
TL new-session -d -s alpha -x 200 -y 50 -c "$SHAPE_TMP/d1" "$BASH_BIN"
TL kill-session -t '=scratch'
TL rename-window -t '=alpha:1' main
ap="$(first_pane alpha)"; TL set -p -t "$ap" @roost-name promo
mkdir -p "$SHAPE_TMP/gone"
kp="$(TL split-window -d -P -F '#{pane_id}' -t "$ap" -c "$SHAPE_TMP/gone" -e STUB_IDENTIFY=1 "claude --resume 3fa32375-68cd-43c9-8bcf-fbb876b2db1e")"
xp="$(TL split-window -d -P -F '#{pane_id}' -t "$ap" -c "$SHAPE_TMP/d2" \
  "$ROOST identify --session 6a7b8c9d-1e2f-4a3b-8c4d-5e6f7a8b9c0d --cwd $SHAPE_TMP/d2 --harness codex; exec $BASH_BIN")"
TL new-session -d -s beta -x 200 -y 50 -c "$SHAPE_TMP/d3" "$BASH_BIN"
sleep 1.5
R save >/dev/null 2>&1
rmdir "$SHAPE_TMP/gone"
stamp="$(sed -n 's/^saved //p;/^$/q' "$SD/shape" | tr -d ':-')-$(sed -n 's/^gen //p;/^$/q' "$SD/shape")"
stop_server
out="$(R restore --dry-run 2>"$SHAPE_TMP/err")"; rc=$?
assert_eq "$rc" "0" "--dry-run with no server: exit 0, what the real run would give"
assert_prefix "$out" "from $stamp (the newest save; saved " "the first line names the save and why it was picked"
assert_contains "$out" $'\nsession alpha\n  window 1 main\n    pane 1 promo' "sessions, two-space windows, four-space panes"
assert_contains "$(printf '%s\n' "$out" | grep "$SHAPE_TMP/gone")" "claude" "a keyed pane shows its harness"
assert_contains "$(printf '%s\n' "$out" | grep "$SHAPE_TMP/gone")" "shell in ~, not resumed: directory gone" "...and a gone directory"
assert_contains "$(printf '%s\n' "$out" | grep "$SHAPE_TMP/d2")" "not resumed: stale (exited codex)" "a stale pane says why"
assert_contains "$out" $'\nsession beta\n' "every session is in the tree"
TL ls >/dev/null 2>&1; assert_eq "$?" "1" "--dry-run never starts a server"
printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')"; assert_eq "$?" "1" "no colour when stdout is a pipe"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "the real run gives the same exit code"
assert_contains "$(cat "$SHAPE_TMP/err")" "directory $SHAPE_TMP/gone is gone; a shell in the home directory" "a gone directory: one stderr line (§8.1 test 3a)"
assert_eq "$(TL list-panes -t '=alpha:1' -F '#{pane_current_path}' | grep -cx "$HOME")" "1" "...and that pane is a shell in the home directory"
out="$(R restore --dry-run 2>/dev/null)"; rc=$?
assert_eq "$rc" "12" "--dry-run against a running server where the sessions exist: exit 12"
assert_contains "$out" "session alpha (exists - skipped, 3 panes not restored)" "...naming each skipped session"

echo "== --dry-run and --list only look: they make no shape directory (review round 1, Fable N6) =="
nd="$SHAPE_TMP/never-made"
ROOST_SHAPE_DIR="$nd" ROOST_SOCKET=roost "$ROOST" restore --dry-run >/dev/null 2>&1
ROOST_SHAPE_DIR="$nd" ROOST_SOCKET=roost "$ROOST" restore --list >/dev/null 2>&1
[ ! -e "$nd" ]; assert_true $? "neither makes the shape directory of a server with no save"

echo "== --list: every save, the one restore would pick marked (§3.6) =="
TL rename-window -t '=beta:1' changed; R save >/dev/null 2>&1
lst="$(R restore --list 2>&1)"; rc=$?
assert_eq "$rc" "0" "--list exits 0"
assert_eq "$(printf '%s\n' "$lst" | grep -c '^[* ] [0-9]\{8\}T[0-9]\{6\}Z-[0-9]')" "$((1 + $(ls "$SD/history" | wc -l)))" "shape and every history save, one line each"
assert_contains "$(printf '%s\n' "$lst" | grep '^\*')" "shape" "the newest, shape, is marked as the one restore picks"
assert_contains "$(printf '%s\n' "$lst" | grep "$stamp")" "save  2 sessions, 2 windows, 4 panes" "a line holds its trigger and counts"

echo "== --from STAMP-GEN, --from FILE, another host =="
stop_server
R restore --from "$stamp" >/dev/null 2>&1; rc=$?
assert_eq "$rc:$(TL list-windows -t '=beta:' -F '#{window_name}')" "0:d3" "--from STAMP-GEN restores that save from history/"
stop_server
sed 's/^host .*/host elsewhere.example/' "$SD/shape" > "$SHAPE_TMP/copy.shape"
R restore --from "$SHAPE_TMP/copy.shape" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc:$(TL list-windows -t '=beta:' -F '#{window_name}')" "0:changed" "--from FILE restores a copy"
assert_contains "$(cat "$SHAPE_TMP/err")" "elsewhere.example" "...and a copy from another host says so in one line, then restores"
stop_server
R restore --from 20000101T000000Z-1 >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "2" "--from a STAMP-GEN that is not there: exit 2"

echo "== --only (§4.3) =="
R restore --only beta >/dev/null 2>&1; rc=$?
assert_eq "$rc:$(TL list-sessions -F '#{session_name}' | tr '\n' ' ')" "0:beta " "--only SESSION places that session alone"
stop_server
R restore --only alpha:1 >/dev/null 2>&1
assert_eq "$(TL list-sessions -F '#{session_name}' | tr '\n' ' ')" "alpha " "--only SESSION:WINDOW places that window's session with it"
stop_server
# The pane's id in THIS save: the newest save was made on a restored
# server, whose pane ids are not the fixture's.
oldxp="$(awk -v RS= -v d="cwd $SHAPE_TMP/d2" 'index($0 "\n", "\n" d "\n") && /^pane / { sub(/.*\nid /, ""); sub(/\n.*/, ""); print }' "$SD/shape")"
R restore --only "$oldxp" >/dev/null 2>"$SHAPE_TMP/err"
assert_eq "$(TL list-panes -a -F '#{pane_current_path}')" "$SHAPE_TMP/d2" "--only %OLD places that one pane"
stop_server
out="$(R restore --only nosuch 2>&1)"; rc=$?
assert_eq "$rc" "2" "--only that matches nothing: exit 2"
assert_contains "$out" "nosuch" "...naming the selector"

echo "== a group in --only, --dry-run and --list (R7) =="
fresh_server
TL new-session -d -s gm -x 200 -y 50 -c "$SHAPE_TMP/d1" "$BASH_BIN"
TL kill-session -t '=scratch'
TL new-session -d -t '=gm' -s gv
R save >/dev/null 2>&1
stop_server
out="$(R restore --dry-run 2>/dev/null)"
assert_contains "$out" "session gv (joins gm's group)" "--dry-run names a later member once, as joining its group"
assert_eq "$(printf '%s\n' "$out" | grep -c '^session ')" "2" "...each session one line"
lst="$(R restore --list 2>&1)"
assert_contains "$(printf '%s\n' "$lst" | grep -A1 '^\*')" "sessions: gm, gv (joins gm's group)" \
  "--list names each save's sessions, a later member once as joining its group (R7)"
TL -f /dev/null new-session -d -s other 'sleep 600'
before="$(TL list-sessions -F '#{session_name}')"
R restore --only gv >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "16" "--only a later member whose first member is not on the server: exit 16"
assert_eq "$(TL list-sessions -F '#{session_name}')" "$before" "...nothing done"
assert_contains "$(cat "$SHAPE_TMP/err")" "gm" "...naming the first member it needs"
R restore --only gm >/dev/null 2>&1; rc=$?
assert_eq "$rc:$(TL list-sessions -F '#{session_name} #{session_group}' | grep -c ' gm$')" "0:2" "--only the first member brings its later members"
TL kill-session -t '=gv'
R restore --only gv >/dev/null 2>&1; rc=$?
assert_eq "$rc:$(TL display -p -t '=gv:' '#{session_group}')" "0:gm" "--only a later member alone joins a first member already on the server"

echo "== no save, and a malformed one =="
stop_server
mv "$SD/shape" "$SHAPE_TMP/kept.shape"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "2" "no shape for this server: exit 2"
TL -f /dev/null new-session -d -s live 'sleep 600'
before="$(TL list-sessions -F '#{session_name}'; TL list-panes -a -F '#{pane_id}')"
{ head -11 "$SHAPE_TMP/kept.shape"; printf '%s\n' 'session broken' 'id $0' '' 'pane broken:1.0' 'id %0' 'cwd /tmp'; } > "$SD/shape"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "16" "a malformed shape: exit 16"
assert_eq "$(TL list-sessions -F '#{session_name}'; TL list-panes -a -F '#{pane_id}')" "$before" "...and a listing before and after is identical (create nothing)"
assert_contains "$(cat "$SHAPE_TMP/err")" "line 15" "...naming the line"
mv "$SHAPE_TMP/kept.shape" "$SD/shape"
stop_server

echo "== renumber-windows on: the --dry-run tree says so =="
RN="$SHAPE_TMP/rn/roost"; mkdir -p "$SHAPE_TMP/rn"
R2() { ROOST_SOCKET="$RN" "$ROOST" "$@"; }
tmux -S "$RN" -f /dev/null new-session -d -s numbered -x 200 -y 50 'sleep 600'
tmux -S "$RN" set -g renumber-windows on
tmux -S "$RN" new-window -d -t '=numbered:5' 'sleep 600'
R2 save >/dev/null 2>&1
out="$(R2 restore --dry-run 2>/dev/null)"
assert_contains "$out" "renumber-windows" "the tree carries a note that the conf renumbers windows"
tmux -S "$RN" kill-server

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
