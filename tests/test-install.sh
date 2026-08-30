#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$HERE/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- the sandbox canary -----------------------------------------------------
# Every variable install.sh -- and the `roost install` it now runs -- can be
# steered by, exported here at one directory that NOTHING in this file may
# write to. Each invocation below overrides all of them; an invocation that
# forgets even one inherits the canary instead, and the check at the very
# bottom of this file fails.
#
# This deliberately IS the shape of the bug rather than a defence against a
# hypothetical one. AGENTS.md §8 records it: a runner that exports COPILOT_HOME
# (or any of the other four) has it inherited straight through a sandboxed
# HOME, and then a test about a PATH line rewrites the developer's live agent
# config. The ZDOTDIR case below did exactly that -- merging roost's hooks into
# the real $CLAUDE_SETTINGS, writing $CODEX_HOME/hooks.json, and linking
# copilot's and pi's extensions -- while its own assertion passed throughout,
# because what that assertion checks is a line in a .zshrc.
#
# So the guard is a leak detector and not a comment asking the next person to
# remember: the case that leaked had a green assertion the whole time, and the
# only thing that would have caught it is something watching the paths.
#
# HOME is not canaried. Every invocation here has always set it, and pointing
# it at the canary would trip on the unrelated writes a `roost help` or a git
# lookup makes; the five harness homes, ZDOTDIR and the XDG pair are the ones
# that get forgotten, and they are exactly the set AGENTS.md §8 lists.
CANARY="$TMP/canary"
export ZDOTDIR="$CANARY/zdot"
export XDG_CONFIG_HOME="$CANARY/xdg-config"
export XDG_DATA_HOME="$CANARY/xdg-data"
export COPILOT_HOME="$CANARY/copilot"
export PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export CODEX_HOME="$CANARY/codex"
export CLAUDE_SETTINGS="$CANARY/claude/settings.json"

# What escaped, if anything. -mindepth 1 so the directory itself is never the
# finding, and the whole listing is printed on failure rather than a count --
# which path leaked names the variable that was missed.
canary_leaks() { find "$CANARY" -mindepth 1 2>/dev/null | sort; }

# Runs the installer against a sandboxed HOME so a test can never touch the
# developer's real dotfiles.
#
# $RUN_ZDOTDIR, when the caller sets it for one call, is the ONE sandbox value
# a case may choose: zsh's dotfile directory is the subject of a case below,
# and routing that case through here rather than spelling its own environment
# is what keeps the other six pinned. Unset means cleared, as before.
run_install() { # HOME_SUBDIR SHELL_PATH [args...]
  local home="$TMP/$1"; shift
  local shell_path="$1"; shift
  mkdir -p "$home"
  # Clear ZDOTDIR and the XDG vars too. The installer honours all three, so a
  # runner that exports XDG_CONFIG_HOME would otherwise send fish's config
  # outside the sandbox -- which is exactly how this leaked in CI while
  # passing locally.
  #
  # The four harness homes are redirected as well, because install.sh now ends
  # by running `roost install`, which writes to them. Per AGENTS.md §8 the XDG
  # pair is NOT enough on its own: copilot, pi and codex each read their own
  # variable, and claude's names a FILE. A runner exporting any of those would
  # otherwise have it inherited straight through the sandboxed HOME and the
  # developer's live agent config rewritten by a test about a PATH line.
  #
  # stdin is /dev/null, never the runner's. install.sh asks `[ -t 0 ]` to
  # decide whether the wiring may prompt, so a suite run by hand in a terminal
  # would otherwise sit at a 60-second prompt in every case here.
  HOME="$home" SHELL="$shell_path" ZDOTDIR="${RUN_ZDOTDIR:-}" \
  XDG_CONFIG_HOME= XDG_DATA_HOME= \
  COPILOT_HOME="$home/.copilot" PI_CODING_AGENT_DIR="$home/.pi/agent" \
  CODEX_HOME="$home/.codex" CLAUDE_SETTINGS="$home/.claude/settings.json" \
    sh "$INSTALL" "$@" </dev/null 2>&1
}
rc_line() { printf '%s' "$1" | sed -n '/roost: shell is/{n;s/^  //;p;}'; }

# POSIX sh, not bash: the documented install is piped into `sh`, which is dash
# on Debian derivatives. A bashism would break the most common path.
sh -n "$INSTALL"
assert_eq "$?" "0" "install.sh parses as POSIX sh"

# --- each shell gets the file it actually reads -------------------------

out="$(run_install zsh /bin/zsh)"
assert_contains "$(rc_line "$out")" ".zshrc" "zsh -> .zshrc"

mkdir -p "$TMP/zdot"
out="$(RUN_ZDOTDIR="$TMP/zdot" run_install zdotshome /bin/zsh)"
assert_contains "$(rc_line "$out")" "zdot/.zshrc" "zsh honours ZDOTDIR"

# macOS terminals start LOGIN shells, which never read .bashrc.
if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$TMP/bmac"; : > "$TMP/bmac/.bashrc"; : > "$TMP/bmac/.bash_profile"
  out="$(run_install bmac /bin/bash)"
  assert_contains "$(rc_line "$out")" ".bash_profile" "bash on macOS -> .bash_profile"
fi

mkdir -p "$TMP/fishhome"
out="$(run_install fishhome /usr/bin/fish)"
fish_rc="$(rc_line "$out")"
assert_contains "$fish_rc" "config.fish" "fish -> config.fish"
# Read back the file the installer said it wrote, rather than one the test
# assumes -- if those two ever disagree, that is itself the bug.
assert_contains "$(cat "$fish_rc" 2>/dev/null)" "fish_add_path" \
  "fish gets fish_add_path, not export"

# An unknown shell must print instructions rather than guess at a file.
out="$(run_install kshhome /bin/ksh)"
assert_contains "$out" "unrecognised shell" "unknown shell is reported"
assert_contains "$out" "export PATH" "unknown shell still gets a copyable line"

# --- safety properties --------------------------------------------------

# Re-running must not stack duplicate PATH entries.
run_install rerun /bin/zsh >/dev/null
out="$(run_install rerun /bin/zsh)"
assert_contains "$out" "already on PATH" "second run is a no-op"
# Match the real bin directory, not a literal "roost/bin": a checkout (or a
# git worktree) can live in a directory with any name at all.
n="$(grep -cF "$HERE/bin" "$TMP/rerun/.zshrc")"
assert_eq "$n" "1" "PATH line is not duplicated"

# --dry-run must not write anything.
mkdir -p "$TMP/dry"; : > "$TMP/dry/.zshrc"
before="$(cksum < "$TMP/dry/.zshrc")"
out="$(run_install dry /bin/zsh --dry-run)"
assert_contains "$out" "would append" "dry run says what it would do"
assert_eq "$(cksum < "$TMP/dry/.zshrc")" "$before" "dry run leaves the rc file untouched"

# --- symlink mode -------------------------------------------------------

mkdir -p "$TMP/lb"
out="$(run_install lbhome /bin/zsh --symlink "$TMP/lb")"
assert_eq "$([ -L "$TMP/lb/roost" ] && echo yes)" "yes" "--symlink creates a symlink"
assert_eq "$("$TMP/lb/roost" help >/dev/null 2>&1; echo $?)" "0" "roost runs through the symlink"
assert_contains "$out" "not on your PATH" "warns when the link dir is not on PATH"

# `--symlink --dry-run` must not swallow the following flag as its value.
out="$(run_install optval /bin/zsh --symlink --dry-run)"
assert_contains "$out" "would run" "--symlink treats a following flag as absent, not as its value"

# An unknown option fails loudly rather than silently installing something else.
# Through run_install like everything else: this one dies in the argument loop,
# long before the wiring step, but "it exits early" is a property of today's
# code and not of the sandbox -- and the sandbox is what has to hold.
run_install bad /bin/zsh --nonsense >/dev/null
assert_eq "$?" "1" "unknown option exits non-zero"

# --- wiring: install.sh finishes the job -----------------------------------
# install.sh places `roost` and then runs `roost install` to wire the agents,
# so that installing is one step rather than three.
#
# These cases replace PATH outright with a shim carrying core tools and ONE
# fake harness. The developer running this suite really does have claude,
# codex and opencode installed, so a prepended shim would leave the real ones
# findable and the run would depend on this machine's inventory --
# tests/test-adapter-install.sh's make_harness_shim makes the same call for
# the same reason. Only `opencode` is faked, which keeps the plan to a single
# adapter symlink and off the JSON path entirely.
#
# `tr` and `cut` are deliberately not on this list and must not be used by
# anything it runs: an earlier round of this work called `tr` on a thin PATH,
# where it silently did nothing at all.
WIRE_BINS="bash sh cat cp mv rm mkdir mktemp dirname basename readlink ln find grep sed date env printf true false chmod stat cmp uname git"
WIRE_SHIM="$(mktemp -d "$TMP/shim.XXXX")"
for b in $WIRE_BINS; do
  real="$(command -v "$b" 2>/dev/null)" && ln -s "$real" "$WIRE_SHIM/$b" 2>/dev/null
done
printf '#!/bin/sh\nexit 0\n' > "$WIRE_SHIM/opencode"; chmod +x "$WIRE_SHIM/opencode"

# One wiring run. `env -i` rather than a prefix assignment: it drops every
# variable the runner exported, so nothing of the developer's environment --
# an exported COPILOT_HOME, a live $TMUX -- can reach the installer.
#
# stdin is a PIPE CARRYING TEXT, which is what `curl ... | sh` really is. Not
# a terminal, so install.sh must not prompt; and the "n" sitting there must
# not be mistaken for an answer, because under curl those bytes are the rest
# of the script rather than anything a person typed.
run_wire() { # run_wire BOX [args...]
  local box="$TMP/$1"; shift
  mkdir -p "$box/home"
  printf 'n\n' | env -i \
    HOME="$box/home" SHELL=/bin/zsh PATH="$WIRE_SHIM" \
    XDG_CONFIG_HOME="$box/home/.config" XDG_DATA_HOME="$box/home/.local/share" \
    COPILOT_HOME="$box/home/.copilot" PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
    CODEX_HOME="$box/home/.codex" CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
    sh "$INSTALL" "$@" 2>&1
}

# Where the adapter goes, asked of the table the installer itself reads rather
# than restated here. If the two ever disagree, that disagreement is the bug.
wire_adapter() { # wire_adapter BOX
  XDG_CONFIG_HOME="$TMP/$1/home/.config" \
    bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_adapter_path opencode' _ "$HERE"
}

# Every path under a box, and for a symlink what it points at: "no new file"
# is not the same claim as "nothing was rewritten", since a relink to a
# different target adds no path. (Same shape as tree_of in
# tests/test-adapter-install.sh.)
wire_tree() { # wire_tree BOX
  ( cd "$TMP/$1" 2>/dev/null && find . | sort | while read -r f; do
      if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
      else printf '%s\n' "$f"; fi
    done )
}

# The piped install: no terminal, so nothing can be asked -- it wires anyway,
# and says so before it does.
out="$(run_wire wired)"
assert_contains "$out" "WIRING YOUR AGENTS -- nothing to answer" \
  "the piped install announces the wiring before it runs"
assert_contains "$out" "Every file it edits is backed up first" \
  "the notice says every edited file is backed up"
assert_contains "$out" "Skip this entirely: re-run install.sh with --no-wire." \
  "the notice names the way out"
link="$(wire_adapter wired)"
assert_eq "$([ -L "$link" ] && echo yes)" "yes" "the piped install wires the adapter"
assert_eq "$(readlink "$link")" "$HERE/adapters/opencode/roost.js" \
  "the adapter points at this checkout"
assert_contains "$(cat "$TMP/wired/home/.zshrc" 2>/dev/null)" "$HERE/bin" \
  "the piped install still does the PATH step"

# --no-wire: the PATH step and nothing else.
out="$(run_wire nowire --no-wire)"
assert_contains "$(cat "$TMP/nowire/home/.zshrc" 2>/dev/null)" "$HERE/bin" \
  "--no-wire still does the PATH step"
assert_file_absent "$(wire_adapter nowire)" "--no-wire writes no adapter"
assert_contains "$out" "Your agents were not wired: --no-wire." \
  "--no-wire says why nothing was wired"

# --dry-run must reach the installer's OWN --dry-run rather than skip the step,
# and still change nothing anywhere -- adapter paths included.
mkdir -p "$TMP/drywire/home"; : > "$TMP/drywire/home/.zshrc"
before="$(wire_tree drywire)"
out="$(run_wire drywire --dry-run)"
assert_contains "$out" "--dry-run: nothing above was written." \
  "--dry-run reaches the installer's own dry run"
assert_eq "$(wire_tree drywire)" "$before" \
  "--dry-run changes nothing, adapter paths included"

# A wiring run that fails must not take the PATH step down with it: that step
# already succeeded, and undoing it would leave the user with neither half.
# The failure is forced with a checkout whose bin/roost exits 3, because the
# real one has no reliable way to fail on demand.
FAKE="$TMP/fakeco"
mkdir -p "$FAKE/bin" "$FAKE/tmux"
cp "$INSTALL" "$FAKE/install.sh"; : > "$FAKE/tmux/roost.conf"
printf '#!/bin/sh\nexit 3\n' > "$FAKE/bin/roost"; chmod +x "$FAKE/bin/roost"
mkdir -p "$TMP/wirefail/home"
out="$(printf 'n\n' | env -i \
  HOME="$TMP/wirefail/home" SHELL=/bin/zsh PATH="$WIRE_SHIM" \
  XDG_CONFIG_HOME="$TMP/wirefail/home/.config" \
  sh "$FAKE/install.sh" 2>&1)"
assert_eq "$?" "0" "a failed wiring run does not fail the install"
assert_contains "$out" "roost install exited 3" "the failure is reported with its status"
assert_contains "$out" "but the wiring did not finish" "the closing block says wiring is unfinished"
assert_contains "$(cat "$TMP/wirefail/home/.zshrc" 2>/dev/null)" "$FAKE/bin" \
  "the PATH step survives a failed wiring run"

# --- nothing escaped the sandbox --------------------------------------------
# Last, because it has to see every invocation above.
#
# The detector is checked before it is trusted. "Found nothing" is exactly what
# a detector aimed at the wrong path also says, and this suite has been fooled
# by that shape more than once -- a probe pointed at a filename the code never
# reads, a `tr` that silently deleted its own input. So make it find something
# first, then ask it about the real thing.
mkdir -p "$CANARY"; : > "$CANARY/detector-check"
assert_contains "$(canary_leaks)" "detector-check" \
  "the sandbox canary reports a file when there is one"
rm -f "$CANARY/detector-check"

assert_eq "$(canary_leaks)" "" \
  "no install.sh invocation wrote outside its sandbox"
