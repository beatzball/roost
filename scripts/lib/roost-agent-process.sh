# Process evidence for an identity report and for guarded send. The pane's
# shell can survive the agent, and a resumed conversation can reuse its session
# id. Bind the report to the process that made it and to its foreground group.

roost_agent_process_foreground() {
  local group
  case "$1" in ''|0|1|*[!0123456789]*) return 1 ;; esac
  group="$(LC_ALL=C /bin/ps -o tpgid= -p "$1" 2>/dev/null)" || return 1
  group="${group//[[:space:]]/}"
  case "$group" in ''|0|1|*[!0123456789]*) return 1 ;; esac
  printf '%s\n' "$group"
}

# ps comm can include a path on macOS. Use roost's distinctive command names,
# with no fallback to labels or to a generic runtime such as node.
roost_agent_process_command() {
  roost_close_harness "" "${2##*/}" ""
  [ "$ROOST_CLOSE_HARNESS" = "$1" ]
}

roost_agent_process_birth() {
  local started
  started="$(LC_ALL=C TZ=UTC0 /bin/ps -o lstart= -p "$1" 2>/dev/null)" || return 1
  started="${started//[[:space:]]/}"; started="${started//:/}"
  case "$started" in ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]*) return 1 ;; esac
  printf '%s\n' "$started"
}

# Walk the reporter's parents to locate the harness. A launcher can lead the
# process group while its child runs the harness (for example an npm shim).
# A detached hook cannot borrow an unrelated foreground process's identity.
roost_agent_process_stamp() {
  local pane_pid="$1" harness="$2" process="$3" group row parent pgid tpgid command started n
  case "$harness" in claude|codex|opencode|copilot|pi) ;; *) return 1 ;; esac
  group="$(roost_agent_process_foreground "$pane_pid")" || return 1
  for ((n=0; n<32; n++)); do
    case "$process" in ''|0|1|*[!0123456789]*) break ;; esac
    row="$(LC_ALL=C /bin/ps -o ppid= -o pgid= -o tpgid= -o comm= -p "$process" 2>/dev/null)" || return 1
    read -r parent pgid tpgid command <<< "$row"
    if [ "$pgid" = "$group" ] && [ "$tpgid" = "$group" ] && roost_agent_process_command "$harness" "$command"; then
      started="$(roost_agent_process_birth "$process")" || return 1
      printf '%s-%s-%s-%s\n' "$pane_pid" "$group" "$process" "$started"
      return 0
    fi
    [ "$process" != "$pane_pid" ] || break
    process="$parent"
  done
  return 1
}

# Run by tmux if-shell immediately before it queues the format check and key.
# Recheck the command as well as birth: exec can replace a process in place.
roost_agent_process_matches() {
  local pane_pid="$1" group="$2" process="$3" started="$4" harness="$5" row pgid tpgid state command
  row="$(LC_ALL=C /bin/ps -o pgid= -o tpgid= -o stat= -o comm= -p "$process" 2>/dev/null)" || return 1
  read -r pgid tpgid state command <<< "$row"
  case "$state" in ''|Z*|T*|X*) return 1 ;; esac
  [ "$pgid" = "$group" ] && [ "$tpgid" = "$group" ] && roost_agent_process_command "$harness" "$command" \
    && [ "$(roost_agent_process_birth "$process")" = "$started" ] \
    && [ "$(roost_agent_process_foreground "$pane_pid")" = "$group" ]
}

. "${BASH_SOURCE[0]%/*}/roost-close.sh"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  roost_agent_process_matches "$@"
fi
