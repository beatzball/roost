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

out="$(with_preen "$ROOST" read --render "$other" 2>/dev/null)"
assert_prefix "$out" "PREEN-IN[-]" \
  "--render also renders the screen fallback"
assert_contains "$out" "scr-3" \
  "the rendered screen fallback carries the pane's own lines"

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
