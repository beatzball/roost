#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Two real servers have the same %0. Only the client under test sees the
# routed socket, which lets each pause cross a boot boundary deterministically.
dir="$(mktemp -d /tmp/amx.XXXX)" || exit 1
export RACE_DIR="$dir" RACE_TMUX="$(command -v tmux)" RACE_SLEEP="$(command -v sleep)"
trap '"$RACE_TMUX" -S "$dir/old" kill-server 2>/dev/null; "$RACE_TMUX" -S "$dir/new" kill-server 2>/dev/null; rm -rf "$dir"' EXIT
export XDG_STATE_HOME="$dir/state" ROOST_NO_SHIM=1 ROOST_EVENTS="" ROOST_SOCKET="$dir/route"
unset TMUX TMUX_PANE
mkdir "$dir/bin"
cat > "$dir/bin/rendezvous" <<'EOF'
# Sourced by the tmux and sleep wrappers.
pause_client() {
  [ -e "$RACE_DIR/paused" ] && return
  touch "$RACE_DIR/paused"
  local i=0
  while [ ! -e "$RACE_DIR/go" ] && [ "$i" -lt 200 ]; do
    "$RACE_SLEEP" 0.05; i=$((i+1))
  done
}
EOF
cat > "$dir/bin/tmux" <<'EOF'
#!/usr/bin/env bash
extra=()
if [ "$1" = -u ]; then extra=(-u); shift; fi
if [ "$1" = -S ] && [ "$2" = "$RACE_DIR/route" ]; then
  shift 2
  sock="$(cat "$RACE_DIR/route")"
  args=("${extra[@]}" -S "$sock" "$@")
  if [ "${RACE_GATE:-}" = resolve ] && [ "$*" = 'show-options -pqv -t %0 @roost-id' ]; then
    out="$("$RACE_TMUX" "${args[@]}")"; rc=$?
    . "$RACE_DIR/bin/rendezvous"
    pause_client
    printf '%s\n' "$out"
    exit "$rc"
  fi
  case "${RACE_GATE:-}:$*" in
    revive:*respawn-pane*|revive-new:*new-window*)
      . "$RACE_DIR/bin/rendezvous"
      pause_client
      args=("${extra[@]}" -S "$(cat "$RACE_DIR/route")" "$@")
      if [ "$RACE_GATE" = revive-new ]; then
        out="$("$RACE_TMUX" "${args[@]}")"; rc=$?
        case "$out" in %[0-9]*) touch "$RACE_DIR/window-created" ;; esac
        printf '%s\n' "$out"
        exit "$rc"
      fi ;;
    close-poll:*send-keys*" Enter"*)
      touch "$RACE_DIR/close-entered" ;;
    close-poll:list-panes*window_panes*|wait-done:list-panes*'p#{pane_pid}'*)
      if [ "${RACE_GATE:-}" = wait-done ] || [ -f "$RACE_DIR/close-entered" ]; then
        "$RACE_TMUX" "${args[@]}"; rc=$?
        "$RACE_TMUX" -S "$sock" kill-pane -t "${RACE_PANE:-%0}"
        exit "$rc"
      fi ;;
  esac
  exec "$RACE_TMUX" "${args[@]}"
fi
exec "$RACE_TMUX" "${extra[@]}" "$@"
EOF
cat > "$dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
if [ "${RACE_GATE:-}" = "$1" ]; then
  . "$RACE_DIR/bin/rendezvous"
  pause_client
fi
exec "$RACE_SLEEP" "$@"
EOF
chmod +x "$dir/bin/tmux" "$dir/bin/sleep"

cat > "$dir/bin/roost-lock-fixture" <<'EOF'
#!/usr/bin/env bash
. "$1"
roost_panelock_take "$RACE_DIR/old" %0 0 || exit 1
trap 'roost_panelock_drop' EXIT
touch "$RACE_DIR/locked"
for ((i=0; i<200; i++)); do
  [ ! -e "$RACE_DIR/unlock" ] || exit 0
  "$RACE_SLEEP" 0.05
done
EOF

T() { local server="$1"; shift; "$RACE_TMUX" -S "$dir/$server" "$@"; }
for server in old new; do
  T "$server" -f /dev/null new-session -d -s main 'exec cat' || exit 1
  T "$server" new-window -d 'exec cat' || exit 1
  T "$server" set -g @roost-send-enter-delay 0.42
  T "$server" set -g @roost-send-turn-timeout 0
done
id=p-000-100-8
T old set -p -t %0 @roost-id "$id"
T new set -p -t %0 @roost-id p-000-101-7
T new set -p -t %0 @roost-reply WRONG-REPLY

cross_boot() {
  local gate="$1" label="$2" pid i=0 before after exists
  shift 2
  rm -f "$dir/paused" "$dir/go"
  printf '%s/old\n' "$dir" > "$dir/route"
  before="$(T new capture-pane -pt %0)"
  PATH="$dir/bin:$PATH" RACE_GATE="$gate" "$HERE/bin/roost" "$@" >"$dir/out" 2>"$dir/err" &
  pid=$!
  while [ ! -e "$dir/paused" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    "$RACE_SLEEP" 0.05; i=$((i+1))
  done
  [ -e "$dir/paused" ]; assert_true $? "$label reached the pause"
  printf '%s/new\n' "$dir" > "$dir/route"
  if [ "$gate" = 0.1 ]; then
    touch "$dir/unlock"
    wait "$lock_pid"
  fi
  touch "$dir/go"
  wait "$pid"; race_rc=$?
  race_out="$(cat "$dir/out")"; race_err="$(cat "$dir/err")"
  after="$(T new capture-pane -pt %0 2>/dev/null)"; exists=$?
  assert_eq "$exists|$after" "0|$before" "$label leaves the replacement open with its input untouched"
}

refuses() {
  cross_boot "$@"
  assert_eq "$race_rc|$race_out" '2|' "$2 refuses the replaced pane"
  assert_contains "$race_err" 'no longer names the resolved pane' "$2 reports the lost stable target"
}

bash "$dir/bin/roost-lock-fixture" "$HERE/scripts/lib/roost-panelock.sh" &
lock_pid=$!
for ((i=0; i<100; i++)); do
  [ ! -e "$dir/locked" ] || break
  "$RACE_SLEEP" 0.05
done
[ -e "$dir/locked" ] || exit 1
refuses 0.1 'send after its lock' send "$id" 'first message for original pane'
T old set -p -t %0 @agent_state working
refuses 1 'send after --when-idle' send --when-idle "$id" 'second message for original pane'
cross_boot 0.25 'wait-done after a poll' wait-done --json "$id" 5
assert_eq "$race_rc" 2 'wait-done exits as a dead agent after losing a working pane'
assert_contains "$race_out" '"outcome":"died"' 'wait-done preserves the died JSON outcome'
T old set -pu -t %0 @agent_state
cross_boot 0.42 'send between paste and Enter' send "$id" 'third message for original pane'
assert_eq "$race_rc|$race_out" '1|' 'send reports paste without submit'
assert_contains "$race_err" 'but never submitted' 'the send failure explains that Enter was withheld'
for ((i=0; i<50; i++)); do
  old_screen="$(T old capture-pane -pt %0)"
  [ -n "$old_screen" ] || break
  "$RACE_SLEEP" 0.05
done
assert_eq "$old_screen" '' 'cleanup clears the draft in the pane that received it'
refuses resolve 'read after resolution' read --json "$id"
refuses resolve 'answer after resolution' answer "$id" --deny
refuses resolve 'close after resolution' close --force "$id"
T new send-keys -t %0 -l WRONG-PANE-SCREEN
refuses resolve 'screen after resolution' screen "$id"
refuses resolve 'JSON screen after resolution' screen --json "$id"

# The exec fixture changes the old pane's PID if revive actually runs.
printf '#!/bin/sh\nexec sleep 120\n' > "$dir/bin/claude"
chmod +x "$dir/bin/claude"
T old respawn-pane -k -t %0 'ENV= exec /bin/sh'
printf '{"type":"user","cwd":"%s"}\n' "$dir" > "$dir/transcript.jsonl"
T old set -p -t %0 @roost-harness claude
T old set -p -t %0 @roost-session 3fa3c0de-1111-4abc-8def-000000000001
T old set -p -t %0 @roost-cwd "$dir"
T old set -p -t %0 @roost-transcript-path "$dir/transcript.jsonl"
T new set -p -t %0 @roost-reply KEEP-REPLY
replacement_pid="$(T new display -pt %0 '#{pane_pid}')"
refuses revive 'revive before respawn' revive "$id"
assert_eq "$(T new display -pt %0 '#{pane_pid}')" "$replacement_pid" 'revive leaves the replacement process alone'
assert_eq "$(T new show -pqv -t %0 @roost-reply)" KEEP-REPLY 'revive leaves the replacement options alone'

# A dead pane with a kept conversation can open a new window. The
# creation must be pinned before the ID transfer can even be attempted.
T old set -p -t %0 remain-on-exit on
T old set -pu -t %0 @roost-session
T old respawn-pane -k -t %0 'exit 1'
for ((i=0; i<100; i++)); do
  [ "$(T old display -pt %0 '#{pane_dead}')" != 1 ] || break
  "$RACE_SLEEP" 0.05
done
boot="$(T old display -p '#{start_time}-#{pid}')"
rec="$dir/records/$boot/0"
mkdir -p "$rec"
printf '1\n' > "$rec/schema"
printf '%s\n' "$dir/old" > "$rec/socket"
printf 'claude\n' > "$rec/harness"
printf '3fa3c0de-1111-4abc-8def-000000000001\n' > "$rec/session_id"
printf '%s\n' "$dir" > "$rec/cwd"
printf '%s\n' "$dir/transcript.jsonl" > "$rec/transcript"
ROOST_RECORD_DIR="$dir/records" refuses revive-new 'revive before creating its new window' revive --new-window "$id"
assert_file_absent "$dir/window-created" 'revive does not start a new process on the replacement server'

# The close wait receives its last row just as the original pane exits.
printf '%s/old\n' "$dir" > "$dir/route"
T old set -p -t %0 remain-on-exit off
T old respawn-pane -k -t %0 'exec sleep 120'
T old set -p -t %0 @agent_state idle
boot="$(T old display -p '#{start_time}-#{pid}')"
shape_key="path-$(printf '%s' "$ROOST_SOCKET" | cksum | cut -d' ' -f1)"
out="$(ROOST_SHAPE_DIR="$dir/shapes" PATH="$dir/bin:$PATH" RACE_GATE=close-poll "$HERE/bin/roost" close "$id" 5 2>"$dir/err")"; rc=$?
assert_eq "$rc" 0 'close succeeds when the addressed pane exits during its poll'
assert_contains "$out" 'closed %0' 'close reports the completed action'
assert_eq "$(cat "$dir/shapes/$shape_key/closed/$boot/close.0" 2>/dev/null)" '%0' 'close keeps its intentional-close marker'
assert_contains "$(cat "$dir/shapes/$shape_key/shape" 2>/dev/null)" 'trigger close' 'close saves the new shape after the pane exits'
done_pane="$(T old new-window -d -P -F '#{pane_id}' 'exec cat')"
T old set -p -t "$done_pane" @roost-id "$id"
T old set -p -t "$done_pane" @agent_state done
out="$(PATH="$dir/bin:$PATH" RACE_GATE=wait-done RACE_PANE="$done_pane" "$HERE/bin/roost" wait-done --json "$id" 5)"; rc=$?
assert_eq "$rc" 0 'wait-done succeeds when a pane exits after the done snapshot'
assert_contains "$out" '"outcome":"done"' 'wait-done preserves the completed JSON outcome'
assert_contains "$out" '"state":"done"' 'the done snapshot supplies the last known state'
[ "$ROOST_TESTS_FAIL" -eq 0 ]
