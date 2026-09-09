#!/usr/bin/env bash
# tests/test-ext.sh — the extension seam. Every later task in this feature
# adds to this ONE file rather than a file of its own: the whole feature must
# revert as one clean pull request, and a scattering of test-ext-*.sh files
# would defeat that the first time someone reverted only some of them.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
TMP="$(mktemp -d)"
trap 'roost_test_teardown; rm -rf "$TMP"' EXIT

# --- the sandbox canary -----------------------------------------------------
# Copied in shape from tests/test-install.sh, which grew this after a test
# about a PATH line rewrote the developer's live agent config: one idiom for
# "a test must never touch the real user's homes," not a new one per file.
# AGENTS.md §8 names the full set that gets forgotten -- ZDOTDIR, the XDG
# pair, and the four harness homes (COPILOT_HOME, PI_CODING_AGENT_DIR,
# CODEX_HOME, CLAUDE_SETTINGS) -- and calls out that any of them left
# exported in the runner's own environment passes straight through a
# sandboxed HOME. Task 3 makes this concrete rather than defensive: the
# dispatcher execs extension binaries with an inherited environment, so this
# file has to be right about the whole set before that lands, not patched
# after it does.
#
# HOME is canaried here, unlike test-install.sh's copy: everything this file
# exercises today (--version) only READS, so nothing legitimately needs to
# write under $HOME, and pinning it turns a forgotten override into an empty
# directory under $TMP rather than the developer's real one. tests/test-doctor.sh
# made the same call for the same reason — see its header for the longer
# version of this argument.
#
# XDG_STATE_HOME is new to this pattern: no other test file canaries it,
# because no other file has anything under it to protect. This feature does —
# ext.lock, ext.index and every extension's data live there starting with a
# later task — so it is pinned from task 1 onward, before anything writes to
# it, rather than added the day something does.
CANARY="$TMP/canary"
export HOME="$CANARY/home"
export ZDOTDIR="$CANARY/zdot"
export XDG_CONFIG_HOME="$CANARY/xdg-config"
export XDG_DATA_HOME="$CANARY/xdg-data"
export XDG_STATE_HOME="$CANARY/xdg-state"
export COPILOT_HOME="$CANARY/copilot"
export PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export CODEX_HOME="$CANARY/codex"
export CLAUDE_SETTINGS="$CANARY/claude/settings.json"

# What escaped, if anything. -mindepth 1 so the directory itself is never the
# finding, and the whole listing is printed on failure rather than a count —
# which path leaked names the variable that was missed.
canary_leaks() { find "$CANARY" -mindepth 1 2>/dev/null | sort; }

# --- roost --version / -V / version -----------------------------------------

version_file="$(cat "$HERE/VERSION" 2>/dev/null)"

out="$("$ROOST" --version 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "roost --version exits 0"
assert_eq "$out" "$version_file" "roost --version prints VERSION's exact contents"
assert_eq "$(cat "$TMP/err")" "" "roost --version writes nothing to stderr"

# grep -E, not a case-pattern glob: a shell glob has no anchors of its own to
# reject trailing junk or extra dot-groups, so the check would end up
# re-implementing what -E already does correctly.
printf '%s' "$version_file" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
assert_true "$?" "VERSION matches ^[0-9]+\\.[0-9]+\\.[0-9]+\$"

# Grepped rather than invoked: contract 1 has no subcommand of its own to
# report it through yet, that arrives with the seam itself in a later task.
# Without this, nothing fails if the line is deleted, and tasks 3 onward
# version-gate their whole feature on it being there.
grep -q '^ROOST_CONTRACT=1$' "$HERE/bin/roost"
assert_true "$?" "bin/roost pins ROOST_CONTRACT=1"

out_flag="$("$ROOST" -V 2>"$TMP/err")"
assert_eq "$out_flag" "$out" "roost -V matches roost --version"
assert_eq "$(cat "$TMP/err")" "" "roost -V writes nothing to stderr"

out_word="$("$ROOST" version 2>"$TMP/err")"
assert_eq "$out_word" "$out" "roost version matches roost --version"
assert_eq "$(cat "$TMP/err")" "" "roost version writes nothing to stderr"

# --- the extension helper library -------------------------------------------
# Sourced, not executed, the way bin/roost and scripts/roost-install take it.
# From $HERE rather than from an inherited $ROOST_HOME: a suite run from
# inside a live roost session inherits that variable pointing at the PRIMARY
# checkout (scripts/lib/roost-adapters.sh's header spells out why), and would
# then assert against a different copy of the file than the one under test.
. "$HERE/scripts/lib/roost-ext.sh"

declare -f roost_ext_index_lookup >/dev/null 2>&1
assert_true "$?" "roost-ext.sh sources and defines its functions"

# XDG_STATE_HOME and XDG_DATA_HOME are pinned at the canary above, and some of
# what follows WRITES (ext.index, a lockfile) -- so they are pointed at a
# writable sandbox for those stretches and put back afterwards. Two named
# functions rather than a `VAR=value roost_ext_thing` prefix per call: the
# sandbox has to hold across a whole run of assertions, most of which reach
# the helpers through `$(...)`, and a pair of calls makes where it starts and
# where it ends something you can see rather than something you have to
# count.
ext_sandbox_on()  { export XDG_STATE_HOME="$TMP/xdg/state" XDG_DATA_HOME="$TMP/xdg/data"; }
ext_sandbox_off() { export XDG_STATE_HOME="$CANARY/xdg-state" XDG_DATA_HOME="$CANARY/xdg-data"; }

# --- path resolvers ---------------------------------------------------------
# These only COMPUTE paths -- they never create a directory -- which is why it
# is safe to ask them what the canary paths would be without anything landing
# there.
assert_eq "$(roost_ext_data_dir)"  "$CANARY/xdg-data/roost/ext" \
  "data_dir honours XDG_DATA_HOME"
assert_eq "$(roost_ext_state_dir)" "$CANARY/xdg-state/roost/ext" \
  "state_dir honours XDG_STATE_HOME"
assert_eq "$(roost_ext_lock)"      "$CANARY/xdg-state/roost/ext.lock" \
  "lock honours XDG_STATE_HOME"
assert_eq "$(roost_ext_index)"     "$CANARY/xdg-state/roost/ext.index" \
  "index honours XDG_STATE_HOME"

# The lockfile and the index sit beside the ext/ directory, not inside it:
# ext/<name>/ is per-extension and a file named ext.lock could not live in a
# directory named ext without colliding with an extension called "lock".
assert_eq "$(dirname "$(roost_ext_lock)")" "$(dirname "$(roost_ext_state_dir)")" \
  "ext.lock sits beside the ext/ state directory, not inside it"

unset XDG_DATA_HOME XDG_STATE_HOME
assert_eq "$(roost_ext_data_dir)"  "$HOME/.local/share/roost/ext" \
  "data_dir falls back to ~/.local/share when XDG_DATA_HOME is unset"
assert_eq "$(roost_ext_state_dir)" "$HOME/.local/state/roost/ext" \
  "state_dir falls back to ~/.local/state when XDG_STATE_HOME is unset"
assert_eq "$(roost_ext_lock)"      "$HOME/.local/state/roost/ext.lock" \
  "lock falls back to ~/.local/state when XDG_STATE_HOME is unset"
assert_eq "$(roost_ext_index)"     "$HOME/.local/state/roost/ext.index" \
  "index falls back to ~/.local/state when XDG_STATE_HOME is unset"

# Set-but-EMPTY is the case that separates ${X:-default} from ${X-default},
# and it is not hypothetical: `export XDG_STATE_HOME=` in a shell profile, or
# a launcher that exports every variable it knows about whether or not it has
# a value, both produce it. The default has to win there too, or roost writes
# ext.lock to "/roost/ext.lock" at the filesystem root.
export XDG_STATE_HOME="" XDG_DATA_HOME=""
assert_eq "$(roost_ext_state_dir)" "$HOME/.local/state/roost/ext" \
  "an empty XDG_STATE_HOME falls back to the default, not to /roost"
assert_eq "$(roost_ext_data_dir)"  "$HOME/.local/share/roost/ext" \
  "an empty XDG_DATA_HOME falls back to the default, not to /roost"
ext_sandbox_off

# --- roost_ext_name_valid ---------------------------------------------------
for n in mark m ma-rk mark2 a-b-c-d; do
  roost_ext_name_valid "$n"
  assert_true "$?" "name_valid accepts [$n]"
done
# 32 is the documented maximum, so both sides of it are pinned: a limit tested
# only from the inside passes just as happily when it is off by one.
n32="$(printf 'a%.0s' $(seq 1 32))"
roost_ext_name_valid "$n32"
assert_true "$?" "name_valid accepts a 32-character name"
for n in "" Mark 2mark mark_x "mark ext" -mark mark/ext "mark." "${n32}a"; do
  roost_ext_name_valid "$n"
  assert_eq "$?" "1" "name_valid refuses [$n]"
done

# --- roost_ext_repo_valid ---------------------------------------------------
# A security control, not a tidiness check: SPEC reaches a git command line
# after this, where ../.. escapes the clone base, a URL form smuggles
# credentials, and a leading dash arrives as a flag.
for r in beatzball/roost-mark a/b A.B_c-1/d.e_f-2; do
  roost_ext_repo_valid "$r"
  assert_true "$?" "repo_valid accepts [$r]"
done
for r in "../.." -x/y x/-y https://host/o/r "o r/repo" "" o/ /r o/r/x "o/r;id" 'o/$(id)' ".." "./x"; do
  roost_ext_repo_valid "$r"
  assert_eq "$?" "1" "repo_valid refuses [$r]"
done

# --- roost_ext_needs_valid --------------------------------------------------
for c in "" fleet "fleet fleet" fleet,fleet; do
  roost_ext_needs_valid "$c"
  assert_true "$?" "needs_valid accepts [$c]"
done
roost_ext_needs_valid sudo
assert_eq "$?" "1" "needs_valid refuses an unknown authority"
assert_eq "$ROOST_EXT_NEEDS_UNKNOWN" "sudo" \
  "needs_valid names the unknown authority so the caller can quote it"
roost_ext_needs_valid "fleet sudo"
assert_eq "$?" "1" "needs_valid refuses an unknown authority beside a known one"
roost_ext_needs_valid fleet
assert_eq "$ROOST_EXT_NEEDS_UNKNOWN" "" \
  "needs_valid clears the unknown-authority name on success"
# A NEWLINE between two values, in BOTH orders. This is not decoration: the
# first spelling passed while `sudo` was silently ignored, and the second
# refused correctly -- so testing either one alone reads as working. Reachable
# from task 3 onward, which takes `needs` from ext.lock, and nothing validates
# ext.lock.
roost_ext_needs_valid "$(printf 'fleet\nsudo')"
assert_eq "$?" "1" "needs_valid refuses an unknown authority AFTER a newline"
assert_eq "$ROOST_EXT_NEEDS_UNKNOWN" "sudo" \
  "needs_valid names the unknown authority that followed a newline"
roost_ext_needs_valid "$(printf 'sudo\nfleet')"
assert_eq "$?" "1" "needs_valid refuses an unknown authority BEFORE a newline"
roost_ext_needs_valid "$(printf 'fleet\nfleet')"
assert_true "$?" "needs_valid accepts known authorities either side of a newline"
# A glob character must be reported as itself. Splitting an unquoted expansion
# also globs, so without `set -f` this names whatever files happen to sit in
# the working directory instead.
roost_ext_needs_valid '*'
assert_eq "$?" "1" "needs_valid refuses a glob character"
assert_eq "$ROOST_EXT_NEEDS_UNKNOWN" '*' \
  "needs_valid names the glob itself, not a filename from the caller's directory"
# ...and puts globbing back the way it found it, because `set -f` is a
# SHELL-WIDE option and leaking it would quietly break every unquoted pattern
# in the caller.
case "$-" in *f*) globbing_off=1 ;; *) globbing_off=0 ;; esac
assert_eq "$globbing_off" "0" "needs_valid leaves globbing enabled as it found it"

# --- roost_ext_semver_in_range ----------------------------------------------
roost_ext_semver_in_range 0.1.0 ">=0.1.0 <0.2.0"; assert_eq "$?" "0" "semver: the lower bound is inclusive"
roost_ext_semver_in_range 0.1.9 ">=0.1.0 <0.2.0"; assert_eq "$?" "0" "semver: inside the range"
roost_ext_semver_in_range 0.2.0 ">=0.1.0 <0.2.0"; assert_eq "$?" "1" "semver: the upper bound is exclusive"
roost_ext_semver_in_range 0.0.9 ">=0.1.0 <0.2.0"; assert_eq "$?" "1" "semver: below the lower bound"
# 10 vs 9 has to compare as numbers, not as text: string ordering puts "0.10.0"
# below "0.9.0" and would silently declare a supported roost unsupported.
roost_ext_semver_in_range 0.10.0 ">=0.9.0 <1.0.0"; assert_eq "$?" "0" "semver: components compare numerically, not as strings"
roost_ext_semver_in_range 1.0.0 "*"; assert_eq "$?" "0" "semver: * is always in range"
roost_ext_semver_in_range 1.0.0 "";  assert_eq "$?" "0" "semver: an absent range is always in range"
roost_ext_semver_in_range 1.0.0 "^1.0.0"; assert_eq "$?" "2" "semver: a caret range is unparsable, not a refusal"
roost_ext_semver_in_range 1.0.0 ">=1.0"; assert_eq "$?" "2" "semver: a two-component bound is unparsable"
roost_ext_semver_in_range 1.0.0 ">=1.0.0"; assert_eq "$?" "2" "semver: a range with no upper bound is unparsable"
roost_ext_semver_in_range 1.0.0-rc1 ">=1.0.0 <2.0.0"; assert_eq "$?" "2" "semver: a prerelease VERSION is unparsable rather than guessed at"
roost_ext_semver_in_range "" ">=1.0.0 <2.0.0"; assert_eq "$?" "2" "semver: an empty VERSION is unparsable"

# --- roost_ext_core_commands ------------------------------------------------
# The drift test. This list is what stops an extension claiming `send`, and
# nothing else would notice it going stale: bin/roost gaining a subcommand is
# a one-line change in a file nobody thinks of as this list's source.
core_labels_from_bin_roost() {
  # The top-level subcommand case only. Its labels are the only lines indented
  # exactly two spaces inside it -- every nested case in bin/roost is indented
  # further -- and its `esac` is the only one at column 0.
  awk '
    $0 == "case \"${1:-up}\" in" { inside = 1; next }
    inside && /^esac/           { exit }
    inside && /^  [^ ]/ {
      label = $0
      sub(/^  /, "", label)
      sub(/\).*$/, "", label)
      n = split(label, alts, "|")
      for (i = 1; i <= n; i++) {
        gsub(/"/, "", alts[i])
        # `*` is the extension fallback itself and `""` is the no-argument
        # default; neither is a subcommand anyone could claim.
        if (alts[i] != "*" && alts[i] != "") print alts[i]
      }
    }
  ' "$HERE/bin/roost"
}
src_cmds="$(core_labels_from_bin_roost | LC_ALL=C sort)"
lib_cmds="$(roost_ext_core_commands | LC_ALL=C sort)"
# Asked to find something before it is trusted to find everything: two empty
# lists compare equal, so an extractor aimed at the wrong file would make this
# whole test pass while proving nothing.
assert_contains "$src_cmds" "send" "the case-label extractor finds bin/roost's own subcommands"
[ "$(printf '%s\n' "$src_cmds" | wc -l)" -ge 20 ]
assert_true "$?" "the case-label extractor finds the whole list, not one line of it"
assert_eq "$lib_cmds" "$src_cmds" \
  "roost_ext_core_commands agrees with bin/roost's own case labels"

# --- roost_ext_manifest_read ------------------------------------------------
MAN="$TMP/manifests"; mkdir -p "$MAN"
cat > "$MAN/good.json" <<'JSON'
{
  "name": "mark",
  "contract": 1,
  "roost": ">=0.1.0 <0.2.0",
  "needs": ["fleet"],
  "commands": ["mark", "marks"],
  "description": "Bookmark a spot in an agent pane, with a note."
}
JSON
read -r -d '' want_good <<'WANT' || true
name=mark
contract=1
roost=>=0.1.0 <0.2.0
needs=fleet
commands=mark marks
description=Bookmark a spot in an agent pane, with a note.
WANT
out="$(roost_ext_manifest_read "$MAN/good.json" 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "manifest_read accepts the design's own example manifest"
assert_eq "$out" "$want_good" "manifest_read prints one KEY=VALUE line per field"
assert_eq "$(cat "$TMP/err")" "" "manifest_read is silent on a good manifest"

# Absent optional fields are printed EMPTY rather than omitted, so a caller's
# `while IFS== read` sees the same six keys every time and cannot mistake a
# missing line for a missing file.
cat > "$MAN/minimal.json" <<'JSON'
{ "name": "mark", "contract": 1, "commands": ["mark"] }
JSON
out="$(roost_ext_manifest_read "$MAN/minimal.json")"; rc=$?
assert_eq "$rc" "0" "manifest_read accepts a manifest with only the required fields"
assert_contains "$out" "needs=" "manifest_read prints an empty needs= when needs is absent"
assert_contains "$out" "roost=" "manifest_read prints an empty roost= when roost is absent"
assert_contains "$out" "description=" "manifest_read prints an empty description= when it is absent"
# The empty needs line has to mean "no authority", so feed it straight back to
# the validator the installer will use rather than eyeballing the string.
needs_line="$(printf '%s\n' "$out" | sed -n 's/^needs=//p')"
roost_ext_needs_valid "$needs_line"
assert_true "$?" "an absent needs field reads back as no authority at all"

cat > "$MAN/no-contract.json" <<'JSON'
{ "name": "mark", "commands": ["mark"] }
JSON
out="$(roost_ext_manifest_read "$MAN/no-contract.json" 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "manifest_read refuses a manifest with no contract field"
assert_contains "$(cat "$TMP/err")" "contract" "manifest_read names the missing field"
assert_eq "$out" "" "manifest_read prints nothing when it refuses"

printf '{ "name": "mark", "contract": 1, ' > "$MAN/broken.json"
out="$(roost_ext_manifest_read "$MAN/broken.json" 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "manifest_read refuses malformed JSON"
[ -s "$TMP/err" ]
assert_true "$?" "manifest_read says something on stderr about malformed JSON"

# A bad name is not manifest_read's refusal to make -- it reads what is there
# and roost_ext_name_valid judges it -- but the pair has to refuse together,
# because that pair is what the installer runs.
cat > "$MAN/bad-name.json" <<'JSON'
{ "name": "Mark Two", "contract": 1, "commands": ["mark"] }
JSON
out="$(roost_ext_manifest_read "$MAN/bad-name.json")"; rc=$?
assert_eq "$rc" "0" "manifest_read reads a manifest whose name is invalid"
bad_name="$(printf '%s\n' "$out" | sed -n 's/^name=//p')"
roost_ext_name_valid "$bad_name"
assert_eq "$?" "1" "the name from a bad manifest is refused by name_valid"

# A value carrying a newline would turn one KEY=VALUE line into two, and the
# caller's `while read` would take the tail of a description as a key.
printf '{ "name": "mark", "contract": 1, "commands": ["mark"], "description": "one\\ntwo" }\n' > "$MAN/newline.json"
out="$(roost_ext_manifest_read "$MAN/newline.json" 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "manifest_read refuses a field value containing a newline"
assert_contains "$(cat "$TMP/err")" "description" "manifest_read names the field that carried the newline"

# The degraded contract, matching roost_json_merge's: no python3 and no jq is
# a 3, not a crash and not a silent empty read. A directory of nothing on
# PATH, never a shim with a real binary symlinked into it -- `>` follows a
# symlink, and that has destroyed real binaries on this machine.
mkdir -p "$TMP/no-tools"
saved_path="$PATH"
PATH="$TMP/no-tools"
roost_ext_manifest_read "$MAN/good.json" >/dev/null 2>&1; rc=$?
PATH="$saved_path"
assert_eq "$rc" "3" "manifest_read returns 3 when neither python3 nor jq is present"

# Both engines have to answer the same, or a machine with only jq installs
# extensions by different rules than one with python3. Skipped rather than
# failed where jq is absent: it is not a roost dependency.
if command -v jq >/dev/null 2>&1; then
  # A PATH holding jq and nothing else roost could mistake for python3. Each
  # entry is a stub that EXECS the real binary by absolute path -- never a
  # symlink, because `>` follows one and overwriting a shim entry has
  # destroyed real binaries on this machine.
  #
  # `cat` is in there because this models a machine WITHOUT PYTHON3, not one
  # without coreutils: the engine scripts are heredocs through cat, exactly as
  # scripts/lib/roost-json.sh's are. The standing decision this file protects
  # is about python3 and jq, and only roost_ext_index_lookup promises to run
  # with nothing at all -- which it is asked to do separately below.
  mkdir -p "$TMP/jq-only"
  for c in jq cat; do
    printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$c")" > "$TMP/jq-only/$c"
    chmod +x "$TMP/jq-only/$c"
  done
  PATH="$TMP/jq-only"
  jq_good="$(roost_ext_manifest_read "$MAN/good.json" 2>/dev/null)"; jq_good_rc=$?
  roost_ext_manifest_read "$MAN/no-contract.json" >/dev/null 2>"$TMP/err-jq"; jq_bad_rc=$?
  roost_ext_manifest_read "$MAN/broken.json" >/dev/null 2>&1; jq_broken_rc=$?
  PATH="$saved_path"
  assert_eq "$jq_good_rc" "0" "the jq engine accepts the same good manifest"
  assert_eq "$jq_good" "$want_good" "the jq engine prints byte-identical output to python3's"
  assert_eq "$jq_bad_rc" "1" "the jq engine refuses the manifest with no contract field"
  assert_contains "$(cat "$TMP/err-jq")" "contract" "the jq engine names the missing field too"
  assert_eq "$jq_broken_rc" "1" "the jq engine refuses malformed JSON with a 1, not jq's own 5"

  # Past the three cases above, because "the engines agree" was asserted only
  # for a good manifest, a missing field and a broken file -- and they did NOT
  # agree on a contract of 1.5, which python3 refused and jq printed straight
  # through. A stated invariant that is false is worse than none.
  #
  # Each case is run under BOTH engines and the two answers compared to each
  # other, not to a hardcoded expectation: that is what makes this a parity
  # test rather than two copies of the same assertion drifting apart.
  parity_case() {
    # parity_case <label> <manifest-json>
    local label="$1" json="$2" p_out p_rc j_out j_rc
    printf '%s\n' "$json" > "$MAN/parity.json"
    p_out="$(roost_ext_manifest_read "$MAN/parity.json" 2>/dev/null)"; p_rc=$?
    PATH="$TMP/jq-only"
    j_out="$(roost_ext_manifest_read "$MAN/parity.json" 2>/dev/null)"; j_rc=$?
    PATH="$saved_path"
    assert_eq "$j_rc" "$p_rc" "both engines agree on the status for $label"
    assert_eq "$j_out" "$p_out" "both engines agree on the output for $label"
  }
  parity_case "a fractional contract" \
    '{ "name": "mark", "contract": 1.5, "commands": ["mark"] }'
  parity_case "a contract written in exponent form" \
    '{ "name": "mark", "contract": 1e2, "commands": ["mark"] }'
  parity_case "a contract given as a string" \
    '{ "name": "mark", "contract": "1", "commands": ["mark"] }'
  parity_case "a boolean contract" \
    '{ "name": "mark", "contract": true, "commands": ["mark"] }'
  parity_case "an empty commands array" \
    '{ "name": "mark", "contract": 1, "commands": [] }'
  parity_case "commands that is not an array" \
    '{ "name": "mark", "contract": 1, "commands": "mark" }'
  parity_case "a command with a space in it" \
    '{ "name": "mark", "contract": 1, "commands": ["mark two"] }'
  parity_case "a needs entry that is not a string" \
    '{ "name": "mark", "contract": 1, "commands": ["mark"], "needs": [1] }'
  parity_case "a description carrying a newline" \
    '{ "name": "mark", "contract": 1, "commands": ["mark"], "description": "one\\ntwo" }'
  parity_case "a top-level array" '[ "mark" ]'
  # The refusal a user actually reads has to be the same sentence too, not
  # just the same exit status.
  printf '%s\n' '{ "name": "mark", "contract": 1.5, "commands": ["mark"] }' > "$MAN/parity.json"
  roost_ext_manifest_read "$MAN/parity.json" 2>"$TMP/err-py" >/dev/null
  PATH="$TMP/jq-only"
  roost_ext_manifest_read "$MAN/parity.json" 2>"$TMP/err-jq" >/dev/null
  PATH="$saved_path"
  assert_eq "$(cat "$TMP/err-jq")" "$(cat "$TMP/err-py")" \
    "both engines refuse a fractional contract in the same words"
fi

# --- roost_ext_tree_hash ----------------------------------------------------
TREE="$TMP/tree"; mkdir -p "$TREE/bin"
printf 'hello\n' > "$TREE/a.txt"
printf '#!/bin/sh\necho hi\n' > "$TREE/bin/roost-demo"; chmod +x "$TREE/bin/roost-demo"
h1="$(roost_ext_tree_hash "$TREE")"; rc=$?
assert_eq "$rc" "0" "tree_hash succeeds on a directory"
printf '%s' "$h1" | grep -Eq '^[0-9a-f]{40}$'
assert_true "$?" "tree_hash prints a 40-character git object id"
h2="$(roost_ext_tree_hash "$TREE")"
assert_eq "$h2" "$h1" "tree_hash is the same value twice on an unchanged directory"
# The whole point of the hash: install time and verify time compute it the
# same way, so one changed byte in one file has to move it.
printf 'hellp\n' > "$TREE/a.txt"
h3="$(roost_ext_tree_hash "$TREE")"
[ "$h3" != "$h1" ]
assert_true "$?" "tree_hash changes when one byte of one file changes"
# .git is excluded, and it has to be: the clone's own .git changes on every
# fetch, and a verify that tripped over that would cry tamper at a no-op.
printf 'hello\n' > "$TREE/a.txt"
git -C "$TREE" init -q >/dev/null 2>&1
h4="$(roost_ext_tree_hash "$TREE")"
assert_eq "$h4" "$h1" "tree_hash ignores .git, so a repository and a plain copy hash alike"
# A RELATIVE directory has to give the same answer as the absolute one. It
# used to return a bare 1 -- indistinguishable from "no such directory" --
# because `git -C "$dir"` chdirs before a relative GIT_WORK_TREE is resolved.
tree_pwd="$PWD"
cd "$TMP" || exit 1
h_rel="$(roost_ext_tree_hash tree)"
cd "$tree_pwd" || exit 1
assert_eq "$h_rel" "$h1" "tree_hash accepts a relative directory and agrees with the absolute one"
roost_ext_tree_hash "$TMP/does-not-exist" >/dev/null 2>&1
assert_eq "$?" "1" "tree_hash refuses a directory that is not there"

# --- roost_ext_index_lookup -------------------------------------------------
ext_sandbox_on
mkdir -p "$TMP/xdg/state/roost" "$TMP/xdg/data/roost/ext/demo/bin"
demo_bin="$TMP/xdg/data/roost/ext/demo/bin/roost-demo"
printf '#!/bin/sh\necho demo\n' > "$demo_bin"; chmod +x "$demo_bin"
printf 'demo\tdemo\t%s\n' "$demo_bin" > "$(roost_ext_index)"
out="$(roost_ext_index_lookup demo)"; rc=$?
assert_eq "$rc" "0" "index_lookup finds an installed command"
assert_eq "$out" "$demo_bin" "index_lookup prints the executable's path"
out="$(roost_ext_index_lookup nope)"; rc=$?
assert_eq "$rc" "1" "index_lookup misses an unknown command"
assert_eq "$out" "" "index_lookup prints nothing on a miss"

# The two variables task 3's dispatcher reads. Called WITHOUT a `$(...)` here
# on purpose: that is the only way the dispatcher can call it -- a command
# substitution would put back the fork this function exists to avoid, and
# would also throw the variables away with the subshell -- so this is the
# call shape under test, not just the values.
roost_ext_index_lookup demo >/dev/null
assert_eq "$ROOST_EXT_LOOKUP_NAME" "demo" \
  "index_lookup reports the extension NAME, which the dispatcher needs for ext.lock"
assert_eq "$ROOST_EXT_LOOKUP_PATH" "$demo_bin" \
  "index_lookup reports the path in a variable as well as on stdout"
roost_ext_index_lookup nope >/dev/null
assert_eq "$ROOST_EXT_LOOKUP_NAME" "" \
  "index_lookup clears the reported name on a miss"
assert_eq "$ROOST_EXT_LOOKUP_PATH" "" \
  "index_lookup clears the reported path on a miss, so a stale hit cannot be exec'd"
# A prefix is not a match. `dem` sharing three letters with `demo` must not
# dispatch, or a typo runs somebody's extension.
roost_ext_index_lookup dem >/dev/null; assert_eq "$?" "1" "index_lookup does not match a prefix of a command"
roost_ext_index_lookup demoX >/dev/null; assert_eq "$?" "1" "index_lookup does not match an extension of a command"
# The lockfile is the record of what is installed; the clone is not. A clone
# whose files went away therefore has to degrade to "unknown subcommand"
# rather than to exec'ing whatever is at that path now.
mv "$demo_bin" "$demo_bin.moved"
roost_ext_index_lookup demo >/dev/null; assert_eq "$?" "1" "index_lookup misses when the executable is gone"
mv "$demo_bin.moved" "$demo_bin"
chmod -x "$demo_bin"
roost_ext_index_lookup demo >/dev/null; assert_eq "$?" "1" "index_lookup misses when the file is not executable"
chmod +x "$demo_bin"

# This runs on EVERY mistyped roost subcommand, and roost-json.sh opens by
# recording that neither python3 nor jq is a runtime dependency of roost.
# Parsing ext.lock here would quietly have made one of them exactly that, so
# the lookup is pinned two ways: it works with NOTHING on PATH...
PATH="$TMP/no-tools"
out="$(roost_ext_index_lookup demo)"; rc=$?
PATH="$saved_path"
assert_eq "$rc" "0" "index_lookup works with no external command on PATH at all"
assert_eq "$out" "$demo_bin" "index_lookup still finds the path with an empty PATH"
# ...and its source contains no command substitution, which is the fork that
# would otherwise creep back in the first time someone reached for a helper.
lookup_body="$(declare -f roost_ext_index_lookup)"
case "$lookup_body" in
  *'$('*|*'`'*) forks=1 ;;
  *)            forks=0 ;;
esac
assert_eq "$forks" "0" "index_lookup's body has no command substitution in it"

# --- roost_ext_index_write --------------------------------------------------
cat > "$(roost_ext_lock)" <<'JSON'
{
  "mark": { "repo": "beatzball/roost-mark", "commands": ["mark", "marks"], "needs": ["fleet"] },
  "demo": { "repo": "o/demo", "commands": ["demo"] }
}
JSON
roost_ext_index_write; rc=$?
assert_eq "$rc" "0" "index_write regenerates the index from the lockfile"
ext_data="$(roost_ext_data_dir)"
want_index="$(printf 'demo\tdemo\t%s\nmark\tmark\t%s\nmarks\tmark\t%s\n' \
  "$ext_data/demo/bin/roost-demo" "$ext_data/mark/bin/roost-mark" "$ext_data/mark/bin/roost-marks")"
assert_eq "$(cat "$(roost_ext_index)")" "$want_index" \
  "index_write writes one tab-separated line per claimed command, sorted by command"
# Written for the reader that actually consumes it, not for a diff: the two
# have to agree or the dispatch path is testing something the installer never
# produced. The clones the index points at are built first, because a lookup
# whose executable is not there is a MISS by design -- see index_lookup.
mkdir -p "$ext_data/mark/bin" "$ext_data/demo/bin"
for f in "$ext_data/mark/bin/roost-mark" "$ext_data/mark/bin/roost-marks" \
         "$ext_data/demo/bin/roost-demo"; do
  printf '#!/bin/sh\n' > "$f"; chmod +x "$f"
done
out="$(roost_ext_index_lookup marks)"
assert_eq "$out" "$ext_data/mark/bin/roost-marks" \
  "index_lookup reads back a command index_write wrote (the file's own reader)"
# Same input, same bytes -- a regeneration that reordered itself would show up
# as a spurious change every time `roost ext list` or a removal ran.
first="$(cat "$(roost_ext_index)")"
roost_ext_index_write
assert_eq "$(cat "$(roost_ext_index)")" "$first" "index_write is byte-identical on a second run"
# Atomic: a temp file then a mv, so a reader never sees a half-written index.
# What that leaves behind is the observable part -- nothing.
leftovers="$(find "$(dirname "$(roost_ext_index)")" -name '.roost-ext*' 2>/dev/null)"
assert_eq "$leftovers" "" "index_write leaves no temp file behind"

# No lockfile is not an error: it is what a machine with nothing installed
# looks like, and what removing the last extension leaves. The index has to
# become empty rather than stay stale.
rm -f "$(roost_ext_lock)"
roost_ext_index_write; rc=$?
assert_eq "$rc" "0" "index_write succeeds when there is no lockfile"
assert_eq "$(cat "$(roost_ext_index)")" "" "index_write empties the index when nothing is installed"

# A lockfile claiming one command for two extensions is an ambiguous dispatch
# table. Refused and named, rather than written in whichever order the JSON
# happened to be in.
cat > "$(roost_ext_lock)" <<'JSON'
{
  "one": { "repo": "o/one", "commands": ["clash"] },
  "two": { "repo": "o/two", "commands": ["clash"] }
}
JSON
roost_ext_index_write 2>"$TMP/err"; rc=$?
assert_eq "$rc" "1" "index_write refuses a lockfile where two extensions claim one command"
assert_contains "$(cat "$TMP/err")" "clash" "index_write names the command that is claimed twice"

printf '{ "mark": ' > "$(roost_ext_lock)"
roost_ext_index_write 2>/dev/null; rc=$?
assert_eq "$rc" "1" "index_write refuses a malformed lockfile"
rm -f "$(roost_ext_lock)"
ext_sandbox_off

# --- the dispatcher ---------------------------------------------------------
# From here on the subject is bin/roost's `*)` fallback rather than the helper
# library: what an unknown subcommand does, and what environment an extension
# that claims one is handed. The fixtures are hand-written -- an ext.index and
# an ext.lock, no installer -- because `roost ext install` does not exist yet
# and the dispatcher has to be correct before it does.
#
# Every run below pins ROOST_SOCKET at this file's OWN test server. bin/roost
# falls back to `-L roost` otherwise, which on this machine is the author's
# live server holding real agents (AGENTS.md §2); a `show-options` read would
# not disturb it, but "the test suite never addresses that socket at all" is
# the property worth having rather than the one worth arguing about.
roost_test_server

ext_sandbox_on
EXT_DATA="$TMP/xdg/data/roost/ext"
EXT_STATE_ROOT="$TMP/xdg/state/roost"
mkdir -p "$EXT_DATA/probe/bin" "$EXT_STATE_ROOT"

# The stub extension. It reports its own environment and exits 7, so every
# assertion below reads what the dispatcher actually handed it rather than
# what this file believes the dispatcher hands it -- and the 7 doubles as the
# proof that an extension's exit status reaches the user unwrapped.
#
# `${VAR-...}` and never `${VAR:-...}`: the distinction this whole stub exists
# to report is ABSENT versus PRESENT-AND-EMPTY, and only the first form tells
# those apart. An extension handed an EMPTY ROOST_SOCKET would address the
# DEFAULT tmux server -- the user's own everyday tmux, the one thing roost
# exists to leave alone -- so a test that could not see the difference would
# pass on the exact bug that matters.
#
# Shell builtins only, no `env`: this same stub is run below under a PATH with
# almost nothing on it.
cat > "$EXT_DATA/probe/bin/roost-probe" <<'SH'
#!/bin/sh
printf 'ROOST_HOME=%s\n'      "${ROOST_HOME-<unset>}"
printf 'ROOST_VERSION=%s\n'   "${ROOST_VERSION-<unset>}"
printf 'ROOST_CONTRACT=%s\n'  "${ROOST_CONTRACT-<unset>}"
printf 'ROOST_EXT_DIR=%s\n'   "${ROOST_EXT_DIR-<unset>}"
printf 'ROOST_EXT_STATE=%s\n' "${ROOST_EXT_STATE-<unset>}"
printf 'ROOST_SOCKET=%s\n'    "${ROOST_SOCKET-<unset>}"
printf 'PATH=%s\n'            "${PATH-<unset>}"
printf 'ARGS=%s\n'            "$*"
exit 7
SH
chmod +x "$EXT_DATA/probe/bin/roost-probe"

# The manifest inside the clone, claiming the fleet. Nothing below ever makes
# the lockfile agree with it: this file is here precisely so that every
# no-fleet assertion is also an assertion that the dispatcher did NOT read it.
# It is the file an attacker who reached the disk would edit, and an extension
# that could rewrite its own manifest between installs could grant itself the
# run of every agent.
cat > "$EXT_DATA/probe/roost-ext.json" <<'JSON'
{ "name": "probe", "contract": 1, "commands": ["probe"], "needs": ["fleet"] }
JSON

printf 'probe\tprobe\t%s\n' "$EXT_DATA/probe/bin/roost-probe" > "$EXT_STATE_ROOT/ext.index"

lock_no_needs() {
  cat > "$EXT_STATE_ROOT/ext.lock" <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"] }
}
JSON
}
lock_fleet() {
  cat > "$EXT_STATE_ROOT/ext.lock" <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"], "needs": ["fleet"] }
}
JSON
}

# The PATH the dispatcher runs under, built by REMOVING roost's own scripts
# directory from the ambient one rather than by assuming it is not there. A
# suite run from inside a roost pane inherits a PATH tmux has already put a
# checkout's scripts on, and "no fleet means no roost scripts on PATH" would
# then be testing the pane's environment instead of the dispatcher's grant.
EXT_PATH=":$PATH:"
EXT_PATH="${EXT_PATH//:$HERE\/scripts:/:}"
EXT_PATH="${EXT_PATH#:}"; EXT_PATH="${EXT_PATH%:}"

ext_field() { printf '%s\n' "$1" | sed -n "s|^$2=||p"; }
# Reports whether roost's own scripts directory reached the extension. A case
# glob, not a grep: the answer has to be about THIS checkout's path, and the
# ambient PATH may legitimately carry another checkout's.
ext_has_scripts() { case "$1" in *"$HERE/scripts"*) return 0 ;; esac; return 1; }

# --- an unknown subcommand is untouched by all of this ----------------------
# Captured FIRST and reused as the expected text everywhere the seam declines
# to dispatch, so "the usage error is unchanged" is one fact asserted against
# one string rather than three copies of a long line that can drift apart.
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" definitely-not-a-subcommand 2>"$TMP/err")"; rc=$?
usage_ref="$(cat "$TMP/err")"
assert_eq "$rc" "2" "an unknown subcommand still exits 2"
assert_eq "$out" "" "an unknown subcommand still prints nothing on stdout"
assert_prefix "$usage_ref" "usage: roost [up|session NAME|" \
  "an unknown subcommand still prints the usage error on stderr"
# A lookup MISS is the ordinary case -- every typo lands in the same branch --
# and bin/roost runs under `set -e`, so a lookup called as a bare statement
# would exit the shell on the miss and print nothing at all. That failure
# looks like this assertion and only like this assertion.
assert_contains "$usage_ref" "kill [SESSION]" \
  "the usage error is the whole line, not a shell that died on the failed lookup"

# --- the always-on environment ----------------------------------------------
lock_no_needs
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe %200 "a note" 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "the dispatcher execs the extension and its exit status passes through"
assert_eq "$(ext_field "$out" ROOST_HOME)" "$HERE" "the extension is handed ROOST_HOME"
assert_eq "$(ext_field "$out" ROOST_VERSION)" "$version_file" "the extension is handed ROOST_VERSION"
assert_eq "$(ext_field "$out" ROOST_CONTRACT)" "1" "the extension is handed ROOST_CONTRACT"
assert_eq "$(ext_field "$out" ROOST_EXT_DIR)" "$EXT_DATA/probe" \
  "the extension is handed its own install directory"
assert_eq "$(ext_field "$out" ROOST_EXT_STATE)" "$EXT_STATE_ROOT/ext/probe" \
  "the extension is handed its own private state directory"
# Created BEFORE the exec, so an extension's first run has somewhere to write
# without every extension author repeating the same mkdir.
[ -d "$EXT_STATE_ROOT/ext/probe" ]
assert_true "$?" "the state directory exists by the time the extension runs"
# The extension's own name is dropped: `roost probe %200` has to reach
# bin/roost-probe as `%200`, the same arguments it would have had if the user
# had run the binary directly.
assert_eq "$(ext_field "$out" ARGS)" "%200 a note" \
  "the subcommand is shifted off and the rest of the arguments passed through"

# --- no fleet unless the LOCKFILE says so -----------------------------------
# ROOST_SOCKET is exported into these runs on purpose. Withholding authority
# is not "never setting a variable", it is REMOVING one the parent had, and a
# test that ran with it already absent would pass without exercising that.
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "without fleet, ROOST_SOCKET is ABSENT from the environment, not present-and-empty"
ext_has_scripts "$(ext_field "$out" PATH)"
assert_eq "$?" "1" "without fleet, roost's own scripts are not on the extension's PATH"
# The clone's roost-ext.json says "needs": ["fleet"] and has said so all
# along. If this ever starts failing, the dispatcher has begun trusting the
# extension's own file over roost's record of what the user agreed to.
[ -f "$EXT_DATA/probe/roost-ext.json" ]
assert_true "$?" "the clone's own manifest, which claims fleet, is really there"

lock_fleet
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "an extension the lockfile grants fleet still runs"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" \
  "with fleet, ROOST_SOCKET names the server roost itself is addressing"
ext_has_scripts "$(ext_field "$out" PATH)"
assert_true "$?" "with fleet, roost's own scripts are prepended to the extension's PATH"
assert_prefix "$(ext_field "$out" PATH)" "$HERE/scripts:" \
  "with fleet, roost's scripts come FIRST on PATH, as a pane's do"

# A needs array split over several lines is the same grant. The design prints
# the lockfile pretty-printed and a hand-edit or a different writer will wrap
# it, so the reader cannot be one that only ever sees `["fleet"]` on one line.
cat > "$EXT_STATE_ROOT/ext.lock" <<'JSON'
{
  "probe": {
    "repo": "o/probe",
    "needs": [
      "fleet"
    ],
    "commands": ["probe"]
  }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" \
  "a needs array spread over several lines grants fleet just the same"

# ...and one extension's grant is not another's. Both orders, because a reader
# that stopped scoping at the entry boundary would pass whichever order it was
# tested in and fail the other -- roost_ext_needs_valid's own newline case was
# exactly that bug.
cat > "$EXT_STATE_ROOT/ext.lock" <<'JSON'
{
  "other": { "repo": "o/other", "commands": ["other"], "needs": ["fleet"] },
  "probe": { "repo": "o/probe", "commands": ["probe"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "fleet declared by an EARLIER entry does not leak to this one"
cat > "$EXT_STATE_ROOT/ext.lock" <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"] },
  "other": { "repo": "o/other", "commands": ["other"], "needs": ["fleet"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "fleet declared by a LATER entry does not leak to this one either"

# No lockfile at all is no record of consent, so it is no authority -- not a
# crash, and not a grant.
rm -f "$EXT_STATE_ROOT/ext.lock"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "an extension whose lockfile entry has gone still runs"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "a missing lockfile grants nothing rather than everything"

# An authority this roost does not know is REFUSED, not ignored. Ignoring it
# would leave the extension believing it had everything while it had nothing,
# and that surfaces as corrupted behaviour instead of a clean stop --
# roost_ext_needs_valid exists to make exactly that refusal, and the
# dispatcher has to honour it. `roost ext install` refuses such a manifest, so
# a lockfile that says this was hand-edited or written by a newer roost.
cat > "$EXT_STATE_ROOT/ext.lock" <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"], "needs": ["fleet", "sudo"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "an unknown authority in the lockfile stops the command"
assert_eq "$out" "" "an unknown authority means the extension is never exec'd at all"
assert_contains "$(cat "$TMP/err")" "sudo" "the refusal names the authority it did not know"

# --- the two kill switches --------------------------------------------------
lock_fleet
out="$(ROOST_NO_EXT=1 ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "2" "ROOST_NO_EXT=1 turns a working extension command back into the usage error"
assert_eq "$out" "" "ROOST_NO_EXT=1 means the extension does not run"
assert_eq "$(cat "$TMP/err")" "$usage_ref" \
  "ROOST_NO_EXT=1 prints the same usage error an unknown subcommand does"
# Set-but-EMPTY is not a request to turn anything off. `export ROOST_NO_EXT=`
# in a profile, or a launcher that exports every name it knows whether or not
# it has a value, would otherwise disable the seam for a user who never asked.
out="$(ROOST_NO_EXT= ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "an EMPTY ROOST_NO_EXT does not disable the seam"

T set-option -g @roost-ext-enabled off
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "2" "@roost-ext-enabled off turns a working extension command back into the usage error"
assert_eq "$out" "" "@roost-ext-enabled off means the extension does not run"
assert_eq "$(cat "$TMP/err")" "$usage_ref" \
  "@roost-ext-enabled off prints the same usage error an unknown subcommand does"
T set-option -g @roost-ext-enabled on
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "@roost-ext-enabled on dispatches again"
T set-option -gu @roost-ext-enabled
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "an unset @roost-ext-enabled leaves the seam on, which is the default"

# --- core always wins -------------------------------------------------------
# The structural property, tested through behaviour rather than by reading the
# source: an ext.index claiming `status` cannot shadow it, because the lookup
# lives ONLY in the `*)` fallback and `status` matched a branch above. An
# extension that could intercept `roost send` would sit between every message
# the user's agents exchange, so this is worth a test that fails loudly the
# day someone moves the lookup up to the top of the case.
printf 'probe\tprobe\t%s\nstatus\tprobe\t%s\n' \
  "$EXT_DATA/probe/bin/roost-probe" "$EXT_DATA/probe/bin/roost-probe" \
  > "$EXT_STATE_ROOT/ext.index"
out="$(ROOST_SOCKET="$TMP/no-such-server/s" PATH="$EXT_PATH" "$ROOST" status 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "roost status still runs core with an extension claiming the name"
assert_eq "$out" "roost: not running" "roost status prints core's own answer, not the extension's"
printf 'probe\tprobe\t%s\n' "$EXT_DATA/probe/bin/roost-probe" > "$EXT_STATE_ROOT/ext.index"

# --- an index entry whose executable is gone --------------------------------
# The lockfile is the record of what is installed; the clone is not. A clone
# whose files went away has to degrade to "unknown subcommand" rather than to
# exec'ing whatever now sits at that path.
mv "$EXT_DATA/probe/bin/roost-probe" "$EXT_DATA/probe/bin/roost-probe.moved"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "2" "an index entry pointing at a missing executable is a usage error"
assert_eq "$(cat "$TMP/err")" "$usage_ref" "...and it is the same usage error, unchanged"
mv "$EXT_DATA/probe/bin/roost-probe.moved" "$EXT_DATA/probe/bin/roost-probe"

# --- neither python3 nor jq is a runtime dependency -------------------------
# The standing decision scripts/lib/roost-json.sh opens with. Dispatching an
# extension is on the path a user hits every time they run one, and a JSON
# tool forked there to read `needs` out of ext.lock would have made one of
# them exactly that -- quietly, and only on machines that have one.
#
# A stub directory of scripts that EXEC the real binary by absolute path,
# never a symlink: `>` follows a symlink, and overwriting a shim entry has
# destroyed real binaries on this machine.
#
# `bash`, `dirname` and `mkdir` are in it because this models a machine
# WITHOUT PYTHON3 AND JQ, not one without coreutils: /usr/bin/env resolves
# bin/roost's own interpreter through PATH, bin/roost runs `dirname` while
# resolving its checkout, and the dispatcher creates ROOST_EXT_STATE.
mkdir -p "$TMP/no-json"
for c in bash dirname mkdir; do
  printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$c")" > "$TMP/no-json/$c"
  chmod +x "$TMP/no-json/$c"
done
# Checked before it is trusted: a PATH that still found python3 would make
# every assertion below pass while proving nothing at all.
PATH="$TMP/no-json" command -v python3 >/dev/null 2>&1
assert_eq "$?" "1" "the no-JSON-tool PATH really has no python3 on it"
PATH="$TMP/no-json" command -v jq >/dev/null 2>&1
assert_eq "$?" "1" "the no-JSON-tool PATH really has no jq on it"
lock_fleet
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$TMP/no-json" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "an extension runs with neither python3 nor jq on PATH"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" \
  "...and the fleet grant is read out of ext.lock without a JSON tool"
lock_no_needs
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$TMP/no-json" "$ROOST" probe 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "...and so is the refusal to grant it"

rm -f "$EXT_STATE_ROOT/ext.lock" "$EXT_STATE_ROOT/ext.index"
ext_sandbox_off

# --- nothing escaped the sandbox --------------------------------------------
# Checked before it is trusted: "found nothing" is exactly what a detector
# aimed at the wrong path also says. Make it find something first, then ask
# it about the real thing — tests/test-install.sh and tests/test-doctor.sh
# both do this for the same reason.
mkdir -p "$CANARY"; : > "$CANARY/detector-check"
assert_contains "$(canary_leaks)" "detector-check" \
  "the sandbox canary reports a file when there is one"
rm -f "$CANARY/detector-check"

assert_eq "$(canary_leaks)" "" \
  "no roost invocation in this file wrote outside its sandbox"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
