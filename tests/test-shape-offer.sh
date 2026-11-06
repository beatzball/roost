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
stop_server() { TL kill-server 2>/dev/null; local i=0; while TL ls >/dev/null 2>&1 && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done; sleep 0.2; }
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
plant() {
  local fx="${1:-shared}" gen="${2:-5}" saved="${3:-2026-11-01T10:00:00Z}" out="${4:-$SD/shape}" n=0
  win() { # SESSION:IDX
    printf '%s\n' "window $1" "id @$n" "layout b25d,200x50,0,0,$n" 'active 1' ''; n=$((n+1)); }
  pane() { # ADDR ID CWD [KEYED-ID]
    printf '%s\n' "pane $1" "id $2" "cwd $3"
    [ -n "${4:-}" ] && printf '%s\n' "harness claude" "session_id $4"
    printf '\n'; }
  sess() { printf '%s\n' "session $1" "id \$$n"; [ -n "${2:-}" ] && printf 'active 1\n'; printf '\n'; n=$((n+1)); }
  { printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" "boot $OLDBOOT" \
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
inner="$(TL list-windows -a -F '#{session_name} #{window_name} #{window_panes}' | sort)"
# The control: the same spawn on a third throwaway server with saving off.
CTL="$TMUX_TMPDIR/ctl"
env -u TMUX -u TMUX_PANE ROOST_SOCKET="$CTL" ROOST_SHAPE_DIR= "$ROOST" spawn x sh >/dev/null 2>&1
ctl="$(tmux -S "$CTL" list-windows -a -F '#{session_name} #{window_name} #{window_panes}' | sort)"
tmux -S "$CTL" kill-server 2>/dev/null
assert_eq "$inner" "$ctl" "roost spawn: the ordinary fresh 'spawn x sh' shape (as on a server with no shape directory)"
assert_eq "$(TL has-session -t =work 2>/dev/null && echo yes || echo no)" "no" "...no work session"
keys="$(TL list-panes -a -F '#{@roost-session}#{@roost-was}' | tr -d '\n')"
assert_eq "$keys" "" "...no pane carries a planted key or a @roost-was"
assert_contains "$(cat "$SD/login.log")" "declined at the restore offer" "...and login.log names the decline"
stop_server
rm -f "$SD/persist"

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
