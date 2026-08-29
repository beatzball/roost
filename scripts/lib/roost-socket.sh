# roost-socket.sh — the one place that answers "which tmux server am I in?".
#
# Sourced by BOTH bin/roost and scripts/roost-agent-state, for the reason
# roost-reply.sh gives about truncation: these two are the two halves of the
# adapter contract — `roost state` badges a pane and `roost reply` records what
# that pane said — and they used to answer this question by two different
# rules. roost-agent-state read the socket out of $TMUX; bin/roost defaulted to
# the shared production server by NAME. On any server that was not the default
# `-L roost`, badges landed and replies vanished, exit 0, nothing printed. That
# is the drift this file exists to prevent, so keep it one rule and one copy.
#
# It answers a NARROWER question than "is $TMUX set". A user's everyday tmux is
# still a tmux server, and `roost spawn` / `roost send` typed from inside one
# must keep addressing the roost server — the same exemption
# scripts/lib/roost-config.sh carries, and tests/test-socket-seams.sh pins.

# roost_self_socket — set ROOST_SELF_SOCK to the socket PATH of the roost
# server this process is running inside, or to "" if it is not inside one.
#
# It SETS a variable rather than printing one. roost-agent-state calls this on
# the PostToolUse hot path, which fires after every tool call of every live
# agent and which Claude blocks on; `$(...)` would add a fork per tool call to
# a path whose whole design is one tmux read and then bail.
roost_self_socket() {
  ROOST_SELF_SOCK=""
  # $TMUX is "<socket-path>,<pid>,<session>" — the socket is the first field.
  [ -n "${TMUX:-}" ] || return 0
  # The path must END IN /roost. That is a deliberately conservative test, and
  # it is the one roost-agent-state has always applied:
  #
  #  - It is what makes a global Claude hook safe. The hook is wired into
  #    ~/.claude/settings.json by absolute path and runs for `claude` started
  #    ANYWHERE, including inside the user's own tmux; matching every server
  #    would stamp @agent_state onto their everyday panes.
  #  - It compares the PATH, not the pid, which is what lets it recognise a
  #    roost server it was never told about — a second server, a `roost ssh`
  #    one, a live smoke test.
  #
  # What it refuses, and this is on purpose: a roost server on a socket named
  # anything else (tests/lib.sh's .../s). Those set $ROOST_SOCKET explicitly,
  # which outranks this in every caller.
  case "${TMUX%%,*}" in
    */roost) ROOST_SELF_SOCK="${TMUX%%,*}" ;;
  esac
}
