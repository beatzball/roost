#!/usr/bin/env bash
# Addressing after a restore (#191 Part 3, Task 3.9): `@roost-was %OLD` on
# every restored pane, the alias map aliases/<new boot>, and `was:%N`.
# Design: docs/airig/specs/2026-10-24-persistent-sessions-design.md §5.4 and
# §8.1 test 7 (the whole of it), test 11's "two sockets", and the §8.1 guard
# on `status --json`.
#
# THE RULE UNDER TEST. A bare %N always means a pane of the running server and
# nothing else: pane ids restart at %0 after a reboot (§2.7), so an old id
# usually EXISTS as some other pane, and a verb that redirected a miss would
# deliver to the wrong agent on a hit. A historical id is written was:%N and
# resolves through THIS boot's map only.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
shape_test_setup; trap 'shape_test_teardown; [ -n "${ASOCK:-}" ] && tmux -S "$ASOCK" kill-server 2>/dev/null' EXIT

export XDG_CONFIG_HOME="$SHAPE_TMP/config"
REC="$SHAPE_TMP/records"; mkdir -p "$REC"; export ROOST_RECORD_DIR="$REC"
ROOST="$PWD/bin/roost"
R() { env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"; mkdir -p "$SD"
BOOT="$(TL display -p '#{start_time}-#{pid}')"
TL set -g default-shell "$(command -v bash)"
export SHELL="$(command -v bash)"
D="$SHAPE_TMP/d"; mkdir -p "$D"
B1=1700000000-4242
B2=1700000999-5151
first_pane() { TL list-panes -t "=$1:$2" -F '#{pane_id}' 2>/dev/null | head -1; }
wait_screen() { local i=0; while [ "$i" -lt 30 ]; do TL capture-pane -p -t "$1" 2>/dev/null | grep -qF -- "$2" && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
# A second server, A: the shape below is A's, and nothing may be placed in it.
ASOCK="$SHAPE_TMP/a.sock"
tmux -S "$ASOCK" -f /dev/null new-session -d -s keepA 'sleep 600'

# shape BOOT SESSION:%OLD[,%OLD2] ... -> $SD/shape: one session per argument;
# one window per old id, one pane each, all in $D. Saved on server A, boot BOOT.
shape() {
  local b="$1" a n=0 w s ids id
  shift
  { printf '%s\n' 'roost-shape 1' 'server roost' "socket $ASOCK" "boot $b" \
      'saved 2026-10-28T12:00:00Z' 'gen 1' 'trigger save' 'roost 0.10.0' 'tmux 3.6' 'host h' ''
    for a in "$@"; do
      s="${a%%:*}"; ids="${a#*:}"
      printf '%s\n' "session $s" "id \$$n" ''
      w=1
      for id in $(printf '%s' "$ids" | tr ',' ' '); do
        printf '%s\n' "window $s:$w" "id @$n$w" "layout b25d,200x50,0,0,$w" '' "pane $s:$w.0" "id $id" "cwd $D" ''
        w=$((w+1))
      done
      n=$((n+1))
    done; } > "$SD/shape"
}

echo "== placement: @roost-was on every pane, and aliases/<this boot> =="
shape "$B1" "aa:%0" "bb:%930,%932"
R restore --no-resume >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "(fixture) restore exits 0"
X="$(first_pane aa 1)"; Y="$(first_pane bb 1)"; Y2="$(first_pane bb 2)"
assert_eq "$(TL show -pqv -t "$X" @roost-was)|$(TL show -pqv -t "$Y" @roost-was)|$(TL show -pqv -t "$Y2" @roost-was)" "%0|%930|%932" \
  "every restored pane carries @roost-was %OLD"
assert_eq "$(sort "$SD/aliases/$BOOT" 2>/dev/null | tr '\n' ';')" "$(printf '%s\n' "%0 $B1 $X" "%930 $B1 $Y" "%932 $B1 $Y2" | sort | tr '\n' ';')" \
  "aliases/<new boot> holds one '%OLD OLDBOOT %NEW' line per pane"
assert_eq "$(ls -l "$SD/aliases/$BOOT" | cut -c1-10)" "-rw-------" "...0600"
assert_eq "$(tmux -S "$ASOCK" list-sessions -F '#{session_name}' | tr '\n' ' ')" "keepA " \
  "two sockets: a shape saved on server A, restored into B, places nothing in A"

echo "== send was:%OLD reaches the new pane, and says so =="
R send "was:%930" "echo REACHED-930" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "send was:%930: exit 0"
assert_contains "$(cat "$SHAPE_TMP/err")" "roost send: was:%930 is $Y" "...one stderr line naming the new pane"
wait_screen "$Y" "REACHED-930"; assert_true $? "...and the text reached $Y"

echo "== read was:%OLD reads the OLD boot's record =="
od="$REC/$B1/930"; mkdir -p "$od/replies"; printf '1\n' > "$od/schema"; printf '%s\n' "$ASOCK" > "$od/socket"
printf 'THE-OLD-REPLY\n' > "$od/replies/000003"
out="$(R read "was:%930" 2>"$SHAPE_TMP/err")"; rc=$?
assert_eq "$rc|$out" "0|THE-OLD-REPLY" "read was:%930: the reply the pane gave before the reboot"
out="$(R read --turn 3 "was:%930" 2>/dev/null)"
assert_eq "$out" "THE-OLD-REPLY" "...and --turn N reads the old record's turn"

echo "== a bare %N is the live pane: the courtesy note, never a redirect =="
R send "%0" "echo BARE-ZERO" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "send %0 (a live pane that is also an old id): exit 0"
assert_contains "$(cat "$SHAPE_TMP/err")" "note: %0 was also an old id; the pane that was %0 is now $X (was:%0)" "...with the courtesy note"
wait_screen "$(TL list-panes -t '=shp:' -F '#{pane_id}' | head -1)" "BARE-ZERO"; assert_true $? "...delivered to the live %0, as asked"
TL capture-pane -p -t "$X" | grep -q BARE-ZERO; assert_eq "$?" "1" "...and not to the pane that was %0"
R send "%777" "x" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "2" "a bare %N that names nothing: exit 2"
grep -q "was" "$SHAPE_TMP/err"; assert_eq "$?" "1" "...no redirect, no mention of the map"
R send "was:%555" "x" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "2" "was:%N not in the map: exit 2"
assert_contains "$(cat "$SHAPE_TMP/err")" "was:%555" "...naming it"

echo "== a map file from another boot is never read =="
printf '%%444 %s %s\n' "$B1" "$Y" > "$SD/aliases/1600000000-1"
R send "was:%444" "x" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "2" "an old id only another boot's map knows: exit 2"

echo "== two restores with the same old id: ambiguous, and each long form delivers =="
shape "$B2" "cc:%930"
R restore --no-resume >/dev/null 2>&1
Z="$(first_pane cc 1)"
R send "was:%930" "x" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "2" "was:%930 in two old boots: exit 2"
assert_contains "$(cat "$SHAPE_TMP/err")" "was:%930@$B1" "...naming was:%930@$B1"
assert_contains "$(cat "$SHAPE_TMP/err")" "was:%930@$B2" "...and was:%930@$B2"
R send "was:%930@$B2" "echo LONG-FORM-B2" >/dev/null 2>&1; rc=$?
wait_screen "$Z" "LONG-FORM-B2"; assert_eq "$rc|$?" "0|0" "was:%930@$B2 delivers to $Z"
R send "was:%930@$B1" "echo LONG-FORM-B1" >/dev/null 2>&1; rc=$?
wait_screen "$Y" "LONG-FORM-B1"; assert_eq "$rc|$?" "0|0" "was:%930@$B1 delivers to $Y"

echo "== one save restored twice into one boot: the NEWEST line wins (review round 1, B1) =="
# The spec's own recovery path (§4.3: a session skipped because a key took
# its bootstrap comes back with kill-session, then restore --only) restores
# the same save into one boot twice, so the map holds two lines for one
# (old id, old boot). The first restore's pane is gone; the second's is live.
B3=1700002222-7373
shape "$B3" "dd:%950"
# The second restore names its save (restore's own advice now says --from):
# since Part 4 the kill-session below is recorded for this boot and the
# newest save no longer holds dd, so a plain `restore --only dd` finds
# nothing (§3.6). By path, because every fixture save here has the same
# stamp and gen, so a STAMP-GEN could name an earlier fixture's file.
cp "$SD/shape" "$SHAPE_TMP/dd.shape"
R restore --no-resume >/dev/null 2>&1
G1="$(first_pane dd 1)"
TL kill-session -t '=dd'
R restore --no-resume --from "$SHAPE_TMP/dd.shape" --only dd >/dev/null 2>&1
G2="$(first_pane dd 1)"
[ -n "$G1" ] && [ -n "$G2" ] && [ "$G1" != "$G2" ]; assert_true $? "(fixture) two restores of dd: $G1 (killed), then $G2"
R send "was:%950" "echo SECOND-RESTORE" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
wait_screen "$G2" "SECOND-RESTORE"
assert_eq "$rc|$?" "0|0" "send was:%950 reaches the pane of the newer restore ($G2)"
assert_contains "$(cat "$SHAPE_TMP/err")" "was:%950 is $G2" "...and names it"
out="$(R screen "was:%950" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "screen was:%950: exit 0"
assert_contains "$out" "SECOND-RESTORE" "...the newer pane's screen"

echo "== the other verbs resolve it too =="
out="$(R screen "was:%930@$B1" 2>/dev/null)"; assert_contains "$out" "LONG-FORM-B1" "screen was:%930@BOOT"
R wait-done "was:%932" 1 >/dev/null 2>"$SHAPE_TMP/err"
assert_contains "$(cat "$SHAPE_TMP/err")" "was:%932 is $Y2" "wait-done was:%N resolves (and says so)"
R close "was:%930@$B1" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(TL list-panes -a -F '#{pane_id}' | grep -cx -- "$Y")" "0|0" "close was:%OLD closes the new pane"
R close "was:%930@$B1" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "was:%N whose pane is gone: exit 2, today's message"

echo "== status: was in --json (null when none), (was %N) on the human line =="
if command -v python3 >/dev/null 2>&1; then
  got="$(R status --json | python3 -c 'import json,sys
d = json.load(sys.stdin)
w = {p["id"]: p.get("was", "MISSING") for p in d["panes"]}
print(w.get(sys.argv[1]), w.get(sys.argv[2]))' "$Y2" "$(TL list-panes -t '=shp:' -F '#{pane_id}' | head -1)")"
  assert_eq "$got" "%932 None" "status --json: was is the old id, null on a pane that was never restored"
fi
assert_contains "$(R status 2>/dev/null | grep -- "$Y2")" "(was %932)" "status: the restored pane's line ends (was %932)"

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
