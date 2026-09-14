#!/usr/bin/env bash
# The release bookkeeping lives in scripts/roost-release-gate rather than
# inline in .github/workflows/ci.yml for one reason: a workflow step cannot be
# tested, and this project does not ship logic nobody has watched fail.
. "$(dirname "$0")/lib.sh"

GATE="$(cd -P "$(dirname "$0")/.." && pwd)/scripts/roost-release-gate"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A throwaway project: a VERSION and a CHANGELOG, nothing else.
mk() { # mk DIR VERSION CHANGELOG_BODY
  mkdir -p "$1"; printf '%s\n' "$2" > "$1/VERSION"; printf '%s\n' "$3" > "$1/CHANGELOG.md"
}

# --- the happy path ----------------------------------------------------------
mk "$TMP/ok" "1.2.3" '# Changelog

## [1.2.3]

- did a thing

## [1.2.2]

- did an older thing'

out="$("$GATE" check "$TMP/ok" 2>&1)"; rc=$?
assert_eq "$rc" "0" "check passes when VERSION has a matching section"
assert_contains "$out" "1.2.3" "...and says which version it matched"

notes="$("$GATE" notes "$TMP/ok")"
assert_contains "$notes" "did a thing" "notes carry this version's body"
case "$notes" in *"older thing"*) leaked=yes ;; *) leaked=no ;; esac
assert_eq "$leaked" "no" "notes stop at the next ## heading"
case "$notes" in *"## [1.2.3]"*) repeated=yes ;; *) repeated=no ;; esac
assert_eq "$repeated" "no" "notes drop the heading itself"

# --- the failure this exists to catch ---------------------------------------
mk "$TMP/missing" "9.9.9" '# Changelog

## [1.2.3]

- a section for a different version'
out="$("$GATE" check "$TMP/missing" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" "1" "check FAILS when VERSION has no section"
assert_contains "$out" "9.9.9" "...and names the version that is missing"
assert_contains "$out" "empty release" "...and says why it matters"

# --- a prefix must not count as a match -------------------------------------
# "## [0.1.0" would be found inside "## [0.1.0-rc1]" by a sloppy grep, and a
# release-candidate section is not the release's section.
mk "$TMP/prefix" "0.1.0" '# Changelog

## [0.1.0-rc1]

- a release candidate, not the release'
"$GATE" check "$TMP/prefix" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "$rc" "1" "an rc section does not satisfy the release version"

# --- a malformed VERSION is refused before anything is published ------------
for bad in "v1.2.3" "1.2" "1.2.3.4" "1.2.x" "" "latest"; do
  mk "$TMP/bad" "$bad" '# Changelog

## [1.2.3]

- x'
  "$GATE" check "$TMP/bad" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "$rc" "1" "VERSION '$bad' is refused as not X.Y.Z"
done

# --- an empty section is refused rather than published as a blank release ----
mk "$TMP/blank" "2.0.0" '# Changelog

## [2.0.0]

## [1.9.9]

- the previous one'
"$GATE" notes "$TMP/blank" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "$rc" "1" "an empty section is refused, not published as a blank release"

# --- the last section in the file still extracts -----------------------------
mk "$TMP/last" "0.1.0" '# Changelog

## [0.1.0]

- the only section, with no heading after it'
notes="$("$GATE" notes "$TMP/last")"
assert_contains "$notes" "only section" "the final section extracts with no following heading"

# --- the real repository, as shipped ----------------------------------------
# Guarded on both files existing. A checkout that predates VERSION is a valid
# state -- it is what main looked like before versioning started -- and this
# test must not fail on it. Caught by running this file on such a checkout.
ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT/VERSION" ] && [ -f "$ROOT/CHANGELOG.md" ]; then
  "$GATE" check "$ROOT" >/dev/null && rc=0 || rc=$?
  assert_eq "$rc" "0" "this repository's own VERSION and CHANGELOG agree"
else
  assert_eq "pre-version" "pre-version" "no VERSION yet in this checkout — nothing to cross-check"
fi

roost_test_teardown 2>/dev/null || true
