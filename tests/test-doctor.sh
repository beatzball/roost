#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$HERE/scripts/amux-doctor"

# amux-doctor now reads the saved glyph config, which means it can also
# reach through amux_opt/amux_cfg_tmux to a LIVE server — and with
# AMUX_CONFIG_SOCK unset, that defaults to `-L amux`, the developer's real,
# possibly-live amux server. Pin both to isolated, inert values for every
# invocation in this file, not just the ones that exercise the new check:
# a real ~/.config/amux/amux.conf existing on the machine running this
# suite must never leak in, and this suite must never contact -L amux.
export AMUX_CONFIG_SOCK="/nonexistent/amx-doctor-test-sock"
export XDG_CONFIG_HOME="$(mktemp -d /tmp/amx.XXXX)"
trap 'rm -rf "$XDG_CONFIG_HOME"' EXIT

# reports the running tmux version
out="$("$DOC" 2>&1 || true)"
assert_contains "$out" "tmux" "doctor reports on tmux"

# a faked old tmux makes the required check fail (non-zero exit)
marker="$(mktemp)"
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
ln -s "$HERE/adapters/opencode/amux.js" "$ocdir/opencode/plugin/amux.js"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "opencode plugin linked" "doctor confirms a correctly linked plugin"

# a link pointing at some OTHER amux checkout is worse than none -- it silently
# runs a different version's plugin
rm "$ocdir/opencode/plugin/amux.js"
printf 'not the real plugin\n' > "$ocdir/opencode/plugin/amux.js"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "not this install" "doctor flags a plugin that is not this installation"

# a DANGLING symlink (target moved/deleted) must not read as "not installed":
# -e follows symlinks, so it reports absent, and the printed `ln -s` fix then
# fails with "File exists" because the link itself is still there.
rm "$ocdir/opencode/plugin/amux.js"
ln -s "$ocdir/opencode/plugin/nonexistent-target.js" "$ocdir/opencode/plugin/amux.js"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "dangling" "doctor flags a dangling plugin symlink distinctly"
COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" >/dev/null 2>&1
assert_eq "$?" "0" "a dangling plugin symlink does not fail doctor"

rm -rf "$ocdir" "$shimdir"

# --- amux itself must be on PATH ---
# Adapters (the opencode plugin, and any future one) shell out to `amux
# state ...` by bare name, so a pane goes silently unbadged if amux is not
# reachable that way. Informational only.
noamuxdir="$(mktemp -d /tmp/amx.XXXX)"
cat > "$noamuxdir/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "-V" ] && { echo "tmux 3.4"; exit 0; }
exit 0
EOF
chmod +x "$noamuxdir/tmux"
# A minimal, explicit PATH (not $PATH-prepended): this machine's real PATH
# has a real `amux` on it, and prepending would never exercise the "absent"
# branch. /usr/bin:/bin carries bash/env/grep/sed/etc; $noamuxdir carries
# only the tmux shim, so no amux is reachable.
out="$(PATH="$noamuxdir:/usr/bin:/bin" COLORTERM=truecolor "$DOC" 2>&1)"
assert_contains "$out" "amux not found on PATH" "doctor warns when amux is not on PATH"
PATH="$noamuxdir:/usr/bin:/bin" COLORTERM=truecolor "$DOC" >/dev/null 2>&1
assert_eq "$?" "0" "amux missing from PATH does not fail doctor (informational only)"

printf '#!/bin/sh\nexit 0\n' > "$noamuxdir/amux"; chmod +x "$noamuxdir/amux"
out="$(PATH="$noamuxdir:/usr/bin:/bin" COLORTERM=truecolor "$DOC" 2>&1)"
assert_contains "$out" "amux is on PATH" "doctor confirms amux is on PATH"
rm -rf "$noamuxdir"

# --- an upgraded config predating the error state ---
# A user who picked ascii before this branch has four saved glyph lines and
# no @amux-glyph-error, so they silently inherit the emoji default -- an
# emoji in a bar they deliberately chose not to have emoji in.
gcdir="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$gcdir/amux"
cat > "$gcdir/amux/amux.conf" <<EOF
set -g @amux-glyph-blocked "[!]"
set -g @amux-glyph-working "[~]"
set -g @amux-glyph-done    "[+]"
set -g @amux-glyph-idle    "[·]"
EOF
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$gcdir" "$DOC" 2>&1)"
assert_contains "$out" "predates the error state" "doctor warns when a saved glyph set has no matching error glyph"
COLORTERM=truecolor XDG_CONFIG_HOME="$gcdir" "$DOC" >/dev/null 2>&1
assert_eq "$?" "0" "a mismatched error glyph does not fail doctor (informational only)"

# once @amux-glyph-error is added and matches, the warning goes away
printf 'set -g @amux-glyph-error   "[x]"\n' >> "$gcdir/amux/amux.conf"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$gcdir" "$DOC" 2>&1)"
case "$out" in
  *"predates the error state"*) assert_eq "warned" "silent" "doctor is silent once the error glyph matches its set" ;;
  *) assert_eq ok ok "doctor is silent once the error glyph matches its set" ;;
esac
rm -rf "$gcdir"

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
# is unset -- mirroring the AMUX_CONFIG_SOCK/XDG_CONFIG_HOME hazard noted
# above for amux-doctor. Pin HOME to a fresh temp dir for every case below
# (never the real $HOME), PWD to that same dir where a case needs
# project/local resolution, and both socket variables to inert paths, so this
# suite never reads the real settings.json, the real opencode plugin
# directory, or contacts -L roost.
RDOC="$HERE/scripts/roost-doctor"
export ROOST_CONFIG_SOCK="/nonexistent/roost-doctor-test-sock"
export ROOST_NOTIFY_SOCK="/nonexistent/roost-doctor-test-sock"

# stale: settings.json still names the old amux-agent-state hook command
stalehome="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$stalehome/.claude"
cat > "$stalehome/.claude/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/amux/scripts/amux-agent-state done"}]}]}}
EOF
out="$(HOME="$stalehome" XDG_CONFIG_HOME="$stalehome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
assert_contains "$out" "amux-agent-state" "roost doctor warns when settings.json still references amux-agent-state"
assert_contains "$out" "roost-agent-state" "roost doctor names the roost-agent-state fix"
assert_contains "$out" "user settings" "roost doctor labels which settings file is stale (user)"
HOME="$stalehome" XDG_CONFIG_HOME="$stalehome/.config" COLORTERM=truecolor "$RDOC" >/dev/null 2>&1
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
out="$(HOME="$cleanhome" XDG_CONFIG_HOME="$cleanhome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
case "$out" in
  *"amux-agent-state"*) assert_eq "warned" "silent" "roost doctor is silent once settings.json is migrated, even with 'amux' in the checkout path" ;;
  *) assert_eq ok ok "roost doctor is silent once settings.json is migrated, even with 'amux' in the checkout path" ;;
esac
rm -rf "$cleanhome"

# absent: no settings.json at all -> silent, not a crash
absenthome="$(mktemp -d /tmp/amx.XXXX)"
out="$(HOME="$absenthome" XDG_CONFIG_HOME="$absenthome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
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
  out="$(HOME="$unreadhome" XDG_CONFIG_HOME="$unreadhome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
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
out="$(cd "$projhome" && HOME="$projhome" XDG_CONFIG_HOME="$projhome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
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
out="$(cd "$localhome" && HOME="$localhome" XDG_CONFIG_HOME="$localhome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
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
  out="$(cd "$wtroot/wt" && HOME="$wtroot" XDG_CONFIG_HOME="$wtroot/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
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
out="$(HOME="$ocstale" XDG_CONFIG_HOME="$ocstale/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
assert_contains "$out" "opencode/plugin/amux.js" "roost doctor warns when the old opencode plugin file still exists"
assert_contains "$out" "no longer need the amux half" "roost doctor names the exact fix and frames it as expected noise during coexistence"
assert_contains "$out" "rm \"" "roost doctor prints an exact rm command for the stale plugin file"
assert_contains "$out" "ln -s \"" "roost doctor prints an exact ln -s command naming roost.js, not just 'relink'"

# and once it's gone, silent
rm "$ocstale/.config/opencode/plugin/amux.js"
out="$(HOME="$ocstale" XDG_CONFIG_HOME="$ocstale/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
case "$out" in
  *"opencode/plugin/amux.js"*) assert_eq "warned" "silent" "roost doctor is silent once the old opencode plugin file is gone" ;;
  *) assert_eq ok ok "roost doctor is silent once the old opencode plugin file is gone" ;;
esac
rm -rf "$ocstale"
