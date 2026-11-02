#!/usr/bin/env bash
# Saving on change, the hook half (#51, #191 Part 4): tmux/roost.conf's save
# hooks, the server's own pane list (@roost-ids) and the closed record a kill
# leaves (closed/<boot>/). Design:
# docs/airig/specs/2026-10-24-persistent-sessions-design.md §3.4, §3.5 step 1,
# §3.6a; the probes docs/airig/probes/persist-4-hooks-tmux.md and
# persist-4-kill-diff.md; the plan's Task 4.6 (4.8, 4.9a and 4.9b add to it).
#
# Every case runs the real hooks: the conf is loaded into this file's server,
# and a case reads what the hooks' `roost save --auto` left on disk.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
shape_test_setup; trap shape_test_teardown EXIT
. scripts/lib/roost-shape.sh

# `roost wiring apply` runs when restore starts a server (the boot-change
# case below), and writes under XDG_CONFIG_HOME: a temp dir here, not the
# canary, as tests/test-shape-place.sh does.
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
ROOST="$PWD/bin/roost"
R() { ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"
gen_of() { cat "$1/gen" 2>/dev/null || printf -- '-'; }
nhist() { ls "$1/history" 2>/dev/null | wc -l | tr -d ' '; }
trig() { sed -n 's/^trigger //p;/^$/q' "$1/shape" 2>/dev/null; }
wait_at() { local i=0; while [ "$i" -lt 100 ]; do ls "$1".at.* >/dev/null 2>&1 && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
settle() { shape_settle "$SD"; }
# kills BOOT — every pane id named by a kill file of that boot, sorted, one line.
kills() { cat "$SD/closed/$1"/kill.* 2>/dev/null | sort -u | tr '\n' ' '; }
boot_now() { TL display -p '#{start_time}-#{pid}'; }
# A pane that exits when $SHAPE_TMP/go-<tag> appears: a death on cue.
dier() { printf "sh -c 'while [ ! -e %s/go-%s ]; do sleep 0.02; done'" "$SHAPE_TMP" "$1"; }

echo "== the conf loads clean on this tmux, and every [98] save hook is set (§8.1 test 8 hooks) =="
CS="$TMUX_TMPDIR/conf"
tmux -S "$CS" -f /dev/null new-session -d -s c 'ENV= exec /bin/sh'
tmux -S "$CS" set -g @roost-home "$PWD"
err="$(tmux -S "$CS" source-file tmux/roost.conf 2>&1)"
assert_eq "$err" "" "tmux/roost.conf loads with nothing on stderr ($(tmux -V))"
names="$(grep -o '^set-hook -g [a-z-]*\[98\]' tmux/roost.conf | sed 's/^set-hook -g //' | sort -u)"
listed="$( (tmux -S "$CS" show-hooks -g; tmux -S "$CS" show-hooks -gw) 2>/dev/null | grep -o '^[a-z-]*\[98\]' | sort -u)"
missing=""
for n in $names; do printf '%s\n' "$listed" | grep -qxF "$n" || missing="$missing $n"; done
assert_eq "$missing" "" "every [98] hook the conf sets is listed by show-hooks -g or -gw (probe 4.3: pane and window hooks are -gw)"
for n in after-new-session session-closed after-rename-session after-new-window window-linked window-unlinked \
         after-rename-window after-split-window pane-exited pane-died after-kill-pane after-select-layout after-resize-pane; do
  v="$( (tmux -S "$CS" show-hooks -g "$n[98]"; tmux -S "$CS" show-hooks -gw "$n[98]") 2>/dev/null)"
  assert_contains "$v" "save --auto" "$n[98] saves"
done
for n in window-layout-changed after-set-option; do
  v="$( (tmux -S "$CS" show-hooks -g; tmux -S "$CS" show-hooks -gw) 2>/dev/null | grep "^$n")"
  case "$v" in *'save --auto'*) r=1 ;; *) r=0 ;; esac
  assert_true $r "$n does not save (every resize, every badge)"
done
tmux -S "$CS" kill-server

echo "== the fleet, with the conf loaded =="
TL set -g base-index 1
TL set -g @roost-home "$PWD"
TL source-file tmux/roost.conf
TL new-session -d -s main -x 200 -y 50 'ENV= exec /bin/sh'
shp_p="$(TL display -p -t '=shp:' '#{pane_id}')"
TL kill-session -t '=shp:' 2>/dev/null
settle
BOOT="$(boot_now)"
[ -f "$SD/shape" ]; assert_true $? "a hook saved the fleet with no roost save typed"
assert_eq "$(TL show -gv @roost-ids)" "$(TL display -p '#{S:#{W:#{P:#{pane_id} }}}')" "@roost-ids is the server's pane list"

echo "== kills by every route leave a kill file naming exactly their panes (8i) =="
# The setup's kill-session of `shp` was a kill too, and its file is there:
assert_eq "$(kills "$BOOT")" "$shp_p " "the setup's kill-session of shp (not the last session) named its pane"
rm -rf "$SD/closed"
p1="$(TL display -p -t '=main:1' '#{pane_id}')"
b="$(TL split-window -d -P -F '#{pane_id}' -t "$p1" 'ENV= exec /bin/sh')"
settle
TL kill-pane -t "$b"; settle
assert_eq "$(kills "$BOOT")" "$b " "kill-pane: a kill file naming exactly that pane"
assert_contains "$(trig "$SD")" "after-kill-pane" "...and the save after it is labelled after-kill-pane"
rm -rf "$SD/closed"
w="$(TL new-window -d -P -F '#{window_id}' -t '=main:' 'ENV= exec /bin/sh')"
w1="$(TL display -p -t "$w" '#{pane_id}')"
w2="$(TL split-window -d -P -F '#{pane_id}' -t "$w" 'ENV= exec /bin/sh')"
settle
TL kill-window -t "$w"; settle
assert_eq "$(kills "$BOOT")" "$(printf '%s\n' "$w1" "$w2" | sort | tr '\n' ' ')" "kill-window of a two-pane window: its two panes"
assert_contains "$(trig "$SD")" "window-unlinked" "...the save after it is labelled window-unlinked"
rm -rf "$SD/closed"
TL new-session -d -s other 'ENV= exec /bin/sh'
o1="$(TL display -p -t '=other:' '#{pane_id}')"
o2="$(TL split-window -d -P -F '#{pane_id}' -t "$o1" 'ENV= exec /bin/sh')"
settle
TL kill-session -t '=other'; settle
assert_eq "$(kills "$BOOT")" "$(printf '%s\n' "$o1" "$o2" | sort | tr '\n' ' ')" "kill-session (not the last): its panes"
assert_contains "$(trig "$SD")" "session-closed" "...the save after it is labelled session-closed"
rm -rf "$SD/closed"
TL new-window -d -t '=main:' -n mv 'ENV= exec /bin/sh'
m2="$(TL split-window -d -P -F '#{pane_id}' -t '=main:mv' 'ENV= exec /bin/sh')"
settle
TL break-pane -d -s "$m2"; settle
TL new-session -d -s side 'ENV= exec /bin/sh'; settle
TL move-window -d -s '=main:mv' -t '=side:'; settle
j="$(TL new-window -d -P -F '#{pane_id}' -t '=main:' 'ENV= exec /bin/sh')"; settle
TL join-pane -d -s "$j" -t "$p1"; settle
TL kill-session -t '=side'; settle
rm -rf "$SD/closed"
TL break-pane -d -s "$j"; settle
TL join-pane -d -s "$j" -t "$p1"; settle
x="$(TL new-window -d -P -F '#{window_id}' -t '=main:' 'ENV= exec /bin/sh')"; settle
TL new-session -d -s side2 'ENV= exec /bin/sh'; settle
TL move-window -d -s "$x" -t '=side2:'; settle
[ ! -e "$SD/closed" ] || [ -z "$(kills "$BOOT")" ]; assert_true $? "break-pane, join-pane and move-window leave no kill file"
TL kill-session -t '=side2'; settle; rm -rf "$SD/closed"

echo "== a death is never a kill; the overlap is rewritten (8b2) =="
TL new-session -d -s csess "$(dier c1)"
c="$(TL display -p -t '=csess:' '#{pane_id}')"
b="$(TL split-window -d -P -F '#{pane_id}' -t "$p1" 'ENV= exec /bin/sh')"
settle
H="$SHAPE_TMP/hold-8b2"
TL set-environment -g ROOST_TEST_SAVE_HOLD "$H"
TL rename-window -t '=main:1' hold-8b2
wait_at "$H"; assert_true $? "a hook's saver is held"
TL set-environment -gu ROOST_TEST_SAVE_HOLD
TL kill-pane -t "$b"
: > "$SHAPE_TMP/go-c1"
sleep 1
: > "$H"; settle
assert_eq "$(kills "$BOOT")" "$b " "kill-pane B while C dies, the saver held: the kill files name B only"
[ -f "$SD/closed/$BOOT/died.${c#%}" ]; assert_true $? "...and a died.<C> note exists"
assert_eq "$(cat "$SD/closed/$BOOT/died.${c#%}" 2>/dev/null)" "$c" "...naming %C"
rm -rf "$SD/closed"

echo "== a death in the gap after the drain is still not a kill =="
TL new-session -d -s csess2 "$(dier c2)"
c="$(TL display -p -t '=csess2:' '#{pane_id}')"
b="$(TL split-window -d -P -F '#{pane_id}' -t "$p1" 'ENV= exec /bin/sh')"
settle
H="$SHAPE_TMP/hold-gap"
TL set-environment -g ROOST_TEST_SAVE_HOLD_AFTER_DRAIN "$H"
TL rename-window -t '=main:1' hold-gap
wait_at "$H"; assert_true $? "a hook's saver is held after its drain"
TL set-environment -gu ROOST_TEST_SAVE_HOLD_AFTER_DRAIN
: > "$SHAPE_TMP/go-c2"; sleep 0.5
TL kill-pane -t "$b"
sleep 0.5; : > "$H"; settle
assert_eq "$(kills "$BOOT")" "$b " "C exits, then kill-pane B: still only B"
rm -rf "$SD/closed"

echo "== what no hook covers: saved with the next event (§3.4) =="
TL select-layout -t '=main:1' even-horizontal >/dev/null 2>&1; settle
s2="$(TL split-window -d -P -F '#{pane_id}' -t "$p1" 'ENV= exec /bin/sh')"; settle
g="$(gen_of "$SD")"
TL swap-pane -d -s "$p1" -t "$s2"; sleep 1.5; settle
assert_eq "$(gen_of "$SD")" "$g" "swap-pane: no new shape"
TL new-window -d -t '=main:' -n sw 'ENV= exec /bin/sh'; settle; g="$(gen_of "$SD")"
TL swap-window -d -s '=main:1' -t '=main:sw'; sleep 1.5; settle
assert_eq "$(gen_of "$SD")" "$g" "swap-window: no new shape"
TL swap-window -d -s '=main:1' -t '=main:sw'; sleep 1; settle
j="$(TL split-window -d -P -F '#{pane_id}' -t "$p1" 'ENV= exec /bin/sh')"; settle; g="$(gen_of "$SD")"
TL join-pane -d -s "$j" -t '=main:sw'; sleep 1.5; settle
assert_eq "$(gen_of "$SD")" "$g" "a join-pane that keeps its window: no new shape"
TL respawn-pane -k -t "$j" 'ENV= exec /bin/sh'; sleep 1.5; settle
assert_eq "$(gen_of "$SD")" "$g" "respawn-pane -k by hand: no new shape"
TL resize-window -t '=main:1' -x 150 -y 40 >/dev/null 2>&1; sleep 1.5; settle
assert_eq "$(gen_of "$SD")" "$g" "window-layout-changed alone (a resize): no new shape"
TL rename-window -t '=main:sw' sw2; settle
[ "$(gen_of "$SD")" != "$g" ]; assert_true $? "...and the next event saves them all"

echo "== coalescing on cue: ten renames while held, one save (§3.5) =="
H="$SHAPE_TMP/hold-coal"
TL set-environment -g ROOST_TEST_SAVE_HOLD "$H"
TL rename-window -t '=main:1' coal-0
wait_at "$H"; assert_true $? "the first rename's saver is held"
TL set-environment -gu ROOST_TEST_SAVE_HOLD
h0="$(nhist "$SD")"
i=1; while [ "$i" -le 10 ]; do TL rename-window -t '=main:1' "coal-$i"; i=$((i+1)); done
sleep 1
TL select-layout -t '=main:1' even-vertical >/dev/null 2>&1; sleep 1
: > "$H"; settle
assert_eq "$(nhist "$SD")" "$((h0 + 1))" "released: exactly one more history file"
assert_contains "$(sed -n 's/^name //p' "$SD/shape")" "coal-10" "...its body holds the tenth name"
t="$(trig "$SD")"
r=1; case " $t " in *" after-rename-window "*) case " $t " in *" after-select-layout "*) r=0 ;; esac ;; esac
assert_true $r "...and its trigger lists every distinct trigger fired ($t)"
H="$SHAPE_TMP/hold-coal2"; g="$(gen_of "$SD")"; h0="$(nhist "$SD")"
ROOST_TEST_SAVE_HOLD="$H" R save --auto --trigger save & hp=$!
wait_at "$H"
i=0; while [ "$i" -lt 10 ]; do R save --auto --trigger save; i=$((i+1)); done
: > "$H"; wait "$hp"; settle
assert_eq "$(gen_of "$SD"):$(nhist "$SD")" "$g:$h0" "held again, ten save --auto with no change: no new history file, gen unchanged"

echo "== a boot change: the kill goes under the hook's boot, never the shape's (8h) =="
R save >/dev/null 2>&1; B1="$(boot_now)"
rm -rf "$SD/closed"
TL kill-server; sleep 0.3
H="$SHAPE_TMP/hold-boot"
ROOST_TEST_RESTORE_HOLD="$H" R restore --no-resume >/dev/null 2>&1 & rp=$!
i=0; while [ "$i" -lt 100 ] && ! TL list-sessions >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
sleep 0.5
B2="$(boot_now)"
[ -n "$B2" ] && [ "$B2" != "$B1" ]; assert_true $? "restore started a new server (boot $B2, was $B1)"
k="$(TL split-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
sleep 0.5; TL kill-pane -t "$k"; sleep 1
: > "$H"; wait "$rp"; settle
assert_eq "$(kills "$B2")" "$k " "closed/<B2>/ names exactly the pane killed during the held restore"
[ ! -e "$SD/closed/$B1" ]; assert_true $? "...and nothing is under closed/<B1>/"

echo "== kill -TERM of the server: no hook, no kill file (8i) =="
rm -rf "$SD/closed"
B="$(boot_now)"; spid="$(TL display -p '#{pid}')"
kill -TERM "$spid"; sleep 1
[ ! -e "$SD/closed/$B" ]; assert_true $? "a SIGTERM to the server writes no kill file"

echo "== saving off: every hook still exits 0 within 5 s, writing nothing (10b) =="
OFF="$TMUX_TMPDIR/off"
dirs0="$(ls "$ROOST_SHAPE_DIR")"
ROOST_SHAPE_DIR= tmux -S "$OFF" -f /dev/null new-session -d -s o 'ENV= exec /bin/sh'
tmux -S "$OFF" set -g @roost-home "$PWD"
tmux -S "$OFF" source-file tmux/roost.conf
tmux -S "$OFF" new-window -d 'ENV= exec /bin/sh'
q="$(tmux -S "$OFF" split-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
tmux -S "$OFF" rename-window xx; tmux -S "$OFF" select-layout tiled; tmux -S "$OFF" resize-pane -t "$q" -x 10
tmux -S "$OFF" kill-pane -t "$q"; tmux -S "$OFF" new-session -d -s o2 'sleep 0.2'; tmux -S "$OFF" kill-window -t '=o:1'
sleep 5
pgrep -f "save --auto --socket $OFF" >/dev/null 2>&1; assert_eq "$?" "1" "5 s after every kind of event, no save --auto of a saving-off server is running"
assert_eq "$(ls "$ROOST_SHAPE_DIR")" "$dirs0" "...and none wrote a shape directory"
tmux -S "$OFF" kill-server 2>/dev/null

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
