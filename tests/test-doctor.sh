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
# roost doctor warns when ~/.claude/settings.json still references the old
# amux-agent-state hook path. This is the ONLY signal the author uses to know
# it is safe to delete the amux compatibility shims later, so it must fire
# reliably on a stale reference and stay silent on an absent or migrated one.
#
# roost-doctor defaults its settings lookup to $HOME/.claude/settings.json and
# its config-socket lookup to `-L roost` (a real, possibly-live named server
# on this machine) when ROOST_CONFIG_SOCK is unset -- mirroring the
# AMUX_CONFIG_SOCK/XDG_CONFIG_HOME hazard noted above for amux-doctor. Pin
# HOME to a fresh temp dir for every case below (never the real $HOME) and
# ROOST_CONFIG_SOCK to an inert path, so this suite never reads the real
# settings.json and never contacts -L roost.
RDOC="$HERE/scripts/roost-doctor"
export ROOST_CONFIG_SOCK="/nonexistent/roost-doctor-test-sock"

# stale: settings.json still names the old amux-agent-state hook command
stalehome="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$stalehome/.claude"
cat > "$stalehome/.claude/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/amux/scripts/amux-agent-state done"}]}]}}
EOF
out="$(HOME="$stalehome" XDG_CONFIG_HOME="$stalehome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
assert_contains "$out" "amux-agent-state" "roost doctor warns when settings.json still references amux-agent-state"
assert_contains "$out" "roost-agent-state" "roost doctor names the roost-agent-state fix"
HOME="$stalehome" XDG_CONFIG_HOME="$stalehome/.config" COLORTERM=truecolor "$RDOC" >/dev/null 2>&1
assert_eq "$?" "0" "a stale hook reference does not fail doctor (warning only)"
rm -rf "$stalehome"

# clean: settings.json present and already migrated -> silent
cleanhome="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$cleanhome/.claude"
cat > "$cleanhome/.claude/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/path/to/roost/scripts/roost-agent-state done"}]}]}}
EOF
out="$(HOME="$cleanhome" XDG_CONFIG_HOME="$cleanhome/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
case "$out" in
  *"amux-agent-state"*) assert_eq "warned" "silent" "roost doctor is silent once settings.json is migrated" ;;
  *) assert_eq ok ok "roost doctor is silent once settings.json is migrated" ;;
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

# --- roost doctor: stale opencode plugin file (amux.js) still present ---
# Same Phase 5 trigger, for the other artifact a stale install can leave
# behind: an opencode plugin directory still holding the OLD amux.js after
# the user meant to move to roost.js.
ocstale="$(mktemp -d /tmp/amx.XXXX)"
mkdir -p "$ocstale/.config/opencode/plugin"
printf 'not the real plugin\n' > "$ocstale/.config/opencode/plugin/amux.js"
out="$(HOME="$ocstale" XDG_CONFIG_HOME="$ocstale/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
assert_contains "$out" "opencode/plugin/amux.js" "roost doctor warns when the old opencode plugin file still exists"

# and once it's gone, silent
rm "$ocstale/.config/opencode/plugin/amux.js"
out="$(HOME="$ocstale" XDG_CONFIG_HOME="$ocstale/.config" COLORTERM=truecolor "$RDOC" 2>&1)"
case "$out" in
  *"opencode/plugin/amux.js"*) assert_eq "warned" "silent" "roost doctor is silent once the old opencode plugin file is gone" ;;
  *) assert_eq ok ok "roost doctor is silent once the old opencode plugin file is gone" ;;
esac
rm -rf "$ocstale"
