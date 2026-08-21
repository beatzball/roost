#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$HERE/scripts/roost-init"

cfgdir="$(mktemp -d /tmp/amx.XXXX)"
export XDG_CONFIG_HOME="$cfgdir"

# scripted answers: notify=n, powerline=triangle, mode=dark, theme=roost, glyph=emoji, hooks=skip
printf 'n\ny\ndark\nroost\nemoji\nskip\n' | ROOST_INIT_ANSWERS=- "$INIT" >/dev/null 2>&1
conf="$cfgdir/roost/roost.conf"

[ -f "$conf" ] && assert_eq ok ok "writes config file" || assert_eq "" exists "writes config file"
assert_contains "$(cat "$conf")" "@roost-notify-backend" "sets notify-backend"
assert_contains "$(cat "$conf")" 'tmux' "notify=n → backend tmux"
assert_contains "$(cat "$conf")" "@roost-color-active-bg" "writes theme colours"
assert_contains "$(cat "$conf")" 'set -g @roost-glyph-error   "💥"' "writes error glyph with the right value"
assert_contains "$(cat "$conf")" 'set -g @roost-glyph-blocked "🛑"' "writes blocked glyph with the right value"
assert_contains "$(cat "$conf")" 'set -g @roost-glyph-working "⏳"' "writes working glyph with the right value"
assert_contains "$(cat "$conf")" 'set -g @roost-glyph-done    "✅"' "writes done glyph with the right value"
assert_contains "$(cat "$conf")" 'set -g @roost-glyph-idle    "💤"' "writes idle glyph with the right value"

# the wedge must be written as real UTF-8 bytes, not a literal \u escape
# (bash 3.2 printf has no \u; a regression would silently corrupt the bar).
sepline="$(grep '@roost-sep-left' "$conf")"
case "$sepline" in
  *'\u'*) assert_eq "literal-escape" "utf8-bytes" "sep-left written as real UTF-8 bytes, not \\u escape" ;;
  *)      assert_eq ok ok "sep-left written as real UTF-8 bytes, not \\u escape" ;;
esac
wedge="$(printf '\xee\x82\xb0')"
grep -q "$wedge" "$conf" && assert_eq ok ok "sep-left contains the actual U+E0B0 wedge byte" \
  || assert_eq "" wedge "sep-left contains the actual U+E0B0 wedge byte"

# nerd glyph set must also write real bytes, not \u escapes
cfg2="$(mktemp -d /tmp/amx.XXXX)"
printf 'n\ny\ndark\nroost\nnerd\nskip\n' | XDG_CONFIG_HOME="$cfg2" ROOST_INIT_ANSWERS=- "$INIT" >/dev/null 2>&1
conf2="$cfg2/roost/roost.conf"
case "$(grep '@roost-glyph-blocked' "$conf2")" in
  *'\u'*) assert_eq "literal-escape" "utf8-bytes" "nerd glyph written as real UTF-8 bytes" ;;
  *)      assert_eq ok ok "nerd glyph written as real UTF-8 bytes" ;;
esac
rm -rf "$cfg2"

# idempotent + backup: second run backs up the first
printf 'n\ny\ndark\nroost\nemoji\nskip\n' | ROOST_INIT_ANSWERS=- "$INIT" >/dev/null 2>&1
ls "$cfgdir/roost/"*.bak >/dev/null 2>&1 && assert_eq ok ok "backs up existing config" \
  || assert_eq "" backup "backs up existing config"

# light/dark mode drives the default theme when no theme name is given.
# (Empty theme answer → mode's default: light picks catppuccin-latte, dark roost.)
cfgL="$(mktemp -d /tmp/amx.XXXX)"
printf 'n\nn\nlight\n\nemoji\nskip\n' | XDG_CONFIG_HOME="$cfgL" ROOST_INIT_ANSWERS=- "$INIT" >/dev/null 2>&1
assert_contains "$(cat "$cfgL/roost/roost.conf")" '@roost-color-bar-bg    "#eff1f5"' "light mode defaults to a light theme (catppuccin-latte)"
rm -rf "$cfgL"

# refuses on non-tty without the answers hook
if [ -t 0 ]; then :; else
  out="$("$INIT" </dev/null 2>&1 || true)"
  assert_contains "$out" "tty" "refuses on non-tty without scripted answers"
fi
rm -rf "$cfgdir"
