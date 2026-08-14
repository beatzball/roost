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
