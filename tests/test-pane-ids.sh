#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/lib/roost-pane-id.sh"
ROOST="$HERE/bin/roost"

work="$(mktemp -d /tmp/amx.XXXX)"; sock="$work/roost"
trap 'tmux -S "$work/roost" kill-server 2>/dev/null; tmux -S "$work/restored/roost" kill-server 2>/dev/null; rm -rf "$work"' EXIT
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_STATE_HOME="$work/state"
export COPILOT_HOME="$work/copilot" CODEX_HOME="$work/codex" PI_CODING_AGENT_DIR="$work/pi"
export CLAUDE_SETTINGS="$work/claude/settings.json" CLAUDE_CONFIG_DIR="$work/claude"
export OPENCODE_CONFIG_DIR="$work/opencode" ROOST_SOCKET="$sock" ROOST_NO_SHIM=1
export ROOST_RECORD_DIR="$work/records" ROOST_EVENTS="$work/events"
unset TMUX TMUX_PANE ZDOTDIR
mkdir -p "$HOME"
T() { tmux -S "$sock" "$@"; }
R() { "$ROOST" "$@"; }
id_of() { T show-options -pqv -t "$1" @roost-id; }
in_pane() { local p="$1"; shift; env TMUX="$sock,$(T display -p '#{pid}'),0" TMUX_PANE="$p" "$@"; }
valid() { roost_pane_id_parse "$1" && [ "$1" = "$ROOST_PANE_ID" ]; }

changed="$(awk '/^## / { if (active) exit; active = ($0 ~ /Unreleased/) } active && /^### / { changed = ($0 == "### Changed") } active && changed' "$HERE/CHANGELOG.md")"
assert_contains "$changed" 'roost whoami' "Unreleased Changed calls out the new whoami output"
assert_contains "$changed" 'roost status' "Unreleased Changed calls out the leading status ID"
assert_contains "$changed" 'p-` are read as pane IDs' "Unreleased Changed calls out the reserved address prefix"

# All single-symbol substitutions and distinct adjacent swaps for each of 64
# random codewords, including the fixed prefix and the check digit.
check_typos() {
  local n i j digit compact mutant second
  for ((n=0; n<64; n++)); do
    roost_pane_id__new && valid "$ROOST_PANE_ID" || return 1
    compact="${ROOST_PANE_ID//-/}"
    for ((i=0; i<8; i++)); do
      for ((j=0; j<32; j++)); do
        digit="${ROOST_PANE_ID_ALPHABET:j:1}"
        [ "$digit" = "${compact:i:1}" ] && continue
        mutant="${compact:0:i}$digit${compact:i+1}"
        if roost_pane_id_parse "${mutant:0:1}-${mutant:1}"; then printf 'accepted substitution %s -> %s\n' "$compact" "$mutant"; return 1; fi
      done
      [ "$i" -lt 7 ] || continue
      digit="${compact:i:1}"; second="${compact:i+1:1}"
      [ "$digit" = "$second" ] && continue
      mutant="${compact:0:i}$second$digit${compact:i+2}"
      if roost_pane_id_parse "${mutant:0:1}-${mutant:1}"; then printf 'accepted swap %s -> %s\n' "$compact" "$mutant"; return 1; fi
    done
  done
  return 0
}
check_typos; assert_true $? "the check rejects all substitutions and adjacent swaps in 64 generated IDs"
roost_pane_id_parse 'P-OOO-IOO-8'; folded_rc=$?
assert_eq "$folded_rc|$ROOST_PANE_ID" '0|p-000-100-8' "case, O, I and hyphens fold to one spelling"
roost_pane_id_parse 'p--o0ol0-08'; assert_eq "$ROOST_PANE_ID" p-000-100-8 "lowercase L folds to 1"

T -f /dev/null new-session -d -x 200 -y 50 -s main 'ENV= exec /bin/sh' || exit 1
caller="$(T display -p '#{pane_id}')"
assert_eq "$(id_of "$caller")" '' "a manually opened pane starts without an ID"
me="$(in_pane "$caller" "$ROOST" whoami)"
valid "$me"; assert_true $? "whoami adopts the caller and prints its stable ID"
T set -p -t "$caller" @roost-role coordinator
assert_contains "$(R status)" "$me coordinator  $caller" "status puts the ID and role before the tmux number"
assert_contains "$(R status --json)" "\"roost_id\":\"$me\",\"role\":\"coordinator\",\"id\":\"$caller\"" "status JSON includes the stable ID and role"
context="$(in_pane "$caller" "$HERE/scripts/roost-session-context" </dev/null)"
assert_contains "$context" "This pane is $me ($caller)" "SessionStart leads with the stable ID"
assert_contains "$context" "roost send $me" "SessionStart gives the stable address for replies"

worker="$(R spawn worker "exec /bin/sh '$HERE/tests/fixtures/turn-agent.sh' '$HERE/scripts/roost-agent-state' 0 0.5")"
require_pane "$worker" worker
id="$(id_of "$worker")"
valid "$id"; assert_true $? "spawn assigned an ID before returning"
other="$(R split -h -t "$id" -n helper 'exec sleep 120')"
require_pane "$other" helper
assert_eq "$(T display -p -t "$other" '#{window_id}')" "$(T display -p -t "$worker" '#{window_id}')" "split -t accepts a stable ID"
other_id="$(id_of "$other")"
valid "$other_id"; assert_true $? "split assigned the new pane its own ID"
view="$(in_pane "$caller" "$ROOST" view -n logs 'exec sleep 120' 2>/dev/null)"
require_pane "$view" view
valid "$(id_of "$view")"; assert_true $? "view assigned an ID before returning"

# The typo is also a real tmux window name. A bad check must refuse before
# falling through to the name or touching either pane's input.
check=0; [ "${id: -1}" != 0 ] || check=1
bad="${id%?}$check"
decoy="$(T new-window -d -P -F '#{pane_id}' -n "$bad" 'exec cat')"
before="$(T capture-pane -pt "$worker")$(T capture-pane -pt "$decoy")"
out="$(R send "$bad" 'printf SHOULD-NOT-ARRIVE' 2>&1)"; rc=$?
assert_eq "$rc" 2 "send refuses a bad check even when a tmux window has that name"
assert_contains "$out" 'not a valid pane id' "the bad check has a specific diagnostic"
assert_eq "$(T capture-pane -pt "$worker")$(T capture-pane -pt "$decoy")" "$before" "the bad ID typed no keys on either pane"
for bad_alias in p-OOOIOO9 "$id." "${id%?}"; do
  decoy_alias="$(T new-window -d -P -F '#{pane_id}' -n "$bad_alias" 'exec cat')"
  out="$(R send "$bad_alias" MUST-NOT-ARRIVE 2>&1)"; rc=$?
  assert_eq "$rc" 2 "refuse a malformed p- address ($bad_alias)"
  assert_contains "$out" 'not a valid pane id' "malformed input stays in the pane ID namespace"
  assert_eq "$(T capture-pane -pt "$decoy_alias")" '' "the matching window got no keys"
done
for name in postgres payments packages perftest pooo1oo9; do
  named="$(T new-window -d -P -F '#{pane_id}' -n "$name" 'exec cat')"
  assert_contains "$(R screen --json "$name")" "\"pane\":\"$named\"" "ordinary window name $name still resolves"
done
assert_contains "$(R screen --json "main:$bad")" "\"pane\":\"$decoy\"" "a qualified p- window name still resolves"
proj="$(T new-session -d -P -F '#{pane_id}' -s p-proj -n web 'exec cat')"
assert_contains "$(R screen --json p-proj:0)" "\"pane\":\"$proj\"" 'a colon qualifies a p- session with a numeric window'
project_split="$(T split-window -d -P -F '#{pane_id}' -t p-proj:web 'exec cat')"
assert_contains "$(R screen --json p-proj:web.1)" "\"pane\":\"$project_split\"" 'a colon qualifies a p- session with a named window and pane'
R send p-proj:web.1 'QUALIFIED-PANE-INPUT' >/dev/null 2>&1
assert_true $? 'send accepts a session-qualified p- target'
assert_contains "$(T capture-pane -pt "$project_split")" QUALIFIED-PANE-INPUT 'the qualified target receives the input'
stamp_tmux() {
  if [ "$1" = if-shell ]; then
    T display-message -p -t "$4" "$5" > "$work/stamp-predicate"
  fi
  T "$@"
}
if roost_pane_id_restore stamp_tmux "$decoy" "$id"; then collision_rejected=1; else collision_rejected=0; fi
assert_eq "$collision_rejected" 0 "a saved ID already present on the live server cannot be assigned to another pane"
assert_eq "$(cat "$work/stamp-predicate")" 1 "the duplicate predicate without a boot expands to 1"
unstamped="$(T new-window -d -P -F '#{pane_id}' -n unstamped 'exec cat')"
roost_pane_id_ensure stamp_tmux "$unstamped"
assert_true $? "an unused ID can be stamped without a boot"
assert_eq "$(cat "$work/stamp-predicate")" 0 "the unused ID predicate without a boot expands to 0"
fresh="$(id_of "$unstamped")"
T set -pu -t "$unstamped" @roost-id
boot="$(T display-message -p -t "$unstamped" '#{start_time}-#{pid}')"
if roost_pane_id__stamp T "$unstamped" "$fresh" "0-${boot#*-}"; then mismatched=0; else mismatched=1; fi
assert_eq "$mismatched|$(id_of "$unstamped")" '1|' "a mismatched boot rejects adoption without writing an ID"
roost_pane_id_ensure T "$unstamped" "" "$boot"
assert_true $? "a matching boot accepts adoption"
valid "$(id_of "$unstamped")"; assert_true $? "adoption on the matching boot writes a valid ID"
valid "$(id_of "$decoy")"; decoy_stamped=$?
assert_eq "$decoy_stamped" 1 "before status, the hand-made decoy has no ID"
R status >/dev/null
valid "$(id_of "$decoy")"; assert_true $? "status adopts a pane opened by hand"

in_pane "$worker" "$HERE/scripts/roost-agent-state" idle </dev/null
upper="P-$(printf '%s' "${id#p-}" | tr -d '-' | tr '[:lower:]' '[:upper:]')"
out="$(in_pane "$caller" "$ROOST" send "$upper" '/clear' 2>"$work/send.err")"; rc=$?
assert_eq "$rc|$out" "0|$worker 1" "send accepts an uppercase compact ID and reaches the right pane"
R wait-done --turn 1 "$id" 10 >/dev/null; assert_true $? "wait-done --turn accepts a stable ID"
reply="$(R read --json --turn 1 "$upper")"
assert_contains "$reply" "\"target\":\"$upper\"" "read JSON keeps the address as typed"
assert_contains "$reply" "REPLY-TO[/clear]" "the command arrives literally from a roost caller"
assert_contains "$reply" "\"sent_by\":\"pane:$me\"" "the kept reply names the stable sender"
assert_contains "$(R screen "$id")" '/clear' "screen accepts a stable ID"
assert_contains "$(R events --pane "$id")" "\"pane\":\"$worker\"" "events filters by the resolved pane"
R answer "$id" --deny >/dev/null 2>"$work/answer.err"; assert_eq $? 6 "answer resolves the ID and sees no blocked dialog"
R revive "$other_id" >/dev/null 2>"$work/revive.err"; assert_eq $? 13 "revive resolves the ID and sees no conversation key"
R forget "$id" >/dev/null; assert_true $? "forget finds the pane's kept reply by stable ID"

# The old sender prefix shortened the head match so that the old brief on
# screen hid a lost new send. The receiver swallows input without echo.
swallow="$(T new-window -d -P -F '#{pane_id}' \
  "stty -echo; printf '%s\\n' '[from $me] Read /tmp/briefs/first.md'; exec cat >/dev/null")"
for ((i=0; i<100; i++)); do
  T capture-pane -pt "$swallow" | grep -q 'first.md' && break
  sleep 0.05
done
T set -p -t "$swallow" @agent_state idle
T set -g @roost-send-ready-timeout 0
T set -g @roost-send-turn-timeout 0
out="$(in_pane "$caller" "$ROOST" send "$swallow" 'Read /tmp/briefs/second.md' 2>&1)"; rc=$?
assert_eq "$rc" 1 "the earlier brief does not hide the loss of the new prompt"
assert_contains "$out" 'could not confirm the message reached' "lost delivery fails visibly"
T set -gu @roost-send-ready-timeout
T set -gu @roost-send-turn-timeout

# Make the next draw deterministic: first issue the all-zero payload onto a
# known pane, close it, then force the allocator to draw that payload again.
# A fake od returns those bytes once and delegates to the real RNG after that.
retired=p-000-000-0
retiring="$(T new-window -d -P -F '#{pane_id}' 'exec sleep 120')"
roost_pane_id_restore T "$retiring" "$retired" || exit 1
R close --force "$retired" >/dev/null; assert_true $? "close accepts a stable ID"
real_od="$(command -v od)"
mkdir "$work/bin"
cat > "$work/bin/od" <<'SCRIPT'
#!/bin/sh
if [ ! -f "$PANE_ID_DRAW" ]; then
  : > "$PANE_ID_DRAW"
  printf '0 0 0 0 0 0\n'
else
  exec "$PANE_ID_REAL_OD" "$@"
fi
SCRIPT
chmod +x "$work/bin/od"
fresh="$(PANE_ID_DRAW="$work/draw" PANE_ID_REAL_OD="$real_od" PATH="$work/bin:$PATH" R spawn fresh 'exec sleep 120')"
[ -f "$work/draw" ] && [ -f "$XDG_STATE_HOME/roost/pane-ids/00/$retired" ] && valid "$(id_of "$fresh")" && [ "$(id_of "$fresh")" != "$retired" ]
assert_true $? "spawning after close rejects the already issued random payload"

payments_pane="$(T new-session -d -P -F '#{pane_id}' -s payments 'exec sleep 120')"
roost_pane_id_ensure T "$payments_pane" || exit 1
R save --to "$work/shape" >/dev/null || exit 1
assert_contains "$(cat "$work/shape")" "roost_id $me" "save keeps the original ID"
sed -e "s/^roost_id $id\$/roost_id p-000-100-9/" -e "/^roost_id $other_id\$/d" "$work/shape" > "$work/old-shape"
T kill-server >/dev/null 2>&1 || true
# A fresh socket keeps the test independent of when an exiting tmux 3.4
# server removes the old socket. The archive and ID ledger stay the same.
mkdir "$work/restored"
sock="$work/restored/roost"; export ROOST_SOCKET="$sock"
# Start another boot with %0 used elsewhere so a lookup by an old numeric
# sender ID cannot pass this test by accident.
T -f /dev/null new-session -d -x 200 -y 50 -s unrelated 'ENV= exec /bin/sh' || exit 1
R restore --dry-run --from "$work/shape" --only "$me" >/dev/null; assert_true $? "restore --only selects a pane by stable ID"
R restore --dry-run --from "$work/shape" --only payments >/dev/null; assert_true $? "restore --only accepts the session name payments"
R restore --dry-run --from "$work/shape" --only '=p-proj' >/dev/null; assert_true $? "restore --only accepts an exact p- session"
R restore --dry-run --from "$work/shape" --only '=p-proj:0' >/dev/null; assert_true $? "restore --only accepts an exact p- session's window"
R restore --dry-run --from "$work/shape" --only 'p-proj:0' >/dev/null; assert_true $? "restore --only accepts the qualified p- session's window"
out="$(R restore --no-resume --from "$work/old-shape" 2>"$work/restore.err")"; rc=$?
assert_eq "$rc" 0 "restore accepts a shape with intact, missing and damaged pane IDs"
restored="$(T list-panes -a -F '#{pane_id} #{@roost-id}' | awk -v id="$me" '$2==id {print $1}')"
[ -n "$restored" ] && [ "$restored" != "$caller" ]; assert_true $? "restore kept the sender ID on a different tmux number"
restored_worker="$(T list-panes -a -F '#{pane_id} #{@roost-name}' | awk '$2=="worker" {print $1}')"
valid "$(id_of "$restored_worker")" && [ "$(id_of "$restored_worker")" != "$id" ]
assert_true $? "the pane with the damaged field receives a new ID"
restored_helper="$(T list-panes -a -F '#{pane_id} #{@roost-name}' | awk '$2=="helper" {print $1}')"
valid "$(id_of "$restored_helper")" && [ "$(id_of "$restored_helper")" != "$other_id" ]
assert_true $? "a pane from an old block receives a new ID"
R send "$me" "printf 'REPLY-%s\\n' RECEIVED" >/dev/null 2>"$work/return.err"; assert_true $? "the recorded sender ID still routes after restore"
for ((i=0; i<100; i++)); do
  screen="$(T capture-pane -pt "$restored")"
  [[ "$screen" == *REPLY-RECEIVED* ]] && break
  sleep 0.05
done
assert_contains "$screen" REPLY-RECEIVED "the reply reaches the restored pane"

live_payments="$(T display -pt payments:0 '#{pane_id}')"
payments_id="$(id_of "$live_payments")"
T move-window -s payments:0 -t main:99 || exit 1
R restore --only payments --no-resume --from "$work/shape" >/dev/null 2>"$work/collision.err"; rc=$?
assert_eq "$rc" 0 "an already-live saved ID does not change the restore outcome"
assert_contains "$(cat "$work/collision.err")" "could not keep its pane id $payments_id" "restore warns about the occupied ID"
new_payments_id="$(id_of "$(T display -pt payments:0 '#{pane_id}')")"
valid "$new_payments_id" && [ "$new_payments_id" != "$payments_id" ]
assert_true $? "the placed pane gets a fresh ID"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
