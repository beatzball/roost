#!/usr/bin/env bash
# The saved shape (#51, #191): the one switch for saving, the server key, the
# shape directory. Design: docs/airig/specs/2026-10-24-persistent-sessions-design.md
# §3.1 (where it lives) and §3.4a (the one switch). Later tasks add `roost
# save`, the checker and the parser to this file.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
shape_test_setup; trap shape_test_teardown EXIT
. scripts/lib/roost-shape.sh

echo "== roost_shape_saving: the one switch (§3.4a) =="
# Each case in a subshell, so one case's ROOST_SHAPE_DIR never reaches the next.
got="$(ROOST_SHAPE_DIR="" roost_shape_saving)"
assert_eq "$got" "" "ROOST_SHAPE_DIR empty: saving is off (prints nothing)"
got="$(ROOST_SHAPE_DIR="rel/dir" roost_shape_saving)"
assert_eq "$got" "" "ROOST_SHAPE_DIR relative: saving is off (prints nothing)"
got="$(unset ROOST_SHAPE_DIR; XDG_STATE_HOME="$SHAPE_TMP/st" roost_shape_saving)"
assert_eq "$got" "$SHAPE_TMP/st/roost/shapes" "unset: the default under XDG_STATE_HOME"
got="$(unset ROOST_SHAPE_DIR XDG_STATE_HOME; roost_shape_saving)"
assert_eq "$got" "$HOME/.local/state/roost/shapes" "unset with no XDG_STATE_HOME: under HOME"
got="$(unset ROOST_SHAPE_DIR; XDG_STATE_HOME="rel" roost_shape_saving)"
assert_eq "$got" "$HOME/.local/state/roost/shapes" "a relative XDG_STATE_HOME is ignored, as the record's root does"
got="$(ROOST_SHAPE_DIR="$SHAPE_TMP/abs" roost_shape_saving)"
assert_eq "$got" "$SHAPE_TMP/abs" "absolute: that path"
got="$(ROOST_SHAPE_DIR="$SHAPE_TMP/abs//" roost_shape_saving)"
assert_eq "$got" "$SHAPE_TMP/abs" "trailing slashes are dropped"
got="$(ROOST_SHAPE_DIR="/" roost_shape_saving)"
assert_eq "$got" "" "the root directory itself is refused"
# The default must not read anything else: a persist marker, a config file.
# Saving is always on (§3.4a, decided 2026-10-25), so a server dir that holds
# no `persist` file still saves.
got="$(ROOST_SHAPE_DIR="$SHAPE_TMP/abs" roost_shape_saving; echo "rc=$?")"
assert_eq "$got" "$SHAPE_TMP/abs
rc=0" "saving on exits 0"
got="$(ROOST_SHAPE_DIR="" roost_shape_saving; echo "rc=$?")"
assert_eq "$got" "rc=1" "saving off exits 1"

echo "== roost_shape_key: the server's directory name (§3.1) =="
assert_eq "$(roost_shape_key -L roost "")" "roost" "-L roost is keyed roost"
assert_eq "$(roost_shape_key -L shp9 "")" "shp9" "-L NAME is keyed NAME"
k1="$(roost_shape_key -S /a/b-c)"; k2="$(roost_shape_key -S /a-b/c)"
assert_prefix "$k1" "path-" "-S PATH is keyed path-<cksum>"
want="path-$(printf '%s' /a/b-c | cksum | cut -d' ' -f1)"
assert_eq "$k1" "$want" "...and the number is cksum of the path"
[ "$k1" != "$k2" ]; assert_true $? "/a/b-c and /a-b/c give two keys ($k1, $k2)"
[ "$(roost_shape_key -S /tmp/x/roost)" != "roost" ]
assert_true $? "a -S server whose socket is called roost never shares the real server's key"

echo "== roost_shape_dir: the per-server directory, 0700 (§3.1, §8.1) =="
d="$(roost_shape_dir -L "$ROOST_SOCKET")"; rc=$?
assert_eq "$rc:$d" "0:$ROOST_SHAPE_DIR/$ROOST_SOCKET" "prints <root>/<key>"
[ -d "$d" ]; assert_true $? "...and makes it"
assert_eq "$(ls -ld "$d" | cut -c1-10)" "drwx------" "...mode 0700"
chmod 755 "$d"
d="$(roost_shape_dir -L "$ROOST_SOCKET")"
assert_eq "$(ls -ld "$d" | cut -c1-10)" "drwx------" "an existing server dir is put back to 0700"
assert_eq "$(ls -ld "$ROOST_SHAPE_DIR" | cut -c1-10)" "drwx------" "a shape root it creates is 0700"
d="$(ROOST_SHAPE_DIR="" roost_shape_dir -L "$ROOST_SOCKET")"; rc=$?
assert_eq "$rc:$d" "1:" "saving off: prints nothing, exits 1"
d="$(ROOST_SHAPE_DIR="$SHAPE_TMP/off-check" roost_shape_dir -L x >/dev/null; ROOST_SHAPE_DIR="" roost_shape_dir -L y)"
[ ! -e "$SHAPE_TMP/off-check/y" ]; assert_true $? "...and makes nothing"

echo "== the test library itself =="
stub_store_add 3fa32375-68cd-43c9-8bcf-fbb876b2db1e /tmp/roost-fixture/w.x/proj
f="$CLAUDE_CONFIG_DIR/projects/-tmp-roost-fixture-w-x-proj/3fa32375-68cd-43c9-8bcf-fbb876b2db1e.jsonl"
[ -f "$f" ]; assert_true $? "stub_store_add files by the measured folder rule (/ and . as -)"
assert_contains "$(cat "$f" 2>/dev/null)" '"cwd":"/tmp/roost-fixture/w.x/proj"' "...holding the cwd line"
p="$(TL new-window -d -P -F '#{pane_id}' -t shp: -e STUB_IDENTIFY=1 "claude --resume 3fa32375-68cd-43c9-8bcf-fbb876b2db1e")"
i=0; while [ "$i" -lt 30 ] && [ -z "$(TL show -pqv -t "$p" @roost-session)" ]; do sleep 0.1; i=$((i+1)); done
assert_eq "$(TL show -pqv -t "$p" @roost-session)" "3fa32375-68cd-43c9-8bcf-fbb876b2db1e" \
  "the claude stub with STUB_IDENTIFY=1 identifies its pane with the --resume id"
assert_contains "$(cat "$STUB_LOG")" "claude --resume 3fa32375-68cd-43c9-8bcf-fbb876b2db1e" "...and logs its argv"
assert_eq "$(TL display -p -t "$p" '#{pane_current_command}')" "claude" "...and reads as claude"
TL kill-pane -t "$p"

# --- roost save: the writer (Task 1.9) ----------------------------------------
ROOST="$PWD/bin/roost"
R() { ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"        # this server's shape directory (key: the -L name)
# blk FILE ID — the block holding the line `id ID`; val BLOCK KEY — its value.
blk() { awk -v RS= -v want="id $2" '{ s = $0 "\n"; if (index(s, "\n" want "\n")) print }' "$1"; }
val() { printf '%s\n' "$1" | sed -n "s/^$2 //p"; }
has() { printf '%s\n' "$1" | grep -q "^$2 "; }
# wait_opt PANE OPTION — until the pane's option is set (an identify inside it
# runs asynchronously to this shell), at most 3 s.
wait_opt() { local i=0; while [ "$i" -lt 30 ] && [ -z "$(TL show -pqv -t "$1" "$2")" ]; do sleep 0.1; i=$((i+1)); done; }
# wait_cmd PANE NAME — until #{pane_current_command} reads NAME, at most 3 s.
wait_cmd() { local i=0; while [ "$i" -lt 30 ] && [ "$(TL display -p -t "$1" '#{pane_current_command}')" != "$2" ]; do sleep 0.1; i=$((i+1)); done; }
ID_A=3fa32375-68cd-43c9-8bcf-fbb876b2db1e
ID_B=0b5e1c2a-7d4f-4e61-9a3b-5c2d1e0f9a87
ID_C=6a7b8c9d-1e2f-4a3b-8c4d-5e6f7a8b9c0d

echo "== roost_shape_agree: is the pane still running the agent it reported? =="
assert_eq "$(roost_shape_agree claude claude)" "ok" "claude reported, claude running: ok"
assert_eq "$(roost_shape_agree claude 2.1.312)" "ok" "Claude's version string is claude: ok"
assert_eq "$(roost_shape_agree claude bash)" "exited" "a shell: exited"
assert_eq "$(roost_shape_agree codex zsh)" "exited" "a shell, any harness: exited"
assert_eq "$(roost_shape_agree codex claude)" "nested" "another harness running: nested"
assert_eq "$(roost_shape_agree claude sleep)" "other" "any other command: other"
assert_eq "$(roost_shape_agree copilot copilot)" "ok" "copilot reads copilot (probe 1.6): ok"
assert_eq "$(roost_shape_agree copilot node)" "other" "copilot is measured, so node under it is other"
assert_eq "$(roost_shape_agree pi node)" "ok" "pi reads node, not distinctive: presence alone"
assert_eq "$(roost_shape_agree opencode node)" "ok" "opencode is not measured: presence alone"
assert_eq "$(roost_shape_agree pi bash)" "exited" "a shell under pi: exited (holds for all five)"

echo "== the fixture fleet =="
TL set -g base-index 1
TL new-session -d -s alpha -x 200 -y 50 -c "$SHAPE_TMP" 'ENV= exec /bin/sh'
# The setup session goes only AFTER alpha exists: killing a server's last
# session ends the server, and the next command would start a fresh one with
# none of the options set above.
TL kill-session -t '=shp:' 2>/dev/null
TL new-session -d -s beta -x 200 -y 50 -c "$SHAPE_TMP" 'ENV= exec /bin/sh'
# alpha: window 1 split in two and zoomed; the second pane carries a name with
# two leading and three trailing spaces.
a1="$(TL display -p -t '=alpha:1' '#{pane_id}')"
a2="$(TL split-window -d -P -F '#{pane_id}' -t "$a1" -c "$SHAPE_TMP" 'ENV= exec /bin/sh')"
TL set -p -t "$a2" @roost-name '  sp   '
TL resize-pane -Z -t "$a1"
# alpha window 2: a claude stub identified through the real `roost identify`.
mkdir -p "$SHAPE_TMP/w.x/proj"
k1="$(TL new-window -d -P -F '#{pane_id}' -t '=alpha:2' -c "$SHAPE_TMP/w.x/proj" -e STUB_IDENTIFY=1 "claude --resume $ID_A")"
# beta window 5 (base-index 1 makes its first window 1): a codex pane identified
# with a transcript, a stale exited pane, a nested pane, an `other` pane.
k2="$(TL new-window -d -P -F '#{pane_id}' -t '=beta:5' -c "$SHAPE_TMP" \
  "$ROOST identify --session $ID_B --cwd $SHAPE_TMP --harness codex --transcript $SHAPE_TMP/t.jsonl; exec \"\$STUB_BIN/codex\" 600")"
ex="$(TL split-window -d -P -F '#{pane_id}' -t "$k2" -c "$SHAPE_TMP" \
  "$ROOST identify --session $ID_C --cwd $SHAPE_TMP --harness claude; ENV= exec /bin/sh")"
ne="$(TL split-window -d -P -F '#{pane_id}' -t "$k2" -c "$SHAPE_TMP" \
  "$ROOST identify --session $ID_C --cwd $SHAPE_TMP --harness codex; exec \"\$STUB_BIN/claude\" 600")"
ot="$(TL split-window -d -P -F '#{pane_id}' -t "$k2" -c "$SHAPE_TMP" \
  "$ROOST identify --session $ID_A --cwd $SHAPE_TMP --harness claude; exec sleep 600")"
for p in "$k1" "$k2" "$ex" "$ne" "$ot"; do wait_opt "$p" @roost-session; done
wait_cmd "$k1" claude; wait_cmd "$k2" codex; wait_cmd "$ne" claude; wait_cmd "$ot" sleep
# A pane `roost spawn` started with a secret in its command.
sp="$(cd "$SHAPE_TMP" && TMUX_PANE="$a1" R spawn x 'FOO_TOKEN=abc sh')"

echo "== a first save =="
out="$(R save 2>"$SHAPE_TMP/save.err")"; rc=$?
assert_eq "$rc:$out" "0:$SD/shape" "roost save prints the shape's path, exit 0"
assert_eq "$(cat "$SHAPE_TMP/save.err")" "2 sessions, 5 windows, 9 panes, 2 with a conversation, 3 stale" \
  "...and its summary on stderr"
F="$SD/shape"
assert_eq "$(head -1 "$F")" "roost-shape 1" "the file starts roost-shape 1"
hdr="$(awk 'NF == 0 { exit } { print }' "$F")"
for k in server socket boot saved gen trigger roost tmux host; do
  has "$hdr" "$k"; assert_true $? "the header has $k"
done
assert_eq "$(val "$hdr" server)" "roost" "server is the key"
assert_eq "$(val "$hdr" socket)" "$SHAPE_SOCK" "socket is the server's socket path"
assert_eq "$(val "$hdr" boot)" "$(TL display -p '#{start_time}-#{pid}')" "boot is start_time-pid"
case "$(val "$hdr" saved)" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) r=0 ;; *) r=1 ;; esac
assert_true $r "saved is a UTC stamp ($(val "$hdr" saved))"
assert_eq "$(val "$hdr" gen)" "1" "gen 1"
assert_eq "$(val "$hdr" trigger)" "save" "trigger save"
assert_eq "$(val "$hdr" roost)" "$(cat VERSION)" "roost is this checkout's VERSION"
assert_eq "$(val "$hdr" tmux)" "$(TL display -p '#{version}')" "tmux is the server's version"
assert_eq "$(ls -l "$F" | cut -c1-10)" "-rw-------" "shape is 0600"
assert_eq "$(cat "$SD/gen")" "1" "the gen file reads 1"
assert_eq "$(ls "$SD/history" 2>/dev/null | wc -l | tr -d ' ')" "0" "a first save archives nothing"

aid="$(TL display -p -t '=alpha:' '#{session_id}')"
b="$(blk "$F" "$aid")"
assert_eq "$(printf '%s\n' "$b" | head -1)" "session alpha" "a session block names its session"
w="$(blk "$F" "$(TL display -p -t "$a1" '#{window_id}')")"
assert_eq "$(printf '%s\n' "$w" | head -1)" "window alpha:1" "a window block is SESSION:INDEX"
assert_eq "$(val "$w" layout)" "$(TL display -p -t "$a1" '#{window_layout}')" "the layout is #{window_layout} as read, zoomed (probe 1.1)"
assert_eq "$(val "$w" zoomed)" "1" "the zoomed window has zoomed 1"
w5="$(blk "$F" "$(TL display -p -t "$k2" '#{window_id}')")"
assert_eq "$(printf '%s\n' "$w5" | head -1)" "window beta:5" "the window at index 5 keeps its index"
has "$w5" zoomed; assert_eq "$?" "1" "an unzoomed window has no zoomed line"
p="$(blk "$F" "$a2")"
assert_eq "$(printf '%s\n' "$p" | head -1)" "pane alpha:1.1" "a pane block is SESSION:WINDOW.PANE"
assert_eq "[$(val "$p" name)]" "[  sp   ]" "a name with two leading and three trailing spaces is kept byte for byte"
assert_eq "$(val "$p" cwd)" "$SHAPE_TMP" "cwd is the pane's directory"
has "$p" session_cwd; assert_eq "$?" "1" "no session_cwd where @roost-cwd is unset"
p="$(blk "$F" "$k1")"
assert_eq "$(val "$p" harness):$(val "$p" session_id)" "claude:$ID_A" "an agreeing claude pane has harness and session_id"
assert_eq "$(val "$p" session_cwd)" "$SHAPE_TMP/w.x/proj" "session_cwd is @roost-cwd"
assert_eq "$(val "$p" command)" "claude" "command is #{pane_current_command}"
p="$(blk "$F" "$k2")"
assert_eq "$(val "$p" harness):$(val "$p" transcript)" "codex:$SHAPE_TMP/t.jsonl" "a codex pane keeps its transcript"
p="$(blk "$F" "$ex")"
assert_eq "$(val "$p" stale_reason):$(val "$p" stale_harness):$(val "$p" stale_session_id)" "exited:claude:$ID_C" \
  "an agent that exited to its shell is stale_reason exited"
has "$p" harness; assert_eq "$?" "1" "...with no plain harness line"
p="$(blk "$F" "$ne")"
assert_eq "$(val "$p" stale_reason):$(val "$p" stale_harness)" "nested:codex" "codex reported, claude running: stale_reason nested"
has "$p" harness; assert_eq "$?" "1" "...with no plain harness line"
p="$(blk "$F" "$ot")"
assert_eq "$(val "$p" stale_reason)" "other" "identity set, sleep running: stale_reason other"
has "$p" session_id; assert_eq "$?" "1" "...with no plain session_id line"
p="$(blk "$F" "$sp")"
assert_eq "$(val "$p" launch)" "FOO_TOKEN=… sh" "spawn's command is the launch hint, its secret redacted"
assert_eq "$(TL show -pqv -t "$sp" @roost-launch)" "FOO_TOKEN=abc sh" "...redacted at save, not in the pane option"
assert_eq "$(TL list-panes -a -F '#{@roost-shape-probe}' | grep -c .)" "0" "no pane carries the writer's test option after the save"
TL list-panes -a -F '#{pane_id}' > "$SHAPE_TMP/ids"
assert_eq "$(grep -c '^pane ' "$F")" "$(wc -l < "$SHAPE_TMP/ids" | tr -d ' ')" "one pane block per pane"
assert_eq "$(LC_ALL=C grep -c '[[:cntrl:]]' "$F")" "0" "no control byte anywhere in the file"

echo "== the body compare (§8.1 test 1) =="
R save >/dev/null 2>&1
assert_eq "$(cat "$SD/gen"):$(ls "$SD/history" | wc -l | tr -d ' ')" "1:0" "a second save with no change writes nothing"
TL rename-window -t "$k1" renamed
R save >/dev/null 2>&1
assert_eq "$(cat "$SD/gen"):$(ls "$SD/history" | wc -l | tr -d ' ')" "2:1" "a change: gen 2 and one history file"
assert_eq "$(ls "$SD/history")" "$(val "$hdr" saved | tr -d ':-')-1" "the history file is the old save's stamp and gen"
assert_eq "$(ls -l "$SD/history/"* | cut -c1-10)" "-rw-------" "a history file is 0600"
R save >/dev/null 2>&1
assert_eq "$(cat "$SD/gen"):$(ls "$SD/history" | wc -l | tr -d ' ')" "2:1" "no change again: still gen 2, one history file"
assert_eq "$(val "$(blk "$F" "$(TL display -p -t "$k1" '#{window_id}')")" name)" "renamed" "a renamed window is saved with its name"
R save --to "$SHAPE_TMP/copy" >/dev/null 2>&1; rc=$?
assert_eq "$rc:$(head -1 "$SHAPE_TMP/copy" 2>/dev/null)" "0:roost-shape 1" "save --to FILE writes there"
assert_eq "$(cat "$SD/gen"):$(ls "$SD/history" | wc -l | tr -d ' ')" "2:1" "...and leaves shape alone"
R save --trigger spawn --to "$SHAPE_TMP/copy2" >/dev/null 2>&1
assert_eq "$(sed -n 's/^trigger //p' "$SHAPE_TMP/copy2")" "spawn" "--trigger names the cause in the header"

echo "== saving off, a read-only directory, a stopped server (§8.1 test 10a) =="
out="$(ROOST_SHAPE_DIR= R save 2>"$SHAPE_TMP/e")"; rc=$?
assert_eq "$rc:$out" "0:" "ROOST_SHAPE_DIR empty: exit 0, nothing printed"
assert_contains "$(cat "$SHAPE_TMP/e")" "saving is off" "...one stderr line says saving is off"
assert_eq "$(wc -l < "$SHAPE_TMP/e" | tr -d ' ')" "1" "...exactly one line"
out="$(ROOST_SHAPE_DIR=rel/dir R save 2>"$SHAPE_TMP/e")"; rc=$?
assert_eq "$rc:$out:$(cat "$SHAPE_TMP/e" | grep -c 'saving is off')" "0::1" "ROOST_SHAPE_DIR relative: the same"
[ ! -e rel ]; assert_true $? "...and no relative directory was made"
# Root writes into a mode-500 directory regardless (the Ubuntu container runs
# the suite as root; CI's runner does not), so that case can only be asserted
# as a normal user. A FILE where the directory should be refuses everyone.
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$SHAPE_TMP/ro/roost"; chmod 500 "$SHAPE_TMP/ro/roost"
  ROOST_SHAPE_DIR="$SHAPE_TMP/ro" R save >/dev/null 2>"$SHAPE_TMP/e"; rc=$?
  assert_eq "$rc" "1" "a read-only shape directory: exit 1"
  assert_contains "$(cat "$SHAPE_TMP/e")" "$SHAPE_TMP/ro/roost" "...naming it"
  assert_eq "$(ls -ld "$SHAPE_TMP/ro/roost" | cut -c1-10)" "dr-x------" "...and still read-only (roost takes bits away, never adds them)"
  chmod 700 "$SHAPE_TMP/ro/roost"
else
  printf '  SKIP: a read-only shape directory (running as root, which writes into it anyway)\n'
fi
mkdir -p "$SHAPE_TMP/blocked"; : > "$SHAPE_TMP/blocked/roost"
ROOST_SHAPE_DIR="$SHAPE_TMP/blocked" R save >/dev/null 2>"$SHAPE_TMP/e"; rc=$?
assert_eq "$rc" "1" "a file where the shape directory should be: exit 1"
assert_contains "$(cat "$SHAPE_TMP/e")" "$SHAPE_TMP/blocked/roost" "...naming it"
cp -Rp "$SD" "$ROOST_SHAPE_DIR/stopped"
ROOST_SOCKET=stopped "$ROOST" save >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "a server that is not running: exit 1"
diff -r "$SD" "$ROOST_SHAPE_DIR/stopped" >/dev/null; assert_true $? "...shape, gen and history unchanged (a failed listing never publishes)"

echo "== odd values (probe 1.3, rulings R6 and R8) =="
# Each value as a directory a shell entered, as @roost-cwd and as @roost-name.
# R6: tmux 3.4 prints `$` as `\$`; the writer must read every one back as typed.
O="$SHAPE_TMP/odd"; mkdir -p "$O"
TL new-session -d -s odd -x 200 -y 50 -c "$O" 'ENV= exec /bin/sh'
oddpane() { # VALUE -> pane id; a pane whose shell entered $O/VALUE, @roost-cwd and @roost-name set
  local d="$O/$1" p
  mkdir -p "$d"
  p="$(TL new-window -d -P -F '#{pane_id}' -t '=odd:' -e "PD=$d" 'cd "$PD" && exec sleep 600')"
  TL set -p -t "$p" @roost-cwd "$d"
  TL set -p -t "$p" @roost-name "$1"
  printf '%s\n' "$p"
}
ODD=('a$b' 'a\$b' 'a$HOME' 'a${HOME}b' 'ab'); OP=()
for v in "${ODD[@]}"; do OP+=("$(oddpane "$v")"); done
sleep 0.5
R save --to "$SHAPE_TMP/odd.shape" >/dev/null 2>"$SHAPE_TMP/odd.err"
i=0
for v in "${ODD[@]}"; do
  p="${OP[$i]}"; i=$((i+1)); b="$(blk "$SHAPE_TMP/odd.shape" "$p")"
  assert_eq "$(val "$b" cwd)|$(val "$b" session_cwd)|$(val "$b" name)" "$O/$v|$O/$v|$v" \
    "R6: [$v] round-trips as cwd, session_cwd and name ($(TL display -p '#{version}'))"
done
# Control bytes, Task 1.3's rows and R8: each dropped or sent home, one stderr
# line each, the same result on every tmux build.
esc="$(printf '\033')"; tab="$(printf '\t')"; nl="$(printf 'n\nl')"
cbpane() { # VALUE -> pane id; its shell entered $O/VALUE and @roost-name is VALUE
  local d="$O/$1" p
  mkdir -p "$d"
  p="$(TL new-window -d -P -F '#{pane_id}' -t '=odd:' -e "PD=$d" 'cd "$PD" && exec sleep 600')"
  TL set -p -t "$p" @roost-name "$1"
  printf '%s\n' "$p"
}
cbe="$(cbpane "e${esc}c")"; cbt="$(cbpane "t${tab}b")"; cbn="$(cbpane "$nl")"
TL rename-window -t "$cbe" "w${esc}x"
sleep 0.5
R save --to "$SHAPE_TMP/cb.shape" >/dev/null 2>"$SHAPE_TMP/cb.err"; rc=$?
assert_eq "$rc" "0" "a fleet with control bytes still saves, exit 0"
assert_eq "$(LC_ALL=C grep -c '[[:cntrl:]]' "$SHAPE_TMP/cb.shape")" "0" "no control byte anywhere in the file"
for pair in "$cbe:ESC" "$cbt:tab" "$cbn:newline (R8.1)"; do
  p="${pair%%:*}"; what="${pair#*:}"; b="$(blk "$SHAPE_TMP/cb.shape" "$p")"
  assert_eq "$(val "$b" cwd)" "$HOME" "a directory holding a $what: cwd is the home directory"
  has "$b" name; assert_eq "$?" "1" "a name holding a $what: the name key is dropped"
  assert_contains "$(cat "$SHAPE_TMP/cb.err")" "pane $p:" "...a stderr line names $p"
done
assert_eq "$(grep -c "pane $cbn:" "$SHAPE_TMP/cb.err")" "2" "the newline pane gets one line for its cwd and one for its name"
w="$(blk "$SHAPE_TMP/cb.shape" "$(TL display -p -t "$cbe" '#{window_id}')")"
assert_eq "$(val "$w" name)" 'w\033x' "a window name: tmux itself stores the ESC as text on every build (probe 1.3)"

echo "== the owner rule holds under a race (review round 1, B2) =="
# Two separate processes (each its own $$ and start time, as two restores
# are) call the real roost_shape_owner_take on one directory. The seams pause
# each at the point the reviewer found racy, so the race is planted on cue:
# ROOST_TEST_OWNER_PAUSE_DEAD right after a dead owner's record is seen,
# ROOST_TEST_OWNER_PAUSE_FRESH right before the first claim. Each waits for
# its FILE and marks FILE.at.<pid> when it arrives.
OD="$SHAPE_TMP/own"; mkdir -p "$OD"
taker() { # NAME DIR SEAM -> a process that takes DIR's owner and then stays alive until $OD/stop
  env "$3=$OD/go.$1" bash -c '. scripts/lib/roost-shape.sh; echo $$ > "$1/$2.pid"
    roost_shape_owner_take "$3"; echo $? > "$1/$2.rc"
    while [ ! -e "$1/stop" ]; do sleep 0.1; done' _ "$OD" "$1" "$2" &
}
arrived() { local i=0; while [ "$i" -lt 50 ] && ! ls "$OD/go.$1.at."* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done; }
done_rc() { local i=0; while [ "$i" -lt 50 ] && [ ! -s "$OD/$1.rc" ]; do sleep 0.1; i=$((i+1)); done; cat "$OD/$1.rc" 2>/dev/null; }
sh -c 'exit 0' & deadpid=$!; wait "$deadpid"
D1="$OD/dead"; mkdir -p "$D1"; ln -s "$deadpid Thu Jan  1 00:00:00 1970" "$D1/owner"
taker A "$D1" ROOST_TEST_OWNER_PAUSE_DEAD; taker B "$D1" ROOST_TEST_OWNER_PAUSE_DEAD
arrived A; arrived B
: > "$OD/go.A"; ra="$(done_rc A)"
: > "$OD/go.B"; rb="$(done_rc B)"
assert_eq "$ra|$rb" "2|1" "both saw the same dead owner: A takes it over, B is refused while A lives"
assert_eq "$(readlink "$D1/owner" | cut -d' ' -f1)" "$(cat "$OD/A.pid")" "...and the record names A"
D2="$OD/fresh"; mkdir -p "$D2"
taker C "$D2" ROOST_TEST_OWNER_PAUSE_FRESH; taker E "$D2" ROOST_TEST_OWNER_PAUSE_FRESH
arrived C; arrived E
: > "$OD/go.C"; : > "$OD/go.E"
rc_c="$(done_rc C)"; rc_e="$(done_rc E)"
assert_eq "$(printf '%s\n%s\n' "$rc_c" "$rc_e" | sort | tr '\n' ' ')" "0 1 " \
  "a directory with no owner yet, two claims at once: exactly one owns it"
: > "$OD/stop"; wait 2>/dev/null

echo "== the caller's locale changes nothing (review round 1, B4) =="
# tmux's CLIENT decides how to print a value: under LC_ALL=C or no locale at
# all it turns a control byte and every non-ASCII byte into `_` (measured on
# 3.2a, 3.4 and 3.6), so a writer reading under the caller's locale would save
# `n_l` for a directory holding a newline and a mangled glyph. The writer must
# read the real bytes whatever locale it was started in: three saves of the
# same fleet — UTF-8, C, none — have the same body. $TMUX is unset for the
# two: a tmux client started inside tmux assumes UTF-8 whatever the locale
# says (measured: inside a pane these passed before the fix), and a person
# runs `roost save` from any shell.
gl="$(cbpane "g🐓l")"; TL set -p -t "$gl" @roost-name "g🐓l"
sleep 0.3
R save --to "$SHAPE_TMP/loc-utf8.shape" >/dev/null 2>&1
env -u TMUX -u TMUX_PANE LC_ALL=C LANG=C ROOST_SOCKET=roost "$ROOST" save --to "$SHAPE_TMP/loc-c.shape" >/dev/null 2>&1
env -u TMUX -u TMUX_PANE -u LC_ALL -u LANG -u LC_CTYPE ROOST_SOCKET=roost "$ROOST" save --to "$SHAPE_TMP/loc-none.shape" >/dev/null 2>&1
body() { sed '1,/^$/d' "$1"; }
assert_eq "$(body "$SHAPE_TMP/loc-c.shape")" "$(body "$SHAPE_TMP/loc-utf8.shape")" "a save under LC_ALL=C writes the same body as one under UTF-8"
assert_eq "$(body "$SHAPE_TMP/loc-none.shape")" "$(body "$SHAPE_TMP/loc-utf8.shape")" "a save with no locale set writes the same body"
grep -q '🐓' "$SHAPE_TMP/loc-c.shape"; assert_true $? "...the UTF-8 glyph survives a C-locale save"

echo "== a value that ENDS in a newline is still a control byte (review round 1, Codex B5) =="
# A $(...) drops every trailing newline, the value's own included, so a
# reread by id must keep them (a sentinel) before the control-byte rule runs.
d="$O/end"$'\n'; mkdir -p "$d"
en="$(TL new-window -d -P -F '#{pane_id}' -t '=odd:' -e "PD=$d" 'cd "$PD" && exec sleep 600')"
TL set -p -t "$en" @roost-name "label"$'\n'
sleep 0.5
R save --to "$SHAPE_TMP/end.shape" >/dev/null 2>"$SHAPE_TMP/end.err"
b="$(blk "$SHAPE_TMP/end.shape" "$en")"
has "$b" name; assert_eq "$?" "1" "a name ending in a newline is dropped, not saved as 'label'"
assert_eq "$(val "$b" cwd)" "$HOME" "a directory ending in a newline is saved as the home directory"
assert_eq "$(grep -c "pane $en:" "$SHAPE_TMP/end.err")" "2" "...one stderr line for each"
TL kill-pane -t "$en"

echo "== a cut line in a linked window keeps its own address (review round 1, Codex B3) =="
# A linked pane is listed once per session/window it is in. When its line is
# cut by a newline, the reread must keep that line's own context: asked by
# %N alone, tmux answers one context, both copies got the same address, and
# the save published a file its own checker refused.
TL new-session -d -s lka -x 200 -y 50 -c "$SHAPE_TMP" 'ENV= exec /bin/sh'
TL new-session -d -s lkb -x 200 -y 50 -c "$SHAPE_TMP" 'ENV= exec /bin/sh'
TL link-window -s '=lka:1' -t '=lkb:7'
lp="$(TL list-panes -t '=lka:1' -F '#{pane_id}')"
TL set -p -t "$lp" @roost-name "$(printf 'a\nb')"
R save --to "$SHAPE_TMP/lk.shape" >/dev/null 2>&1; rc=$?
roost_shape_check "$SHAPE_TMP/lk.shape" 2>/dev/null; ckrc=$?
assert_eq "$rc:$ckrc:${ROOST_SHAPE_FAULT:-}" "0:0:" "save exits 0 and its file passes its own checker"
assert_eq "$(grep -c '^pane lka:1\.0$' "$SHAPE_TMP/lk.shape"):$(grep -c '^pane lkb:7\.0$' "$SHAPE_TMP/lk.shape")" "1:1" \
  "...the pane is written once under each of its two windows"
TL kill-session -t '=lka'; TL kill-session -t '=lkb'

echo "== a session group (R7) =="
TL new-session -d -s gmain -x 200 -y 50 -c "$SHAPE_TMP" 'ENV= exec /bin/sh'
TL new-window -d -t '=gmain:' 'ENV= exec /bin/sh'
TL split-window -d -t '=gmain:2' 'ENV= exec /bin/sh'
TL new-session -d -t '=gmain' -s gview
TL select-window -t '=gview:2'
R save --to "$SHAPE_TMP/g2.shape" >/dev/null 2>&1
gm="$(blk "$SHAPE_TMP/g2.shape" "$(TL display -p -t '=gmain:' '#{session_id}')")"
gv="$(blk "$SHAPE_TMP/g2.shape" "$(TL display -p -t '=gview:' '#{session_id}')")"
has "$gm" group; assert_eq "$?" "1" "the first member (lowest id) is saved in full, with no group line"
assert_eq "$(val "$gv" group)" "gmain" "the later member has group <first member's name>"
assert_eq "$(val "$gv" active_window)" "2" "...and its own current window"
assert_eq "$(grep -c '^window gview:' "$SHAPE_TMP/g2.shape"):$(grep -c '^pane gview:' "$SHAPE_TMP/g2.shape")" "0:0" \
  "...and no window or pane blocks"
assert_eq "$(grep -c '^window gmain:' "$SHAPE_TMP/g2.shape"):$(grep -c '^pane gmain:' "$SHAPE_TMP/g2.shape")" "2:3" \
  "the first member's windows and panes are there once"
assert_eq "$(sed -n 's/^id %//p' "$SHAPE_TMP/g2.shape" | sort | uniq -d)" "" "no pane id appears twice in the save"
TL new-session -d -t '=gmain' -s gthird
R save --to "$SHAPE_TMP/g3.shape" >/dev/null 2>&1
assert_eq "$(grep -c '^group gmain$' "$SHAPE_TMP/g3.shape")" "2" "a three-member group: two later-member blocks"
assert_eq "$(sed -n 's/^id %//p' "$SHAPE_TMP/g3.shape" | sort | uniq -d)" "" "...and still no pane id twice"
TL kill-session -t '=gview'; TL kill-session -t '=gthird'; TL kill-session -t '=gmain'

echo "== spawn, split and view keep the launch hint =="
s2="$(TMUX_PANE="$a1" R split -t "$a1" sleep 600)"
assert_eq "$(TL show -pqv -t "$s2" @roost-launch)" "sleep 600" "split sets @roost-launch to the command as handed"
v="$(TMUX_PANE="$a1" ROOST_VIEW_MIN_COLS=100000 R view -n vv sleep 600 2>/dev/null)"
assert_eq "$(TL show -pqv -t "$v" @roost-launch)" "roost view -n vv sleep 600" "view overwrites it with its own command"
s3="$(TMUX_PANE="$a1" R spawn bare)"
assert_eq "$(TL show -pqv -t "$s3" @roost-launch)" "" "a spawn with no command sets no launch hint"

# --- the checker and the parser (Task 1.10) ------------------------------------
# A file is checked WHOLE before restore runs its first tmux command (§3.2,
# §4.3): any fault refuses the file, naming the line. ck FILE -> "rc|fault".
ck() { roost_shape_check "$1" 2>"$SHAPE_TMP/ck.err"; printf '%s|%s' "$?" "${ROOST_SHAPE_FAULT:-}"; }
good() { # a small valid shape, one line per argument appended to the last block
  printf '%s\n' 'roost-shape 1' 'server roost' 'socket /tmp/x/roost' 'boot 1792526903-7170' \
    'saved 2026-10-24T20:51:02Z' 'gen 3' 'trigger save' 'roost 0.10.0' 'tmux 3.6' 'host h' '' \
    'session main' 'id $0' '' \
    'window main:1' 'id @0' 'layout 2774,200x50,0,0,0' 'active 1' '' \
    'pane main:1.0' 'id %0' 'cwd /tmp' "$@"
}
C="$SHAPE_TMP/ck"; mkdir -p "$C"
echo "== the checker refuses by line (§8.1 test 5, the parse half) =="
good > "$C/ok"
assert_eq "$(ck "$C/ok")" "0|" "a valid file passes"
good | sed '1s/.*/roost-shape 2/' > "$C/v2"
assert_eq "$(ck "$C/v2")" "1|line 1: roost-shape 2 is newer than this roost reads (1)" "roost-shape 2 is refused"
: > "$C/empty"
assert_eq "$(ck "$C/empty")" "1|line 1: no readable first line (want roost-shape 1)" "a zero-byte file is a named refusal"
printf 'hello\n' > "$C/junk"
assert_eq "$(ck "$C/junk")" "1|line 1: no readable first line (want roost-shape 1)" "a file that is not a shape is refused"
good | head -3 > "$C/cut"
assert_eq "$(ck "$C/cut")" "1|line 1: the header has no boot" "a file cut off inside its header is a named refusal"
good | sed '/^boot /d' > "$C/noboot"
assert_eq "$(ck "$C/noboot")" "1|line 1: the header has no boot" "a header with no boot is refused"
good 'cwd /var' > "$C/rep"
assert_eq "$(ck "$C/rep")" "1|line 23: repeated key cwd" "a repeated key in one block is refused"
good "$(printf 'name a\tb')" > "$C/tab"
assert_eq "$(ck "$C/tab")" "1|line 23: a value holds a tab or a control character" "a value with a tab is refused"
good "$(printf 'name a\033b')" > "$C/esc"
assert_eq "$(ck "$C/esc")" "1|line 23: a value holds a tab or a control character" "a value with another control character is refused"
{ good; printf '%s\n' '' 'window main:1' 'id @1' 'layout 1,1x1,0,0,0'; } > "$C/dupaddr"
assert_eq "$(ck "$C/dupaddr")" "1|line 24: repeated address window main:1" "a repeated address is refused"
good | sed '/^layout /d' > "$C/nolayout"
assert_eq "$(ck "$C/nolayout")" "1|line 15: window main:1 has no layout" "a window with no layout is refused"
good | sed '/^cwd /d' > "$C/nocwd"
assert_eq "$(ck "$C/nocwd")" "1|line 20: pane main:1.0 has no cwd" "a pane with no cwd is refused"
good | sed 's/^pane main:1\.0/pane main:2.0/' > "$C/noparent"
assert_eq "$(ck "$C/noparent")" "1|line 20: pane main:2.0 has no window block" "a pane whose window block is missing is refused"
good | sed 's/^session main$/session work/' > "$C/renamed"
assert_eq "$(ck "$C/renamed")" "1|line 15: window main:1 has no session block" "a renamed session whose windows and panes were not renamed is refused"
good | sed 's/main/work/' > "$C/renamedall"
assert_eq "$(ck "$C/renamedall")" "0|" "a session renamed with all its addresses passes"
good | sed 's/^pane main:1\.0/pane main:1/' > "$C/badaddr"
assert_eq "$(ck "$C/badaddr")" "1|line 20: pane main:1 is not SESSION:WINDOW.PANE" "a malformed address is refused"
good 'nokey' > "$C/nospace"
assert_eq "$(ck "$C/nospace")" "1|line 23: no value after the key nokey" "a line with no value is refused"
{ good; printf '%s\n' '' 'parent main:1.0' 'id x'; } > "$C/unknown"
assert_eq "$(ck "$C/unknown")" "0|" "a block whose first word is unknown is skipped and the file passes"
assert_contains "$(cat "$SHAPE_TMP/ck.err")" "line 24" "...with one stderr line naming its line"
assert_eq "$(wc -l < "$SHAPE_TMP/ck.err" | tr -d ' ')" "1" "...exactly one"
good 'futurekey whatever' > "$C/unknownkey"
assert_eq "$(ck "$C/unknownkey")" "0|" "an unknown key is ignored"

{ good; printf '%s\n' '' 'session empty' 'id $5'; } > "$C/nowin"
assert_eq "$(ck "$C/nowin")" "1|line 24: session empty has no window block" \
  "a full session block with no window block is refused (review round 1, Fable B1: it could not start a server the roost way)"

echo "== session groups in the checker (R7) =="
{ good; printf '%s\n' '' 'session view' 'id $1' 'group main' 'active_window 1'; } > "$C/grp"
assert_eq "$(ck "$C/grp")" "0|" "a later member naming a full session passes"
{ good; printf '%s\n' '' 'session view' 'id $1' 'group nosuch'; } > "$C/grpbad"
assert_eq "$(ck "$C/grpbad")" "1|line 24: session view joins nosuch, which has no full session block" "a group line naming a session not in the file: the whole file is refused"
{ good; printf '%s\n' '' 'session view' 'id $1' 'group view'; } > "$C/grpself"
assert_eq "$(ck "$C/grpself")" "1|line 24: session view joins view, which has no full session block" "a member joining itself is refused"
{ good; printf '%s\n' '' 'session view' 'id $1' 'group main' '' 'session third' 'id $2' 'group view'; } > "$C/grpchain"
assert_eq "$(ck "$C/grpchain")" "1|line 28: session third joins view, which has no full session block" "a member joining another later member is refused"
{ good; printf '%s\n' '' 'session view' 'id $1' 'group main' '' 'window view:1' 'id @0' 'layout 1,1x1,0,0,0'; } > "$C/grpwin"
assert_eq "$(ck "$C/grpwin")" "1|line 28: window view:1 belongs to view, a later member of a group (it has no windows of its own)" "a later member with a window block is refused"

echo "== the parser =="
roost_shape_check "$C/grp" 2>/dev/null
PD="$SHAPE_TMP/parsed"; rm -rf "$PD"; roost_shape_parse "$C/grp" "$PD"
assert_eq "$(ls "$PD" | tr '\n' ' ')" "0000.header 0001.session 0002.window 0003.pane 0004.session " "one file per block, NNNN.<kind>, in file order"
assert_eq "$(roost_shape_get "$PD/0003.pane" cwd)" "/tmp" "roost_shape_get prints a value"
roost_shape_get "$PD/0003.pane" name >/dev/null; assert_eq "$?" "1" "...and returns 1 for an absent key (a reader tests presence)"
roost_shape_check "$C/unknown" 2>/dev/null; rm -rf "$PD"; roost_shape_parse "$C/unknown" "$PD"
assert_eq "$(ls "$PD" | grep -c parent)" "0" "an unknown block is not handed to restore"

echo "== the writer's files pass the reader (moved here from Task 1.9) =="
for f in "$F" "$SHAPE_TMP/copy" "$SHAPE_TMP/copy2" "$SHAPE_TMP/odd.shape" "$SHAPE_TMP/cb.shape" "$SHAPE_TMP/g2.shape" "$SHAPE_TMP/g3.shape" "$SD/history/"*; do
  assert_eq "$(ck "$f")" "0|" "$(basename "$f") passes roost_shape_check"
done
rm -rf "$PD"; roost_shape_parse "$F" "$PD"
b="$(grep -l "^id $a2\$" "$PD"/*.pane)"
assert_eq "[$(roost_shape_get "$b" name)]" "[  sp   ]" "a name with leading and trailing spaces parses byte for byte"
echo "== R6: the round trip through the reader =="
rm -rf "$PD"; roost_shape_parse "$SHAPE_TMP/odd.shape" "$PD"
i=0
for v in "${ODD[@]}"; do
  b="$(grep -l "^id ${OP[$i]}\$" "$PD"/*.pane)"; i=$((i+1))
  assert_eq "$(roost_shape_get "$b" cwd)|$(roost_shape_get "$b" session_cwd)|$(roost_shape_get "$b" name)" "$O/$v|$O/$v|$v" \
    "[$v] comes back from save, check and parse byte for byte ($(TL display -p '#{version}'))"
done

echo "== the kept shape (tests/fixtures/shape-v1.txt) =="
# This file was written by `roost save` (Task 1.10's own fleet: two sessions,
# a zoomed window, a keyed pane, a stale pane, a launch line), scrubbed to
# /tmp/roost-fixture/... paths and fake ids, and committed. It is NEVER
# edited: a later key gets a second fixture beside it, so every later roost is
# proven to read what this one wrote. One tool lost every saved session at an
# upgrade because nothing pinned its old format.
FX="tests/fixtures/shape-v1.txt"
assert_eq "$(ck "$FX")" "0|" "the kept shape passes the checker"
rm -rf "$PD"; roost_shape_parse "$FX" "$PD"
assert_eq "$(ls "$PD" | sed 's/^[0-9]*\.//' | sort | uniq -c | tr -s ' ' | tr '\n' ',')" " 1 header, 4 pane, 2 session, 3 window," "its block counts"
assert_eq "$(roost_shape_get "$PD/0000.header" server)" "roost" "header server"
b="$(grep -l '^harness claude$' "$PD"/*.pane)"
assert_eq "$(roost_shape_get "$b" session_id)" "11111111-1111-4111-8111-111111111111" "the keyed pane's session_id"
b="$(grep -l '^stale_reason ' "$PD"/*.pane)"
assert_eq "$(roost_shape_get "$b" stale_reason)" "exited" "the stale pane's reason"
b="$(grep -l '^zoomed 1$' "$PD"/*.window)"
assert_eq "$(roost_shape_get "$b" layout | cut -d, -f2)" "200x50" "the zoomed window's layout"
b="$(grep -l '^launch ' "$PD"/*.pane)"
assert_eq "$(roost_shape_get "$b" launch)" "FOO_TOKEN=… sh" "the launch line"

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
