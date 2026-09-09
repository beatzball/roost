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
  #
  # `mktemp`, `mv` and `mkdir` join it for roost_ext_index_write, which is run
  # under this PATH further down: it writes its output through a temp file and
  # a rename so a reader never sees a half-written dispatch table.
  mkdir -p "$TMP/jq-only"
  for c in jq cat mktemp mv mkdir; do
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

# The three variables the dispatcher reads. Called WITHOUT a `$(...)` here
# on purpose: that is the only way the dispatcher can call it -- a command
# substitution would put back the fork this function exists to avoid, and
# would also throw the variables away with the subshell -- so this is the
# call shape under test, not just the values.
roost_ext_index_lookup demo >/dev/null
assert_eq "$ROOST_EXT_LOOKUP_NAME" "demo" \
  "index_lookup reports the extension NAME, which the dispatcher needs for its directories"
assert_eq "$ROOST_EXT_LOOKUP_PATH" "$demo_bin" \
  "index_lookup reports the path in a variable as well as on stdout"
# A line with only three columns is what an older roost wrote and what a hand
# edit leaves behind. It has to read back as NO authority -- fail closed --
# rather than as an unset variable the dispatcher would trip over under
# `set -u`.
assert_eq "$ROOST_EXT_LOOKUP_NEEDS" "" \
  "a line with no fourth column reports no authority at all"
printf 'demo\tdemo\t%s\tfleet\n' "$demo_bin" > "$(roost_ext_index)"
roost_ext_index_lookup demo >/dev/null
assert_eq "$ROOST_EXT_LOOKUP_NEEDS" "fleet" \
  "index_lookup reports the authority column, which is what the dispatcher grants from"
# Surrounding whitespace on any field. This function's own comment promises a
# hand-edited ext.index "has to survive", and it did not: one trailing space
# after the path made `[ -x "$path" ]` false and turned an installed command
# back into "unknown subcommand" with nothing printed to say why.
printf '  demo \t demo \t %s \t fleet \n' "$demo_bin" > "$(roost_ext_index)"
out="$(roost_ext_index_lookup demo)"; rc=$?
assert_eq "$rc" "0" "index_lookup still finds a line whose fields carry surrounding whitespace"
assert_eq "$out" "$demo_bin" "...and hands back the path without it"
roost_ext_index_lookup demo >/dev/null
assert_eq "$ROOST_EXT_LOOKUP_NAME" "demo" "...and the name without it"
assert_eq "$ROOST_EXT_LOOKUP_NEEDS" "fleet" "...and the authority without it"
# A path that legitimately contains a space is not the same thing and must
# survive intact -- an XDG_DATA_HOME under "Application Support" is enough.
mkdir -p "$TMP/xdg/data/roost/ext/with space/bin"
space_bin="$TMP/xdg/data/roost/ext/with space/bin/roost-spaced"
printf '#!/bin/sh\n' > "$space_bin"; chmod +x "$space_bin"
printf 'spaced\tspaced\t%s\t\n' "$space_bin" > "$(roost_ext_index)"
assert_eq "$(roost_ext_index_lookup spaced)" "$space_bin" \
  "trimming the ends does not disturb a path with a space inside it"
printf 'demo\tdemo\t%s\n' "$demo_bin" > "$(roost_ext_index)"
roost_ext_index_lookup nope >/dev/null
assert_eq "$ROOST_EXT_LOOKUP_NAME" "" \
  "index_lookup clears the reported name on a miss"
assert_eq "$ROOST_EXT_LOOKUP_PATH" "" \
  "index_lookup clears the reported path on a miss, so a stale hit cannot be exec'd"
assert_eq "$ROOST_EXT_LOOKUP_NEEDS" "" \
  "index_lookup clears the reported authority on a miss, so no grant outlives its line"
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
want_index="$(printf 'demo\tdemo\t%s\t\nmark\tmark\t%s\tfleet\nmarks\tmark\t%s\tfleet\n' \
  "$ext_data/demo/bin/roost-demo" "$ext_data/mark/bin/roost-mark" "$ext_data/mark/bin/roost-marks")"
assert_eq "$(cat "$(roost_ext_index)")" "$want_index" \
  "index_write writes one tab-separated line per claimed command, sorted by command"
# The FOURTH column is the grant, resolved here -- where a real JSON parser is
# reading ext.lock anyway -- and carried to the dispatcher rather than
# re-derived there. The dispatcher's first version re-derived it with shell
# string operations and granted fleet to an entry that declared none; the
# regression assertions for that live in the dispatcher section below. Written
# even when EMPTY, so every row has four fields and a hand edit that drops the
# trailing tab still reads back as no authority.
assert_contains "$(cat "$(roost_ext_index)")" "$(printf 'mark\t%s\tfleet' "$ext_data/mark/bin/roost-mark")" \
  "index_write carries the extension's declared authority in a fourth column"
assert_contains "$(cat "$(roost_ext_index)")" "$(printf 'demo\t%s\t' "$ext_data/demo/bin/roost-demo")" \
  "index_write writes an empty authority column for an extension that declared none"
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

# A `needs` this cannot understand is refused, not read as "no authority".
# Guessing at a lockfile that says something unreadable ABOUT AUTHORITY is
# exactly the class of decision that produced the bypass the dispatcher
# section below regresses against.
cat > "$(roost_ext_lock)" <<'JSON'
{ "mark": { "commands": ["mark"], "needs": "fleet" } }
JSON
roost_ext_index_write 2>"$TMP/err"; rc=$?
assert_eq "$rc" "1" "index_write refuses a needs that is not an array"
assert_contains "$(cat "$TMP/err")" "needs" "...and says which field it was"
cat > "$(roost_ext_lock)" <<'JSON'
{ "mark": { "commands": ["mark"], "needs": ["fleet two"] } }
JSON
roost_ext_index_write 2>"$TMP/err"; rc=$?
assert_eq "$rc" "1" "index_write refuses an authority with whitespace in it"
assert_contains "$(cat "$TMP/err")" "authority" "...and says that is what it was"

# The two engines have to agree about the authority column too. A machine with
# only jq would otherwise write a different dispatch table than one with
# python3 -- and this column is a grant, so "different" means one of the two
# users is handed authority the other is not.
if command -v jq >/dev/null 2>&1; then
  index_parity_case() {
    # index_parity_case <label> <lockfile-json>
    local label="$1" json="$2" p_rc j_rc p_out j_out
    printf '%s\n' "$json" > "$(roost_ext_lock)"
    roost_ext_index_write 2>"$TMP/err-py"; p_rc=$?
    p_out="$(cat "$(roost_ext_index)" 2>/dev/null)"
    PATH="$TMP/jq-only"
    roost_ext_index_write 2>"$TMP/err-jq"; j_rc=$?
    j_out="$(cat "$(roost_ext_index)" 2>/dev/null)"
    PATH="$saved_path"
    assert_eq "$j_rc" "$p_rc" "both engines agree on the status for $label"
    assert_eq "$j_out" "$p_out" "both engines agree on the index written for $label"
    assert_eq "$(cat "$TMP/err-jq")" "$(cat "$TMP/err-py")" \
      "both engines agree on the message for $label"
  }
  index_parity_case "an entry that declares fleet" \
    '{ "mark": { "commands": ["mark"], "needs": ["fleet"] } }'
  index_parity_case "an entry with an empty needs" \
    '{ "mark": { "commands": ["mark"], "needs": [] } }'
  index_parity_case "an entry with no needs field at all" \
    '{ "mark": { "commands": ["mark"] } }'
  index_parity_case "a needs of null" \
    '{ "mark": { "commands": ["mark"], "needs": null } }'
  index_parity_case "a needs that is a string" \
    '{ "mark": { "commands": ["mark"], "needs": "fleet" } }'
  index_parity_case "a needs entry that is not a string" \
    '{ "mark": { "commands": ["mark"], "needs": [1] } }'
  index_parity_case "a needs entry with whitespace in it" \
    '{ "mark": { "commands": ["mark"], "needs": ["fleet two"] } }'
  index_parity_case "an authority roost does not know" \
    '{ "mark": { "commands": ["mark"], "needs": ["sudo"] } }'
  index_parity_case "the entry that steered the shell reader" \
    '{ "mark": { "description": "needs", "commands": ["fleet"], "needs": [] } }'
fi

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

# The fixtures go in through the SAME path an install would take: write
# ext.lock, then let roost_ext_index_write derive ext.index from it with a
# real JSON parser. Hand-writing the index instead would test a dispatch table
# no installer could produce, and the two places this file does hand-write one
# say why they are doing it.
lock_install() {
  # lock_install <<'JSON' ... JSON  -- reads the lockfile on stdin.
  cat > "$EXT_STATE_ROOT/ext.lock"
  roost_ext_index_write
}
lock_no_needs() {
  lock_install <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"] }
}
JSON
}
lock_fleet() {
  lock_install <<'JSON'
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
# With an extension really installed, so the miss below is a miss against a
# populated dispatch table rather than against no table at all.
lock_no_needs

# The literal bytes, written out once here. `usage_ref` is captured from a
# live run and reused everywhere the seam declines to dispatch, which pins
# those paths to EACH OTHER but not to anything -- a mid-string edit would
# move all four together and every comparison would still hold. This is the
# one assertion that would notice, and the whole point of this branch is that
# an unknown subcommand behaves exactly as it did before the seam existed.
usage_want='usage: roost [up|session NAME|new NAME [SESSION]|spawn NAME [CMD]|split [-h|-v] [-t P] [-n NAME] [CMD]|whoami|ssh HOST|send [--force] TGT TEXT|read TGT [N]|screen TGT [N]|reply TEXT|wait-done TGT [T]|state STATE|hooks|doctor|validate|install|update|init|settings|status|kill [SESSION]|--version|help]'

out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" definitely-not-a-subcommand 2>"$TMP/err")"; rc=$?
usage_ref="$(cat "$TMP/err")"
assert_eq "$rc" "2" "an unknown subcommand still exits 2"
assert_eq "$out" "" "an unknown subcommand still prints nothing on stdout"
assert_eq "$usage_ref" "$usage_want" \
  "an unknown subcommand prints the usage error byte for byte as it did before the seam"
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
# it, so nothing on this path may depend on where the lines fell.
lock_install <<'JSON'
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
lock_install <<'JSON'
{
  "other": { "repo": "o/other", "commands": ["other"], "needs": ["fleet"] },
  "probe": { "repo": "o/probe", "commands": ["probe"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "fleet declared by an EARLIER entry does not leak to this one"
lock_install <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"] },
  "other": { "repo": "o/other", "commands": ["other"], "needs": ["fleet"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "fleet declared by a LATER entry does not leak to this one either"

# --- the grant bypass this whole column exists to close ---------------------
# The dispatcher's first version read `needs` out of ext.lock itself, with
# shell string operations, because neither python3 nor jq may be a runtime
# dependency of roost. It matched the bytes `"needs"` ANYWHERE in an entry and
# took the next `[` after that, so two ordinary string values -- both of them
# copied into the lockfile from the extension's OWN manifest, which is the
# file the design names as the one an attacker would edit -- steered it into
# granting the fleet to an entry whose needs was `[]`.
#
# Every lockfile below is flat: scalars and arrays of strings, the shape the
# contract documents. Nothing here is malformed, which is exactly why it was a
# bypass and not a limitation. The grant now comes from a column a real JSON
# parser wrote, so what these assert is that the shell never gets to guess
# again.
cp "$EXT_DATA/probe/bin/roost-probe" "$EXT_DATA/probe/bin/roost-fleet"
cp "$EXT_DATA/probe/bin/roost-probe" "$EXT_DATA/probe/bin/roost-needs"
lock_install <<'JSON'
{
  "probe": {
    "repo": "o/probe",
    "description": "needs",
    "commands": ["fleet"],
    "needs": []
  }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" fleet 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "the demonstration extension runs, so the assertion below is about the grant"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "a description of 'needs' beside a command called 'fleet' grants nothing"
ext_has_scripts "$(ext_field "$out" PATH)"
assert_eq "$?" "1" "...and puts no roost scripts on its PATH either"
lock_install <<'JSON'
{
  "probe": {
    "repo": "o/probe",
    "commands": ["needs"],
    "description": "see [fleet] for details",
    "needs": []
  }
}
JSON
# Field ORDER matters in this one and it is not decoration: the old reader
# took the first `[` after the first literal `"needs"` bytes, so the
# description has to come after the command that supplies those bytes. Two
# demonstrations rather than one because a single unlucky field order would
# read as a fluke, and this is not one.
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" needs 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "the second demonstration extension runs too"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "a command called 'needs' beside a description containing [fleet] grants nothing"
rm -f "$EXT_DATA/probe/bin/roost-fleet" "$EXT_DATA/probe/bin/roost-needs"

# The same reader failed OPEN on a `]` inside an authority: `fleet]x` was cut
# at the bracket, `fleet` was granted, and the rest never reached
# roost_ext_needs_valid at all. Worse, `["fleet]", "sudo"]` granted fleet and
# DROPPED sudo -- silently ignoring an authority roost does not know, which is
# the one thing roost_ext_needs_valid exists to refuse.
lock_install <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"], "needs": ["fleet]x"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "an authority with a bracket in it is refused, not cut down to one roost knows"
assert_contains "$(cat "$TMP/err")" "fleet]x" "...and the refusal names the whole thing"
lock_install <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"], "needs": ["fleet]", "sudo"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "an unknown authority after a bracketed one is refused, not dropped"
assert_eq "$out" "" "...and nothing is exec'd"

# --- ext.index outlives ext.lock, and that is the whole obligation ----------
# The grant is now carried in the index, so the index IS the dispatcher's
# record and ext.lock is only where that record was derived from. That moves a
# burden onto every writer of ext.lock -- install, update, remove -- and these
# four assertions are the burden written down. The two in the middle pin
# behaviour that is DANGEROUS, not behaviour that is safe: they assert the
# authority is STILL THERE. Anyone reading this section has to come away
# knowing that, rather than believing a stale index fails closed. It does not.
#
# The rule, and task 5 and task 7 both depend on it: whatever writes ext.lock
# regenerates ext.index in the SAME operation. `roost ext list` warning when
# the two disagree is the backstop, not the mechanism.
lock_fleet
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" \
  "stale-index baseline: written together, the grant is there"

# A user deletes the extension from ext.lock by hand and nothing regenerates
# the index. The extension KEEPS the fleet until something does. Asserted as
# the grant being present, because that is what happens.
rm -f "$EXT_STATE_ROOT/ext.lock"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "lockfile deleted, index NOT regenerated: the extension still runs"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" \
  "lockfile deleted, index NOT regenerated: it STILL HAS FLEET -- the index is the record now"

# The sharper version of the same window: the user does not remove the
# extension, they REVOKE its authority -- edits `needs` down to `[]` -- and
# again nothing regenerates the index. The revocation does not take effect.
cat > "$EXT_STATE_ROOT/ext.lock" <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"], "needs": [] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "authority revoked in ext.lock, index NOT regenerated: the extension still runs"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" \
  "authority revoked in ext.lock, index NOT regenerated: the revocation has NOT taken effect"
# ...and it takes effect the moment anything rewrites the index, which is what
# every ext.lock writer is required to do.
roost_ext_index_write
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "regenerating the index is what makes a revocation in ext.lock real"

# And removing the extension the supported way -- both files written in the
# same step -- turns the command back into an unknown one.
rm -f "$EXT_STATE_ROOT/ext.lock"
roost_ext_index_write
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "2" "with the lockfile gone and the index regenerated, the command is unknown again"
assert_eq "$(cat "$TMP/err")" "$usage_ref" "...and it is the usage error, unchanged"

# A hand-edited index line with only three columns -- what an older roost
# wrote, and what an editor that strips trailing whitespace leaves -- is no
# authority. Hand-written on purpose: no installer produces this, and the
# point is what happens when something outside roost has touched the file.
printf 'probe\tprobe\t%s\n' "$EXT_DATA/probe/bin/roost-probe" > "$EXT_STATE_ROOT/ext.index"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "an index line with no authority column still dispatches"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "...and grants nothing, rather than tripping over a column that is not there"

# An authority this roost does not know is REFUSED, not ignored. Ignoring it
# would leave the extension believing it had everything while it had nothing,
# and that surfaces as corrupted behaviour instead of a clean stop.
# roost_ext_index_write deliberately does NOT judge the authority -- deciding
# what `fleet` means is not the index writer's job -- so an unknown one
# reaches the dispatcher, and it is the dispatcher that stops.
lock_install <<'JSON'
{
  "probe": { "repo": "o/probe", "commands": ["probe"], "needs": ["fleet", "sudo"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "an unknown authority stops the command"
assert_eq "$out" "" "an unknown authority means the extension is never exec'd at all"
assert_contains "$(cat "$TMP/err")" "sudo" "the refusal names the authority it did not know"
# A refusal a user cannot act on is a dead end. Both ways out are things they
# can type: take the extension off the machine, or turn the seam off.
assert_contains "$(cat "$TMP/err")" "roost ext remove probe" \
  "the refusal says how to get rid of the extension"
assert_contains "$(cat "$TMP/err")" "ROOST_NO_EXT=1" \
  "the refusal says how to turn the seam off instead"
# The same refusal from a hand-edited index, because that is the other way an
# unknown authority arrives and it must not be the way in.
printf 'probe\tprobe\t%s\tsudo\n' "$EXT_DATA/probe/bin/roost-probe" > "$EXT_STATE_ROOT/ext.index"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "an unknown authority hand-written into the index is refused too"
assert_contains "$(cat "$TMP/err")" "sudo" "...and named"

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

# --- conformance: could a command roost already ships be rebuilt on this? ---
# Every assertion above this line asks whether the seam behaves as specified.
# None of them asks the question that actually decides whether contract 1 was
# designed well: is what the contract HANDS OVER enough to build something
# real with? If a command roost already ships cannot be expressed as an
# extension, the contract is missing something, and the cheap moment to find
# that out is now -- before an extension exists whose shape depends on it.
#
# `roost status` is the subject for three reasons. It needs ROOST_SOCKET, so
# it exercises `needs: ["fleet"]`, the newest and riskiest mechanism here. It
# is about ten lines of list-sessions and list-panes, so writing it twice
# costs almost nothing. And its output is plain text, which against a FIXED
# set of panes makes "byte for byte" a real automated oracle rather than a
# person squinting at two terminals.
#
# The reimplementation in tests/fixtures/ext-status/ is INDEPENDENT, and that
# is the whole value of it: it sources nothing from $ROOST_HOME and never runs
# `roost`. A wrapper that exec'd the original would have proved only that
# `exec` works -- which the assertions above already prove four times over --
# while hiding whatever the contract fails to hand over.
#
# These are FIXTURES AND ONLY FIXTURES. A published roost-status extension
# would be a permanent duplicate of a core command, maintained forever, which
# is the exact bloat this design exists to prevent. They live under
# tests/fixtures/ and go away with the branch.
CONF_FIX="$HERE/tests/fixtures"

# Installed by hand, because `roost ext install` is a later task and this one
# must not wait for it. "By hand" means ext.lock is written here rather than
# by an installer -- ext.index is still DERIVED from it by
# roost_ext_index_write, with a real JSON parser, exactly as an install would
# derive it. Hand-writing the index directly would test a dispatch table no
# installer could ever produce.
#
# The clone directory is named by the manifest's `name` and the binary by
# `bin/roost-<command>`, because that is the layout roost_ext_index_write
# writes paths for and the layout ROOST_EXT_DIR is computed from. Getting
# either wrong here would show up as "unknown subcommand" with nothing to say
# why.
cp -R "$CONF_FIX/ext-status"        "$EXT_DATA/status-ext"
cp -R "$CONF_FIX/ext-status-noneed" "$EXT_DATA/status-noneed-ext"
cp -R "$CONF_FIX/ext-argv"          "$EXT_DATA/argv-ext"

# The two status fixtures are the SAME PROGRAM. Only the declaration differs,
# and asserting that here is what stops the negative case below from quietly
# decaying into "some other program also failed": if these two ever drift
# apart, ext-status-noneed stops being evidence about `needs` at all.
#
# Their manifests differ in `name` and `commands` as well as in `needs`, and
# they have to: `name` is the install directory and a command may be claimed
# by exactly one extension, so two fixtures both called status-ext and both
# claiming status-ext could not be installed side by side -- roost refuses
# that collision by design, and it is asserted higher up this file. The twins
# are therefore identical where it matters, which is the executable, and that
# is what cmp is checking.
cmp -s "$EXT_DATA/status-ext/bin/roost-status-ext" \
       "$EXT_DATA/status-noneed-ext/bin/roost-status-noneed-ext"
assert_true "$?" "the fleet and no-fleet status fixtures are byte-identical programs"

# The manifests are read back with roost's OWN reader, not eyeballed. They are
# hand-written today and `roost ext install` will read them for real in a
# later task; a fixture that install would refuse is a fixture that stops
# meaning anything the day the installer lands.
man="$(roost_ext_manifest_read "$EXT_DATA/status-ext/roost-ext.json" 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "the ext-status manifest parses with roost's own manifest reader"
assert_eq "$(ext_field "$man" name)"     "status-ext" "the ext-status manifest names status-ext"
assert_eq "$(ext_field "$man" contract)" "1"          "the ext-status manifest speaks contract 1"
assert_eq "$(ext_field "$man" commands)" "status-ext" "the ext-status manifest claims the status-ext command"
assert_eq "$(ext_field "$man" needs)"    "fleet"      "the ext-status manifest declares the fleet authority"

man="$(roost_ext_manifest_read "$EXT_DATA/status-noneed-ext/roost-ext.json" 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "the ext-status-noneed manifest parses too"
assert_eq "$(ext_field "$man" needs)" "" \
  "the ext-status-noneed manifest declares NO authority -- the one difference between the twins"

man="$(roost_ext_manifest_read "$EXT_DATA/argv-ext/roost-ext.json" 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "the ext-argv manifest parses"
assert_eq "$(ext_field "$man" needs)" "" "the ext-argv manifest declares no authority either"

lock_install <<'JSON'
{
  "argv-ext":          { "repo": "o/argv-ext",          "commands": ["argv-ext"] },
  "status-ext":        { "repo": "o/status-ext",        "commands": ["status-ext"],        "needs": ["fleet"] },
  "status-noneed-ext": { "repo": "o/status-noneed-ext", "commands": ["status-noneed-ext"] }
}
JSON

# The fourth column, checked before anything is concluded from a run. It is
# the authority the dispatcher will act on -- it reads the grant off this line
# and never from ext.lock or from the extension's own manifest -- so a wrong
# column here would make every grant assertion below pass or fail for a reason
# that has nothing to do with the seam.
conf_index="$EXT_STATE_ROOT/ext.index"
conf_needs() { awk -F'\t' -v c="$1" '$1==c{print $4}' "$conf_index"; }
assert_eq "$(conf_needs status-ext)"        "fleet" "the index grants status-ext the fleet"
assert_eq "$(conf_needs status-noneed-ext)" ""      "the index grants status-noneed-ext nothing"
assert_eq "$(conf_needs argv-ext)"          ""      "the index grants argv-ext nothing"

# --- a fleet that does not move between two runs ----------------------------
# The comparison is only an oracle if both sides see the SAME fleet, so the
# panes are pinned here rather than taken as they come. Every pane gets an
# @roost-name, which keeps #{pane_current_command} out of the output
# entirely -- tests/lib.sh's header records that the test shell's reported
# command is bash on macOS and sh or dash on Linux, so a run that fell back to
# it would compare two platform-dependent strings and could differ between the
# two invocations while a pane was still settling.
#
# The layout exercises both arms of the "/LABEL" conditional in the pane
# format: two panes whose label EQUALS the window name, where the suffix must
# be suppressed, and two where it differs and must be shown. A fixture that
# only ever hit one arm would let a reimplementation that dropped the
# conditional altogether pass.
#
# automatic-rename is tmux's DEFAULT and it is the trap here: a window created
# with `-n api` keeps that name only until the shell inside it reports, and
# then tmux renames the window to the running command. #{window_name} appears
# twice in the pane format -- once shown, once inside the equality test that
# suppresses the "/LABEL" suffix -- so a rename landing between the core run
# and the extension run makes two correct programs print different bytes. This
# was not theorised: a first draft of the overhead measurement, built the same
# way but without this line, refused to time anything on one run in two
# because its own before-and-after sanity check saw the name change. Turning
# the option off globally before any window exists is what makes the fleet
# below actually fixed. (rename-window disables it per window as a side
# effect, which is why the two renamed windows would have been safe anyway and
# the `-n api` one would not.)
T set-option -g automatic-rename off
conf_sess="$(T list-sessions -F '#{session_name}' | head -n 1)"
T rename-session -t "=$conf_sess" conf
T rename-window -t '=conf:0' shell
conf_p_shell="$(T list-panes -t '=conf:0' -F '#{pane_id}')"
require_pane "$conf_p_shell" "the conformance fleet's shell pane"
T new-window -d -t '=conf:' -n api 'ENV= exec /bin/sh'
conf_p_api="$(T list-panes -t '=conf:1' -F '#{pane_id}')"
require_pane "$conf_p_api" "the conformance fleet's api pane"
T rename-window -t '=conf:1' api
conf_p_helper="$(T split-window -d -P -F '#{pane_id}' -t "$conf_p_api" 'ENV= exec /bin/sh')"
require_pane "$conf_p_helper" "the conformance fleet's helper pane"
T new-session -d -s side -x 200 -y 50 'ENV= exec /bin/sh'
T rename-window -t '=side:0' solo
conf_p_worker="$(T list-panes -t '=side:0' -F '#{pane_id}')"
require_pane "$conf_p_worker" "the conformance fleet's worker pane"

# Every option is set on a captured %N rather than on a `session:window.pane`
# string. A name-based target that resolved to nothing sets the option on
# NOTHING and still exits 0 -- and a fleet quietly missing its labels would
# fall back to #{pane_current_command}, which is the one field tests/lib.sh
# warns is not the same on macOS and Linux.
#
# `-p` for a PANE option, not `-w` or `-g`: @roost-name and @agent_state are
# per-pane in roost, and a window-scoped copy would be invisible to the format
# string while looking perfectly set to anyone reading this file.
T set-option -p -t "$conf_p_shell"  @roost-name shell
T set-option -p -t "$conf_p_api"    @roost-name api
T set-option -p -t "$conf_p_api"    @agent_state working
T set-option -p -t "$conf_p_helper" @roost-name helper
T set-option -p -t "$conf_p_helper" @agent_state blocked
T set-option -p -t "$conf_p_worker" @roost-name worker
T set-option -p -t "$conf_p_worker" @agent_state done

# Checked before it is trusted: a fleet that failed to build would make both
# sides of the comparison equally empty, and "" = "" is the shape of a test
# that passes while asserting nothing.
assert_eq "$(T list-panes -a -F x | wc -l | tr -d ' ')" "4" \
  "the conformance fleet really is four panes across two sessions"

# --- the byte comparison ----------------------------------------------------
conf_core="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" status 2>"$TMP/core-err")"; rc=$?
assert_eq "$rc" "0" "core roost status exits 0 against the conformance fleet"
conf_ext="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" status-ext 2>"$TMP/ext-err")"; rc=$?
assert_eq "$rc" "0" "the rebuilt status extension exits 0 against the same fleet"

# Checked before the comparison, for the same reason the pane count is: two
# empty strings compare equal, so an assertion that only says "these match"
# would pass loudest exactly when both sides had broken.
assert_contains "$conf_core" "roost: running (socket=$ROOST_TEST_SOCK)" \
  "core roost status really printed a fleet, so the comparison has something to compare"
assert_eq "$(printf '%s\n' "$conf_core" | wc -l | tr -d ' ')" "7" \
  "core roost status printed one header, two session lines and four pane lines"

assert_eq "$conf_ext" "$conf_core" \
  "an extension rebuilt on contract 1 reproduces roost status BYTE FOR BYTE"
assert_eq "$(cat "$TMP/ext-err")" "$(cat "$TMP/core-err")" \
  "...and writes the same thing to stderr, which for both of them is nothing"

# The other branch of the same command. A reimplementation that only ever
# handled a live server would pass everything above and then print a tmux
# error where roost prints one plain line, and "not running" is the state a
# user sees most often on a machine where they have not started roost yet.
conf_dead="$TMP/no-such-server/s"
conf_core="$(ROOST_SOCKET="$conf_dead" PATH="$EXT_PATH" "$ROOST" status 2>"$TMP/core-err")"; rc=$?
conf_core_rc=$rc
conf_ext="$(ROOST_SOCKET="$conf_dead" PATH="$EXT_PATH" "$ROOST" status-ext 2>"$TMP/ext-err")"; rc=$?
assert_eq "$conf_core" "roost: not running" "core roost status says so when no server is listening"
assert_eq "$conf_ext" "$conf_core" \
  "the extension reproduces the not-running branch byte for byte as well"
assert_eq "$rc" "$conf_core_rc" "...and exits with the same status core does"
assert_eq "$(cat "$TMP/ext-err")" "" \
  "...without leaking tmux's own 'no server running' complaint to stderr"

# --- the negative case: the same program, without the declaration -----------
# The more valuable half. An authority you have never watched being REFUSED is
# an authority you have not tested, and the failure has to be the loud one:
# ROOST_SOCKET is UNSET rather than empty precisely so that a read of it dies
# here instead of quietly addressing the default tmux server -- the user's own
# everyday tmux, which is the one thing roost exists to leave alone. That
# wrong-server run would print a perfectly plausible fleet and exit 0.
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" status-noneed-ext 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "without a declared fleet, the identical program FAILS instead of running"
assert_eq "$out" "" "...printing nothing at all on stdout"
# Not merely "nothing": nothing *of this shape*. Either line would mean it had
# reached a tmux server and answered about it.
case "$out" in *"roost: running"*|*"roost: not running"*) conf_leak=1 ;; *) conf_leak=0 ;; esac
assert_eq "$conf_leak" "0" \
  "...and in particular no status output from whatever server it would otherwise have found"
assert_contains "$(cat "$TMP/err")" "ROOST_SOCKET" \
  "the failure names ROOST_SOCKET"
assert_contains "$(cat "$TMP/err")" "unbound variable" \
  "the failure is an UNSET-variable error, not a tmux error and not silence"

# --- argument fidelity ------------------------------------------------------
# `roost status` takes no arguments, so nothing else in this feature tests
# what the seam does to argv -- and a seam that hands one process's arguments
# to another breaks on quoting far more often than on logic. Each of these
# four is aimed at a different way that goes wrong: `%200` at globbing or
# expansion, `sess:win` at anything that splits on a colon, `--force` at
# option parsing upstream of the extension, and the last at the failure that
# actually happens -- a `$*` or an unquoted `$@` somewhere on the path
# delivering one argument as four.
read -r -d '' conf_argv_want <<'WANT' || true
%200
sess:win
--force
an argument with spaces
WANT
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" argv-ext \
  '%200' 'sess:win' '--force' 'an argument with spaces' 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "the argv extension runs"
assert_eq "$out" "$conf_argv_want" \
  "every argument reaches the extension intact and in order, spaces included"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "4" \
  "...as four arguments, not as words -- an unquoted \$@ anywhere would make seven"
assert_eq "$(cat "$TMP/err")" "" "the argv extension writes nothing to stderr"

# And with no arguments at all, because `roost <cmd>` with nothing after it is
# the ordinary case and a dispatcher that passed the subcommand along would
# show up here as a single line reading "argv-ext".
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" argv-ext 2>"$TMP/err")"; rc=$?
# The exit status is asserted beside the empty stdout because empty stdout on
# its own is also what an extension that never ran prints. One of these two
# lines has to be able to tell "received nothing" from "was never dispatched".
assert_eq "$rc" "0" "the argv extension runs with no arguments at all"
assert_eq "$out" "" "with no arguments the extension receives none -- not its own name"

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
