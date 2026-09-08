#!/usr/bin/env bash
# `roost read --render`: the same text, handed to preen
# (https://github.com/beatzball/preen) so a HUMAN reading an agent's answer
# gets its markdown rendered instead of its source.
#
# Two properties carry the whole feature, and both are asserted below against a
# stub `preen` rather than the real one: the flag is opt-in, so the default
# output stays byte-identical for the callers that grep and diff it; and a
# machine without preen still gets the text, because the reply is the payload
# and the colour is not.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

# Same server shape as tests/test-reply-channel.sh, and for the same reason:
# roost-agent-state only acts on a socket path ending in /roost, and bin/roost
# takes its socket from $ROOST_SOCKET.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
shimdir="$(mktemp -d /tmp/amx.XXXX)"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir" "$shimdir"' EXIT
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
pane="$(tmux -S "$s" display -p '#{pane_id}')"
spid="$(tmux -S "$s" display -p '#{pid}')"
export ROOST_SOCKET="$s"

as_pane() { env TMUX="$s,$spid,0" TMUX_PANE="$pane" "$@"; }

# A stub, NOT the real preen. The real one pages, colours, and would make every
# assertion below a test of glow's output rather than of roost's plumbing. This
# one is transparent: it brackets whatever it is given, so an assertion can say
# both "the renderer ran" and "it received the text intact".
#
# Written as a fresh file in a scratch dir. Never symlink a real binary into a
# shim directory: a later `>` on the shim follows the link and truncates the
# original.
cat > "$shimdir/preen" <<'SHIM'
#!/bin/sh
printf 'PREEN-IN[%s]\n' "$1"
cat
printf 'PREEN-OUT\n'
SHIM
chmod +x "$shimdir/preen"
with_preen() { PATH="$shimdir:$PATH" "$@"; }

# A PATH with every directory that actually holds a preen removed, so the
# degrade-gracefully case is tested against a real absence rather than a
# guessed-at minimal PATH that might drop tmux or grep along with it. The
# author's own machine has preen installed; this is what makes the test give
# the same answer there as in CI, where it is not.
no_preen_path() {
  local out="" d
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    [ -x "$d/preen" ] && continue
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}
NOPREEN="$(no_preen_path)"
without_preen() { PATH="$NOPREEN" "$@"; }

reply=$'# heading\n\nsome **bold** text\n\n- one\n- two'
as_pane "$ROOST" reply "$reply"

# --- opt-in: the default path is untouched ----------------------------------

# The property the whole feature rests on. tests/test-reply-channel.sh compares
# this output byte for byte, and tests/test-coordination.sh and
# tests/test-panes.sh pipe it into grep -q, so anything added to the default
# path breaks all three. Asserted WITH the stub on PATH: "preen is missing" must
# not be what is really keeping the default clean.
assert_eq "$(with_preen "$ROOST" read "$pane")" "$reply" \
  "read without a flag returns the reply unchanged, even with preen on PATH"

# --- the rendered path ------------------------------------------------------

out="$(with_preen "$ROOST" read --render "$pane")"
assert_prefix "$out" "PREEN-IN[-]" \
  "--render pipes the reply through preen, invoked as \`preen -\`"
assert_contains "$out" "$reply" \
  "--render hands preen the whole reply, unchanged"

assert_eq "$(with_preen "$ROOST" read -r "$pane")" "$out" \
  "-r is the same flag as --render"

# --- a missing renderer degrades, it does not fail --------------------------

assert_eq "$(without_preen command -v preen || true)" "" \
  "the no-preen PATH really has no preen on it"

out="$(without_preen "$ROOST" read --render "$pane" 2>/dev/null)"
assert_eq "$out" "$reply" \
  "--render with no preen installed still prints the raw reply on stdout"

err="$(without_preen "$ROOST" read --render "$pane" 2>&1 >/dev/null)"
assert_contains "$err" "preen" \
  "--render with no preen installed warns on stderr"

without_preen "$ROOST" read --render "$pane" >/dev/null 2>&1
assert_eq "$?" "0" \
  "a missing renderer does not fail the read"

# --- the screen fallback renders too, and LINES still applies ---------------

# A pane with no @roost-reply, so `read` takes its documented fallback. Give it
# a screen worth reading first: screen_dump greps out blank lines, and an empty
# result would make the assertions below vacuous.
tmux -S "$s" split-window -d -t "$pane" 'ENV= exec /bin/sh'
other="$(tmux -S "$s" list-panes -F '#{pane_id}' | grep -v "^$pane$" | head -n 1)"
require_pane "$other" "the no-reply fallback pane"
tmux -S "$s" send-keys -t "$other" "printf 'scr-1\nscr-2\nscr-3\n'" Enter
sleep 0.5

# The fallback is NOT rendered, and that is a deliberate reversal. A recorded
# reply is markdown, because an agent wrote it. A PANE'S SCREEN IS NOT: it is
# terminal output, and handing it to a markdown renderer DELETES characters
# that happen to look like syntax. Measured against the real preen:
#
#   CANARY <ttyUSB0> port  ->  CANARY  port      (an HTML-ish tag, gone)
#   2*3*4 = 24             ->  234 = 24          (*3* read as emphasis)
#   rate _low_ now         ->  rate low now      (underscores eaten)
#
# Silently deleting bytes out of the one output a human reads to find out what
# a pane is doing is worse than not colouring it, so the screen goes through
# untouched and stderr says why. Found by review before this shipped.
out="$(with_preen "$ROOST" read --render "$other" 2>/dev/null)"
case "$out" in
  *"PREEN-IN[-]"*) assert_eq rendered raw \
    "--render does NOT render the screen fallback (it is not markdown)" ;;
  *) assert_eq ok ok "--render does NOT render the screen fallback (it is not markdown)" ;;
esac
assert_contains "$out" "scr-3" \
  "the unrendered screen fallback still carries the pane's own lines"
err="$(with_preen "$ROOST" read --render "$other" 2>&1 >/dev/null)"
assert_contains "$err" "not rendered" \
  "--render says on stderr why the screen fallback was left alone"


# LINES is still the third word. The flag is consumed in front of the target,
# so a caller that has always written `roost read TGT N` keeps that shape with
# the flag added — this is why the flag is not accepted after the target.
# 2, not 1: the pane is a shell, so its last non-blank line is the PROMPT that
# came back after the printf. Asking for 1 would return only that and assert
# nothing about the flag.
out="$(with_preen "$ROOST" read --render "$other" 2 2>/dev/null)"
assert_contains "$out" "scr-3" \
  "LINES still applies with --render: the last line survives"
case "$out" in
  *scr-1*) assert_eq kept dropped "LINES still applies with --render: earlier lines are dropped" ;;
  *)       assert_eq ok ok "LINES still applies with --render: earlier lines are dropped" ;;
esac

# The characters themselves, which is the assertion that would have caught the
# bug. A screen carrying markdown-looking punctuation must come back whole.
# Placed AFTER the LINES cases on purpose: it writes another line to the pane,
# and those cases count back from the last one.
tmux -S "$s" send-keys -t "$other" "printf 'CAN <tty0> 2*3*4 _low_\n'" Enter
sleep 0.5
out="$(with_preen "$ROOST" read --render "$other" 2>/dev/null)"
assert_contains "$out" "<tty0>" \
  "the screen fallback keeps an angle-bracketed token under --render"
assert_contains "$out" "2*3*4" \
  "the screen fallback keeps asterisks under --render"
assert_contains "$out" "_low_" \
  "the screen fallback keeps underscores under --render"

# --- a preen that FAILS must not fail the read ------------------------------
# bin/roost runs `set -euo pipefail`, so a renderer that exits non-zero used to
# take the whole command's status with it: the reply printed fine and
# `roost read -r X || die` died anyway. The renderer is a convenience; its
# failure must cost the caller the COLOUR, never the text and never the exit
# status. Same principle the missing-preen case above already encodes -- this
# is the other half of it, and only review caught that the half was missing.
cat > "$shimdir/preen" <<'SHIM'
#!/bin/sh
cat >/dev/null
echo "preen: simulated failure" >&2
exit 3
SHIM
chmod +x "$shimdir/preen"
out="$(with_preen "$ROOST" read -r "$pane" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "a preen that exits 3 does not fail roost read"
assert_eq "$out" "$reply" \
  "a preen that exits 3 still delivers the reply, unrendered"
err="$(with_preen "$ROOST" read -r "$pane" 2>&1 >/dev/null)"
assert_contains "$err" "preen" \
  "a failing preen is named on stderr, not swallowed"
# Put the transparent stub back for anything after this point.
cat > "$shimdir/preen" <<'SHIM'
#!/bin/sh
printf 'PREEN-IN[%s]\n' "$1"
cat
SHIM
chmod +x "$shimdir/preen"

# --- the flag AFTER the target is refused, not silently eaten ---------------
# `roost read TGT --render` used to be swallowed as the LINES argument: with a
# recorded reply it printed raw text at exit 0 with no warning, and on the
# fallback path it produced `tail: illegal offset -- --render` and no output at
# all. A flag that looks like it worked and did nothing is the failure mode
# this repo keeps paying for, so it is now a usage error that names the shape.
out="$(with_preen "$ROOST" read "$pane" --render 2>&1)"; rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
  "the flag after the target exits non-zero instead of being ignored"
assert_contains "$out" "usage" \
  "the flag after the target says what the right shape is"
out="$(with_preen "$ROOST" read "$other" -r 2>&1)"; rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
  "-r after the target is refused on the fallback path too"
case "$out" in
  *"illegal offset"*) assert_eq leaked clean \
    "the refusal does not leak tail's error" ;;
  *) assert_eq ok ok "the refusal does not leak tail's error" ;;
esac

# --- a missing target is still a usage error --------------------------------

# The flag must not swallow the target check. `roost read --render` with nothing
# after it used to be `roost read` with nothing after it, and that exits 1 with
# a usage message rather than reading the active pane.
with_preen "$ROOST" read --render >/dev/null 2>&1
rc=$?
case "$rc" in
  0) assert_eq 0 nonzero "--render with no target is still a usage error" ;;
  *) assert_eq ok ok "--render with no target is still a usage error" ;;
esac

# --- the flag is documented -------------------------------------------------

# `roost help` reads the command list back out of bin/roost's own header
# comment, so this asserts the header was updated rather than that a second
# copy exists.
assert_contains "$("$ROOST" help 2>/dev/null)" "--render" \
  "roost help documents --render"
