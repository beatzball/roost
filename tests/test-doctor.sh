#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$HERE/scripts/roost-doctor"

# roost-doctor now reads the saved glyph config, which means it can also
# reach through roost_opt/roost_cfg_tmux to a LIVE server — and with
# ROOST_CONFIG_SOCK unset, that defaults to `-L roost`, the developer's real,
# possibly-live roost server. It also shells out to roost-notify --which for
# the notify-backend line, which falls back through $TMUX and then to that
# same `-L roost` when ROOST_NOTIFY_SOCK is unset. Pin all three to isolated,
# inert values for every invocation in this file, not just the ones that
# exercise the new check: a real ~/.config/roost/roost.conf existing on the
# machine running this suite must never leak in, and this suite must never
# contact -L roost.
export ROOST_CONFIG_SOCK="/nonexistent/roost-doctor-test-sock"
export ROOST_NOTIFY_SOCK="/nonexistent/roost-doctor-test-sock"
export XDG_CONFIG_HOME="$(mktemp -d /tmp/amx.XXXX)"
trap 'rm -rf "$XDG_CONFIG_HOME"' EXIT

# $CLAUDE_SETTINGS names the FILE doctor reports on, and doctor honours it via
# scripts/lib/roost-adapters.sh -- so a runner that exports it redirects every
# case in this file at one stroke. Measured: with it set, the four stale-hook
# assertions below (which seed $HOME/.claude/settings.json and expect doctor to
# read that) fail, because doctor was reading somebody else's file the whole
# time. Same omission as the one AGENTS.md §8 describes for install.sh, and
# harmless only because doctor reads and never writes.
#
# So: pinned inert here for the few cases that pin no HOME of their own, and
# set explicitly beside HOME in every case where that file IS the thing under
# test. The one case that deliberately points it somewhere else sets it itself.
export CLAUDE_SETTINGS="$XDG_CONFIG_HOME/no-such-claude-home/settings.json"

# reports the running tmux version
out="$("$DOC" 2>&1 || true)"
assert_contains "$out" "tmux" "doctor reports on tmux"

# a faked old tmux makes the required check fail (non-zero exit)
shimdir="$(mktemp -d /tmp/amx.XXXX)"
cat > "$shimdir/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "-V" ] && { echo "tmux 3.1c"; exit 0; }
exit 0
EOF
chmod +x "$shimdir/tmux"
PATH="$shimdir:$PATH" "$DOC" >/dev/null 2>&1
assert_eq "$?" "1" "doctor exits non-zero on tmux < 3.2"
rm -rf "$shimdir"

# a faked new tmux passes the version gate
shimdir="$(mktemp -d /tmp/amx.XXXX)"
cat > "$shimdir/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "-V" ] && { echo "tmux 3.4"; exit 0; }
exit 0
EOF
chmod +x "$shimdir/tmux"
out="$(COLORTERM=truecolor PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "3.4" "doctor accepts tmux 3.4"
rm -rf "$shimdir"

# --- the opencode adapter check ---
# Informational only: most users will not have opencode, and its absence must
# never fail the required-check exit code.
ocdir="$(mktemp -d /tmp/amx.XXXX)"
shimdir="$(mktemp -d /tmp/amx.XXXX)"
printf '#!/bin/sh\nexit 0\n' > "$shimdir/opencode"; chmod +x "$shimdir/opencode"

# opencode present, plugin not linked -> a warning naming the fix
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "opencode" "doctor mentions opencode when it is installed"
assert_contains "$out" "ln -s" "doctor prints the command that links the plugin"

# ...and it is still only a warning
COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" >/dev/null 2>&1
assert_eq "$?" "0" "a missing opencode plugin does not fail doctor"

# plugin linked -> reported as linked, with no install command
mkdir -p "$ocdir/opencode/plugin"
ln -s "$HERE/adapters/opencode/roost.js" "$ocdir/opencode/plugin/roost.js"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "opencode plugin linked" "doctor confirms a correctly linked plugin"

# a link pointing at some OTHER roost checkout is worse than none -- it silently
# runs a different version's plugin
rm "$ocdir/opencode/plugin/roost.js"
printf 'not the real plugin\n' > "$ocdir/opencode/plugin/roost.js"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "not this install" "doctor flags a plugin that is not this installation"

# a DANGLING symlink (target moved/deleted) must not read as "not installed":
# -e follows symlinks, so it reports absent, and the printed `ln -s` fix then
# fails with "File exists" because the link itself is still there.
rm "$ocdir/opencode/plugin/roost.js"
ln -s "$ocdir/opencode/plugin/nonexistent-target.js" "$ocdir/opencode/plugin/roost.js"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "dangling" "doctor flags a dangling plugin symlink distinctly"
COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" >/dev/null 2>&1
assert_eq "$?" "0" "a dangling plugin symlink does not fail doctor"

rm -rf "$ocdir" "$shimdir"

# --- roost itself must be on PATH ---
# Adapters (the opencode plugin, and any future one) shell out to `roost
# state ...` by bare name, so a pane goes silently unbadged if roost is not
# reachable that way. Informational only.
noroostdir="$(mktemp -d /tmp/amx.XXXX)"
cat > "$noroostdir/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "-V" ] && { echo "tmux 3.4"; exit 0; }
exit 0
EOF
chmod +x "$noroostdir/tmux"
# A minimal, explicit PATH (not $PATH-prepended): this machine's real PATH
# has a real `roost` on it, and prepending would never exercise the "absent"
# branch. /usr/bin:/bin carries bash/env/grep/sed/etc; $noroostdir carries
# only the tmux shim, so no roost is reachable.
out="$(PATH="$noroostdir:/usr/bin:/bin" COLORTERM=truecolor "$DOC" 2>&1)"
assert_contains "$out" "roost not found on PATH" "doctor warns when roost is not on PATH"
PATH="$noroostdir:/usr/bin:/bin" COLORTERM=truecolor "$DOC" >/dev/null 2>&1
assert_eq "$?" "0" "roost missing from PATH does not fail doctor (informational only)"

printf '#!/bin/sh\nexit 0\n' > "$noroostdir/roost"; chmod +x "$noroostdir/roost"
out="$(PATH="$noroostdir:/usr/bin:/bin" COLORTERM=truecolor "$DOC" 2>&1)"
assert_contains "$out" "roost is on PATH" "doctor confirms roost is on PATH"
rm -rf "$noroostdir"

# --- the saved error glyph does not match the saved glyph set ---
# Two different situations reach this check and they need two different
# messages, because the single old message ("your saved set predates the error
# state") asserted a cause that is simply false for the second:
#
#   1. No @roost-glyph-error LINE at all. The config was written before the
#      `error` state existed, so the bar falls back to tmux/roost.conf's
#      global 💥 -- an emoji in a bar the user chose not to have emoji in.
#   2. An @roost-glyph-error line holding a value the set does not use. The
#      user set a custom error glyph on purpose; nothing is wrong.
#
# So each case below asserts the message names what was OBSERVED -- and
# asserts the actual glyph VALUES it printed, not just that a warning fired.
# The process lesson in docs/known-gaps.md is that the init test asserted an
# option NAME only, so a bug that shifted every glyph by one position passed
# throughout; a message naming the wrong set's glyph would do the same here.
#
# HOME is pinned to a throwaway dir for every invocation, alongside the
# XDG_CONFIG_HOME each case sets: doctor reads $HOME/.claude/settings.json,
# and this suite must never touch the real one.
gchome="$(mktemp -d /tmp/amx.XXXX)"
gcdir="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$gcdir/roost"
cat > "$gcdir/roost/roost.conf" <<EOF
set -g @roost-glyph-blocked "[!]"
set -g @roost-glyph-working "[~]"
set -g @roost-glyph-done    "[+]"
set -g @roost-glyph-idle    "[·]"
EOF
out="$(HOME="$gchome" CLAUDE_SETTINGS="$gchome/.claude/settings.json" COLORTERM=truecolor XDG_CONFIG_HOME="$gcdir" "$DOC" 2>&1)"
assert_contains "$out" "has no @roost-glyph-error line" "doctor reports the missing line as missing, rather than asserting a cause"
assert_contains "$out" "'ascii'" "doctor names the set it actually matched (ascii)"
assert_contains "$out" "falls back to the built-in '💥'" "doctor names the exact glyph being inherited, not just 'the default'"
HOME="$gchome" CLAUDE_SETTINGS="$gchome/.claude/settings.json" COLORTERM=truecolor XDG_CONFIG_HOME="$gcdir" "$DOC" >/dev/null 2>&1
assert_eq "$?" "0" "a missing error glyph does not fail doctor (informational only)"

# once @roost-glyph-error is added and matches, the warning goes away
printf 'set -g @roost-glyph-error   "[x]"\n' >> "$gcdir/roost/roost.conf"
out="$(HOME="$gchome" CLAUDE_SETTINGS="$gchome/.claude/settings.json" COLORTERM=truecolor XDG_CONFIG_HOME="$gcdir" "$DOC" 2>&1)"
case "$out" in
  *"@roost-glyph-error"*) assert_eq "warned" "silent" "doctor is silent once the error glyph matches its set" ;;
  *) assert_eq ok ok "doctor is silent once the error glyph matches its set" ;;
esac
rm -rf "$gcdir"

# Case 2: a deliberate custom error glyph on an otherwise-standard set. The
# old message told this user their config "predates the error state", which is
# false -- they wrote that line themselves. The new one states both values and
# leaves the cause to the person who knows it.
cudir="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$cudir/roost"
cat > "$cudir/roost/roost.conf" <<EOF
set -g @roost-glyph-error   "(X)"
set -g @roost-glyph-blocked "[!]"
set -g @roost-glyph-working "[~]"
set -g @roost-glyph-done    "[+]"
set -g @roost-glyph-idle    "[·]"
EOF
out="$(HOME="$gchome" CLAUDE_SETTINGS="$gchome/.claude/settings.json" COLORTERM=truecolor XDG_CONFIG_HOME="$cudir" "$DOC" 2>&1)"
assert_contains "$out" "sets @roost-glyph-error to '(X)'" "doctor quotes the custom error glyph the config actually holds"
assert_contains "$out" "the 'ascii' set's own error glyph is '[x]'" "doctor quotes the set's own error glyph for comparison"
assert_contains "$out" "if you chose that yourself there is nothing to fix" "doctor offers the deliberate-choice reading instead of asserting a cause"
case "$out" in
  *"has no @roost-glyph-error line"*) assert_eq "claimed-missing" "described-mismatch" "doctor does not tell a user with a custom error glyph that the line is missing" ;;
  *) assert_eq ok ok "doctor does not tell a user with a custom error glyph that the line is missing" ;;
esac
HOME="$gchome" CLAUDE_SETTINGS="$gchome/.claude/settings.json" COLORTERM=truecolor XDG_CONFIG_HOME="$cudir" "$DOC" >/dev/null 2>&1
assert_eq "$?" "0" "a custom error glyph does not fail doctor (informational only)"
rm -rf "$cudir" "$gchome"

# === roost doctor: stale-hook check (Phase 5 trigger) ===
# roost doctor warns when a settings file still references the old
# amux-agent-state hook path. This is the ONLY signal the author uses to know
# it is safe to delete the amux compatibility shims later, so it must fire
# reliably on a stale reference and stay silent on an absent or migrated one.
# A false negative here is the expensive direction (it green-lights deleting
# a live shim), so these cases lean toward over-covering rather than under.
#
# Claude Code merges hooks from three files, not just $HOME/.claude/settings.json
# (https://code.claude.com/docs/en/settings): user (~/.claude/settings.json),
# project (.claude/settings.json, read from the directory the session runs
# in), and local (.claude/settings.local.json, read from the git repository
# root and resolved through worktrees to the MAIN checkout). roost-doctor's
# stale-hook check now covers all three, so the cases below do too.
#
# roost-doctor's config-socket lookup falls back to `-L roost` (a real,
# possibly-live named server on this machine) when ROOST_CONFIG_SOCK is
# unset, and its notify-backend line (scripts/roost-notify --which) falls
# back through $TMUX and then to that same `-L roost` when ROOST_NOTIFY_SOCK
# is unset -- the same hazard already pinned above, at the top of this file.
# Pin HOME to a fresh temp dir for every case below (never the real $HOME),
# PWD to that same dir where a case needs project/local resolution, and reuse
# $DOC (both socket variables are already inert, set at the top), so this
# suite never reads the real settings.json, the real opencode plugin
# directory, or contacts -L roost.
RDOC="$DOC"

# stale: settings.json still names the old amux-agent-state hook command
stalehome="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$stalehome/.claude"
cat > "$stalehome/.claude/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/amux/scripts/amux-agent-state done"}]}]}}
EOF
out="$(HOME="$stalehome" CLAUDE_SETTINGS="$stalehome/.claude/settings.json" XDG_CONFIG_HOME="$stalehome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
assert_contains "$out" "amux-agent-state" "roost doctor warns when settings.json still references amux-agent-state"
assert_contains "$out" "roost-agent-state" "roost doctor names the roost-agent-state fix"
assert_contains "$out" "user settings" "roost doctor labels which settings file is stale (user)"
HOME="$stalehome" CLAUDE_SETTINGS="$stalehome/.claude/settings.json" XDG_CONFIG_HOME="$stalehome/.config" COLORTERM=truecolor "$RDOC" >/dev/null 2>&1
assert_eq "$?" "0" "a stale hook reference does not fail doctor (warning only)"
rm -rf "$stalehome"

# clean: settings.json present and already migrated -> silent.
# The command path deliberately still contains the substring "amux" (the
# checkout directory itself is named amux) even though the HOOK COMMAND is
# roost-agent-state -- pinning that a sloppy `grep -q amux` implementation
# (which would match on the directory name alone) fails this case, where the
# correct `grep -q amux-agent-state` stays silent.
cleanhome="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$cleanhome/.claude"
cat > "$cleanhome/.claude/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/amux/scripts/roost-agent-state done"}]}]}}
EOF
out="$(HOME="$cleanhome" CLAUDE_SETTINGS="$cleanhome/.claude/settings.json" XDG_CONFIG_HOME="$cleanhome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
case "$out" in
  *"amux-agent-state"*) assert_eq "warned" "silent" "roost doctor is silent once settings.json is migrated, even with 'amux' in the checkout path" ;;
  *) assert_eq ok ok "roost doctor is silent once settings.json is migrated, even with 'amux' in the checkout path" ;;
esac
rm -rf "$cleanhome"

# absent: no settings.json at all -> silent, not a crash
absenthome="$(mktemp -d /tmp/amx.XXXX)"
out="$(HOME="$absenthome" CLAUDE_SETTINGS="$absenthome/.claude/settings.json" XDG_CONFIG_HOME="$absenthome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
case "$out" in
  *"amux-agent-state"*) assert_eq "warned" "silent" "roost doctor is silent when settings.json is absent" ;;
  *) assert_eq ok ok "roost doctor is silent when settings.json is absent" ;;
esac
rm -rf "$absenthome"

# unreadable: a permission error must not read as "absent" (grep -q exits 2
# with stderr already discarded, so a naive check would silently miss a
# stale hook it could not even open -- the exact false negative this whole
# check exists to avoid). Skipped as root, which can read mode 000 files it
# owns and so cannot exercise this branch.
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP: unreadable-settings.json case skipped when running as root"
else
  unreadhome="$(mktemp -d /tmp/amx.XXXX)"
  mkdir -p "$unreadhome/.claude"
  printf '{"hooks":{}}' > "$unreadhome/.claude/settings.json"
  chmod 000 "$unreadhome/.claude/settings.json"
  out="$(HOME="$unreadhome" CLAUDE_SETTINGS="$unreadhome/.claude/settings.json" XDG_CONFIG_HOME="$unreadhome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
  # The specific phrase from the STALE-hook check's own unreadable branch,
  # not just "not readable" generically -- the pre-existing "Claude hooks
  # wired" check also says "not readable" for the same file, so a looser
  # assertion here would pass even if only THAT check were fixed and the new
  # stale-hook check still silently swallowed the permission error.
  assert_contains "$out" "could not check it for a stale amux-agent-state hook" "roost doctor's stale-hook check distinguishes an unreadable settings.json from an absent one"
  chmod 600 "$unreadhome/.claude/settings.json"
  rm -rf "$unreadhome"
fi

# --- roost doctor: project settings (.claude/settings.json, cwd-relative) ---
# Claude Code reads project settings from the directory the session runs in,
# not from $HOME, so this check must too -- a hook only ever set in the
# project's checked-in .claude/settings.json is otherwise invisible to it.
projhome="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$projhome/.claude"
cat > "$projhome/.claude/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/amux/scripts/amux-agent-state done"}]}]}}
EOF
out="$(cd "$projhome" && HOME="$projhome" CLAUDE_SETTINGS="$projhome/.claude/settings.json" XDG_CONFIG_HOME="$projhome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
assert_contains "$out" "project settings" "roost doctor warns on a stale project .claude/settings.json (cwd-relative, not just \$HOME)"
rm -rf "$projhome"

# --- roost doctor: local settings (.claude/settings.local.json) ---
# Outside a git repository, Claude Code resolves the local file to the
# starting directory too (same as project settings above).
localhome="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$localhome/.claude"
cat > "$localhome/.claude/settings.local.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/amux/scripts/amux-agent-state done"}]}]}}
EOF
out="$(cd "$localhome" && HOME="$localhome" CLAUDE_SETTINGS="$localhome/.claude/settings.json" XDG_CONFIG_HOME="$localhome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
assert_contains "$out" "local settings" "roost doctor warns on a stale local .claude/settings.local.json"
rm -rf "$localhome"

# --- roost doctor: local settings resolve through a worktree to the MAIN checkout ---
# The subtlest part of the merge rule: inside a git repository,
# .claude/settings.local.json lives at the git root and, for a linked
# worktree, resolves to the MAIN checkout's copy -- not a (nonexistent) copy
# inside the worktree itself. A session started in a worktree must still see
# the one real file. This repo is entirely fake and thrown away (git init in
# a temp dir), never the real checkout this suite runs from.
if command -v git >/dev/null 2>&1; then
  wtroot="$(mktemp -d /tmp/amx.XXXX)"
  git -C "$wtroot" init -q -b main main >/dev/null 2>&1
  ( cd "$wtroot/main" && git -c user.email=t@t.example -c user.name=t commit -q --allow-empty -m init )
  mkdir -p "$wtroot/main/.claude"
  cat > "$wtroot/main/.claude/settings.local.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/amux/scripts/amux-agent-state done"}]}]}}
EOF
  git -C "$wtroot/main" worktree add -q "$wtroot/wt" -b wtbranch >/dev/null 2>&1
  out="$(cd "$wtroot/wt" && HOME="$wtroot" CLAUDE_SETTINGS="$wtroot/.claude/settings.json" XDG_CONFIG_HOME="$wtroot/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
  assert_contains "$out" "local settings" "roost doctor resolves local settings through a worktree to the main checkout"
  rm -rf "$wtroot"
else
  echo "  SKIP: worktree local-settings resolution case skipped — git not found"
fi

# --- roost doctor: stale opencode plugin file (amux.js) still present ---
# Same Phase 5 trigger, for the other artifact a stale install can leave
# behind: an opencode plugin directory still holding the OLD amux.js after
# the user meant to move to roost.js.
ocstale="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$ocstale/.config/opencode/plugin"
printf 'not the real plugin\n' > "$ocstale/.config/opencode/plugin/amux.js"
out="$(HOME="$ocstale" CLAUDE_SETTINGS="$ocstale/.claude/settings.json" XDG_CONFIG_HOME="$ocstale/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
assert_contains "$out" "opencode/plugin/amux.js" "roost doctor warns when the old opencode plugin file still exists"
assert_contains "$out" "no reason to keep the old name around" "roost doctor names the exact fix and frames it as a harmless leftover, not a coexistence need"
assert_contains "$out" "rm \"" "roost doctor prints an exact rm command for the stale plugin file"
assert_contains "$out" "ln -s \"" "roost doctor prints an exact ln -s command naming roost.js, not just 'relink'"

# and once it's gone, silent
rm "$ocstale/.config/opencode/plugin/amux.js"
out="$(HOME="$ocstale" CLAUDE_SETTINGS="$ocstale/.claude/settings.json" XDG_CONFIG_HOME="$ocstale/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
case "$out" in
  *"opencode/plugin/amux.js"*) assert_eq "warned" "silent" "roost doctor is silent once the old opencode plugin file is gone" ;;
  *) assert_eq ok ok "roost doctor is silent once the old opencode plugin file is gone" ;;
esac
rm -rf "$ocstale"

# --- roost doctor: the codex adapter, and its consent gate ---
#
# The codex check does one thing the opencode and copilot checks do not: it
# reads the TRUST entries out of config.toml, because codex skips an untrusted
# hook in total silence and nothing else on the machine will ever say so (spec
# §5 T6). "Installed" and "will run" are different claims, so both are asserted
# here, separately.
#
# A fake `codex` on PATH, because the checks are gated on the binary existing
# and most machines running this suite will not have it — the same shape as the
# faked-tmux cases at the top of this file.
cxshim="$(mktemp -d /tmp/amx.XXXX)"
printf '#!/bin/sh\nexit 0\n' > "$cxshim/codex"
chmod +x "$cxshim/codex"
cxhome="$(mktemp -d /tmp/amx.XXXX)"
HOOK="$HERE/adapters/codex/roost-codex-hook"
rdoctor() { PATH="$cxshim:$PATH" CODEX_HOME="$cxhome" COLORTERM=truecolor "$RDOC" 2>&1; }

# 1. codex present, nothing written
out="$(rdoctor)"
assert_contains "$out" "roost hooks codex" "doctor names the exact command when codex hooks are not written"

# 2. a hooks.json that wires some other tool
printf '{"hooks":{}}\n' > "$cxhome/hooks.json"
out="$(rdoctor)"
assert_contains "$out" "does not reference roost-codex-hook" "doctor spots a hooks.json that is not roost's"

# 3. a hooks.json wiring a DIFFERENT checkout's shim. This is the codex
# equivalent of the opencode "not this install" case, and it matters more here:
# the trust entry is keyed by the hooks.json path, so a stale checkout path
# fails at the exec rather than at the trust prompt.
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/somewhere/else/adapters/codex/roost-codex-hook Stop","timeout":10}]}]}}\n' > "$cxhome/hooks.json"
out="$(rdoctor)"
assert_contains "$out" "different checkout" "doctor spots a roost-codex-hook from another checkout"

# 4. wired to THIS checkout, but never trusted — the silent-failure case
"$HERE/bin/roost" hooks codex | sed -n '/^{/,$p' > "$cxhome/hooks.json"
out="$(rdoctor)"
assert_contains "$out" "codex hooks wired in" "doctor confirms roost's own hooks.json"
assert_contains "$out" "trusted NONE" "doctor reports untrusted hooks rather than inferring consent from the file"
assert_contains "$out" "Trust all and continue" "doctor prints the exact answer the user has to give"

# 5. partially trusted. Real trust entries are keyed
# "<hooks.json path>:<snake_case event>:<group>:<handler>" — captured live from
# codex-cli 0.151.0's config.toml.
{
  printf '[hooks.state."%s:stop:0:0"]\n' "$cxhome/hooks.json"
  printf 'trusted_hash = "sha256:0000"\n'
} > "$cxhome/config.toml"
out="$(rdoctor)"
assert_contains "$out" "only 1 of the four" "doctor counts partially-granted trust instead of calling it done"

# 6. fully trusted
{
  for ev in user_prompt_submit post_tool_use permission_request stop; do
    printf '[hooks.state."%s:%s:0:0"]\n' "$cxhome/hooks.json" "$ev"
    printf 'trusted_hash = "sha256:0000"\n'
  done
} > "$cxhome/config.toml"
out="$(rdoctor)"
assert_contains "$out" "trusted all four" "doctor confirms a fully trusted codex install"

# ...and none of it is ever a hard failure: most users do not have codex, and a
# missing adapter for a harness you do not run is not a broken roost.
PATH="$cxshim:$PATH" CODEX_HOME="$cxhome" COLORTERM=truecolor "$RDOC" >/dev/null 2>&1
assert_eq "$?" "0" "the codex checks never fail doctor"

rm -rf "$cxshim" "$cxhome"

# === roost doctor: the adapter advice points at `roost install` ===
# `roost install` performs all five of these fixes in one go, so every warn
# that hands the user a command to paste now names it too.
#
# The paste-command STAYS. The installer cannot run everywhere doctor can:
# the two hook files need python3 or jq to edit, a foreign file at an adapter
# path is left alone rather than replaced, and a read-only home cannot be
# written at all. On any of those machines the pasted command is the only fix
# there is, so the tail is an addition to it and never a replacement -- both
# halves are asserted below, on the same line, for that reason.

# doc_line NEEDLE REPORT -> the first line of REPORT containing NEEDLE, or the
# empty string.
#
# Every assertion in this section is pinned to ONE line through this rather
# than run against the whole report, because "roost install" now appears in
# five separate lines: a whole-output assert_contains would go green on any of
# them, including with the line it names deleted. That exact false pass has
# already happened twice in this plan.
#
# bash's own parameter expansion and `read`, with no `tr` and no `cut`: the
# thin PATHs this file builds elsewhere carry neither, and a silently absent
# `tr` in a pipeline is a no-op that makes the filter match everything.
doc_line() {
  local needle="$1" hay="$2" line found=""
  while IFS= read -r line; do
    case "$line" in
      *"$needle"*) [ -z "$found" ] && found="$line" ;;
    esac
  done <<EOF
$hay
EOF
  printf '%s' "$found"
}

# All four optional harnesses faked onto PATH at once, each pointed at an
# empty home of its own, so one run produces all five "not installed" lines --
# the claude one comes for free, since an empty HOME has no settings.json.
insthome="$(mktemp -d /tmp/amx.XXXX)"
instshim="$(mktemp -d /tmp/amx.XXXX)"
for _h in opencode copilot pi codex; do
  printf '#!/bin/sh\nexit 0\n' > "$instshim/$_h"; chmod +x "$instshim/$_h"
done
out="$(HOME="$insthome" CLAUDE_SETTINGS="$insthome/.claude/settings.json" XDG_CONFIG_HOME="$insthome/.config" \
  COPILOT_HOME="$insthome/.copilot" PI_CODING_AGENT_DIR="$insthome/.pi/agent" \
  CODEX_HOME="$insthome/.codex" COLORTERM=truecolor \
  PATH="$instshim:$PATH" "$RDOC" 2>&1)"

l="$(doc_line "opencode found, roost plugin not installed" "$out")"
assert_contains "$l" "ln -s " "doctor still prints the opencode symlink command"
assert_contains "$l" "or run: roost install" "the opencode not-installed line also points at roost install"

l="$(doc_line "copilot found, roost extension not installed" "$out")"
assert_contains "$l" "ln -s " "doctor still prints the copilot symlink command"
assert_contains "$l" "or run: roost install" "the copilot not-installed line also points at roost install"

l="$(doc_line "pi found, roost extension not installed" "$out")"
assert_contains "$l" "ln -s " "doctor still prints the pi symlink command"
assert_contains "$l" "or run: roost install" "the pi not-installed line also points at roost install"

l="$(doc_line "codex found, roost hooks not written" "$out")"
assert_contains "$l" "run: roost hooks codex," "doctor still prints the codex hooks command"
assert_contains "$l" "or run: roost install" "the codex hooks line also points at roost install"

l="$(doc_line "Claude hooks not found in" "$out")"
assert_contains "$l" "run: roost hooks," "doctor still prints the claude hooks command"
assert_contains "$l" "or run: roost install" "the claude hooks line also points at roost install"

# and none of this is a failure: advice is advice
HOME="$insthome" CLAUDE_SETTINGS="$insthome/.claude/settings.json" XDG_CONFIG_HOME="$insthome/.config" \
  COPILOT_HOME="$insthome/.copilot" PI_CODING_AGENT_DIR="$insthome/.pi/agent" \
  CODEX_HOME="$insthome/.codex" COLORTERM=truecolor \
  PATH="$instshim:$PATH" "$RDOC" >/dev/null 2>&1
assert_eq "$?" "0" "the adapter advice never fails doctor"
rm -rf "$insthome" "$instshim"

# === roost doctor honours $CLAUDE_SETTINGS ===
# doctor takes this path from roost_adapter_settings (scripts/lib/roost-adapters.sh)
# rather than spelling ${CLAUDE_SETTINGS:-...} out itself, so doctor's report
# and roost install's write can never disagree about which file they mean --
# the divergence that file's header exists to prevent. Nothing covered the
# override before this: every case above exercises the default.
cshome="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$cshome/.claude" "$cshome/elsewhere"
# The DEFAULT location is deliberately populated, and with a STALE hook, so
# that an implementation which ignored $CLAUDE_SETTINGS would not merely look
# similar -- it would name this path and warn about amux-agent-state, and both
# assertions below would catch it.
cat > "$cshome/.claude/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/amux/scripts/amux-agent-state done"}]}]}}
EOF
cat > "$cshome/elsewhere/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/roost/scripts/roost-agent-state done --stop-hook"}]}]}}
EOF
out="$(HOME="$cshome" XDG_CONFIG_HOME="$cshome/.config" \
  CLAUDE_SETTINGS="$cshome/elsewhere/settings.json" COLORTERM=truecolor "$RDOC" 2>&1)"
assert_contains "$out" "Claude hooks wired in $cshome/elsewhere/settings.json" \
  "doctor checks the file \$CLAUDE_SETTINGS names, not \$HOME/.claude/settings.json"
case "$out" in *"$cshome/.claude/settings.json"*) csleak=1 ;; *) csleak=0 ;; esac
[ "$csleak" -eq 0 ]
assert_true $? "doctor never reads \$HOME/.claude/settings.json when \$CLAUDE_SETTINGS names another file"
rm -rf "$cshome"
