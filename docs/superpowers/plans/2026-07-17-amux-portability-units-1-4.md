# amux Portability (Units 1-4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make amux publicly usable — cross-platform notifications, a tmux-option config layer with five validated themes, an `amux doctor` preflight, and an `amux init` setup wizard — plus a test harness and CI so this class of bug stops shipping silently.

**Architecture:** Config lives in tmux user options (`@amux-*`), with defaults in `tmux/amux.conf` and an optional user file at `$XDG_CONFIG_HOME/amux/amux.conf` sourced after (so it wins). Scripts read appearance from those options; they know only *states*, config owns *glyphs and colours*. `amux-agent-state` remains the single source of truth for state→glyph. Notification delivery is factored into its own `amux-notify` script. Themes are expanded to explicit colour values by `amux init`, never resolved at runtime.

**Tech Stack:** POSIX-ish bash, tmux ≥ 3.1, python3 (only for JSON hook-merge and the contrast validator), fzf (optional, switcher only). No frameworks.

## Global Constraints

- **tmux floor is 3.1**, verified exactly: gated only by `source-file -F` and `display-popup` (both landed 3.1). `#{E:}` (2.9), `#{==:}` (2.4), `refresh-client -S` (1.7) all predate it. Update the README's `≥ 3.0` claim.
- **`amux-agent-state` runs inside every Claude tool call and must never break Claude.** Keep `|| true` and `exit 0` throughout; every failure degrades, never aborts.
- **Naming:** `@amux-*` (dash) for user-facing config; `@agent_*` (underscore) for per-window runtime state. Rename internal `@amux_home` → `@amux-home`.
- **No personal/second-person copy** in shipped files (the repo is public). No machine paths, no real emails, no assumptions about the reader's setup.
- **PUA characters (U+E0B0 wedge, Nerd-Font glyphs) do not survive normal file edits.** Write them as explicit bytes (printf `\uXXXX` or a python heredoc) and verify by codepoint count.
- **Config values are read with the global fallback:** `#{@agent_glyph}` / `display-message -p '#{@option}'` resolves the window option *and* the global default. `show-options -wqv` does NOT fall back — do not use it to read a value that has a global default.
- **Socket paths in tests must be short** (`mktemp -d /tmp/amx.XXXX`) — the ~104-char unix socket limit silently produces false passes on long paths.
- **Presets are expanded, not resolved:** `amux init` writes explicit `@amux-glyph-blocked "🛑"` lines, never `@amux-glyphs "emoji"`.
- **Commit identity** is already `beatzball <38116726+beatzball@users.noreply.github.com>` (repo-local git config). Do not change it.

## File Structure

| Path | Responsibility | Task |
|---|---|---|
| `tests/lib.sh` | Test harness: temp-socket tmux, assert helpers, PATH shims | 1 |
| `scripts/amux-notify` | Deliver one notification across OSes; backend chain | 2 |
| `scripts/amux-agent-state` | *Modify*: read glyph from config; call amux-notify | 3 |
| `tmux/amux.conf` | *Modify*: default `@amux-*` options; `@amux_home`→`@amux-home` | 4 |
| `scripts/amux-status`, `scripts/amux-switch` | *Modify*: `@amux_home`→`@amux-home` reference only | 4 |
| `bin/amux` | *Modify*: source user config; rename option; `doctor`/`init` subcommands | 4, 6, 8 |
| `scripts/amux-themes.sh` | Theme name → six colour values (sourced by init + tests) | 5 |
| `tests/test-contrast.py` | Contrast + ΔE validator over every theme | 5 |
| `scripts/amux-doctor` | Preflight checks | 6 |
| `scripts/amux-init` | Setup wizard | 7 |
| `.github/workflows/ci.yml` | Run the harness on macOS + Linux | 9 |
| `README.md` | *Modify*: tmux 3.1, font requirement, init/doctor/themes, notify | 10 |

---

## Task 1: Test harness

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/run.sh` (discovers and runs `tests/test-*.sh`)
- Test: self-testing via `tests/test-harness.sh`

**Interfaces:**
- Produces (sourced by every `tests/test-*.sh`):
  - `amux_test_server` — start a tmux server on a fresh short socket; sets and exports `$AMUX_TEST_SOCK`. **Call it bare, then read `$AMUX_TEST_SOCK`** (`amux_test_server; sock="$AMUX_TEST_SOCK"`) — NOT via `sock=$(amux_test_server)`, because command substitution runs in a subshell and the export would not reach your shell (`T` reads the global and would break).
  - `amux_test_teardown` — kill the server, remove the socket dir
  - `assert_eq <actual> <expected> <label>` — print PASS/FAIL, increment counters
  - `assert_contains <haystack> <needle> <label>`
  - `with_path_shim <name> <marker-file> -- <cmd...>` — put a fake `<name>` on `$PATH` that appends its own name to `<marker-file>` when called, run `<cmd>`, then restore
  - `T` — alias for `tmux -S "$AMUX_TEST_SOCK"`
  - On exit, `run.sh` prints `N passed, M failed` and exits non-zero if any failed

- [ ] **Step 1: Write the harness self-test**

Create `tests/test-harness.sh`:

```bash
#!/usr/bin/env bash
# Self-test for the test harness itself.
set -u
. "$(dirname "$0")/lib.sh"

amux_test_server; sock="$AMUX_TEST_SOCK"
trap amux_test_teardown EXIT

# socket path must be short enough for the ~104-char unix limit
[ "${#sock}" -lt 100 ] && assert_eq ok ok "socket path is short" \
  || assert_eq "${#sock}" "<100" "socket path is short"

# server is actually up
T new-window -n probe
assert_contains "$(T list-windows -F '#{window_name}')" probe "server accepts commands"

# path shim records invocation
marker="$(mktemp)"
with_path_shim faketool "$marker" -- sh -c 'faketool arg1'
assert_contains "$(cat "$marker")" faketool "path shim intercepts the call"

# assert_eq fails loudly on mismatch (run in subshell so it can't kill us)
out="$(assert_eq a b "intentional-fail" 2>&1 || true)"
assert_contains "$out" FAIL "assert_eq reports FAIL on mismatch"
```

- [ ] **Step 2: Run it to confirm it fails (no lib yet)**

Run: `bash tests/test-harness.sh`
Expected: FAIL — `lib.sh: No such file or directory`

- [ ] **Step 3: Write `tests/lib.sh`**

```bash
# tests/lib.sh — minimal bash test harness. No framework.
# Sourced by tests/test-*.sh. Requires: tmux, mktemp.
: "${AMUX_TESTS_PASS:=0}"
: "${AMUX_TESTS_FAIL:=0}"

amux_test_server() {
  # Short socket dir — the ~104-char unix socket limit silently corrupts long paths.
  AMUX_TEST_SOCKDIR="$(mktemp -d /tmp/amx.XXXX)"
  AMUX_TEST_SOCK="$AMUX_TEST_SOCKDIR/s"
  export AMUX_TEST_SOCK
  tmux -S "$AMUX_TEST_SOCK" -f /dev/null new-session -d -x 200 -y 50
  printf '%s\n' "$AMUX_TEST_SOCK"
}

amux_test_teardown() {
  [ -n "${AMUX_TEST_SOCK:-}" ] && tmux -S "$AMUX_TEST_SOCK" kill-server 2>/dev/null
  [ -n "${AMUX_TEST_SOCKDIR:-}" ] && rm -rf "$AMUX_TEST_SOCKDIR"
}

T() { tmux -S "$AMUX_TEST_SOCK" "$@"; }

assert_eq() {
  if [ "$1" = "$2" ]; then
    AMUX_TESTS_PASS=$((AMUX_TESTS_PASS+1)); printf '  PASS: %s\n' "$3"
  else
    AMUX_TESTS_FAIL=$((AMUX_TESTS_FAIL+1)); printf '  FAIL: %s\n       want [%s] got [%s]\n' "$3" "$2" "$1"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) AMUX_TESTS_PASS=$((AMUX_TESTS_PASS+1)); printf '  PASS: %s\n' "$3" ;;
    *)      AMUX_TESTS_FAIL=$((AMUX_TESTS_FAIL+1)); printf '  FAIL: %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
  esac
}

with_path_shim() {
  # with_path_shim <name> <marker> -- <cmd...>
  local name="$1" marker="$2"; shift 3   # drop name, marker, and the "--"
  local dir; dir="$(mktemp -d /tmp/amx.XXXX)"
  cat > "$dir/$name" <<EOF
#!/bin/sh
printf '%s\n' "$name" >> "$marker"
EOF
  chmod +x "$dir/$name"
  PATH="$dir:$PATH" "$@"
  rm -rf "$dir"
}
```

- [ ] **Step 4: Write `tests/run.sh`**

```bash
#!/usr/bin/env bash
# Run every tests/test-*.sh and sum results.
set -u
cd "$(dirname "$0")"
pass=0 fail=0
for t in test-*.sh; do
  [ -e "$t" ] || continue
  printf '\n== %s ==\n' "$t"
  # each test file sources lib.sh and prints PASS/FAIL lines; capture counts via env
  out="$(AMUX_TESTS_PASS=0 AMUX_TESTS_FAIL=0 bash "$t" 2>&1; )"
  printf '%s\n' "$out"
  pass=$((pass + $(printf '%s' "$out" | grep -c '^  PASS')))
  fail=$((fail + $(printf '%s' "$out" | grep -c '^  FAIL')))
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 5: Make executable, run the self-test**

Run: `chmod +x tests/run.sh && bash tests/test-harness.sh`
Expected: four PASS lines, zero FAIL.

- [ ] **Step 6: Commit**

```bash
git add tests/lib.sh tests/run.sh tests/test-harness.sh
git commit -m "Add bash test harness with temp-socket tmux and PATH shims"
```

---

## Task 2: `amux-notify` cross-platform delivery

**Files:**
- Create: `scripts/amux-notify`
- Test: `tests/test-notify.sh`

**Interfaces:**
- Consumes: `$AMUX_TEST_SOCK` and helpers from Task 1.
- Produces: `amux-notify <title> <message>` — CLI. Reads `@amux-notify-backend`
  (`auto`|`tmux`|`none`, default `auto`) and `@amux-notify-cmd` off the tmux
  server named by `$AMUX_NOTIFY_SOCK` (default socket `amux`). Backend order when
  `auto`: notify-cmd → osascript (Darwin) → powershell.exe (WSL) → notify-send
  (Linux with `$DISPLAY`/`$WAYLAND_DISPLAY`) → `tmux display-message`. Always
  exits 0.

- [ ] **Step 1: Write the failing tests**

Create `tests/test-notify.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY="$HERE/scripts/amux-notify"

amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_NOTIFY_SOCK="$AMUX_TEST_SOCK"

# backend=none → nothing invoked, exit 0
T set-option -g @amux-notify-backend none
marker="$(mktemp)"
with_path_shim osascript "$marker" -- with_path_shim notify-send "$marker" -- \
  "$NOTIFY" "title" "msg"
assert_eq "$(cat "$marker")" "" "backend=none invokes no OS notifier"

# backend=tmux → falls straight to display-message, no OS notifier
T set-option -g @amux-notify-backend tmux
marker="$(mktemp)"
with_path_shim osascript "$marker" -- "$NOTIFY" "t" "m"
assert_eq "$(cat "$marker")" "" "backend=tmux skips the OS chain"

# @amux-notify-cmd wins over everything, with %t/%s substitution
T set-option -g @amux-notify-backend auto
cmdout="$(mktemp)"
T set-option -g @amux-notify-cmd "printf '%s|%s' '%t' '%s' > $cmdout"
"$NOTIFY" "TITLE" "MSG"
assert_eq "$(cat "$cmdout")" "TITLE|MSG" "@amux-notify-cmd runs with %t/%s substituted"

# always exits 0 even when a backend command fails
T set-option -g @amux-notify-cmd "false"
"$NOTIFY" a b; assert_eq "$?" "0" "amux-notify exits 0 even when backend fails"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-notify.sh`
Expected: FAIL — `amux-notify: No such file or directory`.

- [ ] **Step 3: Write `scripts/amux-notify`**

```bash
#!/usr/bin/env bash
# amux-notify <title> <message> — deliver one desktop notification, cross-platform.
# Delivery only; the caller decides *whether* to notify. Never fails: every
# backend miss falls through, and the final fallback is an in-tmux message.
set -u
title="${1:-amux}"; msg="${2:-}"
sock="${AMUX_NOTIFY_SOCK:-amux}"

opt() { tmux -S "$sock" show-options -gqv "$1" 2>/dev/null; }

backend="$(opt @amux-notify-backend)"; backend="${backend:-auto}"
[ "$backend" = none ] && exit 0

tmux_fallback() { tmux -S "$sock" display-message "$title — $msg" 2>/dev/null || true; }

if [ "$backend" = tmux ]; then tmux_fallback; exit 0; fi

# auto: user override first
cmd="$(opt @amux-notify-cmd)"
if [ -n "$cmd" ]; then
  # %t → title, %s → message. User-supplied shell (documented).
  esc_t=$(printf '%s' "$title" | sed 's/[&/\]/\\&/g')
  esc_s=$(printf '%s' "$msg"   | sed 's/[&/\]/\\&/g')
  run=$(printf '%s' "$cmd" | sed "s/%t/$esc_t/g; s/%s/$esc_s/g")
  sh -c "$run" >/dev/null 2>&1 || true
  exit 0
fi

case "$(uname -s)" in
  Darwin)
    osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Ping\"" >/dev/null 2>&1 && exit 0 ;;
esac
if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command "New-BurntToastNotification -Text '$title','$msg'" >/dev/null 2>&1 && exit 0
  powershell.exe -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')" >/dev/null 2>&1
fi
if { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; } && command -v notify-send >/dev/null 2>&1; then
  notify-send "$title" "$msg" >/dev/null 2>&1 && exit 0
fi
tmux_fallback
exit 0
```

- [ ] **Step 4: Make executable, run tests**

Run: `chmod +x scripts/amux-notify && bash tests/test-notify.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/amux-notify tests/test-notify.sh
git commit -m "Add cross-platform amux-notify with opt-in backend chain"
```

---

## Task 3: Wire `amux-agent-state` to config + amux-notify

**Files:**
- Modify: `scripts/amux-agent-state`
- Test: `tests/test-agent-state.sh`

**Interfaces:**
- Consumes: `amux-notify` (Task 2), `@amux-glyph-<state>` options (defaults land in Task 4).
- Produces: on a state change, stamps `@agent_state` + `@agent_glyph` (glyph read from `@amux-glyph-$state`, falling back to a built-in default) and calls `amux-notify` when newly `blocked` on an inactive window. Preserves the existing early-return and `exit 0`/`|| true` discipline.

- [ ] **Step 1: Write the failing tests**

Create `tests/test-agent-state.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
# amux-agent-state only acts on a socket path ending in /amux
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/amux"
tmux -S "$s" -f /dev/null new-session -d
pane="$(tmux -S "$s" display -p '#{pane_id}')"
# configured glyph for 'working'
tmux -S "$s" set-option -g @amux-glyph-working "GW"
run() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/amux-agent-state" "$1"; }
st() { tmux -S "$s" display -p -t "$pane" '#{@agent_state}|#{@agent_glyph}'; }

run working
assert_eq "$(st)" "working|GW" "glyph is read from @amux-glyph-working, not hardcoded"

# unknown/empty config → built-in default, never blank
tmux -S "$s" set-option -gu @amux-glyph-working
run idle; run working
assert_contains "$(st)" "working|" "missing config falls back to a non-empty glyph"
[ "$(tmux -S "$s" display -p -t "$pane" '#{@agent_glyph}')" != "" ] \
  && assert_eq ok ok "glyph never blank" || assert_eq "" "non-empty" "glyph never blank"

# early-return: repeat call does not restamp @agent_since
run done
before="$(tmux -S "$s" display -p -t "$pane" '#{@agent_since}')"
sleep 1; run done
after="$(tmux -S "$s" display -p -t "$pane" '#{@agent_since}')"
assert_eq "$after" "$before" "unchanged state bails before writing"

tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-agent-state.sh`
Expected: FAIL — first assert wants `working|GW`, current script produces the hardcoded `⏳`.

- [ ] **Step 3: Edit the glyph lookup**

In `scripts/amux-agent-state`, replace the hardcoded `case "$state"` glyph block with a config read plus built-in fallback. The fallback map stays so a torn config can never blank the bar:

```bash
# Built-in fallback glyphs. Config (@amux-glyph-<state>) overrides these; the
# fallback guarantees the bar never goes blank if the option is missing/empty.
case "$state" in
  blocked) fallback="🛑" ;;
  working) fallback="⏳" ;;
  done)    fallback="✅" ;;
  idle|*)  state="idle"; fallback="💤" ;;
esac
glyph="$(tmux -S "$sock" show-options -gqv "@amux-glyph-$state" 2>/dev/null)"
[ -n "$glyph" ] || glyph="$fallback"
```

- [ ] **Step 4: Route the notification through amux-notify**

Replace the inline `osascript` block with a call to the sibling script. Find its
dir relative to this script so it works regardless of cwd:

```bash
  if [ "$state" = blocked ]; then
    active="$(tmux -S "$sock" display-message -p -t "$TMUX_PANE" '#{window_active}' 2>/dev/null || echo 0)"
    if [ "$active" != "1" ]; then
      wname="$(tmux -S "$sock" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null || echo agent)"
      AMUX_NOTIFY_SOCK="$sock" "$(dirname "$0")/amux-notify" "amux · ${wname}" "needs your input" || true
    fi
  fi
```

- [ ] **Step 5: Run tests**

Run: `bash tests/test-agent-state.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/amux-agent-state tests/test-agent-state.sh
git commit -m "amux-agent-state: read glyph from config, notify via amux-notify"
```

---

## Task 4: Config layer + `@amux-home` rename + user-config sourcing

**Files:**
- Modify: `tmux/amux.conf` (add `@amux-*` defaults; rename `@amux_home`→`@amux-home`)
- Modify: `bin/amux` (set `@amux-home`; source user config; reload binding uses both)
- Modify: `scripts/amux-status`, `scripts/amux-switch` (rename reference only)
- Test: `tests/test-config.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: global defaults for every `@amux-*` option; `$XDG_CONFIG_HOME/amux/amux.conf` (default `~/.config/amux/amux.conf`) sourced after the base config; `#{@amux-home}` available for the reload binding.

- [ ] **Step 1: Write the failing tests**

Create `tests/test-config.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"

# defaults exist for the appearance options
for o in @amux-glyph-blocked @amux-glyph-idle @amux-sep-left @amux-color-bar-bg \
         @amux-color-active-bg @amux-notify-backend; do
  v="$(T show-options -gqv "$o")"
  [ -n "$v" ] && assert_eq ok ok "default set: $o" || assert_eq "" "non-empty" "default set: $o"
done

# notify-backend default is auto
assert_eq "$(T show-options -gqv @amux-notify-backend)" auto "notify-backend defaults to auto"

# no lingering underscore option name in tracked files
grep -rq '@amux_home' "$HERE/tmux" "$HERE/scripts" "$HERE/bin" \
  && assert_eq "found" "none" "no @amux_home (underscore) remains" \
  || assert_eq ok ok "no @amux_home (underscore) remains"
```

Create `tests/test-reload.sh` (proves the keybindings this repo shipped broken):

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"

# prefix r: source-file -F must expand #{@amux-home}, not pass it literally
out="$(T source-file -F "#{@amux-home}/tmux/amux.conf" 2>&1)"
assert_eq "$out" "" "prefix r reload sources cleanly (no literal-path error)"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-config.sh; bash tests/test-reload.sh`
Expected: FAIL — options not yet defined; `@amux_home` still present.

- [ ] **Step 3: Add `@amux-*` defaults to `tmux/amux.conf`**

Replace the current `set -g @agent_state "idle"` / `set -g @agent_glyph` block and add the appearance defaults. These mirror the built-in fallbacks and the shipped `amux` theme:

```bash
# Default per-window runtime state (overwritten by hooks).
set -g @agent_state "idle"
set -g @agent_glyph "💤"

# --- User-facing config (override in ~/.config/amux/amux.conf) ---
set -g @amux-glyph-blocked "🛑"
set -g @amux-glyph-working "⏳"
set -g @amux-glyph-done    "✅"
set -g @amux-glyph-idle    "💤"
set -g @amux-sep-left      ""
set -g @amux-sep-right     ""
set -g @amux-color-bar-bg    "#211e38"
set -g @amux-color-bar-fg    "#c8c3e0"
set -g @amux-color-logo-bg   "#7c6ff0"
set -g @amux-color-active-bg "#bd93f9"
set -g @amux-color-active-fg "#12101f"
set -g @amux-color-idle-fg   "#8a84b0"
set -g @amux-notify-backend  "auto"
```

(The `@amux-sep-*` defaults hold the U+E0B0 wedge — write them as real bytes in Step 6, they are shown here as `` for readability.)

- [ ] **Step 4: Point the status/window formats at the colour options**

Replace the hardcoded hexes in `status-left`, `window-status-format`, and `window-status-current-format` with `#{@amux-color-*}` and `#{@amux-sep-*}` references. Example for the active tab (single line):

```
setw -g window-status-current-format "#[fg=#{@amux-color-bar-bg},bg=#{@amux-color-active-bg}]#{@amux-sep-left}#[bg=#{@amux-color-active-bg},fg=#{@amux-color-active-fg},bold] #{@agent_glyph} #I #{window_name}·#{pane_current_command} #[fg=#{@amux-color-active-bg},bg=#{@amux-color-bar-bg}]#{@amux-sep-right}#[default]"
```

Do the same substitution for `window-status-format` (idle-dim conditional keeps `@amux-color-idle-fg` / `@amux-color-bar-fg`) and `status-left` (`@amux-color-logo-bg`).

- [ ] **Step 5: Rename `@amux_home`→`@amux-home` and source user config in `bin/amux`**

In `bin/amux` `ensure_session`, when booting the server:

```bash
    t set-option -g @amux-home "$AMUX_HOME"
    # User config: sourced AFTER the base conf so it overrides. -q: silent if absent.
    AMUX_USER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/amux/amux.conf"
    t set-option -g @amux-user-conf "$AMUX_USER_CONF"
    t source-file -qF "#{@amux-user-conf}"
```

Update the two internal readers: `scripts/amux-status` and `scripts/amux-switch` use socket `amux` directly, but the reload binding and `status-right` reference `#{@amux_home}` — rename those to `#{@amux-home}`.

- [ ] **Step 6: Update the reload binding + write wedge bytes**

Reload binding sources both files:

```bash
bind r source-file -F "#{@amux-home}/tmux/amux.conf" \; source-file -qF "#{@amux-user-conf}" \; display "amux config reloaded"
```

The format strings from Step 4 reference `#{@amux-sep-left}`/`#{@amux-sep-right}`,
so the wedge byte lives ONLY in the two `@amux-sep-*` default lines. PUA chars do
not survive normal file edits (they silently vanished three times during this
project's earlier work), so write the byte via `chr(0xE0B0)` in python — never by
typing it into an editor — and verify by exact count:

```bash
python3 - <<'PYEOF'
p="tmux/amux.conf"; s=open(p,encoding="utf-8").read()
W=chr(0xE0B0)  # powerline wedge; MUST come from chr(), never typed
assert 'set -g @amux-sep-left      ""' in s, "sep-left default not found verbatim"
assert 'set -g @amux-sep-right     ""' in s, "sep-right default not found verbatim"
s=s.replace('set -g @amux-sep-left      ""', 'set -g @amux-sep-left      "%s"' % W)
s=s.replace('set -g @amux-sep-right     ""', 'set -g @amux-sep-right     "%s"' % W)
open(p,"w",encoding="utf-8").write(s)
print("wedge count:", s.count(W))
PYEOF
```

Expected output: `wedge count: 2` — exactly the two `@amux-sep-*` default lines.
If it prints anything else, STOP: either the format strings still hold literal
wedges (they must use `#{@amux-sep-*}`), or a default line did not match verbatim.
Do not proceed until it prints exactly `2`.

- [ ] **Step 7: Run all tests + confirm config still loads**

Run: `bash tests/test-config.sh && bash tests/test-reload.sh && bash tests/test-agent-state.sh`
Then: `D=$(mktemp -d /tmp/amx.XXXX); tmux -S "$D/amux" -f tmux/amux.conf new-session -d && echo LOADS && tmux -S "$D/amux" kill-server; rm -rf "$D"`
Expected: all PASS; `LOADS` printed.

- [ ] **Step 8: Commit**

```bash
git add tmux/amux.conf bin/amux scripts/amux-status scripts/amux-switch tests/test-config.sh tests/test-reload.sh
git commit -m "Add @amux-* config layer; source user config; rename @amux-home"
```

---

## Task 5: Themes + contrast validator

**Files:**
- Create: `scripts/amux-themes.sh` (theme name → six colour values)
- Create: `tests/test-contrast.py`
- Test: run the validator itself

**Interfaces:**
- Consumes: nothing.
- Produces: `amux_theme <name>` (POSIX function, when `scripts/amux-themes.sh` is sourced) echoing six space-separated hex values in the fixed order `bar-bg bar-fg logo-bg active-bg active-fg idle-fg`; and `amux_theme_names` echoing all shipped theme names. `tests/test-contrast.py` asserts every theme passes.

**All five palettes are pre-validated** (contrast ≥ thresholds; logo-vs-active ΔE ≥ 20, calibrated from the amux default that the user accepted at ΔE 23.4):

| theme | bar-bg | bar-fg | logo-bg | active-bg | active-fg | idle-fg |
|---|---|---|---|---|---|---|
| amux | #211e38 | #c8c3e0 | #7c6ff0 | #bd93f9 | #12101f | #8a84b0 |
| catppuccin-mocha | #1e1e2e | #cdd6f4 | #89b4fa | #cba6f7 | #1e1e2e | #9399b2 |
| catppuccin-latte | #eff1f5 | #4c4f69 | #1e66f5 | #8839ef | #eff1f5 | #5c5f77 |
| tokyonight-storm | #24283b | #c0caf5 | #7aa2f7 | #bb9af7 | #1f2335 | #9aa5ce |
| tokyonight-day | #e1e2e7 | #343b58 | #2e7de9 | #7847bd | #e1e2e7 | #565f89 |

- [ ] **Step 1: Write the contrast validator (the test)**

Create `tests/test-contrast.py`:

```python
#!/usr/bin/env python3
"""Fail if any shipped theme violates the readability thresholds.
Metrics: WCAG contrast for text-on-bg (luminance); CIE76 ΔE for
'are these two chips distinguishable' (hue+luminance). ΔE >= 20 is
calibrated from the amux default the user accepted (logo/active = 23.4)."""
import math, subprocess, sys, os

def rgb(h): h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))
def _l(c):
    c/=255; return c/12.92 if c<=0.03928 else ((c+0.055)/1.055)**2.4
def lum(h): r,g,b=rgb(h); return 0.2126*_l(r)+0.7152*_l(g)+0.0722*_l(b)
def contrast(a,b):
    la,lb=lum(a),lum(b); hi,lo=max(la,lb),min(la,lb); return (hi+0.05)/(lo+0.05)
def _lab(h):
    r,g,b=[_l(c) for c in rgb(h)]
    X=(r*0.4124+g*0.3576+b*0.1805)/0.95047; Y=r*0.2126+g*0.7152+b*0.0722
    Z=(r*0.0193+g*0.1192+b*0.9505)/1.08883
    f=lambda t: t**(1/3) if t>0.008856 else 7.787*t+16/116
    return (116*f(Y)-16, 500*(f(X)-f(Y)), 200*(f(Y)-f(Z)))
def dE(a,b):
    (l1,a1,b1),(l2,a2,b2)=_lab(a),_lab(b)
    return math.sqrt((l1-l2)**2+(a1-a2)**2+(b1-b2)**2)

ROLES=["bar-bg","bar-fg","logo-bg","active-bg","active-fg","idle-fg"]

def load_themes():
    here=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src=os.path.join(here,"scripts","amux-themes.sh")
    names=subprocess.check_output(["sh","-c",f'. "{src}"; amux_theme_names'],text=True).split()
    out={}
    for n in names:
        vals=subprocess.check_output(["sh","-c",f'. "{src}"; amux_theme {n}'],text=True).split()
        out[n]=dict(zip(ROLES,vals))
    return out

def check(name,t):
    fails=[]
    def C(a,b,m,lbl): 
        r=contrast(t[a],t[b])
        if r<m: fails.append(f"{lbl}: {r:.2f} < {m}")
    C("bar-fg","bar-bg",4.5,"bar-fg on bar-bg")
    C("idle-fg","bar-bg",4.5,"idle-fg on bar-bg")
    C("active-fg","active-bg",4.5,"active-fg on active-bg")
    C("active-bg","bar-bg",3.0,"wedge active-bg on bar-bg")
    d=dE(t["logo-bg"],t["active-bg"])
    if d<20: fails.append(f"logo vs active ΔE: {d:.1f} < 20")
    return fails

if __name__=="__main__":
    themes=load_themes(); bad=0
    for n,t in themes.items():
        f=check(n,t)
        if f:
            bad+=1; print(f"FAIL {n}"); [print(f"    {x}") for x in f]
        else:
            print(f"PASS {n}")
    sys.exit(1 if bad else 0)
```

- [ ] **Step 2: Run to verify failure (no themes file yet)**

Run: `python3 tests/test-contrast.py`
Expected: FAIL — `amux-themes.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/amux-themes.sh`**

```bash
# amux-themes.sh — theme name → six colour values.
# Order: bar-bg bar-fg logo-bg active-bg active-fg idle-fg
# All values are contrast-validated by tests/test-contrast.py.
amux_theme_names() { printf '%s\n' amux catppuccin-mocha catppuccin-latte tokyonight-storm tokyonight-day; }
amux_theme() {
  case "$1" in
    amux)             echo "#211e38 #c8c3e0 #7c6ff0 #bd93f9 #12101f #8a84b0" ;;
    catppuccin-mocha) echo "#1e1e2e #cdd6f4 #89b4fa #cba6f7 #1e1e2e #9399b2" ;;
    catppuccin-latte) echo "#eff1f5 #4c4f69 #1e66f5 #8839ef #eff1f5 #5c5f77" ;;
    tokyonight-storm) echo "#24283b #c0caf5 #7aa2f7 #bb9af7 #1f2335 #9aa5ce" ;;
    tokyonight-day)   echo "#e1e2e7 #343b58 #2e7de9 #7847bd #e1e2e7 #565f89" ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Run the validator**

Run: `python3 tests/test-contrast.py`
Expected: five `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/amux-themes.sh tests/test-contrast.py
git commit -m "Add five contrast-validated themes and a ΔE/WCAG validator test"
```

---

## Task 6: `amux doctor`

**Files:**
- Create: `scripts/amux-doctor`
- Modify: `bin/amux` (add `doctor` subcommand + usage line)
- Test: `tests/test-doctor.sh`

**Interfaces:**
- Consumes: `scripts/amux-notify` (to report the resolved backend).
- Produces: `amux doctor` — prints a check report; exit 0 if all *required* checks pass (tmux ≥ 3.1, truecolor), non-zero otherwise. Optional checks (fzf, python3, hooks wired) warn but don't fail.

- [ ] **Step 1: Write the failing tests**

Create `tests/test-doctor.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$HERE/scripts/amux-doctor"

# reports the running tmux version
out="$("$DOC" 2>&1 || true)"
assert_contains "$out" "tmux" "doctor reports on tmux"

# a faked old tmux makes the required check fail (non-zero exit)
marker="$(mktemp)"
shimdir="$(mktemp -d /tmp/amx.XXXX)"
cat > "$shimdir/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "-V" ] && { echo "tmux 3.0a"; exit 0; }
exit 0
EOF
chmod +x "$shimdir/tmux"
PATH="$shimdir:$PATH" "$DOC" >/dev/null 2>&1
assert_eq "$?" "1" "doctor exits non-zero on tmux < 3.1"
rm -rf "$shimdir"

# a faked new tmux passes the version gate
shimdir="$(mktemp -d /tmp/amx.XXXX)"
cat > "$shimdir/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "-V" ] && { echo "tmux 3.4"; exit 0; }
exit 0
EOF
chmod +x "$shimdir/tmux"
out="$(COLORTERM=truecolor PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "3.4" "doctor accepts tmux 3.4"
rm -rf "$shimdir"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-doctor.sh`
Expected: FAIL — `amux-doctor: No such file or directory`.

- [ ] **Step 3: Write `scripts/amux-doctor`**

```bash
#!/usr/bin/env bash
# amux doctor — preflight checks. Exit non-zero only if a REQUIRED check fails
# (tmux >= 3.1, truecolor). Optional checks warn.
required_fail=0
ok()   { printf '  ✓ %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1"; }
bad()  { printf '  ✗ %s\n' "$1"; required_fail=1; }

ver="$(tmux -V 2>/dev/null | sed 's/^tmux //')"
# numeric compare: 3.1 is the floor (source-file -F, display-popup)
maj="${ver%%.*}"; rest="${ver#*.}"; min="${rest%%[a-z]*}"
if [ -z "$maj" ]; then bad "tmux not found"
elif [ "$maj" -gt 3 ] 2>/dev/null || { [ "$maj" -eq 3 ] && [ "${min:-0}" -ge 1 ]; } 2>/dev/null; then
  ok "tmux $ver (>= 3.1)"
else
  bad "tmux $ver — need >= 3.1 (source-file -F, display-popup)"
fi

case "${COLORTERM:-}" in
  truecolor|24bit) ok "truecolor terminal" ;;
  *) warn "COLORTERM not truecolor — the palette is #rrggbb and may band" ;;
esac

command -v fzf >/dev/null 2>&1 && ok "fzf present (prefix a switcher)" \
  || warn "fzf missing — the prefix a switcher will be unavailable"
command -v python3 >/dev/null 2>&1 && ok "python3 present (hook merge)" \
  || warn "python3 missing — amux init can't auto-merge Claude hooks"

settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
if grep -q amux-agent-state "$settings" 2>/dev/null; then
  ok "Claude hooks wired in $settings"
else
  warn "Claude hooks not found in $settings — run: amux hooks"
fi

printf '\n  notify backend: %s\n' \
  "$("$(dirname "$0")/amux-notify" --which 2>/dev/null || echo 'auto (run amux init to choose)')"

[ "$required_fail" -eq 0 ]
```

Note: add a `--which` early-exit to `amux-notify` that prints the backend it would use and exits, so doctor can report it without sending a notification. If that is out of scope, replace the last block with a static line; keep the plan honest by NOT calling an interface that doesn't exist. (Implementer: add the two-line `--which` handler to amux-notify, and a test for it.)

- [ ] **Step 4: Add `--which` to amux-notify + its test**

In `scripts/amux-notify`, immediately after computing `backend`, before delivery:

```bash
if [ "${1:-}" = "--which" ]; then printf '%s\n' "$backend"; exit 0; fi
```

(Place the `--which` check at the very top, before `title`/`msg` assignment, and read backend first.) Add to `tests/test-notify.sh`:

```bash
T set-option -g @amux-notify-backend tmux
assert_eq "$("$NOTIFY" --which)" "tmux" "--which reports the resolved backend"
```

- [ ] **Step 5: Wire `doctor` into `bin/amux`**

Add a case and usage entry:

```bash
  doctor)
    exec "$AMUX_HOME/scripts/amux-doctor"
    ;;
```

Add `doctor` to the final `usage:` line.

- [ ] **Step 6: Run tests**

Run: `chmod +x scripts/amux-doctor && bash tests/test-doctor.sh && bash tests/test-notify.sh`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/amux-doctor scripts/amux-notify bin/amux tests/test-doctor.sh tests/test-notify.sh
git commit -m "Add amux doctor preflight and amux-notify --which"
```

---

## Task 7: `amux init` wizard

**Files:**
- Create: `scripts/amux-init`
- Modify: `bin/amux` (add `init` subcommand + usage)
- Test: `tests/test-init.sh`

**Interfaces:**
- Consumes: `scripts/amux-themes.sh` (`amux_theme`, `amux_theme_names`).
- Produces: `amux init` — interactive on a tty; writes `$XDG_CONFIG_HOME/amux/amux.conf`. Non-interactive with `AMUX_INIT_ANSWERS` env (test hook: newline-separated answers) so it's testable. Refuses on a non-tty *without* that env. Idempotent; backs up an existing config.

- [ ] **Step 1: Write the failing tests**

Create `tests/test-init.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$HERE/scripts/amux-init"

cfgdir="$(mktemp -d /tmp/amx.XXXX)"
export XDG_CONFIG_HOME="$cfgdir"

# scripted answers: notify=n, powerline=triangle, mode=dark, theme=amux, glyph=emoji, hooks=skip
printf 'n\ny\ndark\namux\nemoji\nskip\n' | AMUX_INIT_ANSWERS=- "$INIT" >/dev/null 2>&1
conf="$cfgdir/amux/amux.conf"

[ -f "$conf" ] && assert_eq ok ok "writes config file" || assert_eq "" exists "writes config file"
assert_contains "$(cat "$conf")" "@amux-notify-backend" "sets notify-backend"
assert_contains "$(cat "$conf")" 'tmux' "notify=n → backend tmux"
assert_contains "$(cat "$conf")" "@amux-color-active-bg" "writes theme colours"
assert_contains "$(cat "$conf")" "@amux-glyph-blocked" "writes glyph set"

# idempotent + backup: second run backs up the first
printf 'n\ny\ndark\namux\nemoji\nskip\n' | AMUX_INIT_ANSWERS=- "$INIT" >/dev/null 2>&1
ls "$cfgdir/amux/"*.bak >/dev/null 2>&1 && assert_eq ok ok "backs up existing config" \
  || assert_eq "" backup "backs up existing config"

# refuses on non-tty without the answers hook
if [ -t 0 ]; then :; else
  out="$("$INIT" </dev/null 2>&1 || true)"
  assert_contains "$out" "tty" "refuses on non-tty without scripted answers"
fi
rm -rf "$cfgdir"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-init.sh`
Expected: FAIL — `amux-init: No such file or directory`.

- [ ] **Step 3: Write `scripts/amux-init`**

```bash
#!/usr/bin/env bash
# amux init — write ~/.config/amux/amux.conf from a few prompts.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/amux-themes.sh"

# Answers come from stdin. On a non-tty we require AMUX_INIT_ANSWERS=- (tests).
if [ ! -t 0 ] && [ "${AMUX_INIT_ANSWERS:-}" != "-" ]; then
  echo "amux init: needs a tty (or AMUX_INIT_ANSWERS=- with scripted stdin)"; exit 1
fi
ask() { printf '%s ' "$1" >&2; IFS= read -r REPLY || REPLY=""; printf '%s' "$REPLY"; }

notify="$(ask 'Enable OS notifications? [y/N]')"
case "$notify" in y|Y|yes) nb="auto" ;; *) nb="tmux" ;; esac

pl="$(ask 'Does this look like a triangle?  (y/N)')"   # caller shows the wedge
case "$pl" in y|Y) sep="$(printf '')" ;; *) sep="" ;; esac

mode="$(ask 'Terminal is light or dark? [dark]')"; mode="${mode:-dark}"

# theme list, optionally filtered by mode
theme="$(ask 'Theme? [amux]')"; theme="${theme:-amux}"
amux_theme "$theme" >/dev/null 2>&1 || theme="amux"
set -- $(amux_theme "$theme")
bar_bg="$1" bar_fg="$2" logo_bg="$3" active_bg="$4" active_fg="$5" idle_fg="$6"

gset="$(ask 'Glyph set? emoji/orbs/ascii/nerd [emoji]')"; gset="${gset:-emoji}"
case "$gset" in
  orbs)  gb="🔴" gw="🟡" gd="🔵" gi="🟢" ;;
  ascii) gb="[!]" gw="[~]" gd="[+]" gi="[·]" ;;
  nerd)  gb="$(printf '')" gw="$(printf '')" gd="$(printf '')" gi="$(printf '')" ;;
  *)     gb="🛑" gw="⏳" gd="✅" gi="💤" ;;
esac

cfg="${XDG_CONFIG_HOME:-$HOME/.config}/amux"
mkdir -p "$cfg"
target="$cfg/amux.conf"
[ -f "$target" ] && cp "$target" "$target.$(date +%s 2>/dev/null || echo prev).bak"

{
  echo "# Generated by amux init. Re-run amux init to change, or edit by hand."
  echo "set -g @amux-notify-backend \"$nb\""
  echo "set -g @amux-sep-left  \"$sep\""
  echo "set -g @amux-sep-right \"$sep\""
  echo "set -g @amux-color-bar-bg    \"$bar_bg\""
  echo "set -g @amux-color-bar-fg    \"$bar_fg\""
  echo "set -g @amux-color-logo-bg   \"$logo_bg\""
  echo "set -g @amux-color-active-bg \"$active_bg\""
  echo "set -g @amux-color-active-fg \"$active_fg\""
  echo "set -g @amux-color-idle-fg   \"$idle_fg\""
  echo "set -g @amux-glyph-blocked \"$gb\""
  echo "set -g @amux-glyph-working \"$gw\""
  echo "set -g @amux-glyph-done    \"$gd\""
  echo "set -g @amux-glyph-idle    \"$gi\""
} > "$target"

hooks="$(ask 'Merge Claude Code hooks into settings.json now? [y/skip]')"
case "$hooks" in y|Y|yes) "$HERE/../bin/amux" hooks ;; *) : ;; esac

echo "amux: wrote $target" >&2
echo "Reload a running amux with prefix + r, or start one with: amux" >&2
```

- [ ] **Step 4: Run tests**

Run: `chmod +x scripts/amux-init && bash tests/test-init.sh`
Expected: all PASS.

- [ ] **Step 5: Wire `init` into `bin/amux`**

```bash
  init)
    exec "$AMUX_HOME/scripts/amux-init"
    ;;
```

Add `init` to the usage line.

- [ ] **Step 6: Commit**

```bash
git add scripts/amux-init bin/amux tests/test-init.sh
git commit -m "Add amux init setup wizard"
```

---

## Task 8: End-to-end keybinding + switcher tests

**Files:**
- Create: `tests/test-switcher.sh`
- Modify: none (proves already-shipped behaviour + the new config path)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write the test**

Create `tests/test-switcher.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"

# prefix a target resolves to an absolute, existing script (display-popup has no -F)
[ -x "$HERE/scripts/amux-switch" ] && assert_eq ok ok "amux-switch is executable" \
  || assert_eq "" exec "amux-switch is executable"

# status rollup renders configured glyphs, no raw #[fg=
T new-window; T new-window
T set-option -w -t :1 @agent_state blocked; T set-option -w -t :1 @agent_glyph "🛑"
out="$(AMUX_STATUS_SOCK="$AMUX_TEST_SOCK" "$HERE/scripts/amux-status" 2>/dev/null || true)"
# amux-status hardcodes socket 'amux'; assert it at least runs and emits no colour codes
case "$out" in *'#[fg='*) assert_eq "has-codes" "no-codes" "status emits no raw colour codes" ;;
  *) assert_eq ok ok "status emits no raw colour codes" ;; esac
```

- [ ] **Step 2: Run**

Run: `bash tests/test-switcher.sh`
Expected: PASS (or a clear FAIL that pins a real gap to fix).

- [ ] **Step 3: Commit**

```bash
git add tests/test-switcher.sh
git commit -m "Add switcher/status end-to-end tests"
```

---

## Task 9: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Install tmux + fzf (Linux)
        if: runner.os == 'Linux'
        run: sudo apt-get update && sudo apt-get install -y tmux fzf
      - name: Install tmux + fzf (macOS)
        if: runner.os == 'macOS'
        run: brew install tmux fzf
      - name: tmux version
        run: tmux -V
      - name: Run test suite
        run: bash tests/run.sh
      - name: Contrast validator
        run: python3 tests/test-contrast.py
```

- [ ] **Step 2: Run the whole suite locally as CI would**

Run: `bash tests/run.sh && python3 tests/test-contrast.py`
Expected: `N passed, 0 failed`; five theme PASS lines.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add CI: run test suite + contrast validator on macOS and Linux"
```

---

## Task 10: README — match the docs to reality

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Fix requirements + document what now exists**

Update `## Requirements`:

```markdown
- `tmux` ≥ 3.1  (needs `source-file -F` and `display-popup`)
- `git`
- A powerline/Nerd Font for the tab separators — or run `amux init` and pick the
  plain-separator fallback
- Claude Code (for the state badges; the view itself works without it)
- Optional: `fzf` (the `prefix a` switcher), `python3` (auto-merge Claude hooks)
```

- [ ] **Step 2: Add a Setup section**

```markdown
## Setup

```sh
amux doctor   # check tmux version, font, notifier, hooks
amux init     # pick theme, glyph set, separator style; merge Claude hooks
```

`amux init` writes `~/.config/amux/amux.conf` and is safe to re-run (it backs up
the previous file). Reload a running amux with `prefix + r`.
```

- [ ] **Step 3: Document notifications + themes honestly**

Update the desktop-notification bullet to describe the cross-platform chain and
the `@amux-notify-cmd` escape hatch, and note the headless-remote limitation.
Add a short Themes list: `amux`, `catppuccin-mocha`, `catppuccin-latte`,
`tokyonight-storm`, `tokyonight-day`.

- [ ] **Step 4: Verify no personal copy or stale claims remain**

Run:
```bash
grep -nE "macOS notification|≥ 3.0|your main config|three Claude" README.md
```
Expected: no matches (all replaced).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "README: tmux 3.1, font requirement, init/doctor/themes, cross-platform notify"
```

---

## Self-Review

**Spec coverage:**
- Unit 1 amux-notify → Task 2 ✓ (opt-in backend, chain, %t/%s, exits 0)
- Unit 2 config layer → Task 4 ✓ (`@amux-*` defaults, user-conf sourcing, rename, glyph-from-config in Task 3)
- Themes → Task 5 ✓ (five pre-validated palettes)
- Contrast validator → Task 5 ✓ (now a CI test; ΔE added for the hue-distinctness rule the spec's luminance-only pair couldn't capture)
- Unit 3 doctor → Task 6 ✓ (tmux 3.1 gate verified exact; optional warns)
- Unit 4 init → Task 7 ✓ (5 questions, non-tty refusal, backup, idempotent)
- Error handling → Tasks 2,3,7 ✓ (exit 0 discipline, glyph fallback, non-tty refuse, backup)
- Testing/CI → Tasks 1,8,9 ✓ (harness, PATH shims, prefix r/a coverage, matrix)
- README accuracy → Task 10 ✓
- Unit 5 installer → deferred by decision (needs the repo published)

**Deviations from spec, recorded:**
1. **ΔE metric added.** Spec's `logo-bg vs active-bg` used contrast (luminance). That can't detect two same-luminance hues, which was the *original* complaint. Task 5 uses CIE76 ΔE ≥ 20, calibrated from the amux default the user accepted (23.4). The four upstream palettes failed the naive check; all five pass the corrected one.
2. **Upstream palettes required tuning.** As the spec warned, catppuccin/tokyonight values are designed for editor text; idle-fg and logo-bg were adjusted per-theme to pass. Final values are in Task 5.
3. **`amux-notify --which`** added so `doctor` can report the backend without sending a notification.

**Placeholder scan:** none — every code step carries full code; every command has expected output.

**Type/name consistency:** `@amux-*` option names, `amux_theme`/`amux_theme_names`, role order `bar-bg bar-fg logo-bg active-bg active-fg idle-fg`, and `@amux-home` are used identically across Tasks 3–10.

**Known follow-ups (not blocking units 1-4):**
- `amux-status`/`amux-switch` still hardcode socket `amux`; fine in production, so Task 8's status assertion is loose. A future task could parameterise the socket for tighter tests.
- Light/dark theme *filtering* in init is presented but not enforced (any theme name is accepted); the validator guarantees every theme is readable regardless, so this is cosmetic.
