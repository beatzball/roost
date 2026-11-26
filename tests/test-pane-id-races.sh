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
    paste-signal:*paste-buffer*)
      "$RACE_TMUX" "${args[@]}"; rc=$?
      . "$RACE_DIR/bin/rendezvous"
      pause_client
      exit "$rc" ;;
    paste-no-ack:*paste-buffer*)
      "$RACE_TMUX" "${args[@]}" >/dev/null
      exit $? ;;
    paste-refusal:*paste-buffer*)
      . "$RACE_DIR/bin/rendezvous"
      pause_client
      args=("${extra[@]}" -S "$(cat "$RACE_DIR/route")" "$@") ;;
    lost-after-enter:*send-keys*' Enter ;'*)
      "$RACE_TMUX" "${args[@]}"; rc=$?
      "$RACE_TMUX" -S "$sock" set-option -pu -t %0 @roost-id
      exit "$rc" ;;
    close-save:*kill-pane*)
      "$RACE_TMUX" "${args[@]}"; rc=$?
      printf '%s/new\n' "$RACE_DIR" > "$RACE_DIR/route"
      exit "$rc" ;;
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
  if [ "$gate" = paste-signal ]; then
    kill -TERM "$pid" 2>/dev/null
  else
    printf '%s/new\n' "$dir" > "$dir/route"
  fi
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

old_draft_clear() {
  local i
  for ((i=0; i<50; i++)); do
    [ -n "$(T old capture-pane -pt %0)" ] || return 0
    "$RACE_SLEEP" 0.05
  done
  return 1
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

# A paste can land before the client has its acknowledgement. A signal or
# a missing acknowledgement must leave the old editor ready for the next send.
cross_boot paste-signal 'send interrupted during paste' send "$id" 'FIRST-'
assert_eq "$race_rc" 143 'a signal during paste keeps the interrupted status'
old_draft_clear; assert_true $? 'the signal trap clears the in-flight stable paste'
out="$(PATH="$dir/bin:$PATH" "$HERE/bin/roost" send "$id" SECOND 2>"$dir/err")"; rc=$?
assert_eq "$rc" 0 'the next stable send succeeds'
old_screen="$(T old capture-pane -pt %0)"
assert_contains "$old_screen" SECOND 'the next prompt reaches the original pane'
[[ "$old_screen" != *FIRST-SECOND* ]]; assert_true $? 'the next prompt contains no previous draft'
T old respawn-pane -k -t %0 'exec cat'
PATH="$dir/bin:$PATH" RACE_GATE=paste-no-ack "$HERE/bin/roost" send "$id" 'UNACKNOWLEDGED-DRAFT' >"$dir/out" 2>"$dir/err"; rc=$?
assert_eq "$rc" 1 'an unacknowledged paste fails as a delivery error'
old_draft_clear; assert_true $? 'the unacknowledged paste is also cleared'

T old send-keys -t %0 -l EXISTING-DRAFT
refuses paste-refusal 'send refused at dispatch' send "$id" 'NOT-PASTED'
assert_eq "$(T old capture-pane -pt %0)" EXISTING-DRAFT 'a confirmed refusal leaves existing input alone'

# This editor echoes the paste and swallows Enter without moving its cursor.
# Losing the ID after Enter cannot turn that surviving draft into a success.
cat >"$dir/editor.py" <<'PY'
import os
import tty

tty.setraw(0)
os.write(1, b"> ")
while True:
    data = os.read(0, 1024)
    if not data:
        break
    os.write(1, data.replace(b"\r", b"").replace(b"\n", b""))
PY
T old respawn-pane -k -t %0 "exec python3 '$dir/editor.py'"
for ((i=0; i<100; i++)); do
  [ "$(T old capture-pane -pt %0)" != '> ' ] || break
  "$RACE_SLEEP" 0.05
done
printf '%s/old\n' "$dir" > "$dir/route"
PATH="$dir/bin:$PATH" RACE_GATE=lost-after-enter "$HERE/bin/roost" send "$id" 'SWALLOWED-ENTER-DRAFT' >"$dir/out" 2>"$dir/err"; rc=$?
assert_eq "$rc" 1 'an ID move after a swallowed Enter preserves the delivery failure'
assert_contains "$(cat "$dir/err")" 'but never submitted' 'a swallowed Enter is reported as unsubmitted'
T old set -p -t %0 @roost-id "$id"
T old respawn-pane -k -t %0 'exec cat'

refuses resolve 'read after resolution' read --json "$id"
refuses resolve 'answer after resolution' answer "$id" --deny
refuses resolve 'close after resolution' close --force "$id"

# Both records have the same pane number. Forget must reject the target
# after the boot changes, and its lookup must stay on the original boot.
old_boot="$(T old display -p '#{start_time}-#{pid}')"
new_boot="$(T new display -p '#{start_time}-#{pid}')"
for server in "$old_boot" "$new_boot"; do
  mkdir -p "$dir/kept/$server/0/replies"
  printf '1\n' >"$dir/kept/$server/0/schema"
  printf '%s\n' "$server" >"$dir/kept/$server/0/replies/000001"
done
ROOST_RECORD_DIR="$dir/kept" refuses resolve 'forget after resolution' forget "$id"
for server in "$old_boot" "$new_boot"; do
  assert_eq "$(cat "$dir/kept/$server/0/replies/000001" 2>/dev/null)" "$server" 'forget preserves the kept reply'
done

(
  export ROOST_EVENTS="$dir/event-log"
  . "$HERE/scripts/lib/roost-events.sh"
  roost_events_write "{\"server\":\"$old_boot\",\"pane\":\"%0\",\"event\":\"original-boot\"}"
  roost_events_write "{\"server\":\"$new_boot\",\"pane\":\"%0\",\"event\":\"replacement-boot\"}"
)
ROOST_EVENTS="$dir/event-log" cross_boot resolve 'events after resolution' events --pane "$id"
assert_eq "$race_rc" 0 'events can read the original boot after replacement'
assert_contains "$race_out" 'original-boot' 'events uses the resolved boot'
[[ "$race_out" != *replacement-boot* ]]; assert_true $? 'events excludes the replacement boot'

T new set -p -t %1 @roost-name existing-view
TMUX_PANE=%0 refuses resolve 'view before replacing a pane' view -n existing-view -- -t "$id" 'exec cat'
assert_eq "$(T new show -pqv -t %1 @roost-name)" existing-view 'view preserves the replacement boot view pane'
refuses resolve 'spawn before creating a window' spawn newer -t "$id" 'exec cat'
refuses resolve 'split before creating a pane' split -h -t "$id" 'exec cat'

# Control the stable split path re-entered by view without changing the boot.
printf '%s/old\n' "$dir" > "$dir/route"
created="$(TMUX_PANE=%0 ROOST_VIEW_MIN_COLS=0 PATH="$dir/bin:$PATH" "$HERE/bin/roost" view -n stable-view -- -t "$id" 'exec cat')"
require_pane "$created" 'view with a stable placement target'
assert_eq "$(T old show -pqv -t "$created" @roost-name)" stable-view 'view preserves its stable target through child placement'
T old kill-pane -t "$created"

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
alias_id=P-0001008
out="$(PATH="$dir/bin:$PATH" "$HERE/bin/roost" wait-done --json --turn 7 "$alias_id" 5 2>"$dir/err")"; rc=$?
assert_eq "$rc" 2 'wait-done exits 2 for a valid stable ID whose pane is already gone'
assert_contains "$out" '"outcome":"gone"' 'wait-done emits the gone JSON document'
assert_contains "$out" "\"target\":\"$alias_id\"" 'the gone document preserves the address as typed'
assert_contains "$out" '"turn":7' 'the gone document preserves the requested turn'

closing_pane="$(T old new-window -d -P -F '#{pane_id}' 'exec cat')"
T old set -p -t "$closing_pane" @roost-id "$id"
out="$(ROOST_SHAPE_DIR="$dir/close-save" PATH="$dir/bin:$PATH" RACE_GATE=close-save "$HERE/bin/roost" close --force "$id" 2>"$dir/err")"; rc=$?
assert_eq "$rc" 0 'close reports its successful kill even when the server changes before save'
assert_file_absent "$dir/close-save/$shape_key/shape" 'close never saves a shape from the replacement boot'
[ "$ROOST_TESTS_FAIL" -eq 0 ]
