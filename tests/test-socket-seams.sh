#!/usr/bin/env bash
# Every amux script has to pick WHICH tmux server to talk to. Getting that wrong
# is the sharpest edge in the codebase: the production default is the shared
# server by name (-L amux), so a script invoked without its test seam silently
# addresses the developer's real session — reading their agents, or worse,
# writing to them.
#
# The scripts that only ever run from inside an amux server resolve in three
# steps: explicit seam -> the server we are running inside ($TMUX) -> -L amux.
# These tests pin the MIDDLE step, which is the one that keeps an invocation
# without the seam on the right server. They deliberately never set the seam.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT

# $TMUX is "<socket-path>,<pid>,<session>" — scripts read the first field.
FAKE_TMUX="$sock,0,0"

# Distinctive glyphs, so a passing assertion cannot be a coincidental match
# against whatever the developer's live server happens to be reporting.
T set-option -g @amux-glyph-blocked "SEAMBLOCK"
T set-option -g @amux-glyph-idle    "SEAMIDLE"

pane="$(T display-message -p '#{pane_id}')"
T set-option -p -t "$pane" @agent_state blocked

# --- amux-status: reads. Wrong server => reports someone else's agents. ---
out="$(env -u AMUX_STATUS_SOCK TMUX="$FAKE_TMUX" "$HERE/scripts/amux-status" 2>&1)"
assert_contains "$out" "SEAMBLOCK" \
  "amux-status follows \$TMUX when its seam is unset (not -L amux)"

# --- amux-switch: reads AND issues select-*. Wrong server => yanks focus. ---
rows="$(env -u AMUX_SWITCH_SOCK TMUX="$FAKE_TMUX" AMUX_SWITCH_DUMP=1 \
  "$HERE/scripts/amux-switch" 2>&1)"
assert_contains "$rows" "$pane" \
  "amux-switch follows \$TMUX when its seam is unset (not -L amux)"
assert_contains "$rows" "SEAMBLOCK" \
  "amux-switch resolves glyphs from the same server it lists"

# --- amux-notify: reads its backend choice from the server it resolves. ---
# `--which` prints the resolved backend, so a distinctive value proves which
# server was actually consulted. (Asserting a 0 exit here would prove nothing:
# this script is built never to fail.)
T set-option -g @amux-notify-backend "seam-backend"
which="$(env -u AMUX_NOTIFY_SOCK TMUX="$FAKE_TMUX" \
  "$HERE/scripts/amux-notify" --which 2>&1)"
assert_eq "$which" "seam-backend" \
  "amux-notify follows \$TMUX when its seam is unset (not -L amux)"
T set-option -gu @amux-notify-backend 2>/dev/null || true

# --- the explicit seam still wins over $TMUX (precedence, not replacement) ---
other_dir="$(mktemp -d /tmp/amx.XXXX)"; other="$other_dir/s"
tmux -S "$other" -f /dev/null new-session -d
tmux -S "$other" set-option -g @amux-glyph-blocked "OTHERBLOCK"
opane="$(tmux -S "$other" display-message -p '#{pane_id}')"
tmux -S "$other" set-option -p -t "$opane" @agent_state blocked
# seam points at `other`, $TMUX points at our test server: the seam must win
out="$(AMUX_STATUS_SOCK="$other" TMUX="$FAKE_TMUX" "$HERE/scripts/amux-status" 2>&1)"
assert_contains "$out" "OTHERBLOCK" "an explicit seam still outranks \$TMUX"
tmux -S "$other" kill-server 2>/dev/null; rm -rf "$other_dir"

# --- glyph reads must not round-trip a separator through tmux's format engine.
# A literal 0x1F in a display-message template survives on tmux 3.6+ but comes
# back as the four characters \037 on 3.4, so the split silently stops
# happening below the version we support. This looks correct on a modern box —
# it took CI on tmux 3.4 to catch it — hence a guard rather than a comment. ---
status_src="$(cat "$HERE/scripts/amux-status")"
case "$status_src" in
  *'display-message -p "#{@amux-glyph-'*)
    assert_eq "in-band-split" "per-value reads" \
      "amux-status reads glyphs one per call, not via a separator through tmux" ;;
  *) assert_eq ok ok \
      "amux-status reads glyphs one per call, not via a separator through tmux" ;;
esac

# and it must actually work when a glyph contains the characters a separator
# would have used
T set-option -g @amux-glyph-blocked 'a|b'
T set-option -g @amux-glyph-idle    'c d'
out="$(AMUX_STATUS_SOCK="$sock" "$HERE/scripts/amux-status" 2>&1)"
assert_contains "$out" "a|b 1" "a glyph containing | survives the read"
T set-option -g @amux-glyph-blocked "SEAMBLOCK"
T set-option -g @amux-glyph-idle    "SEAMIDLE"

# --- amux-config is EXEMPT by design: `amux init` / `amux settings` may run
# from a user's REGULAR tmux, where inheriting $TMUX would write amux's options
# into their everyday server. Pin that exemption so nobody "fixes" it. ---
case "$(cat "$HERE/scripts/lib/amux-config.sh")" in
  *'elif [ -n "${TMUX:-}" ]'*)
    assert_eq "inherits-TMUX" "exempt" \
      "amux-config does NOT inherit \$TMUX (it may run outside amux)" ;;
  *) assert_eq ok ok \
      "amux-config does NOT inherit \$TMUX (it may run outside amux)" ;;
esac
