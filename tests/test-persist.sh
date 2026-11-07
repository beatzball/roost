#!/usr/bin/env bash
# `roost persist on|off|status` (#192; spec §4.4, the plan's Task 5.5, §8.1
# test 9): one login unit per server, never stopped.
#
# No real launchctl or systemctl is ever called (the plan's Global
# constraints): the first half writes the unit with ROOST_PERSIST_WRITE_ONLY=1
# and loads nothing; the second puts the recording stubs of tests/lib-shape.sh
# (persist_stubs) first on PATH. `uname -s` is stubbed too, so the macOS plist
# and the Linux unit are both checked on either runner. HOME is a temp dir, so
# ~/Library/LaunchAgents and ~/.config/systemd/user here are the sandbox's.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh

shape_test_setup
# A unit file and `roost wiring apply` write under XDG_CONFIG_HOME: a temp dir
# here, not the canary.
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
unset TMUX TMUX_PANE
HOLDS=""
cleanup() {
  local p
  for p in $HOLDS; do kill "$p" 2>/dev/null; done
  [ -n "${B_SOCK:-}" ] && tmux -S "$B_SOCK" kill-server 2>/dev/null
  shape_test_teardown
}
trap cleanup EXIT

ROOST="$PWD/bin/roost"
CHECKOUT="$PWD"
R() { ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"
STUBS="$SHAPE_TMP/persist-stubs"
persist_stubs "$STUBS"
export PERSIST_LOG="$SHAPE_TMP/persist.log"
: > "$PERSIST_LOG"
UID_="$(id -u)"
PLIST="$HOME/Library/LaunchAgents/dev.roosting.roost.roost.plist"
UNIT="$XDG_CONFIG_HOME/systemd/user/roost-persist-roost.service"
gen_of() { cat "$1/gen" 2>/dev/null || printf -- '-'; }
trig() { sed -n 's/^trigger //p;/^$/q' "$1/shape" 2>/dev/null; }
mode_of() { ls -l "$1" | cut -c1-10; }
live_pid() { sleep 600 & LIVE=$!; disown "$LIVE" 2>/dev/null; HOLDS="$HOLDS $LIVE"; LIVE_ST="$(roost_shape__lstart "$LIVE")"; }
. scripts/lib/roost-shape.sh

TL set -g base-index 1
TL new-session -d -s main -x 200 -y 50 'ENV= exec /bin/sh'
TL kill-session -t '=shp:' 2>/dev/null

echo "== on, write-only, macOS: the plist, service.env, one save =="
CUSTOM_STATE="$XDG_STATE_HOME"
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" ROOST_PERSIST_WRITE_ONLY=1 CODEX_HOME=/x MY_API_KEY=1 GH_TOKEN=t \
  R persist on 2>&1)"; rc=$?
assert_eq "$rc" "0" "persist on exits 0 (write-only) ($out)"
assert_eq "$([ -f "$PLIST" ] && echo yes)" "yes" "the plist is at ~/Library/LaunchAgents/dev.roosting.roost.roost.plist"
p="$(cat "$PLIST" 2>/dev/null)"
assert_contains "$p" "<string>dev.roosting.roost.roost</string>" "...labelled dev.roosting.roost.<server>"
assert_contains "$p" "<string>$CHECKOUT/bin/roost</string>" "...running THIS checkout's bin/roost"
assert_contains "$p" "<string>--at-login</string>" "...with --at-login"
assert_contains "$p" "<key>RunAtLoad</key>"$'\n'"  <true/>" "...RunAtLoad true"
assert_contains "$p" "<key>AbandonProcessGroup</key>"$'\n'"  <true/>" "...AbandonProcessGroup true"
assert_contains "$p" "<string>$SD/login.log</string>" "...stdout and stderr at the shape directory's login.log"
assert_contains "$p" "<key>XDG_STATE_HOME</key>" "...EnvironmentVariables from service.env"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST" >/dev/null 2>&1; assert_true $? "...and plutil reads it as a valid plist"
fi
env_="$(cat "$SD/service.env" 2>/dev/null)"
assert_contains "$env_" "XDG_STATE_HOME=$CUSTOM_STATE" "service.env names the custom state root, resolved"
assert_contains "$env_" "ROOST_SHAPE_DIR=$ROOST_SHAPE_DIR" "...and the shape root"
assert_contains "$env_" "CODEX_HOME=/x" "...and a harness home override (CODEX_HOME=/x)"
assert_contains "$env_" "HOME=$HOME" "...and HOME"
assert_contains "$env_" "PATH=" "...and PATH"
assert_not_contains "$env_" "MY_API_KEY" "...never a variable named like a key"
assert_not_contains "$env_" "GH_TOKEN" "...nor one named like a token"
assert_eq "$(mode_of "$SD/service.env")" "-rw-------" "service.env is 0600"
assert_eq "$([ -e "$SD/persist" ] && echo yes)" "yes" "the persist marker is written"
assert_eq "$(gen_of "$SD")|$(trig "$SD")" "1|persist-on" "one save, trigger persist-on"
assert_eq "$(cat "$PERSIST_LOG")" "" "write-only: nothing loaded, no launchctl call"

echo "== on, write-only, Linux: the unit =="
out="$(STUB_UNAME=Linux PATH="$STUBS:$PATH" ROOST_PERSIST_WRITE_ONLY=1 R persist on 2>&1)"; rc=$?
assert_eq "$rc" "0" "persist on exits 0 (write-only, Linux) ($out)"
u="$(cat "$UNIT" 2>/dev/null)"
assert_contains "$u" "Type=oneshot" "the unit is Type=oneshot"
assert_contains "$u" "RemainAfterExit=yes" "...RemainAfterExit=yes"
assert_contains "$u" "KillMode=process" "...KillMode=process"
assert_not_contains "$u" "ExecStop" "...and has no ExecStop"
assert_contains "$u" "EnvironmentFile=$SD/service.env" "...EnvironmentFile names service.env"
assert_contains "$u" "ExecStart=\"$CHECKOUT/bin/roost\" persist --at-login roost" "...ExecStart runs this checkout's --at-login for roost"
assert_contains "$u" "WantedBy=default.target" "...WantedBy=default.target"
assert_contains "$out" "loginctl enable-linger" "Linux: on prints the linger line"
assert_eq "$(cat "$PERSIST_LOG")" "" "...and calls no systemctl"

echo "== on for B, then off for A: B's files and A's shapes stay =="
TL rename-window -t '=main:1' before-b
B_SOCK="$TMUX_TMPDIR/tmux-$UID_/b"
tmux -L b -f /dev/null new-session -d -s bmain 'ENV= exec /bin/sh'
B_SOCK="$(tmux -L b display -p '#{socket_path}')"
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" ROOST_PERSIST_WRITE_ONLY=1 R persist on --name b 2>&1)"; rc=$?
assert_eq "$rc" "0" "persist on --name b exits 0 ($out)"
BPLIST="$HOME/Library/LaunchAgents/dev.roosting.roost.b.plist"
assert_eq "$([ -f "$BPLIST" ] && [ -f "$ROOST_SHAPE_DIR/b/persist" ] && [ -f "$ROOST_SHAPE_DIR/b/service.env" ] && echo yes)" "yes" \
  "B has its own plist, marker and service.env"
assert_contains "$(sed -n 's/^server //p;/^$/q' "$ROOST_SHAPE_DIR/b/shape")" "b" "B's save is of server b"
mkdir -p "$SD/pending/1700000000-1"; : > "$SD/pending/1700000000-1/%9"
mkdir -p "$SD/history"; : > "$SD/history/20260101T000000Z-0"
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist off 2>&1)"; rc=$?
assert_eq "$rc" "0" "persist off (A) exits 0 ($out)"
assert_eq "$([ -e "$PLIST" ] || [ -e "$SD/persist" ] || [ -e "$SD/service.env" ] || echo gone)" "gone" \
  "off removes A's plist, marker and service.env"
assert_eq "$([ -f "$SD/shape" ] && [ -f "$SD/history/20260101T000000Z-0" ] && [ -f "$SD/pending/1700000000-1/%9" ] && echo kept)" "kept" \
  "...and nothing else: A's shape, history/ and pending/ stay"
assert_eq "$([ -f "$BPLIST" ] && [ -f "$ROOST_SHAPE_DIR/b/persist" ] && [ -f "$ROOST_SHAPE_DIR/b/service.env" ] && echo kept)" "kept" \
  "...and B's files are not touched"
assert_not_contains "$(cat "$PERSIST_LOG")" "bootout gui/$UID_/dev.roosting.roost.b" "off for A never boots out B"
STUB_UNAME=Darwin PATH="$STUBS:$PATH" ROOST_PERSIST_WRITE_ONLY=1 R persist off --name b >/dev/null 2>&1
tmux -S "$B_SOCK" kill-server 2>/dev/null; B_SOCK=""
: > "$PERSIST_LOG"

echo "== the stubs: on loads, off disables, never stop or --now =="
TL rename-window -t '=main:1' stubs-mac
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist on 2>&1)"; rc=$?
assert_eq "$rc" "0" "macOS: on exits 0 ($out)"
assert_contains "$(cat "$PERSIST_LOG")" "launchctl bootstrap gui/$UID_ $PLIST" "macOS: on loads the plist with launchctl bootstrap gui/UID"
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist status 2>&1)"; rc=$?
assert_eq "$rc" "0" "status exits 0"
assert_contains "$out" "persist: on for 'roost'" "status: on, for this server"
assert_contains "$out" "$PLIST" "status: the unit's path"
assert_contains "$out" "loaded" "status: the unit is loaded"
assert_contains "$out" "names this checkout" "status: the unit names this checkout"
assert_contains "$out" "roots match" "status: service.env's roots match the caller's"
assert_contains "$out" "persist-on" "status: the newest save's trigger"
assert_contains "$out" "pending:" "status: the pending record's counts"
assert_eq "$(printf '%s\n' "$out" | grep -c '^  pending: .*)$')" "1" "status: the pending line ends at its counts (fix round 1)"
assert_eq "$(printf '%s\n' "$out" | grep -c '^  last login restore: ')" "1" "status: the last login line is a line of its own"
# #234: the newest save starts with `#` notes; the same save without them (a
# save an older roost wrote) gives the same newest-save line.
nsl() { printf '%s\n' "$1" | grep '^  newest save: '; }
withn="$(nsl "$out")"
assert_eq "$(head -c 1 "$SD/shape")" "#" "(the control) the save status read starts with its notes"
cp -p "$SD/shape" "$SHAPE_TMP/shape.notes"; grep -v '^#' "$SHAPE_TMP/shape.notes" > "$SD/shape"
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist status 2>&1)"
assert_eq "$(nsl "$out")" "$withn" "status: the same newest-save line for a save with notes and one without ($withn)"
assert_contains "$withn" "gen $(cat "$SD/gen") persist-on, $(grep -c '^session ' "$SD/shape") sessions / $(grep -c '^pane ' "$SD/shape") panes" "...and it reads the header (gen, trigger) and the counts"
cp -p "$SHAPE_TMP/shape.notes" "$SD/shape"
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist off 2>&1)"; rc=$?
assert_eq "$rc" "0" "macOS: off exits 0 ($out)"
log="$(cat "$PERSIST_LOG")"
assert_contains "$log" "launchctl bootout gui/$UID_/dev.roosting.roost.roost" "macOS: off is launchctl bootout"
assert_not_contains "$log" "launchctl stop" "macOS: never launchctl stop"
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist status 2>&1)"
assert_contains "$out" "persist: off for 'roost'" "status after off: off"
: > "$PERSIST_LOG"
TL rename-window -t '=main:1' stubs-linux
out="$(STUB_UNAME=Linux PATH="$STUBS:$PATH" R persist on 2>&1)"; rc=$?
assert_eq "$rc" "0" "Linux: on exits 0 ($out)"
log="$(cat "$PERSIST_LOG")"
assert_contains "$log" "systemctl --user enable roost-persist-roost.service" "Linux: on enables the unit"
assert_not_contains "$log" "--now" "Linux: on never uses --now"
out="$(STUB_UNAME=Linux PATH="$STUBS:$PATH" R persist status 2>&1)"
assert_contains "$out" "persist: on for 'roost'" "Linux status: on"
assert_contains "$out" "$UNIT" "Linux status: the unit's path"
out="$(STUB_UNAME=Linux PATH="$STUBS:$PATH" R persist off 2>&1)"; rc=$?
assert_eq "$rc" "0" "Linux: off exits 0 ($out)"
log="$(cat "$PERSIST_LOG")"
assert_contains "$log" "systemctl --user disable roost-persist-roost.service" "Linux: off is systemctl --user disable"
assert_not_contains "$log" " stop" "Linux: never stop"
assert_not_contains "$log" "--now" "Linux: never --now"
assert_eq "$([ -e "$UNIT" ] || echo gone)" "gone" "Linux: off removes the unit file"
: > "$PERSIST_LOG"

echo "== a name roost will not put in a unit name =="
for bad in "a b" "a/b" ""; do
  out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist on --name "$bad" 2>&1)"; rc=$?
  assert_eq "$rc" "1" "persist on --name '$bad' exits 1"
done
assert_eq "$(ls "$HOME/Library/LaunchAgents" 2>/dev/null)" "" "...and writes no plist"
assert_eq "$(cat "$PERSIST_LOG")" "" "...and loads nothing"

echo "== service.env is written by on, and only by on =="
TL rename-window -t '=main:1' env-edit
STUB_UNAME=Darwin PATH="$STUBS:$PATH" ROOST_PERSIST_WRITE_ONLY=1 R persist on >/dev/null 2>&1
sed "s|^XDG_STATE_HOME=.*|XDG_STATE_HOME=/elsewhere/state|" "$SD/service.env" > "$SHAPE_TMP/env.edited"
cat "$SHAPE_TMP/env.edited" > "$SD/service.env"
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist status 2>&1)"
assert_contains "$out" "XDG_STATE_HOME" "status names the root that differs"
assert_not_contains "$out" "roots match" "...and does not say the roots match"
cmp -s "$SHAPE_TMP/env.edited" "$SD/service.env"; assert_true $? "status leaves the edited service.env byte for byte as it was"
STUB_UNAME=Darwin PATH="$STUBS:$PATH" ROOST_PERSIST_WRITE_ONLY=1 R persist off >/dev/null 2>&1

echo "== the publish wait: a live saver's lock holds the load back =="
TL rename-window -t '=main:1' publish-wait
: > "$PERSIST_LOG"
live_pid
mkdir -p "$SD/lock"; ln -s "$LIVE $LIVE_ST" "$SD/lock/owner"
( STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist on > "$SHAPE_TMP/on.out" 2>&1; echo $? > "$SHAPE_TMP/on.rc" ) &
onp=$!
sleep 2
assert_eq "$([ -e "$SHAPE_TMP/on.rc" ] || echo waiting)" "waiting" "on is still waiting while the lock's owner lives"
assert_eq "$(grep -c bootstrap "$PERSIST_LOG")" "0" "...and has not loaded the unit"
kill "$LIVE" 2>/dev/null
wait "$onp" 2>/dev/null
assert_eq "$(cat "$SHAPE_TMP/on.rc")" "0" "once the owner is gone, on exits 0 ($(cat "$SHAPE_TMP/on.out"))"
assert_eq "$(trig "$SD")" "persist-on" "...its save is published (trigger persist-on)"
assert_eq "$(grep -c "launchctl bootstrap" "$PERSIST_LOG")" "1" "...and only then the unit is loaded"
STUB_UNAME=Darwin PATH="$STUBS:$PATH" R persist off >/dev/null 2>&1
: > "$PERSIST_LOG"

echo "== a failing save: on leaves nothing behind =="
TL rename-window -t '=main:1' failing-save
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" ROOST_TEST_PUBLISH_FAIL=1 R persist on 2>&1)"; rc=$?
assert_eq "$rc" "1" "on exits 1 when its save fails"
assert_eq "$([ -e "$SD/persist" ] || [ -e "$SD/service.env" ] || [ -e "$PLIST" ] || echo none)" "none" \
  "...and removes the persist marker and service.env it wrote (no plist)"
assert_eq "$(cat "$PERSIST_LOG")" "" "...and loads nothing"
rm -f "$SD/save.err"

echo "== no launchd or systemd: exit 17 =="
out="$(STUB_UNAME=SunOS PATH="$STUBS:$PATH" R persist on 2>&1)"; rc=$?
assert_eq "$rc" "17" "on exits 17 on a system with neither ($out)"
assert_eq "$([ -e "$SD/persist" ] || [ -e "$SD/service.env" ] || echo none)" "none" "...and writes nothing"
out="$(STUB_UNAME=SunOS PATH="$STUBS:$PATH" R persist off 2>&1)"; rc=$?
assert_eq "$rc" "17" "off exits 17 too"

echo "== saving off: persist has nothing to restore from =="
out="$(STUB_UNAME=Darwin PATH="$STUBS:$PATH" ROOST_SHAPE_DIR= R persist on 2>&1)"; rc=$?
assert_eq "$rc" "1" "on exits 1 with saving off"
assert_contains "$out" "saving is off" "...and says why"

echo "== usage =="
out="$(R persist 2>&1)"; rc=$?
assert_eq "$rc" "2" "persist with no verb exits 2"
out="$(R persist sideways 2>&1)"; rc=$?
assert_eq "$rc" "2" "an unknown verb exits 2"

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
