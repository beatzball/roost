#!/usr/bin/env bash
# tests/test-adapter-install.sh — scripts/roost-install: detection, the plan,
# the prompt, the flags, and the three adapter symlinks.
#
# EVERY case runs against a scratch HOME, XDG_CONFIG_HOME, XDG_DATA_HOME,
# COPILOT_HOME, PI_CODING_AGENT_DIR and CODEX_HOME under one `mktemp -d`, and
# against FAKE harness binaries on a shim PATH. The developer running this
# suite has live agent configuration in ~/.claude, ~/.codex, ~/.copilot,
# ~/.config/opencode and ~/.pi; an installer test that reached any of those
# would rewrite real config on a machine driving real agents. The XDG
# variables are cleared-and-redirected rather than merely left alone for the
# reason tests/test-install.sh's run_install records: a runner that exports
# XDG_CONFIG_HOME sends the write outside the sandbox, which is exactly how
# that leaked in CI while passing locally. And per AGENTS.md §8, XDG is not
# enough on its own — copilot, pi and codex each read their OWN home variable,
# so all three are set here too.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$HERE/scripts/roost-install"

TMP="$(mktemp -d /tmp/amx.XXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- fake harness binaries -------------------------------------------------
# roost-install detects harnesses with `command -v`, so the shim IS the
# machine's harness inventory as far as a case is concerned. It replaces PATH
# outright rather than prepending to it -- tests/test-roost-json.sh's
# build_shim makes the same call for the same reason. The developer running
# this suite really does have claude, codex and opencode installed, so a
# PREPENDED shim would leave the real ones findable and the "a harness that is
# not installed is not mentioned at all" case could never fail.
CORE_BINS="bash sh cat cp mv rm mkdir mktemp dirname readlink ln find grep sed date env printf true false chmod stat"
make_harness_shim() { # make_harness_shim NAME... -> prints a PATH dir
  local dir h real
  dir="$(mktemp -d /tmp/amx.XXXX)"
  for h in $CORE_BINS; do
    real="$(command -v "$h" 2>/dev/null)" && ln -s "$real" "$dir/$h" 2>/dev/null
  done
  for h in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$dir/$h"
    chmod +x "$dir/$h"
  done
  printf '%s' "$dir"
}

# --- one sandboxed run -----------------------------------------------------
# Every harness home lives under $box, so a case can list the whole tree and
# assert on it. stdin is /dev/null unless the caller redirects: the installer
# must treat "no terminal" as no, and a test that inherited the runner's
# stdin would be answering the prompt by accident.
run_install() { # run_install BOX SHIMDIR [args...]
  local box="$1" shim="$2"; shift 2
  mkdir -p "$box"
  HOME="$box/home" \
  XDG_CONFIG_HOME="$box/home/.config" \
  XDG_DATA_HOME="$box/home/.local/share" \
  COPILOT_HOME="$box/home/.copilot" \
  PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
  CODEX_HOME="$box/home/.codex" \
  PATH="$shim" \
    bash "$INSTALL" "$@" </dev/null 2>&1
}

# Same, but with a terminal-less stdin that still carries an answer, for the
# --yes-less paths. (There is no tty here either way; this only proves the
# installer does not read an answer it was never entitled to ask for.)
run_install_stdin() { # run_install_stdin BOX SHIMDIR ANSWER [args...]
  local box="$1" shim="$2" ans="$3"; shift 3
  mkdir -p "$box"
  HOME="$box/home" \
  XDG_CONFIG_HOME="$box/home/.config" \
  XDG_DATA_HOME="$box/home/.local/share" \
  COPILOT_HOME="$box/home/.copilot" \
  PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
  CODEX_HOME="$box/home/.codex" \
  PATH="$shim" \
    bash "$INSTALL" "$@" <<<"$ans" 2>&1
}

# The three paths the installer is allowed to create, expressed the way the
# installer computes them -- via scripts/lib/roost-adapters.sh, not by this
# test restating the table. If the two ever disagree about where an adapter
# goes, that disagreement is the bug, and restating it here would hide it.
adapter_path_in() { # adapter_path_in BOX HARNESS
  local box="$1" h="$2"
  HOME="$box/home" \
  XDG_CONFIG_HOME="$box/home/.config" \
  COPILOT_HOME="$box/home/.copilot" \
  PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
  CODEX_HOME="$box/home/.codex" \
    bash -c '. "'"$HERE"'/scripts/lib/roost-adapters.sh"; roost_adapter_path "$1"' _ "$h"
}
adapter_target() { # adapter_target HARNESS
  bash -c '. "'"$HERE"'/scripts/lib/roost-adapters.sh"; roost_adapter_target "$1"' _ "$1"
}

# tree_of BOX -> a stable, comparable description of everything under the
# sandbox: every path, and for a symlink what it points at. Used by the
# "changed nothing" cases, because "no new file" is not the same claim as
# "nothing was rewritten" -- a relink to a different target adds no path.
tree_of() {
  ( cd "$1" 2>/dev/null && find . | sort | while read -r p; do
      if [ -L "$p" ]; then printf '%s -> %s\n' "$p" "$(readlink "$p")"
      else printf '%s\n' "$p"; fi
    done )
}

ALL_SHIM="$(make_harness_shim opencode pi copilot claude codex)"

# ===========================================================================
# 1. Fresh machine, every harness present -> exactly three symlinks, exit 0
# ===========================================================================
box="$TMP/fresh"
out="$(run_install "$box" "$ALL_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "fresh machine: exits 0"
for h in opencode pi copilot; do
  p="$(adapter_path_in "$box" "$h")"
  [ -L "$p" ]; assert_true $? "fresh machine: $h adapter is a symlink"
  assert_eq "$(readlink "$p" 2>/dev/null)" "$(adapter_target "$h")" \
    "fresh machine: $h symlink points at this checkout"
done
n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "3" "fresh machine: exactly three symlinks were created, no more"

# The plan must name the exact path BEFORE the write, not after. A plan that
# only says "link the opencode adapter" is not something a user can check.
assert_contains "$out" "$(adapter_path_in "$box" opencode)" \
  "fresh machine: the plan names opencode's exact target path"
# Every write gets a one-line undo, or a user who regrets this has to work out
# what was touched from a tree they did not see before.
assert_contains "$out" "rm \"$(adapter_path_in "$box" pi)\"" \
  "fresh machine: a copy-pasteable undo is printed for each link"

# ===========================================================================
# 2. Re-run -> idempotent: zero writes, exit 0
# ===========================================================================
before="$(tree_of "$box")"
out2="$(run_install "$box" "$ALL_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "re-run: exits 0"
assert_eq "$(tree_of "$box")" "$before" "re-run: the sandbox tree is unchanged"
# `ok` says nothing beyond a summary line (spec: "ok -> nothing, and say
# nothing beyond a summary line"), so the per-write undo must NOT reappear --
# printing `rm` lines for links this run did not make is how a user ends up
# deleting a working install.
case "$out2" in
  *"rm \"$(adapter_path_in "$box" pi)\""*) s=printed ;;
  *) s=quiet ;;
esac
assert_eq "$s" "quiet" "re-run: no undo line for a link this run did not create"

# ===========================================================================
# 3. A foreign path -> refused, byte-identical after, named in the output
# ===========================================================================
# Someone's own opencode plugin. This must survive an install run untouched:
# "it is probably ours" is not a good enough reason to delete a file.
box="$TMP/foreign"
mkdir -p "$box/home/.config/opencode/plugin"
printf 'export const mine = true; // not roost\n' > "$box/home/.config/opencode/plugin/roost.js"
fpath="$box/home/.config/opencode/plugin/roost.js"
fbefore="$(cksum < "$fpath")"
out="$(run_install "$box" "$ALL_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "foreign path: still exits 0 (a refusal is not a failure)"
assert_eq "$(cksum < "$fpath")" "$fbefore" "foreign path: the file is byte-identical after"
[ ! -L "$fpath" ]; assert_true $? "foreign path: it was not replaced by a symlink"
assert_contains "$out" "$fpath" "foreign path: the exact path is named in the output"
assert_contains "$out" "rm \"$fpath\"" "foreign path: the manual rm && ln -s is printed"
assert_contains "$out" "ln -s \"$(adapter_target opencode)\"" \
  "foreign path: the manual command names the right target"
# The other two are unaffected by one harness being refused.
[ -L "$(adapter_path_in "$box" pi)" ]; assert_true $? "foreign path: pi is still linked"

# ===========================================================================
# 4. A dangling link -> relinked. It is ours and broken; replacing it loses
#    nothing, which is exactly why roost_adapter_state reports `dangling`
#    separately from `foreign`.
# ===========================================================================
box="$TMP/dangling"
mkdir -p "$box/home/.pi/agent/extensions"
ln -s "$TMP/no-such-checkout/adapters/pi/roost.ts" "$box/home/.pi/agent/extensions/roost.ts"
dpath="$box/home/.pi/agent/extensions/roost.ts"
out="$(run_install "$box" "$ALL_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "dangling link: exits 0"
assert_eq "$(readlink "$dpath")" "$(adapter_target pi)" \
  "dangling link: relinked at this checkout"
assert_contains "$out" "relink" "dangling link: the output says it was a relink, not a fresh link"

# ===========================================================================
# 5. --dry-run -> the plan is printed and NOTHING is written, mkdir included
# ===========================================================================
# --yes is passed DELIBERATELY. Without it this case proves nothing: there is
# no tty in the suite, so the run would decline to write for that reason
# instead, and the assertions below would hold with --dry-run wired to
# nothing at all. Verified by mutation -- with the --dry-run branch disabled,
# the version of this case that omitted --yes still passed.
box="$TMP/dry"
mkdir -p "$box/home"
before="$(tree_of "$box")"
out="$(run_install "$box" "$ALL_SHIM" --dry-run --yes)"; rc=$?
assert_eq "$rc" "0" "--dry-run: exits 0"
assert_eq "$(tree_of "$box")" "$before" "--dry-run: nothing under the sandbox changed"
# Called out separately because `mkdir -p` on the parent is the write that is
# easiest to leave outside a dry-run guard -- it happens before the ln, and it
# leaves an empty directory nobody looks at.
[ ! -d "$box/home/.config/opencode" ]; assert_true $? \
  "--dry-run: no parent directory was created either"
assert_contains "$out" "$(adapter_path_in "$box" copilot)" \
  "--dry-run: the plan still names each exact path"

# ===========================================================================
# 6. Not a tty and no --yes -> nothing is written
# ===========================================================================
# Someone who started this and walked away, or a pipe, or CI, has agreed to
# nothing. Both halves are checked: an empty stdin (walked away) and a stdin
# that actually says "y" -- neither is consent, because neither came from a
# person at a terminal.
box="$TMP/notty"
mkdir -p "$box/home"
before="$(tree_of "$box")"
out="$(run_install "$box" "$ALL_SHIM")"; rc=$?
assert_eq "$rc" "0" "not a tty: exits 0"
assert_eq "$(tree_of "$box")" "$before" "not a tty, no --yes: nothing was written"
assert_contains "$out" "--yes" "not a tty: the output says how to opt in unattended"

box="$TMP/nottyyes"
mkdir -p "$box/home"
before="$(tree_of "$box")"
run_install_stdin "$box" "$ALL_SHIM" y >/dev/null; rc=$?
assert_eq "$rc" "0" "not a tty with 'y' on stdin: exits 0"
assert_eq "$(tree_of "$box")" "$before" \
  "not a tty: a 'y' piped in is not consent and nothing was written"

# ===========================================================================
# 7. --only pi -> pi is linked and nothing else is touched
# ===========================================================================
box="$TMP/onlypi"
out="$(run_install "$box" "$ALL_SHIM" --only pi --yes)"; rc=$?
assert_eq "$rc" "0" "--only pi: exits 0"
[ -L "$(adapter_path_in "$box" pi)" ]; assert_true $? "--only pi: pi is linked"
n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "1" "--only pi: exactly one symlink exists"
# Same stripping as case 9, same two reasons.
body="$(printf '%s' "$out" | sed "s|$HERE||g")"
printf '%s' "$body" | grep -Eqw opencode && s=mentioned || s=absent
assert_eq "$s" "absent" "--only pi: opencode is not even mentioned"

# ===========================================================================
# 8. Unknown flag -> exit 2
# ===========================================================================
box="$TMP/badflag"
mkdir -p "$box/home"
before="$(tree_of "$box")"
out="$(run_install "$box" "$ALL_SHIM" --wat --yes)"; rc=$?
assert_eq "$rc" "2" "unknown flag: exits 2"
assert_eq "$(tree_of "$box")" "$before" "unknown flag: nothing was written"
assert_contains "$out" "--wat" "unknown flag: the offending argument is named"

# An unknown harness name is the same class of caller error.
box="$TMP/badonly"
out="$(run_install "$box" "$ALL_SHIM" --only nosuchharness --yes)"; rc=$?
assert_eq "$rc" "2" "--only with an unknown harness: exits 2"

# --only that names NOTHING must be a usage error, never "no restriction".
# `--only nosuchharness` above takes the unknown-name branch and so proves
# nothing about these: each of the four below used to reduce to an empty
# ONLY_LIST, which in_scope reads as unrestricted -- so the run dropped the
# restriction and linked EVERY harness. `roost install --only="$HARNESS"
# --yes` in a wrapper where $HARNESS is unset is the realistic way in, and
# after Tasks 5-7 the same hole writes claude's settings.json, codex's
# hooks.json and copilot's settings.json on a machine that scoped them out.
# Each case asserts BOTH halves: exit 2, and nothing linked.
i=0
for empty_only in "--only=" "--only,--only-sep" "--only,--only-ws" "--only-space"; do
  i=$((i + 1))
  box="$TMP/emptyonly$i"
  mkdir -p "$box/home"
  case "$empty_only" in
    "--only=")            out="$(run_install "$box" "$ALL_SHIM" --only= --yes)" ;;
    "--only,--only-sep")  out="$(run_install "$box" "$ALL_SHIM" --only , --yes)" ;;
    "--only,--only-ws")   out="$(run_install "$box" "$ALL_SHIM" --only " " --yes)" ;;
    "--only-space")       out="$(run_install "$box" "$ALL_SHIM" --only=, --yes)" ;;
  esac
  rc=$?
  assert_eq "$rc" "2" "--only naming nothing ($empty_only): exits 2"
  n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$n" "0" "--only naming nothing ($empty_only): links nothing"
done

# The complement, so the guard cannot be "reject everything": a real name
# still restricts rather than erroring.
box="$TMP/onlyok"
run_install "$box" "$ALL_SHIM" --only=copilot --yes >/dev/null; rc=$?
assert_eq "$rc" "0" "--only=copilot (the = spelling with a real name): exits 0"
n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "1" "--only=copilot: exactly one symlink"

# ===========================================================================
# 8b. A write that fails -> exit 1
# ===========================================================================
# 0 means "everything it could do succeeded, even with manual steps left", so
# a refusal must NOT be a 1 (case 3 pins that) -- but a write that was
# attempted and did not happen must be. A plain file where pi's parent
# directory has to go makes `mkdir -p` fail without needing root or a
# permission trick that behaves differently in CI.
box="$TMP/writefail"
mkdir -p "$box/home/.pi/agent"
printf 'not a directory\n' > "$box/home/.pi/agent/extensions"
out="$(run_install "$box" "$ALL_SHIM" --yes)"; rc=$?
assert_eq "$rc" "1" "a failed write exits 1"
assert_eq "$(cat "$box/home/.pi/agent/extensions")" "not a directory" \
  "a failed write leaves what was in the way untouched"
# The other harnesses still get linked: one broken path is not a reason to
# abandon the two that would have worked.
[ -L "$(adapter_path_in "$box" opencode)" ]; assert_true $? \
  "a failed write does not abort the harnesses that can be wired"

# ===========================================================================
# 9. A harness that is not installed is not mentioned at all
# ===========================================================================
box="$TMP/onlyopencode"
shim="$(make_harness_shim opencode)"
out="$(run_install "$box" "$shim" --yes)"; rc=$?
assert_eq "$rc" "0" "one harness installed: exits 0"
[ -L "$(adapter_path_in "$box" opencode)" ]; assert_true $? "one harness installed: opencode is linked"
n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "1" "one harness installed: nothing else was linked"
# The checkout's own path is stripped first, and then the harness name is
# matched as a whole WORD. Both matter: this worktree lives under
# `.claude/worktrees/`, so an unstripped output makes `grep -w claude` true no
# matter what the installer said, and an unanchored substring match would fire
# on an mktemp suffix. What is left after stripping is the installer's own
# prose plus the sandbox paths, which is the text the claim is actually about.
body="$(printf '%s' "$out" | sed "s|$HERE||g")"
for absent in pi copilot codex claude; do
  printf '%s' "$body" | grep -Eqw "$absent" && s=mentioned || s=absent
  assert_eq "$s" "absent" "an uninstalled harness ($absent) is not mentioned at all"
done
assert_contains "$out" "Detected: opencode" "one harness installed: only it is listed as detected"
rm -rf "$shim"

# ===========================================================================
# 10. --symlinks-only -> the three links, and no JSON advice at all
# ===========================================================================
# This is the mode `roost validate` calls (`roost install --symlinks-only
# --yes`), so its output has to be about symlinks and nothing else: validate
# writes it into a report that promises "nothing else was written -- no hooks
# file, no trust granted, no settings edited".
box="$TMP/symonly"
out="$(run_install "$box" "$ALL_SHIM" --symlinks-only --yes)"; rc=$?
assert_eq "$rc" "0" "--symlinks-only: exits 0"
n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "3" "--symlinks-only: the three symlinks are still made"
case "$out" in *settings.json*|*hooks.json*) s=mentioned ;; *) s=absent ;; esac
assert_eq "$s" "absent" "--symlinks-only: no JSON file is mentioned"

# A foreign path must survive this mode too -- validate's own policy is
# "never replaces a foreign path", and --symlinks-only is the call it makes.
box="$TMP/symonlyforeign"
mkdir -p "$box/home/.copilot/extensions/roost"
printf 'mine\n' > "$box/home/.copilot/extensions/roost/extension.mjs"
fpath="$box/home/.copilot/extensions/roost/extension.mjs"
fbefore="$(cksum < "$fpath")"
run_install "$box" "$ALL_SHIM" --symlinks-only --yes >/dev/null
assert_eq "$(cksum < "$fpath")" "$fbefore" \
  "--symlinks-only: a foreign path is byte-identical after"

# ===========================================================================
# 11. --print-only -> the hook blocks to paste, from the one shared source
# ===========================================================================
# The bytes must come from scripts/lib/roost-hooks.sh, not from a copy inside
# the installer: codex silently skips any handler whose normalised hash no
# longer matches, so a second copy that drifts by one byte un-badges every
# machine that had already granted trust.
box="$TMP/printonly"
out="$(run_install "$box" "$ALL_SHIM" --print-only --yes)"; rc=$?
assert_eq "$rc" "0" "--print-only: exits 0"
want_line="$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_codex | grep '"command":.*PermissionRequest')"
assert_contains "$out" "$want_line" \
  "--print-only: the codex block is byte-identical to roost_hooks_codex's"
n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "3" "--print-only: the symlinks are still made (it only governs JSON)"

# ===========================================================================
# 12. -h / --help -> usage, exit 0, nothing written
# ===========================================================================
box="$TMP/help"
mkdir -p "$box/home"
before="$(tree_of "$box")"
out="$(run_install "$box" "$ALL_SHIM" --help)"; rc=$?
assert_eq "$rc" "0" "--help: exits 0"
assert_contains "$out" "--symlinks-only" "--help: the flags are documented"
assert_eq "$(tree_of "$box")" "$before" "--help: nothing was written"

# ===========================================================================
# 13. Hygiene
# ===========================================================================
[ -x "$INSTALL" ]; assert_true $? "scripts/roost-install is executable"
bash -n "$INSTALL"; assert_true $? "scripts/roost-install parses as bash"
# bash 3.2 is the floor (AGENTS.md / the spec's global constraints): no
# associative arrays, no ${var^^}, no printf '\uXXXX'.
n="$(grep -cE 'declare -A|\$\{[A-Za-z_]+\^\^|printf .*\\u[0-9a-fA-F]{4}' "$INSTALL" || true)"
assert_eq "${n:-0}" "0" "scripts/roost-install uses no bash-4-only construct"

rm -rf "$ALL_SHIM"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
