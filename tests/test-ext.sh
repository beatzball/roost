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
printf 'ROOST_SOCKET_FLAG=%s\n' "${ROOST_SOCKET_FLAG-<unset>}"
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
# `|ext|` is new as of task 5, alongside the wiring in bin/roost's `ext)`
# case arm -- this literal has to move in lockstep with that arm's usage
# string or this assertion stops meaning anything.
usage_want='usage: roost [up|session NAME|new NAME [SESSION]|spawn NAME [CMD]|split [-h|-v] [-t P] [-n NAME] [CMD]|whoami|ssh HOST|send [--force] TGT TEXT|read TGT [N]|screen TGT [N]|reply TEXT|wait-done TGT [T]|state STATE|hooks|doctor|validate|ext|install|update|init|settings|status|kill [SESSION]|--version|help]'

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
# The socket and the flag are ONE grant and they leave together. Leaving the
# flag behind would hand out half a capability and a misleading signal with it:
# an extension finding a flag and no socket would be reading the leftovers of a
# grant it was refused. Absent, again, rather than empty -- an empty flag makes
# `tmux "" "$sock"` and tmux reads the empty string as a command, which fails
# in a way that says nothing about authority.
assert_eq "$(ext_field "$out" ROOST_SOCKET_FLAG)" "<unset>" \
  "without fleet, ROOST_SOCKET_FLAG is ABSENT too -- the pair is withheld together"
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
# tmux needs -S for a socket PATH and -L for a socket NAME, and an extension
# handed only the value writes the obvious `tmux -L "$ROOST_SOCKET"` -- which
# works against the production server, whose socket is the NAME `roost`, and
# silently addresses a DIFFERENT server everywhere else. This suite's own
# server is a path under mktemp -d, so -S is the right answer here and -L
# would be the wrong one.
assert_eq "$(ext_field "$out" ROOST_SOCKET_FLAG)" "-S" \
  "with fleet, a socket PATH is handed over as -S"
ext_has_scripts "$(ext_field "$out" PATH)"
assert_true "$?" "with fleet, roost's own scripts are prepended to the extension's PATH"
assert_prefix "$(ext_field "$out" PATH)" "$HERE/scripts:" \
  "with fleet, roost's scripts come FIRST on PATH, as a pane's do"

# The OTHER shape, and it is the one the production server has: a socket NAME
# rather than a path, which tmux takes with -L. Everything else in this file
# addresses a path under mktemp -d, so without this assertion the flag could be
# hardcoded to "-S" and the whole suite would still be green while every real
# user's roost -- socket name `roost` -- got the wrong flag.
#
# The name is one no server exists on, and that is deliberate rather than
# incidental. The dispatcher's only tmux call before exec is
# `show-options -gqv @roost-ext-enabled`, which on an absent socket ERRORS and
# creates nothing -- checked, not assumed -- so this run starts no server, and
# in particular never goes near `-L roost`, which on this machine is the
# author's live fleet (AGENTS.md §2). The probe stub prints its environment
# and runs no tmux of its own.
# TMUX_TMPDIR moves where a `-L` NAME resolves to, so every named socket in
# this file lands inside $TMP and the real /tmp/tmux-<uid> is never touched at
# all -- not by a connect, not by a mistake, and not by a future edit to this
# block. That is belt and braces on top of the paragraph above: with it set,
# even the literal name `roost` here could not reach the author's live fleet.
#
# It is its OWN mktemp -d under /tmp, not a directory inside $TMP, and that is
# not tidiness. A unix socket path is capped at ~104 characters and silently
# fails past it -- tests/lib.sh's header says so, and it is why that file
# builds its socket under /tmp/amx.XXXX rather than in $TMPDIR. On macOS
# $TMPDIR is a ~50-character path under /var/folders, and `-L <name>` appends
# tmux-<uid>/<name> to TMUX_TMPDIR on top of it: the first version of this
# line put the directory inside $TMP and `new-session` exited 1 with the
# server never starting. Cleaned up by the EXIT trap re-armed just below.
CONF_TMUXTMP="$(mktemp -d /tmp/amx.XXXX)"
# A hook the conformance block replaces once it has a named server to kill.
# One trap, one place, rather than a second trap that a later edit could leave
# holding a stale command.
conf_teardown() { :; }
trap 'conf_teardown; roost_test_teardown; rm -rf "$TMP" "$CONF_TMUXTMP"' EXIT
# EXPORTED once, here, rather than prefixed onto each `-L` invocation. The
# prefixed form was the first version of this and it was wrong in a way that
# is easy to miss: it makes safety a thing every FUTURE `-L` line in this file
# has to remember, and the assertion below that checks the sandbox is empty
# would still pass while a forgotten prefix put the server in the real
# directory. Exported, every later line is safe by construction.
# tests/test-session-context.sh and tests/test-reply-socket.sh already do
# exactly this; nothing after this point wants `-L` to reach the real
# directory. NT() below keeps its own prefix as belt and braces.
export TMUX_TMPDIR="$CONF_TMUXTMP"
# ...and REFUSE to go on if that did not take. Exits 1, so tests/run.sh reports
# this file as died-mid-run rather than letting a green count hide it.
roost_test_tmux_named_guard
conf_named_sock="roost-conformance-no-such-socket"
out="$(ROOST_SOCKET="$conf_named_sock" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "an extension runs when the socket is a NAME rather than a path"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$conf_named_sock" \
  "a socket name is handed over verbatim"
assert_eq "$(ext_field "$out" ROOST_SOCKET_FLAG)" "-L" \
  "...and a socket NAME is handed over as -L, where a path is handed over as -S"
# Proof that the paragraph above is true rather than merely believed: if that
# show-options call had started a server, this is where the socket would be.
assert_file_absent "$CONF_TMUXTMP/tmux-$(id -u)/$conf_named_sock" \
  "probing a named socket started no tmux server in the sandbox"
# The sandbox check above is not enough on its own, and saying "anywhere" while
# only looking in the sandbox is exactly the kind of assertion this repository
# gets bitten by: if the export were ever dropped, the server would land in the
# REAL directory and that check would still pass. So look there too -- at both
# named sockets this file uses. These two are the assertions that would notice.
assert_file_absent "/tmp/tmux-$(id -u)/$conf_named_sock" \
  "...and none in the REAL tmux directory, where a dropped TMUX_TMPDIR would put it"

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

# --- roost ext list / roost ext info ----------------------------------------
# Task 5. Both verbs are read-only and never touch tmux, so unlike everything
# above this comment neither needs $EXT_PATH's scrubbed PATH or a live server
# to be correct about -- ROOST_SOCKET is still exported on every call anyway,
# for the same belt-and-braces reason the rest of this file does: the test
# suite should never be one dropped export away from falling through to `-L
# roost`, the author's live fleet (AGENTS.md §2), even on a path that
# provably never calls `t`.
[ -x "$HERE/scripts/roost-ext" ]
assert_true "$?" "scripts/roost-ext exists and is executable"

# An unknown verb -- and no verb at all -- is a usage error naming every verb
# this feature will have by the end of task 8, not just the two that work
# today. Breaks if the case in scripts/roost-ext stops listing all six, or if
# the exit code drifts off the usage-error convention every other unknown
# roost command uses.
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext bogus-verb 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "2" "an unknown 'roost ext' verb exits 2"
assert_eq "$out" "" "an unknown 'roost ext' verb prints nothing on stdout"
ext_usage_err="$(cat "$TMP/err")"
for v in install list info verify update remove; do
  assert_contains "$ext_usage_err" "$v" "the roost ext usage error names the '$v' verb"
done

out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "2" "'roost ext' with no verb at all is the same usage error"
assert_eq "$(cat "$TMP/err")" "$ext_usage_err" "...byte for byte"

# --- list: nothing installed -------------------------------------------------
# Both "no lockfile at all" and "a lockfile that is the empty object" have to
# read the same way to a user: nothing is installed. Neither should trip the
# disagreement warning on its own -- there being nothing in ext.lock is not a
# disagreement as long as ext.index says the same.
rm -f "$(roost_ext_lock)" "$(roost_ext_index)"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "roost ext list with no lockfile at all exits 0"
assert_contains "$out" "no extensions installed" "...and says nothing is installed"
assert_contains "$out" "roost ext install" "...and says how to install one"
assert_eq "$(cat "$TMP/err")" "" "no lockfile and no index: nothing to warn about"

printf '{}\n' > "$(roost_ext_lock)"
roost_ext_index_write
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "roost ext list with an empty ({}) lockfile exits 0"
assert_contains "$out" "no extensions installed" "...and reads the same as no lockfile at all"
assert_eq "$(cat "$TMP/err")" "" "an empty lockfile freshly regenerated into an empty index: no warning"

# --- list: two entries, and the commit is SHORTENED -------------------------
mkdir -p "$EXT_DATA/alpha/bin" "$EXT_DATA/beta/bin"
: > "$EXT_DATA/alpha/bin/roost-alpha"; chmod +x "$EXT_DATA/alpha/bin/roost-alpha"
: > "$EXT_DATA/beta/bin/roost-beta";   chmod +x "$EXT_DATA/beta/bin/roost-beta"
lock_install <<'JSON'
{
  "alpha": { "repo": "o/alpha", "ref": "v1.0.0", "commit": "1111111111111111111111111111111111111111", "commands": ["alpha"] },
  "beta":  { "repo": "o/beta",  "ref": "v2.0.0", "commit": "2222222222222222222222222222222222222222", "commands": ["beta", "beta2"], "needs": ["fleet"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "roost ext list with two entries exits 0"
assert_eq "$(cat "$TMP/err")" "" "two entries written together with the index (lock_install's own shape): no disagreement"
assert_contains "$out" "alpha" "roost ext list names the alpha extension"
assert_contains "$out" "1111111" "roost ext list shows alpha's commit, shortened"
assert_contains "$out" "beta" "roost ext list names the beta extension"
assert_contains "$out" "beta2" "roost ext list shows every command an entry claims, not just the first"
case "$out" in
  *1111111111111111111111111111111111111111*) commit_not_shortened=1 ;;
  *)                                           commit_not_shortened=0 ;;
esac
assert_eq "$commit_not_shortened" "0" "the full 40-character commit never appears -- only the shortened form does"

# --- list: a deleted clone is marked missing --------------------------------
rm -rf "$EXT_DATA/alpha"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"
alpha_line="$(printf '%s\n' "$out" | grep '^alpha ')"
beta_line="$(printf '%s\n' "$out" | grep '^beta ')"
assert_contains "$alpha_line" "missing" "a clone whose directory is gone is marked missing"
case "$beta_line" in
  *missing*) beta_marked_missing=1 ;;
  *)         beta_marked_missing=0 ;;
esac
assert_eq "$beta_marked_missing" "0" "an intact clone is NOT marked missing"

# --- list: the ext.lock / ext.index disagreement warning --------------------
# The security property task 5 exists to surface, not merely a formatting
# one: the dispatcher (bin/roost's `*)` fallback, wired in task 3) obeys
# ext.index alone, so a lockfile that has moved on has no effect until
# something regenerates the index. These assertions would not notice a
# regression that turned the warning into plain "the two files differ" --
# that is why they check for the file names, "obeyed", and a way to fix it,
# not just that SOME text appeared on stderr.
mkdir -p "$EXT_DATA/gamma/bin"
: > "$EXT_DATA/gamma/bin/roost-gamma"; chmod +x "$EXT_DATA/gamma/bin/roost-gamma"
lock_install <<'JSON'
{ "gamma": { "repo": "o/gamma", "commands": ["gamma"], "needs": ["fleet"] } }
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"
assert_eq "$(cat "$TMP/err")" "" "gamma installed and the index regenerated together: no warning yet"

# The sharper case from the design doc's own table: an authority REVOKED in
# ext.lock by hand, with ext.index never rewritten. This is the unsafe
# direction -- the grant is still live -- and list's job is to say so loudly,
# not to pretend the lockfile's new "no fleet" already took effect.
cat > "$(roost_ext_lock)" <<'JSON'
{ "gamma": { "repo": "o/gamma", "commands": ["gamma"], "needs": [] } }
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"; rc=$?
gamma_warn="$(cat "$TMP/err")"
assert_eq "$rc" "0" "list still runs and shows what it can when the two files disagree -- it warns, it does not refuse"
assert_contains "$out" "gamma" "list still shows gamma while the two files disagree"
assert_contains "$gamma_warn" "ext.lock" "the warning names ext.lock"
assert_contains "$gamma_warn" "ext.index" "the warning names ext.index"
assert_contains "$gamma_warn" "obeyed" "the warning says which file is being OBEYED, not merely that they differ"
assert_contains "$gamma_warn" "SECURITY" "the warning reads as a security warning, not a tidiness one"
assert_contains "$gamma_warn" "install, update, remove" "the warning says how to reconcile the two files"
assert_contains "$gamma_warn" "gamma" "the warning names the extension it is ABOUT, not just the two filenames"
assert_contains "$gamma_warn" "authority" "the warning says the disagreement is about an AUTHORITY, not just any difference"
# Every printed line stays short enough to read -- roost-install and
# roost-validate hold their own user-facing lines under 150 characters, and a
# security warning nobody reads because it wrapped badly in a narrow terminal
# defeats the point of writing one at all.
long_line="$(printf '%s\n' "$gamma_warn" | awk '{ if (length > 150) print }')"
assert_eq "$long_line" "" "no line of the disagreement warning exceeds 150 characters"

roost_ext_index_write
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"
assert_eq "$(cat "$TMP/err")" "" "regenerating the index is what makes the warning go away"

# The other direction the design's table names: the lockfile deleted outright
# and the index left behind. `list` reports from the lockfile (there is
# nothing installed, as far as ext.lock says) while STILL warning that
# ext.index disagrees -- an index with entries and no lockfile at all is
# exactly the shape a hand-deleted ext.lock leaves.
rm -f "$(roost_ext_lock)"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"; rc=$?
gone_warn="$(cat "$TMP/err")"
assert_eq "$rc" "0" "list with the lockfile gone entirely still exits 0"
assert_contains "$out" "no extensions installed" "...and reports what the (now empty) lockfile says"
assert_contains "$gone_warn" "ext.index" "...while still warning that a now-stale ext.index disagrees"
assert_contains "$gone_warn" "gamma" "...and names gamma specifically -- it is the one still sitting in ext.index"

# ...and the last row in the table: a lockfile with entries and NO index file
# at all (rather than a stale one). Also a disagreement -- an index that
# cannot even be found is not "in agreement" with a lockfile that names
# commands to dispatch.
lock_install <<'JSON'
{ "delta": { "repo": "o/delta", "commands": ["delta"] } }
JSON
rm -f "$(roost_ext_index)"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"; rc=$?
delta_warn="$(cat "$TMP/err")"
assert_eq "$rc" "0" "list with the index missing outright still exits 0"
assert_contains "$out" "delta" "...and still reports what the lockfile says"
assert_contains "$delta_warn" "ext.index" "...while warning that the missing index disagrees with the lockfile"
assert_contains "$delta_warn" "delta" "...and names delta -- it is the one ext.lock claims that ext.index cannot"

# --- list: an index-engine-only refusal is STILL a disagreement -------------
# The sharper bug: a lockfile that _ext_lock_rows (the DISPLAY reader) can
# read just fine, but that roost_ext_index_write's own engines refuse --
# an empty `commands` array is exactly this, since the display reader treats
# an absent-or-empty list as "-" while the index engine calls it "lists no
# commands" and refuses to write a row for it at all. A version of this
# check that read "the index engine failed" as "expected nothing" compared
# that against an ALSO-empty on-disk index and called them equal -- silence,
# on a lockfile that names an extension the index names none of, which is
# the exact disagreement item 5 exists to warn about.
mkdir -p "$EXT_DATA/echo-ext/bin"
: > "$EXT_DATA/echo-ext/bin/roost-echo-ext"; chmod +x "$EXT_DATA/echo-ext/bin/roost-echo-ext"
cat > "$(roost_ext_lock)" <<'JSON'
{ "echo-ext": { "repo": "o/echo-ext", "commit": "abcdef0123456789", "commands": [] } }
JSON
: > "$(roost_ext_index)"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"; rc=$?
empty_commands_warn="$(cat "$TMP/err")"
assert_eq "$rc" "0" "a lockfile the index engine refuses still lets list run"
assert_contains "$out" "echo-ext" "...and list still shows the extension the lockfile names"
[ -n "$empty_commands_warn" ]
assert_true "$?" "an index-engine refusal is not silently read as 'nothing to disagree about'"
assert_contains "$empty_commands_warn" "ext.index" "the warning fires even though the index engine, not a byte mismatch, is what disagrees"
assert_contains "$empty_commands_warn" "echo-ext" "...and names the extension the lockfile claims"
rm -rf "$EXT_DATA/echo-ext"
rm -f "$(roost_ext_lock)"
roost_ext_index_write

# --- info: a known name ------------------------------------------------------
mkdir -p "$EXT_DATA/mark/bin"
: > "$EXT_DATA/mark/bin/roost-mark";  chmod +x "$EXT_DATA/mark/bin/roost-mark"
: > "$EXT_DATA/mark/bin/roost-marks"; chmod +x "$EXT_DATA/mark/bin/roost-marks"
cat > "$EXT_DATA/mark/roost-ext.json" <<'JSON'
{
  "name": "mark",
  "contract": 1,
  "roost": ">=0.1.0 <0.2.0",
  "needs": ["fleet"],
  "commands": ["mark", "marks"],
  "description": "Bookmark a spot in an agent pane, with a note."
}
JSON
lock_install <<'JSON'
{
  "mark": {
    "repo": "beatzball/roost-mark",
    "ref": "v0.1.0",
    "commit": "a3f91c2e5b7d4419c2f0aa18e6cd3b7f92104a6d",
    "tree": "6b1d0c94f2a7e5318cd40b7a2f9e6c1d83b45209",
    "contract": 1,
    "needs": ["fleet"],
    "commands": ["mark", "marks"],
    "installed": "2026-09-08T10:14:22Z"
  }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext info mark 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "roost ext info on a known name exits 0"
assert_eq "$(cat "$TMP/err")" "" "...and writes nothing to stderr"
assert_contains "$out" "mark" "info names the extension"
assert_contains "$out" "beatzball/roost-mark" "info shows the lockfile's repo"
assert_contains "$out" "v0.1.0" "info shows the lockfile's ref"
assert_contains "$out" "a3f91c2e5b7d4419c2f0aa18e6cd3b7f92104a6d" "info shows the lockfile's commit IN FULL, unlike list"
assert_contains "$out" "fleet" "info shows the declared authority"
assert_contains "$out" "Bookmark a spot in an agent pane" "info shows the manifest's own description"
assert_contains "$out" "$EXT_DATA/mark" "info shows the clone directory path"
assert_contains "$out" "$EXT_STATE_ROOT/ext/mark" "info shows the extension's private state directory path"

# --- info: an unknown name, and a missing NAME argument ---------------------
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext info definitely-not-installed 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "roost ext info on an unknown name exits 1"
assert_eq "$out" "" "...and prints nothing on stdout"
assert_contains "$(cat "$TMP/err")" "definitely-not-installed" "...and the refusal names the unknown extension"

out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext info 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "2" "roost ext info with no NAME at all is a usage error, not an unknown-name refusal"

# --- info: the lockfile entry survives a deleted clone -----------------------
# The lockfile is the record of what is installed, not the clone -- the same
# rule roost_ext_index_lookup enforces on the dispatch path. `info` on a name
# ext.lock still names has a real answer even with the clone gone.
rm -rf "$EXT_DATA/mark"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext info mark 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "info on a name whose clone is gone still succeeds"
assert_contains "$out" "beatzball/roost-mark" "...and still shows the lockfile entry"
assert_contains "$out" "missing" "...and says the manifest/clone is missing"

# --- info / list: a hand-edited ext.lock cannot escape the extensions dir ---
# `roost ext install` will refuse (per the design spec) any path resolving
# outside the extension directory. `_ext_lock_rows` applies no name
# validation of its own -- it is a display reader, not a security control --
# so without a guard at the point a name is turned into a PATH, a lockfile
# key of "../secret" would make `info` open
# $data_dir/../secret/roost-ext.json: a real file outside ext/ entirely,
# read and printed, exit 0. This is the read-side version of the exact
# property the spec already requires on the write side.
mkdir -p "$TMP/traversal-target"
cat > "$TMP/traversal-target/roost-ext.json" <<'JSON'
{ "name": "secret", "contract": 1, "commands": ["secret"], "description": "should never be read" }
JSON
# The lockfile key is "../traversal-target", which from $EXT_DATA/ (this
# test's ext/ directory) resolves to $TMP/traversal-target -- the file
# above, outside ext/ entirely. roost_ext_name_valid refuses it outright
# (a `/` is not in [a-z0-9-]), which is exactly the property under test.
lock_install <<'JSON'
{ "../traversal-target": { "repo": "o/x", "commands": ["x"] } }
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext info '../traversal-target' 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "info refuses a lockfile key that is not a valid install name, rather than reading through it"
assert_eq "$out" "" "...and prints nothing on stdout -- not the traversed file's manifest fields"
assert_contains "$(cat "$TMP/err")" "traversal-target" "...and names what was refused"
case "$(cat "$TMP/err")" in
  *"should never be read"*) assert_true 1 "the traversal target's own content never reaches stdout or stderr" ;;
  *) assert_true 0 "the traversal target's own content never reaches stdout or stderr" ;;
esac
# `list` sees the same malformed entry (every entry in ext.lock is listed,
# not just the one asked about) -- it must not touch the filesystem for it
# either, and it says so rather than silently treating it like an ordinary
# missing clone.
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"
assert_contains "$out" "invalid name" "list marks the bad entry as an invalid name rather than checking a path outside ext/"
rm -f "$(roost_ext_lock)"
roost_ext_index_write

# --- list / info: the `-` placeholder, asserted directly -------------------
# Guarded only INDIRECTLY until now: reverting the placeholder fix breaks
# "roost ext list shows every command an entry claims" (a shifted field, not
# a literal absence) because that entry has OTHER optional fields recorded
# too. This is the field-shift bug's minimal case -- ONE entry, nothing but
# `commands` -- asserted as the exact rendered text rather than through a
# side effect of a bigger fixture.
mkdir -p "$EXT_DATA/bare/bin"
: > "$EXT_DATA/bare/bin/roost-bare"; chmod +x "$EXT_DATA/bare/bin/roost-bare"
lock_install <<'JSON'
{ "bare": { "commands": ["bare"] } }
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"
bare_line="$(printf '%s\n' "$out" | grep '^bare ')"
assert_eq "$bare_line" "bare  -  bare" "list renders a genuinely absent commit as the literal placeholder '-', not an empty or shifted field"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext info bare 2>"$TMP/err")"
assert_contains "$out" "  repo       -" "info renders a genuinely absent repo as '-'"
assert_contains "$out" "  ref        -" "...ref too"
assert_contains "$out" "  commit     -" "...commit too"
assert_contains "$out" "  needs      none" "...but needs gets the word 'none', not the bare placeholder"
rm -rf "$EXT_DATA/bare"
rm -f "$(roost_ext_lock)"
roost_ext_index_write

# --- list / info: the jq engine must agree with python3 ---------------------
# _ext_lock_rows_py and _ext_lock_rows_jq live in scripts/roost-ext, not in
# the sourced library, so they cannot be called directly the way
# roost_ext_manifest_read's parity_case (above, ~line 394) and
# roost_ext_index_write's index_parity_case (above, ~line 655) call THEIR
# engine pairs. This harness proves the same thing the way it has to be
# proved here: run `roost ext list` twice against the identical lockfile,
# once under the ambient PATH (python3 present) and once under a PATH with
# nothing but jq and what scripts/roost-ext needs merely to START (bash, for
# its own #!/usr/bin/env shebang; dirname, for the one line that finds its
# sibling library; cat, for the heredoc-through-cat engine scripts) -- then
# diff exit status, stdout and stderr.
#
# Skipped, not failed, where jq is absent: it is not a roost dependency.
if command -v jq >/dev/null 2>&1; then
  # awk, sort and head are NOT part of what distinguishes a jq machine from a
  # python3 one -- _ext_index_disagrees uses them, unconditionally, to name
  # WHICH extension a disagreement is about, regardless of which JSON engine
  # answered "is there one". Omitting them here would test "does scripts/
  # roost-ext run with awk missing", which is not the question this harness
  # asks and not a machine that exists.
  mkdir -p "$TMP/ext-jq-only"
  for c in bash dirname cat jq awk sort head; do
    printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$c")" > "$TMP/ext-jq-only/$c"
    chmod +x "$TMP/ext-jq-only/$c"
  done
  _ext_lock_rows_parity_case() {
    # _ext_lock_rows_parity_case <label> <lockfile-json>
    local label="$1" json="$2" p_out p_rc j_out j_rc
    printf '%s\n' "$json" > "$(roost_ext_lock)"
    p_out="$("$HERE/scripts/roost-ext" list 2>"$TMP/err-py")"; p_rc=$?
    j_out="$(PATH="$TMP/ext-jq-only" "$HERE/scripts/roost-ext" list 2>"$TMP/err-jq")"; j_rc=$?
    assert_eq "$j_rc" "$p_rc" "both engines agree on the exit status for $label"
    assert_eq "$j_out" "$p_out" "both engines agree on roost ext list's stdout for $label"
    assert_eq "$(cat "$TMP/err-jq")" "$(cat "$TMP/err-py")" \
      "both engines agree on the stderr message for $label"
  }
  # A lockfile key containing a TAB -- this is the exact reproduction that
  # found the jq engine reading `.foo` at the call site and folding "key
  # absent" and "key present but null" into the same placeholder: the tab
  # check on the NAME was missing entirely, so jq built a 9-field row where
  # python3 refused the file outright.
  _ext_lock_rows_parity_case "a lockfile key containing a tab" \
    '{ "a\tb": { "repo": "o/a", "commit": "abcdef0123456789", "commands": ["x", "y"] } }'
  _ext_lock_rows_parity_case "an explicit null ref" \
    '{ "a": { "repo": "o/a", "commands": ["x"], "ref": null } }'
  _ext_lock_rows_parity_case "an explicit null needs" \
    '{ "a": { "repo": "o/a", "commands": ["x"], "needs": null } }'
  _ext_lock_rows_parity_case "an explicit null commands" \
    '{ "a": { "repo": "o/a", "commands": null } }'
  _ext_lock_rows_parity_case "a fully populated, well-formed entry" \
    '{ "mark": { "repo": "o/mark", "ref": "v1.0.0", "commit": "abcdef0123456789", "commands": ["mark", "marks"], "needs": ["fleet"] } }'
  _ext_lock_rows_parity_case "an entry with almost nothing recorded" \
    '{ "a": { "commands": ["x"] } }'
  rm -f "$(roost_ext_lock)"
  roost_ext_index_write
fi

# --- roost ext install ------------------------------------------------------
# The security-critical command of this feature, and the one place where a
# refusal that quietly stopped working would not be noticed by anything else
# in this file: every other section here is handed a lockfile and a clone that
# a test wrote by hand, so nothing above proves that the thing which PUT them
# there refuses what it is supposed to refuse.
#
# NO NETWORK, EVER. `git ls-remote` and `git clone` resolve through
# ROOST_EXT_GIT_BASE, which is pointed at a directory of local bare
# repositories addressed as file:// URLs. A suite that reached GitHub would be
# flaky, and -- much worse -- would go green while the pinning logic was
# wrong, because a network install that works proves nothing about which
# commit was pinned.
rm -f "$(roost_ext_lock)"
roost_ext_index_write
# The names this section installs under, cleared first. Earlier sections
# hand-build clone directories with some of these names (the index_lookup
# fixtures use `demo`), and `roost ext install` REFUSES a directory it did not
# put there rather than moving a clone inside it -- correct behaviour, and
# without this line it would show up here as a puzzling failure of the first
# install rather than as the leftover it is.
rm -rf "$EXT_DATA/demo" "$EXT_DATA/quiet" "$EXT_DATA/inlink" "$EXT_DATA/withsub" \
       "$EXT_DATA/later" "$EXT_DATA/weird" "$EXT_DATA/parity"

EXT_REMOTES="$TMP/remotes"
EXT_SRCS="$TMP/ext-src"
mkdir -p "$EXT_REMOTES" "$EXT_SRCS"
EXT_BASE="file://$EXT_REMOTES/"

# Every git that BUILDS a fixture, in one place. -c rather than a written
# config because HOME is the canary in this file and must stay empty: git
# would otherwise have no identity to commit with and no default branch name,
# and would say so on stderr in the middle of an unrelated assertion.
# core.hooksPath=/dev/null keeps the developer's own global hooks off these
# throwaway commits -- this machine has a pre-commit hook that scans content,
# and a fixture commit is not something it has any business reading.
ext_fixture_git() {
  git -c init.defaultBranch=main -c core.hooksPath=/dev/null \
      -c user.name=roost-test -c user.email=roost-test@example.invalid \
      -c commit.gpgsign=false "$@"
}

# ext_src DIR MANIFEST-JSON [CMD...] -> a source tree for a fixture: the
# manifest at the root, and one executable per CMD at bin/roost-<CMD>. The
# executables print their own name and their arguments, so a dispatch
# assertion can tell "the right program ran" from "something ran".
ext_src() {
  local dir="$1" json="$2" c
  shift 2
  mkdir -p "$dir/bin"
  printf '%s\n' "$json" > "$dir/roost-ext.json"
  for c in "$@"; do
    printf '#!/bin/sh\nprintf "%s ran [%%s]\\n" "$*"\n' "$c" > "$dir/bin/roost-$c"
    chmod +x "$dir/bin/roost-$c"
  done
}

# ext_publish ORG/REPO SRCDIR [TAG] -> publish SRCDIR as a BARE repository at
# the path ROOST_EXT_GIT_BASE maps ORG/REPO to. Bare, and reached over
# file://, because that is what makes `git clone` and `git ls-remote` take the
# same code path they take against a real remote -- a plain directory would
# still clone, but a local-path clone hardlinks objects and skips the transfer
# entirely, so the one thing this fixture exists to exercise would not run.
ext_publish() {
  local spec="$1" src="$2" tag="${3:-}"
  local bare="$EXT_REMOTES/$spec"
  mkdir -p "$(dirname "$bare")"
  rm -rf "$bare"
  ext_fixture_git init -q "$src" >/dev/null 2>&1
  ext_fixture_git -C "$src" add -A >/dev/null 2>&1
  ext_fixture_git -C "$src" commit -q -m "roost-ext fixture" >/dev/null 2>&1
  if [ -n "$tag" ]; then
    ext_fixture_git -C "$src" tag "$tag" >/dev/null 2>&1
  fi
  git clone -q --bare "$src" "$bare" >/dev/null 2>&1
}

# The command under test, always through ROOST_EXT_GIT_BASE.
ext_install() { ROOST_EXT_GIT_BASE="$EXT_BASE" "$HERE/scripts/roost-ext" install "$@"; }

# ext_lock_field NAME KEY -> one field of one ext.lock entry, read back with
# roost's own reader rather than with grep: a grep over JSON would pass on a
# lockfile this feature could not itself read.
ext_lock_field() {
  local name="$1" key="$2" rows
  rows="$("$HERE/scripts/roost-ext" info "$name" 2>/dev/null)" || return 1
  # Only the "lockfile entry:" stanza, cut at the blank line that ends it.
  # `info` prints the MANIFEST underneath with the same two-space layout, and
  # four of the keys (name, contract, needs, commands) appear in both -- a
  # reader that took the first match anywhere would be reading the lockfile
  # for some keys and the extension's own file for others, which is exactly
  # the confusion the fourth column of ext.index exists to prevent.
  printf '%s\n' "$rows" | sed -n '/^lockfile entry:/,/^$/p' | sed -n "s/^  $key  *//p" | head -1
}

ext_index_col() {
  # ext_index_col CMD N -> field N of the ext.index line claiming CMD.
  awk -F'\t' -v c="$1" -v n="$2" '$1==c{print $n}' "$EXT_STATE_ROOT/ext.index"
}

# --- <org>/<repo> is refused BEFORE git is invoked --------------------------
# The one check in this command that happens before network contact, and the
# only way to prove it happened first is to make the network contact
# impossible to survive: ROOST_EXT_GIT_BASE points at a directory that does
# not exist, so ANY install that reached git would fail with git's own words.
# Each of these fails with roost's instead, naming the rule and the section of
# the design that carries it.
ext_nowhere() { ROOST_EXT_GIT_BASE="file://$TMP/there-is-no-such-directory/" "$HERE/scripts/roost-ext" install "$@"; }
for bad in '../..' '-x/y' 'x/-y' 'https://host/o/r' 'a b/c' './..' 'o/..'; do
  out="$(ext_nowhere "$bad" --yes 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"
  assert_eq "$rc" "1" "install refuses [$bad]"
  assert_eq "$out" "" "install prints nothing on stdout for [$bad]"
  assert_contains "$err" "Input handling" \
    "the refusal for [$bad] names the design's own rule, not git's error"
  case "$err" in
    *fatal:*|*"install: git:"*) leaked=1 ;;
    *) leaked=0 ;;
  esac
  assert_eq "$leaked" "0" "nothing reached git for [$bad] — no git message in the refusal"
done
# A single argument with an embedded space is one argv element, and the loop
# above passes it as one. Asserted separately rather than assumed, because a
# `for bad in $list` with the wrong quoting would have split it into two and
# the case would have silently become a different, easier one.
out="$(ext_nowhere 'a b/c' --yes 2>"$TMP/err")"
assert_contains "$(cat "$TMP/err")" "refusing a b/c" \
  "the embedded-space spec really did arrive as ONE argument"

# The other value that reaches a git command line.
for badref in '-x' 'a..b' '/abs' 'a b'; do
  out="$(ext_nowhere fix/good --ref "$badref" --yes 2>"$TMP/err")"; rc=$?
  assert_eq "$rc" "1" "install refuses the ref [$badref]"
  assert_contains "$(cat "$TMP/err")" "not a plain ref name" \
    "the refusal for the ref [$badref] says which rule it broke"
  assert_contains "$(cat "$TMP/err")" "nothing has been fetched" \
    "...and says nothing was fetched"
done

# --- a real install, against a real file:// repository ----------------------
ext_src "$EXT_SRCS/good" '{
  "name": "demo",
  "contract": 1,
  "roost": ">=0.1.0 <9.0.0",
  "needs": ["fleet"],
  "commands": ["demo", "demos"],
  "description": "A fixture, not a published extension."
}' demo demos
ext_publish fix/good "$EXT_SRCS/good" v0.1.0
# What the remote really holds, resolved HERE with git rather than taken from
# the installer's own output: an assertion that compared the installer to
# itself would hold however wrong the pin was.
good_sha="$(git ls-remote -- "file://$EXT_REMOTES/fix/good" v0.1.0 | awk '{print $1}')"
good_head="$(git ls-remote -- "file://$EXT_REMOTES/fix/good" HEAD | awk '{print $1}')"

# Its own variable, not `out`: the consent-block assertions further down read
# this again, and `out` is reused by every run between here and there.
good_out="$(ext_install fix/good --ref v0.1.0 --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "install succeeds against a file:// fixture with --yes"
assert_eq "$(cat "$TMP/err")" "" "a successful install writes nothing to stderr"

# The plan block, line for line against the design's own layout.
assert_contains "$good_out" "  repo     file://$EXT_REMOTES/fix/good" \
  "the plan names the repository it is about to fetch from"
assert_contains "$good_out" "  ref      v0.1.0" "the plan names the ref that was asked for"
assert_contains "$good_out" "  commit   ${good_sha:0:7}...  (pinned)" \
  "the plan shows the resolved commit, marked as pinned"
assert_contains "$good_out" "  contract 1                       (roost speaks 1)     ok" \
  "the contract row sits where the design's block puts it"
assert_contains "$good_out" "  claims   roost demo, roost demos" \
  "the plan names every command the extension would claim"

# THE PIN. A full 40-character commit id, and the one the remote really
# resolves that tag to -- not the ref, not an abbreviation.
lock_commit="$(ext_lock_field demo commit)"
assert_eq "$lock_commit" "$good_sha" "ext.lock records the commit the ref resolved to"
assert_eq "${#lock_commit}" "40" "...as the full 40-character id, not the ref and not an abbreviation"
assert_eq "$(ext_lock_field demo ref)" "v0.1.0" "ext.lock records the ref that was asked for, beside the commit"
assert_eq "$(ext_lock_field demo repo)" "fix/good" "ext.lock records the repository"
assert_eq "$(ext_lock_field demo needs)" "fleet" "ext.lock records the authority that was consented to"
assert_eq "$(ext_lock_field demo contract)" "1" "ext.lock records the contract"
printf '%s' "$(ext_lock_field demo installed)" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
assert_true "$?" "ext.lock records an install time in UTC ISO-8601"

# THE TREE, and WHICH function produced it. On a pristine clone
# roost_ext_tree_hash and `git rev-parse HEAD^{tree}` agree, so this pair of
# assertions cannot tell them apart on its own -- the submodule fixture
# further down is where they genuinely diverge, and that is where the choice
# is actually pinned. What this one proves is the half that matters to task
# 7: the recorded value is what verify will recompute.
lock_tree="$(ext_lock_field demo tree)"
assert_eq "$lock_tree" "$(roost_ext_tree_hash "$EXT_DATA/demo")" \
  "ext.lock records the tree hash roost_ext_tree_hash computes for the installed directory"
printf '%s' "$lock_tree" | grep -Eq '^[0-9a-f]{40}$'
assert_true "$?" "...as a 40-character git object id"

# The dispatch table, in the four columns the dispatcher reads.
assert_eq "$(ext_index_col demo 2)" "demo" "ext.index names the extension in column 2"
assert_eq "$(ext_index_col demo 3)" "$EXT_DATA/demo/bin/roost-demo" \
  "ext.index points at the installed executable"
assert_eq "$(ext_index_col demo 4)" "fleet" \
  "ext.index carries the authority in column 4, where the dispatcher reads it"
assert_eq "$(ext_index_col demos 3)" "$EXT_DATA/demo/bin/roost-demos" \
  "the second claimed command gets its own line"

# AND IT RUNS. Everything above is bookkeeping until the command a user types
# reaches the program that was installed.
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" demo a 'b c' 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "roost <cmd> runs the freshly installed extension"
assert_eq "$out" "demo ran [a b c]" "...the right program, with its arguments"

# --- the default ref is the remote's HEAD -----------------------------------
ext_src "$EXT_SRCS/quiet" '{
  "name": "quiet",
  "contract": 1,
  "commands": ["quiet"]
}' quiet
ext_publish fix/quiet "$EXT_SRCS/quiet"
quiet_head="$(git ls-remote -- "file://$EXT_REMOTES/fix/quiet" HEAD | awk '{print $1}')"
quiet_out="$(ext_install fix/quiet --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "install with no --ref succeeds"
assert_eq "$(ext_lock_field quiet commit)" "$quiet_head" \
  "with no --ref the pin is the remote's own HEAD, resolved to a full id"
assert_eq "$(ext_lock_field quiet ref)" "HEAD" "...and the recorded ref says so"

# --- the consent block: what it says about authority, and what it never says -
# The two fixtures are compared as a PAIR. Either assertion on its own would
# pass on a build that printed the same paragraph for both, which is the one
# failure that would make the whole declaration worthless: a user who reads
# "asks to drive your agents" on every install stops reading it.
assert_contains "$good_out" "This extension asks to drive your agents" \
  "a fleet extension's consent block says what it can do, in words"
assert_contains "$good_out" "read any pane's screen and send prompts to any agent" \
  "...naming the two capabilities, not the name of a manifest field"
case "$quiet_out" in
  *"asks to drive your agents"*) quiet_authority=1 ;;
  *) quiet_authority=0 ;;
esac
assert_eq "$quiet_authority" "0" \
  "an extension that declared no authority gets NO authority paragraph"
assert_contains "$quiet_out" "does not ask for access to your agents" \
  "...it gets the one line that says what it declared"
# "does not ask", never "cannot reach" -- the second would be false, and the
# design says so outright. This is the assertion that would catch someone
# tightening the wording into a promise roost cannot keep.
case "$quiet_out" in
  *"cannot reach"*) quiet_overclaim=1 ;;
  *) quiet_overclaim=0 ;;
esac
assert_eq "$quiet_overclaim" "0" \
  "...and never claims the extension CANNOT reach the agents, which would be false"

# Printed under BOTH branches, because `needs` is a declaration and not a
# boundary: a pane's own $TMUX and PATH already carry the fleet, and the
# production socket is the guessable name `roost`. The user who reads "does
# not ask" has to be told that in the same breath.
for consent_out in "$good_out" "$quiet_out"; do
  assert_contains "$consent_out" "An extension that did NOT ask can still reach them if it tries" \
    "the consent block says a declaration is not a boundary"
  assert_contains "$consent_out" "Roost has checked that this is the exact commit named above" \
    "the consent block states the one thing roost really checked"
  assert_contains "$consent_out" "NOT checked whether the code is honest. It cannot." \
    "...and states, always, what it did not check"
  assert_contains "$consent_out" "Nothing runs during install." \
    "the consent block promises nothing runs during install"
done

# NO WORD THAT READS AS A VERDICT. Roost checks integrity and grants
# authority; it cannot judge whether code is honest, and one reassuring
# adjective undoes the whole design because people believe badges. Checked
# case-insensitively over both consent blocks and over the success message.
consent_all="$(printf '%s\n%s\n' "$good_out" "$quiet_out" | tr 'A-Z' 'a-z')"
for verdict in safe clean scanned verified trusted trustworthy secure vetted audited approved legitimate; do
  case "$consent_all" in
    *"$verdict"*) verdict_hit=1 ;;
    *) verdict_hit=0 ;;
  esac
  assert_eq "$verdict_hit" "0" "no install output reads as a verdict on the code: [$verdict]"
done

# --- every refusal in step 4 of the design, each with its own fixture -------
# `assert_contains` on the REASON, not merely on a non-zero exit: a command
# that refused everything for one generic reason would pass an exit-status
# test and tell a user nothing.
ext_refuse_case() {
  # ext_refuse_case <label> <org/repo> <expected-substring> [extra args...]
  local label="$1" spec="$2" want="$3"
  shift 3
  local r_out r_rc
  r_out="$(ext_install "$spec" --yes "$@" 2>"$TMP/err")"; r_rc=$?
  [ "$r_rc" -ne 0 ]
  assert_true "$?" "install refuses $label"
  assert_contains "$(cat "$TMP/err")" "$want" "...naming the reason: $label"
  # Nothing installed, nothing recorded. A refusal that left a clone behind
  # would leave `roost ext list` reporting an extension nobody consented to.
  assert_eq "$(ext_index_col "$refuse_cmd" 3)" "" "...and claims no command in ext.index: $label"
}

mkdir -p "$EXT_SRCS/nomanifest"
printf 'not a manifest\n' > "$EXT_SRCS/nomanifest/README.md"
ext_publish fix/nomanifest "$EXT_SRCS/nomanifest"
refuse_cmd=nothing
ext_refuse_case "a repository with no roost-ext.json" fix/nomanifest "has no roost-ext.json"

ext_src "$EXT_SRCS/badname" '{ "name": "Bad Name", "contract": 1, "commands": ["bad"] }' bad
ext_publish fix/badname "$EXT_SRCS/badname"
refuse_cmd=bad
ext_refuse_case "a manifest whose name is not usable" fix/badname "is not usable"

ext_src "$EXT_SRCS/contract2" '{ "name": "future", "contract": 2, "commands": ["future"] }' future
ext_publish fix/contract2 "$EXT_SRCS/contract2"
refuse_cmd=future
ext_refuse_case "a contract this roost does not speak" fix/contract2 "speaks contract 2, this roost speaks 1"

ext_src "$EXT_SRCS/badneeds" '{ "name": "greedy", "contract": 1, "needs": ["sudo"], "commands": ["greedy"] }' greedy
ext_publish fix/badneeds "$EXT_SRCS/badneeds"
refuse_cmd=greedy
ext_refuse_case "an authority roost does not know" fix/badneeds "does not know: sudo"

# CORE ALWAYS WINS, and `send` is the command the design picks out by name: an
# extension that could shadow it could silently intercept every message
# between the user's agents.
ext_src "$EXT_SRCS/shadow" '{ "name": "shadow", "contract": 1, "commands": ["send"] }' send
ext_publish fix/shadow "$EXT_SRCS/shadow"
refuse_cmd=send
ext_refuse_case "a manifest claiming a core command" fix/shadow "which is a roost command"

# Already claimed by the extension installed at the top of this section.
ext_src "$EXT_SRCS/collide" '{ "name": "rival", "contract": 1, "commands": ["demo"] }' demo
ext_publish fix/collide "$EXT_SRCS/collide"
out_collide="$(ext_install fix/collide --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "install refuses a command another extension already claims"
assert_contains "$(cat "$TMP/err")" "already claimed by demo" \
  "...naming the extension that holds it, which is the actionable half"
assert_eq "$(ext_index_col demo 2)" "demo" "...and the extension that held it still holds it"

# A declared command with nothing behind it. The manifest claims `ghost`; the
# repository has bin/roost-real and no bin/roost-ghost.
ext_src "$EXT_SRCS/nobin" '{ "name": "ghosty", "contract": 1, "commands": ["ghost"] }' real
ext_publish fix/nobin "$EXT_SRCS/nobin"
refuse_cmd=ghost
ext_refuse_case "a declared command with no executable" fix/nobin "has no executable bin/roost-ghost"

# Present but not executable is the same refusal, and it is the one a real
# extension author hits: a file committed without its mode bit.
ext_src "$EXT_SRCS/notexec" '{ "name": "flat", "contract": 1, "commands": ["flat"] }' flat
chmod -x "$EXT_SRCS/notexec/bin/roost-flat"
ext_publish fix/notexec "$EXT_SRCS/notexec"
refuse_cmd=flat
ext_refuse_case "a declared command whose file is not executable" fix/notexec "has no executable bin/roost-flat"

# --- a hostile tree, refused after cloning and before anything is moved -----
# A SYMLINK OUT OF THE EXTENSION DIRECTORY. That directory is deleted whole by
# `remove`, hashed whole by `verify` and replaced whole by `update`; a link
# out of it turns each of those into an operation on the user's own files.
# git stores symlinks (mode 120000) and a clone materialises them, so this one
# really does arrive through the pipeline rather than being staged by hand.
ext_src "$EXT_SRCS/escape" '{ "name": "escapee", "contract": 1, "commands": ["escapee"] }' escapee
ln -s ../../../../etc/passwd "$EXT_SRCS/escape/outside"
ext_publish fix/escape "$EXT_SRCS/escape"
refuse_cmd=escapee
ext_refuse_case "a tree with a symlink pointing outside the extension" fix/escape \
  "a symlink pointing outside the extension: outside"

# An ABSOLUTE symlink, which escapes whatever its text says.
ext_src "$EXT_SRCS/abslink" '{ "name": "abslink", "contract": 1, "commands": ["abslink"] }' abslink
ln -s /etc/hosts "$EXT_SRCS/abslink/hosts"
ext_publish fix/abslink "$EXT_SRCS/abslink"
refuse_cmd=abslink
ext_refuse_case "a tree with an absolute symlink" fix/abslink "a symlink pointing outside"

# A symlink that stays INSIDE is ordinary and must still install: a check that
# refused every link would be refused by every real extension, and would be
# turned off within a week.
ext_src "$EXT_SRCS/inlink" '{ "name": "inlink", "contract": 1, "commands": ["inlink"] }' inlink
ln -s bin/roost-inlink "$EXT_SRCS/inlink/alias"
ln -s ../roost-ext.json "$EXT_SRCS/inlink/bin/manifest"
ext_publish fix/inlink "$EXT_SRCS/inlink"
out_inlink="$(ext_install fix/inlink --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "a symlink that resolves INSIDE the extension installs normally"
assert_eq "$(cat "$TMP/err")" "" "...with nothing on stderr"

# THE SETUID CASE CANNOT COME THROUGH GIT, and saying so is the point. Git
# records exactly three file modes -- 100644, 100755 and 120000 -- so no
# repository, hostile or otherwise, can deliver a setuid bit through a clone.
# The check still has to exist (the clone is not the only way a directory gets
# populated, and `update` will move trees around too), so it is exercised
# where it CAN be exercised: directly, against a directory with a real setuid
# file in it. A fixture repository here would have proved nothing, because the
# bit would never have survived the round trip.
HOSTILE="$TMP/hostile"; mkdir -p "$HOSTILE/bin"
printf '#!/bin/sh\n:\n' > "$HOSTILE/bin/roost-x"; chmod 4755 "$HOSTILE/bin/roost-x"
roost_ext_tree_hostile "$HOSTILE"
assert_true "$?" "tree_hostile finds a setuid file"
assert_contains "$ROOST_EXT_HOSTILE_FOUND" "setuid or setgid file: bin/roost-x" \
  "...and names the file, relative to the extension directory"
chmod 2755 "$HOSTILE/bin/roost-x"
roost_ext_tree_hostile "$HOSTILE"
assert_true "$?" "tree_hostile finds a setgid file too"
chmod 755 "$HOSTILE/bin/roost-x"
roost_ext_tree_hostile "$HOSTILE"
assert_eq "$?" "1" "...and finds nothing once the bit is off"
# A setgid DIRECTORY is deliberately not a finding: on macOS and the BSDs a
# new directory inherits the bit from its parent, so refusing it would refuse
# an ordinary install for a property of the machine's temp directory.
chmod 2755 "$HOSTILE/bin"
roost_ext_tree_hostile "$HOSTILE"
assert_eq "$?" "1" "a setgid DIRECTORY is not a finding — it is inherited, not chosen"
chmod 755 "$HOSTILE/bin"

# The lexical rule the symlink half rests on, asserted on its own so the
# reasoning is pinned rather than inferred from one fixture.
roost_ext__link_escapes "bin/x" "../../etc/passwd"
assert_true "$?" "a link two levels up from bin/ escapes"
roost_ext__link_escapes "bin/x" "../roost-ext.json"
assert_eq "$?" "1" "...and one level up from bin/ does not"
roost_ext__link_escapes "x" "../y"
assert_true "$?" "a link one level up from the root escapes"
roost_ext__link_escapes "x" "/etc/hosts"
assert_true "$?" "an absolute target escapes"
roost_ext__link_escapes "x" "a/../b"
assert_eq "$?" "1" "a target that dips and returns without leaving stays inside"
roost_ext__link_escapes "x" "../ext/x"
assert_true "$?" "...but one that leaves and comes back is refused anyway — conservative on purpose"

# --- the hardened clone: a submodule is NOT fetched -------------------------
# A .gitmodules URL is another fetch, to a host the user was never shown, and
# its checkout is another tree nothing has looked at. The fixture carries a
# real gitlink and a real .gitmodules pointing at a second local repository
# whose only file is unmistakable; installing must leave that file absent.
ext_src "$EXT_SRCS/subpayload" '{ "name": "payload", "contract": 1, "commands": ["payload"] }' payload
printf 'THE-SUBMODULE-WAS-FETCHED\n' > "$EXT_SRCS/subpayload/marker"
ext_publish fix/subpayload "$EXT_SRCS/subpayload"
sub_sha="$(git ls-remote -- "file://$EXT_REMOTES/fix/subpayload" HEAD | awk '{print $1}')"
ext_src "$EXT_SRCS/withsub" '{ "name": "withsub", "contract": 1, "commands": ["withsub"] }' withsub
cat > "$EXT_SRCS/withsub/.gitmodules" <<GITMOD
[submodule "sub"]
	path = sub
	url = file://$EXT_REMOTES/fix/subpayload
GITMOD
ext_fixture_git init -q "$EXT_SRCS/withsub" >/dev/null 2>&1
ext_fixture_git -C "$EXT_SRCS/withsub" add -A >/dev/null 2>&1
# A gitlink written straight into the index: `git submodule add` would clone
# the thing this fixture exists to prove is never cloned.
ext_fixture_git -C "$EXT_SRCS/withsub" update-index --add --cacheinfo "160000,$sub_sha,sub" >/dev/null 2>&1
ext_fixture_git -C "$EXT_SRCS/withsub" commit -q -m "roost-ext fixture" >/dev/null 2>&1
rm -rf "$EXT_REMOTES/fix/withsub"
git clone -q --bare "$EXT_SRCS/withsub" "$EXT_REMOTES/fix/withsub" >/dev/null 2>&1

out_sub="$(ext_install fix/withsub --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "a repository carrying a .gitmodules still installs"
assert_file_absent "$EXT_DATA/withsub/sub/marker" \
  "...but the submodule was never fetched — nothing ran and nothing was downloaded"
[ -f "$EXT_DATA/withsub/.gitmodules" ]
assert_true "$?" "...while the .gitmodules file itself is present, so this really is the submodule case"

# WHAT THE FIXTURE ABOVE DOES AND DOES NOT PROVE, measured rather than
# assumed. Each hardening measure was removed from scripts/roost-ext in turn
# and this file re-run:
#
#   --no-recurse-submodules removed, --no-checkout kept  -> ALL GREEN. With
#   nothing checked out there is no submodule work to recurse into, and the
#   `git checkout --detach` that follows does not recurse by default. The flag
#   is real belt-and-braces, and this fixture cannot see it on its own.
#
#   both removed                                          -> the install FAILS
#   and two assertions above go red, because git refuses to clone a file://
#   submodule at all (protocol.file.allow). So the fixture catches the pair
#   coming off -- but by the clone erroring, not by the marker appearing.
#
# Which means the marker file can never appear on a git this recent, and an
# assertion resting on it alone would be asserting git's behaviour rather than
# roost's. GIT_LFS_SKIP_SMUDGE and core.hooksPath are worse still: neither can
# be provoked at all without installing git-lfs and a hook into a fixture.
#
# So the three measures the design names by name are ALSO pinned in the
# source, and this is a grep -- it proves the line is PRESENT, not that it is
# live (AGENTS.md §9), which is exactly why it sits beside the behavioural
# fixture above rather than instead of it. Without it, deleting the flag that
# makes the consent block's promise true is a change nothing in this suite
# would notice.
grep -q -- '--no-recurse-submodules' "$HERE/scripts/roost-ext"
assert_true "$?" "the clone passes --no-recurse-submodules: a .gitmodules URL is another fetch"
grep -q 'GIT_LFS_SKIP_SMUDGE=1' "$HERE/scripts/roost-ext"
assert_true "$?" "every git runs with GIT_LFS_SKIP_SMUDGE=1: an LFS smudge filter is a command"
grep -q -- '-c core.hooksPath=/dev/null' "$HERE/scripts/roost-ext"
assert_true "$?" "every git runs with core.hooksPath=/dev/null"
# All three on ONE wrapper, so a git invocation added later cannot be the
# unhardened one. Asserted because the alternative -- repeating them per call
# -- is what makes that possible, and it would still pass the three greps
# above.
grep -q 'GIT_LFS_SKIP_SMUDGE=1 GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null' "$HERE/scripts/roost-ext"
assert_true "$?" "...carried by one wrapper, so a git added here later is hardened by construction"

# THE TREE HASH, AND WHICH FUNCTION PRODUCED IT. This is the fixture where
# roost_ext_tree_hash and `git rev-parse HEAD^{tree}` genuinely disagree: the
# commit's tree carries a gitlink entry for `sub`, and the working tree that
# was actually installed does not carry it at all. Recording the commit's tree
# here would have `roost ext verify` compare a hash of something that is not
# on the disk, and cry tamper at a clean install every single time.
sub_lock_tree="$(ext_lock_field withsub tree)"
assert_eq "$sub_lock_tree" "$(roost_ext_tree_hash "$EXT_DATA/withsub")" \
  "ext.lock records roost_ext_tree_hash's answer for the installed directory"
sub_commit_tree="$(git -C "$EXT_DATA/withsub" rev-parse 'HEAD^{tree}' 2>/dev/null)"
[ "$sub_lock_tree" != "$sub_commit_tree" ]
assert_true "$?" \
  "...which is NOT git rev-parse HEAD^{tree} — the two really do differ here, so the choice is pinned"

# --- the pin is checked against what actually arrived -----------------------
# The ref moved between resolving it and cloning it: the commit that was
# pinned is no longer in the repository at all. This is the shape of the
# attack the pin exists to survive, built rather than imagined -- the tip is
# rewritten and the old object pruned.
ext_src "$EXT_SRCS/moved" '{ "name": "moved", "contract": 1, "commands": ["moved"] }' moved
ext_publish fix/moved "$EXT_SRCS/moved"
moved_sha="$(git ls-remote -- "file://$EXT_REMOTES/fix/moved" HEAD | awk '{print $1}')"
printf 'second\n' > "$EXT_SRCS/moved/second.txt"
ext_fixture_git -C "$EXT_SRCS/moved" add -A >/dev/null 2>&1
ext_fixture_git -C "$EXT_SRCS/moved" commit -q --amend -m "rewritten" >/dev/null 2>&1
rm -rf "$EXT_REMOTES/fix/moved"
git clone -q --bare "$EXT_SRCS/moved" "$EXT_REMOTES/fix/moved" >/dev/null 2>&1
moved_new="$(git ls-remote -- "file://$EXT_REMOTES/fix/moved" HEAD | awk '{print $1}')"
[ "$moved_new" != "$moved_sha" ]
assert_true "$?" "the fixture really did rewrite the tip, so this case has something to catch"
out_moved="$(ext_install fix/moved --ref "$moved_sha" --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "install refuses when the pinned commit is not in the repository"
assert_contains "$(cat "$TMP/err")" "$moved_sha" "...naming the commit that was asked for"
assert_contains "$(cat "$TMP/err")" "refusing rather than installing something else" \
  "...and saying it would rather refuse than install a different commit"
assert_file_absent "$EXT_DATA/moved" "...leaving nothing on disk"

# --- an out-of-range or unparsable `roost` warns, and still installs --------
# The range is advisory on purpose: a hard product-version gate would make
# every roost release a compatibility event, which is the cost the contract
# integer exists to avoid. Both directions warn; neither may ever refuse.
ext_src "$EXT_SRCS/future" '{ "name": "later", "contract": 1, "roost": ">=9.0.0 <10.0.0", "commands": ["later"] }' later
ext_publish fix/future "$EXT_SRCS/future"
out_range="$(ext_install fix/future --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "an out-of-range roost range still installs"
assert_contains "$out_range" ">=9.0.0 <10.0.0" "...the plan shows the range that was declared"
assert_contains "$out_range" "warn" "...marked as a warning rather than as ok"
assert_contains "$out_range" "the range is advisory" "...saying in words that it is advisory"
assert_eq "$(ext_index_col later 2)" "later" "...and it really is installed"

ext_src "$EXT_SRCS/weird" '{ "name": "weird", "contract": 1, "roost": "^1.0.0", "commands": ["weird"] }' weird
ext_publish fix/weird "$EXT_SRCS/weird"
out_weird="$(ext_install fix/weird --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "an unparsable roost range still installs"
assert_contains "$out_weird" "cannot read" "...saying roost could not read the range"
assert_eq "$(ext_index_col weird 2)" "weird" "...and it really is installed"

# --- silence is never consent ------------------------------------------------
# Not a terminal, and no --yes. The install must refuse AND leave nothing
# behind: an install driven from a script, a cron entry or a pipe has nobody
# to answer, and the answer roost invents for an absent person must be no.
ext_src "$EXT_SRCS/silent" '{ "name": "silent", "contract": 1, "commands": ["silent"] }' silent
ext_publish fix/silent "$EXT_SRCS/silent"
lock_before="$(cat "$(roost_ext_lock)")"
index_before="$(cat "$EXT_STATE_ROOT/ext.index")"
out_silent="$(ext_install fix/silent </dev/null 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "a non-tty install without --yes refuses"
assert_contains "$(cat "$TMP/err")" "not a terminal" "...saying why"
assert_contains "$out_silent" "Install? [y/N]" "...after printing the plan it was asking about"
assert_file_absent "$EXT_DATA/silent" "...and installs nothing"
assert_file_absent "$EXT_STATE_ROOT/ext/silent" "...creates no state directory"
assert_eq "$(cat "$(roost_ext_lock)")" "$lock_before" "...leaves ext.lock byte-identical"
assert_eq "$(cat "$EXT_STATE_ROOT/ext.index")" "$index_before" "...leaves ext.index byte-identical"

# --- a lockfile write without a matching index is not an install ------------
# ext.index is the authority of record: the dispatcher never opens ext.lock,
# so a lockfile written without a matching index is a grant nobody can see and
# nobody can revoke. The design states it as a requirement -- every command
# that changes ext.lock regenerates ext.index in the same operation and must
# not report success if that regeneration failed.
#
# The failure is provoked with a lockfile that `roost ext list` can read but
# that cannot be turned into a dispatch table: an entry claiming no commands
# at all. That is what a hand-edited ext.lock looks like, and it is the only
# way to reach this branch without breaking the machine's JSON tools.
ext_src "$EXT_SRCS/halfway" '{ "name": "halfway", "contract": 1, "commands": ["halfway"] }' halfway
ext_publish fix/halfway "$EXT_SRCS/halfway"
printf '%s\n' '{ "wedged": { "repo": "o/wedged", "commands": [] } }' > "$(roost_ext_lock)"
lock_before="$(cat "$(roost_ext_lock)")"
rm -f "$EXT_STATE_ROOT/ext.index"
out_half="$(ext_install fix/halfway --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "install fails when ext.index cannot be regenerated"
assert_contains "$(cat "$TMP/err")" "could not be turned into a dispatch table" "...saying what failed"
assert_contains "$(cat "$TMP/err")" "halfway is not installed" "...and that the install did not happen"
assert_eq "$(cat "$(roost_ext_lock)")" "$lock_before" \
  "...with ext.lock put back exactly as it was, not left carrying an entry nothing dispatches"
assert_file_absent "$EXT_DATA/halfway" "...and the clone taken back off the disk"
rm -f "$(roost_ext_lock)"
roost_ext_index_write

# --- install's own engine pair: python3 and jq must agree -------------------
# A THIRD pair of JSON engines lands with this task -- _ext_lock_add_py and
# _ext_lock_add_jq, which merge one entry into ext.lock. Three separate times
# on this branch a pair that was CLAIMED to agree did not, and each divergence
# was silent and only wrong on a jq-only machine. So the parity test lands
# with the engines rather than after them.
#
# It cannot call the two functions directly -- they live in scripts/roost-ext,
# not in the sourced library -- so it proves the same thing the way
# _ext_lock_rows_parity_case does: run the WHOLE install twice, against the
# same fixture and the same pre-existing lockfile, once under the ambient PATH
# and once under a PATH carrying jq and no python3, then compare the ext.lock
# that came out of each, byte for byte.
#
# Skipped, not failed, where jq is absent: it is not a roost dependency.
if command -v jq >/dev/null 2>&1; then
  # Everything `roost ext install` actually runs. Longer than the other
  # jq-only PATHs in this file because install is the one verb that fetches,
  # hashes and writes -- but the same shape, and the same reason for the
  # shape: files WRITTEN here, never symlinks to the real binaries. A `>`
  # follows a symlink, and overwriting an entry in a shim directory built out
  # of symlinks has destroyed real binaries on this machine before.
  mkdir -p "$TMP/install-jq-only"
  for c in bash sh dirname cat jq git sed date mktemp mv cp rm mkdir find readlink chmod awk sort head; do
    if command -v "$c" >/dev/null 2>&1; then
      printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$c")" > "$TMP/install-jq-only/$c"
      chmod +x "$TMP/install-jq-only/$c"
    fi
  done
  ext_src "$EXT_SRCS/parity" '{
  "name": "parity",
  "contract": 1,
  "roost": ">=0.1.0 <9.0.0",
  "needs": ["fleet"],
  "commands": ["parity"],
  "description": "parité — a description that is not ASCII"
}' parity
  ext_publish fix/parity "$EXT_SRCS/parity"

  # _ext_lock_add_parity_case <label> <pre-existing ext.lock> -- installs the
  # same fixture into two throwaway sandboxes, one per engine, and diffs the
  # lockfile each wrote. The `installed` timestamp is the one field that
  # legitimately differs between two runs a second apart, so it is normalised
  # away; everything else has to match exactly.
  _ext_lock_add_parity_case() {
    local label="$1" seed="$2" engine root rc
    for engine in py jq; do
      root="$TMP/parity-$engine"
      rm -rf "$root"; mkdir -p "$root/state/roost" "$root/data"
      printf '%s\n' "$seed" > "$root/state/roost/ext.lock"
      if [ "$engine" = jq ]; then
        XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
          PATH="$TMP/install-jq-only" ROOST_EXT_GIT_BASE="$EXT_BASE" \
          "$HERE/scripts/roost-ext" install fix/parity --yes >/dev/null 2>"$TMP/perr-$engine"
      else
        XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
          ROOST_EXT_GIT_BASE="$EXT_BASE" \
          "$HERE/scripts/roost-ext" install fix/parity --yes >/dev/null 2>"$TMP/perr-$engine"
      fi
      rc=$?
      # Through files rather than through two variables built by `eval`: the
      # engine name is part of the variable name and an eval there is one
      # quoting mistake away from comparing a variable with itself, which is
      # the shape of a parity test that passes while proving nothing.
      printf '%s\n' "$rc" > "$TMP/prc-$engine"
      sed 's/"installed": ".*"/"installed": "<t>"/' "$root/state/roost/ext.lock" > "$TMP/plock-$engine" 2>/dev/null
    done
    assert_eq "$(cat "$TMP/prc-jq")" "$(cat "$TMP/prc-py")" \
      "both engines agree on the exit status for $label"
    assert_eq "$(cat "$TMP/plock-jq")" "$(cat "$TMP/plock-py")" \
      "both engines write a byte-identical ext.lock for $label"
    # The engine name is part of the sandbox PATH, and both engines quote the
    # lockfile's path back in their refusals -- so the two roots are
    # normalised away before comparing. Without this the assertion compares
    # ".../parity-py/..." with ".../parity-jq/..." and fails on two messages
    # that agree in every word that matters.
    sed "s|$TMP/parity-py|<root>|g" "$TMP/perr-py" > "$TMP/perr-py.norm"
    sed "s|$TMP/parity-jq|<root>|g" "$TMP/perr-jq" > "$TMP/perr-jq.norm"
    assert_eq "$(cat "$TMP/perr-jq.norm")" "$(cat "$TMP/perr-py.norm")" \
      "both engines agree on the stderr message for $label"
  }
  _ext_lock_add_parity_case "a machine with nothing installed" '{}'
  _ext_lock_add_parity_case "an existing entry that must survive untouched" \
    '{ "mark": { "repo": "o/mark", "ref": "v1.0.0", "commit": "abc", "commands": ["mark"], "needs": ["fleet"] } }'
  _ext_lock_add_parity_case "an existing entry carrying fields roost does not write" \
    '{ "mark": { "commands": ["mark"], "future": { "b": 2, "a": [1, {"z": null, "y": true}] } } }'
  _ext_lock_add_parity_case "an existing entry with a non-ASCII description" \
    '{ "mark": { "commands": ["mark"], "description": "caffè — ünïcode" } }'
  _ext_lock_add_parity_case "a name already in the lockfile" \
    '{ "parity": { "repo": "o/parity", "commands": ["parity"] } }'
  _ext_lock_add_parity_case "a lockfile that is not an object" '[ "mark" ]'
  # NOT a case here: a lockfile that is not JSON at all. The two engines
  # deliberately word a parse failure differently -- roost_ext__json_read's
  # header records that decision, and says why pretending they agree would be
  # worse -- so comparing their stderr there would be asserting the opposite
  # of the contract.

  # THE ONE PLACE THE TWO ENGINES DO NOT AGREE, asserted rather than glossed
  # over. A JSON number written in EXPONENT form comes back as `100.0` from
  # python3 and as `1E+2` from jq 1.7: the same value, spelled differently.
  # Nothing roost writes produces an exponent literal -- only a hand-edited
  # lockfile can -- and no reader in this feature cares which spelling it
  # sees. Recorded here because a stated invariant that is false is worse than
  # no invariant, and the next person to add a parity case needs to know this
  # one is expected rather than a fresh bug.
  for engine in py jq; do
    root="$TMP/parity-$engine"
    rm -rf "$root"; mkdir -p "$root/state/roost" "$root/data"
    printf '%s\n' '{ "mark": { "commands": ["mark"], "odd": 1e2 } }' > "$root/state/roost/ext.lock"
    if [ "$engine" = jq ]; then
      XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" PATH="$TMP/install-jq-only" \
        ROOST_EXT_GIT_BASE="$EXT_BASE" "$HERE/scripts/roost-ext" install fix/parity --yes >/dev/null 2>&1
    else
      XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
        ROOST_EXT_GIT_BASE="$EXT_BASE" "$HERE/scripts/roost-ext" install fix/parity --yes >/dev/null 2>&1
    fi
  done
  exp_py="$(sed -e 's/"installed": ".*"/"installed": "<t>"/' -e 's/"odd": .*/"odd": <num>/' "$TMP/parity-py/state/roost/ext.lock" 2>/dev/null)"
  exp_jq="$(sed -e 's/"installed": ".*"/"installed": "<t>"/' -e 's/"odd": .*/"odd": <num>/' "$TMP/parity-jq/state/roost/ext.lock" 2>/dev/null)"
  assert_eq "$exp_jq" "$exp_py" \
    "the two engines agree on everything but the spelling of an exponent-form number"
  grep -q '"odd": 100.0' "$TMP/parity-py/state/roost/ext.lock"
  assert_true "$?" "python3 re-spells 1e2 as 100.0 — the known divergence, pinned so it is not mistaken for a bug"
  rm -rf "$TMP/parity-py" "$TMP/parity-jq"
fi

# Leave the state this section built behind, so the conformance block below
# starts from nothing. The clones go too: the block underneath copies its own
# fixtures into this same directory.
rm -f "$(roost_ext_lock)"
roost_ext_index_write
rm -rf "$EXT_DATA/demo" "$EXT_DATA/quiet" "$EXT_DATA/inlink" "$EXT_DATA/withsub" \
       "$EXT_DATA/later" "$EXT_DATA/weird"

# Leave a clean slate for the conformance block below, which builds its own
# lockfile from scratch and must not inherit any entry from this section.
rm -f "$(roost_ext_lock)"
roost_ext_index_write
rm -rf "$EXT_DATA/alpha" "$EXT_DATA/beta" "$EXT_DATA/gamma" "$EXT_DATA/delta" "$EXT_DATA/mark"

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
# THIS BLOCK MUST REMAIN THE LAST ONE BEFORE THE SANDBOX CANARY, and a later
# task appending to this file has to append ABOVE it, not below.
#
# The header of this file invites exactly that appending -- every task in this
# feature adds to this one file rather than a file of its own -- so the
# constraint has to be written down rather than inferred. What follows is not
# self-contained: it MUTATES the shared test server every section above uses.
# It renames the session tests/lib.sh created from `0` to `conf`, adds a second
# session `side`, adds windows and panes, and turns automatic-rename off
# globally. A section added underneath would inherit all of that and would be
# debugging a renamed session it never created.
#
# It also leaves TMUX_TMPDIR exported, which is safe in every direction but is
# another piece of inherited state a later section should know about.
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
# because its own before-and-after sanity check saw the name change.
#
# What makes the fleet below fixed is TWO things, and neither of them is
# ordering -- roost_test_server has already created conf:0 by the time this
# line runs, so "before any window exists" would be false:
#
#   - `-g` sets the option's DEFAULT, and a window that has never set it
#     locally inherits that. conf:0 has not, so turning it off globally
#     reaches the already-created window as well as every later one.
#   - every window here is then explicitly renamed, and rename-window turns
#     automatic-rename off for that window as a side effect, which pins the
#     name whatever the global says.
#
# So the two renamed windows would have been safe on the second mechanism
# alone; the `-n api` window, which is created named and then renamed only to
# pin it, is the one that flaked before the global default covered it.
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
# WHY THIS PROVES THE FIXTURE USES $ROOST_SOCKET_FLAG, rather than passing by
# luck. Read this before changing either side of it.
#
# The contract hands an extension both the socket and the flag to address it
# with, because tmux needs -L for a socket NAME and -S for a socket PATH. That
# was not in contract 1's first draft; this fixture is what found it missing,
# and a fixture that then hardcoded a flag would have hidden the very defect it
# exists to surface.
#
# This server is addressed by PATH -- tests/lib.sh builds it under mktemp -d --
# so -S is the only flag that reaches it. A fixture that hardcoded `-L` would
# address a socket NAME that does not exist, print "roost: not running" where
# core prints a fleet, and fail loudly right here. That is the direction that
# matters most, because `-L` is the flag an author writes by hand: the
# production server's socket is the NAME `roost`, so a hardcoded `-L` is the
# mistake that WORKS on the machine the author tested on.
#
# The opposite mistake -- a hardcoded `-S` -- would pass against this server
# and break for every real user. So it is closed underneath, against a second
# server addressed by NAME. Both directions are behaviour, not a grep over the
# fixture's source; a grep hit would not be proof the line was live
# (AGENTS.md §9).
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
# Both halves of the claim, because the label makes two: that the two agree,
# and that what they agree on is nothing. Asserting only the first would let a
# future change make BOTH of them noisy and still read as a pass.
assert_eq "$(cat "$TMP/core-err")" "" "core roost status writes nothing to stderr"
assert_eq "$(cat "$TMP/ext-err")" "$(cat "$TMP/core-err")" \
  "...and the extension writes the same thing, which is therefore also nothing"

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

# --- the same comparison, against a server addressed by NAME ----------------
# The other half of the flag, and the half a suite built entirely on mktemp -d
# sockets cannot otherwise see. Every other server in this file is a PATH, so a
# fixture that hardcoded `-S` would be green everywhere above and wrong for
# every real user -- the production socket is the NAME `roost`.
#
# It is a throwaway server, and TMUX_TMPDIR is what makes addressing one BY
# NAME safe here: with it pointed inside $TMP, `-L <name>` resolves under the
# test directory instead of /tmp/tmux-<uid>, so this cannot collide with, read
# or disturb the author's live `-L roost` fleet (AGENTS.md §2) even by
# accident. The kill below names this socket explicitly, and the EXIT trap is
# re-armed to name it too so a mid-file failure cannot leave a server running.
conf_named="roost-conformance-named"
NT() { TMUX_TMPDIR="$CONF_TMUXTMP" tmux -L "$conf_named" "$@"; }
# Filled in HERE rather than at the top of the file: this is the line that
# creates the thing needing cleanup, and a teardown written next to what it
# tears down is one a later edit cannot leave behind. It names this socket
# explicitly -- AGENTS.md §2 -- and TMUX_TMPDIR keeps it inside a temp
# directory besides, so there is no arrangement of this line that could reach
# the author's live server.
conf_teardown() { NT kill-server 2>/dev/null; return 0; }
NT -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
# automatic-rename again, and here it can only be turned off AFTER the server
# exists -- there is no server to set an option on until new-session has run,
# so this ordering is forced rather than chosen and the option is briefly on.
# What makes this window safe is the rename two lines down: rename-window
# disables automatic-rename for the window as a side effect, and it runs before
# anything reads #{window_name}. The `-g` line is the belt-and-braces half,
# covering any window a later edit adds here without renaming it.
NT set-option -g automatic-rename off
NT rename-session -t '=0' named
NT rename-window -t '=named:0' solo
conf_np_a="$(NT list-panes -t '=named:0' -F '#{pane_id}')"
require_pane "$conf_np_a" "the named server's first pane"
conf_np_b="$(NT split-window -d -P -F '#{pane_id}' -t "$conf_np_a" 'ENV= exec /bin/sh')"
require_pane "$conf_np_b" "the named server's second pane"
NT set-option -p -t "$conf_np_a" @roost-name solo
NT set-option -p -t "$conf_np_b" @roost-name sidekick
NT set-option -p -t "$conf_np_b" @agent_state working

# WHERE that server actually landed, asserted rather than assumed, and this is
# the pair that would notice a future edit dropping TMUX_TMPDIR. The positive
# half comes first on purpose: "no socket in the real directory" is also what a
# detector aimed at the wrong path says, so make it find the socket where it is
# supposed to be before believing it about where it is not. The same shape
# tests/test-install.sh uses for its canary.
[ -S "$CONF_TMUXTMP/tmux-$(id -u)/$conf_named" ]
assert_true "$?" "the named server's socket really is inside the sandbox"
assert_file_absent "/tmp/tmux-$(id -u)/$conf_named" \
  "...and NOT in the real /tmp/tmux-<uid>/, beside the author's live agents"

conf_core="$(ROOST_SOCKET="$conf_named" PATH="$EXT_PATH" "$ROOST" status 2>"$TMP/core-err")"; rc=$?
assert_eq "$rc" "0" "core roost status runs against a server addressed by NAME"
assert_contains "$conf_core" "roost: running (socket=$conf_named)" \
  "core really reached the named server, so this comparison has something to compare"
conf_ext="$(ROOST_SOCKET="$conf_named" PATH="$EXT_PATH" "$ROOST" status-ext 2>"$TMP/ext-err")"; rc=$?
assert_eq "$rc" "0" "the rebuilt status extension runs against it too"
# The assertion that closes the hardcoded-`-S` direction: an extension using
# `-S` here would address a relative PATH called "roost-conformance-named",
# find no server, and print "roost: not running" while core printed a fleet.
assert_eq "$conf_ext" "$conf_core" \
  "the extension reproduces roost status BYTE FOR BYTE on a NAME-addressed server too"
# Symmetric with the path-addressed comparison above: core's stderr is checked
# too, not just the extension's. A comparison that only ever looked at one side
# could not tell "both silent" from "both noisy in the same way".
assert_eq "$(cat "$TMP/core-err")" "" "core writes nothing to stderr on the named server"
assert_eq "$(cat "$TMP/ext-err")" "$(cat "$TMP/core-err")" \
  "...and the extension writes the same thing there too"
NT kill-server 2>/dev/null
conf_teardown() { :; }

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

# --- the same conformance check, THROUGH A REAL INSTALL ---------------------
# Everything above this line in the conformance block installed its fixtures
# by hand: ext.lock written here, ext.index derived from it. That proved the
# CONTRACT -- what the seam hands an extension is enough to rebuild a command
# roost already ships, byte for byte.
#
# This proves the PIPELINE that delivers it. `roost ext install` resolves a
# ref to a commit, clones it hardened, validates the manifest, asks, moves the
# tree into place and writes both files; every one of those steps handles the
# extension's own bytes, and any of them could corrupt what arrives -- a lost
# executable bit, a mangled path, an authority that did not survive the trip
# from the manifest to the fourth column of ext.index. The comparison is worth
# running a second time for exactly that reason, and it is the cheapest
# possible end-to-end test of the whole command.
#
# The hand-installed copy is taken back off the disk first: the fixture claims
# the name `status-ext` and the command `status-ext`, and install refuses a
# name that is already in the lockfile -- which is itself the behaviour being
# relied on here rather than worked around.
rm -f "$EXT_STATE_ROOT/ext.lock"
roost_ext_index_write
rm -rf "$EXT_DATA/status-ext"

conf_pub="$TMP/conf-publish"
rm -rf "$conf_pub"; mkdir -p "$conf_pub"
# A COPY, published from $TMP. Never the fixture directory in the checkout:
# `git init` inside tests/fixtures/ would put a repository inside this
# repository, and the first person to run the suite would find it in
# `git status`.
cp -R "$CONF_FIX/ext-status/." "$conf_pub/"
ext_publish fix/status "$conf_pub" v1.0.0

conf_install="$(ext_install fix/status --ref v1.0.0 --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "the conformance fixture installs through the real pipeline"
assert_eq "$(cat "$TMP/err")" "" "...with nothing on stderr"
assert_contains "$conf_install" "This extension asks to drive your agents" \
  "...and the consent block named the authority it was about to be granted"

# The authority survived the trip: manifest -> ext.lock -> ext.index, resolved
# once by a real JSON parser and carried forward. This is the column the
# dispatcher acts on, and nothing else in this file checks it on a lockfile an
# INSTALLER wrote rather than one this test wrote.
assert_eq "$(conf_needs status-ext)" "fleet" \
  "a real install grants the fleet in column 4 of ext.index"
assert_eq "$(ext_index_col status-ext 3)" "$EXT_DATA/status-ext/bin/roost-status-ext" \
  "...and points at the installed executable"
# The executable bit is the one that would be lost silently: the dispatcher's
# lookup treats a non-executable path as a miss and falls through to the usage
# error, which reads exactly like a typo.
[ -x "$EXT_DATA/status-ext/bin/roost-status-ext" ]
assert_true "$?" "the installed program is still executable after the trip through git and mv"

conf_core="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" status 2>"$TMP/core-err")"; rc=$?
assert_eq "$rc" "0" "core roost status still exits 0 against the conformance fleet"
conf_ext="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" status-ext 2>"$TMP/ext-err")"; rc=$?
assert_eq "$rc" "0" "the INSTALLED status extension exits 0 against the same fleet"
# Checked before the comparison, for the reason the hand-installed run checks
# it: two empty strings compare equal, so an assertion that only says "these
# match" passes loudest exactly when both sides have broken.
assert_contains "$conf_core" "roost: running (socket=$ROOST_TEST_SOCK)" \
  "core really printed a fleet, so this comparison has something to compare"
assert_eq "$conf_ext" "$conf_core" \
  "an extension delivered by roost ext install reproduces roost status BYTE FOR BYTE"
assert_eq "$(cat "$TMP/ext-err")" "$(cat "$TMP/core-err")" \
  "...and writes the same nothing to stderr"

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
