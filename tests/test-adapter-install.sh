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
# a machine with no JSON tool at all, which is the degraded path the claude,
# codex and copilot writes have to keep working -- they print the block to
# paste instead; make_json_shim below is the same machine with one.
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

# make_versioned_shim VERSIONLINE NAME... -> the same shim as make_harness_shim,
# except that the `opencode` stub prints VERSIONLINE, the way a real one
# answers `opencode --version` (`1.18.30` on 1.x, `opencode v2.0.20` on 2.x).
# A stub, never a symlink to a real opencode: 1.x and 2.x cannot share a data
# directory, and the machine running this suite may hold a real 1.x with real
# data.
#
# `sleep` is added because roost_opencode_version's watchdog runs
# `sleep 5; kill "$probe"`. With no sleep on PATH that line fails at once and
# the kill fires straight away, so whether the stub got to answer first would be
# a race, and a "2.x" case could read as "no version" for a reason that has
# nothing to do with the code under test.
make_versioned_shim() { # make_versioned_shim VERSIONLINE NAME... -> prints a PATH dir
  local line="$1"; shift
  local dir h real
  dir="$(make_harness_shim "$@")"
  real="$(command -v sleep 2>/dev/null)" && ln -s "$real" "$dir/sleep" 2>/dev/null
  for h in "$@"; do
    [ "$h" = opencode ] || continue
    printf "#!/bin/sh\necho '%s'\n" "$line" > "$dir/opencode"
    chmod +x "$dir/opencode"
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
  CLAUDE_CONFIG_DIR="$box/home/.claude" CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
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
  CLAUDE_CONFIG_DIR="$box/home/.claude" CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
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
  CLAUDE_CONFIG_DIR="$box/home/.claude" CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
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
# Every count of symlinks in this file leaves out the roost skill links
# (`<harness home>/skills/roost`, #208): they are one more link per detected
# harness, and tests/test-skill-links.sh counts them, planted state by state.
# Excluded by that exact tail, so any OTHER stray link is still counted here.
n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
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
# A regular file: the note never hands over an `rm` for it, which would
# delete the user's plugin itself. It says to move it aside instead.
case "$out" in *"rm \"$fpath\""*) s=printed ;; *) s=absent ;; esac
assert_eq "$s" "absent" "foreign path: no rm is printed for a regular file"
assert_contains "$out" "it is not a symlink — look at it first, move it aside yourself, then:" \
  "foreign path: the note says to move the file aside"
assert_contains "$out" "ln -s \"$(adapter_target opencode)\"" \
  "foreign path: the manual command names the right target"
# The other two are unaffected by one harness being refused.
[ -L "$(adapter_path_in "$box" pi)" ]; assert_true $? "foreign path: pi is still linked"

# ===========================================================================
# 3b. A link to ANOTHER copy of roost -> relinked from a plain checkout,
#     refused from a git worktree
# ===========================================================================
# Whether the installer may take the link over depends on whether the
# checkout RUNNING it is a linked git worktree, so every case here runs an
# installer from a checkout this test builds, never "$INSTALL": the checkout
# running this suite is often a worktree itself and on CI is a plain clone,
# so its own answer would differ by machine. git is on the shim PATH because
# with no git the question cannot be asked and every checkout reads as plain;
# a "plain checkout relinks" case that passed for that reason proves nothing.
#
# The throwaway repository is built with the runner's global git config and
# hooks shut out, so a commit-msg or identity hook there cannot change it.
export GIT_CONFIG_GLOBAL=/dev/null
tgit() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }

OC2_GIT_SHIM="$(make_versioned_shim 'opencode v2.0.20' opencode pi)"
real_git="$(command -v git 2>/dev/null)" && ln -s "$real_git" "$OC2_GIT_SHIM/git"

# A second copy of roost. Only its adapters matter: the link's own text and
# an existing target are what make it another copy's link.
co2="$TMP/second-checkout"
mkdir -p "$co2"
cp -R "$HERE/adapters" "$co2/"
printf 'export const mine = true; // not roost\n' > "$TMP/stranger.js"

# copy_checkout DIR -- the parts of this checkout an install run reads.
copy_checkout() {
  mkdir -p "$1"
  cp -R "$HERE/scripts" "$HERE/bin" "$HERE/adapters" "$HERE/tmux" "$HERE/VERSION" "$1/"
}
# Plain: not a git repository at all.
plain="$TMP/plain-checkout"
copy_checkout "$plain"
# A repository with a primary checkout and a linked worktree carrying the SAME
# installer, so the worktree case and its control differ in nothing else.
repo="$TMP/wt-repo"; wt="$TMP/wt-repo-wt"
mkdir -p "$repo"
( cd "$repo" && tgit init -q && tgit commit -q --allow-empty -m one ) >/dev/null 2>&1
copy_checkout "$repo"
( cd "$repo" && tgit add -A && tgit commit -q -m two && tgit worktree add -q "$wt" -b wt ) >/dev/null 2>&1

# The harness checks itself before any case leans on it: a worktree that was
# never made would leave every "refused" assertion below passing vacuously.
[ -x "$wt/scripts/roost-install" ]; assert_true $? "other-checkout setup: the worktree carries the installer"
bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_checkout_is_worktree "$1"' _ "$wt"
assert_eq "$?" "0" "other-checkout setup: the worktree reads as a worktree"
bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_checkout_is_worktree "$1"' _ "$repo"
assert_eq "$?" "1" "other-checkout setup: its primary checkout does not"

# run_install_from CHECKOUT BOX SHIMDIR [args...] -- run_install, but the
# installer of CHECKOUT, and with ZDOTDIR redirected as well.
run_install_from() {
  local co="$1" box="$2" shim="$3"; shift 3
  mkdir -p "$box"
  HOME="$box/home" \
  ZDOTDIR="$box/home" \
  XDG_CONFIG_HOME="$box/home/.config" \
  XDG_DATA_HOME="$box/home/.local/share" \
  COPILOT_HOME="$box/home/.copilot" \
  PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
  CODEX_HOME="$box/home/.codex" \
  CLAUDE_CONFIG_DIR="$box/home/.claude" CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
  PATH="$shim" \
    bash "$co/scripts/roost-install" "$@" </dev/null 2>&1
}
adapter_tail() { bash -c '. "'"$HERE"'/scripts/lib/roost-adapters.sh"; roost_adapter_tail "$1"' _ "$1"; }
plant_link() { # plant_link BOX KEY TARGET
  local p; p="$(adapter_path_in "$1" "$2")"
  mkdir -p "$(dirname "$p")"; ln -s "$3" "$p"
}

for pair in "opencode2 opencode" "pi pi"; do
  key="${pair% *}"; h="${pair#* }"
  tl="$(adapter_tail "$key")"
  old="$co2$tl"

  # --- plain checkout, other-checkout link -> relinked, and said so
  box="$TMP/oc-plain-$key"
  plant_link "$box" "$key" "$old"
  P="$(adapter_path_in "$box" "$key")"
  out="$(run_install_from "$plain" "$box" "$OC2_GIT_SHIM" --yes --records "$box/records")"; rc=$?
  assert_eq "$rc" "0" "$key, plain checkout, other copy's link: exits 0"
  [ "$P" -ef "$plain$tl" ]; assert_true $? "$key, plain checkout, other copy's link: now points at this checkout"
  [ -L "$P" ]; assert_true $? "$key, plain checkout, other copy's link: still a symlink"
  [ -e "$old" ]; assert_true $? "$key, plain checkout, other copy's link: the other copy's adapter is untouched"
  assert_contains "$out" "relinked" "$key, plain checkout, other copy's link: the output says relinked"
  assert_contains "$out" "was $old" "$key, plain checkout, other copy's link: the output names the old target"
  assert_contains "$out" "a second copy of roost" "$key, plain checkout, other copy's link: the output says it is a second copy"
  assert_contains "$out" "rm \"$P\" && ln -s \"$old\" \"$P\"" \
    "$key, plain checkout, other copy's link: the printed undo puts the old link back"
  assert_contains "$(cat "$box/records" 2>/dev/null)" \
    "$(printf 'wrote\t%s\t%s\trm "%s" && ln -s "%s" "%s"' "$h" "$P" "$P" "$old" "$P")" \
    "$key, plain checkout, other copy's link: --records holds wrote with the undo"

  # --- plain checkout, a stranger's link (the control) -> still refused
  box="$TMP/oc-plain-stranger-$key"
  plant_link "$box" "$key" "$TMP/stranger.js"
  P="$(adapter_path_in "$box" "$key")"
  sbefore="$(cksum < "$TMP/stranger.js")"
  out="$(run_install_from "$plain" "$box" "$OC2_GIT_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "$key, plain checkout, stranger's link: exits 0"
  assert_eq "$(readlink "$P")" "$TMP/stranger.js" "$key, plain checkout, stranger's link: the link is unchanged"
  assert_eq "$(cksum < "$TMP/stranger.js")" "$sbefore" "$key, plain checkout, stranger's link: the file is byte-identical"
  assert_contains "$out" "$P" "$key, plain checkout, stranger's link: the path is named"
  case "$out" in *relinked*) s=relinked ;; *) s=refused ;; esac
  assert_eq "$s" "refused" "$key, plain checkout, stranger's link: nothing says relinked"

  # --- worktree, other-checkout link -> left alone, and the reason named
  box="$TMP/oc-wt-$key"
  plant_link "$box" "$key" "$old"
  P="$(adapter_path_in "$box" "$key")"
  out="$(run_install_from "$wt" "$box" "$OC2_GIT_SHIM" --yes --records "$box/records")"; rc=$?
  assert_eq "$rc" "0" "$key, worktree, other copy's link: exits 0"
  assert_eq "$(readlink "$P")" "$old" "$key, worktree, other copy's link: the link is unchanged"
  assert_contains "$out" "this is a git worktree" "$key, worktree, other copy's link: the output says why"
  assert_contains "$out" "points at another copy of roost, $old." \
    "$key, worktree, other copy's link: the manual note names the other copy"
  assert_contains "$out" "run roost install from that copy, or from this repository's primary" \
    "$key, worktree, other copy's link: the manual note says where to run it"
  case "$out" in *relinked*) s=relinked ;; *) s=refused ;; esac
  assert_eq "$s" "refused" "$key, worktree, other copy's link: nothing says relinked"
  assert_contains "$(cat "$box/records" 2>/dev/null)" "$(printf 'refused\t%s\t%s' "$h" "$P")" \
    "$key, worktree, other copy's link: --records says refused"

  # --- worktree, a stranger's link (the control) -> unchanged too
  box="$TMP/oc-wt-stranger-$key"
  plant_link "$box" "$key" "$TMP/stranger.js"
  P="$(adapter_path_in "$box" "$key")"
  out="$(run_install_from "$wt" "$box" "$OC2_GIT_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "$key, worktree, stranger's link: exits 0"
  assert_eq "$(readlink "$P")" "$TMP/stranger.js" "$key, worktree, stranger's link: the link is unchanged"
  assert_eq "$(cksum < "$TMP/stranger.js")" "$sbefore" "$key, worktree, stranger's link: the file is byte-identical"

  # --- the SAME repository's primary checkout -> relinks. The control that
  # proves the rule: same planted link, same installer, only the checkout
  # kind differs.
  box="$TMP/oc-primary-$key"
  plant_link "$box" "$key" "$old"
  P="$(adapter_path_in "$box" "$key")"
  out="$(run_install_from "$repo" "$box" "$OC2_GIT_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "$key, primary checkout, other copy's link: exits 0"
  [ "$P" -ef "$repo$tl" ]; assert_true $? "$key, primary checkout, other copy's link: relinked to the primary"
  assert_contains "$out" "relinked" "$key, primary checkout, other copy's link: the output says relinked"

  # --- --dry-run from the plain checkout -> the plan says what it replaces
  box="$TMP/oc-dry-$key"
  plant_link "$box" "$key" "$old"
  before="$(tree_of "$box")"
  out="$(run_install_from "$plain" "$box" "$OC2_GIT_SHIM" --dry-run --yes)"; rc=$?
  assert_eq "$rc" "0" "$key, --dry-run, other copy's link: exits 0"
  assert_eq "$(tree_of "$box")" "$before" "$key, --dry-run, other copy's link: nothing changed"
  assert_contains "$out" "(was $old)" "$key, --dry-run, other copy's link: the plan says what the relink replaces"
  case "$out" in *"relink "*"(was $old)"*) s=listed ;; *) s=missing ;; esac
  assert_eq "$s" "listed" "$key, --dry-run, other copy's link: listed as a relink"
done

# --- the 1.x plugin path on opencode 2, linking ANOTHER copy's 1.x adapter.
# opencode 2 cannot load it whichever copy it names, so from a plain checkout
# it is removed like this checkout's own; from a worktree it is left alone.
old1="$co2$(adapter_tail opencode)"
box="$TMP/oc1x-plain"
plant_link "$box" opencode "$old1"
P1="$(adapter_path_in "$box" opencode)"
out="$(run_install_from "$plain" "$box" "$OC2_GIT_SHIM" --yes --records "$box/records")"; rc=$?
assert_eq "$rc" "0" "opencode 2, other copy's 1.x link, plain checkout: exits 0"
[ ! -e "$P1" ] && [ ! -L "$P1" ]; assert_true $? "opencode 2, other copy's 1.x link, plain checkout: removed"
[ -e "$old1" ]; assert_true $? "opencode 2, other copy's 1.x link, plain checkout: the other copy's adapter is untouched"
assert_contains "$out" "removed  $P1" "opencode 2, other copy's 1.x link, plain checkout: the output names it"
assert_contains "$(cat "$box/records" 2>/dev/null)" \
  "$(printf 'removed\topencode\t%s\tln -s "%s" "%s"' "$P1" "$old1" "$P1")" \
  "opencode 2, other copy's 1.x link, plain checkout: --records holds removed with the ln -s undo"

box="$TMP/oc1x-wt"
plant_link "$box" opencode "$old1"
P1="$(adapter_path_in "$box" opencode)"
out="$(run_install_from "$wt" "$box" "$OC2_GIT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "opencode 2, other copy's 1.x link, worktree: exits 0"
assert_eq "$(readlink "$P1")" "$old1" "opencode 2, other copy's 1.x link, worktree: the link is unchanged"
assert_contains "$out" "this is a git worktree" "opencode 2, other copy's 1.x link, worktree: the heading says why"
assert_contains "$out" "points at another copy of roost's 1.x adapter, $old1, which opencode 2 cannot load" \
  "opencode 2, other copy's 1.x link, worktree: the manual note names the 1.x adapter"
assert_contains "$out" "run roost install from that copy, or from this repository's primary" \
  "opencode 2, other copy's 1.x link, worktree: the manual note says where to run it"

box="$TMP/oc1x-stranger"
plant_link "$box" opencode "$TMP/stranger.js"
P1="$(adapter_path_in "$box" opencode)"
out="$(run_install_from "$plain" "$box" "$OC2_GIT_SHIM" --yes)"; rc=$?
assert_eq "$(readlink "$P1")" "$TMP/stranger.js" "opencode 2, stranger's link at the 1.x path, plain checkout: unchanged"
assert_eq "$(cksum < "$TMP/stranger.js")" "$sbefore" "opencode 2, stranger's link at the 1.x path: the file is byte-identical"

# --- the manual note for a stranger at the pi path: `rm` only for a symlink.
box="$TMP/pi-regular"
Ppi="$(adapter_path_in "$box" pi)"
mkdir -p "$(dirname "$Ppi")"; printf 'mine\n' > "$Ppi"
out="$(run_install_from "$plain" "$box" "$OC2_GIT_SHIM" --yes)"
assert_contains "$out" "/adapters/pi/roost.ts\" \"$Ppi\"" "pi, regular file: the note gives the ln -s"
assert_contains "$out" "it is not a symlink — look at it first, move it aside yourself, then:" \
  "pi, regular file: the note says to move it aside"
case "$out" in *"rm \"$Ppi\""*) s=printed ;; *) s=absent ;; esac
assert_eq "$s" "absent" "pi, regular file: the note never prints rm for it"
assert_eq "$(cat "$Ppi")" "mine" "pi, regular file: the file is untouched"
box="$TMP/pi-stranger-link"
plant_link "$box" pi "$TMP/stranger.js"
Ppi="$(adapter_path_in "$box" pi)"
out="$(run_install_from "$plain" "$box" "$OC2_GIT_SHIM" --yes)"
assert_contains "$out" "rm \"$Ppi\" && ln -s" "pi, stranger's symlink: the note prints rm && ln -s"

# --- a relink whose old link cannot be removed FAILS. The parent is made
# read-only, so `rm` of the old link fails; an unchecked `ln -s` would then
# follow the still-live directory link and create a link inside the other
# copy's adapter directory while reporting success.
box="$TMP/oc-relink-blocked"
plant_link "$box" opencode2 "$co2$(adapter_tail opencode2)"
P="$(adapter_path_in "$box" opencode2)"
inside_before="$(ls -a "$co2$(adapter_tail opencode2)")"
chmod 555 "$(dirname "$P")"
if [ -w "$(dirname "$P")" ]; then
  # root ignores the mode, so there is no way to make the rm fail here.
  printf '  SKIP: relink with an unremovable old link (running as root)\n'
else
  out="$(run_install_from "$plain" "$box" "$OC2_GIT_SHIM" --yes --records "$box/records")"; rc=$?
  [ "$rc" -ne 0 ]; assert_true $? "relink, old link cannot be removed: exits non-zero"
  assert_contains "$out" "could NOT relink $P" "relink, old link cannot be removed: says so"
  case "$out" in *relinked*) s=relinked ;; *) s=no ;; esac
  assert_eq "$s" "no" "relink, old link cannot be removed: nothing says relinked"
  assert_eq "$(readlink "$P")" "$co2$(adapter_tail opencode2)" "relink, old link cannot be removed: the link is unchanged"
  assert_eq "$(ls -a "$co2$(adapter_tail opencode2)")" "$inside_before" \
    "relink, old link cannot be removed: nothing new inside the other copy's adapter"
  assert_contains "$(cat "$box/records" 2>/dev/null)" "$(printf 'failed\topencode\t%s' "$P")" \
    "relink, old link cannot be removed: --records says failed"
fi
chmod 755 "$(dirname "$P")"
rm -rf "$OC2_GIT_SHIM"
# The throwaway git config is for the repository above only.
unset GIT_CONFIG_GLOBAL

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
n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "1" "--only pi: exactly one symlink exists"
# Same stripping as case 9, same two reasons.
body="$(printf '%s' "$out" | sed "s|$HERE||g")"
printf '%s' "$body" | grep -Eqw opencode && s=mentioned || s=absent
assert_eq "$s" "absent" "--only pi: opencode is not even mentioned"

# The half of --only that is a SAFETY invariant rather than a convenience, and
# the reason scripts/roost-install spells it out at length above in_scope: the
# blast radius of getting --only wrong is not just three symlinks: it is
# claude's settings.json, codex's hooks.json and copilot's settings.json
# edited on a machine whose caller explicitly scoped them out.
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
# --yes` in a wrapper where $HARNESS is unset is the realistic way in, and the
# same hole writes claude's settings.json, codex's hooks.json and copilot's
# settings.json on a machine that scoped them out.
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
  n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$n" "0" "--only naming nothing ($empty_only): links nothing"
done

# The complement, so the guard cannot be "reject everything": a real name
# still restricts rather than erroring.
box="$TMP/onlyok"
run_install "$box" "$ALL_SHIM" --only=copilot --yes >/dev/null; rc=$?
assert_eq "$rc" "0" "--only=copilot (the = spelling with a real name): exits 0"
n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
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
n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
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
# This is the mode `roost validate` calls, and the reason the mode exists:
# validate writes its result into a report that promises "nothing else was
# written -- no hooks file, no trust granted, no settings edited", so this
# output has to be about symlinks and nothing else. What validate does with
# the mode -- the flags it passes, and the policy those flags express -- is
# tests/test-validate-install.sh; this section is about the mode itself.
box="$TMP/symonly"
out="$(run_install "$box" "$ALL_SHIM" --symlinks-only --yes)"; rc=$?
assert_eq "$rc" "0" "--symlinks-only: exits 0"
n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
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
n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "3" "--print-only: the symlinks are still made (it only governs JSON)"

# The other direction, which nothing covered: a NORMAL run must print no JSON
# block at all. Without this, wiring PRINT_ONLY permanently on is a mutation
# the suite survives -- case 10 skips the branch via --symlinks-only, and
# cases 7 and 9 have no claude or codex detected, so none of them can see it.
#
# The shim here carries a JSON tool, and that is the whole point. A run
# WITHOUT one prints the block on purpose -- that is the degraded path, pinned
# in section 13 -- so building this case on ALL_SHIM would assert the opposite
# of what it claims and go green either way.
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
# 13. claude: roost's hooks are merged into settings.json
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

# --- an existing settings.json: roost's hooks go in, everything else stays --
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
  for ev in UserPromptSubmit Notification PostToolUse Stop StopFailure; do
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
# The names line, with ", " closed on the end so "claude" can only match
# as a whole name: the line also carries "claude skill" (#208), which
# names the skill link and not the hooks this case is about.
assert_contains "$(printf '%s\n' "$out" | grep '^Already correct:'), " ", claude, " \
  "claude re-run: claude is named as already correct"
case "$out" in *"merge  $cset"*) s=planned ;; *) s=absent ;; esac
assert_eq "$s" "absent" "claude re-run: no write is even PLANNED for it"

# --- wired before StopFailure existed -> the one new hook is added (#55) ----
# Every machine wired before #55 has roost's other hooks exactly right and no
# StopFailure entry, so a failed Claude turn stays ⏳ working there. Re-running
# the installer is the documented fix, so it must see the missing event as a
# write, add it, and leave the rest as they were.
if command -v python3 >/dev/null 2>&1; then
  box="$TMP/claudepre55"
  cset="$box/home/.claude/settings.json"
  mkdir -p "$box/home/.claude"
  ( . "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_claude "$HERE/scripts/roost-agent-state" ) \
    | python3 -c 'import json,sys
d=json.load(sys.stdin); del d["hooks"]["StopFailure"]; print(json.dumps(d, indent=2))' > "$cset"
  out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "claude wired before StopFailure: exits 0"
  case "$out" in *"Already correct: opencode, claude"*) s=skipped ;; *) s=planned ;; esac
  assert_eq "$s" "planned" "claude wired before StopFailure: is not reported as already correct"
  assert_eq "$(claude_event "$cset" StopFailure)" "$(claude_want StopFailure)" \
    "claude wired before StopFailure: the StopFailure entry is added"
  for ev in SessionStart UserPromptSubmit Notification PostToolUse Stop; do
    assert_eq "$(claude_event "$cset" "$ev")" "$(claude_want "$ev")" \
      "claude wired before StopFailure: the $ev entry is still roost's own"
  done
  case "$out" in *"kept the"*|*"replaced 1"*) s=claimed ;; *) s=quiet ;; esac
  assert_eq "$s" "quiet" "claude wired before StopFailure: claims to have kept or replaced nothing"
fi

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

# --- wired to ANOTHER LIVE copy of roost -> replaced from a plain checkout,
#     refused from a worktree ------------------------------------------------
# Generated from roost-hooks.sh with another checkout's path, not typed out
# here: a second copy of those bytes is exactly the drift the one-definition
# rule exists to prevent, and a hand-typed near-miss would make this case pass
# for the wrong reason.
#
# The other checkout's script really EXISTS: this is a second copy somebody
# keeps, not a dead one (the sibling case below deletes it). Whether it is
# taken over depends on whether the checkout RUNNING the installer is a git
# worktree, so these cases run the installers case 3b built ($plain, $wt)
# rather than "$INSTALL": the checkout running this suite is a worktree on the
# machine it is developed on and a plain clone on CI, and its own answer would
# differ between the two. git is on the shim so the question is really asked.
CLAUDE_GIT_SHIM="$(make_json_shim claude opencode)"
[ -n "${real_git:-}" ] && ln -s "$real_git" "$CLAUDE_GIT_SHIM/git"
mkdir -p "$TMP/some-other-checkout/scripts"
: > "$TMP/some-other-checkout/scripts/roost-agent-state"

# plain checkout -> rewritten to this checkout, and said so
box="$TMP/claudeforeign"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
( . "$HERE/scripts/lib/roost-hooks.sh"
  roost_hooks_claude "$TMP/some-other-checkout/scripts/roost-agent-state" ) > "$cset"
out="$(run_install_from "$plain" "$box" "$CLAUDE_GIT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude wired to another live copy, plain checkout: exits 0"
grep -qF "$plain/scripts/roost-agent-state" "$cset" 2>/dev/null; assert_true $? \
  "claude wired to another live copy, plain checkout: settings.json now names THIS checkout"
grep -qF "$TMP/some-other-checkout/scripts/" "$cset" 2>/dev/null && s=left || s=gone
assert_eq "$s" "gone" \
  "claude wired to another live copy, plain checkout: the other copy's entries are replaced, not appended beside"
assert_eq "$(grep -c roost-session-context "$cset" 2>/dev/null)" "1" \
  "claude wired to another live copy, plain checkout: exactly one SessionStart hook survives"
assert_eq "$(bak_count "$cset")" "1" \
  "claude wired to another live copy, plain checkout: a backup was taken before rewriting it"
[ -e "$TMP/some-other-checkout/scripts/roost-agent-state" ]; assert_true $? \
  "claude wired to another live copy, plain checkout: the other copy itself is untouched"
assert_contains "$out" "  replaced a hook from another copy of roost, $TMP/some-other-checkout — if you did not mean to keep two, remove that copy and its PATH line." \
  "claude wired to another live copy, plain checkout: the output names the other copy"
case "$out" in *"different checkout"*|*"this checkout is a git worktree"*) s=refused ;; *) s=replaced ;; esac
assert_eq "$s" "replaced" \
  "claude wired to another live copy, plain checkout: nothing says it was refused"

# worktree -> left alone, byte for byte, and the reason named
box="$TMP/claudeforeign-wt"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
( . "$HERE/scripts/lib/roost-hooks.sh"
  roost_hooks_claude "$TMP/some-other-checkout/scripts/roost-agent-state" ) > "$cset"
fbefore="$(cksum < "$cset")"
out="$(run_install_from "$wt" "$box" "$CLAUDE_GIT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude wired elsewhere, worktree: still exits 0 (a refusal is not a failure)"
assert_eq "$(cksum < "$cset")" "$fbefore" \
  "claude wired elsewhere, worktree: settings.json is byte-identical after"
assert_eq "$(bak_count "$cset")" "0" "claude wired elsewhere, worktree: no backup was taken"
assert_contains "$out" "$cset" "claude wired elsewhere, worktree: the exact file is named"
assert_contains "$out" "a roost hook there points at another copy of roost, $TMP/some-other-checkout/scripts/roost-agent-state" \
  "claude wired elsewhere, worktree: the output names the other copy"
assert_contains "$out" "and this checkout is a git worktree — run roost install from that copy, or from the primary checkout" \
  "claude wired elsewhere, worktree: the output says why it will not touch it"
case "$out" in *"replaced a hook from another copy"*) s=replaced ;; *) s=refused ;; esac
assert_eq "$s" "refused" "claude wired elsewhere, worktree: nothing says replaced"
[ -L "$(adapter_path_in "$box" opencode)" ]; assert_true $? \
  "claude wired elsewhere: refusing one step does not abandon the others"

# --- a live copy is matched by roost's two scripts EXACTLY, never by prefix --
# Taking over a gone copy may drop everything under its directory: nothing
# there can run. A LIVE copy's directory can hold the user's own hooks, so
# only commands that run roost-agent-state or roost-session-context there
# count as roost's. These were found by review: a prefix match deleted both
# of the hooks pinned below.
#
# claude_live_extra FILE OTHER EXTRA -- roost's hooks for OTHER, plus the
# user's own Stop hook EXTRA.
claude_live_extra() {
  ( . "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_claude "$2/scripts/roost-agent-state" ) \
    | sed 's|"Stop": \[|"Stop": [ { "hooks": [ { "type": "command", "command": "'"$3"'" } ] },|' > "$1"
}
# A Stop hook of the user's own that runs ANOTHER script from the live copy.
box="$TMP/claudelive-extra"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
claude_live_extra "$cset" "$TMP/some-other-checkout" "$TMP/some-other-checkout/scripts/roost-notify done finished"
assert_eq "$(grep -c roost-notify "$cset")" "1" "claude live copy, user's roost-notify hook: setup plants it"
out="$(run_install_from "$plain" "$box" "$CLAUDE_GIT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude live copy, user's roost-notify hook: exits 0"
assert_eq "$(grep -c "$TMP/some-other-checkout/scripts/roost-notify done finished" "$cset" 2>/dev/null)" "1" \
  "claude live copy, user's roost-notify hook: the user's hook is KEPT"
grep -qF "$TMP/some-other-checkout/scripts/roost-agent-state" "$cset" 2>/dev/null && s=left || s=gone
assert_eq "$s" "gone" "claude live copy, user's roost-notify hook: the other copy's roost-agent-state hooks are replaced"
grep -qF "$TMP/some-other-checkout/scripts/roost-session-context" "$cset" 2>/dev/null && s=left || s=gone
assert_eq "$s" "gone" "claude live copy, user's roost-notify hook: the other copy's roost-session-context hook is replaced"
grep -qF "$plain/scripts/roost-agent-state" "$cset" 2>/dev/null; assert_true $? \
  "claude live copy, user's roost-notify hook: settings.json now names THIS checkout"
assert_contains "$out" "kept the 1 entry already in those events" \
  "claude live copy, user's roost-notify hook: the write says it kept the user's entry"
assert_contains "$out" "replaced a hook from another copy of roost, $TMP/some-other-checkout —" \
  "claude live copy, user's roost-notify hook: the output names the other copy"

# A roost-agent-state copied into a bin directory, beside the user's own
# formatter. That directory is not a copy of roost, so this is not a takeover
# at all: refused, and the file left byte for byte.
box="$TMP/claudelive-bin"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude" "$box/home/bin"
: > "$box/home/bin/roost-agent-state"; : > "$box/home/bin/my-format"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s/roost-agent-state idle"}]}],"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"%s/my-format"}]}]}}\n' \
  "$box/home/bin" "$box/home/bin" > "$cset"
fbefore="$(cksum < "$cset")"
out="$(run_install_from "$plain" "$box" "$CLAUDE_GIT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude, roost-agent-state copied into ~/bin: exits 0"
assert_eq "$(cksum < "$cset")" "$fbefore" "claude, roost-agent-state copied into ~/bin: settings.json is byte-identical"
assert_eq "$(bak_count "$cset")" "0" "claude, roost-agent-state copied into ~/bin: no backup was taken"
assert_contains "$out" "a roost hook there points at a different checkout: $box/home/bin/roost-agent-state" \
  "claude, roost-agent-state copied into ~/bin: refused as a different checkout"
case "$out" in *"another copy of roost"*) s=named ;; *) s=quiet ;; esac
assert_eq "$s" "quiet" "claude, roost-agent-state copied into ~/bin: ~/bin is never called a copy of roost"

# The plan says it BEFORE the prompt: answering y is consenting to it.
box="$TMP/claudelive-dry"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
( . "$HERE/scripts/lib/roost-hooks.sh"
  roost_hooks_claude "$TMP/some-other-checkout/scripts/roost-agent-state" ) > "$cset"
fbefore="$(cksum < "$cset")"
out="$(run_install_from "$plain" "$box" "$CLAUDE_GIT_SHIM" --dry-run)"; rc=$?
assert_eq "$rc" "0" "claude live copy, --dry-run: exits 0"
assert_eq "$(cksum < "$cset")" "$fbefore" "claude live copy, --dry-run: nothing written"
assert_contains "$out" "         (one of those is a hook from another copy of roost, $TMP/some-other-checkout; it is replaced)" \
  "claude live copy, --dry-run: the plan names the other copy before consent"
assert_contains "$out" "         roost's Claude hooks" \
  "claude live copy, --dry-run: the plan row's label is the label alone"
tab="$(printf '\t')"
case "$out" in *"scripts${tab}roost's"*) s=garbled ;; *) s=clean ;; esac
assert_eq "$s" "clean" "claude live copy, --dry-run: no directory leaks into the label"

# An ordinary write with no other copy anywhere says nothing about one.
box="$TMP/claude-nocopy"
mkdir -p "$box/home/.claude"
out="$(run_install_from "$plain" "$box" "$CLAUDE_GIT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude, no other copy: exits 0"
case "$out" in *"another copy"*) s=named ;; *) s=quiet ;; esac
assert_eq "$s" "quiet" "claude, no other copy: nothing mentions another copy"

# --- wired to a checkout that is GONE -> repair it, do not refuse forever ---
# Found by the multi-model review of #27. A moved, renamed or re-cloned
# checkout leaves a settings.json whose hook command is a path that no longer
# exists. The symlink adapters heal that case already (a broken link is
# `dangling`, and the installer relinks it); claude did not, because the
# refusal compared the path STRING and never asked whether that checkout was
# still there. So the hook could not run, the pane never badged, and every
# re-run of `roost install` refused again -- while README.md and the `roost
# update` help line both promise it handles "a moved or re-cloned checkout".
#
# The codex adapter deliberately does NOT get this treatment: rewriting a
# codex handler re-hashes it and silently un-badges a machine that had already
# granted trust, so there a refusal really is the lesser harm. See the codex
# case further down, which pins that it still refuses AND that it now says the
# true reason.
box="$TMP/claudegone"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
# Generated the same way as the case above, from roost-hooks.sh, so the two
# differ in exactly one thing: whether that path exists. It is never created.
( . "$HERE/scripts/lib/roost-hooks.sh"
  roost_hooks_claude "$TMP/deleted-checkout/scripts/roost-agent-state" ) > "$cset"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude wired to a deleted checkout: exits 0"
case "$out" in
  *"different checkout"*) s=refused ;;
  *) s=repaired ;;
esac
assert_eq "$s" "repaired" \
  "claude wired to a deleted checkout: it is NOT refused as another checkout's"
# The assertion that matters is the CONTENT, not the message: the file must
# now name this checkout and must no longer name the dead one. A repair that
# appended beside the dead entry would leave both, and the pane would still
# carry a hook that cannot run.
grep -qF "$HERE/scripts/roost-agent-state" "$cset" 2>/dev/null; assert_true $? \
  "claude wired to a deleted checkout: settings.json now names THIS checkout"
grep -qF "$TMP/deleted-checkout/scripts/roost-agent-state" "$cset" 2>/dev/null && s=left || s=gone
assert_eq "$s" "gone" \
  "claude wired to a deleted checkout: the dead entry is replaced, not appended beside"
assert_eq "$(bak_count "$cset")" "1" \
  "claude wired to a deleted checkout: a backup was taken before rewriting it"
# The SessionStart entry specifically, and this one only an end-to-end run
# found. SessionStart's command is roost-session-context -- the ONE claude
# command that does not contain the marker (roost-agent-state) the dead-
# checkout detection keys on. Matching the dead script path alone left it
# classified as a stranger's hook: kept, with roost's own appended beside it.
# The file came back with TWO SessionStart hooks, one of them a path that does
# not exist, and every assertion above still passed. Matching the dead
# DIRECTORY is what closes it.
assert_eq "$(grep -c roost-session-context "$cset" 2>/dev/null)" "1" \
  "claude wired to a deleted checkout: exactly one SessionStart hook survives"
grep -qF "$TMP/deleted-checkout/scripts/roost-session-context" "$cset" 2>/dev/null && s=left || s=gone
assert_eq "$s" "gone" \
  "claude wired to a deleted checkout: the dead SessionStart hook is gone too"

# --- someone ELSE's hook in one of roost's events -> kept, roost added -----
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
    "$HERE/scripts/roost-agent-state working --tool-hook" \
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
# The names line, with ", " closed on the end so "claude" can only match
# as a whole name: the line also carries "claude skill" (#208), which
# names the skill link and not the hooks this case is about.
assert_contains "$(printf '%s\n' "$out" | grep '^Already correct:'), " ", claude, " \
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
n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
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
n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
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

# --- a DIRECTORY where the config file goes -> refused, and said so --------
# `[ -f ]` reads a directory as absent, so this used to take the create
# branch: the temp file was moved INSIDE the directory and the run reported
# "needed no change" and exited 0. A directory there is pathological, but
# "needed no change" is the one message a user reads to conclude they are
# already wired up, and a wrong one sends them away satisfied.
box="$TMP/claudedir"
cset="$box/home/.claude/settings.json"
mkdir -p "$cset"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "1" "claude with a directory at the config path: exits 1"
[ -d "$cset" ]; assert_true $? "claude with a directory at the config path: it is still a directory"
assert_eq "$(find "$cset" -mindepth 1 | wc -l | tr -d ' ')" "0" \
  "claude with a directory at the config path: nothing was left inside it"
case "$out" in *"needed no change"*) s=claimed ;; *) s=honest ;; esac
assert_eq "$s" "honest" \
  "claude with a directory at the config path: it does NOT report itself as already correct"

# --- a command string with a newline in it is not rendered as a note -------
# $json_detail is text out of the user's own JSON, and the refusal records are
# newline-separated. An embedded newline used to split one record into two, so
# the second half arrived with no harness and no path and was printed as its
# own "Still manual" note -- telling the user to run `roost hooks <their
# text>`. Nothing executes, and the file is still correctly left alone; the
# point is that text from a file roost is READING must never come back out as
# an instruction roost is GIVING.
box="$TMP/claudeinject"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude" "$TMP/inject-checkout/scripts"
# The other checkout EXISTS and the installer is run from the worktree case
# 3b built, so this stays a refusal. Its subject is how the refusal MESSAGE is
# rendered, and a checkout that is gone -- or a live one seen from a plain
# checkout -- is now repaired instead of refused, which would leave this case
# with no refusal to render and both assertions below passing on nothing.
: > "$TMP/inject-checkout/scripts/roost-agent-state"
printf '%s\n' '{ "hooks": { "Notification": [ { "hooks": [ { "type": "command", "command": "'"$TMP"'/inject-checkout/scripts/roost-agent-state working\nrm -rf /tmp/whatever" } ] } ] } }' > "$cset"
fbefore="$(cksum < "$cset")"
out="$(run_install_from "$wt" "$box" "$CLAUDE_GIT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude with a newline in a command: exits 0"
assert_eq "$(cksum < "$cset")" "$fbefore" \
  "claude with a newline in a command: settings.json is byte-identical after"
assert_eq "$(bak_count "$cset")" "0" "claude with a newline in a command: no backup was taken"
assert_contains "$out" "this checkout is a git worktree" \
  "claude with a newline in a command: the real refusal is still reported"
case "$out" in *"whatever: left alone"*) s=leaked ;; *) s=contained ;; esac
assert_eq "$s" "contained" \
  "claude with a newline in a command: no second note is fabricated from the user's text"
# The positive half, and it is the one that matters. Absence alone passes when
# the detail comes out EMPTY -- which is exactly what happened first time
# round: the stripping was written with `tr`, the harness shim carries no
# `tr`, and the whole string vanished. This asserts the flattened text is
# still reported, on one line, so a sanitiser that silently deletes
# everything fails here.
assert_contains "$out" \
  "another copy of roost, $TMP/inject-checkout/scripts/roost-agent-state workingrm -rf /tmp/whatever, and this checkout" \
  "claude with a newline in a command: the command is still reported, flattened onto one line"
case "$out" in *"roost hooks rm"*) s=leaked ;; *) s=contained ;; esac
assert_eq "$s" "contained" \
  "claude with a newline in a command: no command is suggested that names the user's text"

# --- a hand-customised roost entry is replaced, and the run SAYS so --------
# An entry whose every command points at this checkout is roost's own, so the
# merge drops it and appends the canonical one -- that is the convergence
# mechanism, and it is how an older shape of roost's entry gets updated. But
# a user who changed the matcher deliberately gets it reverted, and from the
# accounting's point of view nothing of "theirs" was there, so no kept-line
# fires. They should be able to see it from the output, not from a diff.
box="$TMP/claudecustom"
cset="$box/home/.claude/settings.json"
mkdir -p "$box/home/.claude"
cat > "$cset" <<EOF
{
  "hooks": {
    "Notification": [
      { "matcher": "my_custom",
        "hooks": [ { "type": "command", "command": "$HERE/scripts/roost-agent-state blocked" } ] }
    ]
  }
}
EOF
cbefore="$(cat "$cset")"
out="$(run_install "$box" "$CLAUDE_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "claude with a customised roost entry: exits 0"
# Both halves, and the WRITE phrasing is spelled out rather than matched on
# the bare word: the plan line above also says "replaced", so a needle of
# "replaced" alone goes green with the line reporting what actually happened
# deleted. That exact survivor turned up twice in this batch.
assert_contains "$out" "a roost entry already there is replaced with the current one" \
  "claude with a customised roost entry: the plan warns before the prompt"
assert_contains "$out" "replaced 1 roost entry of its own with the current one" \
  "claude with a customised roost entry: the write reports it afterwards"
assert_contains "$out" "the backup above still has what it said" \
  "claude with a customised roost entry: it points at where their version went"
assert_eq "$(bak_count "$cset")" "1" "claude with a customised roost entry: a backup was taken"
assert_eq "$(cat "$(bak_of "$cset")" 2>/dev/null)" "$cbefore" \
  "claude with a customised roost entry: the backup still holds their version"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "$(claude_event "$cset" Notification)" "$(claude_want Notification)" \
    "claude with a customised roost entry: the canonical entry is what is there now"
fi
# And the point of saying it: a run that changed nothing of the user's must
# NOT claim it kept something, or the two messages stop meaning anything.
case "$out" in *"kept the"*) s=claimed ;; *) s=quiet ;; esac
assert_eq "$s" "quiet" \
  "claude with a customised roost entry: it does not also claim to have kept an entry"

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

  # Another LIVE copy, under jq: refused from a worktree, replaced from a
  # plain checkout -- run from case 3b's two checkouts for the reason the
  # python case above gives. git rides along so the worktree question is
  # really asked.
  [ -n "${real_git:-}" ] && ln -s "$real_git" "$JQ_SHIM/git"
  box="$TMP/claudejqforeign"
  cset="$box/home/.claude/settings.json"
  mkdir -p "$box/home/.claude"
  ( . "$HERE/scripts/lib/roost-hooks.sh"
    roost_hooks_claude "$TMP/some-other-checkout/scripts/roost-agent-state" ) > "$cset"
  fbefore="$(cksum < "$cset")"
  out="$(run_install_from "$wt" "$box" "$JQ_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "claude under jq, wired elsewhere, worktree: exits 0"
  assert_eq "$(cksum < "$cset")" "$fbefore" \
    "claude under jq, wired elsewhere, worktree: the file is byte-identical after"
  assert_eq "$(bak_count "$cset")" "0" \
    "claude under jq, wired elsewhere, worktree: no backup was taken"
  assert_contains "$out" "and this checkout is a git worktree" \
    "claude under jq, wired elsewhere, worktree: refused for the same stated reason"

  box="$TMP/claudejqforeign-plain"
  cset="$box/home/.claude/settings.json"
  mkdir -p "$box/home/.claude"
  ( . "$HERE/scripts/lib/roost-hooks.sh"
    roost_hooks_claude "$TMP/some-other-checkout/scripts/roost-agent-state" ) > "$cset"
  out="$(run_install_from "$plain" "$box" "$JQ_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "claude under jq, wired to another live copy, plain checkout: exits 0"
  grep -qF "$plain/scripts/roost-agent-state" "$cset" 2>/dev/null; assert_true $? \
    "claude under jq, wired to another live copy, plain checkout: settings.json now names THIS checkout"
  grep -qF "$TMP/some-other-checkout/scripts/" "$cset" 2>/dev/null && s=left || s=gone
  assert_eq "$s" "gone" \
    "claude under jq, wired to another live copy, plain checkout: the other copy's entries are replaced, not appended beside"
  assert_contains "$out" "replaced a hook from another copy of roost, $TMP/some-other-checkout —" \
    "claude under jq, wired to another live copy, plain checkout: the output names the other copy"

  # The exact-script rule under jq, probe and merge both.
  box="$TMP/claudejqlive-extra"
  cset="$box/home/.claude/settings.json"
  mkdir -p "$box/home/.claude"
  claude_live_extra "$cset" "$TMP/some-other-checkout" "$TMP/some-other-checkout/scripts/roost-notify done finished"
  out="$(run_install_from "$plain" "$box" "$JQ_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "claude under jq, live copy, user's roost-notify hook: exits 0"
  assert_eq "$(grep -c "$TMP/some-other-checkout/scripts/roost-notify done finished" "$cset" 2>/dev/null)" "1" \
    "claude under jq, live copy, user's roost-notify hook: the user's hook is KEPT"
  grep -qF "$TMP/some-other-checkout/scripts/roost-" "$cset" 2>/dev/null && \
    grep -vF roost-notify "$cset" | grep -qF "$TMP/some-other-checkout/scripts/" && s=left || s=gone
  assert_eq "$s" "gone" "claude under jq, live copy, user's roost-notify hook: the other copy's two scripts are replaced"
  assert_contains "$out" "kept the 1 entry already in those events" \
    "claude under jq, live copy, user's roost-notify hook: the write says it kept the user's entry"

  # ...and the repair, under jq. python3 is preferred, so every case above ran
  # the python engine; without this the jq spelling of the dead-checkout logic
  # would be shipped untested and could differ silently -- the whole reason
  # this file runs a jq-only shim at all.
  box="$TMP/claudejqgone"
  cset="$box/home/.claude/settings.json"
  mkdir -p "$box/home/.claude"
  ( . "$HERE/scripts/lib/roost-hooks.sh"
    roost_hooks_claude "$TMP/deleted-checkout-jq/scripts/roost-agent-state" ) > "$cset"
  out="$(run_install "$box" "$JQ_SHIM" --yes)"; rc=$?
  assert_eq "$rc" "0" "claude under jq, wired to a deleted checkout: exits 0"
  case "$out" in *"different checkout"*) s=refused ;; *) s=repaired ;; esac
  assert_eq "$s" "repaired" \
    "claude under jq, wired to a deleted checkout: it is repaired, not refused"
  grep -qF "$HERE/scripts/roost-agent-state" "$cset" 2>/dev/null; assert_true $? \
    "claude under jq, wired to a deleted checkout: settings.json now names THIS checkout"
  grep -qF "$TMP/deleted-checkout-jq/scripts/roost-agent-state" "$cset" 2>/dev/null && s=left || s=gone
  assert_eq "$s" "gone" \
    "claude under jq, wired to a deleted checkout: the dead entry is replaced, not appended beside"
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

# --- this checkout, but the Interrupt timeout roost used to write ----------
# The migration the timeout change depends on, and the only one roost has ever
# needed for a codex handler. A machine wired before the change has roost's own
# command string with "timeout": 10 on Interrupt; codex caps that event at 3s,
# clamps it, and warns with the hooks.json path on every start. The entry is
# roost's OWN -- same checkout, same command -- so the merge replaces it rather
# than refusing, which is what separates this case from the foreign-checkout
# one below. Without this, nothing in the suite proves an existing install ever
# picks the new number up, and every user would keep the warning for ever.
box="$TMP/codexoldtimeout"
chooks="$box/home/.codex/hooks.json"
run_install "$box" "$CODEX_SHIM" --yes >/dev/null
sed 's/"timeout": 3$/"timeout": 10/' "$chooks" > "$chooks.old" && mv "$chooks.old" "$chooks"
assert_contains "$(cat "$chooks")" '"timeout": 10' \
  "codex old timeout: setup planted the pre-change value"
out="$(run_install "$box" "$CODEX_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "codex old timeout: exits 0"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "$(codex_event_of "$chooks" Interrupt)" \
    "$(codex_hooks_want | python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)["Interrupt"]))')" \
    "codex old timeout: the Interrupt handler is rewritten to roost-hooks.sh's own"
  for ev in UserPromptSubmit PostToolUse PermissionRequest Stop; do
    assert_eq "$(codex_event_of "$chooks" "$ev")" \
      "$(codex_hooks_want | python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$ev")" \
      "codex old timeout: the $ev handler is untouched"
  done
fi
assert_eq "$(bak_count "$chooks")" "1" \
  "codex old timeout: the pre-change file is backed up before it is rewritten"
assert_contains "$out" "Trust all and continue" \
  "codex old timeout: the trust answer the rewrite makes necessary is printed"

# --- a roost entry pointing at a DIFFERENT checkout -> refuse --------------
# This is the one place in this command where helpfully fixing something is
# worse than doing nothing. Rewriting the command string re-hashes the
# handler, and codex then skips it in silence, so a machine that was badging
# correctly would simply stop.
box="$TMP/codexforeign"
chooks="$box/home/.codex/hooks.json"
mkdir -p "$box/home/.codex" "$TMP/some-other-checkout/adapters/codex"
# The other checkout EXISTS, which is what makes "a different checkout" the
# true reason here. The sibling case below deletes it: codex still refuses --
# rewriting a trusted handler re-hashes it and silently un-badges the machine
# -- but the REASON it prints changes, because "somebody else's checkout" is
# no longer what it found.
: > "$TMP/some-other-checkout/adapters/codex/roost-codex-hook"
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

# The control for claude's rule: from a PLAIN checkout -- the one place a
# Claude hook from another live copy is now replaced -- codex still refuses,
# with the same reason, and the file is left byte for byte. Run from case
# 3b's plain copy, with git on the shim, so the answer cannot depend on what
# kind of checkout runs this suite.
CODEX_GIT_SHIM="$(make_json_shim codex opencode)"
[ -n "${real_git:-}" ] && ln -s "$real_git" "$CODEX_GIT_SHIM/git"
box="$TMP/codexforeign-plain"
chooks="$box/home/.codex/hooks.json"
mkdir -p "$box/home/.codex"
( . "$HERE/scripts/lib/roost-hooks.sh"
  roost_hooks_codex "$TMP/some-other-checkout/adapters/codex/roost-codex-hook" ) > "$chooks"
fbefore="$(cksum < "$chooks")"
out="$(run_install_from "$plain" "$box" "$CODEX_GIT_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "codex wired to another live copy, plain checkout: exits 0"
assert_eq "$(cksum < "$chooks")" "$fbefore" \
  "codex wired to another live copy, plain checkout: hooks.json is byte-identical after"
assert_eq "$(bak_count "$chooks")" "0" \
  "codex wired to another live copy, plain checkout: no backup was taken"
assert_contains "$out" "a roost hook there points at a different checkout: $TMP/some-other-checkout/adapters/codex/roost-codex-hook" \
  "codex wired to another live copy, plain checkout: the existing reason, unchanged"
case "$out" in *"replaced a hook from another copy"*) s=replaced ;; *) s=refused ;; esac
assert_eq "$s" "refused" \
  "codex wired to another live copy, plain checkout: nothing says replaced"
rm -rf "$CODEX_GIT_SHIM"

# --- codex wired to a checkout that is GONE -> still refuse, but say so ----
# The deliberate asymmetry with claude, and the reason it is deliberate.
# claude repairs this case (a dead hook is roost's own and broken, so it is
# replaced). codex must NOT: its handler hashes live in config.toml, and
# rewriting one re-hashes it, which silently un-badges a machine that had
# already granted trust -- nothing printed on stdout, stderr or in the TUI.
# So the refusal stays and only the REASON improves. Telling somebody their
# config belongs to "a different checkout" when that checkout no longer exists
# sends them looking for a checkout that is not there.
box="$TMP/codexgone"
chooks="$box/home/.codex/hooks.json"
mkdir -p "$box/home/.codex"
( . "$HERE/scripts/lib/roost-hooks.sh"
  roost_hooks_codex "$TMP/deleted-checkout/adapters/codex/roost-codex-hook" ) > "$chooks"
fbefore="$(cksum < "$chooks")"
out="$(run_install "$box" "$CODEX_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "codex wired to a deleted checkout: exits 0"
assert_eq "$(cksum < "$chooks")" "$fbefore" \
  "codex wired to a deleted checkout: hooks.json is STILL byte-identical (the refusal stands)"
assert_eq "$(bak_count "$chooks")" "0" \
  "codex wired to a deleted checkout: no backup was taken"
assert_contains "$out" "no longer exists" \
  "codex wired to a deleted checkout: the reason names the real problem"
assert_contains "$out" "re-hash" \
  "codex wired to a deleted checkout: it still says why rewriting would be worse"
case "$out" in
  *"points at a different checkout"*) s=misleading ;;
  *) s=honest ;;
esac
assert_eq "$s" "honest" \
  "codex wired to a deleted checkout: it does NOT blame a different checkout"

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
case "$out" in *"enable $cps"*) s=planned ;; *) s=absent ;; esac
assert_eq "$s" "absent" "copilot flag already true: no write is even PLANNED for it"

# --- explicitly FALSE -> it must be turned on -----------------------------
# scripts/roost-doctor:233 greps for the flag's NAME and says so in its own
# comment: a file that sets it to false reads as set. The installer cannot
# afford that reading -- it would leave the extension off forever while
# reporting success.
# Setting a boolean flag is not a merge in the sense the two hook files are,
# and calling it one in the plan reads as "roost is about to rewrite my
# copilot settings". Its own verb -- and asserted, because the case above
# proves only that some string is ABSENT, which a renamed verb satisfies for
# the wrong reason.
box="$TMP/copilotverb"
cps="$box/home/.copilot/settings.json"
mkdir -p "$box/home/.copilot"
printf '{"theme":"dark"}\n' > "$cps"
out="$(run_install "$box" "$COPILOT_SHIM" --dry-run --yes)"; rc=$?
assert_eq "$rc" "0" "copilot plan verb: --dry-run exits 0"
assert_contains "$out" "enable $cps" \
  "copilot plan verb: the flag step is planned as its own action, not as a merge"

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
# People will reasonably expect `roost install` to update roost's own code. It
# does not, and must not: the checkout may be someone's dev tree with local
# work in it, and `roost upgrade` is the command with a gate for that. All
# install does is SAY so, from what git already knows locally -- never a fetch, which would
# be a surprise network call inside an installer, and never a pull.
#
# A scratch checkout carrying the files roost-install needs to run. Copies,
# not symlinks: the installer resolves its own location through a symlink
# chain (that is how it refuses to trust an inherited $ROOST_HOME), so a
# symlink here would resolve straight back to the real worktree and every
# case below would be measuring THIS repo's upstream instead of the
# fixture's. Defined outside the git guard below: it needs only `cp`, and
# section 21's symlinked-plugin/ case builds one whether or not git is here.
mkcheckout() { # mkcheckout DIR
  mkdir -p "$1/scripts/lib"
  cp "$HERE/scripts/roost-install" "$1/scripts/roost-install"
  cp "$HERE/scripts/lib/roost-adapters.sh" \
     "$HERE/scripts/lib/roost-hooks.sh" \
     "$HERE/scripts/lib/roost-json.sh" \
     "$HERE/scripts/lib/roost-opencode.sh" "$1/scripts/lib/"
}

if command -v git >/dev/null 2>&1; then
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
  # The scratch checkout is a COPY of the files roost-install needs, so a lib
  # that starts sourcing a new sibling breaks it without failing anything else
  # here: bash prints "No such file or directory" into this output and carries
  # on. That happened when roost-adapters.sh began sourcing roost-opencode.sh
  # and mkcheckout did not copy it. Asserted here so the next missing sibling
  # fails a test instead of being swallowed.
  case "$out" in *"No such file"*) s=missing ;; *) s=complete ;; esac
  assert_eq "$s" "complete" "behind upstream: the scratch checkout has every file the installer sources"
  assert_contains "$out" "1 commit behind $upname" \
    "behind upstream: the line names how far behind and what it tracks"
  assert_contains "$out" "To update the code:  roost upgrade" \
    "behind upstream: the line names the command to run"
  case "$out" in *"git -C"*) s=old ;; *) s=new ;; esac
  assert_eq "$s" "new" "behind upstream: the line no longer prints a raw git pull"
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
# 17. bin/roost exposes `install`, `upgrade`, and `update` as upgrade's alias
# ===========================================================================
# `update` has to be a real alias of `upgrade` -- the SAME script, reached with
# the SAME arguments -- rather than a second dispatch arm that happens to do
# the same thing today. A second arm would satisfy "both are mentioned in the
# help" and still diverge the first time either side gained a flag, silently.
#
# The proof is byte-identical --dry-run output, from a copy of roost that is
# NOT a git checkout: `upgrade` pulls, so a run from a repository would reach
# the network. Here the shim PATH has no git, so the first gate rule
# (`gate_git`) refuses before any git or tmux call,
# identically for both spellings (rc 1, same stderr). Both runs share ONE
# sandbox so the refusal text, which names the checkout, cannot differ for a
# reason that says nothing about the dispatch.
ROOST_BIN="$HERE/bin/roost"

run_roost() { # run_roost BOX SHIMDIR [args...]
  local box="$1" shim="$2"; shift 2
  mkdir -p "$box"
  HOME="$box/home" \
  XDG_CONFIG_HOME="$box/home/.config" \
  XDG_DATA_HOME="$box/home/.local/share" \
  COPILOT_HOME="$box/home/.copilot" \
  PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
  CODEX_HOME="$box/home/.codex" \
  CLAUDE_CONFIG_DIR="$box/home/.claude" CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
  PATH="$shim" \
    env -u TMUX -u TMUX_PANE -u ROOST_SOCKET -u ROOST_SELF_SOCK \
    bash "${RUN_BIN:-$ROOST_BIN}" "$@" </dev/null 2>&1
}

dispatch_box="$TMP/dispatchbox"
inst_out="$(run_roost "$dispatch_box" "$ALL_JSON_SHIM" install --dry-run)"; inst_rc=$?
assert_eq "$inst_rc" "0" "roost install --dry-run exits 0"
# Pin the installer's own closing line, not a word that also appears in the
# plan above it. "dry-run" alone matches the `--dry-run` flag echoed in the
# usage text as well, so a dispatch that fell through to the usage error
# would still match it.
assert_contains "$inst_out" "--dry-run: nothing above was written." \
  "roost install --dry-run reaches the installer's own plan"

nogit="$TMP/dispatch-nogit"
copy_checkout "$nogit"
RUN_BIN="$nogit/bin/roost"
up_out="$(run_roost "$dispatch_box" "$ALL_JSON_SHIM" upgrade --dry-run)"; up_rc=$?
upd_out="$(run_roost "$dispatch_box" "$ALL_JSON_SHIM" update --dry-run)"; upd_rc=$?
unset RUN_BIN
assert_eq "$up_rc"  "1" "roost upgrade --dry-run from a non-checkout is refused (exit 1)"
assert_eq "$upd_rc" "1" "roost update --dry-run from a non-checkout is refused (exit 1)"
# The refusal is what proves `upgrade` reached scripts/roost-upgrade at all:
# a dispatch that fell through to the usage error would print something else.
assert_contains "$up_out" "roost upgrade: refused" \
  "roost upgrade --dry-run reaches the upgrade script's own gate"
assert_eq "$upd_out" "$up_out" \
  "roost update --dry-run is byte-identical to roost upgrade --dry-run"

# Arguments really are forwarded, not swallowed. Without a `shift` in
# bin/roost's install arm the installer is handed `install --help`:
# the SUBCOMMAND arrives as its first argument, hits the installer's `*)` arm
# and exits 2 with `roost install: unknown argument 'install'`, so --help is
# never looked at. Measured by deleting that one line -- 7 assertions in this
# file fail, both --dry-run runs among them. The identity check above does
# catch it, because the refusal names the subcommand and the two spellings
# therefore differ; what it cannot tell you is that the failure was a usage
# error rather than a dropped flag, which is what this loop is here to pin.
for sub in install; do
  out="$(run_roost "$dispatch_box" "$ALL_JSON_SHIM" "$sub" --help)"; rc=$?
  assert_eq "$rc" "0" "roost $sub --help exits 0"
  assert_contains "$out" "usage: roost install [-y|--yes] [--dry-run]" \
    "roost $sub --help prints the installer's usage"
  # The installer's exit-2 arm, reached through bin/roost rather than around
  # it: 2 is the usage code the script documents, and bin/roost's own
  # unknown-subcommand arm also exits 2, so this only means anything
  # alongside the --help case above proving the script is what answered.
  run_roost "$dispatch_box" "$ALL_JSON_SHIM" "$sub" --nonsense >/dev/null 2>&1
  assert_eq "$?" "2" "roost $sub rejects an unknown flag with exit 2"
done

# --- the help block --------------------------------------------------------
# bin/roost's help is read back out of its own header comment, so this is
# also the check that the header carries both lines.
help_out="$(ROOST_BANNER=blocks bash "$ROOST_BIN" help)"
for sub in install upgrade update; do
  n="$(printf '%s\n' "$help_out" | grep -c "roost $sub" || true)"
  assert_eq "$n" "1" "roost help lists \`roost $sub\` on exactly one line"
done

# `roost install` must say it never fetches, and `roost upgrade` that it pulls:
# someone who types either expecting the other has been misled by this file,
# not by their own guess. `update` must say it is the same as `upgrade`.
#
# Asserted against each extracted LINE, never the whole help text: "install"
# appears on several lines of that block, and a phrase-level match against all
# of it would stay green with one of these lines deleted.
inst_line="$(printf '%s\n' "$help_out" | grep 'roost install ')"
assert_contains "$inst_line" "never fetches" \
  "the roost install help line says it never fetches code"
up_line="$(printf '%s\n' "$help_out" | grep 'roost upgrade ')"
assert_contains "$up_line" "fast-forward only" \
  "the roost upgrade help line says it pulls, fast-forward only"
upd_line="$(printf '%s\n' "$help_out" | grep 'roost update ')"
assert_contains "$upd_line" "the same as" \
  "the roost update help line says it is the same as upgrade"

# ===========================================================================
# 18. --records: the machine-readable record of what this run actually wrote
# ===========================================================================
# The reason it exists: `roost validate` used to rebuild its report by reading
# the adapter state back off the disk after the installer had run, and "is it
# linked now" is a different question from "did this run link it". The two
# diverge in both directions -- a link created against a target that does not
# exist reads back as `dangling`, and a link a tester makes in another
# terminal while validate's prompt is open reads back as `ok` -- so the report
# both hid a write and claimed one. This file is the installer stating what it
# did, and it is the only thing validate is allowed to build that report from.
#
# TAB-separated, one line per path the run reached a final outcome for:
#   VERB \t HARNESS \t PATH \t UNDO
# VERB is wrote | unchanged | refused | failed, and UNDO is empty for
# everything but `wrote`.
TAB="$(printf '\t')"
records_of() { cat "$1" 2>/dev/null; }

box="$TMP/records"
recs="$TMP/records.tsv"
out="$(run_install "$box" "$ALL_SHIM" --yes --records "$recs")"; rc=$?
assert_eq "$rc" "0" "--records: the run still exits 0"
for h in opencode pi copilot; do
  p="$(adapter_path_in "$box" "$h")"
  assert_contains "$(records_of "$recs")" "wrote$TAB$h$TAB$p${TAB}rm \"$p\"" \
    "--records: $h is recorded as written, with its own undo command"
done
# The undo lines in the record and the undo lines the human sees are the same
# lines. Two spellings of "what this run wrote" is the drift this file exists
# to prevent, so they are compared rather than each asserted alone.
rec_undo="$(records_of "$recs" | while IFS="$TAB" read -r v h p u; do
  [ "$v" = wrote ] && printf '%s\n' "$u"; done | sort)"
# Both shapes: a skill link's undo is guarded, so it starts `if [` (#208).
human_undo="$(printf '%s\n' "$out" | sed -n -e 's/^  rm "/rm "/p' -e 's/^  if \[ /if [ /p' | sort)"
assert_eq "$rec_undo" "$human_undo" \
  "--records: the recorded undo lines are the ones printed to the human"

# A second run wrote nothing. `unchanged` is not the absence of a line: the
# absence of a line is what a failed write looks like, and validate has to be
# able to tell "already correct" from "could not do it" without going back to
# the disk.
recs2="$TMP/records2.tsv"
out2="$(run_install "$box" "$ALL_SHIM" --yes --records "$recs2")"
for h in opencode pi copilot; do
  p="$(adapter_path_in "$box" "$h")"
  assert_contains "$(records_of "$recs2")" "unchanged$TAB$h$TAB$p$TAB" \
    "--records: a re-run records $h as unchanged"
done
n="$(grep -c "^wrote$TAB" "$recs2" || true)"
assert_eq "${n:-0}" "0" "--records: a re-run records no write at all"

# A foreign path is `refused`, never a silent gap.
box="$TMP/records-foreign"
mkdir -p "$box/home/.pi/agent/extensions"
printf 'my own extension\n' > "$box/home/.pi/agent/extensions/roost.ts"
recs3="$TMP/records3.tsv"
run_install "$box" "$ALL_SHIM" --yes --records "$recs3" >/dev/null
fpath="$(adapter_path_in "$box" pi)"
assert_contains "$(records_of "$recs3")" "refused${TAB}pi$TAB$fpath$TAB" \
  "--records: a foreign path is recorded as refused"
# Matched on the refused PATH: pi's skill link (#208) is a separate path that
# this run really did write.
case "$(records_of "$recs3")" in *"wrote${TAB}pi$TAB$fpath$TAB"*) s=claimed ;; *) s=absent ;; esac
assert_eq "$s" "absent" "--records: a path this run refused is never recorded as written"

# --dry-run wrote nothing, so it records no write. The file is still created
# and truncated, so a caller can tell "the installer ran and wrote nothing"
# from "the installer never got far enough to touch this file".
box="$TMP/records-dry"
recs4="$TMP/records4.tsv"
run_install "$box" "$ALL_SHIM" --dry-run --records "$recs4" >/dev/null
assert_true "$([ -f "$recs4" ] && printf 0 || printf 1)" \
  "--records: --dry-run still creates the records file"
n="$(grep -c "^wrote$TAB" "$recs4" || true)"
assert_eq "${n:-0}" "0" "--records: --dry-run records no write"

# The JSON writes are in the record too. A record of "what this run wrote"
# that quietly covered only the symlinks would be a trap for the next caller,
# and the undo for a merge is a `cp` from the backup, not an `rm`.
box="$TMP/records-json"
recs5="$TMP/records5.tsv"
run_install "$box" "$ALL_JSON_SHIM" --yes --only claude --records "$recs5" >/dev/null
cset="$box/home/.claude/settings.json"
assert_contains "$(records_of "$recs5")" "wrote${TAB}claude$TAB$cset${TAB}rm \"$cset\"" \
  "--records: a settings.json this run created records an rm as its undo"
run_install "$box" "$ALL_JSON_SHIM" --yes --only claude --records "$TMP/records5b.tsv" >/dev/null
assert_contains "$(records_of "$TMP/records5b.tsv")" "unchanged${TAB}claude$TAB$cset$TAB" \
  "--records: a settings.json already carrying roost's hooks records as unchanged"

# The human-facing output is byte-identical with the flag and without it. This
# is the constraint the flag was added under: it is opt-in and machine-only,
# and a run someone is watching must not get noisier because validate wanted a
# record. Two fresh boxes, with the box path folded out, because the same box
# twice is not the same run.
box_a="$TMP/records-quiet-a"; box_b="$TMP/records-quiet-b"
out_a="$(run_install "$box_a" "$ALL_JSON_SHIM" --yes --records "$TMP/records6.tsv")"
out_b="$(run_install "$box_b" "$ALL_JSON_SHIM" --yes)"
assert_eq "${out_a//$box_a/BOX}" "${out_b//$box_b/BOX}" \
  "--records: the output a human reads is byte-identical with and without it"

# A missing value is a usage error, for the same reason --only's is: a caller
# whose variable was unset must not get a silent run with no record, which
# reads to validate exactly like a run that wrote nothing.
run_install "$TMP/records-noval" "$ALL_SHIM" --records >/dev/null 2>&1
assert_eq "$?" "2" "--records with no value exits 2"
run_install "$TMP/records-flagval" "$ALL_SHIM" --records --yes >/dev/null 2>&1
assert_eq "$?" "2" "--records swallowing a following flag as its value exits 2"

# ===========================================================================
# 19. json_probe answers only in the words its own contract lists
# ===========================================================================
# json_probe is internal to scripts/roost-install, and that file runs a whole
# install the moment it is sourced -- so its three functions are lifted out by
# name and eval'd here instead. That extraction is checked before it is
# trusted: a harness that quietly defined nothing would leave every case below
# reading `malformed` and passing for exactly the wrong reason, which is the
# shape of bug this section exists to catch in the first place.
#
# Both engines run. roost_json_tool prefers python3 whenever it is present, so
# the jq implementation -- a whole second copy of the same logic, kept so a
# jq-only machine can still tell "already wired" from "wired somewhere else" --
# would otherwise never execute on the developer's machine.
PROBE_SRC="$(sed -n '/^json_probe__py() {/,/^# --- is this checkout itself behind/p' "$INSTALL")"
PROBE_PY_SHIM="$(make_one_tool_shim python3)"
PROBE_JQ_SHIM="$(make_one_tool_shim jq)"

# probe TOOLDIR MODE FILE [PATCH WANT] -> the probe's one word, with the tool
# on PATH being the ONLY JSON engine the run can find.
probe() {
  local tooldir="$1"; shift
  PATH="$tooldir" bash -c '
    set -u
    . "$1/scripts/lib/roost-json.sh"
    . "$1/scripts/lib/roost-hooks.sh"
    eval "$2"
    shift 2
    json_probe "$@"
  ' _ "$HERE" "$PROBE_SRC" "$@"
}

PROBE_BOX="$TMP/probe"; mkdir -p "$PROBE_BOX"
PROBE_WANT="/some/checkout/scripts/roost-agent-state"
PROBE_PATCH="$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_claude "$PROBE_WANT")"
printf '%s' '{"model":"opus"}'                            > "$PROBE_BOX/nohooks.json"
printf '%s' '{"enabledFeatureFlags":{"EXTENSIONS":false}}' > "$PROBE_BOX/flagoff.json"
printf '%s' '{"enabledFeatureFlags":{"EXTENSIONS":true}}'  > "$PROBE_BOX/flagon.json"
printf '%s' 'this is not json at all'                      > "$PROBE_BOX/garbage.json"

for eng in py jq; do
  case "$eng" in py) shim="$PROBE_PY_SHIM" ;; jq) shim="$PROBE_JQ_SHIM" ;; esac

  # The harness self-check, first and on its own two answers. These two must
  # DIFFER: one word for both would mean the eval defined nothing useful and
  # every case below is reading a default.
  assert_eq "$(probe "$shim" flag "$PROBE_BOX/flagon.json")" "ours" \
    "$eng: the lifted-out probe runs (a flag already true reads as ours)"
  assert_eq "$(probe "$shim" hooks "$PROBE_BOX/garbage.json" "$PROBE_PATCH" "$PROBE_WANT")" \
    "malformed" "$eng: the lifted-out probe still reports a real parse error as malformed"

  # A settings.json with no "hooks" key is the most ordinary claude file this
  # command will ever meet, and it parses perfectly. Reporting it as
  # `malformed` -- the one word whose stated job is surfacing a parse error --
  # is wrong even where the write that follows happens to be identical.
  assert_eq "$(probe "$shim" hooks "$PROBE_BOX/nohooks.json" "$PROBE_PATCH" "$PROBE_WANT")" \
    "$(printf 'write\t0\t0')" "$eng: a well-formed settings.json with no hooks key is a write, not malformed"

  # Same for the copilot flag: absent or false is a write, and nothing about
  # the file is malformed.
  assert_eq "$(probe "$shim" flag "$PROBE_BOX/flagoff.json")" \
    "$(printf 'write\t0\t0')" "$eng: a well-formed copilot settings.json with EXTENSIONS off is a write, not malformed"
done
rm -rf "$PROBE_PY_SHIM" "$PROBE_JQ_SHIM"

# ===========================================================================
# 20. The adapter table and opencode 2
# ===========================================================================
# opencode 2's adapter is a DIRECTORY symlink at its own path, so the table
# carries it as a key of its own, `opencode2`, and roost_adapter_key says which
# of the two opencode keys this machine gets. Every case sources the lib in a
# fresh `bash -c` under `set -u` -- roost-install, roost-doctor and
# roost-validate source it, some of them with `set -u` in force -- with PATH
# set to a shim, so the opencode it asks is a stub that prints a version line
# and never a real binary.

# in_adapter_lib ROOT BOX SHIMDIR FUNC [ARG...] -> what FUNC prints when the
# lib is sourced from the checkout at ROOT, with every harness home under BOX
# and PATH set to SHIMDIR.
in_adapter_lib() {
  local root="$1" box="$2" shim="$3"; shift 3
  mkdir -p "$box"
  HOME="$box/home" \
  XDG_CONFIG_HOME="$box/home/.config" \
  XDG_DATA_HOME="$box/home/.local/share" \
  COPILOT_HOME="$box/home/.copilot" \
  PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
  CODEX_HOME="$box/home/.codex" \
  CLAUDE_CONFIG_DIR="$box/home/.claude" CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
  PATH="$shim" \
    bash -c 'set -u; . "$1/scripts/lib/roost-adapters.sh"; shift; "$@"' _ "$root" "$@"
}

OC2_V2_SHIM="$(make_versioned_shim 'opencode v2.0.20' opencode)"
OC2_V1_SHIM="$(make_versioned_shim '1.18.30' opencode)"
# The silent stub is make_harness_shim's own `exit 0` one, which prints nothing
# at all -- not even an empty line. Built on a versioned shim with no opencode
# in it, so it still carries the `sleep` the watchdog needs.
OC2_SILENT_SHIM="$(make_versioned_shim '')"
printf '#!/bin/sh\nexit 0\n' > "$OC2_SILENT_SHIM/opencode"
chmod +x "$OC2_SILENT_SHIM/opencode"
OC2_NONE_SHIM="$(make_versioned_shim '')"
OC2_BOX="$TMP/oc2"

assert_eq "$(in_adapter_lib "$HERE" "$OC2_BOX" "$OC2_V2_SHIM" roost_adapter_key opencode)" "opencode2" \
  "roost_adapter_key opencode is opencode2 when opencode on PATH says v2.0.20"
assert_eq "$(in_adapter_lib "$HERE" "$OC2_BOX" "$OC2_V1_SHIM" roost_adapter_key opencode)" "opencode" \
  "roost_adapter_key opencode stays opencode when opencode on PATH says 1.18.30"
assert_eq "$(in_adapter_lib "$HERE" "$OC2_BOX" "$OC2_SILENT_SHIM" roost_adapter_key opencode)" "opencode" \
  "roost_adapter_key opencode stays opencode when opencode on PATH prints no version"
assert_eq "$(in_adapter_lib "$HERE" "$OC2_BOX" "$OC2_NONE_SHIM" roost_adapter_key opencode)" "opencode" \
  "roost_adapter_key opencode stays opencode with no opencode on PATH"
# Any other harness comes back unchanged, even on a machine with a 2.x.
assert_eq "$(in_adapter_lib "$HERE" "$OC2_BOX" "$OC2_V2_SHIM" roost_adapter_key pi)" "pi" \
  "roost_adapter_key pi is pi, whatever opencode is on PATH"

oc2_path="$(in_adapter_lib "$HERE" "$OC2_BOX" "$OC2_NONE_SHIM" roost_adapter_path opencode2)"
assert_prefix "$oc2_path" "$OC2_BOX/home/.config/opencode/" \
  "roost_adapter_path opencode2 is inside opencode's own config directory"
case "$oc2_path" in */opencode/plugins/roost) r=0 ;; *) r=1 ;; esac
assert_true "$r" "roost_adapter_path opencode2 ends in /opencode/plugins/roost (got $oc2_path)"
oc2_want="$(in_adapter_lib "$HERE" "$OC2_BOX" "$OC2_NONE_SHIM" roost_adapter_target opencode2)"
# `cd -P`, because the lib resolves its root through symlinks and $HERE does
# not; a checkout reached through a symlinked directory would otherwise fail
# here on spelling alone.
assert_eq "$oc2_want" "$(cd -P "$HERE" && pwd)/adapters/opencode/v2" \
  "roost_adapter_target opencode2 is this checkout's adapters/opencode/v2"
# The state cases below run against a scratch copy (the comment there says
# why), so they cannot see whether THIS checkout has the directory the table
# names. This line can: a table naming a directory the checkout does not ship
# would have roost install create a link that reads `dangling` the moment it
# exists.
[ -d "$oc2_want" ]; assert_true $? \
  "roost_adapter_target opencode2, from this checkout, names a directory that exists"

# The three states, on one path. The link is made to the same target string
# the table returns, so `ok` here is the table agreeing with itself through
# `-ef` on a DIRECTORY symlink -- the one thing this key adds over the other
# three, whose links all name a file.
#
# Run against a COPY of scripts/lib in a scratch checkout that has an
# adapters/opencode/v2 directory, not against this checkout. The table finds
# its root from its own file's location (_roost_adapter_root), so the copy
# answers for the scratch checkout. That keeps `ok` meaning "the link reaches a
# directory that is there" whether or not this checkout has the adapter yet --
# against a target that does not exist, the same link reads `dangling`, and the
# case would pass or fail on the state of the tree rather than on the table.
# Resolved with `cd -P` once it exists, because _roost_adapter_root resolves
# its own root the same way: on macOS /tmp is itself a symlink, and
# the unresolved spelling would never compare equal to what the lib prints.
mkdir -p "$TMP/oc2-checkout/scripts/lib" "$TMP/oc2-checkout/adapters/opencode/v2"
OC2_CO="$(cd -P "$TMP/oc2-checkout" && pwd)"
cp "$HERE"/scripts/lib/*.sh "$OC2_CO/scripts/lib/"
oc2_co_want="$(in_adapter_lib "$OC2_CO" "$OC2_BOX" "$OC2_NONE_SHIM" roost_adapter_target opencode2)"
assert_eq "$oc2_co_want" "$OC2_CO/adapters/opencode/v2" \
  "a copy of the lib answers for its own scratch checkout (the harness for the state cases)"
assert_eq "$(in_adapter_lib "$OC2_CO" "$OC2_BOX" "$OC2_NONE_SHIM" roost_adapter_state opencode2)" "missing" \
  "roost_adapter_state opencode2 is missing in an empty home"
mkdir -p "${oc2_path%/*}"
ln -s "$oc2_co_want" "$oc2_path"
assert_eq "$(in_adapter_lib "$OC2_CO" "$OC2_BOX" "$OC2_NONE_SHIM" roost_adapter_state opencode2)" "ok" \
  "roost_adapter_state opencode2 is ok once the plugin directory links to the checkout"
rm -f "$oc2_path"
mkdir -p "$oc2_path"
assert_eq "$(in_adapter_lib "$OC2_CO" "$OC2_BOX" "$OC2_NONE_SHIM" roost_adapter_state opencode2)" "foreign" \
  "roost_adapter_state opencode2 is foreign when a real directory sits at the path"
# The stronger control. A real directory is not a symlink, so the case above
# cannot tell `-ef` from "any symlink to any directory is ok". A link to some
# OTHER real directory -- another checkout's adapter, say -- is the realistic
# foreign case, and only `-ef` reads it as foreign.
rm -rf "$oc2_path"
mkdir -p "$OC2_BOX/elsewhere"
ln -s "$OC2_BOX/elsewhere" "$oc2_path"
assert_eq "$(in_adapter_lib "$OC2_CO" "$OC2_BOX" "$OC2_NONE_SHIM" roost_adapter_state opencode2)" "foreign" \
  "roost_adapter_state opencode2 is foreign when the path links to some other real directory"

rm -rf "$OC2_V2_SHIM" "$OC2_V1_SHIM" "$OC2_SILENT_SHIM" "$OC2_NONE_SHIM"

# ===========================================================================
# 21. roost install on an opencode 2 machine
# ===========================================================================
# One binary, two adapters, and the version on PATH decides which one a run
# links (roost_adapter_key). On 2.x the adapter is the DIRECTORY
# adapters/opencode/v2, linked at plugins/roost; roost's own 1.x link at
# plugin/roost.js is removed, because opencode 2 cannot load it and says
# `1 plugin failed`. Anything else at that path is left alone and named.
#
# Every opencode here is a stub that prints a version line (make_versioned_shim)
# -- never a real binary. The 1.x and the silent-stub runs are the control:
# they must do exactly what sections 1-3 pin, with nothing at plugins/roost.
OCI_V2_SHIM="$(make_versioned_shim 'opencode v2.0.20' opencode)"
OCI_V1_SHIM="$(make_versioned_shim '1.18.30' opencode)"

# --- 2.x, a fresh home -> plugins/roost linked, and no plugin/roost.js ------
box="$TMP/oc2-fresh"
p1="$(adapter_path_in "$box" opencode)"
p2="$(adapter_path_in "$box" opencode2)"
out="$(run_install "$box" "$OCI_V2_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "opencode 2, fresh home: exits 0"
assert_contains "$out" "$p2" "opencode 2, fresh home: the plan names plugins/roost"
assert_contains "$out" "$(adapter_target opencode2)" \
  "opencode 2, fresh home: the plan names the v2 target"
[ -L "$p2" ]; assert_true $? "opencode 2, fresh home: plugins/roost is a symlink"
assert_eq "$(readlink "$p2" 2>/dev/null)" "$(adapter_target opencode2)" \
  "opencode 2, fresh home: plugins/roost points at adapters/opencode/v2"
[ -d "$p2/" ]; assert_true $? "opencode 2, fresh home: plugins/roost reaches a real directory"
[ ! -e "$p1" ] && [ ! -L "$p1" ]; assert_true $? \
  "opencode 2, fresh home: no plugin/roost.js was created"
n="$(find "$box/home" -type l ! -path '*/skills/roost' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "1" "opencode 2, fresh home: exactly one symlink was created"
assert_contains "$out" "rm \"$p2\"" "opencode 2, fresh home: the undo names plugins/roost"

# --- 2.x, a re-run -> nothing written, and the summary names opencode -------
before="$(tree_of "$box")"
out="$(run_install "$box" "$OCI_V2_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "opencode 2, re-run: exits 0"
assert_eq "$(tree_of "$box")" "$before" "opencode 2, re-run: the sandbox tree is unchanged"
assert_contains "$out" "Already correct: opencode" \
  "opencode 2, re-run: the Already correct line names opencode"
case "$out" in *"Will remove"*|*"Will write"*) s=planned ;; *) s=quiet ;; esac
assert_eq "$s" "quiet" "opencode 2, re-run: nothing is planned"

# --- 2.x, roost's own 1.x link present -> removed, and plugins/roost linked -
box="$TMP/oc2-own1x"
p1="$(adapter_path_in "$box" opencode)"
p2="$(adapter_path_in "$box" opencode2)"
mkdir -p "${p1%/*}"
ln -s "$(adapter_target opencode)" "$p1"
out="$(run_install "$box" "$OCI_V2_SHIM" --dry-run)"; rc=$?
assert_eq "$rc" "0" "opencode 2, own 1.x link, --dry-run: exits 0"
assert_contains "$out" "Will remove:" \
  "opencode 2, own 1.x link: the plan says something will be removed"
assert_contains "$out" "$p1" "opencode 2, own 1.x link: the plan names plugin/roost.js"
assert_contains "$out" "1 plugin failed" \
  "opencode 2, own 1.x link: the plan names the '1 plugin failed' it causes"
[ -L "$p1" ]; assert_true $? "opencode 2, own 1.x link: --dry-run left it in place"
[ ! -e "$p2" ] && [ ! -L "$p2" ]; assert_true $? \
  "opencode 2, own 1.x link: --dry-run linked nothing"
recs="$TMP/oc2-own1x.tsv"
out="$(run_install "$box" "$OCI_V2_SHIM" --yes --records "$recs")"; rc=$?
assert_eq "$rc" "0" "opencode 2, own 1.x link: exits 0"
[ ! -e "$p1" ] && [ ! -L "$p1" ]; assert_true $? \
  "opencode 2, own 1.x link: plugin/roost.js is gone after --yes"
assert_eq "$(readlink "$p2" 2>/dev/null)" "$(adapter_target opencode2)" \
  "opencode 2, own 1.x link: plugins/roost is linked"
# The undo for a removal puts the link back, not an `rm`.
undo1="ln -s \"$(adapter_target opencode)\" \"$p1\""
assert_contains "$out" "$undo1" "opencode 2, own 1.x link: the undo puts the 1.x link back"
assert_contains "$(records_of "$recs")" "removed${TAB}opencode$TAB$p1$TAB$undo1" \
  "opencode 2, own 1.x link: --records says it was removed, with its undo"
assert_contains "$(records_of "$recs")" "wrote${TAB}opencode$TAB$p2${TAB}rm \"$p2\"" \
  "opencode 2, own 1.x link: --records says plugins/roost was written"
# The checkout's own 1.x adapter is untouched: removing a link never reaches
# what it points at.
[ -f "$(adapter_target opencode)" ]; assert_true $? \
  "opencode 2, own 1.x link: the checkout's adapters/opencode/roost.js is still there"

# A DANGLING 1.x link is ours too -- the checkout it pointed at moved -- so it
# goes the same way.
box="$TMP/oc2-dangling1x"
p1="$(adapter_path_in "$box" opencode)"
mkdir -p "${p1%/*}"
ln -s "$TMP/no-such-checkout/adapters/opencode/roost.js" "$p1"
out="$(run_install "$box" "$OCI_V2_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "opencode 2, dangling 1.x link: exits 0"
[ ! -L "$p1" ]; assert_true $? "opencode 2, dangling 1.x link: it is removed"
# `1 plugin failed` was measured for a live 1.x adapter, not a dangling link,
# so the plan claims only that it points at nothing.
assert_contains "$out" "it points at nothing" \
  "opencode 2, dangling 1.x link: the plan says it points at nothing"
case "$out" in *"1 plugin failed"*) s=claimed ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 2, dangling 1.x link: the plan does not claim '1 plugin failed'"

# A dangling link that never named a roost adapter is NOT ours: `dangling`
# says only that the target is gone, not whose target it was. The user's own
# plugin on a volume that is not mounted right now reads exactly this way. So
# it is refused, as scripts/roost-doctor already judges it -- a link is
# roost's only when it ends in /adapters/opencode/roost.js. The case above,
# whose target does end that way, is the control: it is still removed.
box="$TMP/oc2-danglingforeign"
p1="$(adapter_path_in "$box" opencode)"
mkdir -p "${p1%/*}"
ln -s "/nowhere/my-own-plugin.js" "$p1"
recs="$TMP/oc2-danglingforeign.tsv"
out="$(run_install "$box" "$OCI_V2_SHIM" --yes --records "$recs")"; rc=$?
assert_eq "$rc" "0" "opencode 2, dangling link that is not roost's: exits 0"
assert_eq "$(readlink "$p1" 2>/dev/null)" "/nowhere/my-own-plugin.js" \
  "opencode 2, dangling link that is not roost's: the link is still there"
assert_contains "$(records_of "$recs")" "refused${TAB}opencode$TAB$p1$TAB" \
  "opencode 2, dangling link that is not roost's: --records says it was refused"
case "$out" in *"Will remove:"*) s=planned ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 2, dangling link that is not roost's: no Will remove: section"
case "$out" in *"removed "*) s=removed ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 2, dangling link that is not roost's: nothing is reported removed"
case "$out" in *"roost's own"*) s=claimed ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 2, dangling link that is not roost's: nothing calls it roost's own"
assert_contains "$out" "something that is not this checkout's link is at" \
  "opencode 2, dangling link that is not roost's: the manual note says it is not this checkout's link"

# The same rule at apply time. The plan sees roost's own dangling 1.x link and
# plans its removal; then, before the removal runs, the link is swapped for
# someone else's dangling one -- which still reads `dangling`. The swap rides
# on `ln`: the plugins/roost link step runs before the unlink step in the
# apply loop, and `ln` comes from the shim PATH. The shim's `ln` is a SYMLINK
# to the real binary, so it is removed first and the wrapper written to a
# fresh file: `>` would follow the link and overwrite the real `ln`.
SWAP_SHIM="$(make_versioned_shim 'opencode v2.0.20' opencode)"
real_ln="$(command -v ln)"
box="$TMP/oc2-danglingswap"
p1="$(adapter_path_in "$box" opencode)"
rm -f "$SWAP_SHIM/ln"
if [ ! -e "$SWAP_SHIM/ln" ] && [ ! -L "$SWAP_SHIM/ln" ]; then
  cat > "$SWAP_SHIM/ln" <<EOF
#!/bin/sh
case "\$*" in
  *plugins/roost*) "$(command -v rm)" -f "$p1" && "$real_ln" -s /nowhere/swapped-in.js "$p1" ;;
esac
exec "$real_ln" "\$@"
EOF
  chmod +x "$SWAP_SHIM/ln"
fi
mkdir -p "${p1%/*}"
ln -s "$TMP/no-such-checkout/adapters/opencode/roost.js" "$p1"
recs="$TMP/oc2-danglingswap.tsv"
out="$(run_install "$box" "$SWAP_SHIM" --yes --records "$recs")"; rc=$?
assert_eq "$rc" "0" "opencode 2, swapped for a foreign dangling link during the run: exits 0"
assert_contains "$out" "Will remove:" \
  "opencode 2, swapped for a foreign dangling link during the run: the plan saw roost's link"
assert_eq "$(readlink "$p1" 2>/dev/null)" "/nowhere/swapped-in.js" \
  "opencode 2, swapped for a foreign dangling link during the run: the swapped-in link is still there"
assert_contains "$(records_of "$recs")" "refused${TAB}opencode$TAB$p1$TAB" \
  "opencode 2, swapped for a foreign dangling link during the run: --records says it was refused"
rm -rf "$SWAP_SHIM"

# --- 2.x, a foreign file at plugin/roost.js -> untouched, and named ---------
box="$TMP/oc2-foreign1x"
p1="$(adapter_path_in "$box" opencode)"
p2="$(adapter_path_in "$box" opencode2)"
mkdir -p "${p1%/*}"
printf 'export const mine = true; // not roost\n' > "$p1"
fbefore="$(cksum < "$p1")"
recs="$TMP/oc2-foreign1x.tsv"
out="$(run_install "$box" "$OCI_V2_SHIM" --yes --records "$recs")"; rc=$?
assert_eq "$rc" "0" "opencode 2, foreign plugin/roost.js: exits 0"
assert_eq "$(cksum < "$p1" 2>/dev/null)" "$fbefore" \
  "opencode 2, foreign plugin/roost.js: the file is byte-identical after"
assert_contains "$out" "$p1" "opencode 2, foreign plugin/roost.js: the path is named"
assert_contains "$(records_of "$recs")" "refused${TAB}opencode$TAB$p1$TAB" \
  "opencode 2, foreign plugin/roost.js: --records says it was refused"
# Never the 1.x manual fix: on 2.x, linking roost's 1.x adapter there is the
# thing that breaks opencode, so the note must not hand the user that command.
case "$out" in *"ln -s \"$(adapter_target opencode)\""*) s=offered ;; *) s=absent ;; esac
assert_eq "$s" "absent" \
  "opencode 2, foreign plugin/roost.js: the manual note does not offer to link the 1.x adapter"
assert_eq "$(readlink "$p2" 2>/dev/null)" "$(adapter_target opencode2)" \
  "opencode 2, foreign plugin/roost.js: plugins/roost is still linked"

# Another checkout's 1.x link is roost's own link from a second copy, and
# opencode 2 cannot load it whichever copy it names, so it is removed like
# this checkout's own. Run from case 3b's plain copy, which is no git
# repository at all: the checkout running this suite may be a worktree, and
# with no git on this shim its `.git` file would read as one. Case 3b runs the
# same link from a real worktree and its primary.
box="$TMP/oc2-other1x"
p1="$(adapter_path_in "$box" opencode)"
mkdir -p "${p1%/*}" "$TMP/other-checkout/adapters/opencode"
printf '// another checkout\n' > "$TMP/other-checkout/adapters/opencode/roost.js"
ln -s "$TMP/other-checkout/adapters/opencode/roost.js" "$p1"
out="$(run_install_from "$plain" "$box" "$OCI_V2_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "opencode 2, another checkout's 1.x link: exits 0"
[ ! -e "$p1" ] && [ ! -L "$p1" ]; assert_true $? \
  "opencode 2, another checkout's 1.x link: removed"
[ -f "$TMP/other-checkout/adapters/opencode/roost.js" ]; assert_true $? \
  "opencode 2, another checkout's 1.x link: the other checkout's file is untouched"
assert_contains "$out" "ln -s \"$TMP/other-checkout/adapters/opencode/roost.js\" \"$p1\"" \
  "opencode 2, another checkout's 1.x link: the undo puts it back"

# The checkout's own 1.x FILE, reached through a plugin/ directory that is
# itself a symlink into the checkout. roost_adapter_state says `ok` (an -ef
# test), but the path is not a link: an `rm` there deletes
# adapters/opencode/roost.js out of the checkout. So the run refuses it, and
# the manual note must not hand the user that `rm` either -- the fix is the
# directory, never the file.
#
# It runs in a SCRATCH checkout (mkcheckout), never against this one. The
# scratch roost-install resolves _roost_adapter_root to the scratch tree, so
# `-ef` holds against a COPY of adapters/opencode/roost.js, and plugin/ links
# to the copy's directory. Were both `-L` guards in roost-install ever to
# regress, the `rm` would delete that copy -- not a tracked file in the
# developer's working copy, which is what this case used to put in reach.
symco="$TMP/oc2-symdir-checkout"
mkcheckout "$symco"
mkdir -p "$symco/adapters/opencode/v2"
cp "$HERE/adapters/opencode/roost.js" "$symco/adapters/opencode/roost.js"
cp "$HERE/adapters/opencode/v2/tui.js" "$symco/adapters/opencode/v2/tui.js"
# The scratch tree's own targets, read through its own lib: resolved the way
# its roost-install resolves them (`cd -P`, so a symlinked /tmp on macOS agrees).
symco_target() { # symco_target HARNESS
  bash -c '. "'"$symco"'/scripts/lib/roost-adapters.sh"; roost_adapter_target "$1"' _ "$1"
}
real1x_before="$(cksum < "$HERE/adapters/opencode/roost.js")"
box="$TMP/oc2-symdir"
p1="$(adapter_path_in "$box" opencode)"
p2="$(adapter_path_in "$box" opencode2)"
mkdir -p "${p1%/*/*}"
ln -s "$symco/adapters/opencode" "${p1%/*}"
recs="$TMP/oc2-symdir.tsv"
symdir_install="$INSTALL"
INSTALL="$symco/scripts/roost-install"
out="$(run_install "$box" "$OCI_V2_SHIM" --yes --records "$recs")"; rc=$?
INSTALL="$symdir_install"
assert_eq "$rc" "0" "opencode 2, symlinked plugin/ directory: exits 0"
[ -f "$(symco_target opencode)" ]; assert_true $? \
  "opencode 2, symlinked plugin/ directory: the scratch checkout's adapters/opencode/roost.js is still there"
assert_eq "$(cksum < "$HERE/adapters/opencode/roost.js" 2>/dev/null)" "$real1x_before" \
  "opencode 2, symlinked plugin/ directory: this checkout's adapters/opencode/roost.js is byte-identical"
assert_contains "$(records_of "$recs")" "refused${TAB}opencode$TAB$p1$TAB" \
  "opencode 2, symlinked plugin/ directory: --records says it was refused"
assert_eq "$(readlink "$p2" 2>/dev/null)" "$(symco_target opencode2)" \
  "opencode 2, symlinked plugin/ directory: plugins/roost is linked"
assert_contains "$out" "this checkout's own file, reached through a symlinked directory" \
  "opencode 2, symlinked plugin/ directory: the Will NOT touch heading says what is there"
assert_contains "$out" "is a regular file reached through a symlinked plugin/ directory" \
  "opencode 2, symlinked plugin/ directory: the manual note says what the path is"
assert_contains "$out" "never delete the file" \
  "opencode 2, symlinked plugin/ directory: the manual note says not to delete the file"
assert_contains "$out" "remove or re-point" \
  "opencode 2, symlinked plugin/ directory: the manual note names the directory as the fix"
case "$out" in *"rm \"$p1\""*) s=offered ;; *) s=absent ;; esac
assert_eq "$s" "absent" \
  "opencode 2, symlinked plugin/ directory: the manual note does not offer rm of the file"
case "$out" in *"something that is not this checkout"*) s=claimed ;; *) s=absent ;; esac
assert_eq "$s" "absent" \
  "opencode 2, symlinked plugin/ directory: nothing calls this checkout's own file 'not this checkout'"

# --- --only opencode on 2.x covers both keys ---------------------------------
box="$TMP/oc2-only"
p1="$(adapter_path_in "$box" opencode)"
p2="$(adapter_path_in "$box" opencode2)"
mkdir -p "${p1%/*}"
ln -s "$(adapter_target opencode)" "$p1"
out="$(run_install "$box" "$OCI_V2_SHIM" --only opencode --yes)"; rc=$?
assert_eq "$rc" "0" "--only opencode on opencode 2: exits 0"
assert_eq "$(readlink "$p2" 2>/dev/null)" "$(adapter_target opencode2)" \
  "--only opencode on opencode 2: plugins/roost is linked"
[ ! -L "$p1" ]; assert_true $? "--only opencode on opencode 2: roost's 1.x link is removed"

# --- 1.x -> exactly today's behaviour, and nothing at plugins/roost ----------
box="$TMP/oc1-fresh"
p1="$(adapter_path_in "$box" opencode)"
p2="$(adapter_path_in "$box" opencode2)"
out="$(run_install "$box" "$OCI_V1_SHIM" --yes)"; rc=$?
assert_eq "$rc" "0" "opencode 1.18.30, fresh home: exits 0"
assert_eq "$(readlink "$p1" 2>/dev/null)" "$(adapter_target opencode)" \
  "opencode 1.18.30, fresh home: plugin/roost.js points at this checkout"
[ ! -e "$p2" ] && [ ! -L "$p2" ]; assert_true $? \
  "opencode 1.18.30, fresh home: nothing at plugins/roost"
case "$out" in *plugins/roost*) s=mentioned ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 1.18.30, fresh home: plugins/roost is not mentioned"
before="$(tree_of "$box")"
out="$(run_install "$box" "$OCI_V1_SHIM" --yes)"; rc=$?
assert_eq "$(tree_of "$box")" "$before" "opencode 1.18.30, re-run: the sandbox tree is unchanged"
assert_contains "$out" "Already correct: opencode" \
  "opencode 1.18.30, re-run: the Already correct line names opencode"

box="$TMP/oc1-foreign"
p1="$(adapter_path_in "$box" opencode)"
mkdir -p "${p1%/*}"
printf 'export const mine = true; // not roost\n' > "$p1"
fbefore="$(cksum < "$p1")"
out="$(run_install "$box" "$OCI_V1_SHIM" --yes)"; rc=$?
assert_eq "$(cksum < "$p1" 2>/dev/null)" "$fbefore" \
  "opencode 1.18.30, foreign plugin/roost.js: the file is byte-identical after"
assert_contains "$out" "ln -s \"$(adapter_target opencode)\"" \
  "opencode 1.18.30, foreign plugin/roost.js: the manual note still names the 1.x target"

rm -rf "$OCI_V2_SHIM" "$OCI_V1_SHIM"

# ===========================================================================
# 22. Hygiene
# ===========================================================================
[ -x "$INSTALL" ]; assert_true $? "scripts/roost-install is executable"
bash -n "$INSTALL"; assert_true $? "scripts/roost-install parses as bash"
# bash 3.2 is the floor (AGENTS.md / the spec's global constraints): no
# associative arrays, no ${var^^}, no printf '\uXXXX'.
n="$(grep -cE 'declare -A|\$\{[A-Za-z_]+\^\^|printf .*\\u[0-9a-fA-F]{4}' "$INSTALL" || true)"
assert_eq "${n:-0}" "0" "scripts/roost-install uses no bash-4-only construct"

rm -rf "$ALL_SHIM" "$ALL_JSON_SHIM" "$CLAUDE_SHIM" "$CLAUDE_GIT_SHIM" "$CODEX_SHIM" "$COPILOT_SHIM"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
