#!/usr/bin/env bash
# The notes at the top of a save (#234, option A): every save starts with a
# few `#` lines a person can read cold — what the fleet is, one line per
# session, when and why it was saved, and the `restore --dry-run --from` line
# that shows the whole tree — and then the `roost-shape 1` file, unchanged.
#
# Three things are pinned here, on a real server and a real `roost save`:
#   - what the notes say, and that they say nothing the file does not already
#     hold (no directory, no host);
#   - the saver's "nothing changed" test ignores them: they carry the stamp
#     and the triggers, so a test that compared them would make every save a
#     new gen;
#   - restore, --list, --from STAMP-GEN and a real restore read a save with
#     notes exactly as they read the same save without them (an old save).
# The unit half (the checker, the parser, the header reader, the kept
# fixtures) is tests/test-shape.sh's; doctor's, persist status's and the
# offer's are in their own files.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh

shape_test_setup; trap shape_test_teardown EXIT
# `roost restore` of a stopped server starts it the roost way, which writes
# wiring under XDG_CONFIG_HOME: a temp dir here, not the canary.
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
mkdir -p "$XDG_CONFIG_HOME/roost"
printf '%s\n' "set -g default-command 'exec /bin/sh'" > "$XDG_CONFIG_HOME/roost/roost.conf"
unset TMUX TMUX_PANE
ROOST="$PWD/bin/roost"
R() { env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"
. scripts/lib/roost-shape.sh
gen_of() { cat "$SD/gen" 2>/dev/null || printf -- '-'; }
nhist() { ls "$SD/history" 2>/dev/null | wc -l | tr -d ' '; }
notes() { grep '^#' "$1"; }
sessions() { TL list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }
# stop_server — the server gone, its PROCESS too, bounded by the clock (10 s):
# restore refuses while the pid in the save's boot line still runs with its
# socket gone (bin/roost's server_lost_socket), and in the Ubuntu container
# as a normal user that process outlived its socket long enough to hit it.
stop_server() {
  local pid end
  pid="$(TL display -p '#{pid}' 2>/dev/null || true)"
  TL kill-server 2>/dev/null
  end=$((SECONDS + 10))
  while { TL ls >/dev/null 2>&1 || { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }; } && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done
}

U1=3fa3c0de-7474-4abc-8def-000000000001
D1="$SHAPE_TMP/w/one"; mkdir -p "$D1"
stub_store_add "$U1" "$D1"

# The fleet: `main` with a window a person named and a keyed, named Claude
# pane; `work` with one plain shell. The server has no roost.conf (-f
# /dev/null), so no hook saves behind the cases' backs.
TL new-session -d -s main -x 200 -y 50 -c "$D1" 'ENV= exec /bin/sh'
TL kill-session -t '=shp:'
TL rename-window -t '=main:' editor
p="$(TL new-window -d -P -F '#{pane_id}' -t '=main:' -c "$D1" "$STUB_WRAP/claude")"
TL set -p -t "$p" @roost-harness claude \; set -p -t "$p" @roost-session "$U1" \; set -p -t "$p" @roost-name promo
TL new-session -d -s work -c "$D1" 'ENV= exec /bin/sh'
got=""; end=$((SECONDS + 20))
while [ "$SECONDS" -lt "$end" ]; do
  got="$(TL display -p -t "$p" '#{pane_current_command}')"; [ "$got" = claude ] && break; sleep 0.1
done
assert_eq "$got" "claude" "(fixture) the keyed pane runs the claude stub"

echo "== what the notes say (#234) =="
R save >/dev/null 2>&1; rc=$?
F="$SD/shape"
assert_eq "$rc|$(gen_of)" "0|1" "roost save publishes the first save"
n="$(notes "$F")"
assert_eq "$(head -1 "$F")" "# A saved roost fleet: server roost, saved $(roost_shape_hdr "$F" saved), because of: save" \
  "line 1: which server, when it was saved (the header's own stamp) and why"
assert_eq "$(sed -n 2p "$F")" "# 2 sessions, 3 windows, 3 panes, 1 agent" "line 2: the counts"
assert_contains "$n" '#   main: 2 windows ("editor", ' "a line for main: its windows, by the name a person gave"
assert_contains "$n" '2 panes; agent: claude "promo"' "...its panes, and its agent by harness and name"
assert_contains "$n" "#   work: 1 window (" "a line for work"
assert_contains "$n" "1 pane; no agents" "...which has no agent"
assert_contains "$n" "# run \`roost restore --dry-run --from <this file>\` to see the full tree" "the line that shows the whole tree"
assert_eq "$(notes "$F" | wc -l | tr -d ' ')" "6" "six note lines for two sessions"
assert_eq "$(grep -v '^#' "$F" | head -1)" "roost-shape 1" "the first line after them is roost-shape 1"
assert_eq "$(sed -n 7p "$F")" "roost-shape 1" "...with no blank line between (every header reader stops at the first one)"
# Nothing the file does not already hold: no directory (no `/` at all), no
# home, no host, no id.
assert_eq "$(notes "$F" | grep -c '/')" "0" "the notes hold no path"
assert_not_contains "$n" "$U1" "...no session id"
h="$(uname -n)"
if [ "${#h}" -ge 4 ]; then assert_not_contains "$n" "$h" "...and not the host name"
else printf '  SKIP: the host name check (the name [%s] is too short to tell apart)\n' "$h"; fi
assert_eq "$(ls -l "$F" | cut -c1-10)" "-rw-------" "the save is still 0600"
assert_eq "$(ls -A "$SD" | grep -c '^\.shape\.')" "0" "...and written atomically: no temp file left"

echo "== the notes never make a save worth writing (the saver's 'nothing changed' test) =="
g="$(gen_of)"; hn="$(nhist)"
R save >/dev/null 2>&1
assert_eq "$(gen_of)|$(nhist)" "$g|$hn" "the same fleet saved again: no new gen, no history file"
ROOST_TEST_NOW=1900000000 R save --trigger after-new-window >/dev/null 2>&1
assert_eq "$(gen_of)|$(nhist)" "$g|$hn" "...nor at another time with another trigger (both are in the notes)"
R save --auto --trigger after-select-layout
assert_eq "$(gen_of)|$(nhist)" "$g|$hn" "...nor through the hooks' saver (save --auto)"
# The control: the same check does see a change.
TL rename-window -t '=work:' build
R save --auto --trigger after-rename-window
assert_eq "$(gen_of)|$(nhist)" "$((g + 1))|$((hn + 1))" "(the control) a renamed window is a new gen"
assert_contains "$(notes "$F")" '#   work: 1 window ("build"), 1 pane; no agents' "...and the notes say the new name"
assert_contains "$(head -1 "$F")" "because of: after-rename-window" "...and the new cause"
assert_eq "$(head -c 1 "$SD/history/$(ls "$SD/history" | head -1)")" "#" "the history file (the save before) kept its own notes"

echo "== restore reads a save with notes as it reads one without =="
# Stopped, so --dry-run shows every pane (a running session is skipped).
stop_server
NEW="$SHAPE_TMP/new.shape"; OLD="$SHAPE_TMP/old.shape"
cp "$F" "$NEW"; grep -v '^#' "$F" > "$OLD"
same() { sed "s|$NEW|FILE|g;s|$OLD|FILE|g"; }
# One clock for both runs (ROOST_TEST_NOW, the plan's seam): the tree's first
# line says how long ago the save was made, and a second can pass between.
NOW="$(date +%s)"
a="$(ROOST_TEST_NOW="$NOW" R restore --dry-run --from "$NEW" 2>&1 | same)"
b="$(ROOST_TEST_NOW="$NOW" R restore --dry-run --from "$OLD" 2>&1 | same)"
assert_eq "$a" "$b" "restore --dry-run --from: the same tree with notes and without"
assert_contains "$a" "promo" "...and it is the fleet's tree (the control)"
# --list: shape and history/ with notes, then the same files without.
la="$(ROOST_TEST_NOW="$NOW" R restore --list 2>&1)"
assert_contains "$la" "sessions: main, work" "--list names the sessions of a save with notes"
for f in "$SD/shape" "$SD"/history/*; do
  grep -v '^#' "$f" > "$f.x"; chmod 600 "$f.x"; mv -f "$f.x" "$f"
done
assert_eq "$(cat "$SD/shape" "$SD"/history/* | grep -c '^#')" "0" "(the control) the files below have no notes"
lb="$(ROOST_TEST_NOW="$NOW" R restore --list 2>&1)"
assert_eq "$la" "$lb" "--list: the same listing with notes and without"
# A person's own note at the top of a block, in a copy they edit: the block
# is still read (--list's paragraph reader drops note lines first).
cp -p "$NEW" "$SD/shape"
sed -i.b 's/^session work$/# my note: the build box\
session work/' "$SD/shape"; rm -f "$SD/shape.b"
assert_eq "$(grep -B1 '^session work$' "$SD/shape" | head -1)" "# my note: the build box" "(the control) the note sits right above session work"
# shape is listed first, so its sessions are the first `sessions:` line.
assert_eq "$(ROOST_TEST_NOW="$NOW" R restore --list 2>&1 | grep -m1 '^    sessions: ')" "    sessions: main, work" "--list: a note at the top of a block hides nothing"
cp -p "$NEW" "$SD/shape"
# --from STAMP-GEN finds a history file with notes, and the reading rule reads
# its header.
hf="$(ls "$SD/history" | head -1)"
cp "$NEW" "$SHAPE_TMP/h.tmp"; sed -i.b 's/^gen .*/gen 1/;s/^saved .*/saved 2026-11-01T10:00:00Z/' "$SHAPE_TMP/h.tmp"
rm -f "$SD/history/$hf"; cp "$SHAPE_TMP/h.tmp" "$SD/history/20261101T100000Z-1"; chmod 600 "$SD/history/20261101T100000Z-1"
out="$(R restore --dry-run --from 20261101T100000Z-1 2>&1)"
assert_contains "$out" "from 20261101T100000Z-1" "--from STAMP-GEN finds a history file that has notes"
assert_contains "$out" "promo" "...and reads its tree"

echo "== a real restore of each: the same fleet =="
WS='#{session_name}:#{window_index} #{?#{==:#{automatic-rename},1},auto,#{window_name}} #{window_panes}'
for v in NEW OLD; do
  stop_server
  eval "file=\$$v"
  R restore --no-resume --from "$file" >/dev/null 2>"$SHAPE_TMP/err.$v"; rc=$?
  eval "rc_$v=$rc"
  eval "fleet_$v=\"\$(TL list-windows -a -F '$WS' 2>/dev/null | sort | tr '\n' ',')\""
done
assert_eq "$rc_NEW|$rc_OLD" "0|0" "restore --from each file exits 0"
assert_eq "$fleet_NEW" "$fleet_OLD" "...and builds the same sessions, windows and panes"
assert_contains "$fleet_NEW" "work:" "...the saved fleet ($fleet_NEW)"
stop_server

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
