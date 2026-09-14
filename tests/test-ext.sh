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
# later task — so it is pinned from the first commit of this feature, before
# anything writes to it, rather than added the day something does.
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
# report it through yet, that arrives with the seam itself. Without this,
# nothing fails if the line is deleted, and the dispatcher and every `roost
# ext` verb version-gate on it being there.
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
# from the dispatcher, which takes `needs` from ext.index, and nothing
# validates ext.index.
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
  # THE EXPONENT LITERALS THE TWO ENGINES ACTUALLY DISAGREED ABOUT. `1e2` is
  # the one exponent form they always agreed on -- decNumber prints it
  # `1E+2`, which fails the pure-digits test on jq, and python3 refused the
  # float -- so the case above could sit here green while `1e0` installed as
  # contract 1 on a jq machine and was refused on a python3 one. Measured on
  # jq-1.7.1-apple: all four of these print as `1`.
  parity_case "a contract of 1e0" \
    '{ "name": "mark", "contract": 1e0, "commands": ["mark"] }'
  parity_case "a contract of 1E0" \
    '{ "name": "mark", "contract": 1E0, "commands": ["mark"] }'
  parity_case "a contract of 1e00" \
    '{ "name": "mark", "contract": 1e00, "commands": ["mark"] }'
  parity_case "a contract of 0.1e1" \
    '{ "name": "mark", "contract": 0.1e1, "commands": ["mark"] }'
  parity_case "a contract of 1.0" \
    '{ "name": "mark", "contract": 1.0, "commands": ["mark"] }'
  parity_case "a contract of 10e-1" \
    '{ "name": "mark", "contract": 10e-1, "commands": ["mark"] }'
  parity_case "a contract of negative zero" \
    '{ "name": "mark", "contract": -0, "commands": ["mark"] }'
  parity_case "a contract too big for a double" \
    '{ "name": "mark", "contract": 123456789012345678901234567890, "commands": ["mark"] }'

  # A KNOWN DIVERGENCE, ASSERTED AS ONE. Everything else in this harness
  # asserts that the engines AGREE; these three assert that they do not, and
  # they are here so the gap is pinned rather than remembered.
  #
  # A leading-zero literal is not valid JSON. python3 refuses the whole
  # document; jq's parser takes it. So `"contract": 001` reads as contract `1`
  # on a jq machine -- which PASSES the hard gate and installs -- and is
  # refused outright on a python3 one. The divergence is therefore in the
  # version gate itself, not in some corner of the reader.
  #
  # It cannot be closed in these engines: by the time the expression sees a
  # number, jq has consumed the literal and `001` is indistinguishable from
  # `1` in its value model. Recorded in docs/known-gaps.md. If either engine
  # ever changes, these go red and the entry gets revisited -- which is the
  # whole reason to assert a divergence instead of leaving it in prose.
  #
  # `007` is NOT the case to use here. jq reads it as 7, 7 is not 1, so its
  # gate refuses too and the outcome coincides -- the same selection bias that
  # let `1e2` stand in for the exponent forms while four of them diverged.
  printf '%s\n' '{ "name": "mark", "contract": 001, "commands": ["mark"] }' > "$MAN/parity.json"
  roost_ext_manifest_read "$MAN/parity.json" >"$TMP/lz-py.out" 2>/dev/null; lz_py_rc=$?
  PATH="$TMP/jq-only"
  roost_ext_manifest_read "$MAN/parity.json" >"$TMP/lz-jq.out" 2>/dev/null; lz_jq_rc=$?
  PATH="$saved_path"
  assert_eq "$lz_py_rc" "1" \
    "a leading-zero contract is refused by python3 — 001 is not valid JSON, so the document is"
  assert_eq "$lz_jq_rc" "0" \
    "...and ACCEPTED by jq, whose parser is more permissive: a known divergence, see docs/known-gaps.md"
  assert_eq "$(sed -n 's/^contract=//p' "$TMP/lz-jq.out")" "1" \
    "...read as contract 1, which passes the hard gate — the same manifest installs on jq and is refused on python3"
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
  parity_case "a roost range past its length cap" \
    '{ "name": "mark", "contract": 1, "commands": ["mark"], "roost": ">=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }'
  parity_case "a roost range exactly at its length cap" \
    '{ "name": "mark", "contract": 1, "commands": ["mark"], "roost": ">=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }'
  parity_case "a description past its length cap" \
    '{ "name": "mark", "contract": 1, "commands": ["mark"], "description": "ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" }'
  parity_case "a field that is both too long and carries a control character" \
    '{ "name": "mark", "contract": 1, "commands": ["mark"], "roost": ">=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u001bZ" }'
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
  # EVERY case above is about `needs`, and that is how the divergence below
  # survived: the engines disagreed about an entry NAME, which nothing here
  # asked them. An empty key made the jq engine write an index and stay
  # silent where python3 refused and raised the SECURITY WARNING -- because
  # `test("\\s")` is false for the empty string and `"".split() != [""]` is
  # true. The cases below ask the same question of the other two fields this
  # function refuses on, so a one-engine regression in any of them is caught
  # by the harness rather than by whoever happens to read both engines again.
  index_parity_case "an empty entry name" \
    '{ "": { "commands": ["mark"] } }'
  index_parity_case "an entry name with whitespace in it" \
    '{ "two words": { "commands": ["mark"] } }'
  index_parity_case "an entry name containing a slash" \
    '{ "../secret": { "commands": ["mark"] } }'
  index_parity_case "an entry that is not an object" \
    '{ "mark": "mark" }'
  index_parity_case "an entry with no commands field at all" \
    '{ "mark": { "repo": "o/mark" } }'
  index_parity_case "an empty commands array" \
    '{ "mark": { "commands": [] } }'
  index_parity_case "a commands that is not an array" \
    '{ "mark": { "commands": "mark" } }'
  index_parity_case "an empty command" \
    '{ "mark": { "commands": [""] } }'
  index_parity_case "a command with whitespace in it" \
    '{ "mark": { "commands": ["two words"] } }'
  index_parity_case "a command containing a slash" \
    '{ "mark": { "commands": ["../secret"] } }'
  index_parity_case "a command that is not a string" \
    '{ "mark": { "commands": [1] } }'
  index_parity_case "two entries claiming one command" \
    '{ "a": { "commands": ["x"] }, "b": { "commands": ["x"] } }'
  index_parity_case "a top-level array" \
    '[ "mark" ]'
  index_parity_case "two well-formed entries, one of them claiming two commands" \
    '{ "a": { "commands": ["a1", "a2"], "needs": ["fleet"] }, "b": { "commands": ["b1"] } }'
  # The escaping and the cap on these engines' refusal messages, compared
  # between the engines rather than only against a literal: both had to grow
  # esc() at the same time, and a fix applied to one of them is exactly the
  # kind of half-landing this harness exists to catch. The payload is written
  # as a JSON \u001b escape, never as a literal byte, for the reason the
  # consent-block section further down gives: a raw ESC in a source file is
  # invisible in the diff of the change that adds it.
  index_parity_case "an entry name carrying an escape sequence" \
    '{ "a\u001b[2A\u001b[1G b": { "commands": ["x"] } }'
  index_parity_case "a command carrying an escape sequence, in a collision" \
    '{ "a": { "commands": ["x\u001bZ"] }, "b": { "commands": ["x\u001bZ"] } }'
  idx_long_a=""
  while [ "${#idx_long_a}" -lt 300 ]; do idx_long_a="${idx_long_a}A"; done
  index_parity_case "an entry name past the message cap" \
    "$(printf '{ "%s x": { "commands": ["x"] } }' "$idx_long_a")"
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
# `|ext|` arrived with the wiring in bin/roost's `ext)` case arm -- this
# literal has to move in lockstep with that arm's usage string or this
# assertion stops meaning anything.
usage_want='usage: roost [up|session NAME|new NAME [SESSION]|spawn NAME [CMD]|split [-h|-v] [-t P] [-n NAME] [CMD]|view [-n NAME] CMD...|whoami|ssh HOST|send [--force] TGT TEXT|read [-r|--render] TGT [N]|screen TGT [N]|reply TEXT|wait-done TGT [T]|state STATE|hooks|doctor|validate|ext|install|update|init|settings|status|kill [SESSION]|--version|help]'

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

# --- and the OTHER list of subcommands, which nothing pinned to this one ----
# `roost help` does not repeat the usage string: it is generated by awk-ing
# bin/roost's own header comment, so a verb can be added to one list and not
# the other with every test in this repository still green. That has now
# happened twice on this branch -- `--version` was added to the usage string
# and not the header, and so was `ext`, whose brief said "add `ext` to the
# usage string" and whose suite pinned that string byte for byte while
# asserting nothing at all about `roost help`.
#
# So the two lists are pinned TO EACH OTHER rather than each to a literal.
# The verbs are read out of `usage_want` above -- bracketed groups stripped
# first, innermost outwards, because `split [-h|-v]` carries a `|` of its own
# inside one -- and every one of them has to have its own line in the help
# block. A `grep -w` over the whole help text would not do: "read", "status"
# and "install" all appear in that block's prose, so the match is anchored to
# the `roost <verb>` line the header format guarantees.
usage_verbs="$(printf '%s\n' "$usage_want" \
  | sed -e 's/^usage: roost \[//' -e 's/\]$//' \
  | sed -e ':a' -e 's/\[[^][]*\]//g' -e 'ta' \
  | tr '|' '\n' | awk 'NF { print $1 }')"
# Checked before it is trusted, the same shape as the comment-filter probe
# further down: a sed that stripped too much would leave a short list and
# every check below would pass for the wrong reason.
assert_eq "$(printf '%s\n' "$usage_verbs" | wc -l | tr -d ' ')" "26" \
  "the usage string parses into the 26 verbs it names"
help_text="$(ROOST_BANNER=blocks "$ROOST" help 2>/dev/null)"
assert_contains "$help_text" "roost session NAME" \
  "roost help really produced its command block, so what follows means something"
usage_undocumented=""
for verb in $usage_verbs; do
  if printf '%s\n' "$help_text" | grep -q "^  roost $verb\([ ]\|\$\)"; then
    continue
  fi
  usage_undocumented="$usage_undocumented $verb"
done
# EXACTLY `up`, not "at most" -- an exact expectation is what turns a newly
# undocumented verb red, and `up` earns its exemption by being the one verb
# whose documentation is the BARE `roost` line (pinned just below), since it
# is what `roost` with no arguments runs. Documenting it on a line of its own
# would turn this red too, which is the right kind of loud.
assert_eq "$usage_undocumented" " up" \
  "every verb in the usage string has its own line in roost help, except up"
printf '%s\n' "$help_text" | grep -q '^  roost  *start/attach the default session'
assert_true "$?" "...and up's line is the bare 'roost' one, which is why it is the exception"

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

# THE DETECTOR IS SHOWN TO FIND SOMETHING BEFORE IT IS BELIEVED ABOUT FINDING
# NOTHING -- the pair further down this file (the NAME-addressed conformance
# server) has the same shape, and it is here for the reason that one gives.
# The two `assert_file_absent`s below were, on their own, checks that could
# not fail: the dispatcher's only tmux call before it `exec`s is
# `show-options`, which creates the `tmux-<uid>` DIRECTORY but never a socket
# file in it, so nothing the probe does could have put one at the path they
# name -- and a detector aimed at the wrong path says exactly the same thing.
#
# A server is started here at a name of its own, under the same
# $TMUX_TMPDIR, so the PATH FORMULA those two use is measured rather than
# assumed: a real `-L <name>` server lands at exactly
# `$TMUX_TMPDIR/tmux-<uid>/<name>`. That is what makes ABSENCE at that path
# mean "no server was ever started here" rather than "this detector is
# pointed somewhere nothing was ever going to appear". The name differs from
# the one under test because no server is ever meant to exist at THAT name;
# what carries over is the directory, which is what a dropped TMUX_TMPDIR
# would move.
#
# Only the positive half is asserted, and that is a measurement rather than
# an omission: on tmux 3.6 the socket FILE survives `kill-server` -- measured
# directly, `ls` still shows it immediately afterwards. So presence would not
# have meant "still running", while absence still means nothing ever created
# it, which is the direction both assertions below rely on.
conf_probe_sock="roost-conformance-path-proof"
# Named socket, inside TMUX_TMPDIR, with roost_test_tmux_named_guard already
# passed above -- AGENTS.md §2. The teardown is written next to the line that
# creates the thing needing it, the same way the conformance server's is.
conf_teardown() { TMUX_TMPDIR="$CONF_TMUXTMP" tmux -L "$conf_probe_sock" kill-server 2>/dev/null; return 0; }
TMUX_TMPDIR="$CONF_TMUXTMP" tmux -L "$conf_probe_sock" -f /dev/null new-session -d -x 80 -y 24 'ENV= exec /bin/sh'
[ -S "$CONF_TMUXTMP/tmux-$(id -u)/$conf_probe_sock" ]
assert_true "$?" "a -L server in this sandbox lands at exactly the path the two assertions below check"
TMUX_TMPDIR="$CONF_TMUXTMP" tmux -L "$conf_probe_sock" kill-server 2>/dev/null
conf_teardown() { :; }
rm -f "$CONF_TMUXTMP/tmux-$(id -u)/$conf_probe_sock"

out="$(ROOST_SOCKET="$conf_named_sock" PATH="$EXT_PATH" "$ROOST" probe 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "7" "an extension runs when the socket is a NAME rather than a path"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$conf_named_sock" \
  "a socket name is handed over verbatim"
assert_eq "$(ext_field "$out" ROOST_SOCKET_FLAG)" "-L" \
  "...and a socket NAME is handed over as -L, where a path is handed over as -S"
# Proof that the paragraph above is true rather than merely believed: if that
# show-options call had started a server, this is where the socket would be --
# a path the pair above has just watched a real server appear at and vanish
# from.
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
# The rule, and `roost ext list` and `roost ext verify` both depend on it:
# whatever writes ext.lock regenerates ext.index in the SAME operation. `roost ext list` warning when
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
# ext.INDEX, not ext.lock, and the distinction is this branch's central
# security claim rather than a detail: the dispatcher reads the authority an
# extension runs with out of ext.index alone and never opens ext.lock again.
# `lock_fleet` above writes the lockfile AND regenerates the index from it in
# the same call, which is why the grant is here to be found at all. These two
# labels used to say "out of ext.lock", which is exactly backwards -- a
# lockfile read on this path is the bug the index column exists to prevent.
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" \
  "...and the fleet grant is read out of ext.index without a JSON tool"
lock_no_needs
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$TMP/no-json" "$ROOST" probe 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "...and so is the refusal to grant it, out of the same file"

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
# this feature has, not only the ones that were wired first. Breaks if the case in scripts/roost-ext stops listing all six, or if
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

# --- list: THE COLUMN HEADER -------------------------------------------------
# The columns are name, commit and commands, and for the commonest extension
# there is -- one command, named after itself -- the first and the third are
# the same word: `mark  e87807c  mark`. A reader took that for one row printed
# twice, which is a fair reading of three unlabelled columns. The header is
# what says which question each column answers.
#
# It is asserted to LINE UP as well as to exist. A header that drifted out of
# alignment with the rows under it would be the same defect wearing a label,
# so the offsets are compared rather than eyeballed: where COMMIT begins in
# the header is where a row's commit has to begin.
list_head="$(printf '%s\n' "$out" | head -1)"
assert_contains "$list_head" "NAME" "roost ext list prints a column header"
assert_contains "$list_head" "COMMIT" "...naming the commit column"
assert_contains "$list_head" "COMMANDS" "...and the commands column"

alpha_row="$(printf '%s\n' "$out" | grep '^alpha ')"
beta_row="$(printf '%s\n' "$out" | grep '^beta ')"
head_commit_pre="${list_head%%COMMIT*}"
alpha_commit_pre="${alpha_row%%1111111*}"
assert_eq "${#alpha_commit_pre}" "${#head_commit_pre}" \
  "a row's commit starts in the column COMMIT names"
head_cmds_pre="${list_head%%COMMANDS*}"
beta_cmds_pre="${beta_row%%beta, beta2*}"
assert_eq "${#beta_cmds_pre}" "${#head_cmds_pre}" \
  "a row's commands start in the column COMMANDS names"
assert_eq "$(printf '%s\n' "$out" | grep -c '^NAME ')" "1" \
  "the header is printed once, not once per row"

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
# A security property `roost ext list` exists to surface, not merely a
# formatting one: the dispatcher (bin/roost's `*)` fallback) obeys
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
# Task 7's requirement item 3: cheap to check while the user is already
# looking at this warning, and a DIFFERENT question from the one the warning
# itself answers -- deleting the two `printf` lines that add this would leave
# the suite green without this assertion, which is exactly the "a pin that
# passes while the thing it pins is gone" shape the clone-flag assertions in
# this file already ran into once.
assert_contains "$gamma_warn" "roost ext verify" \
  "the disagreement warning also suggests running roost ext verify"
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
assert_eq "$bare_line" "bare  -        bare" "list renders a genuinely absent commit as the literal placeholder '-', not an empty or shifted field"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext info bare 2>"$TMP/err")"
assert_contains "$out" "  repo       -" "info renders a genuinely absent repo as '-'"
assert_contains "$out" "  ref        -" "...ref too"
assert_contains "$out" "  commit     -" "...commit too"
assert_contains "$out" "  needs      none" "...but needs gets the word 'none', not the bare placeholder"
rm -rf "$EXT_DATA/bare"
rm -f "$(roost_ext_lock)"
roost_ext_index_write

# The OTHER half of `scalar()`'s `or "-"`, which the case above cannot reach:
# a key that is PRESENT with the empty string, rather than absent. Deleting
# `or "-"` leaves the absent half covered by the "bare" assertion above and
# this half uncovered -- measured, and the suite stayed green -- so an empty
# `ref` is asserted here as the rendered line. Without the placeholder the
# row's later columns shift one to the left and the commands column prints
# the placeholder instead of `x`.
mkdir -p "$EXT_DATA/emptyref/bin"
: > "$EXT_DATA/emptyref/bin/roost-x"; chmod +x "$EXT_DATA/emptyref/bin/roost-x"
lock_install <<'JSON'
{ "emptyref": { "repo": "o/a", "ref": "", "commands": ["x"] } }
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"
emptyref_line="$(printf '%s\n' "$out" | grep '^emptyref ')"
assert_eq "$emptyref_line" "emptyref  -        x" \
  "a field recorded as the EMPTY STRING renders as '-' too, and shifts nothing after it"
rm -rf "$EXT_DATA/emptyref"
rm -f "$(roost_ext_lock)"
roost_ext_index_write

# THE ENTRY NAME IS A FIELD OF THAT ROW TOO, and it is the one that never
# passed through `scalar()`. An empty lockfile KEY shifted all nine columns
# one to the left: `roost ext list` printed the REPOSITORY where the name
# goes, and the disagreement warning below named an empty list of extensions.
# Both engines did it, so the parity harness further down could not catch it
# -- it compares the two engines with each other, and they agreed.
#
# The lockfile is written directly rather than through lock_install: an empty
# key is exactly what roost_ext_index_write refuses, which is the second half
# of what this case is about.
cat > "$(roost_ext_lock)" <<'JSON'
{ "": { "repo": "o/x", "commands": ["x"], "needs": ["fleet"] } }
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>"$TMP/err")"
assert_eq "$out" "$(printf 'NAME  COMMIT   COMMANDS\n-     -        x (invalid name, not something roost ext install could have written)')" \
  "an EMPTY lockfile key renders as the placeholder in the name column, not as the repository"
assert_contains "$(cat "$TMP/err")" "disagree: -" \
  "...and the disagreement warning names that entry rather than an empty list"
rm -f "$(roost_ext_lock)"
roost_ext_index_write

# --- list: the header keeps the table inside 80 columns ---------------------
# The name column is measured from the widest name, so a single absurd name
# could otherwise pad EVERY other row out past a terminal's width. It is
# capped at 32 -- the longest name `roost ext install` can write -- and a
# longer one, which can only have come from a lockfile edited by hand,
# overflows its own row instead of the whole table.
#
# 32 + 2 + 7 + 2 puts the commands column at 43, which is what this asserts:
# the worst case this feature can produce leaves 37 columns for commands on
# an 80-column terminal.
mkdir -p "$EXT_DATA/short/bin"
: > "$EXT_DATA/short/bin/roost-shortcmd"; chmod +x "$EXT_DATA/short/bin/roost-shortcmd"
cat > "$(roost_ext_lock)" <<'JSON'
{
  "short": { "repo": "o/s", "commit": "3333333333333333333333333333333333333333", "commands": ["shortcmd"] },
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": { "repo": "o/l", "commands": ["long"] }
}
JSON
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" "$ROOST" ext list 2>/dev/null)"
list_head="$(printf '%s\n' "$out" | head -1)"
head_cmds_pre="${list_head%%COMMANDS*}"
assert_eq "${#head_cmds_pre}" "43" \
  "a name longer than install could write pads the header no further than 32 columns"
short_row="$(printf '%s\n' "$out" | grep '^short ')"
# Stripped on the COMMANDS value, which is deliberately not the name here:
# `${row%%short*}` would cut at the name in column one and measure nothing.
short_cmds_pre="${short_row%%shortcmd*}"
assert_eq "${#short_cmds_pre}" "43" "...and an ordinary row still lines up under it"
assert_eq "${#list_head}" "51" "...so the header itself is well inside 80 columns"
rm -rf "$EXT_DATA/short"
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
  # The EMPTY key, next to the tab one: the tab case is about a name both
  # engines refuse, this one about a name both engines have to render as the
  # placeholder rather than as an empty field that shifts the row.
  _ext_lock_rows_parity_case "an empty lockfile key" \
    '{ "": { "repo": "o/x", "commit": "abcdef0123456789", "commands": ["x"] } }'
  _ext_lock_rows_parity_case "an explicit null ref" \
    '{ "a": { "repo": "o/a", "commands": ["x"], "ref": null } }'
  _ext_lock_rows_parity_case "an explicit null needs" \
    '{ "a": { "repo": "o/a", "commands": ["x"], "needs": null } }'
  _ext_lock_rows_parity_case "an explicit null commands" \
    '{ "a": { "repo": "o/a", "commands": null } }'
  # `contract` is the one field of a lockfile row a JSON NUMBER can reach, so
  # this engine pair has the same number-model question the manifest pair had:
  # jq reads `1e0` as `1` and a python3 on floats read it as a float and
  # refused the file. Both engines parse numbers with the same decimal model
  # now; these are the literals that told the two apart.
  _ext_lock_rows_parity_case "a contract of 1e0" \
    '{ "a": { "repo": "o/a", "commands": ["x"], "contract": 1e0 } }'
  _ext_lock_rows_parity_case "a contract of 0.1e1" \
    '{ "a": { "repo": "o/a", "commands": ["x"], "contract": 0.1e1 } }'
  _ext_lock_rows_parity_case "a fractional contract" \
    '{ "a": { "repo": "o/a", "commands": ["x"], "contract": 1.5 } }'
  _ext_lock_rows_parity_case "a contract in exponent form jq prints as 1E+2" \
    '{ "a": { "repo": "o/a", "commands": ["x"], "contract": 1e2 } }'
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

# THE NAME TO TYPE NEXT. `fix/good` installs as `demo`: the name comes from
# the manifest and is under no obligation to match the repository the user
# typed. Someone who installed one repository and then reasonably typed the
# repository's own name back at `roost ext update` was told "no such
# extension" -- true, useless, and the name they needed was sitting mid
# sentence in the first line of this output, which is not where anyone looks
# for something to copy. So it is printed as a line to type.
assert_contains "$good_out" "manage:    roost ext info|update|remove demo" \
  "the install prints, as a line to type, the name every other verb takes"
assert_contains "$good_out" "that name comes from the manifest, not from fix/good" \
  "...and says that name is the manifest's, not the repository that was typed"

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
#
# ONE LIST, shared with `roost ext verify`'s own check further down this file.
# They were written separately and drifted: install's had eleven words and
# verify's had five, so `verified`, `secure`, `trusted`, `vetted`, `audited`,
# `approved` and `legitimate` were forbidden in the consent block and allowed
# in the one command whose entire job is to report on integrity -- the output
# a reassuring adjective would do the most damage in. A list per call site is
# a list that drifts; there is one here now, and each site adds only what is
# specific to it.
EXT_VERDICT_WORDS="safe clean scanned verified trusted trustworthy secure vetted audited approved legitimate"
consent_all="$(printf '%s\n%s\n' "$good_out" "$quiet_out" | tr 'A-Z' 'a-z')"
for verdict in $EXT_VERDICT_WORDS; do
  case "$consent_all" in
    *"$verdict"*) verdict_hit=1 ;;
    *) verdict_hit=0 ;;
  esac
  assert_eq "$verdict_hit" "0" "no install output reads as a verdict on the code: [$verdict]"
done

# --- the consent block is printed to a TERMINAL, and a terminal interprets --
# THE MOST SERIOUS FINDING OF THIS BRANCH, kept as two live payloads rather
# than as a sentence in a report.
#
# `roost` and `description` are the only free-text fields in a manifest, and
# `install` prints the first one verbatim in the plan block. The manifest
# reader used to refuse only \n and \r -- enough to protect its own KEY=VALUE
# line protocol, and nothing at all to protect the terminal the value is
# ultimately printed to. ESC is not a character there; it is an instruction.
#
# Payload one REPAINTS the commit row: cursor up two, column one, a forged
# `commit 0000000...  (pinned)`, erase to end of line, cursor back down. The
# user reads a commit that was never resolved, never cloned, never
# HEAD-verified and never written to ext.lock -- and consents to it. That
# defeats integrity at the one point where integrity is COMMUNICATED, which
# makes every control downstream of the prompt worth nothing.
#
# Payload two is cruder and needs no cursor arithmetic: SGR 8 is conceal, so
# everything after it -- the authority paragraph, the honesty paragraph and
# the prompt itself -- is rendered invisible while the install proceeds.
#
# Every payload here is written as a JSON \u001b escape and never as a literal
# byte: a raw ESC in a source file is invisible in the diff of the change that
# would remove it, which is the review this file cannot afford to lose.
#
# The assertions are written against the OUTPUT, not against the reader: what
# has to be true is that no escape sequence and no forged commit row ever
# reaches a user's terminal, whichever layer stops it.
esc="$(printf '\033')"
ext_src "$EXT_SRCS/repaint" '{ "name": "repaint", "contract": 1, "roost": "*\u001b[2A\u001b[1G  commit   0000000...  (pinned)\u001b[K\u001b[2B\u001b[1G", "commands": ["repaint"] }' repaint
ext_publish fix/repaint "$EXT_SRCS/repaint"
out_repaint="$(ext_install fix/repaint --yes 2>"$TMP/err")"; rc=$?
repaint_all="$(printf '%s\n%s\n' "$out_repaint" "$(cat "$TMP/err")")"
[ "$rc" -ne 0 ]
assert_true "$?" "install refuses a manifest whose roost field carries an escape sequence"
assert_contains "$(cat "$TMP/err")" "contains a control character" "...naming the reason"
case "$repaint_all" in
  *"$esc"*) esc_leaked=1 ;;
  *) esc_leaked=0 ;;
esac
assert_eq "$esc_leaked" "0" "...and no ESC byte reaches the terminal, on either stream"
case "$repaint_all" in
  *"0000000...  (pinned)"*) forged=1 ;;
  *) forged=0 ;;
esac
assert_eq "$forged" "0" "...so the forged commit row is never printed"
assert_file_absent "$EXT_DATA/repaint" "...and nothing is installed"

# The other half of the same claim, and the half that makes it mean something:
# an HONEST manifest still shows the real commit. Asserting only that the
# forgery is absent would pass on a build that printed no commit row at all.
assert_contains "$good_out" "  commit   ${good_sha:0:7}...  (pinned)" \
  "...while an honest manifest still shows the commit that was really resolved"
case "$good_out" in
  *"0000000...  (pinned)"*) forged=1 ;;
  *) forged=0 ;;
esac
assert_eq "$forged" "0" "...and only that one"

ext_src "$EXT_SRCS/conceal" '{ "name": "conceal", "contract": 1, "roost": ">=0.1.0 <9.0.0\u001b[8m", "commands": ["conceal"] }' conceal
ext_publish fix/conceal "$EXT_SRCS/conceal"
out_conceal="$(ext_install fix/conceal --yes 2>"$TMP/err")"; rc=$?
conceal_all="$(printf '%s\n%s\n' "$out_conceal" "$(cat "$TMP/err")")"
[ "$rc" -ne 0 ]
assert_true "$?" "install refuses a manifest whose roost field would conceal the rest of the block"
case "$conceal_all" in
  *"$esc"*) esc_leaked=1 ;;
  *) esc_leaked=0 ;;
esac
assert_eq "$esc_leaked" "0" "...with no ESC byte on either stream"
assert_file_absent "$EXT_DATA/conceal" "...and nothing installed"

# `description` is the same class, and it reaches a terminal through
# `roost ext info`'s manifest section rather than through the consent block.
# One reader, one rule, both call sites.
ext_src "$EXT_SRCS/descesc" '{ "name": "descesc", "contract": 1, "commands": ["descesc"], "description": "tidy\u001b[2Kforged" }' descesc
ext_publish fix/descesc "$EXT_SRCS/descesc"
out_desc="$(ext_install fix/descesc --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "install refuses an escape sequence in description too"
assert_contains "$(cat "$TMP/err")" "contains a control character" "...naming the same reason"

# And the lockfile side of the same rule: `roost ext list` and `roost ext info`
# print ext.lock's own fields to the same terminal. Reaching this needs write
# access to the user's state directory already -- install writes every one of
# those fields from a validated alphabet -- so it is the weaker half of the
# pair, and it is closed anyway.
lock_saved="$(cat "$(roost_ext_lock)")"
printf '%s\n' '{ "esc": { "repo": "o/esc", "ref": "v1\u001b[2A\u001b[1Gforged", "commands": ["esc"] } }' > "$(roost_ext_lock)"
out_lockesc="$("$HERE/scripts/roost-ext" list 2>"$TMP/err")"; rc=$?
lockesc_all="$(printf '%s\n%s\n' "$out_lockesc" "$(cat "$TMP/err")")"
[ "$rc" -ne 0 ]
assert_true "$?" "roost ext list refuses a lockfile field carrying an escape sequence"
assert_contains "$(cat "$TMP/err")" "control character" "...naming the reason"
case "$lockesc_all" in
  *"$esc"*) esc_leaked=1 ;;
  *) esc_leaked=0 ;;
esac
assert_eq "$esc_leaked" "0" "...and prints no ESC byte on either stream"
printf '%s\n' "$lock_saved" > "$(roost_ext_lock)"
roost_ext_index_write

# THE THIRD ENGINE PAIR, and the one that decides a GRANT. The two engines
# behind roost_ext_index_write name the lockfile's entry name and command
# back to the reader in every refusal, and both interpolated them RAW while
# the _ext_lock_rows pair above had carried esc() on every message since it
# was written. Same class, same destination -- roost_ext__json_read prints
# that message to stderr, and stderr is a terminal.
#
# Not a display path this time: this is the regeneration-failure path of
# install, update and remove, since every command that writes ext.lock
# regenerates ext.index in the same step.
lock_saved="$(cat "$(roost_ext_lock)")"
printf '%s\n' '{ "a\u001b[2A\u001b[1G b": { "commands": ["x"] } }' > "$(roost_ext_lock)"
roost_ext_index_write 2>"$TMP/err"; rc=$?
idx_esc_err="$(cat "$TMP/err")"
assert_eq "$rc" "1" "index_write refuses an entry name carrying an escape sequence"
case "$idx_esc_err" in
  *"$esc"*) esc_leaked=1 ;;
  *) esc_leaked=0 ;;
esac
assert_eq "$esc_leaked" "0" "...and no ESC byte from ext.lock reaches the terminal"
assert_contains "$idx_esc_err" "a?[2A?[1G b" \
  "...the offending name is still shown, with its control bytes replaced rather than dropped"

# The length half of the same rule, which needs no control character at all:
# 64 characters and then `...`, the cap roost_ext__manifest_py's CAPS table
# already applies to `roost` and `description` for the same reason. Nothing
# honest gets near it -- roost_ext_name_valid stops a real name at 32.
idx_long_a=""
while [ "${#idx_long_a}" -lt 300 ]; do idx_long_a="${idx_long_a}A"; done
idx_want64=""
while [ "${#idx_want64}" -lt 64 ]; do idx_want64="${idx_want64}A"; done
printf '{ "%s x": { "commands": ["x"] } }\n' "$idx_long_a" > "$(roost_ext_lock)"
roost_ext_index_write 2>"$TMP/err"; rc=$?
assert_eq "$rc" "1" "index_write refuses a 300-character entry name with a space in it"
assert_contains "$(cat "$TMP/err")" "entry name '$idx_want64...' is not a plain word" \
  "...and the message it prints is truncated at 64 characters, not 300"
printf '%s\n' "$lock_saved" > "$(roost_ext_lock)"
roost_ext_index_write

# --- a field long enough to scroll the pin off the screen -------------------
# The same attack as the escape payloads above, by OMISSION rather than by
# forgery, and it needs no control character at all -- no ESC, no C1, no bidi.
# `roost` is printed verbatim in the plan block, and a 1349-character value
# pushes the `commit ...  (pinned)` row off an 80x24 terminal by the time the
# prompt is drawn. Measured at the moment the user answers: the prompt is
# visible and the pinned row is not. The block never states anything false; it
# stops stating the pin at all, and a user asked to approve a commit that is
# no longer on screen has consented to nothing.
#
# Every other free-text-adjacent value here was already bounded -- a ref at
# 255, a name and every command at 32 -- and this one was not.
ext_repeat() {
  # ext_repeat CHAR N -> N copies of CHAR. Doubling rather than appending one
  # at a time: 1349 iterations of string concatenation in bash is slow enough
  # to notice in a suite that runs on every change.
  local c="$1" n="$2" out="$1"
  while [ "${#out}" -lt "$n" ]; do out="$out$out"; done
  printf '%s' "${out:0:$n}"
}
scroll_range="*$(ext_repeat a 1348)"
assert_eq "${#scroll_range}" "1349" "the scroll payload really is 1349 characters"
ext_src "$EXT_SRCS/scroll" "{ \"name\": \"scroll\", \"contract\": 1, \"roost\": \"$scroll_range\", \"commands\": [\"scroll\"] }" scroll
ext_publish fix/scroll "$EXT_SRCS/scroll"
out_scroll="$(ext_install fix/scroll --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "install refuses a roost range long enough to scroll the pin off the screen"
assert_contains "$(cat "$TMP/err")" "is longer than 64 characters" "...naming the rule and the cap"
# Refused where the manifest is READ, so the plan block is never drawn at all
# -- there is no prompt to scroll anything away from.
case "$out_scroll" in
  *"Install? [y/N]"*) scroll_prompted=1 ;;
  *) scroll_prompted=0 ;;
esac
assert_eq "$scroll_prompted" "0" "...before any prompt is printed"
case "$out_scroll" in
  *"(pinned)"*) scroll_block=1 ;;
  *) scroll_block=0 ;;
esac
assert_eq "$scroll_block" "0" "...and before any plan block is printed"
assert_file_absent "$EXT_DATA/scroll" "...and nothing is installed"

# The cap is INCLUSIVE at 64, and a value at the cap still behaves the way an
# unreadable range is supposed to: warn, and install. Asserting only the
# refusal would pass on a build that refused every range there is.
cap_ok=">=$(ext_repeat a 62)"
assert_eq "${#cap_ok}" "64" "the boundary fixture is exactly at the cap"
ext_src "$EXT_SRCS/cap64" "{ \"name\": \"capok\", \"contract\": 1, \"roost\": \"$cap_ok\", \"commands\": [\"capok\"] }" capok
ext_publish fix/cap64 "$EXT_SRCS/cap64"
out_cap="$(ext_install fix/cap64 --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "a roost range exactly at the cap still installs"
assert_contains "$out_cap" "cannot read" "...warning that the range is unreadable, as an unparsable range must"
# THE `Note:` LINE IS LOAD-BEARING, and this assertion is here so that nobody
# later simplifies it away as decoration. A value long enough to scroll is
# ALWAYS an unparsable range, so the Note re-prints the same payload at a
# different column offset and garbles whatever wrap alignment an attacker
# chose -- a width-aligned 80-column forged block comes out as obvious mangled
# junk. That is why the length cap closes an omission and never had to close a
# forgery: the Note was already in the way.
assert_contains "$out_cap" "  Note: " "...on the Note line, which re-prints the range at a second column offset"

cap_over=">=$(ext_repeat a 63)"
assert_eq "${#cap_over}" "65" "the over-cap fixture is one character past it"
ext_src "$EXT_SRCS/cap65" "{ \"name\": \"capover\", \"contract\": 1, \"roost\": \"$cap_over\", \"commands\": [\"capover\"] }" capover
ext_publish fix/cap65 "$EXT_SRCS/cap65"
out_capover="$(ext_install fix/cap65 --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "one character past the cap is refused"
assert_contains "$(cat "$TMP/err")" "is longer than 64 characters" "...naming the same rule"

# `description` is capped too: `roost ext list` and `roost ext info` print it,
# and the design calls it one line.
long_desc="$(ext_repeat d 201)"
ext_src "$EXT_SRCS/longdesc" "{ \"name\": \"longdesc\", \"contract\": 1, \"commands\": [\"longdesc\"], \"description\": \"$long_desc\" }" longdesc
ext_publish fix/longdesc "$EXT_SRCS/longdesc"
out_longdesc="$(ext_install fix/longdesc --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "install refuses a description past its own cap"
assert_contains "$(cat "$TMP/err")" "field 'description' is longer than 200 characters" "...naming that field and its cap"
assert_file_absent "$EXT_DATA/longdesc" "...and nothing is installed"

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

# WHAT THE FIXTURE ABOVE DOES AND DOES NOT PROVE. Measured on git 2.50.1, by
# editing scripts/roost-ext and re-running this file:
#
#   delete `--no-checkout --no-recurse-submodules` from the clone -> ALL GREEN
#   before the source assertions below existed. git does not recurse into
#   submodules unless it is asked to, so the fixture above cannot tell the
#   flag being present from the flag being absent, in either direction.
#
# An earlier version of this comment claimed the opposite -- that deleting
# both turns two assertions red. That measurement was of a DIFFERENT change:
# passing `--recurse-submodules`, which is not what deleting `--no-...` does.
# It is corrected here rather than quietly dropped, because a causal claim
# nobody re-ran is the exact failure AGENTS.md §9 is about, and it was sitting
# in a committed comment beside the assertions it was wrong about.
#
# So the fixture pins the PROPERTY -- a repository carrying a gitlink installs
# with no submodule content on disk -- and the flag that is supposed to
# guarantee it is pinned separately, in the SOURCE, below. GIT_LFS_SKIP_SMUDGE
# and core.hooksPath are worse still: provoking either needs git-lfs installed
# or a hook planted in a fixture, and neither is a dependency this suite
# should acquire (the hooks half IS provoked, further down, for the one call
# path where it can be).
#
# THE SOURCE ASSERTIONS RUN AGAINST A COPY WITH THE COMMENTS STRIPPED, and
# that is the whole point of them. The first version of these greps searched
# the file as written and matched the PROSE describing the flags -- "the clone
# passes --no-recurse-submodules" is a comment, and it kept the assertion
# green with the flag deleted from the invocation. An assertion that a
# sentence about the code exists is not an assertion about the code.
ext_code="$TMP/roost-ext.code"
ext_lib_code="$TMP/roost-ext-lib.code"
grep -v '^[[:space:]]*#' "$HERE/scripts/roost-ext" > "$ext_code"
grep -v '^[[:space:]]*#' "$HERE/scripts/lib/roost-ext.sh" > "$ext_lib_code"
# Checked before it is trusted, the same shape the sandbox canary uses at the
# end of this file: a phrase that exists ONLY in a comment has to be in the
# original and gone from the filtered copy. Without this pair, a filter that
# silently produced an empty file would make every grep below fail loudly --
# but a filter that stripped nothing would make them all pass, which is the
# direction that hides a defect.
# The probe is the file's own first prose comment rather than a phrase written
# out here: a literal would rot the first time somebody reworded that comment,
# and a rotted detector fails in the direction that says "nothing to filter"
# while the greps below quietly go back to matching prose.
ext_first_comment="$(grep -m1 '^# ' "$HERE/scripts/roost-ext")"
[ -n "$ext_first_comment" ]
assert_true "$?" "the comment filter has a comment to filter"
grep -qF "$ext_first_comment" "$ext_code"
assert_eq "$?" "1" "...and the filtered copy really has the comment prose taken out"
grep -qF '_ext_git()' "$ext_code"
assert_true "$?" "...while the code it describes is still there"

# TWO clone sites, and the count is the assertion. `install` clones at one
# place in scripts/roost-ext and `update` clones at another, and a `grep -q`
# is satisfied by EITHER of them: measured by deleting the flags from the
# install call alone -- exit 0, whole file green -- and again from the update
# call alone, same result. So the consent block's "Nothing runs during
# install" could be made false on the install path with this file fully
# green, which is the promise these lines exist to hold.
#
# The behavioural fixture above cannot close it (git does not recurse by
# default, as its own comment records), and the two assertions below already
# use the counted form. Two assertions here, and they answer two different
# questions -- the first alone was claimed to answer both, and did not.
#
# `= 2` says the two call sites that exist are hardened. It does NOT notice a
# THIRD one added without the flags: the hardened count stays 2, and the
# "spells git exactly once" invariant further down cannot see it either,
# because `_ext_git` is underscore-prefixed and its pattern excludes exactly
# that. Demonstrated: a third `_ext_git clone --quiet -- ...` in this file
# left the suite green at 975.
#
# So the second assertion pins EVERY `_ext_git clone` in the file to the
# hardened spelling by comparing the two counts. A new call site has to carry
# the flags to keep them equal, which is the property the wrapper pattern is
# supposed to give and the reason the flags are not folded into `_ext_git`
# itself: `_ext_git` runs plenty of commands that take neither flag.
assert_eq "$(grep -cF -- '_ext_git clone --quiet --no-checkout --no-recurse-submodules --' "$ext_code")" "2" \
  "both clone INVOCATIONS -- install's and update's -- pass --no-checkout and --no-recurse-submodules"
assert_eq "$(grep -cF -- '_ext_git clone' "$ext_code")" \
          "$(grep -cF -- '_ext_git clone --quiet --no-checkout --no-recurse-submodules --' "$ext_code")" \
  "...and EVERY clone in the file is one of those two: a new call site has to carry the flags to keep these counts equal"
grep -qF 'GIT_LFS_SKIP_SMUDGE=1 GIT_TERMINAL_PROMPT=0 git -C / -c core.hooksPath=/dev/null "$@"' "$ext_code"
assert_true "$?" "install's git wrapper carries GIT_LFS_SKIP_SMUDGE=1, core.hooksPath=/dev/null and the -C / that stops git DISCOVERING a repository from the cwd"
# On ONE wrapper, so a git invocation added to this file later is hardened by
# construction rather than by whoever adds it remembering.
# Exactly ONE spelling of `git` in the whole of each file's code, and it is
# the wrapper's own line. Stronger than "the wrapper exists", and it is the
# assertion that would notice a second, unhardened git invocation being added
# later -- which is the failure the wrapper exists to make impossible.
assert_eq "$(grep -cE '(^|[^_a-zA-Z])git ' "$ext_code")" "1" \
  "scripts/roost-ext spells git exactly once, inside the hardened wrapper"
assert_eq "$(grep -cE '(^|[^_a-zA-Z])git ' "$ext_lib_code")" "1" \
  "...and so does scripts/lib/roost-ext.sh"

# The library's own git, which roost_ext_tree_hash runs INSIDE an extension's
# directory during install and again during every verify. It was unhardened,
# and with core.hooksPath and init.templateDir set in a user's global config
# that meant hooks firing during an install that had just promised nothing
# runs. Behaviour pins this one, below; these name the three call sites.
grep -qF 'GIT_LFS_SKIP_SMUDGE=1 git -C / -c core.hooksPath=/dev/null -c init.templateDir= "$@"' "$ext_lib_code"
assert_true "$?" "the library's git wrapper is hardened the same way, -C / included"
grep -qF 'roost_ext__git init -q --bare' "$ext_lib_code"
assert_true "$?" "tree_hash's git init goes through it"
grep -qF 'roost_ext__git -C "$dir" add -A --force' "$ext_lib_code"
assert_true "$?" "...its git add too"
grep -qF 'roost_ext__git write-tree' "$ext_lib_code"
assert_true "$?" "...and its git write-tree"

# --- and the hooks half, provoked ------------------------------------------
# The one hardening measure this suite CAN demonstrate rather than grep for.
# These are the USER'S OWN hooks -- no manifest chooses them -- so this is not
# an escalation; it is the consent block's "nothing runs during install" being
# false on an ordinary developer machine, which is enough.
#
# GIT_CONFIG_GLOBAL rather than a $HOME/.gitconfig: HOME is the canary in this
# file and nothing may be written under it.
HOOKY="$TMP/hooky"; mkdir -p "$HOOKY/hooks"
for h in post-index-change reference-transaction post-checkout pre-commit; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$(basename "$0")" >> "%s/fired"\nexit 0\n' "$HOOKY" > "$HOOKY/hooks/$h"
  chmod +x "$HOOKY/hooks/$h"
done
printf '[core]\n\thooksPath = %s/hooks\n' "$HOOKY" > "$HOOKY/gitconfig"
# PUBLISHED FIRST, before the hook config is in force. ext_publish ends in a
# plain `git clone --bare`, which is a git this suite hardens nowhere -- so
# building the fixture under the config fires the hooks itself, and the first
# version of this section read that as the install having fired them. The
# marker is cleared again immediately before the install regardless, so the
# assertion is about the install and nothing else.
ext_src "$EXT_SRCS/hooky" '{ "name": "hooky", "contract": 1, "commands": ["hooky"] }' hooky
ext_publish fix/hooky "$EXT_SRCS/hooky"
export GIT_CONFIG_GLOBAL="$HOOKY/gitconfig"
# The detector first, and it is not decoration: GIT_CONFIG_GLOBAL is git 2.32
# and later, and on an older git this whole section would pass while proving
# nothing at all. So make the hooks fire, through the exact shape
# roost_ext_tree_hash uses, before believing the silence afterwards.
mkdir -p "$HOOKY/work"; printf 'x\n' > "$HOOKY/work/a.txt"
git init -q --bare "$HOOKY/odb" >/dev/null 2>&1
GIT_DIR="$HOOKY/odb" GIT_WORK_TREE="$HOOKY/work" GIT_INDEX_FILE="$HOOKY/idx" \
  git -C "$HOOKY/work" add -A --force -- . >/dev/null 2>&1
[ -s "$HOOKY/fired" ]
assert_true "$?" "the hook fixture really does fire hooks for an unhardened git"
rm -f "$HOOKY/fired"
# roost_ext_tree_hash on its own first: it is what `roost ext verify` will run
# on every installed extension, so it has to be silent independently of
# install.
roost_ext_tree_hash "$HOOKY/work" >/dev/null 2>&1
assert_file_absent "$HOOKY/fired" "roost_ext_tree_hash runs no hook from the user's own git config"
rm -f "$HOOKY/fired"
out_hooky="$(ext_install fix/hooky --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "an install runs to completion with hooks configured globally"
assert_file_absent "$HOOKY/fired" \
  "...and not one hook fired during it — 'nothing runs during install' stays true"
unset GIT_CONFIG_GLOBAL

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

# --- a manifest that claims one command twice -------------------------------
# Caught in the claim loop, with the other manifest problems and BEFORE the
# prompt. roost_ext_index_write does refuse it -- but only after the user has
# consented and the clone has been moved into place, in words written for a
# lockfile that two DIFFERENT extensions edited ("claimed by both 'ds' and
# 'ds'"), and the install then rolls back. The right outcome by a route nobody
# can follow is still a defect: a manifest problem belongs in the manifest's
# own refusal, at the moment the manifest is read.
ext_src "$EXT_SRCS/twice" '{ "name": "twice", "contract": 1, "commands": ["dx", "dx"] }' dx
ext_publish fix/twice "$EXT_SRCS/twice"
out_twice="$(ext_install fix/twice --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "install refuses a manifest that claims the same command twice"
assert_contains "$(cat "$TMP/err")" "claims dx twice" "...naming the command, once"
# BEFORE the prompt, which is the whole point of moving it. If the plan block
# was printed, the refusal happened after the user had already been asked.
case "$out_twice" in
  *"Install? [y/N]"*) twice_late=1 ;;
  *) twice_late=0 ;;
esac
assert_eq "$twice_late" "0" "...before the consent prompt, not after it"
assert_file_absent "$EXT_DATA/twice" "...and nothing is installed"

# --- an empty --ref is a mistake, not a request for the default branch ------
# `--ref "$TAG"` with an unset TAG is the shape this arrives in. Reading it as
# "no ref given, use the default branch" answers a question the user did not
# ask, on the one argument that decides which code gets installed.
out_emptyref="$(ext_install fix/good --ref '' --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "install refuses an EMPTY --ref rather than silently using the default branch"
assert_contains "$(cat "$TMP/err")" "not a plain ref name" "...naming the rule it broke"
assert_contains "$(cat "$TMP/err")" "nothing has been fetched" "...and saying nothing was fetched"

# --- a branch literally named HEAD -------------------------------------------
# `git update-ref refs/heads/HEAD` creates one happily, and `git ls-remote <url>
# HEAD` then answers with two lines: the repository's real HEAD, and that
# branch. gitrevisions resolves a bare name by trying `<name>` before
# refs/heads/<name>, so a default install has to pin the real HEAD -- pinning
# the branch would not be the ref the user meant, however honestly the id was
# shown.
ext_src "$EXT_SRCS/headbranch" '{ "name": "headbranch", "contract": 1, "commands": ["headbranch"] }' headbranch
ext_publish fix/headbranch "$EXT_SRCS/headbranch"
hb_first="$(ext_fixture_git -C "$EXT_SRCS/headbranch" rev-parse HEAD)"
printf 'second\n' > "$EXT_SRCS/headbranch/second.txt"
ext_fixture_git -C "$EXT_SRCS/headbranch" add -A >/dev/null 2>&1
ext_fixture_git -C "$EXT_SRCS/headbranch" commit -q -m second >/dev/null 2>&1
hb_second="$(ext_fixture_git -C "$EXT_SRCS/headbranch" rev-parse HEAD)"
rm -rf "$EXT_REMOTES/fix/headbranch"
git clone -q --bare "$EXT_SRCS/headbranch" "$EXT_REMOTES/fix/headbranch" >/dev/null 2>&1
ext_fixture_git -C "$EXT_REMOTES/fix/headbranch" update-ref refs/heads/HEAD "$hb_first" >/dev/null 2>&1
# The fixture is checked before anything is concluded from it: two different
# commits, and ls-remote really does answer with both lines.
[ "$hb_first" != "$hb_second" ]
assert_true "$?" "the HEAD-branch fixture really has two different commits"
assert_eq "$(git ls-remote -- "file://$EXT_REMOTES/fix/headbranch" HEAD | wc -l | tr -d ' ')" "2" \
  "...and ls-remote HEAD really is ambiguous, so this case has something to resolve"
out_hb="$(ext_install fix/headbranch --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "install succeeds against a repository carrying a branch named HEAD"
assert_eq "$(ext_lock_field headbranch commit)" "$hb_second" \
  "...pinning the repository's real HEAD, not the branch that shares its name"

# --- a failed install takes its state directory with it ---------------------
# The rollback used to restore ext.lock and remove the clone and stop there,
# leaving $state/ext/<name> behind: a failed install stayed visible afterwards
# as an extension that had been there once. A rollback that is partial is a
# rollback nobody can reason about.
#
# The failure is provoked the same way the lockfile one is -- a hand-wedged
# ext.lock that can be read but cannot become a dispatch table -- because that
# is the one abandonment point that happens AFTER the state directory is made.
ext_src "$EXT_SRCS/statedir" '{ "name": "statedir", "contract": 1, "commands": ["statedir"] }' statedir
ext_publish fix/statedir "$EXT_SRCS/statedir"
printf '%s\n' '{ "wedged": { "repo": "o/wedged", "commands": [] } }' > "$(roost_ext_lock)"
rm -f "$EXT_STATE_ROOT/ext.index"
out_sd="$(ext_install fix/statedir --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "the install fails, as the wedged lockfile requires"
assert_file_absent "$EXT_STATE_ROOT/ext/statedir" \
  "...and the state directory it created is gone too, not left behind"

# THE OTHER DIRECTION, and it is the one that matters more. `roost ext remove`
# deliberately KEEPS an extension's state unless --purge is given, precisely so
# an accidental removal does not destroy a year of bookmarks. A reinstall that
# then fails must not be the thing that destroys them instead. The rollback
# removes a state directory only when THIS run created it, with rmdir rather
# than rm -rf, so a directory with anything in it survives structurally rather
# than by care.
mkdir -p "$EXT_STATE_ROOT/ext/statedir"
printf 'a year of bookmarks\n' > "$EXT_STATE_ROOT/ext/statedir/data"
out_sd="$(ext_install fix/statedir --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "the install fails again with the state directory already present"
[ -f "$EXT_STATE_ROOT/ext/statedir/data" ]
assert_true "$?" "...and the state a previous remove kept on purpose is untouched"
assert_eq "$(cat "$EXT_STATE_ROOT/ext/statedir/data")" "a year of bookmarks" \
  "...byte for byte"
rm -rf "$EXT_STATE_ROOT/ext/statedir"
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

# --- roost ext verify ---------------------------------------------------------
# Pinning to a commit describes what was DOWNLOADED once; it says nothing
# about what will RUN tonight. `verify` recomputes roost_ext_tree_hash for an
# installed extension and compares it with the `tree` ext.lock already
# recorded -- the SAME function `install` recorded with (asserted directly by
# name a few lines up in this file, "ext.lock records the tree hash
# roost_ext_tree_hash computes"). This section starts from its own clean
# state rather than reusing "demo" or "withsub" from earlier in this file: an
# assertion that depended on exactly which fixture survived every refusal
# above it would be reading the wrong thing the moment one of those refusals
# changed shape.
rm -f "$(roost_ext_lock)"
roost_ext_index_write
rm -rf "$EXT_DATA/pin" "$EXT_DATA/pin2"

ext_verify() { ROOST_EXT_GIT_BASE="$EXT_BASE" "$HERE/scripts/roost-ext" verify "$@"; }

ext_src "$EXT_SRCS/pin" '{ "name": "pin", "contract": 1, "commands": ["pin"] }' pin
ext_publish fix/pin "$EXT_SRCS/pin"
ext_install fix/pin --yes >/dev/null 2>"$TMP/err"
assert_eq "$(cat "$TMP/err")" "" "the verify fixture installs cleanly"

# --- a fresh install verifies ok, and exits 0 --------------------------------
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "verify exits 0 on a fresh install"
assert_eq "$out_v" "pin: ok" "verify prints ok for a fresh install"
assert_eq "$(cat "$TMP/err")" "" "a clean verify writes nothing to stderr"

# --- one byte changed in an installed file -----------------------------------
printf '#!/bin/sh\nprintf "TAMPERED\\n"\n' > "$EXT_DATA/pin/bin/roost-pin"
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "verify exits non-zero once an installed file is changed"
assert_contains "$out_v" "bin/roost-pin" "...and names the file that changed"
assert_contains "$out_v" "modified" "...saying it was modified"
case "$out_v" in *": ok"*) v_said_ok=1 ;; *) v_said_ok=0 ;; esac
assert_eq "$v_said_ok" "0" "...without also claiming ok anywhere in the same output"

# --- restore the byte: verify is ok again, THEN an untracked file is added --
# This pair is the property roost_ext_tree_hash was measured against, and the
# one `roost ext verify` rests on: it and `git rev-parse HEAD^{tree}` agree on a
# pristine clone and diverge the moment an untracked file exists. Recomputing
# with the wrong function would still say "ok" here -- HEAD^{tree} does not
# know extra.txt exists at all -- so this is the case that actually pins
# which function `verify` calls, not merely that it calls SOME hash function.
printf '#!/bin/sh\nprintf "pin ran [%%s]\\n" "$*"\n' > "$EXT_DATA/pin/bin/roost-pin"
chmod +x "$EXT_DATA/pin/bin/roost-pin"
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "verify is ok again once the byte is put back"
assert_eq "$out_v" "pin: ok" "...back to printing ok, byte for byte"

printf 'unexpected\n' > "$EXT_DATA/pin/extra.txt"
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "verify fails once a file is ADDED to the extension directory"
assert_contains "$out_v" "extra.txt" "...and names the added file"
assert_contains "$out_v" "added" "...saying it was added, not merely different"

# --- a file removed from the clone -------------------------------------------
rm -f "$EXT_DATA/pin/extra.txt"
rm -f "$EXT_DATA/pin/roost-ext.json"
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "verify fails once a file is REMOVED from the extension directory"
assert_contains "$out_v" "roost-ext.json" "...and names the removed file"
assert_contains "$out_v" "removed" "...saying it was removed, not merely different"
cp "$EXT_SRCS/pin/roost-ext.json" "$EXT_DATA/pin/roost-ext.json"
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "verify is ok again once the removed file is restored"
assert_eq "$out_v" "pin: ok" "...back to ok, byte for byte"

# --- no output reads as a verdict on the CODE, only on the BYTES -------------
# Roost has no scanner and makes no claim about whether the pinned code is
# honest -- see the design's "What this design does not attempt". `ok` means
# only "matches the pin". Checked against a FAILING call's output, not the
# "pin: ok" one still sitting in $out_v above -- a check of a 7-character
# constant for these words is a tautology that would pass no matter what
# verify printed on the multi-line FAILURE path, which is the one path that
# could actually carry a verdict word (the per-file "modified"/"added"/
# "removed" lines, and the header line above them).
printf 'unexpected again\n' > "$EXT_DATA/pin/extra2.txt"
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "the fixture built for the verdict-language check really is a failing one"
assert_contains "$out_v" "extra2.txt" "...and really is the multi-line per-file output, not just a header"
# EXT_VERDICT_WORDS is the install check's list, shared rather than copied --
# see its definition for what drifting cost. `honest` is added here and only
# here: the consent block says out loud that roost has NOT checked whether the
# code is honest, so the install check cannot forbid the word, and verify has
# no such sentence to protect. Lowercased before the match, the same way the
# consent check does it, so a capitalised verdict at the start of a line
# cannot slip past.
out_v_lc="$(printf '%s\n' "$out_v" | tr 'A-Z' 'a-z')"
for bad_word in $EXT_VERDICT_WORDS honest; do
  case "$out_v_lc" in
    *"$bad_word"*) said=1 ;;
    *) said=0 ;;
  esac
  assert_eq "$said" "0" "verify's output never says '$bad_word', even on a failing, multi-line result"
done
rm -f "$EXT_DATA/pin/extra2.txt"
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "verify is ok again once the verdict-language fixture is cleaned up"

# --- an unknown name exits 1 --------------------------------------------------
out_v="$(ext_verify nosuchextension 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "verify NAME on an unknown name exits 1"
assert_eq "$out_v" "" "...and prints nothing on stdout"
assert_contains "$(cat "$TMP/err")" "no such extension" "...saying so on stderr"

# --- a clone that has gone missing entirely -----------------------------------
rm -rf "$EXT_DATA/pin"
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "verify fails when the clone is missing entirely"
# Not just "pin" -- the fixture is NAMED pin, so that would pass no matter
# what verify printed. MISSING and the actual (now-absent) clone path are
# specific to this failure mode and could not appear by accident.
assert_contains "$out_v" "MISSING" "...saying so in words"
assert_contains "$out_v" "$EXT_DATA/pin" "...and naming the path that is not there"

# --- verify refuses a lockfile key it did not write, before touching a path -
# The identical property `list`/`info` already guard (see "info / list: a
# hand-edited ext.lock cannot escape the extensions dir" above) applied to
# `verify`, which does far more with the resolved path than a stat: a MATCH
# runs `git add -A --force` over the whole directory. The traversal target
# carries a file whose content would never legitimately reach verify's
# output; if it ever does, the guard failed to stop the path before it was
# used. The lockfile key is "../verify-traversal-target", which from
# $EXT_DATA/ (this section's ext/ directory) resolves to
# $TMP/verify-traversal-target -- outside ext/ entirely.
mkdir -p "$TMP/verify-traversal-target"
printf 'ROOST_VERIFY_TRAVERSAL_CANARY\n' > "$TMP/verify-traversal-target/canary.txt"
lock_install <<'JSON'
{ "../verify-traversal-target": { "repo": "o/x", "commands": ["x"] } }
JSON
out_v="$(ext_verify 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "verify with a traversal key in ext.lock exits non-zero rather than reading through it"
assert_contains "$out_v" "invalid name" "...marking the entry as an invalid name, the same wording list/info use"
case "$out_v" in
  *"ROOST_VERIFY_TRAVERSAL_CANARY"*) assert_true 1 "the traversal target's own content never reaches stdout" ;;
  *) assert_true 0 "the traversal target's own content never reaches stdout" ;;
esac
case "$(cat "$TMP/err")" in
  *"ROOST_VERIFY_TRAVERSAL_CANARY"*) assert_true 1 "...or stderr" ;;
  *) assert_true 0 "...or stderr" ;;
esac
rm -rf "$TMP/verify-traversal-target"
rm -f "$(roost_ext_lock)"
roost_ext_index_write

# --- a hand-edited `tree` cannot smuggle an option onto a git command line ---
# ext.lock's `tree` field reaches `_ext_verify_diff`, which hands it to `git
# diff-tree` as a bare positional argument. `"--output=<path>"` is what a
# read-only integrity check turns into a file-writer if that value is ever
# trusted as a plain 40-character id -- provoked here exactly the way it
# would happen for real: the byte changes (so the mismatch branch runs) and
# the lockfile is hand-edited (so `tree` is no longer a real object id).
ext_src "$EXT_SRCS/pin" '{ "name": "pin", "contract": 1, "commands": ["pin"] }' pin
ext_publish fix/pin "$EXT_SRCS/pin"
ext_install fix/pin --yes >/dev/null 2>&1
printf '#!/bin/sh\nprintf "TAMPERED\\n"\n' > "$EXT_DATA/pin/bin/roost-pin"
pwned="$TMP/verify-pwned-$$"
rm -f "$pwned"
sed "s#\"tree\": \"[0-9a-f]*\"#\"tree\": \"--output=$pwned\"#" "$(roost_ext_lock)" > "$TMP/lock-pwned.json"
# The fixture is checked before anything is concluded from it: if the
# substitution above did not actually change the recorded tree, this case has
# nothing to catch and would pass whether or not the fix works.
grep -qF -- "--output=$pwned" "$TMP/lock-pwned.json"
assert_true "$?" "the malicious tree fixture really does carry an option-shaped value"
cp "$TMP/lock-pwned.json" "$(roost_ext_lock)"
out_v="$(ext_verify pin 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "verify exits non-zero when ext.lock's tree is not a 40-character id"
assert_file_absent "$pwned" "...and never lets that value reach a git command line as an option"
assert_contains "$out_v" "not a 40-character object id" \
  "...saying specifically that the recorded tree is malformed, not just 'could not list'"
rm -f "$(roost_ext_lock)"; roost_ext_index_write
rm -rf "$EXT_DATA/pin"

# --- verify with no name checks every installed extension --------------------
ext_src "$EXT_SRCS/pin2" '{ "name": "pin2", "contract": 1, "commands": ["pin2"] }' pin2
ext_publish fix/pin2 "$EXT_SRCS/pin2"
rm -f "$(roost_ext_lock)"; roost_ext_index_write
ext_install fix/pin2 --yes >/dev/null 2>&1
out_v="$(ext_verify 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "verify with no name checks everything, and exits 0 when it all matches"
assert_eq "$out_v" "pin2: ok" "...naming the one extension that is actually installed"

printf 'oops\n' > "$EXT_DATA/pin2/oops.txt"
out_v="$(ext_verify 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "verify with no name exits non-zero if ANY installed extension differs"
assert_contains "$out_v" "oops.txt" "...and still names the file"

unset -f ext_verify
rm -f "$(roost_ext_lock)"
roost_ext_index_write
rm -rf "$EXT_DATA/pin" "$EXT_DATA/pin2"

# --- roost ext update -------------------------------------------------------
# The only command in this feature that touches an extension ALREADY ON DISK,
# and therefore the only one where the clone's own `.git` is in play. Two
# things are being asserted here and they pull in opposite directions:
#
#   the diff and the consent prompt have to be SHOWN, because consent was
#   given to code and a repository that turns bad turns bad between two
#   commits nobody looked at;
#
#   and nothing the repository or the installed clone can write may be
#   HONOURED -- not a hook, not a config value, not an escape sequence in a
#   diff that repaints the block above the question.
#
# This section starts from its own clean state, the same reason the verify
# section does: an assertion that depended on which fixture survived every
# refusal above it would be reading the wrong thing the moment one of those
# refusals changed shape.
rm -f "$(roost_ext_lock)"
roost_ext_index_write
rm -rf "$EXT_DATA/moving" "$EXT_DATA/grower" "$EXT_DATA/poison" "$EXT_DATA/turncoat" \
       "$EXT_DATA/shy" "$EXT_DATA/loud" "$EXT_DATA/goner" "$EXT_DATA/second"
rm -rf "$EXT_STATE_ROOT/ext/goner"

ext_update() { ROOST_EXT_GIT_BASE="$EXT_BASE" "$HERE/scripts/roost-ext" update "$@"; }
ext_remove() { ROOST_EXT_GIT_BASE="$EXT_BASE" "$HERE/scripts/roost-ext" remove "$@"; }
ext_list()   { ROOST_EXT_GIT_BASE="$EXT_BASE" "$HERE/scripts/roost-ext" list "$@"; }

# ext_bin DIR CMD MARK -> an extension executable that reports the one thing
# the authority assertions in this section are about: whether ROOST_SOCKET
# reached it. MARK is what tells the FIRST commit's program from the SECOND's
# -- "the pin moved" and "the new code is what runs" are different claims, and
# a lockfile field cannot prove the second one.
#
# `${VAR-...}` and never `${VAR:-...}`, for the reason the dispatcher's own
# probe stub gives at length: absent and present-but-empty are exactly the
# distinction, and an empty ROOST_SOCKET would address the user's own everyday
# tmux server.
ext_bin() {
  local dir="$1" cmd="$2" mark="$3"
  mkdir -p "$dir/bin"
  {
    printf '#!/bin/sh\n'
    printf 'printf "ROOST_SOCKET=%%s\\n" "${ROOST_SOCKET-<unset>}"\n'
    printf 'printf "MARK=%s\\n"\n' "$mark"
  } > "$dir/bin/roost-$cmd"
  chmod +x "$dir/bin/roost-$cmd"
}

# ext_head SPEC -> what the fixture remote really resolves HEAD to, asked of
# git rather than taken from roost's own output: an assertion that compared
# the updater to itself would hold however wrong the pin was.
ext_head() { git ls-remote -- "file://$EXT_REMOTES/$1" HEAD | awk '{print $1}'; }

ext_src "$EXT_SRCS/moving" '{
  "name": "moving",
  "contract": 1,
  "needs": ["fleet"],
  "commands": ["moving"]
}' moving
ext_bin "$EXT_SRCS/moving" moving first
ext_publish fix/moving "$EXT_SRCS/moving"
moving_1="$(ext_head fix/moving)"
ext_install fix/moving --yes >/dev/null 2>"$TMP/err"
assert_eq "$(cat "$TMP/err")" "" "the update fixture installs cleanly"

# The grant as it stands, measured through a real dispatch rather than read
# out of the file that grants it. Everything below about a revocation taking
# effect is worthless without this line: an authority never seen working is an
# authority whose absence proves nothing.
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" moving 2>"$TMP/err")"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" \
  "baseline: the installed extension really is granted fleet"
assert_eq "$(ext_field "$out" MARK)" "first" "...and it is the first commit's program that runs"

# --- update on an unchanged ref writes NOTHING ------------------------------
# Not the lockfile, not the index, not the `installed` timestamp. A command
# that rewrote one byte here would make "nothing changed" indistinguishable
# from "something did" to anything watching the file -- and would move the
# `installed` date of a pin nobody moved.
lock_before="$(cat "$(roost_ext_lock)")"
index_before="$(cat "$EXT_STATE_ROOT/ext.index")"
out_u="$(ext_update moving --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "update on an unchanged ref exits 0"
assert_contains "$out_u" "up to date at ${moving_1:0:7}" \
  "...says so, naming the commit it is still pinned to"
assert_eq "$(cat "$(roost_ext_lock)")" "$lock_before" "...and leaves ext.lock BYTE-IDENTICAL"
assert_eq "$(cat "$EXT_STATE_ROOT/ext.index")" "$index_before" "...and ext.index byte-identical"
case "$out_u" in *"Update? [y/N]"*) u_asked=1 ;; *) u_asked=0 ;; esac
assert_eq "$u_asked" "0" "...without asking a question there was nothing to answer"

# --- a new commit: the diff, the pin, the tree, and the revocation ----------
# The manifest's `needs` SHRINKS from ["fleet"] to [] in the same commit. That
# is the direction the design calls dangerous: `ext.index` is the authority of
# record and the dispatcher never opens `ext.lock`, so until the index is
# regenerated the extension still holds exactly what the user just revoked.
sed 's/"needs": \["fleet"\]/"needs": []/' "$EXT_SRCS/moving/roost-ext.json" > "$TMP/m.json"
mv "$TMP/m.json" "$EXT_SRCS/moving/roost-ext.json"
ext_bin "$EXT_SRCS/moving" moving second
ext_publish fix/moving "$EXT_SRCS/moving"
moving_2="$(ext_head fix/moving)"
[ "$moving_2" != "$moving_1" ]
assert_true "$?" "the fixture repository really moved to a second commit"

out_u="$(ext_update moving --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "update accepts a moved ref with --yes"
assert_eq "$(cat "$TMP/err")" "" "a successful update writes nothing to stderr"
assert_contains "$out_u" "  old      ${moving_1:0:7}...  (installed)" \
  "the block names the commit that is installed now"
assert_contains "$out_u" "  new      ${moving_2:0:7}...  (would be pinned)" \
  "...and the commit it would move to"
assert_contains "$out_u" "modified  bin/roost-moving" \
  "...lists every file that changed between the two"
assert_contains "$out_u" '+printf "MARK=second' \
  "...and shows the DIFF, carrying the line that actually changed"
assert_contains "$out_u" "Update? [y/N]" "...then asks"

# THE PIN MOVED, and the tree was rewritten with it.
assert_eq "$(ext_lock_field moving commit)" "$moving_2" "ext.lock records the new commit"
assert_eq "$(ext_lock_field moving tree)" "$(roost_ext_tree_hash "$EXT_DATA/moving")" \
  "...and the tree hash roost_ext_tree_hash computes for the directory that is now installed"
assert_eq "$(ext_lock_field moving ref)" "HEAD" "...with the ref it was pinned by unchanged"
assert_eq "$(ext_lock_field moving needs)" "none" "...and the authority the new manifest asks for"

# THE REVOCATION, MEASURED THE ONLY WAY IT CAN BE: by dispatching. This is the
# assertion the whole task turns on. `roost ext update` regenerating ext.index
# in the same operation as ext.lock is what makes a `needs` that shrank stop
# being granted; without it every assertion above still passes and the
# extension keeps the run of the fleet.
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" moving 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "the updated extension still dispatches"
assert_eq "$(ext_field "$out" MARK)" "second" "...and it is the NEW commit's program that runs"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "an authority that SHRANK is gone the moment update returns — ext.index was regenerated in the same operation"
assert_eq "$(ext_index_col moving 4)" "" \
  "...and the dispatch table's authority column is empty, which is where the dispatcher reads it"
assert_eq "$(ext_list 2>&1 >/dev/null)" "" \
  "...so ext.lock and ext.index agree — roost ext list raises no security warning"

# The negative half of the pair. A build that printed the growth callout on
# every update would satisfy the assertion below it and tell a user nothing,
# which is the exact failure that makes a warning worthless.
case "$out_u" in *"NEW AUTHORITY"*) shrink_shouted=1 ;; *) shrink_shouted=0 ;; esac
assert_eq "$shrink_shouted" "0" "an authority that SHRANK is not announced as a new one"

# --- a `needs` that GREW, on its own line immediately above the prompt ------
# An extension quietly acquiring `fleet` on an update is the exact attack the
# field exists to make visible.
ext_src "$EXT_SRCS/grower" '{ "name": "grower", "contract": 1, "commands": ["grower"] }' grower
ext_bin "$EXT_SRCS/grower" grower first
ext_publish fix/grower "$EXT_SRCS/grower"
ext_install fix/grower --yes >/dev/null 2>&1
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" grower 2>/dev/null)"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "<unset>" \
  "baseline: an extension that asked for nothing is granted nothing"
printf '%s\n' '{ "name": "grower", "contract": 1, "needs": ["fleet"], "commands": ["grower"] }' \
  > "$EXT_SRCS/grower/roost-ext.json"
ext_bin "$EXT_SRCS/grower" grower second
ext_publish fix/grower "$EXT_SRCS/grower"
out_g="$(ext_update grower --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "update accepts a manifest whose needs grew, once consented to"
assert_contains "$out_g" "NEW AUTHORITY: this update asks for fleet" \
  "an authority that GREW is called out in words"
# IMMEDIATELY ABOVE THE PROMPT, not merely somewhere in the output. A callout
# printed above the diff is a callout that scrolls away, and burying the
# question is how a bad update gets approved. Anchored to the line before the
# prompt itself rather than to a count of lines, so re-wording the block
# cannot silently move it.
grew_prev="$(printf '%s\n' "$out_g" | awk '/Update\? \[y\/N\]/{print prev; exit} {prev = $0}')"
assert_contains "$grew_prev" "NEW AUTHORITY" \
  "...on the line IMMEDIATELY above the prompt, where the eye passes it"
assert_contains "$grew_prev" "read any pane and send prompts to any agent" \
  "...saying what the new authority lets it DO, not the name of a manifest field"
assert_eq "$(ext_index_col grower 4)" "fleet" "the granted authority is in ext.index after the update"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" grower 2>/dev/null)"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" \
  "...and the extension that asked for it now has it"

# --- THE INSTALLED CLONE'S .git/config IS THE ATTACKER'S FILE ---------------
# `roost ext verify` deliberately does not cover `.git` (see the design's
# "roost ext verify"), so a compromised extension can put anything in its own
# config and verify still reports `ok`. `update` is the one command with any
# reason to run git against that clone, and three config keys below were
# MEASURED to execute a command on this machine with nothing but the clone's
# own config -- the positive controls a few lines down run each of them and
# assert the payload really fires, BEFORE the same fixture is handed to
# `roost ext update`.
#
# Without those controls this whole block would be the shape AGENTS.md §9
# warns about: a probe whose own setup is wrong prints exactly what a working
# defence prints.
ext_src "$EXT_SRCS/poison" '{ "name": "poison", "contract": 1, "commands": ["poison"] }' poison
ext_bin "$EXT_SRCS/poison" poison first
ext_publish fix/poison "$EXT_SRCS/poison"
ext_install fix/poison --yes >/dev/null 2>&1

pwned_origin="$TMP/pwned-remote-origin"
pwned_instead="$TMP/pwned-insteadof"
pwned_fsmon="$TMP/pwned-fsmonitor"
pwned_pager="$TMP/pwned-pager"
rm -f "$pwned_origin" "$pwned_instead" "$pwned_fsmon" "$pwned_pager"
cat > "$TMP/fsmonitor-payload" <<SH
#!/bin/sh
touch "$pwned_fsmon"
exit 1
SH
chmod +x "$TMP/fsmonitor-payload"

# `% ` is git-remote-ext's escape for a space, and the trailing `% #` makes
# the rest of the line a shell comment -- which matters for the insteadOf
# case, where git appends whatever followed the matched prefix to the
# rewritten URL. Without it the payload would `touch` a path with the rest of
# the repository URL glued onto the end, and the marker this asserts on would
# never appear at the name it is looked for under.
#
# protocol.ext.allow=always is in the same file as the payload, because it is
# the same attacker: git refuses the `ext` transport by default, and a fixture
# without this line would prove only that git's default is on.
# A function, not four inline lines: `update` REPLACES the clone, so every run
# against a poisoned config has to put the config back first.
ext_poison_config() {
  ext_fixture_git -C "$1" config protocol.ext.allow always
  ext_fixture_git -C "$1" config remote.origin.url "ext::sh -c touch% $pwned_origin% #"
  ext_fixture_git -C "$1" config "url.ext::sh -c touch% $pwned_instead% #.insteadOf" "file://"
  ext_fixture_git -C "$1" config core.fsmonitor "$TMP/fsmonitor-payload"
  # core.pager is the same shape as the three above and is set here so the
  # fixture carries the whole of what the design names -- but it only fires
  # when git is writing to a TERMINAL, which this suite never has, so no
  # assertion below claims to have provoked it. Saying that plainly beats an
  # assertion that could not fail.
  ext_fixture_git -C "$1" config core.pager "sh -c 'touch $pwned_pager'"
}
ext_poison_config "$EXT_DATA/poison"

# THE POSITIVE CONTROLS. Each runs the naive thing an implementation of
# `update` would do, against a COPY so the fixture itself is untouched, and
# asserts the payload really executed. Run first, so that the assertions
# underneath are about roost's behaviour rather than about a payload that
# never worked.
rm -rf "$TMP/poison-copy"
cp -R "$EXT_DATA/poison" "$TMP/poison-copy"
ext_fixture_git -C "$TMP/poison-copy" fetch origin >/dev/null 2>&1 || true
[ -e "$pwned_origin" ]
assert_true "$?" "the ext:: payload in remote.origin.url really executes under a naive fetch"
rm -f "$pwned_origin"
# THE ONE THAT DEFEATS THE OBVIOUS FIX: the URL is rebuilt from ext.lock and
# passed on the command line, exactly as the design asks -- and the clone's
# own insteadOf rewrites it back into the payload before git dials it.
# Passing the URL is necessary and is not sufficient.
ext_fixture_git -C "$TMP/poison-copy" fetch "file://$EXT_REMOTES/fix/poison" >/dev/null 2>&1 || true
[ -e "$pwned_instead" ]
assert_true "$?" "...and the clone's own insteadOf rewrites a URL passed on the COMMAND LINE"
rm -f "$pwned_instead"
ext_fixture_git -C "$TMP/poison-copy" status >/dev/null 2>&1 || true
[ -e "$pwned_fsmon" ]
assert_true "$?" "...and core.fsmonitor runs on any command that refreshes that clone's index"
rm -f "$pwned_fsmon"
rm -rf "$TMP/poison-copy"

# Now the real thing, against the same poisoned clone.
ext_bin "$EXT_SRCS/poison" poison second
ext_publish fix/poison "$EXT_SRCS/poison"
poison_2="$(ext_head fix/poison)"
out_p="$(ext_update poison --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "update succeeds against a clone whose .git/config is a payload"
assert_file_absent "$pwned_origin" \
  "update never dialled remote.origin.url out of the installed clone's config"
assert_file_absent "$pwned_instead" \
  "...and that clone's insteadOf never rewrote the URL update built from ext.lock"
assert_file_absent "$pwned_fsmon" \
  "...and core.fsmonitor never ran, because no git here has that clone as its repository"
assert_eq "$(ext_lock_field poison commit)" "$poison_2" \
  "...and the update still did its job: the pin moved to the new commit"
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" poison 2>/dev/null)"
assert_eq "$(ext_field "$out" MARK)" "second" "...and the new commit's program is what runs"
# The replacement clone is a fresh one, so the payload is not merely unread --
# it is gone. Asserted because "we did not honour it" and "it is still sitting
# there for the next command" are different states to leave a user in.
grep -q 'ext::' "$EXT_DATA/poison/.git/config"
assert_eq "$?" "1" "the clone update left behind carries none of the poisoned config"

# --- THE SAME CONFIG, REACHED WITH NO -C AND NO GIT_DIR ---------------------
# Everything above this line proves that roost never NAMES the installed clone
# as a git repository. That is not the same property as git never READING it:
# git resolves a repository by walking up from the current working directory,
# so a user who has `cd`-ed into an extension and runs `roost ext update` there
# hands git that clone's config with no argument of any kind. The insteadOf
# payload then rewrites the URL rebuilt from ext.lock and fires on `ls-remote`
# -- before the diff, before the prompt, so nothing downstream helps.
#
# Every poisoned-config assertion above runs `update` from the suite's own
# working directory, which is a git repository with no insteadOf in it, so all
# of them only ever exercised the neutral-cwd path. These are the ones that
# would have caught it. The precondition is not exotic: a cautious user
# inspecting a suspicious extension is exactly the person who has `cd`-ed into
# it and then runs `update` to see whether there is a new version.
ext_poison_config "$EXT_DATA/poison"
rm -rf "$TMP/poison-copy"
cp -R "$EXT_DATA/poison" "$TMP/poison-copy"
rm -f "$pwned_origin" "$pwned_instead" "$pwned_fsmon"
# The positive controls for THIS variant: a bare `ls-remote` -- no -C, no
# GIT_DIR, the same call `update` makes -- run once from the clone's own
# directory and once from a directory below it, because discovery walks up.
( cd "$TMP/poison-copy" && ext_fixture_git ls-remote -- "file://$EXT_REMOTES/fix/poison" HEAD ) >/dev/null 2>&1 || true
[ -e "$pwned_instead" ]
assert_true "$?" "an ls-remote run from INSIDE the clone discovers its config and executes the payload"
rm -f "$pwned_instead"
( cd "$TMP/poison-copy/bin" && ext_fixture_git ls-remote -- "file://$EXT_REMOTES/fix/poison" HEAD ) >/dev/null 2>&1 || true
[ -e "$pwned_instead" ]
assert_true "$?" "...and so does one run from a directory BELOW it — discovery walks upwards"
rm -f "$pwned_origin" "$pwned_instead" "$pwned_fsmon"
rm -rf "$TMP/poison-copy"

ext_bin "$EXT_SRCS/poison" poison third
ext_publish fix/poison "$EXT_SRCS/poison"
poison_3="$(ext_head fix/poison)"
out_p="$(cd "$EXT_DATA/poison" && ext_update poison --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "update run with cwd INSIDE the poisoned clone still succeeds"
assert_file_absent "$pwned_instead" \
  "...and no git of roost's discovered that config — the insteadOf never rewrote the URL"
assert_file_absent "$pwned_origin" "...nor was its remote.origin.url ever dialled"
assert_file_absent "$pwned_fsmon" "...nor its core.fsmonitor ever run"
assert_eq "$(ext_lock_field poison commit)" "$poison_3" "...and the update still moved the pin"

# ...and from BELOW the clone, which is the case that needs the upward walk
# stopped rather than merely the cwd itself not being a repository.
ext_poison_config "$EXT_DATA/poison"
ext_bin "$EXT_SRCS/poison" poison fourth
ext_publish fix/poison "$EXT_SRCS/poison"
poison_4="$(ext_head fix/poison)"
out_p="$(cd "$EXT_DATA/poison/bin" && ext_update poison --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "update run from a directory BELOW the poisoned clone still succeeds"
assert_file_absent "$pwned_instead" "...and still nothing of that config was discovered"
assert_file_absent "$pwned_origin" "...still nothing dialled"
assert_eq "$(ext_lock_field poison commit)" "$poison_4" "...with the pin moved again"

# --- git's OWN words reach the user, through _ext_git_stderr ----------------
# When a remote will not answer, git's message is the most useful thing a user
# gets, so it is passed through -- prefixed, capped, and run through the same
# control-character replacement the diff body gets, because it lands on a
# terminal and a terminal is an interpreter.
#
# WHAT THIS ASSERTS IS THE PASSTHROUGH, NOT THE SANITISING, and the difference
# is measured rather than assumed. An earlier version of this block put an ESC
# into the URL through ROOST_EXT_GIT_BASE and asserted it came back as `?`.
# That assertion passed with the sanitiser REMOVED: git 2.50.1 already escapes
# control characters in the paths it quotes back, so no ESC was ever in git's
# stderr to strip. It was a check against a thing that could not happen —
# exactly the tautology this branch has shipped before — so it is gone rather
# than left looking like proof.
#
# What is left can fail: delete the `_ext_git_stderr` call and there are no
# prefixed lines; break its awk and the same. That is worth having, because no
# other assertion in this file makes a git command fail at all, and an awk typo
# in a rarely-taken error path is exactly what ships silently.
#
# The sanitising itself is defence in depth for the git versions and messages
# that do NOT escape their own output, and is exercised for real on the diff
# body a few assertions above, where content bytes are reproduced verbatim.
out="$(ROOST_EXT_GIT_BASE="file://$TMP/there-is-no-such-remote/" "$HERE/scripts/roost-ext" install fix/good --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "install fails when the remote cannot be read at all"
git_said="$(grep '^roost ext install: git: ' "$TMP/err" || true)"
[ -n "$git_said" ]
assert_true "$?" "...and passes git's own message through, prefixed so it reads as git's words and not as roost's"
assert_contains "$git_said" "fatal:" "...carrying what git actually said"

# --- update with no NAME visits every installed extension -------------------
out_all="$(ext_update --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "update with no name exits 0 when everything is already current"
assert_contains "$out_all" "moving: up to date" "...and reports on moving"
assert_contains "$out_all" "grower: up to date" "...and on grower"
assert_contains "$out_all" "poison: up to date" "...and on poison — one at a time, all of them"

# --- a long diff is capped, and a diff cannot repaint the question ----------
# Burying the prompt under a huge diff is how a bad update gets approved, and
# an escape sequence in a changed line is the same attack the design's
# Security section records against the consent block: it repainted the commit
# row so the block displayed one commit while another was installed.
ext_src "$EXT_SRCS/loud" '{ "name": "loud", "contract": 1, "commands": ["loud"] }' loud
ext_bin "$EXT_SRCS/loud" loud first
ext_publish fix/loud "$EXT_SRCS/loud"
ext_install fix/loud --yes >/dev/null 2>&1
i=1
while [ "$i" -le 20 ]; do
  printf 'file %s\n' "$i" > "$EXT_SRCS/loud/f$i.txt"
  i=$((i + 1))
done
# Sorts first, so its BODY is inside the cap and the sanitising is actually
# exercised rather than skipped along with the rest of the patch.
printf 'BEGIN\033[2A\033[1GPWNED-REPAINT\nEND\n' > "$EXT_SRCS/loud/a-shouty.txt"
ext_publish fix/loud "$EXT_SRCS/loud"
out_l="$(ext_update loud --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "update accepts a commit with many changed files"
assert_contains "$out_l" "more file(s) not shown" \
  "a long diff is capped, and the number of files whose contents were not shown is named"
assert_contains "$out_l" "added     f20.txt" \
  "...while every changed file is still LISTED, capped bodies or not"
assert_contains "$out_l" "Update? [y/N]" "...and the question survives the diff"
case "$out_l" in *$'\033'*) loud_esc=1 ;; *) loud_esc=0 ;; esac
assert_eq "$loud_esc" "0" "no ESC byte from a diff reaches the terminal"
assert_contains "$out_l" "PWNED-REPAINT" \
  "...the text is still shown — the control character is replaced, the line is not hidden"

# --- update re-validates the manifest with every check install applies ------
# A repository that turns bad between two commits is the whole reason this
# command shows a diff; a repository whose MANIFEST turns bad has to be
# refused by the same gate install used, or an extension could acquire a core
# command on an update that install would never have allowed.
ext_src "$EXT_SRCS/turncoat" '{ "name": "turncoat", "contract": 1, "commands": ["turncoat"] }' turncoat
ext_bin "$EXT_SRCS/turncoat" turncoat first
ext_publish fix/turncoat "$EXT_SRCS/turncoat"
ext_install fix/turncoat --yes >/dev/null 2>&1
printf '%s\n' '{ "name": "turncoat", "contract": 1, "commands": ["send"] }' \
  > "$EXT_SRCS/turncoat/roost-ext.json"
ext_bin "$EXT_SRCS/turncoat" send second
ext_publish fix/turncoat "$EXT_SRCS/turncoat"
lock_before="$(cat "$(roost_ext_lock)")"
index_before="$(cat "$EXT_STATE_ROOT/ext.index")"
out_t="$(ext_update turncoat --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "update refuses a manifest that claims a core command at the new commit"
assert_contains "$(cat "$TMP/err")" "which is a roost command" "...naming the reason install would have named"
assert_eq "$(cat "$(roost_ext_lock)")" "$lock_before" "...and leaves ext.lock byte-identical"
assert_eq "$(cat "$EXT_STATE_ROOT/ext.index")" "$index_before" "...and ext.index byte-identical"
grep -q 'MARK=first' "$EXT_DATA/turncoat/bin/roost-turncoat"
assert_true "$?" "...with the commit that was consented to still on disk"
case "$out_t" in *"Update? [y/N]"*) t_late=1 ;; *) t_late=0 ;; esac
assert_eq "$t_late" "0" "...refused BEFORE the prompt, not after it"

# --- silence is never consent, here too -------------------------------------
ext_src "$EXT_SRCS/shy" '{ "name": "shy", "contract": 1, "commands": ["shy"] }' shy
ext_bin "$EXT_SRCS/shy" shy first
ext_publish fix/shy "$EXT_SRCS/shy"
ext_install fix/shy --yes >/dev/null 2>&1
ext_bin "$EXT_SRCS/shy" shy second
ext_publish fix/shy "$EXT_SRCS/shy"
lock_before="$(cat "$(roost_ext_lock)")"
out_s="$(ext_update shy </dev/null 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "a non-tty update without --yes refuses"
assert_contains "$(cat "$TMP/err")" "not a terminal" "...saying why"
assert_contains "$out_s" "Update? [y/N]" "...after printing the block it was asking about"
assert_eq "$(cat "$(roost_ext_lock)")" "$lock_before" "...and leaves ext.lock byte-identical"
grep -q 'MARK=first' "$EXT_DATA/shy/bin/roost-shy"
assert_true "$?" "...with the old commit still installed"

# --- update: a name that is not installed, and one that is not a name -------
out="$(ext_update nosuchext --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "update on an unknown name exits 1"
assert_contains "$(cat "$TMP/err")" "no such extension: nosuchext" "...naming it"
out="$(ext_update ../../../etc --yes 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "update refuses a name that could not have been installed, before it builds a path"
assert_contains "$(cat "$TMP/err")" "no such extension" "...as an unknown extension, not as a traversal that got somewhere"

# --- update: a half-written ext.lock/ext.index pair is not an update --------
# The same requirement install carries, on the command the design says will be
# the one that misses it. Provoked the same way: a lockfile `roost ext list`
# can read but which cannot be turned into a dispatch table -- an entry
# claiming no commands at all.
moving_tree="$(ext_lock_field moving tree)"
cat > "$(roost_ext_lock)" <<JSON
{
  "moving": { "repo": "fix/moving", "ref": "HEAD", "commit": "$moving_2", "tree": "$moving_tree", "contract": 1, "needs": [], "commands": ["moving"], "installed": "2026-01-01T00:00:00Z" },
  "wedged": { "repo": "o/wedged", "commands": [] }
}
JSON
lock_before="$(cat "$(roost_ext_lock)")"
ext_bin "$EXT_SRCS/moving" moving third
ext_publish fix/moving "$EXT_SRCS/moving"
out_w="$(ext_update moving --yes 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "update fails when ext.index cannot be regenerated"
assert_contains "$(cat "$TMP/err")" "could not be turned into a dispatch table" "...saying what failed"
assert_contains "$(cat "$TMP/err")" "moving is unchanged" "...and that the update did not happen"
assert_eq "$(cat "$(roost_ext_lock)")" "$lock_before" \
  "...with ext.lock put back exactly as it was, not left pinning a commit nothing dispatches"
grep -q 'MARK=second' "$EXT_DATA/moving/bin/roost-moving"
assert_true "$?" "...and the clone that was there before the update back on disk"

rm -f "$(roost_ext_lock)"
roost_ext_index_write
rm -rf "$EXT_DATA/moving" "$EXT_DATA/grower" "$EXT_DATA/poison" "$EXT_DATA/turncoat" \
       "$EXT_DATA/shy" "$EXT_DATA/loud"

# --- roost ext remove -------------------------------------------------------
# Two properties, and the second is the one that stops a mistake being a
# disaster: the clone goes, and the extension's own DATA stays unless --purge
# is given, with the retained path printed so a user who removed the wrong
# thing can see their year of bookmarks is still there.
ext_src "$EXT_SRCS/goner" '{
  "name": "goner",
  "contract": 1,
  "needs": ["fleet"],
  "commands": ["goner", "goners"]
}' goner goners
ext_bin "$EXT_SRCS/goner" goner first
ext_publish fix/goner "$EXT_SRCS/goner"
ext_install fix/goner --yes >/dev/null 2>"$TMP/err"
assert_eq "$(cat "$TMP/err")" "" "the remove fixture installs cleanly"
printf 'a year of bookmarks\n' > "$EXT_STATE_ROOT/ext/goner/data.txt"

out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" goner 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "baseline: the extension about to be removed really does resolve"
assert_eq "$(ext_field "$out" ROOST_SOCKET)" "$ROOST_TEST_SOCK" "...with the authority it declared"

out_r="$(ext_remove goner 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "remove exits 0"
assert_eq "$(cat "$TMP/err")" "" "...writing nothing to stderr"
assert_file_absent "$EXT_DATA/goner" "remove deletes the clone"
[ -f "$EXT_STATE_ROOT/ext/goner/data.txt" ]
assert_true "$?" "...and KEEPS the state directory, contents and all"
assert_contains "$out_r" "$EXT_STATE_ROOT/ext/goner" "...printing the retained path"
assert_contains "$out_r" "kept" "...saying in a word that it was kept"
assert_contains "$out_r" "--purge" "...and how to take it away too"

# THE COMMAND STOPS RESOLVING, which is the half that needs ext.index to have
# been regenerated in the same operation as ext.lock -- exactly the obligation
# the design puts on every writer of that file.
out="$(ROOST_SOCKET="$ROOST_TEST_SOCK" PATH="$EXT_PATH" "$ROOST" goner 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "2" "a removed command stops resolving"
assert_eq "$out" "" "...running nothing"
assert_eq "$(cat "$TMP/err")" "$usage_ref" "...and giving the usual usage error, unchanged"
assert_eq "$(ext_index_col goner 3)" "" "ext.index no longer claims the command"
assert_eq "$(ext_index_col goners 3)" "" "...nor the second command the same extension held"
"$HERE/scripts/roost-ext" info goner >/dev/null 2>&1
assert_eq "$?" "1" "and roost ext info no longer knows the name"
# The last entry out takes the file with it: an empty record is not a record,
# and a machine with nothing installed should look exactly like one -- the
# same call install's own rollback makes.
assert_file_absent "$(roost_ext_lock)" "removing the last extension leaves no empty ext.lock behind"

# --- remove --purge takes the state directory too ---------------------------
ext_install fix/goner --yes >/dev/null 2>&1
printf 'a year of bookmarks\n' > "$EXT_STATE_ROOT/ext/goner/data.txt"
out_r="$(ext_remove goner --purge 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "0" "remove --purge exits 0"
assert_file_absent "$EXT_DATA/goner" "--purge deletes the clone"
assert_file_absent "$EXT_STATE_ROOT/ext/goner" "...and the state directory with it"
assert_contains "$out_r" "deleted — --purge" "...saying which flag did it"

# --- remove refuses a name it does not know, and touches nothing ------------
ext_src "$EXT_SRCS/second" '{ "name": "second", "contract": 1, "commands": ["second"] }' second
ext_publish fix/second "$EXT_SRCS/second"
ext_install fix/second --yes >/dev/null 2>&1
lock_before="$(cat "$(roost_ext_lock)")"
index_before="$(cat "$EXT_STATE_ROOT/ext.index")"
out="$(ext_remove nosuchext 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "remove on an unknown name exits 1"
assert_contains "$(cat "$TMP/err")" "no such extension: nosuchext" "...naming it"
assert_eq "$(cat "$(roost_ext_lock)")" "$lock_before" "...and leaves ext.lock byte-identical"
assert_eq "$(cat "$EXT_STATE_ROOT/ext.index")" "$index_before" "...and ext.index byte-identical"
[ -d "$EXT_DATA/second" ]
assert_true "$?" "...with the extension that IS installed untouched"
out="$(ext_remove ../../../etc 2>"$TMP/err")"; rc=$?
assert_eq "$rc" "1" "remove refuses a name that could not have been installed, before it builds a path to delete"
assert_contains "$(cat "$TMP/err")" "no such extension" "...as an unknown extension"
ext_remove >"$TMP/out" 2>"$TMP/err"; rc=$?
assert_eq "$rc" "2" "remove with no NAME is a usage error"
assert_contains "$(cat "$TMP/err")" "usage: roost ext remove NAME [--purge]" "...showing the usage"

# --- remove: a half-written ext.lock/ext.index pair is not a removal --------
# The same obligation install and update carry. This is also where the ORDER
# pays off: the record is written and the index regenerated BEFORE anything is
# deleted, so a failure here leaves the extension exactly as it was rather
# than leaving a lockfile entry pointing at a clone that is already gone.
goner_commit="$(ext_lock_field second commit)"
goner_tree="$(ext_lock_field second tree)"
cat > "$(roost_ext_lock)" <<JSON
{
  "second": { "repo": "fix/second", "ref": "HEAD", "commit": "$goner_commit", "tree": "$goner_tree", "contract": 1, "needs": [], "commands": ["second"], "installed": "2026-01-01T00:00:00Z" },
  "wedged": { "repo": "o/wedged", "commands": [] }
}
JSON
lock_before="$(cat "$(roost_ext_lock)")"
out="$(ext_remove second 2>"$TMP/err")"; rc=$?
[ "$rc" -ne 0 ]
assert_true "$?" "remove fails when ext.index cannot be regenerated"
assert_contains "$(cat "$TMP/err")" "could not be turned into a dispatch table" "...saying what failed"
assert_contains "$(cat "$TMP/err")" "second has not been removed" "...and that the removal did not happen"
assert_eq "$(cat "$(roost_ext_lock)")" "$lock_before" "...with ext.lock put back exactly as it was"
[ -d "$EXT_DATA/second" ]
assert_true "$?" "...and the clone still on disk — the record is written before anything is deleted"

rm -f "$(roost_ext_lock)"
roost_ext_index_write
rm -rf "$EXT_DATA/second" "$EXT_DATA/goner" "$EXT_STATE_ROOT/ext/second" "$EXT_STATE_ROOT/ext/goner"

# --- remove's own engine pair: python3 and jq must agree --------------------
# A FOURTH pair of JSON engines lands with this task -- _ext_lock_drop_py and
# _ext_lock_drop_jq, which take one entry back out of ext.lock. Four separate
# times on this branch a pair that was CLAIMED to agree did not, and each
# divergence was silent and only wrong on a jq-only machine, so the parity
# test lands with the engines rather than after them.
#
# It cannot call the two functions directly -- they live in scripts/roost-ext,
# not in the sourced library -- so it proves the same thing the harnesses
# above it do: run the WHOLE command twice against the same seeded lockfile,
# once under the ambient PATH and once under a PATH carrying jq and no
# python3, and compare everything that came out.
#
# Nothing is INSTALLED in either sandbox: `remove` works off the lockfile, not
# off the clone, so a seeded ext.lock exercises both engines with no fetch at
# all -- and "the clone was already gone" is itself a line both engines have
# to word the same way.
#
# Skipped, not failed, where jq is absent: it is not a roost dependency.
if command -v jq >/dev/null 2>&1; then
  _ext_lock_drop_parity_case() {
    local label="$1" seed="$2" target="$3" engine root rc
    for engine in py jq; do
      root="$TMP/drop-$engine"
      rm -rf "$root"; mkdir -p "$root/state/roost" "$root/data"
      printf '%s\n' "$seed" > "$root/state/roost/ext.lock"
      if [ "$engine" = jq ]; then
        XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" PATH="$TMP/install-jq-only" \
          "$HERE/scripts/roost-ext" remove "$target" >"$TMP/dout-$engine" 2>"$TMP/derr-$engine"
      else
        XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
          "$HERE/scripts/roost-ext" remove "$target" >"$TMP/dout-$engine" 2>"$TMP/derr-$engine"
      fi
      rc=$?
      # Through files rather than through two variables built by `eval`: the
      # engine name is part of the variable name and an eval there is one
      # quoting mistake away from comparing a variable with itself, which is
      # the shape of a parity test that passes while proving nothing.
      printf '%s\n' "$rc" > "$TMP/drc-$engine"
      if [ -f "$root/state/roost/ext.lock" ]; then
        cp "$root/state/roost/ext.lock" "$TMP/dlock-$engine"
      else
        # A REMOVED file and an EMPTY object are different outcomes, and both
        # engines have to reach the same one.
        printf '<no ext.lock>\n' > "$TMP/dlock-$engine"
      fi
      # The engine name is part of the sandbox path, and both engines quote
      # paths back in their output -- so the two roots are normalised away
      # before comparing. Without this the assertion compares ".../drop-py/..."
      # with ".../drop-jq/..." and fails on two answers that agree in every
      # word that matters.
      sed "s|$root|<root>|g" "$TMP/derr-$engine" > "$TMP/derr-$engine.norm"
      sed "s|$root|<root>|g" "$TMP/dout-$engine" > "$TMP/dout-$engine.norm"
    done
    assert_eq "$(cat "$TMP/drc-jq")" "$(cat "$TMP/drc-py")" \
      "both engines agree on the exit status for $label"
    assert_eq "$(cat "$TMP/dlock-jq")" "$(cat "$TMP/dlock-py")" \
      "both engines leave a byte-identical ext.lock for $label"
    assert_eq "$(cat "$TMP/dout-jq.norm")" "$(cat "$TMP/dout-py.norm")" \
      "both engines print the same thing for $label"
    assert_eq "$(cat "$TMP/derr-jq.norm")" "$(cat "$TMP/derr-py.norm")" \
      "both engines agree on the stderr message for $label"
  }
  _ext_lock_drop_parity_case "one of two entries" \
    '{ "parity": { "repo": "o/parity", "commands": ["parity"] }, "mark": { "repo": "o/mark", "commands": ["mark"] } }' parity
  _ext_lock_drop_parity_case "the last entry, which leaves no record at all" \
    '{ "parity": { "repo": "o/parity", "commands": ["parity"] } }' parity
  _ext_lock_drop_parity_case "an entry carrying fields roost does not write, which must survive" \
    '{ "parity": { "commands": ["parity"] }, "mark": { "commands": ["mark"], "future": { "b": 2, "a": [1, {"z": null, "y": true}] } } }' parity
  _ext_lock_drop_parity_case "an entry with a non-ASCII description beside it" \
    '{ "parity": { "commands": ["parity"] }, "mark": { "commands": ["mark"], "description": "caffè — ünïcode" } }' parity
  _ext_lock_drop_parity_case "a name that is not in the lockfile" \
    '{ "mark": { "repo": "o/mark", "commands": ["mark"] } }' parity
  _ext_lock_drop_parity_case "a lockfile that is not an object" '[ "mark" ]' parity
  rm -rf "$TMP/drop-py" "$TMP/drop-jq"
fi

unset -f ext_update ext_remove ext_list ext_bin ext_head
rm -f "$(roost_ext_lock)"
roost_ext_index_write

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
