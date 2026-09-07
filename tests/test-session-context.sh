#!/usr/bin/env bash
# tests/test-session-context.sh — scripts/roost-session-context must tell a
# Claude session it is inside roost, and must say NOTHING anywhere else.
#
# SAFETY, and it is not optional. Two of the things under test here resolve a
# tmux server by NAME when $ROOST_SOCKET is unset, and `-L roost` by name is
# the developer's live server, holding real agents:
#
#   - bin/roost's socket rule falls through to it (that fallthrough is the
#     whole subject of the negative case below)
#   - scripts/roost-doctor reaches a live server through roost_opt/roost_cfg_tmux
#
# `-L NAME` resolves under $TMUX_TMPDIR, so this file points that at a
# throwaway directory before running anything and creates its own inert
# `-L roost` server inside it. A run of this file therefore reaches an empty
# socket dir instead of real work, which is what makes it safe to exercise the
# fallthrough deliberately rather than tiptoeing around it.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SC="$HERE/scripts/roost-session-context"

# Short dirs — the ~104-char unix socket limit silently corrupts long paths.
tmpdir="$(mktemp -d /tmp/amx.XXXX)"
export TMUX_TMPDIR="$tmpdir"

# The socket path ENDS IN /roost on purpose: that suffix is the rule
# scripts/lib/roost-socket.sh applies to answer "am I inside a roost server",
# so the fixed name roost_test_server gives you (.../s) would not be
# recognised and every assertion below would pass for the wrong reason.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
# A second server whose socket is NOT named roost — a stand-in for the user's
# ordinary everyday tmux, for the negative case.
ndir="$(mktemp -d /tmp/amx.XXXX)"; n="$ndir/plain"
trap 'tmux -L roost kill-server 2>/dev/null; tmux -S "$s" kill-server 2>/dev/null; tmux -S "$n" kill-server 2>/dev/null; rm -rf "$sdir" "$ndir" "$tmpdir"' EXIT

tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
tmux -S "$n" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
# The inert stand-in for the shared production server. It exists so the
# negative case below has something to WRONGLY find: without a `-L roost`
# server running, `roost whoami` would fail for lack of a server rather than
# for the reason the guard is meant to catch, and the test would pass on
# unfixed code.
tmux -L roost -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'

spane="$(tmux -S "$s" display -p '#{pane_id}')"; spid="$(tmux -S "$s" display -p '#{pid}')"
npane="$(tmux -S "$n" display -p '#{pane_id}')"; npid="$(tmux -S "$n" display -p '#{pid}')"

# `env -u ROOST_SOCKET` rather than merely not setting it: the suite may be run
# from a shell that has it exported, and the whole point of both cases is which
# server gets resolved with NOTHING hand-pointing the way.
in_roost()  { env -u ROOST_SOCKET TMUX="$s,$spid,0" TMUX_PANE="$spane" "$@"; }
in_plain()  { env -u ROOST_SOCKET TMUX="$n,$npid,0" TMUX_PANE="$npane" "$@"; }

ctx() { python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }

# --- inside roost: the JSON contract -----------------------------------------

out="$(in_roost "$SC" </dev/null 2>/dev/null)"

# Valid JSON is the first thing to pin, because invalid JSON here is SILENT:
# Claude Code starts the session with no context and prints nothing about it.
if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ROOST_TESTS_PASS=$((ROOST_TESTS_PASS+1)); printf '  PASS: %s\n' "the hook emits parseable JSON"
else
  ROOST_TESTS_FAIL=$((ROOST_TESTS_FAIL+1)); printf '  FAIL: %s\n       [%s]\n' "the hook emits parseable JSON" "$out"
fi

ev="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)"
# Claude Code matches this string to decide the payload is a SessionStart
# result. Any other value and additionalContext is ignored — again silently.
assert_eq "$ev" "SessionStart" "hookEventName is exactly SessionStart"

text="$(printf '%s' "$out" | ctx 2>/dev/null)"
assert_contains "$text" "$spane" "the injected context names this pane's own id"
assert_contains "$text" "roost split" "the injected context steers at roost split"
assert_contains "$text" "roost send" "the injected context steers at roost send"
assert_contains "$text" "kill-server" "the injected context carries the kill-server warning"

# A real newline, not the two characters backslash-n. The text is built by a
# heredoc that writes JSON's own \n escape, so this asserts the escape survived
# as an escape and was not double-written into the literal string.
case "$text" in
  *"$(printf '\n')"*) ROOST_TESTS_PASS=$((ROOST_TESTS_PASS+1)); printf '  PASS: %s\n' "the injected context has real line breaks" ;;
  *) ROOST_TESTS_FAIL=$((ROOST_TESTS_FAIL+1)); printf '  FAIL: %s\n       [%s]\n' "the injected context has real line breaks" "$text" ;;
esac

# No systemMessage. It is a valid field for this event and deliberately unused:
# it prints a line to the USER on every session start, on every machine with
# the hook wired, forever.
has_sm="$(printf '%s' "$out" | python3 -c 'import json,sys; print("yes" if "systemMessage" in json.load(sys.stdin) else "no")' 2>/dev/null)"
assert_eq "$has_sm" "no" "the hook prints no systemMessage at the user"

# --- outside roost: silence ---------------------------------------------------

# The regression this file exists for. From a pane in the user's ORDINARY tmux,
# with a roost server running and $ROOST_SOCKET unset, `roost whoami` prints an
# id and exits 0 — it resolves the production server BY NAME and asks it about
# the caller's pane id, which on that server is a real pane belonging to a
# stranger. A hook that trusted whoami alone therefore told an agent in the
# user's everyday tmux that it was inside roost, and handed it another agent's
# address to `roost send` into. Measured, not reasoned about.
out="$(in_plain "$SC" </dev/null 2>&1)"; rc=$?
assert_eq "$out" "" "an ordinary non-roost tmux gets no context injected"
assert_eq "$rc" "0" "an ordinary non-roost tmux gets exit 0"

# Belt and braces: whoami really does answer for that pane, so the assertion
# above is pinning the guard and not an accident of the server being missing.
who="$(in_plain "$HERE/bin/roost" whoami 2>/dev/null)"
assert_prefix "$who" "%" "roost whoami still resolves an id outside roost (which is why the guard cannot use it alone)"

# No tmux at all — a plain terminal, the ordinary case for anyone who wired the
# hook globally and is not using roost right now.
out="$(env -u TMUX -u TMUX_PANE -u ROOST_SOCKET "$SC" </dev/null 2>&1)"; rc=$?
assert_eq "$out" "" "outside tmux entirely the hook prints nothing"
assert_eq "$rc" "0" "outside tmux entirely the hook exits 0"

# Exit 2 is the one code that must never appear: Claude Code reads it as BLOCK
# and refuses to start the session at all. Assert it explicitly rather than
# leaving it implied by the two exit-0 checks above, because that is the
# failure a future edit would introduce and nothing else would name.
in_roost "$SC" </dev/null >/dev/null 2>&1
assert_eq "$?" "0" "the hook never exits 2 (which would block session start)"

# --- roost hooks claude wires it ----------------------------------------------

hooks="$("$HERE/bin/roost" hooks claude 2>/dev/null | grep -v '^#')"
if printf '%s' "$hooks" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ROOST_TESTS_PASS=$((ROOST_TESTS_PASS+1)); printf '  PASS: %s\n' "roost hooks claude is still valid JSON"
else
  ROOST_TESTS_FAIL=$((ROOST_TESTS_FAIL+1)); printf '  FAIL: %s\n' "roost hooks claude is still valid JSON"
fi

got="$(printf '%s' "$hooks" | python3 -c '
import json,sys
h = json.load(sys.stdin)["hooks"]["SessionStart"]
print(h[0]["matcher"], h[0]["hooks"][0]["type"], h[0]["hooks"][0]["command"].split("/")[-1])
' 2>/dev/null)"
# The matcher is "*" on purpose: SessionStart fires for startup, resume, clear,
# compact and fork, and not one of those leaves the preamble in the context.
# Naming a subset would also silently skip whichever source is added next.
assert_eq "$got" "* command roost-session-context" \
  "roost hooks claude wires SessionStart to roost-session-context for every source"

# The four state hooks must survive the addition. This is the check that would
# catch an edit to that heredoc that added SessionStart by breaking something.
for ev in UserPromptSubmit Notification PostToolUse Stop; do
  assert_contains "$hooks" "\"$ev\"" "roost hooks claude still wires $ev"
done

# --- doctor names a settings file that is missing it ---------------------------

# Pin doctor's reach at inert values, exactly as tests/test-doctor.sh does: it
# reads saved glyph config and shells out to roost-notify, and both fall back
# to `-L roost` when these are unset.
export ROOST_CONFIG_SOCK="/nonexistent/roost-session-context-test-sock"
export ROOST_NOTIFY_SOCK="/nonexistent/roost-session-context-test-sock"
cfgdir="$(mktemp -d /tmp/amx.XXXX)"
setdir="$(mktemp -d /tmp/amx.XXXX)"

# A settings file in the shape someone gets by copying `roost hooks` BEFORE
# this hook existed: the four state hooks, no SessionStart.
printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/x/scripts/roost-agent-state working"}]}],"Stop":[{"hooks":[{"type":"command","command":"/x/scripts/roost-agent-state done --stop-hook"}]}]}}\n' \
  > "$setdir/old.json"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$cfgdir" CLAUDE_SETTINGS="$setdir/old.json" "$HERE/scripts/roost-doctor" 2>&1)"
assert_contains "$out" "no SessionStart hook" "doctor names a settings file wired before SessionStart existed"

# ...and it stays a WARNING. Most of doctor's optional checks must never fail
# the required-check exit code, and a missing context hook costs guidance, not
# correctness.
COLORTERM=truecolor XDG_CONFIG_HOME="$cfgdir" CLAUDE_SETTINGS="$setdir/old.json" "$HERE/scripts/roost-doctor" >/dev/null 2>&1
assert_eq "$?" "0" "a missing SessionStart hook does not fail doctor"

# The same file with the hook added draws no such warning.
printf '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"/x/scripts/roost-session-context"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/x/scripts/roost-agent-state working"}]}],"Stop":[{"hooks":[{"type":"command","command":"/x/scripts/roost-agent-state done --stop-hook"}]}]}}\n' \
  > "$setdir/new.json"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$cfgdir" CLAUDE_SETTINGS="$setdir/new.json" "$HERE/scripts/roost-doctor" 2>&1)"
case "$out" in
  *"no SessionStart hook"*) ROOST_TESTS_FAIL=$((ROOST_TESTS_FAIL+1)); printf '  FAIL: %s\n' "doctor is quiet when the SessionStart hook is wired" ;;
  *) ROOST_TESTS_PASS=$((ROOST_TESTS_PASS+1)); printf '  PASS: %s\n' "doctor is quiet when the SessionStart hook is wired" ;;
esac

rm -rf "$cfgdir" "$setdir"
exit 0
