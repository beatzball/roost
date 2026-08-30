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
# `cmp` is on this list because scripts/lib/roost-json.sh uses it to decide
# whether a merge changed anything -- without it every merge would look like a
# change, take a backup, and rewrite a file it did not need to touch, and the
# "no backup when nothing is written" cases would pass or fail for a reason
# that has nothing to do with the installer.
#
# python3 and jq are DELIBERATELY absent. A shim built by make_harness_shim is
# a machine with no JSON tool at all, which is the degraded path Task 5 has to
# keep working; make_json_shim below is the same machine with one.
CORE_BINS="bash sh cat cp mv rm mkdir mktemp dirname readlink ln find grep sed date env printf true false chmod stat cmp"
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

# make_one_tool_shim TOOL NAME... -> a shim carrying exactly ONE JSON engine.
# scripts/lib/roost-json.sh prefers python3 whenever it is there, and so does
# the installer's own probe, so on this machine the jq branch of both would
# never run. tests/test-roost-json.sh forces each engine for the same reason.
make_one_tool_shim() { # make_one_tool_shim TOOL NAME... -> prints a PATH dir
  local tool="$1"; shift
  local dir real
  dir="$(make_harness_shim "$@")"
  real="$(command -v "$tool" 2>/dev/null)" && ln -s "$real" "$dir/$tool" 2>/dev/null
  printf '%s' "$dir"
}

# make_json_shim NAME... -> the same, plus whichever of python3 and jq this
# machine has. Every case that expects the installer to EDIT a JSON file must
# use this one: roost_json_merge returns 3 and writes nothing when neither
# tool is on PATH, so a merge case built on make_harness_shim would assert the
# degraded path while claiming to assert the write.
make_json_shim() { # make_json_shim NAME... -> prints a PATH dir
  local dir t real
  dir="$(make_harness_shim "$@")"
  for t in python3 jq; do
    real="$(command -v "$t" 2>/dev/null)" && ln -s "$real" "$dir/$t" 2>/dev/null
  done
  printf '%s' "$dir"
}

# --- one sandboxed run -----------------------------------------------------
# Every harness home lives under $box, so a case can list the whole tree and
# assert on it. stdin is /dev/null unless the caller redirects: the installer
# must treat "no terminal" as no, and a test that inherited the runner's
# stdin would be answering the prompt by accident.
#
# CLAUDE_SETTINGS is set EXPLICITLY, not left to default off the sandboxed
# $HOME. It resolves to the same path the default would give, so no case
# behaves differently -- but claude is the one harness whose override names a
# FILE, and a runner that happens to export CLAUDE_SETTINGS pointing at their
# real ~/.claude/settings.json would otherwise have it inherited straight
# through the redirected HOME and merged into for real. AGENTS.md §8: find the
# harness's own variable, do not assume redirecting HOME is enough.
run_install() { # run_install BOX SHIMDIR [args...]
  local box="$1" shim="$2"; shift 2
  mkdir -p "$box"
  HOME="$box/home" \
  XDG_CONFIG_HOME="$box/home/.config" \
  XDG_DATA_HOME="$box/home/.local/share" \
  COPILOT_HOME="$box/home/.copilot" \
  PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
  CODEX_HOME="$box/home/.codex" \
  CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
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
  CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
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
  CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
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

# hook_blocks -> reads text on stdin, prints one canonical JSON object per
# line for every embedded {...} block that carries a "hooks" key.
#
# Filtered on "hooks" rather than emitting every object found, because the
# copilot note in the manual list also contains a JSON object
# ({"enabledFeatureFlags": {"EXTENSIONS": true}}) and it is printed
# unconditionally -- it is a one-line snippet in a sentence, not one of the
# blocks --print-only governs. Scoping to hook blocks keeps these two
# assertions about the thing they actually claim.
#
# Whitespace-insensitive on purpose, and that is a measured decision rather
# than a convenience: codex hashes the PARSED handler struct, not the file
# bytes. Verified on codex-cli 0.151.0 via its `hooks/list` app-server method
# against a scratch CODEX_HOME -- unindented and 2-space-indented hooks.json
# gave identical HookMetadata.currentHash for all four handlers, while
# changing one "timeout": 10 to 11 moved all four (the positive control that
# proves the probe was sensitive). So the installer indenting a printed block
# to fit its manual list is harmless, and the thing worth pinning is the
# parsed structure.
#
# Key order is NOT sorted away: json.dumps keeps insertion order, so a
# reordered event map or a reordered handler still fails here.
hook_blocks() {
  python3 -c '
import json, sys
text = sys.stdin.read()
dec = json.JSONDecoder()
i = 0
while True:
    i = text.find("{", i)
    if i < 0:
        break
    try:
        obj, end = dec.raw_decode(text, i)
    except ValueError:
        i += 1
        continue
    if isinstance(obj, dict):
        if "hooks" in obj:
            sys.stdout.write(json.dumps(obj) + "\n")
        i = end
    else:
        i += 1
'
}

ALL_SHIM="$(make_harness_shim opencode pi copilot claude codex)"
# The same machine, with a JSON tool on it. ALL_SHIM has none by construction,
# so it is the "neither python3 nor jq" machine; this one is the ordinary one.
ALL_JSON_SHIM="$(make_json_shim opencode pi copilot claude codex)"

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

# The half of --only that is a SAFETY invariant rather than a convenience, and
# the reason scripts/roost-install spells it out at length above in_scope: the
# blast radius of getting --only wrong used to be three symlinks, and since
# Tasks 5-7 it is claude's settings.json, codex's hooks.json and copilot's
# settings.json edited on a machine whose caller explicitly scoped them out.
# The shim carries every harness AND a JSON tool, so all three writes are
# fully possible here -- nothing but the restriction stops them.
box="$TMP/onlyjsonscoped"
out="$(run_install "$box" "$ALL_JSON_SHIM" --only opencode --yes)"; rc=$?
assert_eq "$rc" "0" "--only opencode: exits 0"
[ -L "$(adapter_path_in "$box" opencode)" ]; assert_true $? "--only opencode: opencode is linked"
for scoped_out in "$box/home/.claude/settings.json" \
                  "$box/home/.codex/hooks.json" \
                  "$box/home/.copilot/settings.json"; do
  assert_file_absent "$scoped_out" \
    "--only opencode: $(basename "$(dirname "$scoped_out")")/$(basename "$scoped_out") was not written"
done

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
# This is the mode `roost validate` WILL call (`roost install --symlinks-only
# --yes`) -- not yet: roost install is not dispatched from bin/roost until
# Task 9, and roost-validate still carries its own offer_adapter_install until
# Task 10. Pinned now anyway, because it is the reason the mode exists:
# validate writes its result into a report that promises "nothing else was
# written -- no hooks file, no trust granted, no settings edited", so this
# output has to be about symlinks and nothing else.
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
if command -v python3 >/dev/null 2>&1; then
  # The WHOLE block, both harnesses, compared against the lib's own output --
  # not one grepped line of one of them. Fidelity is the entire justification
  # for --print-only, so a check that reads a single line leaves a reordered
  # event map, a dropped "matcher" or an untouched-looking claude block
  # entirely uncovered.
  got_blocks="$(printf '%s\n' "$out" | hook_blocks)"
  want_claude="$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_claude | hook_blocks)"
  want_codex="$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_codex | hook_blocks)"
  assert_eq "$got_blocks" "$(printf '%s\n%s' "$want_claude" "$want_codex")" \
    "--print-only: the printed claude and codex blocks match roost-hooks.sh exactly"
else
  assert_true 0 "--print-only block comparison skipped (python3 needed)"
fi
n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "3" "--print-only: the symlinks are still made (it only governs JSON)"

# The other direction, which nothing covered: a NORMAL run must print no JSON
# block at all. Without this, wiring PRINT_ONLY permanently on is a mutation
# the suite survives -- case 10 skips the branch via --symlinks-only, and
# cases 7 and 9 have no claude or codex detected, so none of them can see it.
#
# The shim here carries a JSON tool, and that is the whole point. Since Task 5
# a run WITHOUT one prints the block on purpose -- that is the degraded path,
# pinned in section 13 -- so building this case on ALL_SHIM would assert the
# opposite of what it claims and go green either way.
box="$TMP/noprint"
out="$(run_install "$box" "$ALL_JSON_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "a normal run: exits 0"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "$(printf '%s\n' "$out" | hook_blocks)" "" \
    "a normal run prints no hook block -- that is what --print-only is for"
fi

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
# 13. claude: the four hooks are merged into settings.json
# ===========================================================================
# Every case here that expects a WRITE uses make_json_shim. roost_json_merge
# returns 3 and writes nothing when neither python3 nor jq is on PATH, so the
# same case built on make_harness_shim would quietly assert the degraded path
# while claiming to assert the merge. The no-tool machine gets its own case at
# the end of this section, because that path is a promise too.
CLAUDE_SHIM="$(make_json_shim claude opencode)"

# bak_of FILE -> the newest FILE.roost-bak-* beside FILE, or nothing.
# bak_count FILE -> how many of them there are.
#
# Two helpers rather than one: "no backup was taken" and "the backup holds the
# pre-run bytes" are different claims, and a case almost always wants exactly
# one of them. A backup taken when nothing was subsequently written is a bug
# (scripts/lib/roost-json.sh's roost_json_backup header says so), which is why
# the count is asserted as often as the content.
bak_of()    { ls -1 "$1".roost-bak-* 2>/dev/null | sort | tail -1; }
bak_count() { ls -1 "$1".roost-bak-* 2>/dev/null | wc -l | tr -d ' '; }

# claude_event FILE EVENT -> that event's entry from FILE, canonicalised.
# claude_want EVENT       -> the same entry as roost-hooks.sh prints it.
# Compared against each other rather than against a copy of the JSON typed
# out here: a second copy of those bytes in this file is the drift the whole
# one-definition rule exists to prevent.
claude_event() {
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(json.dumps(d.get("hooks", {}).get(sys.argv[2])))' "$1" "$2"
}
claude_want() {
  ( . "$HERE/scripts/lib/roost-hooks.sh"
    roost_hooks_claude "$HERE/scripts/roost-agent-state" ) | python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)["hooks"][sys.argv[1]]))' "$1"
}

# --- an existing settings.json: roost's four go in, everything else stays ---
box="$TMP/claudemerge"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
cat > "$cset" <<'EOF'
{
  "unrelatedTopLevelKey": "keep-me",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo unrelated-hook" } ] }
    ]
  }
}
EOF
cbefore="$(cat "$cset")"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude merge: exits 0"
after="$(cat "$cset")"
assert_contains "$after" "keep-me" "claude merge: an unrelated top-level key survives"
assert_contains "$after" "echo unrelated-hook" "claude merge: an unrelated hook survives"
if command -v python3 >/dev/null 2>&1; then
  for ev in UserPromptSubmit Notification PostToolUse Stop; do
    assert_eq "$(claude_event "$cset" "$ev")" "$(claude_want "$ev")" \
      "claude merge: the $ev entry is roost-hooks.sh's own, structure for structure"
  done
fi
bak="$(bak_of "$cset")"
assert_eq "$(bak_count "$cset")" "1" "claude merge: exactly one backup was taken"
assert_eq "$(cat "$bak" 2>/dev/null)" "$cbefore" \
  "claude merge: the backup holds the pre-run bytes"
# The sentinel matters: with no backup taken $bak is empty, and
# assert_contains against an empty needle passes no matter what was printed.
assert_contains "$out" "${bak:-NO-BACKUP-WAS-TAKEN}" "claude merge: the backup path is printed"
# A JSON round-trip reindents the whole file. Someone who diffs their
# settings.json afterwards and finds every line changed needs to have been
# told why, and where the original went.
assert_contains "$out" "two spaces" \
  "claude merge: the output says the round-trip renormalises indentation to two spaces"

# --- already wired to THIS checkout -> untouched, and no backup ------------
box="$TMP/claudeagain"
cset="$box/home/.claude/settings.json"
run_install "$box" "$CLAUDE_SHIM" --yes >/dev/null
[ -f "$cset" ]; assert_true $? "claude: a first run creates settings.json when there was none"
assert_eq "$(bak_count "$cset")" "0" \
  "claude: creating a file that did not exist takes no backup"
cbefore="$(cat "$cset")"
before="$(tree_of "$box")"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude re-run: exits 0"
assert_eq "$(cat "$cset")" "$cbefore" "claude re-run: settings.json is byte-identical"
assert_eq "$(bak_count "$cset")" "0" "claude re-run: no backup was taken"
assert_eq "$(tree_of "$box")" "$before" "claude re-run: nothing under the sandbox changed"
# Named, not just "Already correct" -- opencode is already linked on a re-run
# too, so the bare phrase is printed whatever claude did. Without naming it,
# a mutation that plans the merge anyway and lets roost_json_merge discover it
# is a no-op survives this whole case: the file does come back byte-identical
# and no backup is taken, because the merge itself is idempotent.
assert_contains "$out" "Already correct: opencode, claude" \
  "claude re-run: claude is named as already correct"
case "$out" in *"merge  $cset"*) s=planned ;; *) s=absent ;; esac
assert_eq "$s" "absent" "claude re-run: no write is even PLANNED for it"

# --- already wired, but the file is indented some other way ----------------
# The distinction the case above cannot draw. roost_json_merge compares the
# rendered bytes, so a file that already says the right thing in 4-space
# indentation is NOT byte-identical to what it would write -- it would be
# reindented, backed up and rewritten, for no change anyone asked for. The
# installer has to answer "is this already wired" from the PARSED document,
# and this is the case that proves it does.
box="$TMP/claudereindent"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
if command -v python3 >/dev/null 2>&1; then
  ( . "$HERE/scripts/lib/roost-hooks.sh"
    roost_hooks_claude "$HERE/scripts/roost-agent-state" ) \
    | python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.load(sys.stdin), indent=4) + "\n")' > "$cset"
  fbefore="$(cksum < "$cset")"
  out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "claude already wired at another indentation: exits 0"
  assert_eq "$(cksum < "$cset")" "$fbefore" \
    "claude already wired at another indentation: the file is byte-identical after"
  assert_eq "$(bak_count "$cset")" "0" \
    "claude already wired at another indentation: no backup was taken"
fi

# --- wired to a DIFFERENT checkout -> refuse the whole claude step ---------
# Generated from roost-hooks.sh with another checkout's path, not typed out
# here: a second copy of those bytes is exactly the drift the one-definition
# rule exists to prevent, and a hand-typed near-miss would make this case pass
# for the wrong reason.
box="$TMP/claudeforeign"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
( . "$HERE/scripts/lib/roost-hooks.sh"
  roost_hooks_claude "$TMP/some-other-checkout/scripts/roost-agent-state" ) > "$cset"
fbefore="$(cksum < "$cset")"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude wired elsewhere: still exits 0 (a refusal is not a failure)"
assert_eq "$(cksum < "$cset")" "$fbefore" \
  "claude wired elsewhere: settings.json is byte-identical after"
assert_eq "$(bak_count "$cset")" "0" "claude wired elsewhere: no backup was taken"
assert_contains "$out" "$cset" "claude wired elsewhere: the exact file is named"
assert_contains "$out" "different checkout" \
  "claude wired elsewhere: the output says why it will not touch it"
[ -L "$(adapter_path_in "$box" opencode)" ]; assert_true $? \
  "claude wired elsewhere: refusing one step does not abandon the others"

# --- someone ELSE's hook in one of the four events -> kept, roost added ----
# roost's entry JOINS the event's array; the user's stays. This is not a
# preference: hooks-merge used to assign over the whole array, and a
# PostToolUse carrying a formatter came back with that entry gone -- rc 0,
# backup taken, nothing printed. A PostToolUse formatter or linter is one of
# the most common Claude Code setups. Refusing the whole step instead would
# have denied roost to exactly the people most likely to want it, so the fix
# is in scripts/lib/roost-json.sh and this case pins the caller's half.
box="$TMP/claudeuserhook"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
cat > "$cset" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "Edit",
        "hooks": [ { "type": "command", "command": "my-own-formatter" } ] }
    ]
  }
}
EOF
cbefore="$(cat "$cset")"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude beside a user's own hook: exits 0"
if command -v python3 >/dev/null 2>&1; then
  # The MATCHER is asserted, not just the command. It is the field a
  # rebuild-from-the-command-string implementation would quietly drop, and
  # losing it silently widens a hook the user had scoped to Edit.
  assert_eq "$(claude_event "$cset" PostToolUse | python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)[0]))')" \
    '{"matcher": "Edit", "hooks": [{"type": "command", "command": "my-own-formatter"}]}' \
    "claude beside a user's own hook: their entry survives with its matcher, value for value"
  assert_eq "$(claude_event "$cset" PostToolUse | python3 -c 'import json,sys
print(len(json.load(sys.stdin)))')" "2" \
    "claude beside a user's own hook: roost's entry joins it rather than replacing it"
  assert_eq "$(claude_event "$cset" PostToolUse | python3 -c 'import json,sys
print(json.load(sys.stdin)[1]["hooks"][0]["command"])')" \
    "$HERE/scripts/roost-agent-state working" \
    "claude beside a user's own hook: roost's entry is the one that was added"
fi
assert_eq "$(bak_count "$cset")" "1" "claude beside a user's own hook: a backup was taken"
assert_eq "$(cat "$(bak_of "$cset")" 2>/dev/null)" "$cbefore" \
  "claude beside a user's own hook: the backup holds the pre-run bytes"
# Requirement: a user with their own hooks must be able to SEE they were kept,
# without going and diffing the file.
# The phrasing from the WRITING block, not the bare word: the plan line above
# also says the entry is kept, so a needle of "kept" alone goes green with the
# line that reports what actually happened deleted.
assert_contains "$out" "kept the 1 entry already in those events" \
  "claude beside a user's own hook: the write says the existing entry was kept"

# Re-running must not stack a second roost entry beside it. Asserted as a
# COUNT: "roost's hook is present" stays true while duplicates pile up one per
# run, so presence alone cannot see this.
cbefore="$(cat "$cset")"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude beside a user's own hook, re-run: exits 0"
assert_eq "$(cat "$cset")" "$cbefore" \
  "claude beside a user's own hook, re-run: settings.json is byte-identical"
assert_eq "$(bak_count "$cset")" "1" \
  "claude beside a user's own hook, re-run: no second backup was taken"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "$(claude_event "$cset" PostToolUse | python3 -c 'import json,sys
print(len(json.load(sys.stdin)))')" "2" \
    "claude beside a user's own hook, re-run: still exactly two entries"
fi
assert_contains "$out" "Already correct: opencode, claude" \
  "claude beside a user's own hook, re-run: nothing left to do"

# --- malformed settings.json -> exit 1, no write, no backup ----------------
box="$TMP/claudebad"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
printf '{ this is not json\n' > "$cset"
fbefore="$(cksum < "$cset")"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "1" "claude malformed settings.json: exits 1"
assert_eq "$(cksum < "$cset")" "$fbefore" \
  "claude malformed settings.json: the file is byte-identical after"
assert_eq "$(bak_count "$cset")" "0" "claude malformed settings.json: no backup was taken"

# --- neither python3 nor jq -> print the block, still link, still exit 0 ---
# ALL_SHIM has no JSON tool by construction. The symlinks are unaffected by
# the JSON steps, and the block is printed for the user to merge by hand --
# the honest degraded path, not an error.
box="$TMP/claudenotool"
cset="$box/home/.claude/settings.json"
out="$(run_install "$box" "$ALL_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude with no JSON tool: exits 0"
assert_file_absent "$cset" "claude with no JSON tool: settings.json is not written"
n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "3" "claude with no JSON tool: the symlinks are still made"
if command -v python3 >/dev/null 2>&1; then
  want_claude="$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_claude | hook_blocks)"
  printf '%s\n' "$out" | hook_blocks | grep -qxF "$want_claude" && s=printed || s=absent
  assert_eq "$s" "printed" \
    "claude with no JSON tool: the block is printed exactly as roost hooks prints it"
fi
assert_contains "$out" "python3" \
  "claude with no JSON tool: the output says WHY it printed instead of writing"

# --- --dry-run with a JSON tool present -> still writes literally nothing --
# The no-tool cases above cannot see this: with no tool there is nothing to
# suppress. Without a JSON tool on the shim, wiring --dry-run to nothing at
# all is a mutation the suite survives.
box="$TMP/claudedry"
mkdir -p "$box/home"
before="$(tree_of "$box")"
out="$(run_install "$box" "$CLAUDE_SHIM" --dry-run --yes)"; rc=$?
assert_eq "$rc" "0" "claude --dry-run: exits 0"
assert_eq "$(tree_of "$box")" "$before" "claude --dry-run: nothing under the sandbox changed"
[ ! -d "$box/home/.claude" ]; assert_true $? \
  "claude --dry-run: not even the parent directory was created"
# Matched against the PLAN line, not merely the path: the closing manual block
# names that path too, so a bare path match would go green with the plan entry
# missing entirely.
assert_contains "$out" "merge  $box/home/.claude/settings.json" \
  "claude --dry-run: the plan still names the exact file and what it would do"

# --- --print-only with a JSON tool present -> still writes nothing ---------
# The no-tool cases cannot see this one: with no tool there is nothing for
# --print-only to suppress, so wiring the flag to nothing at all would survive
# them. Here a write is fully possible and must still not happen.
box="$TMP/claudeprintonly"
mkdir -p "$box/home"
out="$(run_install "$box" "$CLAUDE_SHIM" --print-only --yes)"; rc=$?
assert_eq "$rc" "0" "claude --print-only: exits 0"
assert_file_absent "$box/home/.claude/settings.json" \
  "claude --print-only: settings.json is not written even though a JSON tool is there"
n="$(find "$box/home" -type l 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "1" "claude --print-only: the symlink is still made (it only governs JSON)"
if command -v python3 >/dev/null 2>&1; then
  want_claude="$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_claude | hook_blocks)"
  printf '%s\n' "$out" | hook_blocks | grep -qxF "$want_claude" && s=printed || s=absent
  assert_eq "$s" "printed" "claude --print-only: the block is printed instead"
fi

# --- a SYMLINKED settings.json -> write through to the real file -----------
# Keeping ~/.claude/settings.json symlinked into a dotfiles repo is common in
# this audience, and `[ -f ]` follows the link, so the file reads as present
# and an unwary `mv` drops a regular file over the link: the dotfiles repo
# stops seeing the change and the user's VCS never notices. The temp file has
# to land in the REAL file's directory for the write to stay atomic anyway.
box="$TMP/claudelink"
mkdir -p "$box/home/.claude" "$box/dotfiles"
real="$box/dotfiles/settings.json"
link="$box/home/.claude/settings.json"
printf '{\n  "unrelatedTopLevelKey": "keep-me"\n}\n' > "$real"
rbefore="$(cat "$real")"
ln -s "$real" "$link"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude via a symlink: exits 0"
[ -L "$link" ]; assert_true $? "claude via a symlink: the symlink is still a symlink"
assert_eq "$(readlink "$link")" "$real" "claude via a symlink: it still points where it did"
assert_contains "$(cat "$real")" "roost-agent-state" \
  "claude via a symlink: the REAL file is the one that got the hooks"
assert_contains "$(cat "$real")" "keep-me" \
  "claude via a symlink: the real file kept its other keys"
assert_eq "$(bak_count "$real")" "1" \
  "claude via a symlink: the backup sits beside the real file"
assert_eq "$(cat "$(bak_of "$real")" 2>/dev/null)" "$rbefore" \
  "claude via a symlink: that backup holds the real file's pre-run bytes"
assert_eq "$(bak_count "$link")" "0" \
  "claude via a symlink: no backup was dropped beside the link"
assert_contains "$out" "$real" \
  "claude via a symlink: the output says which file it actually wrote"

# --- the same merge, driven by jq instead of python3 -----------------------
# Both engines have to reach the same verdict, because which one a machine has
# is not the user's choice to make. The interesting half is the REFUSAL: an
# engine that answered "merge" where the other answered "other-checkout" would
# silently rewrite a file the other one protects.
if command -v jq >/dev/null 2>&1; then
  JQ_SHIM="$(make_one_tool_shim jq claude opencode)"

  box="$TMP/claudejq"
  cset="$box/home/.claude/settings.json"
  mkdir -p "$box/home/.claude"
  printf '{\n  "unrelatedTopLevelKey": "keep-me"\n}\n' > "$cset"
  out="$(run_install "$box" "$JQ_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "claude under jq: exits 0"
  assert_contains "$(cat "$cset")" "keep-me" "claude under jq: the other keys survive"
  assert_contains "$(cat "$cset")" "$HERE/scripts/roost-agent-state done --stop-hook" \
    "claude under jq: the hooks point at this checkout"
  assert_eq "$(bak_count "$cset")" "1" "claude under jq: exactly one backup was taken"
  # And a second run changes nothing, which is the jq half of the
  # already-wired probe.
  cbefore="$(cat "$cset")"
  run_install "$box" "$JQ_SHIM" --yes >/dev/null
  assert_eq "$(cat "$cset")" "$cbefore" "claude under jq: a re-run is byte-identical"
  assert_eq "$(bak_count "$cset")" "1" "claude under jq: a re-run takes no second backup"

  # The append path under jq. The probe has a whole second implementation for
  # this engine, and "kept somebody else's entry" is the branch where getting
  # it wrong destroys data rather than merely reporting oddly.
  box="$TMP/claudejqappend"
  cset="$box/home/.claude/settings.json"
  mkdir -p "$box/home/.claude"
  cat > "$cset" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "Edit",
        "hooks": [ { "type": "command", "command": "my-own-formatter" } ] }
    ]
  }
}
EOF
  out="$(run_install "$box" "$JQ_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "claude under jq, beside a user's hook: exits 0"
  assert_eq "$(jq -c '.hooks.PostToolUse[0]' "$cset" 2>/dev/null)" \
    '{"matcher":"Edit","hooks":[{"type":"command","command":"my-own-formatter"}]}' \
    "claude under jq, beside a user's hook: their entry survives with its matcher"
  assert_eq "$(jq '.hooks.PostToolUse | length' "$cset" 2>/dev/null)" "2" \
    "claude under jq, beside a user's hook: roost's entry joins it"
  assert_contains "$out" "kept the 1 entry already in those events" \
    "claude under jq, beside a user's hook: the write says what was kept"
  cbefore="$(cat "$cset")"
  run_install "$box" "$JQ_SHIM" --yes >/dev/null
  assert_eq "$(cat "$cset")" "$cbefore" \
    "claude under jq, beside a user's hook: a re-run is byte-identical"
  assert_eq "$(jq '.hooks.PostToolUse | length' "$cset" 2>/dev/null)" "2" \
    "claude under jq, beside a user's hook: a re-run adds no second entry"

  box="$TMP/claudejqforeign"
  cset="$box/home/.claude/settings.json"
  mkdir -p "$box/home/.claude"
  ( . "$HERE/scripts/lib/roost-hooks.sh"
    roost_hooks_claude "$TMP/some-other-checkout/scripts/roost-agent-state" ) > "$cset"
  fbefore="$(cksum < "$cset")"
  out="$(run_install "$box" "$JQ_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "claude under jq, wired elsewhere: exits 0"
  assert_eq "$(cksum < "$cset")" "$fbefore" \
    "claude under jq, wired elsewhere: the file is byte-identical after"
  assert_eq "$(bak_count "$cset")" "0" \
    "claude under jq, wired elsewhere: no backup was taken"
  assert_contains "$out" "different checkout" \
    "claude under jq, wired elsewhere: refused for the same stated reason"
  rm -rf "$JQ_SHIM"
fi

# --- the installer's target script and roost-hooks.sh's default agree ------
# The installer has to name the target script to pass it to roost_json_merge,
# and roost-hooks.sh names its own default independently. Two spellings of one
# path, and if they ever drift the installer writes hooks pointing at a script
# that is not there -- silently, because a hook that cannot exec just never
# badges. Pinned by rendering the block both ways and comparing.
inst_target="$(sed -n 's/^CLAUDE_TARGET="\$HERE\(.*\)"$/\1/p' "$INSTALL")"
assert_eq "$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_claude "$HERE$inst_target")" \
          "$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_claude)" \
  "the installer's CLAUDE_TARGET is the same path roost-hooks.sh defaults to"

# ===========================================================================
# 14. codex: write hooks.json, and never rewrite one
# ===========================================================================
# The stakes here are different from claude's, and higher. Codex stores a hash
# of each normalised handler and silently SKIPS any handler whose hash no
# longer matches -- nothing on stdout, nothing on stderr, nothing in the TUI.
# So the two things worth pinning are that what roost writes is exactly what
# `roost hooks codex` prints, and that an entry already on disk is never
# rewritten.
CODEX_SHIM="$(make_json_shim codex opencode)"

# codex_hooks_of FILE -> the whole .hooks object, canonicalised.
# codex_hooks_want   -> the same object as roost-hooks.sh prints it.
#
# Compared as parsed structures, and that is a MEASURED choice rather than a
# convenience: on codex-cli 0.151.0 the hash covers the parsed handler struct,
# not the file bytes -- an unindented and a 2-space-indented hooks.json gave
# identical HookMetadata.currentHash for all four handlers, while changing one
# "timeout": 10 to 11 moved all four. Key order is NOT sorted away: json.dumps
# keeps insertion order, so a reordered event map still fails here.
codex_hooks_of() {
  python3 -c 'import json,sys
print(json.dumps(json.load(open(sys.argv[1])).get("hooks")))' "$1"
}
codex_hooks_want() {
  ( . "$HERE/scripts/lib/roost-hooks.sh"
    roost_hooks_codex "$HERE/adapters/codex/roost-codex-hook" ) | python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)["hooks"]))'
}
codex_event_of() {
  python3 -c 'import json,sys
print(json.dumps(json.load(open(sys.argv[1])).get("hooks", {}).get(sys.argv[2])))' "$1" "$2"
}

# --- no hooks.json at all -> write all four handlers -----------------------
box="$TMP/codexnew"
chooks="$box/home/.codex/hooks.json"
out="$(run_install "$box" "$CODEX_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "codex fresh: exits 0"
[ -f "$chooks" ]; assert_true $? "codex fresh: hooks.json was written"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "$(codex_hooks_of "$chooks")" "$(codex_hooks_want)" \
    "codex fresh: the four handlers are exactly roost-hooks.sh's own object"
fi
assert_eq "$(bak_count "$chooks")" "0" \
  "codex fresh: creating a file that did not exist takes no backup"
# Unconditional and permanent. Until a human answers this, codex runs no hook
# at all and says nothing about it -- there is no file on disk that records
# the answer and no tool can answer it for them.
assert_contains "$out" "Trust all and continue" \
  "codex fresh: the trust step is printed after a write"

# --- a hooks.json that already has somebody else's handler -----------------
box="$TMP/codexother"
chooks="$box/home/.codex/hooks.json"
mkdir -p "$box/home/.codex"
cat > "$chooks" <<'EOF'
{
  "hooks": {
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "echo unrelated", "timeout": 5 } ] }
    ]
  }
}
EOF
cbefore="$(cat "$chooks")"
if command -v python3 >/dev/null 2>&1; then
  keep_before="$(codex_event_of "$chooks" SessionEnd)"
fi
out="$(run_install "$box" "$CODEX_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "codex merge: exits 0"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "$(codex_event_of "$chooks" SessionEnd)" "$keep_before" \
    "codex merge: the unrelated handler is kept, value for value"
  for ev in UserPromptSubmit PostToolUse PermissionRequest Stop; do
    assert_eq "$(codex_event_of "$chooks" "$ev")" \
      "$(codex_hooks_want | python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$ev")" \
      "codex merge: the $ev handler is roost-hooks.sh's own, value for value"
  done
fi
assert_eq "$(bak_count "$chooks")" "1" "codex merge: exactly one backup was taken"
assert_eq "$(cat "$(bak_of "$chooks")" 2>/dev/null)" "$cbefore" \
  "codex merge: the backup holds the pre-run bytes"
assert_contains "$out" "Trust all and continue" \
  "codex merge: the trust step is printed after a write"

# --- already this checkout -> nothing, and no backup -----------------------
box="$TMP/codexagain"
chooks="$box/home/.codex/hooks.json"
run_install "$box" "$CODEX_SHIM" --yes >/dev/null
cbefore="$(cat "$chooks")"
out="$(run_install "$box" "$CODEX_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "codex re-run: exits 0"
assert_eq "$(cat "$chooks")" "$cbefore" "codex re-run: hooks.json is byte-identical"
assert_eq "$(bak_count "$chooks")" "0" "codex re-run: no backup was taken"
case "$out" in *"merge  $chooks"*) s=planned ;; *) s=absent ;; esac
assert_eq "$s" "absent" "codex re-run: no write is even PLANNED for it"
# Still printed, even though this run wrote nothing. There is no way to read
# the answer off the disk, so the only safe assumption is that it may not have
# been given.
assert_contains "$out" "Trust all and continue" \
  "codex re-run: the trust step is printed anyway -- nothing can detect it"

# --- a roost entry pointing at a DIFFERENT checkout -> refuse --------------
# This is the one place in this command where helpfully fixing something is
# worse than doing nothing. Rewriting the command string re-hashes the
# handler, and codex then skips it in silence, so a machine that was badging
# correctly would simply stop.
box="$TMP/codexforeign"
chooks="$box/home/.codex/hooks.json"
mkdir -p "$box/home/.codex"
( . "$HERE/scripts/lib/roost-hooks.sh"
  roost_hooks_codex "$TMP/some-other-checkout/adapters/codex/roost-codex-hook" ) > "$chooks"
fbefore="$(cksum < "$chooks")"
out="$(run_install "$box" "$CODEX_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "codex wired elsewhere: still exits 0 (a refusal is not a failure)"
assert_eq "$(cksum < "$chooks")" "$fbefore" \
  "codex wired elsewhere: hooks.json is byte-identical after"
assert_eq "$(bak_count "$chooks")" "0" "codex wired elsewhere: no backup was taken"
assert_contains "$out" "$chooks" "codex wired elsewhere: the exact file is named"
assert_contains "$out" "different checkout" \
  "codex wired elsewhere: the output says what it found"
assert_contains "$out" "re-hash" \
  "codex wired elsewhere: the output says in plain words why rewriting would be worse"
[ -L "$(adapter_path_in "$box" opencode)" ]; assert_true $? \
  "codex wired elsewhere: refusing one step does not abandon the others"

# --- somebody else's handler on one of roost's OWN four events -> kept -----
# codex's events are arrays too, so roost's handler joins rather than
# replacing. Safe by the measured hash fact: the hash codex stores is per
# handler and over the parsed struct, so a new neighbour arriving in the same
# array is invisible to an already-trusted handler.
box="$TMP/codexclash"
chooks="$box/home/.codex/hooks.json"
mkdir -p "$box/home/.codex"
cat > "$chooks" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "somebody-elses-codex-hook", "timeout": 3 } ] }
    ]
  }
}
EOF
cbefore="$(cat "$chooks")"
out="$(run_install "$box" "$CODEX_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "codex beside another tool's handler: exits 0"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "$(codex_event_of "$chooks" PostToolUse | python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)[0]))')" \
    '{"hooks": [{"type": "command", "command": "somebody-elses-codex-hook", "timeout": 3}]}' \
    "codex beside another tool's handler: theirs survives, value for value"
  assert_eq "$(codex_event_of "$chooks" PostToolUse | python3 -c 'import json,sys
print(len(json.load(sys.stdin)))')" "2" \
    "codex beside another tool's handler: roost's is appended, not substituted"
  assert_eq "$(codex_event_of "$chooks" PostToolUse | python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)[1]))')" \
    "$(codex_hooks_want | python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)["PostToolUse"][0]))')" \
    "codex beside another tool's handler: roost's handler is byte-exact where it landed"
fi
assert_eq "$(bak_count "$chooks")" "1" "codex beside another tool's handler: a backup was taken"
assert_eq "$(cat "$(bak_of "$chooks")" 2>/dev/null)" "$cbefore" \
  "codex beside another tool's handler: the backup holds the pre-run bytes"
assert_contains "$out" "kept the 1 entry already in those events" \
  "codex beside another tool's handler: the write says the existing entry was kept"
cbefore="$(cat "$chooks")"
run_install "$box" "$CODEX_SHIM" --yes >/dev/null
assert_eq "$(cat "$chooks")" "$cbefore" \
  "codex beside another tool's handler, re-run: hooks.json is byte-identical"
assert_eq "$(bak_count "$chooks")" "1" \
  "codex beside another tool's handler, re-run: no second backup"

# --- malformed hooks.json -> exit 1, no write, no backup -------------------
# The codex half of the claude case in section 13. Same code path, but the
# path is only proven for the mode it is exercised in -- and a hooks.json
# hand-edited into invalidity is exactly the state a codex user gets into.
box="$TMP/codexbad"
chooks="$box/home/.codex/hooks.json"
mkdir -p "$box/home/.codex"
printf '{ "hooks": { "Stop": [ }\n' > "$chooks"
fbefore="$(cksum < "$chooks")"
out="$(run_install "$box" "$CODEX_SHIM" --yes)"; rc=$?
assert_eq "$rc" "1" "codex malformed hooks.json: exits 1"
assert_eq "$(cksum < "$chooks")" "$fbefore" \
  "codex malformed hooks.json: the file is byte-identical after"
assert_eq "$(bak_count "$chooks")" "0" "codex malformed hooks.json: no backup was taken"
assert_contains "$out" "Trust all and continue" \
  "codex malformed hooks.json: the trust step is still printed"

# --- no JSON tool -> print the block, still exit 0, still say to trust -----
box="$TMP/codexnotool"
chooks="$box/home/.codex/hooks.json"
out="$(run_install "$box" "$ALL_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "codex with no JSON tool: exits 0"
assert_file_absent "$chooks" "codex with no JSON tool: hooks.json is not written"
if command -v python3 >/dev/null 2>&1; then
  want_codex="$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_codex | hook_blocks)"
  printf '%s\n' "$out" | hook_blocks | grep -qxF "$want_codex" && s=printed || s=absent
  assert_eq "$s" "printed" \
    "codex with no JSON tool: the block is printed exactly as roost hooks prints it"
fi
assert_contains "$out" "Trust all and continue" \
  "codex with no JSON tool: the trust step is still printed"

# --- the installer's codex target and roost-hooks.sh's default agree -------
codex_inst_target="$(sed -n 's/^CODEX_TARGET="\$HERE\(.*\)"$/\1/p' "$INSTALL")"
assert_eq "$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_codex "$HERE$codex_inst_target")" \
          "$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_codex)" \
  "the installer's CODEX_TARGET is the same path roost-hooks.sh defaults to"

# ===========================================================================
# 15. copilot: the EXTENSIONS feature flag
# ===========================================================================
# COPILOT_HOME, never the XDG path -- AGENTS.md §8 exists for this harness
# specifically. run_install sets it, and the path below is spelled the way the
# installer computes it rather than restated from the docs.
COPILOT_SHIM="$(make_json_shim copilot)"

# --- an existing settings.json -> the flag lands, the rest survives --------
box="$TMP/copilotflag"
cps="$box/home/.copilot/settings.json"
mkdir -p "$box/home/.copilot"
cat > "$cps" <<'EOF'
{
  "theme": "dark",
  "enabledFeatureFlags": {
    "SOME_OTHER_FLAG": true
  }
}
EOF
cbefore="$(cat "$cps")"
out="$(run_install "$box" "$COPILOT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "copilot flag: exits 0"
after="$(cat "$cps")"
assert_contains "$after" '"EXTENSIONS": true' "copilot flag: the flag is set"
assert_contains "$after" '"SOME_OTHER_FLAG": true' "copilot flag: the neighbouring flag survives"
assert_contains "$after" '"theme": "dark"' "copilot flag: the unrelated top-level key survives"
assert_eq "$(bak_count "$cps")" "1" "copilot flag: exactly one backup was taken"
assert_eq "$(cat "$(bak_of "$cps")" 2>/dev/null)" "$cbefore" \
  "copilot flag: the backup holds the pre-run bytes"

# --- already true -> no write, no backup ----------------------------------
# Written on ONE line on purpose. roost_json_merge compares rendered bytes, so
# a canonically-indented fixture would come back identical whatever the
# installer decided and this case would pass with the "already set" check
# wired to nothing. Here the merge WOULD rewrite the file (reindenting it and
# taking a backup) unless the flag is read from the parsed document first.
box="$TMP/copilotset"
cps="$box/home/.copilot/settings.json"
mkdir -p "$box/home/.copilot"
printf '{"enabledFeatureFlags":{"EXTENSIONS":true},"theme":"dark"}\n' > "$cps"
fbefore="$(cksum < "$cps")"
out="$(run_install "$box" "$COPILOT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "copilot flag already true: exits 0"
assert_eq "$(cksum < "$cps")" "$fbefore" \
  "copilot flag already true: settings.json is byte-identical after"
assert_eq "$(bak_count "$cps")" "0" "copilot flag already true: no backup was taken"
case "$out" in *"merge  $cps"*) s=planned ;; *) s=absent ;; esac
assert_eq "$s" "absent" "copilot flag already true: no write is even PLANNED for it"

# --- explicitly FALSE -> it must be turned on -----------------------------
# scripts/roost-doctor:233 greps for the flag's NAME and says so in its own
# comment: a file that sets it to false reads as set. The installer cannot
# afford that reading -- it would leave the extension off forever while
# reporting success.
box="$TMP/copilotfalse"
cps="$box/home/.copilot/settings.json"
mkdir -p "$box/home/.copilot"
printf '{"enabledFeatureFlags":{"EXTENSIONS":false}}\n' > "$cps"
out="$(run_install "$box" "$COPILOT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "copilot flag set to false: exits 0"
assert_contains "$(cat "$cps")" '"EXTENSIONS": true' \
  "copilot flag set to false: it is turned on rather than read as already set"

# --- no settings.json at all -> it is created, and no backup --------------
box="$TMP/copilotnew"
cps="$box/home/.copilot/settings.json"
out="$(run_install "$box" "$COPILOT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "copilot fresh: exits 0"
assert_contains "$(cat "$cps" 2>/dev/null)" '"EXTENSIONS": true' \
  "copilot fresh: settings.json is created with the flag on"
assert_eq "$(bak_count "$cps")" "0" \
  "copilot fresh: creating a file that did not exist takes no backup"

# --- malformed -> exit 1, no write, no backup -----------------------------
box="$TMP/copilotbad"
cps="$box/home/.copilot/settings.json"
mkdir -p "$box/home/.copilot"
printf 'not json at all\n' > "$cps"
fbefore="$(cksum < "$cps")"
out="$(run_install "$box" "$COPILOT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "1" "copilot malformed settings.json: exits 1"
assert_eq "$(cksum < "$cps")" "$fbefore" \
  "copilot malformed settings.json: the file is byte-identical after"
assert_eq "$(bak_count "$cps")" "0" "copilot malformed settings.json: no backup was taken"

# --- the per-directory approval notice, on every path ---------------------
# Copilot asks once per directory to approve the extension ("wants to: handle
# permission requests") and denying stops it loading. scripts/roost-doctor:239
# records that choosing plain "Yes" persists NOTHING, so there is no file to
# read and no way to tell "not yet asked" from "denied". It is a prompt no
# tool can answer, not a step waiting to be automated, so it is printed
# whatever this run did -- including the run that wrote nothing at all.
for probe in copilotflag copilotset copilotnew; do
  out="$(run_install "$TMP/$probe" "$COPILOT_SHIM" --yes)"
  assert_contains "$out" "wants to: handle permission requests" \
    "copilot ($probe): the per-directory approval notice is printed"
done
out="$(run_install "$TMP/copilotnotool" "$ALL_SHIM" --yes)"
assert_contains "$out" "wants to: handle permission requests" \
  "copilot with no JSON tool: the per-directory approval notice is printed"
assert_file_absent "$TMP/copilotnotool/home/.copilot/settings.json" \
  "copilot with no JSON tool: settings.json is not written"

# ===========================================================================
# 16. Saying when the checkout itself is behind its upstream
# ===========================================================================
# `roost update` is an alias for `roost install` (Task 9), so people will
# reasonably expect it to update roost's own code. It does not, and must not:
# the checkout may be someone's dev tree with local work in it. All this does
# is SAY so, from what git already knows locally -- never a fetch, which would
# be a surprise network call inside an installer, and never a pull.
if command -v git >/dev/null 2>&1; then
  # A scratch checkout carrying the files roost-install needs to run. Copies,
  # not symlinks: the installer resolves its own location through a symlink
  # chain (that is how it refuses to trust an inherited $ROOST_HOME), so a
  # symlink here would resolve straight back to the real worktree and every
  # case below would be measuring THIS repo's upstream instead of the
  # fixture's.
  mkcheckout() { # mkcheckout DIR
    mkdir -p "$1/scripts/lib"
    cp "$HERE/scripts/roost-install" "$1/scripts/roost-install"
    cp "$HERE/scripts/lib/roost-adapters.sh" \
       "$HERE/scripts/lib/roost-hooks.sh" \
       "$HERE/scripts/lib/roost-json.sh" "$1/scripts/lib/"
  }
  # An empty hooks directory, and a fixture identity. These repos exist for
  # four seconds inside a mktemp dir; pointing them at an empty hooksPath
  # keeps the machine's global hooks (which scan staged content and commit
  # messages for a real identity) out of a fixture that has neither, and
  # naming an identity here means the case does not depend on the runner
  # having one configured.
  mkdir -p "$TMP/nohooks"
  fixture_git() { git -c core.hooksPath="$TMP/nohooks" \
                      -c user.email=roost-tests@example.invalid \
                      -c user.name='roost tests' -c commit.gpgsign=false "$@"; }

  # A recording git for the RUN itself: log the arguments, then hand over to
  # the real one. `pull` or `fetch` appearing in that log is the failure this
  # step exists to prevent, and it cannot be seen any other way -- a fetch
  # against an up-to-date remote changes nothing observable on disk.
  gitlog="$TMP/git-invocations.log"
  : > "$gitlog"
  GIT_SHIM="$(make_json_shim opencode)"
  cat > "$GIT_SHIM/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$gitlog"
exec "$(command -v git)" "\$@"
EOF
  chmod +x "$GIT_SHIM/git"

  # run_install drives \$INSTALL, and these cases need the copy inside the
  # fixture rather than the one in this worktree. Swapping the variable reuses
  # the one sandboxed harness (all five home variables, a replaced PATH)
  # instead of growing a second one that could drift out of step with it.
  real_install="$INSTALL"

  # --- one commit behind -> say so, and touch nothing -----------------------
  origin="$TMP/gitorigin"
  mkcheckout "$origin"
  fixture_git -C "$origin" init -q
  fixture_git -C "$origin" add -A
  fixture_git -C "$origin" commit -q -m "fixture"
  # NOT "gitbehind": the installer prints this path in its header, so a fixture
  # directory carrying the word would make the "says nothing about being
  # behind" cases below match the path instead of a note.
  co="$TMP/gitclone"
  fixture_git clone -q "$origin" "$co"
  printf 'later\n' > "$origin/NEWER"
  fixture_git -C "$origin" add -A
  fixture_git -C "$origin" commit -q -m "one more"
  # The fetch that makes the clone KNOW it is behind happens here, in the
  # setup, precisely because the installer is not allowed to do it.
  fixture_git -C "$co" fetch -q
  upname="$(git -C "$co" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"

  INSTALL="$co/scripts/roost-install"
  : > "$gitlog"
  out="$(run_install "$TMP/gitclonebox" "$GIT_SHIM" --yes)"; rc=$?
  INSTALL="$real_install"
  assert_eq "$rc" "0" "behind upstream: exits 0 (it is a note, not a problem)"
  assert_contains "$out" "1 commit behind $upname" \
    "behind upstream: the line names how far behind and what it tracks"
  # Resolved with `cd -P`, because the installer resolves its OWN location
  # that way and /tmp is a symlink to /private/tmp on macOS -- the raw $co
  # would never match, on that platform only.
  co_real="$(cd -P "$co" && pwd)"
  assert_contains "$out" "git -C \"$co_real\" pull" \
    "behind upstream: the line prints the command to run, against the right checkout"
  grep -Eq '(^| )(pull|fetch)( |$)' "$gitlog" && s=ran || s=never
  assert_eq "$s" "never" "behind upstream: the run neither pulled nor fetched"
  assert_eq "$(git -C "$co" rev-parse HEAD)" \
            "$(git -C "$origin" rev-parse 'HEAD^')" \
    "behind upstream: the checkout is still where it was"

  # --- no harness on PATH at all -> the note still gets out -----------------
  # A different exit path: with nothing detected the command says so and
  # leaves early, and a note printed only on the other branch would be missing
  # exactly where someone is most likely to be looking at a stale checkout.
  NOHARNESS_SHIM="$(make_json_shim)"
  cp "$GIT_SHIM/git" "$NOHARNESS_SHIM/git"
  INSTALL="$co/scripts/roost-install"
  out="$(run_install "$TMP/gitclonenone" "$NOHARNESS_SHIM" --yes)"; rc=$?
  INSTALL="$real_install"
  assert_eq "$rc" "0" "behind upstream, no harness: exits 0"
  assert_contains "$out" "no supported harness found" \
    "behind upstream, no harness: it still says nothing was found"
  assert_contains "$out" "1 commit behind $upname" \
    "behind upstream, no harness: the note is printed on that path too"
  rm -rf "$NOHARNESS_SHIM"

  # --- up to date -> silent -------------------------------------------------
  fixture_git -C "$co" merge -q --ff-only "$upname"
  INSTALL="$co/scripts/roost-install"
  out="$(run_install "$TMP/gitcurrentbox" "$GIT_SHIM" --yes)"; rc=$?
  INSTALL="$real_install"
  assert_eq "$rc" "0" "up to date: exits 0"
  case "$out" in *behind*) s=said ;; *) s=silent ;; esac
  assert_eq "$s" "silent" "up to date: nothing is said about being behind"

  # --- a repo with no upstream -> silent ------------------------------------
  noup="$TMP/gitnoupstream"
  mkcheckout "$noup"
  fixture_git -C "$noup" init -q
  fixture_git -C "$noup" add -A
  fixture_git -C "$noup" commit -q -m "fixture"
  INSTALL="$noup/scripts/roost-install"
  out="$(run_install "$TMP/gitnoupbox" "$GIT_SHIM" --yes)"; rc=$?
  INSTALL="$real_install"
  assert_eq "$rc" "0" "no upstream: exits 0"
  case "$out" in *behind*) s=said ;; *) s=silent ;; esac
  assert_eq "$s" "silent" "no upstream: nothing is said about being behind"
  case "$out" in *fatal*|*"no upstream"*) s=leaked ;; *) s=quiet ;; esac
  assert_eq "$s" "quiet" "no upstream: git's own complaint is not printed at the user"

  # --- not a git repo at all (a tarball install) -> silent ------------------
  tarball="$TMP/gittarball"
  mkcheckout "$tarball"
  INSTALL="$tarball/scripts/roost-install"
  out="$(run_install "$TMP/gittarballbox" "$GIT_SHIM" --yes)"; rc=$?
  INSTALL="$real_install"
  assert_eq "$rc" "0" "not a repo: exits 0"
  case "$out" in *fatal*|*"not a git repository"*|*behind*) s=said ;; *) s=silent ;; esac
  assert_eq "$s" "silent" "not a repo: no git error and no note -- a tarball install is normal"

  rm -rf "$GIT_SHIM"
else
  assert_true 0 "upstream-note cases skipped (git needed)"
fi

# ===========================================================================
# 17. Hygiene
# ===========================================================================
[ -x "$INSTALL" ]; assert_true $? "scripts/roost-install is executable"
bash -n "$INSTALL"; assert_true $? "scripts/roost-install parses as bash"
# bash 3.2 is the floor (AGENTS.md / the spec's global constraints): no
# associative arrays, no ${var^^}, no printf '\uXXXX'.
n="$(grep -cE 'declare -A|\$\{[A-Za-z_]+\^\^|printf .*\\u[0-9a-fA-F]{4}' "$INSTALL" || true)"
assert_eq "${n:-0}" "0" "scripts/roost-install uses no bash-4-only construct"

rm -rf "$ALL_SHIM" "$ALL_JSON_SHIM" "$CLAUDE_SHIM" "$CODEX_SHIM" "$COPILOT_SHIM"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
