#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$HERE/scripts/amux-init"

cfgdir="$(mktemp -d /tmp/amx.XXXX)"
export XDG_CONFIG_HOME="$cfgdir"

# scripted answers: notify=n, powerline=triangle, mode=dark, theme=amux, glyph=emoji, hooks=skip
printf 'n\ny\ndark\namux\nemoji\nskip\n' | AMUX_INIT_ANSWERS=- "$INIT" >/dev/null 2>&1
conf="$cfgdir/amux/amux.conf"

[ -f "$conf" ] && assert_eq ok ok "writes config file" || assert_eq "" exists "writes config file"
assert_contains "$(cat "$conf")" "@amux-notify-backend" "sets notify-backend"
assert_contains "$(cat "$conf")" 'tmux' "notify=n → backend tmux"
assert_contains "$(cat "$conf")" "@amux-color-active-bg" "writes theme colours"
assert_contains "$(cat "$conf")" "@amux-glyph-blocked" "writes glyph set"

# idempotent + backup: second run backs up the first
printf 'n\ny\ndark\namux\nemoji\nskip\n' | AMUX_INIT_ANSWERS=- "$INIT" >/dev/null 2>&1
ls "$cfgdir/amux/"*.bak >/dev/null 2>&1 && assert_eq ok ok "backs up existing config" \
  || assert_eq "" backup "backs up existing config"

# refuses on non-tty without the answers hook
if [ -t 0 ]; then :; else
  out="$("$INIT" </dev/null 2>&1 || true)"
  assert_contains "$out" "tty" "refuses on non-tty without scripted answers"
fi
rm -rf "$cfgdir"
