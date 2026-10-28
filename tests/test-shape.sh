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

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
