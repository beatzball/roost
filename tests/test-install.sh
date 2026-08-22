#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$HERE/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Runs the installer against a sandboxed HOME so a test can never touch the
# developer's real dotfiles.
run_install() { # HOME_SUBDIR SHELL_PATH [args...]
  local home="$TMP/$1"; shift
  local shell_path="$1"; shift
  mkdir -p "$home"
  # Clear ZDOTDIR and the XDG vars too. The installer honours all three, so a
  # runner that exports XDG_CONFIG_HOME would otherwise send fish's config
  # outside the sandbox -- which is exactly how this leaked in CI while
  # passing locally.
  HOME="$home" SHELL="$shell_path" ZDOTDIR= XDG_CONFIG_HOME= XDG_DATA_HOME= \
    sh "$INSTALL" "$@" 2>&1
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
out="$(HOME="$TMP/zdotshome" ZDOTDIR="$TMP/zdot" SHELL=/bin/zsh \
  XDG_CONFIG_HOME= XDG_DATA_HOME= sh "$INSTALL" 2>&1)"
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
HOME="$TMP/bad" SHELL=/bin/zsh sh "$INSTALL" --nonsense >/dev/null 2>&1
assert_eq "$?" "1" "unknown option exits non-zero"
