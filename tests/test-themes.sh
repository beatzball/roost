#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/roost-themes.sh"

# the three new themes exist and return 6 values each
for t in gruvbox nord rose-pine; do
  n=$(roost_theme "$t" | wc -w | tr -d ' ')
  assert_eq "$n" "6" "theme $t returns 6 colour values"
done
# roster now lists 8 themes and includes the new ones
assert_eq "$(roost_theme_names | wc -l | tr -d ' ')" "8" "roster lists 8 themes"
assert_contains "$(roost_theme_names)" "gruvbox" "roster includes gruvbox"
assert_contains "$(roost_theme_names)" "nord" "roster includes nord"
assert_contains "$(roost_theme_names)" "rose-pine" "roster includes rose-pine"
# unknown theme still fails
roost_theme not-a-theme >/dev/null 2>&1 && assert_eq ok fail "unknown theme returns non-zero" \
  || assert_eq ok ok "unknown theme returns non-zero"

# the contrast validator is the gate: every shipped theme (incl. the 3 new) passes
if command -v python3 >/dev/null 2>&1; then
  python3 "$HERE/tests/test-contrast.py" >/dev/null 2>&1 \
    && assert_eq ok ok "all themes pass the contrast validator" \
    || assert_eq fail ok "all themes pass the contrast validator"
else
  assert_eq ok ok "contrast validator skipped (no python3)"
fi
