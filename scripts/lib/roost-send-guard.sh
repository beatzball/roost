# Guard tokens are opaque to callers. Pin both the tmux pane and the process
# that reported this harness session, including a resume with the same id.
ROOST_SEND_GUARD_FORMAT='v1/#{start_time}-#{pid}/#{pane_id}/#{pane_pid}/#{@roost-harness}/#{@roost-session}/#{@roost-agent-process}/#{pane_current_command}'
. "${BASH_SOURCE[0]%/*}/roost-close.sh"

roost_send_guard_args() {
  local LC_ALL=C pattern
  pattern='^v1/[0-9]+-[0-9]+/(%[0-9]+)/([0-9]+)/(claude|codex|opencode|copilot|pi)/[a-zA-Z0-9._:][a-zA-Z0-9._:-]{0,127}/([0-9]+)-([0-9]+)-([0-9]+)-([a-zA-Z0-9]+)/([a-zA-Z0-9._-]+)$'
  [[ "$1" =~ $pattern ]] || return 1
  GUARD_PANE="${BASH_REMATCH[1]}" GUARD_HARNESS="${BASH_REMATCH[3]}"
  GUARD_PANE_PID="${BASH_REMATCH[4]}" GUARD_GROUP="${BASH_REMATCH[5]}"
  GUARD_PID="${BASH_REMATCH[6]}" GUARD_BIRTH="${BASH_REMATCH[7]}"
  roost_close_harness "" "${BASH_REMATCH[8]}" ""
  [ "$GUARD_PANE_PID" = "${BASH_REMATCH[2]}" ] && [ "$GUARD_PANE" = "$2" ] && [ "$ROOST_CLOSE_HARNESS" = "$GUARD_HARNESS" ]
}

# -> 0 action confirmed, 7 refused by the guard, 1 no reliable response.
# The process probe runs from the server, then the format is evaluated in the
# same command queue as the action. This compares tmux's live foreground
# command too: the pane can return to its shell after the probe completes
# without changing any of its options. Do not evaluate an option as a format or
# put it into a command: only the validated token supplies command arguments.
# The terminal action cannot pin the foreground process through the PTY write.
roost_send_guard_action() {
  local token="$1" pane="$2" action="${3:-}" probe format result
  roost_send_guard_args "$token" "$pane" || return 7
  resolve_was send "$pane" 1 || return 7
  roost_pane__owner "$pane" 2>/dev/null || return 7
  [ "$(roost_send_policy "$ROOST_PENDING_STATE" 0)" = allow ] || return 7

  probe="$(roost_shell_quote "$ROOST_HOME/scripts/lib/roost-agent-process.sh")"
  # if-shell expands formats in its shell command. Preserve literal hashes
  # in the path to this checkout, including a path that looks like a format.
  probe="${probe//#/##}"
  probe="exec /bin/bash $probe $GUARD_PANE_PID $GUARD_GROUP $GUARD_PID $GUARD_BIRTH $GUARD_HARNESS"
  format="#{&&:#{==:$ROOST_SEND_GUARD_FORMAT,$token},#{==:#{pane_dead}/#{pane_in_mode}/#{pane_input_off},0/0/0}}"
  format="#{&&:$format,#{m/r:^(idle|done|working|error)?$,#{@agent_state}}}"
  if [ -n "$action" ]; then action="$action ; "; fi
  result="$(t if-shell -t "$pane" "$probe" \
    "if-shell -F -t $pane '$format' '${action}display-message -p guarded' 'display-message -p refused'" \
    'display-message -p refused' 2>/dev/null)" || return 1
  case "$result" in
    guarded) return 0 ;;
    refused) return 7 ;;
    *) return 1 ;;
  esac
}
