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
if [ "$1" = -S ] && [ "$2" = "$RACE_DIR/route" ]; then
  shift 2
  args=(-S "$(cat "$RACE_DIR/route")" "$@")
  if [ "${RACE_GATE:-}" = resolve ] && [ "$*" = 'show-options -pqv -t %0 @roost-id' ]; then
    out="$("$RACE_TMUX" "${args[@]}")"; rc=$?
    . "$RACE_DIR/bin/rendezvous"
    pause_client
    printf '%s\n' "$out"
    exit "$rc"
  fi
  exec "$RACE_TMUX" "${args[@]}"
fi
exec "$RACE_TMUX" "$@"
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
  local gate="$1" label="$2" pid i=0 rc before after exists
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
  wait "$pid"; rc=$?
  after="$(T new capture-pane -pt %0 2>/dev/null)"; exists=$?
  assert_eq "$rc|$(cat "$dir/out")" '2|' "$label refuses the replaced pane"
  assert_contains "$(cat "$dir/err")" 'no longer names the resolved pane' "$label reports the lost stable target"
  assert_eq "$exists|$after" "0|$before" "$label leaves the replacement open with its input untouched"
}

bash "$dir/bin/roost-lock-fixture" "$HERE/scripts/lib/roost-panelock.sh" &
lock_pid=$!
for ((i=0; i<100; i++)); do
  [ ! -e "$dir/locked" ] || break
  "$RACE_SLEEP" 0.05
done
[ -e "$dir/locked" ] || exit 1
cross_boot 0.1 'send after its lock' send "$id" 'first message for original pane'
T old set -p -t %0 @agent_state working
cross_boot 1 'send after --when-idle' send --when-idle "$id" 'second message for original pane'
cross_boot 0.25 'wait-done after a poll' wait-done "$id" 5
T old set -pu -t %0 @agent_state
cross_boot 0.42 'send between paste and Enter' send "$id" 'third message for original pane'
cross_boot resolve 'read after resolution' read --json "$id"
cross_boot resolve 'answer after resolution' answer "$id" --deny
cross_boot resolve 'close after resolution' close --force "$id"
