#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# tests/run.sh must fail loudly when a test file dies mid-run (syntax error,
# an unexpected abort, a killed server) instead of silently under-counting:
# such a file contributes fewer PASS lines and no FAIL lines, so the naive
# grep-count summary alone can't tell "quiet success" from "died early".
# Exercise this against an isolated COPY of run.sh with fixture test files,
# so the crashing fixture is never picked up by a normal `bash tests/run.sh`
# run (which globs tests/test-*.sh in this directory).
# The copy honours SHARD=k/n (#169) and would shard these fixtures too,
# skipping the one that is meant to die. run.sh unsets it before it starts a
# file, so this only matters when the file is run by hand from a shell that
# exported it — and then it would fail for a reason nothing here names.
unset SHARD
fixdir="$(mktemp -d /tmp/amx.XXXX)"
trap 'rm -rf "$fixdir"' EXIT
cp "$HERE/tests/run.sh" "$fixdir/run.sh"
cp "$HERE/tests/lib.sh" "$fixdir/lib.sh"

cat > "$fixdir/test-ok.sh" <<'EOF'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
assert_eq 1 1 "sanity: this fixture passes cleanly"
EOF

# Prints one PASS (so the naive PASS/FAIL grep alone sees only success), then
# dies with a non-zero exit — the shape of a syntax error or aborted script.
cat > "$fixdir/test-crash.sh" <<'EOF'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
assert_eq 1 1 "runs one assertion before dying"
exit 7
EOF
chmod +x "$fixdir"/test-*.sh

out="$(cd "$fixdir" && bash run.sh 2>&1)"; rc=$?
assert_eq "$rc" "1" "run.sh exits non-zero when a test file dies mid-run"
assert_contains "$out" "test-crash.sh" "run.sh names the file that died"
assert_contains "$out" "PASS: sanity: this fixture passes cleanly" \
  "run.sh still reports the PASS lines a dying file printed before it died"

# Control: with no crashing file, the same runner exits 0 — proves the
# failure above is specifically about the crash, not the fixture harness.
rm -f "$fixdir/test-crash.sh"
(cd "$fixdir" && bash run.sh >/dev/null 2>&1)
assert_eq "$?" "0" "run.sh exits 0 when no test file dies"

# A direct invocation must redirect the same homes even when the parent
# supplies harness-specific overrides. All inherited paths are canaries.
canary="$fixdir/canary"
mkdir "$canary"
cat > "$fixdir/test-direct.sh" <<'EOF'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
for var in HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME COPILOT_HOME CODEX_HOME \
           PI_CODING_AGENT_DIR OPENCODE_CONFIG_DIR CLAUDE_SETTINGS CLAUDE_CONFIG_DIR; do
  case "${!var}" in "${ROOST_TEST_HOME:-missing}/"*) ;; *) echo "$var escaped"; exit 1 ;; esac
done
mkdir -p "$XDG_STATE_HOME/roost/pane-ids"
touch "$XDG_STATE_HOME/roost/pane-ids/marker"
EOF
out="$(env -u ROOST_TEST_HOME HOME="$canary" XDG_CONFIG_HOME="$canary" XDG_DATA_HOME="$canary" \
  XDG_STATE_HOME="$canary" COPILOT_HOME="$canary" CODEX_HOME="$canary" PI_CODING_AGENT_DIR="$canary" \
  OPENCODE_CONFIG_DIR="$canary" CLAUDE_SETTINGS="$canary/settings.json" CLAUDE_CONFIG_DIR="$canary" \
  bash "$fixdir/test-direct.sh" 2>&1)"; rc=$?
assert_eq "$rc|$out|$(ls -A "$canary")" '0||' "a direct test redirects every harness home and the pane ID ledger"

mkdir "$fixdir/tests"
cp "$fixdir/lib.sh" "$fixdir/tests/"
cat >"$fixdir/tests/test-relative.sh" <<'EOF'
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
[ -n "${ROOST_TEST_HOME:-}" ] && printf 'isolated\n'
EOF
out="$(cd "$fixdir/tests" && env -u ROOST_TEST_HOME bash test-relative.sh 2>&1)"; rc=$?
assert_eq "$rc|$out" '0|isolated' 'a test invoked from tests/ can cd before loading the isolation wrapper'
