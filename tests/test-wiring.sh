#!/usr/bin/env bash
# roost-owned wiring (#58): the claude shim, the generated hooks-only settings
# file, opencode's config directory, and every back-out route.
#
# docs/airig/specs/2026-09-15-roost-owned-settings-design.md is the spec. Its
# "Measured" section is where the facts these tests lean on come from: that a
# client-created pane never gets the server's PATH (M1), that `--settings`
# overrides only the keys it sets and that identical hook commands run once
# (M4, M4b), and that the shim must not need `tmux` on the pane's PATH to read
# the server switch (M3).
#
# No real claude runs here. Every `claude` is a fake that prints the argv it
# was handed, written fresh into a scratch directory — never a symlink to a
# real binary, because `>` onto a symlink writes through it into the real tool.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
SHIM="$HERE/shims/claude"
WIRING="$HERE/scripts/roost-wiring"
TMUXBIN="$(command -v tmux)"

TMP="$(mktemp -d /tmp/amx.XXXX)"
trap 'for s in "$TMP"/*/sock/roost; do [ -S "$s" ] && tmux -S "$s" kill-server 2>/dev/null; done; rm -rf "$TMP"' EXIT

# --- the sandbox canary -----------------------------------------------------
# Every home anything in this file could write to, exported at one directory
# nothing may touch. Each case below overrides these for its own box; a case
# that forgets one lands its write here, and the check at the bottom names it.
# Copied in shape from tests/test-install.sh and tests/test-doctor.sh.
CANARY="$TMP/canary"
export HOME="$CANARY/home"
export XDG_CONFIG_HOME="$CANARY/xdg-config"
export CLAUDE_SETTINGS="$CANARY/claude/settings.json"
export COPILOT_HOME="$CANARY/copilot"
export PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export CODEX_HOME="$CANARY/codex"
unset ROOST_NO_SHIM ROOST_TMUX ROOST_WIRING_DIR OPENCODE_CONFIG_DIR TMUX TMUX_PANE ROOST_SOCKET

# box NAME -> a fresh sandbox: $B/home, $B/xdg, $B/real (a fake claude), $B/sock
box() {
  B="$TMP/$1"
  mkdir -p "$B/home" "$B/xdg" "$B/real" "$B/sock" "$B/out"
  printf '#!/bin/sh\nprintf "REAL"; for a in "$@"; do printf " %%s" "$a"; done; printf "\\n"\n' > "$B/real/claude"
  chmod +x "$B/real/claude"
}

# srv -> start a bare tmux server whose socket path ends in /roost, which is
# the one shape roost's hooks and its shim treat as roost (lib/roost-socket.sh).
srv() { tmux -S "$B/sock/roost" -f /dev/null new-session -d -s main -x 120 -y 30 'sleep 600'; }

# shim_run [VAR=VAL ...] -- ARGS... : run the shim with an empty environment
# plus exactly what the caller names, so nothing from the developer's shell (a
# real TMUX, a real ROOST_NO_SHIM) can decide a case.
shim_run() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  # Under a 10-second watchdog. A shim that finds ITSELF as the real claude
  # execs itself forever, adding --settings each time; without a limit that is
  # a test that hangs rather than one that fails (the marker-skip mutation did
  # exactly that, for 900 seconds, twice). An `alarm` before exec did NOT stop
  # it on macOS, so the limit is a kill of the pid, which every exec in the
  # chain keeps.
  local out="$B/out/shim_run.$$.$RANDOM"
  env -i HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" "${envs[@]}" "$SHIM" "$@" >"$out" 2>&1 &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -gt 100 ]; then
      kill -9 "$pid" 2>/dev/null
      printf 'SHIM TIMED OUT (a loop)\n' >>"$out"
      break
    fi
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
  local rc=$?
  cat "$out"; rm -f "$out"
  return "$rc"
}

settings_of() { printf '%s/roost/wiring/claude/settings.json' "$1"; }

# =============================================================================
printf '\n== generated settings: hooks only, and the same commands as roost install ==\n'
box gen
srv
ROOST_SOCKET="$B/sock/roost" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" \
  "$WIRING" apply >"$B/out/apply" 2>&1
assert_eq "$?" "0" "roost wiring apply exits 0 on a roost server"
gen="$(settings_of "$B/xdg")"
[ -f "$gen" ]; assert_true $? "apply writes wiring/claude/settings.json under XDG_CONFIG_HOME"

keys="$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])).keys())))' "$gen" 2>&1)"
assert_eq "$keys" "hooks" "the generated file has exactly one top-level key, hooks — it overrides no user setting"

# The upgrade path from a machine that already ran `roost install`: the same
# six (event, matcher, command) triples, byte for byte. Claude runs an
# identical command once when it appears in two sources (design M4b), so this
# equality is what makes "hooks fire once" true — a single differing byte
# makes every hook run twice.
HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" CLAUDE_SETTINGS="$B/home/.claude/settings.json" \
COPILOT_HOME="$B/home/.copilot" PI_CODING_AGENT_DIR="$B/home/.pi/agent" CODEX_HOME="$B/home/.codex" \
  "$ROOST" install --only claude --yes </dev/null >"$B/out/install" 2>&1
triples() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
out = []
for ev, groups in d.get("hooks", {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            out.append("%s\t%s\t%s" % (ev, g.get("matcher"), h.get("command")))
print("\n".join(sorted(out)))
PY
}
want="$(triples "$B/home/.claude/settings.json")"
got="$(triples "$gen")"
[ -n "$want" ]; assert_true $? "roost install wrote claude hooks into the sandbox (the comparison below is not two empty strings)"
assert_eq "$got" "$want" "upgrade: every generated hook command is identical to the one roost install wrote, so each runs once"
assert_eq "$(printf '%s\n' "$got" | grep -c .)" "6" "the generated file carries all six roost hook entries"

oc="$B/xdg/roost/wiring/opencode/plugin/roost.js"
[ -L "$oc" ] && [ "$oc" -ef "$HERE/adapters/opencode/roost.js" ]
assert_true $? "apply links wiring/opencode/plugin/roost.js to this checkout's adapter"

g() { tmux -S "$B/sock/roost" "$@"; }
assert_eq "$(g show-environment -g OPENCODE_CONFIG_DIR 2>/dev/null)" \
  "OPENCODE_CONFIG_DIR=$B/xdg/roost/wiring/opencode" "apply sets OPENCODE_CONFIG_DIR on the server"
assert_eq "$(g show-environment -g ROOST_TMUX 2>/dev/null)" "ROOST_TMUX=$TMUXBIN" \
  "apply exports the absolute tmux path as ROOST_TMUX, so the shim can read the switch without tmux on PATH"
assert_eq "$(g show-environment -g ROOST_WIRING_DIR 2>/dev/null)" "ROOST_WIRING_DIR=$B/xdg/roost/wiring" \
  "apply exports ROOST_WIRING_DIR"
assert_contains "$(g show-options -gqv default-command)" "$HERE/scripts/roost-pane-shell" \
  "apply sets default-command to roost-pane-shell"
assert_eq "$(g show-options -gqv @roost-wiring-active)" "on" "apply marks the server wired"

# =============================================================================
printf '\n== apply leaves a non-roost socket, a user default-command and a user OPENCODE_CONFIG_DIR alone ==\n'
box notroost
tmux -S "$B/sock/other" -f /dev/null new-session -d -s main 'sleep 600'
ROOST_SOCKET="$B/sock/other" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" "$WIRING" apply >/dev/null 2>&1
[ ! -e "$B/xdg/roost/wiring" ]; assert_true $? "a socket not named roost gets no wiring and no files"
assert_eq "$(tmux -S "$B/sock/other" show-options -gqv default-command)" "" "a socket not named roost keeps an empty default-command"
tmux -S "$B/sock/other" kill-server 2>/dev/null

box userdc
srv
g set-option -g default-command "exec /bin/sh"
g set-environment -g OPENCODE_CONFIG_DIR /users/own/dir
ROOST_SOCKET="$B/sock/roost" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" "$WIRING" apply >/dev/null 2>&1
assert_eq "$(g show-options -gqv default-command)" "exec /bin/sh" "a default-command the user set is never replaced"
assert_eq "$(g show-environment -g OPENCODE_CONFIG_DIR)" "OPENCODE_CONFIG_DIR=/users/own/dir" \
  "an OPENCODE_CONFIG_DIR the user set is never replaced"

# =============================================================================
printf '\n== @roost-wiring-enabled off and the wiring.off marker stop apply entirely ==\n'
box cfgoff
srv
g set-option -g @roost-wiring-enabled off
ROOST_SOCKET="$B/sock/roost" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" "$WIRING" apply >/dev/null 2>&1
[ ! -e "$B/xdg/roost/wiring" ]; assert_true $? "@roost-wiring-enabled off: apply writes nothing"
assert_eq "$(g show-options -gqv default-command)" "" "@roost-wiring-enabled off: no default-command — today's behaviour"
g show-environment -g OPENCODE_CONFIG_DIR >/dev/null 2>&1; assert_eq "$?" "1" "@roost-wiring-enabled off: no OPENCODE_CONFIG_DIR"

box marker
srv
mkdir -p "$B/xdg/roost"; : > "$B/xdg/roost/wiring.off"
ROOST_SOCKET="$B/sock/roost" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" "$WIRING" apply >/dev/null 2>&1
[ ! -e "$B/xdg/roost/wiring" ]; assert_true $? "wiring.off marker: apply writes nothing"
assert_eq "$(g show-options -gqv default-command)" "" "wiring.off marker: no default-command"

# =============================================================================
printf '\n== the shim: scope, recursion, and the per-run bypass ==\n'
box shim
mkdir -p "$B/xdg/roost/wiring/claude"; echo '{"hooks":{}}' > "$(settings_of "$B/xdg")"
set_ok="--settings $(settings_of "$B/xdg")"
P="$HERE/shims:$B/real:/usr/bin:/bin"

assert_eq "$(shim_run PATH="$P" TMUX="/x/roost,1,0" -- -p hi)" "REAL $set_ok -p hi" \
  "inside a roost server the shim adds --settings"
assert_eq "$(shim_run PATH="$P" -- -p hi)" "REAL -p hi" "outside tmux the argv is untouched"
assert_eq "$(shim_run PATH="$P" TMUX="/x/default,1,0" -- -p hi)" "REAL -p hi" \
  "inside some other tmux server the argv is untouched"
assert_eq "$(shim_run PATH="$P" TMUX="/x/roost,1,0" ROOST_NO_SHIM=1 -- -p hi)" "REAL -p hi" \
  "ROOST_NO_SHIM=1 runs the real claude with no roost settings"
assert_eq "$(shim_run PATH="$P" TMUX="/x/roost,1,0" ROOST_NO_SHIM= -- -p hi)" "REAL $set_ok -p hi" \
  "an EMPTY ROOST_NO_SHIM is not a request to bypass"
assert_eq "$(shim_run PATH="$HERE/shims:$HERE/shims:$B/real:/usr/bin:/bin" TMUX="/x/roost,1,0" -- hi)" \
  "REAL $set_ok hi" "the shim directory twice on PATH: no recursion, one --settings"
out="$(shim_run PATH="$HERE/shims:/usr/bin:/bin" TMUX="/x/roost,1,0" -- hi; echo "rc=$?")"
assert_contains "$out" "roost: no claude found on PATH after roost's shim" "no real claude on PATH: the shim says so"
assert_contains "$out" "rc=127" "no real claude on PATH: exit 127, never a loop"
rm "$(settings_of "$B/xdg")"
assert_eq "$(shim_run PATH="$P" TMUX="/x/roost,1,0" -- hi)" "REAL hi" "settings file missing: argv untouched"
echo '{"hooks":{}}' > "$(settings_of "$B/xdg")"
assert_eq "$(shim_run PATH="$P" TMUX="/x/roost,1,0" ROOST_WIRING_DIR="$B/elsewhere" -- hi)" "REAL hi" \
  "ROOST_WIRING_DIR names where the settings are; a directory without them means no --settings"

# =============================================================================
printf '\n== the shim: the server switch, read through ROOST_TMUX ==\n'
srv
S="$B/sock/roost"
g set-option -g @roost-wiring-enabled off
assert_eq "$(shim_run PATH="$HERE/shims:$B/real:$(dirname "$TMUXBIN"):/usr/bin:/bin" TMUX="$S,1,0" -- hi)" "REAL hi" \
  "@roost-wiring-enabled off: the shim runs the real claude with no settings"
assert_eq "$(shim_run PATH="$P" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN" -- hi)" "REAL hi" \
  "the switch is read through ROOST_TMUX when tmux is not on the pane's PATH"
g set-option -gu @roost-wiring-enabled
assert_eq "$(shim_run PATH="$P" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN" -- hi)" "REAL $set_ok hi" \
  "switch cleared: --settings again"

# =============================================================================
printf '\n== panes: default-command and spawn put the shim first ==\n'
box panes
# A stand-in login shell: tmux runs default-command through it with -c, and
# roost-pane-shell execs it with -l. The -l call records what claude resolves
# to, then waits.
cat > "$B/recsh" <<EOF
#!/bin/sh
case "\$1" in
  -c) exec /bin/sh -c "\$2" ;;
  -l) printf '%s\n' "\$(command -v claude)" > "$B/out/login-claude"; exec sleep 600 ;;
esac
exec /bin/sh "\$@"
EOF
chmod +x "$B/recsh"
S="$B/sock/roost"
PATH_BOX="$B/real:/usr/bin:/bin:$(dirname "$TMUXBIN")"
env PATH="$PATH_BOX" SHELL="$B/recsh" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" ROOST_SOCKET="$S" \
  "$ROOST" spawn first 'sleep 600' >/dev/null 2>&1
assert_eq "$(tmux -S "$S" show-options -gqv @roost-wiring-active)" "on" "a server started by roost spawn is wired"
# A window from a client with no command — the prefix-c shape.
env PATH="$PATH_BOX" tmux -S "$S" new-window -t main: 2>/dev/null
for _ in $(seq 1 40); do [ -s "$B/out/login-claude" ] && break; sleep 0.1; done
assert_eq "$(cat "$B/out/login-claude" 2>/dev/null)" "$HERE/shims/claude" \
  "a client-created pane with no command resolves claude to roost's shim"
env PATH="$PATH_BOX" SHELL="$B/recsh" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" ROOST_SOCKET="$S" \
  "$ROOST" spawn second "command -v claude > '$B/out/spawn-claude'; sleep 600" >/dev/null 2>&1
for _ in $(seq 1 40); do [ -s "$B/out/spawn-claude" ] && break; sleep 0.1; done
assert_eq "$(cat "$B/out/spawn-claude" 2>/dev/null)" "$HERE/shims/claude" \
  "roost spawn NAME CMD resolves claude to roost's shim"
env PATH="$PATH_BOX" SHELL="$B/recsh" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" ROOST_SOCKET="$S" \
  TMUX_PANE="$(tmux -S "$S" list-panes -t main:1 -F '#{pane_id}' | head -1)" \
  "$ROOST" split -t "$(tmux -S "$S" list-panes -t main:1 -F '#{pane_id}' | head -1)" \
  "command -v claude > '$B/out/split-claude'; sleep 600" >/dev/null 2>&1
for _ in $(seq 1 40); do [ -s "$B/out/split-claude" ] && break; sleep 0.1; done
assert_eq "$(cat "$B/out/split-claude" 2>/dev/null)" "$HERE/shims/claude" \
  "roost split CMD resolves claude to roost's shim"
env PATH="$PATH_BOX" SHELL="$B/recsh" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" ROOST_SOCKET="$S" \
  "$ROOST" spawn argv /bin/sh -c "command -v claude > '$B/out/argv-claude'; sleep 600" >/dev/null 2>&1
for _ in $(seq 1 40); do [ -s "$B/out/argv-claude" ] && break; sleep 0.1; done
assert_eq "$(cat "$B/out/argv-claude" 2>/dev/null)" "$HERE/shims/claude" \
  "roost spawn NAME with a multi-word argv still runs it, with the shim first"

# =============================================================================
printf '\n== roost wiring off / on, for the server and for one session ==\n'
w() { env HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" PATH="$PATH" ROOST_SOCKET="$S" "$ROOST" wiring "$@" 2>&1; }
tmux -S "$S" new-session -d -s other 'sleep 600'

w off -t other >/dev/null; assert_eq "$?" "0" "roost wiring off -t SESSION exits 0"
assert_eq "$(tmux -S "$S" show-environment -t other ROOST_NO_SHIM 2>/dev/null)" "ROOST_NO_SHIM=1" \
  "off -t SESSION sets ROOST_NO_SHIM in that session's environment"
assert_eq "$(tmux -S "$S" show-environment -t other OPENCODE_CONFIG_DIR 2>/dev/null)" "-OPENCODE_CONFIG_DIR" \
  "off -t SESSION removes OPENCODE_CONFIG_DIR for that session"
tmux -S "$S" show-environment -t main ROOST_NO_SHIM >/dev/null 2>&1
assert_eq "$?" "1" "off -t SESSION leaves other sessions alone"
w on -t other >/dev/null
tmux -S "$S" show-environment -t other ROOST_NO_SHIM >/dev/null 2>&1
assert_eq "$?" "1" "on -t SESSION clears ROOST_NO_SHIM there"
tmux -S "$S" show-environment -t other OPENCODE_CONFIG_DIR >/dev/null 2>&1
assert_eq "$?" "1" "on -t SESSION clears the session's OPENCODE_CONFIG_DIR override"

w off >/dev/null; assert_eq "$?" "0" "roost wiring off exits 0"
assert_eq "$(tmux -S "$S" show-options -gqv @roost-wiring-enabled)" "off" "off sets @roost-wiring-enabled off"
assert_eq "$(tmux -S "$S" show-options -gqv default-command)" "" "off removes roost's default-command"
tmux -S "$S" show-environment -g OPENCODE_CONFIG_DIR >/dev/null 2>&1
assert_eq "$?" "1" "off removes roost's OPENCODE_CONFIG_DIR"
out="$(env -i PATH="$PATH_BOX" SHELL="$B/recsh" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" ROOST_SOCKET="$S" \
  "$ROOST" spawn third "printf '%s' \"\$PATH\" > '$B/out/off-path'; sleep 600" >/dev/null 2>&1)"
for _ in $(seq 1 40); do [ -e "$B/out/off-path" ] && break; sleep 0.1; done
case "$(cat "$B/out/off-path" 2>/dev/null)" in *"$HERE/shims"*) r=1 ;; '') r=2 ;; *) r=0 ;; esac
assert_eq "$r" "0" "while off, roost spawn does not put the shim on PATH"

w on >/dev/null; assert_eq "$?" "0" "roost wiring on exits 0"
tmux -S "$S" show-options -gq @roost-wiring-enabled | grep -q .
assert_eq "$?" "1" "on clears @roost-wiring-enabled"
assert_contains "$(tmux -S "$S" show-options -gqv default-command)" "roost-pane-shell" "on restores default-command"
assert_eq "$(tmux -S "$S" show-environment -g OPENCODE_CONFIG_DIR 2>/dev/null)" \
  "OPENCODE_CONFIG_DIR=$B/xdg/roost/wiring/opencode" "on restores OPENCODE_CONFIG_DIR"

# =============================================================================
printf '\n== roost wiring remove, then on ==\n'
w remove >"$B/out/remove"; assert_eq "$?" "0" "roost wiring remove exits 0"
[ ! -e "$B/xdg/roost/wiring" ]; assert_true $? "remove deletes the wiring directory"
[ -e "$B/xdg/roost/wiring.off" ]; assert_true $? "remove writes the wiring.off marker"
assert_eq "$(tmux -S "$S" show-options -gqv default-command)" "" "remove turns the running server off too"
mkdir -p "$B/xdg/roost"; echo "# the user's own conf" > "$B/xdg/roost/roost.conf"
w remove >/dev/null
assert_eq "$(cat "$B/xdg/roost/roost.conf")" "# the user's own conf" "remove never touches the user's roost.conf"
w on >/dev/null
[ ! -e "$B/xdg/roost/wiring.off" ]; assert_true $? "on after remove deletes the marker"
[ -f "$(settings_of "$B/xdg")" ]; assert_true $? "on after remove regenerates the settings file"

# =============================================================================
printf '\n== doctor: a row for every wiring state ==\n'
box doc
srv
S="$B/sock/roost"
doc() { env -i PATH="$1" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" CLAUDE_SETTINGS="$B/home/.claude/settings.json" \
  COPILOT_HOME="$B/home/.copilot" PI_CODING_AGENT_DIR="$B/home/.pi/agent" CODEX_HOME="$B/home/.codex" \
  ROOST_CONFIG_SOCK=/nonexistent ROOST_NOTIFY_SOCK=/nonexistent "${@:2}" "$HERE/scripts/roost-doctor" 2>&1; }
DP="$HERE/shims:$B/real:$(dirname "$TMUXBIN"):/usr/bin:/bin"
ROOST_SOCKET="$S" HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" "$WIRING" apply >/dev/null 2>&1

out="$(doc "$DP" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN" ROOST_WIRING_DIR="$B/xdg/roost/wiring")"
assert_contains "$out" "✓ claude in this pane runs through roost's shim" "doctor: on, shim first → ok"
out="$(doc "$B/real:$(dirname "$TMUXBIN"):/usr/bin:/bin" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN" ROOST_WIRING_DIR="$B/xdg/roost/wiring")"
assert_contains "$out" "! claude in this pane resolves to $B/real/claude, not roost's shim" "doctor: on, shim bypassed → warn with the path that won"
out="$(doc "$DP" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN" ROOST_NO_SHIM=1 ROOST_WIRING_DIR="$B/xdg/roost/wiring")"
assert_contains "$out" "· ROOST_NO_SHIM is set here" "doctor: ROOST_NO_SHIM → info"
out="$(doc "$DP" TMUX="$S,1,0" ROOST_WIRING_DIR="$B/xdg/roost/wiring")"
assert_contains "$out" "! ROOST_TMUX is not set to a tmux binary" "doctor: ROOST_TMUX missing → warn"
mv "$(settings_of "$B/xdg")" "$B/out/held"
out="$(doc "$DP" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN" ROOST_WIRING_DIR="$B/xdg/roost/wiring")"
assert_contains "$out" "! wiring is on but" "doctor: settings file missing → warn"
mv "$B/out/held" "$(settings_of "$B/xdg")"
out="$(doc "$DP" OPENCODE_CONFIG_DIR=/users/own/dir)"
assert_contains "$out" "· OPENCODE_CONFIG_DIR is /users/own/dir, not roost's" "doctor: a user OPENCODE_CONFIG_DIR → info"
out="$(doc "$DP")"
assert_contains "$out" "· not inside a roost pane — the claude shim check was skipped" "doctor: outside roost → info"
g set-option -g @roost-wiring-enabled off
out="$(doc "$DP" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN")"
assert_contains "$out" "· wiring is off for this roost server" "doctor: server switch off → info"
g set-option -gu @roost-wiring-enabled
: > "$B/xdg/roost/wiring.off"
out="$(doc "$DP" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN")"
assert_contains "$out" "· wiring is removed" "doctor: wiring.off marker → info"
rm "$B/xdg/roost/wiring.off"
HOME="$B/home" XDG_CONFIG_HOME="$B/xdg" CLAUDE_SETTINGS="$B/home/.claude/settings.json" \
COPILOT_HOME="$B/home/.copilot" PI_CODING_AGENT_DIR="$B/home/.pi/agent" CODEX_HOME="$B/home/.codex" \
  "$ROOST" install --only claude --yes </dev/null >/dev/null 2>&1
out="$(doc "$DP" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN" ROOST_WIRING_DIR="$B/xdg/roost/wiring")"
assert_contains "$out" "✓ the global Claude hooks and roost's wiring name the same commands, so each hook runs once" \
  "doctor: global install for this checkout → ok, runs once"
sed -i.bak "s#$HERE/scripts/#/some/other/checkout/scripts/#g" "$B/home/.claude/settings.json"
out="$(doc "$DP" TMUX="$S,1,0" ROOST_TMUX="$TMUXBIN" ROOST_WIRING_DIR="$B/xdg/roost/wiring")"
assert_contains "$out" "! the global Claude hooks name a different checkout, so every roost hook runs twice while wiring is on" \
  "doctor: global install for another checkout → warn, runs twice"

# =============================================================================
printf '\n== sandbox ==\n'
leaks="$(find "$CANARY" -mindepth 1 2>/dev/null | sort)"
assert_eq "$leaks" "" "nothing in this file wrote to the canary homes"
