#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"
# Unset the global @agent_glyph so window-specific states work properly
T set-option -gu @agent_glyph

# prefix a target script exists and is executable
[ -x "$HERE/scripts/amux-switch" ] && assert_eq ok ok "amux-switch is executable" \
  || assert_eq "" exec "amux-switch is executable"

# rollup: one window each of blocked / working / idle, driven against the TEST
# server via AMUX_STATUS_SOCK. Use window IDs (not indices) so base-index timing
# is irrelevant. The third window keeps the global default state (idle).
w0="$(T display -p '#{window_id}')"
w1="$(T new-window -PF '#{window_id}')"
T new-window
T set-option -w -t "$w0" @agent_state blocked
T set-option -w -t "$w1" @agent_state working
out="$(AMUX_STATUS_SOCK="$AMUX_TEST_SOCK" "$HERE/scripts/amux-status" 2>/dev/null || true)"
assert_contains "$out" "🛑 1" "rollup shows one blocked (🛑 1)"
assert_contains "$out" "⏳ 1" "rollup shows one working (⏳ 1)"
assert_contains "$out" "💤 1" "rollup shows one idle (💤 1)"
# emoji self-colour: the rollup must emit NO raw #[fg=...] colour codes
case "$out" in *'#[fg='*) assert_eq "has-codes" "none" "rollup emits no raw colour codes" ;;
  *) assert_eq ok ok "rollup emits no raw colour codes" ;; esac
