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
. scripts/lib/roost-restore.sh

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

# --- restore drops what its boot's closed record names (Task 4.9a) -----------
echo "== §3.6 step 4: the picked save's own boot's closed/ removes those panes =="
# A fleet with no hooks (-f /dev/null): the closed files are planted by hand,
# so each case says exactly which file it is about.
sessions() { TL list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }
paths() { TL list-panes -a -F '#{pane_current_path}' 2>/dev/null | sed "s|^$SHAPE_TMP/||" | sort | tr '\n' ' '; }
mkdir -p "$SHAPE_TMP/pa" "$SHAPE_TMP/pb" "$SHAPE_TMP/pc" "$SHAPE_TMP/pd" "$SHAPE_TMP/pe"
fleet() {
  TL -f /dev/null new-session -d -s s1 -x 200 -y 50 -c "$SHAPE_TMP/pa" 'ENV= exec /bin/sh'
  A="$(TL display -p -t '=s1:' '#{pane_id}')"
  B="$(TL split-window -d -P -F '#{pane_id}' -t "$A" -c "$SHAPE_TMP/pb" 'ENV= exec /bin/sh')"
  C="$(TL new-window -d -P -F '#{pane_id}' -t '=s1:' -c "$SHAPE_TMP/pc" 'ENV= exec /bin/sh')"
  TL new-session -d -s s2 -c "$SHAPE_TMP/pd" 'ENV= exec /bin/sh'; D="$(TL display -p -t '=s2:' '#{pane_id}')"
  TL new-session -d -s s3 -c "$SHAPE_TMP/pe" 'ENV= exec /bin/sh'; E="$(TL display -p -t '=s3:' '#{pane_id}')"
  rm -rf "$SD"; R save >/dev/null 2>&1
  FB="$(boot_now)"; FSG="$(sed -n 's/^saved //p;/^$/q' "$SD/shape" | tr -d ':-')-$(sed -n 's/^gen //p;/^$/q' "$SD/shape")"
  cp "$SD/shape" "$SHAPE_TMP/fleet.shape"
}
plant() { mkdir -p "$SD/closed/$1"; printf '%s\n' "$3" > "$SD/closed/$1/$2"; }
TL kill-server 2>/dev/null; sleep 0.3
fleet
plant "$FB" "close.${A#%}" "$A"
plant "$FB" "kill.20261102T000000Z-1" "$B"; plant "$FB" "died.${B#%}" "$B"
plant "$FB" "close.${E#%}" "$E"; plant "$FB" "died.${E#%}" "$E"
plant "$FB" "kill.20261102T000000Z-2" "$D"
plant "1-1" "close.${C#%}" "$C"
TL kill-server; sleep 0.3
R restore --no-resume >/dev/null 2>"$SHAPE_TMP/e49"; rc=$?
assert_eq "$rc|$(sessions)" "0|s1 " "a plain restore: s2 (killed) and s3 (closed) are not created"
assert_eq "$(paths)" "pb pc " "...A (close.) is gone, B (kill + death note) kept, C (another boot's file) kept"
assert_eq "$(grep -c "default layout" "$SHAPE_TMP/e49")" "1" "...one stderr line: the window that lost a pane takes tmux's default layout"
assert_contains "$(cat "$SHAPE_TMP/e49")" "window s1:0 " "...naming that window (base-index 0 on this server)"
TL kill-server; sleep 0.3
R restore --no-resume --from "$FSG" >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(sessions)|$(paths)" "0|s1 |pb pc " "--from STAMP-GEN: the same filter (that save's boot)"
TL kill-server; sleep 0.3
R restore --no-resume --from "$SHAPE_TMP/fleet.shape" >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(sessions)|$(paths)" "0|s1 s2 s3 |pa pb pc pd pe " "--from FILE: the caller's own choice, nothing filtered"
TL kill-server; sleep 0.3
fleet
for p in "$A" "$B" "$C" "$D" "$E"; do plant "$FB" "close.${p#%}" "$p"; done
TL kill-server; sleep 0.3
out="$(R restore --no-resume 2>&1)"; rc=$?
assert_eq "$rc" "0" "every saved pane closed: exit 0"
assert_contains "$out" "nothing to restore: every saved pane was closed on purpose" "...saying so"
TL list-sessions >/dev/null 2>&1; assert_eq "$?" "1" "...and no server was started"

echo "== 8 (i), the restore half: after a SIGTERM to the server, the whole fleet comes back =="
TL kill-server 2>/dev/null; sleep 0.3
fleet
spid="$(TL display -p '#{pid}')"; kill -TERM "$spid"; sleep 1
[ ! -e "$SD/closed/$FB" ]; assert_true $? "no closed record for that boot"
R restore --no-resume >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(sessions)|$(paths)" "0|s1 s2 s3 |pa pb pc pd pe " "a plain restore brings every pane back"
TL kill-server 2>/dev/null; sleep 0.3

# --- roost close records its intent; kill NAME and stop too, ruling R1-A (Task 4.8) ---
echo "== (8b) the planted race: close's save loses to pane-exited's, and A still stays closed =="
mkdir -p "$SHAPE_TMP/pa8" "$SHAPE_TMP/pb8"
# An agent that leaves when a line is typed: close's exit command is a line.
LEAVER="sh -c 'read x; exit 0'"
cfleet() {
  TL kill-server 2>/dev/null; sleep 0.3
  TL -f /dev/null new-session -d -s f8 -x 200 -y 50 -c "$SHAPE_TMP" 'ENV= exec /bin/sh'
  TL set -g @roost-home "$PWD"; TL source-file tmux/roost.conf
  ${1:+TL set-environment -g ROOST_TEST_NOW "$1"}
  A="$(TL new-window -d -P -F '#{pane_id}' -t '=f8:' -c "$SHAPE_TMP/pa8" "$LEAVER")"
  B="$(TL new-window -d -P -F '#{pane_id}' -t '=f8:' -c "$SHAPE_TMP/pb8" "$LEAVER")"
  for p in "$A" "$B"; do TL set -p -t "$p" @roost-harness claude \; set -p -t "$p" @agent_state idle; done
  settle; rm -rf "$SD"; R save >/dev/null 2>&1; settle
  CB="$(boot_now)"
}
# a_gone LABEL — A (cwd pa8) is not among the restored panes and B (pb8) is.
a_gone() { case " $(paths) " in *" pa8 "*) r=1 ;; *" pb8 "*) r=0 ;; *) r=1 ;; esac; assert_true $r "$1 ($(paths))"; }
sg() { printf '%s-%s' "$(sed -n 's/^saved //p;/^$/q' "$1" | tr -d ':-')" "$(sed -n 's/^gen //p;/^$/q' "$1")"; }
holds() { grep -q "^cwd $SHAPE_TMP/$2\$" "$1"; }
race() {
  local now="${1:-}" H="$SHAPE_TMP/hold-close$$-$RANDOM" g sga
  cfleet "$now"
  sga="$(sg "$SD/shape")"
  ( ROOST_TEST_NOW="$now" ROOST_TEST_SAVE_HOLD="$H" R close "$A" >/dev/null 2>&1; [ -n "$now" ] || unset ROOST_TEST_NOW ) &
  local cp=$!
  wait_at "$H"; assert_true $? "${now:+[same second] }close's own save is held"
  settle
  holds "$SD/shape" pa8; assert_eq "$?" "1" "${now:+[same second] }...the newest shape is the pane-exited save, without A"
  case " $(trig "$SD") " in *" pane-exited "*) r=0 ;; *) r=1 ;; esac
  assert_true $r "${now:+[same second] }...labelled pane-exited ($(trig "$SD"))"
  g="$(gen_of "$SD")"
  : > "$H"; wait "$cp"; settle
  assert_eq "$(gen_of "$SD")" "$g" "${now:+[same second] }...and close's save wrote nothing (the same body)"
  assert_eq "$(cat "$SD/closed/$CB/close.${A#%}" 2>/dev/null)" "$A" "${now:+[same second] }closed/<boot>/close.<A> names %A"
  TL kill-server; sleep 0.3
  R restore --no-resume --from "$sga" >/dev/null 2>&1
  a_gone "${now:+[same second] }restore --from the save that still holds A: A is not back"
}
# The fixtures above used `-f /dev/null`: the conf is sourced by cfleet.
race
race 1793600000

echo "== (g) a save in flight: listed with A, published after the close =="
cfleet
H="$SHAPE_TMP/hold-flight"
TL set-environment -g ROOST_TEST_SAVE_HOLD_AFTER_LIST "$H"
TL rename-window -t '=f8:0' inflight
wait_at "$H"; assert_true $? "a hook's saver is held after listing A"
TL set-environment -gu ROOST_TEST_SAVE_HOLD_AFTER_LIST
R close "$A" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "roost close A while that save is in flight: exit 0"
: > "$H"; settle
TL send-keys -t "$B" x Enter; settle
late=""; lg=0
for f in "$SD/shape" "$SD"/history/*; do
  holds "$f" pa8 || continue
  g="$(sed -n 's/^gen //p;/^$/q' "$f")"; [ "$g" -gt "$lg" ] && { lg="$g"; late="$f"; }
done
[ -n "$late" ] && grep -q '^trigger .*after-rename-window' "$late"; assert_true $? "the save published after the close still holds A ($(sg "$late"))"
TL kill-server; sleep 0.3
R restore --no-resume --from "$(sg "$late")" >/dev/null 2>&1
a_gone "restore --from that save: A is not back, B (who died) is"

echo "== a failed close takes its own record back =="
cfleet
STAY="$(TL new-window -d -P -F '#{pane_id}' -t '=f8:' -c "$SHAPE_TMP" "sh -c 'while :; do read x; done'")"
TL set -p -t "$STAY" @roost-harness claude \; set -p -t "$STAY" @agent_state idle
R close "$STAY" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "a harness that does not leave: close exits 1"
[ ! -e "$SD/closed/$CB/close.${STAY#%}" ]; assert_true $? "...and its close.<N> is removed"
TL list-panes -a -F '#{pane_id}' | grep -qx "$STAY"; assert_true $? "...the pane is still there"

echo "== the ends of a fleet: roost kill NAME and roost stop (ruling R1-A) =="
cfleet
TL new-session -d -s e2 -c "$SHAPE_TMP/pb8" 'ENV= exec /bin/sh'
E2="$(TL display -p -t '=e2:' '#{pane_id}')"
settle
f8p="$(TL list-panes -s -t '=f8:' -F '#{pane_id}' | sort | tr '\n' ' ')"
R kill f8 >/dev/null 2>&1; settle
got=""; for p in $f8p; do [ "$(cat "$SD/closed/$CB/close.${p#%}" 2>/dev/null)" = "$p" ] && got="$got$p "; done
assert_eq "$got" "$f8p" "roost kill NAME: one close.<N> per pane of that session"
[ ! -e "$SD/closed/$CB/close.${E2#%}" ]; assert_true $? "...and none for the session it left"
R stop --yes >/dev/null 2>&1
assert_eq "$(cat "$SD/closed/$CB/close.${E2#%}" 2>/dev/null)" "$E2" "roost stop: a close.<N> for every pane (kill-server runs no hook, so roost wrote it)"
out="$(R restore --no-resume 2>&1)"; rc=$?
assert_eq "$rc" "0" "a plain restore after the stop: exit 0"
assert_contains "$out" "nothing to restore: every saved pane was closed on purpose" "...nothing to restore"
assert_contains "$out" "to bring back a fleet you stopped: roost restore --from $SD/shape" "...and the way back, with the full path"
TL list-sessions >/dev/null 2>&1; assert_eq "$?" "1" "...no server started"
# --json and --dry-run --json still print one JSON document (fix round 1).
jsonok() { if command -v jq >/dev/null 2>&1; then jq -e . >/dev/null 2>&1; else python3 -m json.tool >/dev/null 2>&1; fi; }
for m in "" "--dry-run"; do
  out="$(R restore --no-resume $m --json 2>/dev/null)"; rc=$?
  printf '%s' "$out" | jsonok; r=$?
  assert_eq "$rc|$r" "0|0" "restore ${m:+$m }--json with every pane closed: exit 0, one valid JSON document"
  assert_contains "$out" '"restored":[]' "...nothing restored in it"
  assert_contains "$out" "\"way_back\":\"roost restore --from $SD/shape\"" "...and the way back"
done
out="$(R restore --no-resume --from "$(sg "$SD/shape")" 2>&1)"; rc=$?
assert_eq "$rc" "0" "--from STAMP-GEN of that save: exit 0"
assert_contains "$out" "nothing to restore: every saved pane was closed on purpose" "...the same: step 4 filters it"
assert_contains "$out" "roost restore --from $SD/shape" "...and the same way back"
R restore --no-resume --from "$SD/shape" >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(sessions)" "0|e2 " "--from the file by path places the fleet as it was stopped"
TL kill-server 2>/dev/null; sleep 0.3

# --- which save a restore picks after a shutdown, steps 1 to 3 (Task 4.9b) ---
echo "== (a) a chain of death saves inside the window: the save before it is picked =="
cfleet
SA="$(sg "$SD/shape")"
D1="$(TL new-session -d -P -F '#{pane_id}' -s dd1 "$(dier d1)")"; D2="$(TL new-session -d -P -F '#{pane_id}' -s dd2 "$(dier d2)")"
settle
SPRE="$(sg "$SD/shape")"
H="$SHAPE_TMP/hold-chain"
( ROOST_TEST_SAVE_HOLD="$H" R close "$A" >/dev/null 2>&1 ) & cp=$!
wait_at "$H"; settle
: > "$SHAPE_TMP/go-d1"; settle; : > "$SHAPE_TMP/go-d2"; settle
: > "$H"; wait "$cp"; settle
roost_restore__death "$SD/shape"; assert_true $? "(fixture) the newest save is a death save ($(trig "$SD"))"
lst="$(ROOST_SHUTDOWN_AT="$(date +%s)" R restore --list 2>&1)"
assert_contains "$(printf '%s\n' "$lst" | grep '^\*')" "$SPRE" "--list marks the save before the chain ($SPRE)"
TL kill-server; sleep 0.3
ROOST_SHUTDOWN_AT="$(date +%s)" R restore --no-resume >/dev/null 2>"$SHAPE_TMP/e9b"; rc=$?
assert_eq "$rc|$(sessions)" "0|dd1 dd2 f8 " "a plain restore walks back past the chain: dd1 and dd2 come back"
a_gone "...and A, closed in the planted race inside the window, still does not (8b, the reading-rule form)"
TL kill-server 2>/dev/null; sleep 0.3

echo "== (b2), the restore half: inside the window C comes back, B does not =="
cfleet
TL new-session -d -s cs9 -c "$SHAPE_TMP/pa8" "$(dier c9)"
b9="$(TL split-window -d -P -F '#{pane_id}' -t '=f8:0' -c "$SHAPE_TMP/pe" 'ENV= exec /bin/sh')"
settle; R save >/dev/null 2>&1; settle
TL kill-pane -t "$b9"; settle
: > "$SHAPE_TMP/go-c9"; settle
TL kill-server; sleep 0.3
ROOST_SHUTDOWN_AT="$(date +%s)" R restore --no-resume >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(TL has-session -t '=cs9' 2>/dev/null && echo cs9)" "0|cs9" "C's session (C died inside the window) comes back"
case " $(paths) " in *" pe "*) r=1 ;; *) r=0 ;; esac
assert_true $r "...and B (killed) does not ($(paths))"
TL kill-server 2>/dev/null; sleep 0.3

echo "== (c) no readable record: the newest save, one stderr line, closed/ still applied =="
cfleet
R close "$A" >/dev/null 2>&1; settle
TL kill-server; sleep 0.3
ROOST_SHUTDOWN_AT= R restore --no-resume >/dev/null 2>"$SHAPE_TMP/e9c"; rc=$?
assert_eq "$rc" "0" "ROOST_SHUTDOWN_AT empty: exit 0"
assert_contains "$(cat "$SHAPE_TMP/e9c")" "no shutdown record readable; restoring the newest save — roost restore --list shows the others" "...the stderr line"
a_gone "...and the newest save, A still closed"
TL kill-server 2>/dev/null; sleep 0.3

echo "== a close save is not a death save: the rule does not walk back past it =="
# D dies (a death save), then A — a plain shell, so close kills it at once —
# is closed: that save's triggers are after-kill-pane and close, no death.
# Inside the window the newest save is therefore picked; walking past it
# would reach the save from before D died and bring D back.
cfleet
TL new-session -d -s dz -c "$SHAPE_TMP/pe" "$(dier dz)"
SH1="$(TL new-window -d -P -F '#{pane_id}' -t '=f8:' -c "$SHAPE_TMP/pa" 'ENV= exec /bin/sh')"
settle; R save >/dev/null 2>&1; settle
: > "$SHAPE_TMP/go-dz"; settle
R close "$SH1" >/dev/null 2>&1; settle
roost_restore__death "$SD/shape"; assert_eq "$?" "1" "(fixture) the newest save is close's, not a death save ($(trig "$SD"))"
TL kill-server; sleep 0.3
ROOST_SHUTDOWN_AT="$(date +%s)" R restore --no-resume >/dev/null 2>&1
TL has-session -t '=dz' 2>/dev/null; assert_eq "$?" "1" "inside the window, the close save is picked: D, which died before it, is not back"
TL kill-server 2>/dev/null; sleep 0.3

echo "== (d) sixty death saves inside the window: still recoverable =="
cfleet
SGOOD="$(sg "$SD/shape")"
# The rename hook would save each change first, under its own (not a death)
# label; off for this case, so each save below is the death save it says.
TL set-hook -gu 'after-rename-window[98]'
i=0
while [ "$i" -lt 60 ]; do
  TL rename-window -t '=f8:0' "d$i" 2>/dev/null
  # Labelled as a death by hand: sixty real deaths would take minutes.
  R save --auto --trigger pane-exited
  i=$((i+1))
done
settle
assert_eq "$(nhist "$SD")" "60" "(fixture) sixty death saves after the good one"
ROOST_SHUTDOWN_AT="$(date +%s)"; export ROOST_SHUTDOWN_AT
roost_restore__reading_rule "$SD"; unset ROOST_SHUTDOWN_AT
assert_eq "$(basename "$ROOST_RESTORE_FILE")" "$SGOOD" "...picked through sixty death saves (ring of 100)"
TL kill-server 2>/dev/null; sleep 0.3

echo "== (f) a shutdown on 31 December, a boot on 1 January: the year before =="
SB="$SHAPE_TMP/stub-last"; mkdir -p "$SB"
printf '#!/bin/sh\necho "shutdown time Wed Dec 31 23:59"\necho "reboot time Thu Jan  1 00:01"\n' > "$SB/last"
NY="$(date -j -f '%Y %b %d %H:%M:%S' '2027 Jan 01 00:01:00' +%s 2>/dev/null || date -d 'Jan 1 2027 00:01:00' +%s)"
printf '#!/bin/sh\necho "{ sec = %s, usec = 0 } Fri Jan  1 00:01:00 2027"\n' "$NY" > "$SB/sysctl"
chmod +x "$SB/last" "$SB/sysctl"
want="$(date -j -f '%Y %b %d %H:%M:%S' '2026 Dec 31 23:59:00' +%s 2>/dev/null || date -d 'Dec 31 2026 23:59:00' +%s)"
got="$(PATH="$SB:$PATH" roost_restore__shutdown_at)"
assert_eq "$got" "$want" "the shutdown is read as 31 December of the year BEFORE the boot"

echo "== the year comes from the LOCAL clock, as last's time and the month do (fix round 1) =="
# lepoch TZ "YYYY Mon DD HH:MM" -> epoch of that local time in TZ.
lepoch() { TZ="$1" date -j -f '%Y %b %d %H:%M:%S' "$2:00" +%s 2>/dev/null || TZ="$1" date -d "$(printf '%s' "$2" | awk '{ print $2, $3, $1, $4 }'):00" +%s; }
# yearcase TZ BOOT-LOCAL SHUTDOWN-AS-LAST-PRINTS WANT-LOCAL LABEL
yearcase() {
  local b w g
  b="$(lepoch "$1" "$2")"; w="$(lepoch "$1" "$4")"
  printf '#!/bin/sh\necho "shutdown time %s"\n' "$3" > "$SB/last"
  printf '#!/bin/sh\necho "{ sec = %s, usec = 0 }"\n' "$b" > "$SB/sysctl"
  chmod +x "$SB/last" "$SB/sysctl"
  g="$(TZ="$1" PATH="$SB:$PATH" roost_restore__shutdown_at)"
  assert_eq "$g" "$w" "$5"
}
yearcase America/Chicago "2026 Dec 31 20:00" "Thu Dec 31 19:55" "2026 Dec 31 19:55" \
  "Chicago, boot 31 Dec 20:00 local (already 1 Jan in UTC): shutdown 31 Dec 19:55 of the same year"
yearcase Australia/Sydney "2027 Jan 01 05:00" "Thu Dec 31 23:50" "2026 Dec 31 23:50" \
  "Sydney, boot 1 Jan 05:00 local (still 31 Dec in UTC): shutdown 31 Dec 23:50 of the year before"
yearcase America/Chicago "2027 Jan 02 09:00" "Thu Dec 31 23:50" "2026 Dec 31 23:50" \
  "a boot in January, a shutdown in December: the year steps back one"

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
