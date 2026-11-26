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
  # A job-control shell can hand off to a second agent with the same command
  # name after ps returns, leaving the pane PID and all tmux metadata intact.
  # A dedicated agent owns the pane PID and leads its foreground group. A
  # tmux respawn then changes the pane PID in the final identity comparison.
  [ "$GUARD_PANE_PID" = "${BASH_REMATCH[2]}" ] && [ "$GUARD_PANE_PID" = "$GUARD_PID" ] \
    && [ "$GUARD_PID" = "$GUARD_GROUP" ] && [ "$GUARD_PANE" = "$2" ] \
    && [ "$ROOST_CLOSE_HARNESS" = "$GUARD_HARNESS" ]
}

roost_send_guard_query() {
  local pane="$1" probe="$2" format="$3" action="${4:-}" result
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

# -> 0 action confirmed, 7 refused before input, 1 outcome uncertain.
# The process probe runs from the server, then the format is evaluated in the
# same command queue as the action. Compare tmux's live foreground command
# with the identity and pane PID. Do not evaluate an option as a format or
# put it into a command: only the validated token supplies command arguments.
# The terminal action cannot pin the foreground process through the PTY write.
roost_send_guard_action() {
  local token="$1" pane="$2" action="${3:-}" stable_id="${4:-}" probe identity format claims rc=0
  local RW_TARGET RW_OLD RW_OLDBOOT RW_STABLE_INPUT RW_STABLE_ID
  roost_send_guard_args "$token" "$pane" || return 7
  if [ -n "$stable_id" ]; then
    roost_pane_id_parse "$stable_id" && [ "$ROOST_PANE_ID" = "$stable_id" ] || return 7
    roost_pane_id_find t "$stable_id" && [ "$ROOST_PANE_ID_PANE" = "$pane" ] || return 7
  else
    resolve_was send "$pane" 1 || return 7
  fi
  roost_pane__owner "$pane" 2>/dev/null || return 7
  [ "$(roost_send_policy "$ROOST_PENDING_STATE" 0)" = allow ] || return 7

  probe="$(roost_shell_quote "$ROOST_HOME/scripts/lib/roost-agent-process.sh")"
  # if-shell expands formats in its shell command. Preserve literal hashes
  # in the path to this checkout, including a path that looks like a format.
  probe="${probe//#/##}"
  probe="exec /bin/bash $probe $GUARD_PANE_PID $GUARD_GROUP $GUARD_PID $GUARD_BIRTH $GUARD_HARNESS"
  identity="#{&&:#{==:$ROOST_SEND_GUARD_FORMAT,$token},#{==:#{pane_dead},0}}"
  if [ -n "$stable_id" ]; then identity="#{&&:$identity,#{==:#{@roost-id},$stable_id}}"; fi
  format="#{&&:$identity,#{==:#{pane_in_mode}/#{pane_input_off},0/0}}"
  format="#{&&:$format,#{m/r:^(idle|done|working|error)?$,#{@agent_state}}}"
  # Keep the ordinary alias resolver's pane-local check and diagnostic above.
  # This final scan catches a claim added during the process probe. Each
  # visit to the intended pane emits 'a', and each live competing claim emits
  # 'x'. Requiring at least one 'a' also rejects an empty scan. tmux format
  # lookup inherits user options, so this last check errs on the side of refusal.
  if [ -n "$stable_id" ]; then
    # A stable target disambiguates an old %N claim. Check for competing
    # stable IDs instead, and bind the final action to the same stable ID.
    claims="#{S:#{W:#{P:#{?#{==:#{pane_id},$pane},a,#{?#{==:#{@roost-id},$stable_id},x,}}}}}"
  else
    claims="#{S:#{W:#{P:#{?#{==:#{pane_id},$pane},a,#{?#{&&:#{==:#{pane_dead},0},#{m/r:^%0*${pane#%}$,#{@roost-was}}},x,}}}}}"
  fi
  format="#{&&:$format,#{m/r:^a+$,$claims}}"
  roost_send_guard_query "$pane" "$probe" "$format" "$action" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  # The queue accepted the action. If the recipient disappeared during
  # delivery, preserve the uncertain outcome even after a final Enter. A
  # state change on the same agent (for example a new dialog) is allowed here.
  [ -z "$action" ] || roost_send_guard_query "$pane" "$probe" "$identity" || return 1
}
