#!/usr/bin/env bash
# The restore offer (#191, Part 7): after a crash with `persist` off, a bare
# `roost` asks whether to bring the saved fleet back — `r` restore, `p`
# preview, `n` start fresh and do not ask again, `l` restore at login from now
# on — instead of opening an empty session. And the two things around it:
# `restore --from STAMP-GEN` finds a pinned or declined save, and no automatic
# path ever places a declined one.
# Design: docs/airig/specs/2026-10-24-persistent-sessions-design.md §4.8,
# §3.6, §4.4, §4.6; §8.1 test 12. Plan: Tasks 7.2 to 7.5.
#
# THE TERMINAL IS REAL (§8.1 test 12). The offer is asked only of a person:
# stdin and stdout must be terminals. So `roost` runs in a pane of a SECOND
# throwaway server (the "outer" one, CLT below, a socket path under this
# file's TMUX_TMPDIR), keys go in with `send-keys`, and the screen is read
# with `capture-pane -p`. The server under test — the "inner" one — is this
# file's own `-L roost` (tests/lib-shape.sh says why it is named that, and
# why that is safe), stopped before every case, with an earlier boot's save
# planted for it.
#
# The outer pane clears every agent marker of §4.8 and every name the live
# smoke tests clear (OFFER_ENV): the suite itself may run under Claude Code
# or codex, and an inherited marker would switch the offer off and turn every
# "asked" case into a silent pass of the wrong branch.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh

shape_test_setup
# `roost wiring apply` runs when roost starts a server, and writes under
# XDG_CONFIG_HOME: a temp dir here, not the canary.
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
unset TMUX TMUX_PANE
# No shutdown record unless a case sets one: on a Mac `last reboot` would
# otherwise decide which save the offer pins.
export ROOST_SHUTDOWN_AT=""
SLEEPER=""
cleanup() {
  [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null
  [ -n "${TMUX_TMPDIR:-}" ] && tmux -S "$TMUX_TMPDIR/cl" kill-server 2>/dev/null
  [ -n "${TMUX_TMPDIR:-}" ] && tmux -S "$TMUX_TMPDIR/ctl" kill-server 2>/dev/null
  shape_test_teardown
}
trap cleanup EXIT

ROOST="$PWD/bin/roost"
R() { env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"; mkdir -p "$SD"
STUBS="$SHAPE_TMP/persist-stubs"
persist_stubs "$STUBS"
export PERSIST_LOG="$SHAPE_TMP/persist.log"; : > "$PERSIST_LOG"
. scripts/lib/roost-shape.sh

mkdir -p "$XDG_CONFIG_HOME/roost"
printf '%s\n' "set -g default-command 'exec /bin/sh'" > "$XDG_CONFIG_HOME/roost/roost.conf"

U1=3fa3c0de-7171-4abc-8def-000000000001
U2=3fa3c0de-7272-4abc-8def-000000000002
U3=3fa3c0de-7373-4abc-8def-000000000003
D1="$SHAPE_TMP/w/one"; D2="$SHAPE_TMP/w/two"; DG="$SHAPE_TMP/w/gone"; DN="$SHAPE_TMP/w/none"
mkdir -p "$D1" "$D2" "$DN"
stub_store_add "$U1" "$D1"; stub_store_add "$U2" "$D2"; stub_store_add "$U3" "$DG"

OLDBOOT=1700000000-11
sg() { printf '%s-%s\n' "$(sed -n 's/^saved //p;/^$/q' "$1" | tr -d ':-')" "$(sed -n 's/^gen //p;/^$/q' "$1")"; }
ino() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }
sessions() { TL list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }
live_boot() { TL display -p '#{start_time}-#{pid}' 2>/dev/null; }
npend() { ls "$1" 2>/dev/null | grep -c '^%[0-9]*$'; }
stop_server() { TL kill-server 2>/dev/null; local end=$((SECONDS + 10)); while TL ls >/dev/null 2>&1 && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done; sleep 0.2; }
# Bounded by the clock, never by loop turns (a loaded runner turns slowly).
wait_for() { local end=$((SECONDS + ${2:-10})); while [ "$SECONDS" -lt "$end" ]; do eval "$1" && return 0; sleep 0.1; done; eval "$1"; }

# plant [FIXTURE] [GEN] [SAVED] [OUT] — an earlier boot's save, as `shape`.
#   shared (§8.1 test 12's): `main` and `work`, four panes, one window each:
#     main:1 %1 claude U1 in D1 (resumable)   main:2 %2 a plain shell
#     work:1 %3 a plain shell                 work:2 %4 claude U3, its directory GONE
#   g (12g's own): `main` %1 claude U1, `work` %2 claude U2 and %3 a shell
#   k3 (12k3's own): the same panes as g, every directory present
#   ops (12g, which session): `work` %1 and `ops` %2 (active 1), both keyed
#   one: a single unkeyed shell
#   PLANT_HOST overrides the host line.
#   The save starts with `#` notes, as every save roost writes does (#234);
#   PLANT_OLD=1 leaves them out: a save an older roost wrote.
plant() {
  local fx="${1:-shared}" gen="${2:-5}" saved="${3:-2026-11-01T10:00:00Z}" out="${4:-$SD/shape}" n=0
  win() { # SESSION:IDX
    printf '%s\n' "window $1" "id @$n" "layout b25d,200x50,0,0,$n" 'active 1' ''; n=$((n+1)); }
  pane() { # ADDR ID CWD [KEYED-ID]
    printf '%s\n' "pane $1" "id $2" "cwd $3"
    [ -n "${4:-}" ] && printf '%s\n' "harness claude" "session_id $4"
    printf '\n'; }
  sess() { printf '%s\n' "session $1" "id \$$n"; [ -n "${2:-}" ] && printf 'active 1\n'; printf '\n'; n=$((n+1)); }
  { [ -n "${PLANT_OLD:-}" ] || printf '%s\n' "# A saved roost fleet: server roost, saved $saved, because of: save" \
      '# planted by tests/test-shape-offer.sh' '# run `roost restore --dry-run --from <this file>` to see the full tree'
    printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" "boot $OLDBOOT" \
      "saved $saved" "gen $gen" 'trigger save' 'roost 0.10.0' 'tmux 3.6' "host ${PLANT_HOST:-$(uname -n)}" ''
    case "$fx" in
      shared)
        sess main; win main:1; pane main:1.0 %1 "$D1" "$U1"; win main:2; pane main:2.0 %2 "$DN"
        sess work; win work:1; pane work:1.0 %3 "$DN"; win work:2; pane work:2.0 %4 "$DG" "$U3" ;;
      g|k3)
        sess main; win main:1; pane main:1.0 %1 "$D1" "$U1"
        sess work; win work:1; pane work:1.0 %2 "$D2" "$U2"; win work:2; pane work:2.0 %3 "$DN" ;;
      ops)
        sess work; win work:1; pane work:1.0 %1 "$D1" "$U1"
        sess ops 1; win ops:1; pane ops:1.0 %2 "$D2" "$U2" ;;
      one)
        sess main; win main:1; pane main:1.0 %1 "$DN" ;;
    esac
  } > "$out"
  chmod 600 "$out"
  [ "$out" = "$SD/shape" ] && printf '%s\n' "$gen" > "$SD/gen"
  return 0
}
# fresh_dir: the inner server stopped, its shape directory empty but for a
# planted shared save, no persist marker, no offer, no decline.
fresh_dir() { stop_server; rm -rf "$SD"; mkdir -p "$SD"; chmod 700 "$SD"; plant "${1:-shared}"; }

stop_server

# ============================================================================
# Task 7.2 — --from finds a pinned or declined save; the decline guard
# ============================================================================
echo "== --from STAMP-GEN: shape, then history/, then offer/save, then declined =="
fresh_dir
S0="$(sg "$SD/shape")"
out="$(R restore --dry-run --from "$S0" 2>&1)"; rc=$?
assert_contains "$out" "from $S0" "shape itself is found by its STAMP-GEN (it has no history/ name) (rc $rc)"
# The pin: only in offer/ (the ring dropped it, nothing declined).
mkdir -p "$SD/offer"; mv "$SD/shape" "$SD/offer/save"; plant one 9 2026-11-02T10:00:00Z
out="$(R restore --dry-run --from "$S0" 2>&1)"
assert_contains "$out" "from $S0" "offer/save is found by its STAMP-GEN"
assert_contains "$out" "session work" "...and it is that save's tree"
# Declined only.
mv "$SD/offer/save" "$SD/declined"; rm -rf "$SD/offer"
out="$(R restore --dry-run --from "$S0" 2>&1)"
assert_contains "$out" "from $S0" "declined is found by its STAMP-GEN"
assert_contains "$out" "session work" "...and it is that save's tree"
# Order: the same STAMP-GEN in history/ and declined — history/ wins (the
# order is the rule; the bytes are the same save either way, so a marker line
# in the history copy tells them apart).
mkdir -p "$SD/history"; cp "$SD/declined" "$SD/history/$S0"
sed -i.b "s|^cwd $DN\$|cwd $D2|" "$SD/history/$S0"; rm -f "$SD/history/$S0.b"
out="$(R restore --dry-run --from "$S0" 2>&1)"
assert_contains "$out" "$D2" "history/ is looked at before declined"

echo "== --list marks declined, last when the ring has dropped it =="
fresh_dir
S0="$(sg "$SD/shape")"
ln "$SD/shape" "$SD/declined"
out="$(R restore --list 2>&1)"
assert_contains "$(printf '%s\n' "$out" | grep "$S0")" "declined" "a declined save that is shape is marked declined"
plant one 6 2026-11-02T10:00:00Z "$SD/shape.n"; mkdir -p "$SD/history"
mv "$SD/shape.n" "$SD/shape"
out="$(R restore --list 2>&1)"
last="$(printf '%s\n' "$out" | grep -v '^    ' | tail -1)"
assert_contains "$last" "$S0" "the ring dropped it: it is listed last"
assert_contains "$last" "declined" "...marked declined"

echo "== §8.1 test 12 (h2): no automatic path places a declined save =="
fresh_dir
S0="$(sg "$SD/shape")"
ln "$SD/shape" "$SD/declined"
: > "$SD/persist"; rm -rf "$SD/login"
out="$(R restore --list 2>&1)"
pl="$(printf '%s\n' "$out" | grep "$S0")"
assert_contains "$pl" "restore picks this" "(fixture) the declined save is the one §3.6 picks"
assert_contains "$pl" "declined" "...and --list marks it declined too"
R persist --at-login roost >/dev/null 2>&1
assert_eq "$(sessions)" "" "--at-login: no saved session exists afterwards"
assert_contains "$(cat "$SD/login.log")" "declined at the restore offer" "...and login.log names the decline"
stop_server
rm -rf "$SD/login"; rm -f "$SD/shape"; ln "$SD/declined" "$SD/shape"; : > "$SD/login.log"
R spawn x sh >/dev/null 2>&1
shape_settle "$SD" || true
# What 12 (h2) means is "no saved session was placed": the same sessions,
# windows and pane counts as a server with no shape directory. A window's
# AUTOMATIC name is not part of that: it is whatever its pane runs at the
# instant of listing (`roost`, `sleep`, the shell), a race between two
# servers, and CI's macOS runner lost it once (fix round 1: `main roost 1`
# against `main  1`). So an automatically named window lists as `auto`; a
# name roost or a person set (the spawn's `x`, a saved window's name) is
# compared as it is. tmux prints #{automatic-rename} as 1 or 0 (measured on
# 3.4, 3.6 and 3.8).
WSHAPE='#{session_name} #{?#{==:#{automatic-rename},1},auto,#{window_name}} #{window_panes}'
inner="$(TL list-windows -a -F "$WSHAPE" | sort)"
# The control: the same spawn on a third throwaway server with saving off.
CTL="$TMUX_TMPDIR/ctl"
env -u TMUX -u TMUX_PANE ROOST_SOCKET="$CTL" ROOST_SHAPE_DIR= "$ROOST" spawn x sh >/dev/null 2>&1
ctl="$(tmux -S "$CTL" list-windows -a -F "$WSHAPE" | sort)"
tmux -S "$CTL" kill-server 2>/dev/null
assert_eq "$inner" "$ctl" "roost spawn: the ordinary fresh 'spawn x sh' shape (as on a server with no shape directory)"
assert_eq "$(TL has-session -t =work 2>/dev/null && echo yes || echo no)" "no" "...no work session"
keys="$(TL list-panes -a -F '#{@roost-session}#{@roost-was}' | tr -d '\n')"
assert_eq "$keys" "" "...no pane carries a planted key or a @roost-was"
assert_contains "$(cat "$SD/login.log")" "declined at the restore offer" "...and login.log names the decline"
stop_server
rm -f "$SD/persist"

# ============================================================================
# The outer server: a real terminal for `roost` (§8.1 test 12's opening)
# ============================================================================
CL="$TMUX_TMPDIR/cl"
CLT() { tmux -S "$CL" "$@"; }
# Every agent marker of §4.8 (with Task 7.1's additions) and every name the
# live smoke tests clear (tests/live/claude-decline-smoke.sh), and the
# offer's own switch: a case that wants one sets it back on its own line.
OFFER_UNSET="-u TMUX -u TMUX_PANE -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID
  -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_PID
  -u CLAUDE_EFFORT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN
  -u CLAUDE_CODE_SESSION_ATTENDED -u CODEX_THREAD_ID -u COPILOT_CLI -u COPILOT_AGENT_SESSION_ID
  -u PI_CODING_AGENT -u AI_AGENT -u ROOST_NO_OFFER"
OFFER_UNSET="$(printf '%s' "$OFFER_UNSET" | tr '\n' ' ')"
NP=0
# opane "VAR=x ..." [ARGS...] — `roost ARGS` in a new pane of the outer
# server; OP is the pane, ON its number. Everything the pane prints goes to
# $SHAPE_TMP/pl.ON (pipe-pane: the lines printed before an attach stay
# readable after the attach has taken the screen), and roost's exit code to
# $SHAPE_TMP/rc.ON. The pane waits for its go file, so pipe-pane is in place
# before roost prints its first byte. The wrapper shell traps INT with a
# handler (never ignores it: an ignored signal is inherited, and roost could
# then not trap it): a Ctrl-C reaches the whole foreground group, and without
# it the wrapper dies before it can write roost's exit code (measured).
opane() {
  local extra="$1" go cmd; shift
  NP=$((NP + 1)); ON="$NP"; go="$SHAPE_TMP/go.$ON"
  cmd="trap true INT; e=\$((\$(date +%s) + 30)); while [ ! -e $go ] && [ \$(date +%s) -lt \$e ]; do sleep 0.1; done; env $OFFER_UNSET ROOST_SOCKET=roost $extra $ROOST $*; echo \$? > $SHAPE_TMP/rc.$ON; exec sleep 600"
  if ! CLT has-session 2>/dev/null; then
    CLT -f /dev/null new-session -d -s c0 -x 220 -y 50 "$cmd"
    OP="$(CLT display -p -t c0: '#{pane_id}')"
  else
    OP="$(CLT new-window -d -P -F '#{pane_id}' -t c0: "$cmd")"
  fi
  CLT pipe-pane -t "$OP" "cat >> $SHAPE_TMP/pl.$ON"
  : > "$go"
}
plog() { cat "$SHAPE_TMP/pl.$1" 2>/dev/null | tr -d '\r'; }
in_log() { plog "$1" | grep -qF -- "$2"; }
rc_of() { cat "$SHAPE_TMP/rc.$1" 2>/dev/null; }
# The pid in offer/'s owner record (§3.5's owner rule: "PID LSTART").
offer_pid() { readlink "$SD/offer/owner" 2>/dev/null | cut -d' ' -f1; }
SUMMARY="roost: a saved fleet from"
done_outer() { CLT kill-server 2>/dev/null; stop_server; }

# ============================================================================
# Task 7.3 — when the offer is asked, its lock, and the pin
# ============================================================================
echo "== §8.1 test 12 (a): shown, and pinned =="
fresh_dir
S0="$(sg "$SD/shape")"
opane "ROOST_TEST_NOW=$(( $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' 2026-11-01T10:00:00Z +%s 2>/dev/null || date -u -d 2026-11-01T10:00:00Z +%s) + 7200 ))"
wait_for "in_log $ON '$SUMMARY'" 10; assert_true $? "a bare roost shows the summary"
sl="$(plog "$ON" | grep -F "$SUMMARY" | head -1)"
assert_contains "$sl" "2 sessions" "...naming 2 sessions"
assert_contains "$sl" "4 panes" "...4 panes"
assert_contains "$sl" "1 of 2 agents would resume" "...1 of 2 agents would resume"
assert_contains "$sl" "from 2 h ago" "...and an age from ROOST_TEST_NOW"
assert_true "$(in_log "$ON" "l restore at login from now on: off" && echo 0 || echo 1)" "...then the keys line, l off"
TL ls >/dev/null 2>&1; assert_eq "$?" "1" "no inner server exists while it waits"
pid="$(offer_pid)"
assert_contains "$(ps -o args= -p "$pid" 2>/dev/null)" "bin/roost" "offer/ names the offer's pid"
assert_eq "$(ino "$SD/offer/save")" "$(ino "$SD/shape")" "offer/save is the planted save (its inode)"
assert_eq "$(cat "$SD/offer/stamp" 2>/dev/null)" "$S0" "offer/stamp holds its STAMP-GEN"
# The shape directory's rule (§3.1, §8.1's guards): 0700, every file 0600.
assert_eq "$(ls -ld "$SD/offer" | cut -c1-10)" "drwx------" "offer/ is 0700"
assert_eq "$(find "$SD/offer" -type f ! -perm 600 | sed "s|$SD/||" | tr '\n' ' ')" "" "...and every file in it 0600"
out="$(R restore --dry-run --from "$S0" 2>&1)"
assert_contains "$out" "from $S0" "a second terminal's --dry-run --from STAMP-GEN finds it"
CLT send-keys -t "$OP" C-c
wait_for "[ -n \"\$(rc_of $ON)\" ]" 10
assert_eq "$(rc_of "$ON")|$([ -e "$SD/offer" ] && echo held || echo free)" "130|free" "Ctrl-C: exit 130, offer/ released"
assert_eq "$(head -c 1 "$SD/shape")" "#" "(the control) the save asked about above starts with its notes (#234)"
# #234: the same save without its notes — one an older roost wrote — is
# asked about in the same words.
done_outer
PLANT_OLD=1 fresh_dir
assert_eq "$(grep -c '^#' "$SD/shape")" "0" "(the control) an old save: no notes"
opane "ROOST_TEST_NOW=$(( $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' 2026-11-01T10:00:00Z +%s 2>/dev/null || date -u -d 2026-11-01T10:00:00Z +%s) + 7200 ))"
wait_for "in_log $ON '$SUMMARY'" 10; assert_true $? "an old save without notes: the summary is shown"
assert_eq "$(plog "$ON" | grep -F "$SUMMARY" | head -1)" "$sl" "...the same summary line as the save with notes"
CLT send-keys -t "$OP" C-c; wait_for "[ -n \"\$(rc_of $ON)\" ]" 10
fresh_dir
opane "" new x
wait_for "in_log $ON '$SUMMARY'" 10; assert_true $? "roost new x with the server down asks too"
CLT send-keys -t "$OP" C-c; wait_for "[ -n \"\$(rc_of $ON)\" ]" 10
done_outer

echo "== §8.1 test 12 (b): not shown without a person =="
for how in stdin pipe; do
  fresh_dir
  if [ "$how" = stdin ]; then out="$(env $OFFER_UNSET ROOST_SOCKET=roost "$ROOST" < /dev/null 2>&1)"
  else out="$(env $OFFER_UNSET ROOST_SOCKET=roost "$ROOST" 2>&1 | cat)"; fi
  assert_not_contains "$out" "$SUMMARY" "$how: no summary line"
  wait_for "[ \"\$(sessions)\" = 'main ' ]" 5
  assert_eq "$(sessions)" "main " "$how: the inner server starts with today's one session"
  assert_eq "$([ -e "$SD/declined" ] && echo yes || echo no)" "no" "$how: declined is not written"
done
for m in CLAUDECODE=1 CODEX_THREAD_ID=x COPILOT_CLI=1 PI_CODING_AGENT=1 AI_AGENT=1 ROOST_NO_OFFER=1 --no-offer; do
  fresh_dir
  case "$m" in --*) opane "" "$m" ;; *) opane "$m" ;; esac
  wait_for "[ \"\$(sessions)\" = 'main ' ]" 5
  assert_eq "$(sessions)" "main " "$m: within 5 s the inner server holds today's one session"
  assert_true "$(in_log "$ON" "$SUMMARY" && echo 1 || echo 0)" "$m: ...no summary line"
  assert_eq "$([ -e "$SD/declined" ] || [ -e "$SD/offer" ] && echo yes || echo no)" "no" "$m: ...neither declined nor offer/"
  done_outer
done

echo "== §8.1 test 12 (c): not shown when declined; a new save of it is =="
fresh_dir
ln "$SD/shape" "$SD/declined"
opane ""
wait_for "[ \"\$(sessions)\" = 'main ' ]" 5
assert_eq "$(sessions)" "main " "declined: the inner server starts as today"
assert_true "$(in_log "$ON" "$SUMMARY" && echo 1 || echo 0)" "...with no summary line"
done_outer
rm -f "$SD/shape"; plant shared 6
opane ""
wait_for "in_log $ON '$SUMMARY'" 10; assert_true $? "the same fleet saved again (another gen) is asked about"
CLT send-keys -t "$OP" C-c; wait_for "[ -n \"\$(rc_of $ON)\" ]" 10
done_outer

echo "== §8.1 test 12 (d): not shown when the service is on =="
fresh_dir
: > "$SD/persist"; rm -rf "$SD/login"
opane ""
wait_for "[ \"\$(sessions)\" = 'main work ' ]" 10
assert_eq "$(sessions)" "main work " "persist marker, no login marker: the self-restore places the fleet"
assert_true "$(in_log "$ON" "$SUMMARY" && echo 1 || echo 0)" "...and no prompt"
done_outer
rm -f "$SD/persist"

echo "== §8.1 test 12 (e): not shown when nothing is worth offering, or not here =="
fresh_dir
mkdir -p "$SD/closed/$OLDBOOT"; printf '%%1\n%%2\n%%3\n%%4\n' > "$SD/closed/$OLDBOOT/close.1"
opane ""
wait_for "[ \"\$(sessions)\" = 'main ' ]" 5
assert_true "$(in_log "$ON" "$SUMMARY" && echo 1 || echo 0)" "closed on purpose: no prompt"
done_outer
fresh_dir one
opane ""
wait_for "[ \"\$(sessions)\" = 'main ' ]" 5
assert_true "$(in_log "$ON" "$SUMMARY" && echo 1 || echo 0)" "one unkeyed shell: no prompt"
done_outer
fresh_dir
opane "ROOST_SHAPE_DIR="
wait_for "[ \"\$(sessions)\" = 'main ' ]" 5
assert_true "$(in_log "$ON" "$SUMMARY" && echo 1 || echo 0)" "ROOST_SHAPE_DIR=: no prompt"
done_outer
fresh_dir
opane "" spawn x sh
wait_for "[ -n \"\$(rc_of $ON)\" ]" 10
assert_eq "$(rc_of "$ON")" "0" "roost spawn x sh with the server down: exit 0"
assert_true "$(in_log "$ON" "$SUMMARY" && echo 1 || echo 0)" "...and no prompt"
done_outer
stop_server; rm -rf "$SD"; mkdir -p "$SD"; PLANT_HOST=elsewhere.example plant shared
opane ""
wait_for "[ \"\$(sessions)\" = 'main ' ]" 5
assert_true "$(in_log "$ON" "$SUMMARY" && echo 1 || echo 0)" "another host: no prompt"
assert_true "$(in_log "$ON" "roost: a fleet saved on elsewhere.example is not offered here (roost restore --list)" && echo 0 || echo 1)" "...and the not-offered-here line"
done_outer

echo "== §8.1 test 12 (j), the lock half: two terminals, one offer =="
fresh_dir
opane ""; A="$OP" AN="$ON"
opane ""; B="$OP" BN="$ON"
wait_for "{ in_log $AN '$SUMMARY' || in_log $BN '$SUMMARY'; } && { in_log $AN 'waiting for the restore offer in another terminal' || in_log $BN 'waiting for the restore offer in another terminal'; }" 10
if in_log "$AN" "$SUMMARY"; then F="$A" FN="$AN" W="$B" WN="$BN"; else F="$B" FN="$BN" W="$A" WN="$AN"; fi
assert_true "$(in_log "$FN" "$SUMMARY" && echo 0 || echo 1)" "one terminal shows the summary"
assert_true "$(in_log "$WN" "waiting for the restore offer in another terminal (pid $(offer_pid))" && echo 0 || echo 1)" "...the other waits for it, naming its pid"
assert_true "$(in_log "$WN" "$SUMMARY" && echo 1 || echo 0)" "...and shows no summary"
kill -9 "$(offer_pid)"
wait_for "in_log $WN '$SUMMARY'" 10; assert_true $? "kill -9 the first: the second takes offer/ over and asks"
CLT send-keys -t "$W" C-c; wait_for "[ -n \"\$(rc_of $WN)\" ]" 10
done_outer

# ============================================================================
# Task 7.4 — the prompt: p, n, Enter, no answer, Ctrl-C
# ============================================================================
KEEP="$SHAPE_TMP/planted.keep"
# replant — the inner server stopped by its path, the planted save made
# `shape` again (`rm shape && ln SAVE shape`), offer and decline untouched.
replant() { done_outer; rm -f "$SD/shape"; ln "$KEEP" "$SD/shape"; }
NOW_T="$(( $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' 2026-11-01T10:00:00Z +%s 2>/dev/null || date -u -d 2026-11-01T10:00:00Z +%s) + 7200 ))"
asked() { wait_for "in_log $1 '$SUMMARY'" 10; }

echo "== §8.1 test 12 (b): no answer =="
fresh_dir; rm -f "$KEEP"; ln "$SD/shape" "$KEEP"; S0="$(sg "$SD/shape")"
opane "ROOST_TEST_OFFER_TIMEOUT=2"
asked "$ON"; assert_true $? "(fixture) asked"
wait_for "in_log $ON 'roost: no answer in 2 s; started fresh, nothing declined (roost restore --from $S0 brings it back)'" 10
assert_true $? "2 s later, the no-answer line"
wait_for "[ \"\$(sessions)\" = 'main ' ]" 5
assert_eq "$(sessions)" "main " "...the inner server holds one fresh main"
assert_eq "$([ -e "$SD/declined" ] && echo yes || echo no)|$([ -e "$SD/offer" ] && echo held || echo free)" "no|free" "...no declined, offer/ gone"
replant
opane ""
asked "$ON"; assert_true $? "re-planted: roost asks again"
CLT send-keys -t "$OP" C-c; wait_for "[ -n \"\$(rc_of $ON)\" ]" 10
done_outer

echo "== §8.1 test 12 (f): p previews, then asks again; the bound ends at the first key =="
fresh_dir; S0="$(sg "$SD/shape")"
opane "ROOST_TEST_NOW=$NOW_T ROOST_TEST_OFFER_TIMEOUT=2"
asked "$ON"
CLT send-keys -t "$OP" p
wait_for "[ \"\$(plog $ON | grep -cF '$SUMMARY')\" -ge 2 ]" 10
want="$(ROOST_TEST_NOW=$NOW_T R restore --dry-run --from "$S0" 2>/dev/null)"
got="$(plog "$ON")"
case "$got" in *"$want"*) r=0 ;; *) r=1 ;; esac
assert_true "$r" "p prints, line for line, what a separate restore --dry-run --from STAMP-GEN prints"
assert_contains "$(printf '%s\n' "$got" | grep '^    pane ' | grep "$DG")" "directory gone" "...the gone directory's pane reads directory gone"
after="$(printf '%s\n' "$got" | sed -n '/^from /,$p')"
assert_contains "$after" "$SUMMARY" "...and below it the summary again"
assert_contains "$(printf '%s\n' "$after" | tail -2)" "l restore at login from now on: off" "...and the keys line"
assert_not_contains "$got" "restoring the newest save" "ROOST_SHUTDOWN_AT= empty: no 'restoring the newest save' line"
TL ls >/dev/null 2>&1; assert_eq "$?" "1" "...the inner server still does not exist"
sleep 5
assert_true "$(in_log "$ON" "no answer in" && echo 1 || echo 0)" "timeout 2, p, then 5 s of silence: no no-answer line"
TL ls >/dev/null 2>&1; assert_eq "$?" "1" "...no inner server"
assert_contains "$(CLT capture-pane -p -J -t "$OP" | grep -v '^$' | tail -2)" "l restore at login from now on" "...the keys line still on screen, last"
CLT send-keys -t "$OP" n
wait_for "[ -e '$SD/declined' ]" 10
assert_eq "$(ino "$SD/declined")" "$(ino "$SD/shape")" "then n writes declined, a link to the pin"
done_outer

echo "== §8.1 test 12 (h): n records the decline =="
fresh_dir; S0="$(sg "$SD/shape")"; PIN_INO="$(ino "$SD/shape")"
opane "ROOST_SHAPE_KEEP=2"
asked "$ON"
CLT send-keys -t "$OP" n
wait_for "[ \"\$(sessions)\" = 'main ' ]" 10
assert_eq "$(ino "$SD/declined")" "$PIN_INO" "declined is a hard link to the pin"
assert_eq "$(ls -l "$SD/declined" | cut -c1-10)" "-rw-------" "...0600"
wait_for "in_log $ON 'not restored; roost restore --from $S0 brings it back (doctor names it too)'" 5
assert_true $? "the screen names roost restore --from STAMP-GEN"
hint="$(plog "$ON" | grep -F 'the saved "main" is skipped while a "main" runs' | head -1)"
assert_contains "$hint" "tmux -L roost rename-session -t main main-fresh, then roost restore --from $S0" "...and the rename hint"
assert_eq "$(sessions)" "main " "...the inner server holds one fresh main"
assert_eq "$([ -e "$SD/offer" ] && echo held || echo free)" "free" "...and offer/ is released"
for i in 1 2 3 4 5; do ROOST_SHAPE_KEEP=2 R spawn "s$i" sh >/dev/null 2>&1; shape_settle "$SD" || true; done
assert_eq "$(ls "$SD/history" | grep -c "^$S0\$" || true)" "0" "(fixture) the ring has dropped the declined save"
last="$(R restore --list 2>&1 | grep -v '^    ' | grep -v '^pending' | tail -1)"
assert_contains "$last" "$S0" "restore --list lists it last"
assert_contains "$last" "declined" "...marked declined"
c1="$(printf '%s' "$hint" | sed 's/.*runs: //; s/, then .*//')"
c2="$(printf '%s' "$hint" | sed 's/.*, then //')"
eval "$c1"; assert_eq "$?" "0" "the hint's first command runs as printed ($c1)"
case "$c2" in "roost restore --from $S0") ;; *) echo "  (unexpected second command: $c2)" ;; esac
R restore --from "$S0" >/dev/null 2>&1
assert_contains "$(sessions)" "main main-fresh" "...then its second: main is restored, the fresh one is main-fresh"
assert_contains "$(sessions)" "work" "...and work is restored"
done_outer

echo "== §8.1 test 12 (i): Enter starts fresh without declining; Ctrl-C leaves =="
fresh_dir; rm -f "$KEEP"; ln "$SD/shape" "$KEEP"; S0="$(sg "$SD/shape")"
opane ""
asked "$ON"
CLT send-keys -t "$OP" Enter
wait_for "[ \"\$(sessions)\" = 'main ' ]" 10
assert_eq "$(sessions)" "main " "Enter: one fresh main"
wait_for "in_log $ON 'not restored, not declined; roost restore --from $S0 brings it back'" 5
assert_true $? "...the line says not declined"
assert_eq "$([ -e "$SD/declined" ] && echo yes || echo no)" "no" "...no declined"
replant
opane ""
asked "$ON"; assert_true $? "re-planted: asked again"
CLT send-keys -t "$OP" C-c; wait_for "[ -n \"\$(rc_of $ON)\" ]" 10
assert_eq "$(rc_of "$ON")" "130" "Ctrl-C exits 130"
TL ls >/dev/null 2>&1; assert_eq "$?" "1" "...starts no server"
assert_eq "$([ -e "$SD/declined" ] && echo yes || echo no)" "no" "...writes no declined"
opane ""
asked "$ON"; assert_true $? "...and the next roost asks"
CLT send-keys -t "$OP" C-c; wait_for "[ -n \"\$(rc_of $ON)\" ]" 10
done_outer

echo "== §8.1 test 12 (j), the n half: the other terminal attaches, never asked =="
fresh_dir
opane ""; A="$OP" AN="$ON"
opane ""; B="$OP" BN="$ON"
wait_for "{ in_log $AN '$SUMMARY' || in_log $BN '$SUMMARY'; } && { in_log $AN 'waiting for the restore offer' || in_log $BN 'waiting for the restore offer'; }" 10
if in_log "$AN" "$SUMMARY"; then F="$A" W="$B" WN="$BN"; else F="$B" W="$A" WN="$AN"; fi
CLT send-keys -t "$F" n
wait_for "[ \"\$(TL list-clients 2>/dev/null | grep -c .)\" -ge 2 ]" 10
assert_eq "$(TL list-clients 2>/dev/null | grep -c .)" "2" "n in the first: the second attaches to the running server"
assert_true "$(in_log "$WN" "$SUMMARY" && echo 1 || echo 0)" "...and never shows a summary line"
assert_eq "$(sessions)" "main " "...one main, no prompt"
done_outer

# ============================================================================
# Task 7.5 — r and l
# ============================================================================
PLIST="$HOME/Library/LaunchAgents/dev.roosting.roost.roost.plist"
UNIT="$XDG_CONFIG_HOME/systemd/user/roost-persist-roost.service"
FAILSTUBS="$SHAPE_TMP/fail-stubs"; mkdir -p "$FAILSTUBS"
printf '%s\n' '#!/bin/sh' 'printf "launchctl %s\n" "$*" >> "$PERSIST_LOG"' 'exit 1' > "$FAILSTUBS/launchctl"
cp "$STUBS/uname" "$FAILSTUBS/uname"; chmod +x "$FAILSTUBS/launchctl"
clients() { TL list-clients 2>/dev/null | grep -c .; }
launches() { grep -c -- "--resume " "$STUB_LOG" 2>/dev/null || true; }
attached_to() { TL list-clients -F '#{client_session}' 2>/dev/null | head -1; }
persist_off() { stop_server; rm -f "$PLIST" "$UNIT" "$SD/persist" "$SD/service.env"; }
WRITE_ONLY="ROOST_PERSIST_WRITE_ONLY=1 STUB_UNAME=Darwin PATH=$STUBS:$PATH"

echo "== §8.1 test 12 (g): l then r — placement first, the service after, agents after the attach =="
fresh_dir g; : > "$STUB_LOG"
H="$SHAPE_TMP/place.hold"; rm -f "$H"
opane "$WRITE_ONLY ROOST_TEST_PLACE_HOLD=$H"
asked "$ON"
CLT send-keys -t "$OP" l
wait_for "[ \"\$(CLT capture-pane -p -J -t $OP | grep -c 'l restore at login from now on: on')\" -ge 1 ]" 5
assert_true $? "after l the keys line reads on"
CLT send-keys -t "$OP" r
wait_for "[ -e '$SD/restoring' ] && TL ls >/dev/null 2>&1" 10
sleep 0.5
assert_eq "$([ -e "$SD/restoring" ] && echo held || echo free)" "held" "r: while placement is held, restoring/ exists"
assert_eq "$([ -e "$PLIST" ] || [ -e "$SD/persist" ] && echo yes || echo no)" "no" "...and neither the unit nor the persist marker exists"
assert_eq "$(launches)" "0" "...and nothing is launched"
: > "$H"
wait_for "[ \"\$(clients)\" -ge 1 ]" 15
assert_eq "$([ -e "$PLIST" ] && [ -e "$SD/persist" ] && echo yes || echo no)" "yes" "released: the unit and the persist marker exist"
assert_eq "$([ -e "$SD/restoring" ] && echo held || echo free)" "free" "...restoring/ is gone"
assert_eq "$(sessions)" "main work " "...the inner server holds both saved sessions"
assert_eq "$([ -e "$SD/offer" ] && echo held || echo free)" "free" "...and offer/ is released"
wait_for "[ \"\$(launches)\" -ge 2 ]" 15; sleep 2.5
assert_eq "$(launches)" "2" "the two agents are launched, once each"
assert_eq "$(grep -- '--resume ' "$STUB_LOG" | awk '{print $NF}' | sort | tr '\n' ' ')" "$U1 $U2 " "...each its own key"
ca="$(TL list-clients -F '#{client_created}' 2>/dev/null | sort -n | head -1)"
l1="$(grep -- '--resume ' "$STUB_LOG" | awk 'NR==1{print $1}')"; l2="$(grep -- '--resume ' "$STUB_LOG" | awk 'NR==2{print $1}')"
assert_true "$([ -n "$ca" ] && [ "$l1" -ge "$ca" ] && echo 0 || echo 1)" "...only after the attach (attach $ca, first launch $l1)"
assert_true "$([ $((l2 - l1)) -ge 1 ] && [ $((l2 - l1)) -le 4 ] && echo 0 || echo 1)" "...2 s apart ($((l2 - l1)) s)"
done_outer; persist_off

echo "== (g) a failing persist on is never fatal =="
fresh_dir g
opane "STUB_UNAME=Darwin PATH=$FAILSTUBS:$PATH"
asked "$ON"
CLT send-keys -t "$OP" l; sleep 0.3; CLT send-keys -t "$OP" r
wait_for "[ \"\$(clients)\" -ge 1 ]" 15
assert_true "$(in_log "$ON" "roost: persist on failed; the fleet is restored this time only" && echo 0 || echo 1)" "persist on failed is on the screen"
assert_eq "$(clients)" "1" "...and the client is attached anyway"
done_outer; persist_off

echo "== (g) the shared fixture: r writes one pending file only =="
fresh_dir; : > "$STUB_LOG"
opane ""
asked "$ON"; CLT send-keys -t "$OP" r
wait_for "[ \"\$(clients)\" -ge 1 ]" 15
B="$(live_boot)"
wait_for "[ \"\$(launches)\" -ge 1 ]" 10; sleep 2.5
assert_eq "$(ls "$SD/pending/$B" 2>/dev/null | grep -c .)" "1" "one pending file (the gone directory's pane gets none)"
assert_eq "$(grep -c -- "$U3" "$STUB_LOG" || true)" "0" "...and that pane is never launched"
done_outer

echo "== (g) which session: a fleet with no main attaches to its active session =="
fresh_dir ops
opane ""
asked "$ON"; CLT send-keys -t "$OP" r
wait_for "[ \"\$(clients)\" -ge 1 ]" 15
assert_eq "$(attached_to)" "ops" "the client is attached to ops, the pin's active session"
assert_true "$(in_log "$ON" 'roost: attaching to "ops", the restored fleet'"'"'s active session (it has no "main")' && echo 0 || echo 1)" "...the screen names it"
assert_eq "$(sessions)" "ops work " "...and no main exists"
done_outer

echo "== (g) l then silence: still waiting, nothing started, nothing enabled =="
fresh_dir g; : > "$PERSIST_LOG"
opane "$WRITE_ONLY ROOST_TEST_OFFER_TIMEOUT=2"
asked "$ON"; CLT send-keys -t "$OP" l
sleep 5
assert_contains "$(CLT capture-pane -p -J -t "$OP" | grep -v '^$' | tail -2)" "l restore at login from now on: on" "the offer still waits, the keys line reads on"
assert_true "$(in_log "$ON" "no answer in" && echo 1 || echo 0)" "...no no-answer line"
TL ls >/dev/null 2>&1; assert_eq "$?" "1" "...no inner server"
assert_eq "$([ -e "$PLIST" ] || [ -e "$SD/persist" ] && echo yes || echo no)|$(grep -c . "$PERSIST_LOG" || true)" "no|0" "...no service: no unit, no marker, no load call"
CLT send-keys -t "$OP" C-c; wait_for "[ -n \"\$(rc_of $ON)\" ]" 10
done_outer; persist_off

echo "== §8.1 test 12 (h3): l with a login job that really runs, and a planted lock =="
for branch in n Enter linux; do
  fresh_dir; P0="$(ino "$SD/shape")"; G0="$(cat "$SD/gen")"; : > "$PERSIST_LOG"
  os=Darwin; [ "$branch" = linux ] && os=Linux
  # The lock/ of a saver that never finishes: a sleep this test owns, in
  # §3.5 step 1's owner format, so every saver meets a live owner.
  sleep 120 & SLEEPER=$!
  mkdir -p "$SD/lock"; ln -s "$SLEEPER $(roost_shape__lstart_read "$SLEEPER")" "$SD/lock/owner"
  ONLOAD="env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost $ROOST persist --at-login roost"
  opane "STUB_UNAME=$os PATH=$STUBS:$PATH PERSIST_ON_LOAD='$ONLOAD' PERSIST_ON_ENABLE='$ONLOAD'"
  asked "$ON"; CLT send-keys -t "$OP" l; sleep 0.3
  case "$branch" in n|linux) CLT send-keys -t "$OP" n ;; Enter) CLT send-keys -t "$OP" Enter ;; esac
  wait_for "TL has-session -t =main 2>/dev/null" 10; sleep 2
  assert_eq "$(grep -c 'bootstrap\|enable' "$PERSIST_LOG" || true)" "0" "$branch: while the lock's owner lives, no load call"
  assert_eq "$([ -e "$PLIST" ] || [ -e "$UNIT" ] && echo yes || echo no)" "no" "$branch: ...no unit file"
  assert_eq "$(ino "$SD/shape")" "$P0" "$branch: ...shape is still the planted save"
  if [ "$branch" = Enter ]; then
    assert_eq "$([ -e "$SD/declined" ] && echo yes || echo no)" "no" "$branch: ...no declined"
  else
    assert_eq "$(ino "$SD/declined")" "$P0" "$branch: ...declined exists"
  fi
  kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=""
  wait_for "grep -q 'bootstrap\|enable' '$PERSIST_LOG'" 40
  assert_true $? "$branch: the owner gone, persist on saves and the load is logged"
  wait_for "grep -q 'placed ' '$SD/login.log' 2>/dev/null" 15
  assert_contains "$(cat "$SD/login.log" 2>/dev/null)" "placed 0 sessions" "$branch: login.log: the job ran and skipped every session"
  B="$(live_boot)"
  assert_eq "$(ls "$SD/pending/$B" 2>/dev/null | grep -c . || true)" "0" "$branch: ...no pending file"
  assert_eq "$(sessions)" "main " "$branch: ...one fresh main only"
  if [ "$branch" = linux ]; then
    assert_contains "$(cat "$PERSIST_LOG")" "systemctl --user enable roost-persist-roost.service" "linux: the recorded argv"
    assert_not_contains "$(cat "$PERSIST_LOG")" "--now" "linux: ...holds no --now"
  fi
  done_outer; persist_off; rm -rf "$SD/lock"
done

echo "== §8.1 test 12 (k): a script starts the server mid-prompt =="
fresh_dir; S0="$(sg "$SD/shape")"
opane ""
asked "$ON"
R spawn x sh >/dev/null 2>&1
wait_for "[ \"\$(sed -n 's/^boot //p;/^\$/q' '$SD/shape')\" = \"\$(live_boot)\" ]" 10
assert_true $? "(fixture) the script's fresh save names the live boot"
CLT send-keys -t "$OP" r
wait_for "[ \"\$(clients)\" -ge 1 ]" 15
assert_true "$(in_log "$ON" "roost restore: session 'main' exists" && echo 0 || echo 1)" "r: the report skips the saved main as existing"
assert_eq "$(sessions)" "main work " "...restores work from the pin"
assert_eq "$(TL list-panes -t =work -s 2>/dev/null | grep -c .)" "2" "...with both its saved panes"
assert_eq "$(clients)" "1" "...and the client attaches"
done_outer

echo "== §8.1 test 12 (k2): the ring turns over while the offer waits =="
fresh_dir; S0="$(sg "$SD/shape")"; P0="$(ino "$SD/shape")"
mkdir -p "$SD/closed/$OLDBOOT"; printf '%%3\n' > "$SD/closed/$OLDBOOT/close.3"
opane "ROOST_TEST_NOW=$NOW_T"
asked "$ON"
assert_contains "$(plog "$ON" | grep -F "$SUMMARY" | head -1)" "3 panes" "(fixture) the closed pane is not counted: 3 panes"
ROOST_SHAPE_KEEP=3 R spawn k1 sh >/dev/null 2>&1
for i in 2 3 4 5 6; do
  if [ $((i % 2)) = 0 ]; then ROOST_SHAPE_KEEP=3 R split -t main:k1 sh >/dev/null 2>&1; else ROOST_SHAPE_KEEP=3 R spawn "k$i" sh >/dev/null 2>&1; fi
  shape_settle "$SD" || true
done
assert_eq "$(ls "$SD/history" | grep -c "^$S0\$" || true)" "0" "(fixture) the pinned save has no history/ name left"
R persist --at-login roost >/dev/null 2>&1
assert_eq "$([ -d "$SD/closed/$OLDBOOT" ] && echo kept || echo swept)" "kept" "an --at-login cleanup meanwhile keeps the pin's closed/ record"
CLT send-keys -t "$OP" p
wait_for "[ \"\$(plog $ON | grep -cF '$SUMMARY')\" -ge 2 ]" 10
want="$(ROOST_TEST_NOW=$NOW_T R restore --dry-run --from "$S0" 2>/dev/null)"
got="$(plog "$ON")"
assert_eq "$(cat "$SD/offer/stamp")|$(ino "$SD/offer/save")" "$S0|$P0" "p: offer/stamp and offer/save are still the pin"
tree="$(printf '%s\n' "$got" | sed -n "/^from $S0/,/^roost: a saved fleet/p")"
assert_contains "$tree" "session main (exists - skipped" "...the tree names the saved main as existing and skipped"
assert_contains "$tree" "$DG" "...its work block holds the saved %4"
assert_eq "$(printf '%s\n' "$tree" | grep -c '^session work' || true)" "1" "...and work is in it"
assert_eq "$(printf '%s\n' "$tree" | grep -A3 '^session work' | grep -c '^    pane ' || true)" "1" "...still without %3 (one pane in work)"
case "$got" in *"$want"*) r=0 ;; *) r=1 ;; esac
assert_true "$r" "...and it is line for line a same-moment restore --dry-run --from STAMP-GEN"
CLT send-keys -t "$OP" n
wait_for "[ -e '$SD/declined' ]" 10
assert_eq "$(ino "$SD/declined")" "$P0" "n: declined has the pin's inode"
assert_eq "$([ -d "$SD/closed/$OLDBOOT" ] && echo kept || echo swept)" "kept" "...closed/<boot>/ still exists"
wait_for "[ \"\$(clients)\" -ge 1 ]" 10
TL kill-session -t =work 2>/dev/null
R restore --from "$S0" >/dev/null 2>&1
assert_eq "$(TL list-panes -s -t =work 2>/dev/null | grep -c .)" "1" "roost restore --from STAMP-GEN restores work without %3"
done_outer

echo "== §8.1 test 12 (k3): r on a pin with a closed pane =="
fresh_dir k3; : > "$STUB_LOG"
mkdir -p "$SD/closed/$OLDBOOT"; printf '%%3\n' > "$SD/closed/$OLDBOOT/close.3"
opane ""
asked "$ON"
sl="$(plog "$ON" | grep -F "$SUMMARY" | head -1)"
assert_contains "$sl" "2 sessions" "the summary counts 2 sessions"
assert_contains "$sl" "2 panes" "...2 panes"
assert_contains "$sl" "2 of 2 agents would resume" "...2 of 2 agents would resume"
CLT send-keys -t "$OP" r
wait_for "[ \"\$(clients)\" -ge 1 ]" 15
B="$(live_boot)"
assert_eq "$(TL list-panes -s -t =work 2>/dev/null | grep -c .)" "1" "the restored work has one pane"
assert_eq "$(TL list-panes -a -F '#{@roost-was}' | grep -cx '%3' || true)" "0" "...no pane carries @roost-was %3"
assert_eq "$(grep -l '^was %2$' "$SD/pending/$B"/%* 2>/dev/null | grep -c . || true)" "1" "...%2 has its pending file"
wait_for "[ \"\$(launches)\" -ge 2 ]" 15; sleep 2.5
assert_eq "$(grep -c -- "$U2" "$STUB_LOG" || true)|$(grep -c -- "$U1" "$STUB_LOG" || true)" "1|1" "after the attach %2's id and %1's are launched once each"
l1="$(grep -- '--resume ' "$STUB_LOG" | awk 'NR==1{print $1}')"; l2="$(grep -- '--resume ' "$STUB_LOG" | awk 'NR==2{print $1}')"
assert_true "$([ $((l2 - l1)) -ge 1 ] && [ $((l2 - l1)) -le 4 ] && echo 0 || echo 1)" "...2 s apart ($((l2 - l1)) s)"
done_outer

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
