#!/usr/bin/env bash
# Every roost script has to pick WHICH tmux server to talk to. Getting that wrong
# is the sharpest edge in the codebase: the production default is the shared
# server by name (-L roost), so a script invoked without its test seam silently
# addresses the developer's real session — reading their agents, or worse,
# writing to them.
#
# The scripts that only ever run from inside a roost server resolve in three
# steps: explicit seam -> the server we are running inside ($TMUX) -> -L roost.
# These tests pin the MIDDLE step, which is the one that keeps an invocation
# without the seam on the right server. They deliberately never set the seam.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
roost_test_server; sock="$ROOST_TEST_SOCK"
# `other`/`other_dir` (the secondary server further down, for the explicit-seam-
# outranks-$TMUX case) are unset until that block runs; the ${:-} defaults keep
# this trap safe to install (and to fire) before they exist, matching the shape
# test-agent-state.sh uses for its own secondary server. Without this, an early
# exit or a failed assertion mid-file strands that server and its /tmp/amx.XXXX
# dir — the happy-path cleanup further down only runs if execution gets there.
trap 'tmux -S "${other:-}" kill-server 2>/dev/null; rm -rf "${other_dir:-}"; roost_test_teardown' EXIT

# $TMUX is "<socket-path>,<pid>,<session>" — scripts read the first field.
FAKE_TMUX="$sock,0,0"

# Distinctive glyphs, so a passing assertion cannot be a coincidental match
# against whatever the developer's live server happens to be reporting.
T set-option -g @roost-glyph-blocked "SEAMBLOCK"
T set-option -g @roost-glyph-idle    "SEAMIDLE"

pane="$(T display-message -p '#{pane_id}')"
T set-option -p -t "$pane" @agent_state blocked

# --- roost-status: reads. Wrong server => reports someone else's agents. ---
out="$(env -u ROOST_STATUS_SOCK TMUX="$FAKE_TMUX" "$HERE/scripts/roost-status" 2>&1)"
assert_contains "$out" "SEAMBLOCK" \
  "roost-status follows \$TMUX when its seam is unset (not -L roost)"

# --- roost-switch: reads AND issues select-*. Wrong server => yanks focus. ---
rows="$(env -u ROOST_SWITCH_SOCK TMUX="$FAKE_TMUX" ROOST_SWITCH_DUMP=1 \
  "$HERE/scripts/roost-switch" 2>&1)"
assert_contains "$rows" "$pane" \
  "roost-switch follows \$TMUX when its seam is unset (not -L roost)"
assert_contains "$rows" "SEAMBLOCK" \
  "roost-switch resolves glyphs from the same server it lists"

# --- roost-notify: reads its backend choice from the server it resolves. ---
# `--which` prints the resolved backend, so a distinctive value proves which
# server was actually consulted. (Asserting a 0 exit here would prove nothing:
# this script is built never to fail.)
T set-option -g @roost-notify-backend "seam-backend"
which="$(env -u ROOST_NOTIFY_SOCK TMUX="$FAKE_TMUX" \
  "$HERE/scripts/roost-notify" --which 2>&1)"
assert_eq "$which" "seam-backend" \
  "roost-notify follows \$TMUX when its seam is unset (not -L roost)"
T set-option -gu @roost-notify-backend 2>/dev/null || true

# --- the explicit seam still wins over $TMUX (precedence, not replacement) ---
other_dir="$(mktemp -d /tmp/amx.XXXX)"; other="$other_dir/s"
tmux -S "$other" -f /dev/null new-session -d
tmux -S "$other" set-option -g @roost-glyph-blocked "OTHERBLOCK"
opane="$(tmux -S "$other" display-message -p '#{pane_id}')"
tmux -S "$other" set-option -p -t "$opane" @agent_state blocked
# seam points at `other`, $TMUX points at our test server: the seam must win
out="$(ROOST_STATUS_SOCK="$other" TMUX="$FAKE_TMUX" "$HERE/scripts/roost-status" 2>&1)"
assert_contains "$out" "OTHERBLOCK" "an explicit seam still outranks \$TMUX"
tmux -S "$other" kill-server 2>/dev/null; rm -rf "$other_dir"

# --- glyph reads must not round-trip a separator through tmux's format engine.
# A literal 0x1F in a display-message template survives on tmux 3.6+ but comes
# back as the four characters \037 on 3.4, so the split silently stops
# happening below the version we support. This looks correct on a modern box —
# it took CI on tmux 3.4 to catch it — hence a guard rather than a comment. ---
status_src="$(cat "$HERE/scripts/roost-status")"
case "$status_src" in
  *'display-message -p "#{@roost-glyph-'*)
    assert_eq "in-band-split" "per-value reads" \
      "roost-status reads glyphs one per call, not via a separator through tmux" ;;
  *) assert_eq ok ok \
      "roost-status reads glyphs one per call, not via a separator through tmux" ;;
esac

# and it must actually work when a glyph contains the characters a separator
# would have used
T set-option -g @roost-glyph-blocked 'a|b'
T set-option -g @roost-glyph-idle    'c d'
out="$(ROOST_STATUS_SOCK="$sock" "$HERE/scripts/roost-status" 2>&1)"
assert_contains "$out" "a|b 1" "a glyph containing | survives the read"
T set-option -g @roost-glyph-blocked "SEAMBLOCK"
T set-option -g @roost-glyph-idle    "SEAMIDLE"

# --- roost-config is EXEMPT by design: `roost init` / `roost settings` may run
# from a user's REGULAR tmux, where inheriting $TMUX would write roost's options
# into their everyday server. Pin that exemption so nobody "fixes" it. ---
case "$(cat "$HERE/scripts/lib/roost-config.sh")" in
  *'elif [ -n "${TMUX:-}" ]'*)
    assert_eq "inherits-TMUX" "exempt" \
      "roost-config does NOT inherit \$TMUX (it may run outside roost)" ;;
  *) assert_eq ok ok \
      "roost-config does NOT inherit \$TMUX (it may run outside roost)" ;;
esac
