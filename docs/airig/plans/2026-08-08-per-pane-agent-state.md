# Per-Pane Agent State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the tmux **pane** the unit of agency in amux, so several agents can share a window without clobbering each other's badge.

**Architecture:** `@agent_state`/`@agent_since` move from window scope (`set-option -w`) to pane scope (`set-option -p`). The stamped `@agent_glyph` is deleted outright — glyphs are derived from `@amux-glyph-<state>` at render time, which makes theme changes live and removes a whole class of staleness. The window tab computes a live summary badge from `#{P:}`, and the switcher, status rollup, `wait-done`, and `prefix + b` all move from windows to panes.

**Tech Stack:** bash (3.2-compatible), tmux ≥ 3.2 formats, fzf, no other dependencies.

## Global Constraints

- **bash 3.2 compatible.** macOS ships bash 3.2 as `/bin/bash`. No associative arrays, no `printf '\uXXXX'` (use `\xHH`), no `${var^^}`.
- **Tests never touch the live server.** Every test uses an isolated `-S` socket via `amux_test_server` or the `AMUX_*_SOCK` seams. Nothing may run against `-L amux`.
- **Socket paths must be short.** The ~104-char unix socket limit silently corrupts long paths; always build sockets under `mktemp -d /tmp/amx.XXXX`.
- **Suite stays green.** `bash tests/run.sh` must end with `0 failed`. For every file you touch, also run it under macOS's old bash: `/bin/bash tests/test-<name>.sh`.
- **tmux floor is 3.2** (raised from 3.1 in Task 9).
- **Public repo.** No usernames, real names, `/Users/...` paths, or email addresses in tracked files.
- **All git operations must target this worktree**, never the shared checkout.
- Commit trailers on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```

### tmux facts these tasks depend on (all verified by spike; do not re-derive)

1. `show-options -wqv` on a **pane-scoped** option exits 0 with **empty** output. Reading state with `-wqv` after this change means a `|| echo idle` fallback never fires and the empty string matches neither `done` nor `idle`, so the wait loop hangs until its timeout instead of returning early.
2. A literal **comma inside `#{P:...}` is a separator**, not text — tmux parses the two-argument (active, inactive) form. Loop bodies must use a space separator.
3. Option lookup falls back **pane → window → global**. A leftover window-scoped `@agent_state` is inherited by every unstamped pane in that window.
4. `set-option -gu` on a never-set option exits 0 and prints nothing. No `-q` needed.
5. `list-panes -a` does **not** return panes in display order (observed `%0 %2 %1`). Sort explicitly.
6. `list-panes -t %N` lists that pane's **whole window**, not the single pane.
7. `#{t/f/...}` cannot carry a `%H:%M` argument (the format's own `:` ends the modifier). Use `#{t/p:...}`.
8. `pane-border-status top` costs one row even in a single-pane window.

---

### Task 1: Pane-scoped state in `amux-agent-state`

**Files:**
- Modify: `scripts/amux-agent-state:26-70`
- Test: `tests/test-agent-state.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: pane options `@agent_state` (one of `blocked`, `working`, `done`, `idle`) and `@agent_since` (unix seconds), both written with `set-option -p -t "$TMUX_PANE"`. Nothing writes `@agent_glyph` any more. Every later task reads state from pane scope.

- [ ] **Step 1: Rewrite the test for pane scope**

Replace `tests/test-agent-state.sh` lines 12-32 (the glyph and early-return blocks) with:

```bash
run() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/amux-agent-state" "$1"; }
pstate() { tmux -S "$s" show-options -pqv -t "$1" @agent_state; }

# state is recorded on the PANE, which is what lets two agents share a window
run working
assert_eq "$(pstate "$pane")" "working" "state is stamped at pane scope"

# and NOT on the window — a window-scoped value would be inherited by every
# unstamped pane in that window (pane -> window -> global lookup)
assert_eq "$(tmux -S "$s" show-options -wqv -t "$pane" @agent_state)" "" \
  "nothing is stamped at window scope"

# a sibling pane in the same window is untouched
sib="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
run blocked
assert_eq "$(pstate "$sib")" "" "stamping one pane leaves its sibling empty"
assert_eq "$(pstate "$pane")" "blocked" "the stamped pane holds its own state"

# the retired glyph option is never written
assert_eq "$(tmux -S "$s" show-options -pqv -t "$pane" @agent_glyph)" "" \
  "@agent_glyph is retired and never stamped"

# early-return: a repeat call does not restamp @agent_since
run done
before="$(tmux -S "$s" show-options -pqv -t "$pane" @agent_since)"
sleep 1; run done
after="$(tmux -S "$s" show-options -pqv -t "$pane" @agent_since)"
assert_eq "$after" "$before" "unchanged state bails before writing"
```

Also delete line 13 (`tmux -S "$s" set-option -g @amux-glyph-working "GW"`) — the script no longer reads glyph config.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-agent-state.sh`
Expected: FAIL on "state is stamped at pane scope" (want `working`, got empty) because the script still writes window scope.

- [ ] **Step 3: Rewrite the stamping logic**

In `scripts/amux-agent-state`, replace everything from the `# Each state gets a glyph...` comment block (line 26) through the `refresh-client` line (line 70) with:

```bash
# Normalise: anything unrecognised is idle.
case "$state" in blocked|working|done) ;; *) state="idle" ;; esac

# PostToolUse fires after EVERY tool call and Claude blocks on this script
# exiting, so the common case — state already correct — must be cheap: ONE read,
# then bail before any writes. It MUST carry `|| true`: under `set -e` a bare
# failing $(...) aborts, and a dead tmux server (agent windows are killable) has
# to degrade, never break Claude.
prev="$(tmux -S "$sock" display-message -p -t "$TMUX_PANE" '#{@agent_state}' 2>/dev/null || true)"
[ "$state" = "$prev" ] && exit 0

# Stamp the PANE, not the window. Pane scope is what lets two agents share one
# window without overwriting each other's badge. Glyphs are NOT stamped: the
# status bar derives them from @amux-glyph-<state> at render time, so a theme
# change is live everywhere with nothing left to go stale.
tmux -S "$sock" set-option -p -t "$TMUX_PANE" @agent_state "$state" 2>/dev/null || true
tmux -S "$sock" set-option -p -t "$TMUX_PANE" @agent_since "$(date +%s)" 2>/dev/null || true

# Ping if an off-screen agent just became blocked (needs your input). If the
# window is on screen the pane is visible, so no ping.
if [ "$state" = blocked ]; then
  active="$(tmux -S "$sock" display-message -p -t "$TMUX_PANE" '#{window_active}' 2>/dev/null || echo 0)"
  if [ "$active" != "1" ]; then
    wname="$(tmux -S "$sock" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null || echo agent)"
    AMUX_NOTIFY_SOCK="$sock" "$(dirname "$0")/amux-notify" "amux · ${wname}" "needs your input" || true
  fi
fi

# Nudge every attached client to repaint now instead of waiting for the tick.
tmux -S "$sock" refresh-client -S 2>/dev/null || true
```

Update the file's header comment (lines 2-8): it says "record an AI agent's state onto its tmux window" and "stamps the window that the agent runs in". Change both to say **pane**.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test-agent-state.sh` — expected: all PASS, 0 FAIL.
Run: `/bin/bash tests/test-agent-state.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed` (nothing else reads pane state yet).

- [ ] **Step 5: Commit**

```bash
git add scripts/amux-agent-state tests/test-agent-state.sh
git commit -m "feat(amux): stamp agent state on the pane, not the window

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Window tab badge

**Files:**
- Modify: `tmux/amux.conf:32-37` (state defaults), `:39-52` (add badge options), `:75` and `:86` (tab formats)
- Create: `tests/test-pane-state.sh`
- Test: `tests/test-window-glyph.sh`

**Interfaces:**
- Consumes: pane-scoped `@agent_state` from Task 1.
- Produces: two global options usable by any format — `@amux-tab-badge` (renders one glyph per distinct state in the window) and `@amux-tab-busy` (renders `1` when the window holds a blocked, working, or done agent, else `0`). Both must be referenced as `#{E:@amux-tab-badge}` / `#{E:@amux-tab-busy}`, never bare.

- [ ] **Step 1: Write the failing test**

Create `tests/test-pane-state.sh`:

```bash
#!/usr/bin/env bash
# The window tab badge summarises the PANES in a window: one glyph per distinct
# agent state, urgency-ordered and deduplicated. A pane is an agent only if its
# pane-scoped @agent_state is non-empty, so a plain shell never badges a tab.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"
T set-option -g @amux-glyph-blocked "B"
T set-option -g @amux-glyph-working "W"
T set-option -g @amux-glyph-done    "D"
T set-option -g @amux-glyph-idle    "I"

hold='sh -c "while :; do sleep 5; done"'
badge() { T list-windows -a -F "#{window_id}|#{E:@amux-tab-badge}" | grep "^$1|" | cut -d'|' -f2; }
busy()  { T list-windows -a -F "#{window_id}|#{E:@amux-tab-busy}"  | grep "^$1|" | cut -d'|' -f2; }

# window 1: a plain shell + one blocked agent
w1="$(T display-message -p '#{window_id}')"
p1a="$(T display-message -p '#{pane_id}')"
p1b="$(T split-window -d -P -F '#{pane_id}' -t "$p1a" "$hold")"
T set-option -p -t "$p1b" @agent_state blocked
assert_eq "$(badge "$w1")" "B" "a plain shell alongside an agent adds no idle glyph"

# window 2: no agents at all -> the idle glyph, so a fresh tab looks unchanged
w2="$(T new-window -d -P -F '#{window_id}' "$hold")"
assert_eq "$(badge "$w2")" "I" "a window with no agents falls back to the idle glyph"
assert_eq "$(busy "$w2")"  "0" "a window with no agents is not busy"

# window 3: working + done -> both glyphs, urgency-ordered
w3p="$(T new-window -d -P -F '#{pane_id}' "$hold")"
w3="$(T display-message -p -t "$w3p" '#{window_id}')"
w3b="$(T split-window -d -P -F '#{pane_id}' -t "$w3p" "$hold")"
T set-option -p -t "$w3p" @agent_state working
T set-option -p -t "$w3b" @agent_state done
assert_eq "$(badge "$w3")" "WD" "distinct states render urgency-ordered"
assert_eq "$(busy "$w3")"  "1" "a window with a working agent is busy"

# window 4: two working agents dedupe to ONE glyph
w4p="$(T new-window -d -P -F '#{pane_id}' "$hold")"
w4="$(T display-message -p -t "$w4p" '#{window_id}')"
w4b="$(T split-window -d -P -F '#{pane_id}' -t "$w4p" "$hold")"
T set-option -p -t "$w4p" @agent_state working
T set-option -p -t "$w4b" @agent_state working
assert_eq "$(badge "$w4")" "W" "duplicate states dedupe to one glyph"

# all three urgent states together, in order
T set-option -p -t "$w4b" @agent_state done
w4c="$(T split-window -d -P -F '#{pane_id}' -t "$w4p" "$hold")"
T set-option -p -t "$w4c" @agent_state blocked
assert_eq "$(badge "$w4")" "BWD" "blocked sorts before working before done"

# the tab formats must go through #{E:}, or the option renders as literal text
fmt="$(T show-options -gqv window-status-format)"
assert_contains "$fmt" '#{E:@amux-tab-badge}' "window-status-format expands the badge option"
cfmt="$(T show-options -gqv window-status-current-format)"
assert_contains "$cfmt" '#{E:@amux-tab-badge}' "active tab format expands the badge option"
assert_contains "$(T display-message -p -t "$w1" "$fmt")" "B" "the rendered tab carries the badge"

# regression guard: a literal comma inside #{P:...} is parsed as the
# active/inactive separator, silently changing what the loop emits
conf="$(cat "$HERE/tmux/amux.conf")"
case "$conf" in
  *'#{P:#{@agent_state},'*) assert_eq comma space "no literal comma inside a #{P:} loop body" ;;
  *)                        assert_eq ok ok       "no literal comma inside a #{P:} loop body" ;;
esac
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-pane-state.sh`
Expected: FAIL on the first badge assertion — `@amux-tab-badge` does not exist yet, so `#{E:@amux-tab-badge}` renders empty.

- [ ] **Step 3: Replace the state defaults in `tmux/amux.conf`**

Replace lines 32-37 (the `# Default state for any window...` comment plus both `set -g` lines) with:

```
# NO global default for @agent_state. An unstamped pane must read EMPTY: that is
# what makes "this pane is an agent" a decidable predicate, and it keeps a plain
# shell in a split window from badging the tab. Option lookup falls back
# pane -> window -> global, so a stray value at either outer scope would be
# inherited by every unstamped pane. Deleting these lines is not enough on a
# server that is already running — re-sourcing only adds and overwrites — so
# unset them explicitly. @agent_glyph is retired entirely: glyphs are derived
# from @amux-glyph-<state> at render time, which is why a glyph or theme change
# is now live without re-stamping anything.
set -gu @agent_state
set -gu @agent_glyph
```

- [ ] **Step 4: Add the badge options after the glyph config**

Insert immediately after `set -g @amux-notify-backend  "auto"` (line 52):

```
# --- Tab badge: one glyph per DISTINCT agent state among the window's panes ---
# Panes are the unit of agency, so a tab summarises its panes. Urgency-ordered
# (blocked, working, done, idle) and deduplicated, so three working agents read
# as a single hourglass. Unstamped panes contribute nothing — that is what keeps
# a helper shell from smearing an idle glyph onto a busy tab — and a window with
# no agents at all falls back to the idle glyph so a fresh tab looks unchanged.
#
# Computed live from #{P:} on each status tick, so a pane dying can never leave
# a stale badge behind. Held in ONE option, referenced by both tab formats via
# #{E:}, so the two can never drift and a user can override it in one place.
#
# CAUTION: a literal comma inside #{P:...} is parsed as the active/inactive
# argument separator, NOT as text. The loop bodies below use a space separator.
set -g @amux-tab-badge "#{?#{==:#{P:#{@agent_state}},},#{@amux-glyph-idle},#{?#{m:*blocked*,#{P:#{@agent_state} }},#{@amux-glyph-blocked},}#{?#{m:*working*,#{P:#{@agent_state} }},#{@amux-glyph-working},}#{?#{m:*done*,#{P:#{@agent_state} }},#{@amux-glyph-done},}#{?#{m:*idle*,#{P:#{@agent_state} }},#{@amux-glyph-idle},}}"

# Busy = the window holds something worth looking at. Drives the tab's text
# colour so idle tabs dim and busy ones draw the eye first.
set -g @amux-tab-busy "#{||:#{m:*blocked*,#{P:#{@agent_state} }},#{||:#{m:*working*,#{P:#{@agent_state} }},#{m:*done*,#{P:#{@agent_state} }}}}"
```

- [ ] **Step 5: Point both tab formats at the badge**

Replace line 75 (`setw -g window-status-format ...`) with:

```
setw -g window-status-format         "#[fg=#{?#{E:@amux-tab-busy},#{@amux-color-bar-fg},#{@amux-color-idle-fg}}] #{E:@amux-tab-badge} #I #{window_name}·#{pane_current_command} #[default]"
```

Replace line 86 (`setw -g window-status-current-format ...`) with:

```
setw -g window-status-current-format "#[fg=#{@amux-color-bar-bg},bg=#{@amux-color-active-bg}]#{@amux-sep-left}#[bg=#{@amux-color-active-bg},fg=#{@amux-color-active-fg},bold] #{E:@amux-tab-badge} #I #{window_name}·#{pane_current_command} #[fg=#{@amux-color-active-bg},bg=#{@amux-color-bar-bg}]#{@amux-sep-right}#[default]"
```

Update the comment above line 75 — it currently explains dimming via `@agent_state == idle`. Replace that sentence with: "Idle tabs dim via `@amux-tab-busy` (no blocked, working, or done pane) so busy ones draw the eye first."

- [ ] **Step 6: Update `tests/test-window-glyph.sh` for the badge**

Replace lines 16-28 (from `# a brand-new window` through the active-format assertion) with:

```bash
# a brand-new window, as `prefix c` / `amux new` would create — no agent panes
T new-window
w2="$(T list-windows -F '#{window_id}' | tail -1)"
assert_eq "$(T show-options -pqv -t "$w2" @agent_state)" "" "new window has no stamped state"

# both tab formats render the configured idle glyph for the agent-less window
fmt="$(T show-options -gqv window-status-format)"
assert_contains "$(T display-message -p -t "$w2" "$fmt")" "IDLEMARK" \
  "agent-less window tab renders the configured idle glyph (not a hardcoded emoji)"
cfmt="$(T show-options -gqv window-status-current-format)"
assert_contains "$(T display-message -p -t "$w2" "$cfmt")" "IDLEMARK" \
  "agent-less active window tab renders the configured idle glyph"
```

Leave the rollup assertion at lines 30-33 alone; Task 5 updates it.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/test-pane-state.sh` — expected: all PASS.
Run: `bash tests/test-window-glyph.sh` — expected: all PASS.
Run: `/bin/bash tests/test-pane-state.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed`.

- [ ] **Step 8: Commit**

```bash
git add tmux/amux.conf tests/test-pane-state.sh tests/test-window-glyph.sh
git commit -m "feat(amux): window tab badges its panes' distinct agent states

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Pane borders badge each agent

**Files:**
- Modify: `tmux/amux.conf` (add a border block after the tab formats, before the key bindings section at line 89)
- Test: `tests/test-pane-state.sh` (append)

**Interfaces:**
- Consumes: pane-scoped `@agent_state`, `@agent_since`.
- Produces: global `@amux-pane-border`, referenced by `pane-border-format` via `#{E:}`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-pane-state.sh`:

```bash
# --- pane borders: each pane badges its own state ---
border() { T list-panes -a -F "#{pane_id}|#{E:@amux-pane-border}" | grep "^$1|" | cut -d'|' -f2; }

assert_contains "$(border "$p1b")" "B" "an agent pane's border shows its state glyph"
assert_contains "$(border "$p1b")" "blocked" "an agent pane's border names its state"
assert_contains "$(border "$p1b")" "$p1b" "a pane's border shows its stable %N id"

# a non-agent pane gets no glyph and no state word
nb="$(border "$p1a")"
assert_contains "$nb" "$p1a" "a non-agent pane's border still shows its %N id"
case "$nb" in *blocked*|*working*|*done*|*idle*)
    assert_eq "has-state" "none" "a non-agent pane's border names no state" ;;
  *) assert_eq ok ok "a non-agent pane's border names no state" ;;
esac

# a half-stamped pane (state but no @agent_since) must not render garbage
T set-option -p -t "$p1a" @agent_state working
T set-option -pu -t "$p1a" @agent_since
assert_contains "$(border "$p1a")" "working" "a pane with no @agent_since still renders its state"

# borders are on, so panes are distinguishable inside a split window
assert_eq "$(T show-options -wqv pane-border-status)" "top" "pane border status is enabled"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-pane-state.sh`
Expected: FAIL on "an agent pane's border shows its state glyph" — `@amux-pane-border` does not exist.

- [ ] **Step 3: Add the border block to `tmux/amux.conf`**

Insert immediately after the `setw -g window-status-separator ""` line (line 87), before the key-bindings header:

```
# ---------------------------------------------------------------------------
# Pane borders — inside a split window, which pane is which agent?
# ---------------------------------------------------------------------------
# Always on, not only for split windows: it costs one row everywhere, and the
# alternative is a hook keeping a per-window setting in sync with the pane count.
# An agent pane reads "🛑 %12 claude · blocked 14:20"; a plain shell reads just
# "%14 zsh". Both the glyph and the trailing clause are guarded on @agent_state,
# and the timestamp additionally on @agent_since, so a half-stamped pane cannot
# render garbage. The state->glyph chain is INLINED rather than kept in its own
# option: #{E:} inside #{E:} relies on expansion depth that is not guaranteed.
set -g @amux-pane-border " #{?@agent_state,#{?#{==:#{@agent_state},blocked},#{@amux-glyph-blocked},#{?#{==:#{@agent_state},working},#{@amux-glyph-working},#{?#{==:#{@agent_state},done},#{@amux-glyph-done},#{@amux-glyph-idle}}}} ,}#{pane_id} #{pane_current_command}#{?@agent_state, · #{@agent_state}#{?@agent_since, #{t/p:@agent_since},},} "
setw -g pane-border-status top
setw -g pane-border-format "#{E:@amux-pane-border}"
# The focused pane is marked with the same colour the active tab already uses,
# so "where am I" reads the same on the bar and in the window.
setw -g pane-border-style        "fg=#{@amux-color-idle-fg}"
setw -g pane-active-border-style "fg=#{@amux-color-active-bg}"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test-pane-state.sh` — expected: all PASS.
Run: `/bin/bash tests/test-pane-state.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add tmux/amux.conf tests/test-pane-state.sh
git commit -m "feat(amux): pane borders badge each agent's own state

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Retire re-stamping, add live-server migration

**Files:**
- Create: `scripts/amux-migrate-state`
- Create: `tests/test-migrate-state.sh`
- Delete: `scripts/amux-restamp`, `tests/test-restamp.sh`
- Modify: `tmux/amux.conf` (the `bind r` line), `scripts/lib/amux-config.sh:97-106`, `:108-109`, `:129-131`, `:154`, `:175-183`
- Test: `tests/test-reload.sh`, `tests/test-settings.sh:58-71`, `:110-115`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/amux-migrate-state`, honouring `AMUX_MIGRATE_SOCK` (a socket **path** for tests; unset means the production `-L amux` server). Removes the shell function `_amux_restamp` from `scripts/lib/amux-config.sh` — no later task may call it.

- [ ] **Step 1: Write the failing test**

Create `tests/test-migrate-state.sh`:

```bash
#!/usr/bin/env bash
# A server that predates per-pane state carries window-scoped @agent_state.
# Option lookup falls back pane -> window -> global, so those leftovers would be
# inherited by every UNSTAMPED pane in the window — badging plain shells as
# agents. prefix + r must clean them out without a server restart.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; trap amux_test_teardown EXIT
export AMUX_MIGRATE_SOCK="$AMUX_TEST_SOCK"

w="$(T display-message -p '#{window_id}')"
p="$(T display-message -p '#{pane_id}')"
T set-option -w -t "$w" @agent_state working
T set-option -w -t "$w" @agent_glyph "STALE"
T set-option -w -t "$w" @agent_since "12345"

# the leak this guards against: an unstamped pane inherits the window's state
assert_eq "$(T display-message -p -t "$p" '#{@agent_state}')" "working" \
  "precondition: a window-scoped leftover leaks into an unstamped pane"

"$HERE/scripts/amux-migrate-state"

assert_eq "$(T show-options -wqv -t "$w" @agent_state)" "" "migrate clears window @agent_state"
assert_eq "$(T show-options -wqv -t "$w" @agent_glyph)" "" "migrate clears window @agent_glyph"
assert_eq "$(T show-options -wqv -t "$w" @agent_since)" "" "migrate clears window @agent_since"
assert_eq "$(T display-message -p -t "$p" '#{@agent_state}')" "" \
  "an unstamped pane reads empty once the leftover is gone"

# idempotent: a second run is a clean no-op
"$HERE/scripts/amux-migrate-state"; rc=$?
assert_eq "$rc" "0" "migrate is idempotent"

# a pane's OWN state survives migration
T set-option -p -t "$p" @agent_state blocked
"$HERE/scripts/amux-migrate-state"
assert_eq "$(T show-options -pqv -t "$p" @agent_state)" "blocked" "migrate leaves pane state alone"

# no server at all -> silent no-op, never an error
out="$(AMUX_MIGRATE_SOCK=/tmp/amx.nonexistent "$HERE/scripts/amux-migrate-state" 2>&1)"; rc=$?
assert_eq "$rc" "0" "migrate exits 0 with no server"
assert_eq "$out" "" "migrate is silent with no server"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-migrate-state.sh`
Expected: FAIL — `scripts/amux-migrate-state` does not exist.

- [ ] **Step 3: Create `scripts/amux-migrate-state`**

```bash
#!/usr/bin/env bash
# amux-migrate-state — clear the pre-pane-state leftovers from a running server.
#
# Agent state used to live on the WINDOW. Option lookup falls back
# pane -> window -> global, so a leftover window-scoped @agent_state is inherited
# by every unstamped pane in that window, which would badge plain shells as
# agents. Run from `prefix + r` so a live server upgrades in place, with no
# restart. Idempotent: a no-op after the first run, and on any fresh server.
set -u
tmx() {
  if [ -n "${AMUX_MIGRATE_SOCK:-}" ]; then tmux -S "$AMUX_MIGRATE_SOCK" "$@"
  else tmux -L amux "$@"; fi
}

tmx has-session 2>/dev/null || exit 0
tmx list-windows -a -F '#{window_id}' 2>/dev/null | while read -r win; do
  [ -n "$win" ] || continue
  tmx set-option -wu -t "$win" @agent_state 2>/dev/null || true
  tmx set-option -wu -t "$win" @agent_glyph 2>/dev/null || true
  tmx set-option -wu -t "$win" @agent_since 2>/dev/null || true
done
exit 0
```

Then: `chmod +x scripts/amux-migrate-state`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-migrate-state.sh` — expected: all PASS.

- [ ] **Step 5: Delete the re-stamper and rewire its callers**

```bash
git rm scripts/amux-restamp tests/test-restamp.sh
```

In `tmux/amux.conf`, replace the `bind r` line (line 113) with:

```
bind r source-file -F "#{@amux-home}/tmux/amux.conf" \; source-file -qF "#{@amux-user-conf}" \; run-shell '$AMUX_HOME/scripts/amux-migrate-state' \; display "amux config reloaded"
```

Also fix the stale mention of `amux-restamp` in the comment at line 35 — that whole comment block was already replaced in Task 2; confirm no `amux-restamp` string remains in the conf.

In `scripts/lib/amux-config.sh`:
- Line 97: change the comment to `# amux_apply_live HOME -> reload the running server. No server -> no-op.`
- Delete line 104 (`"$home/scripts/amux-restamp" 2>/dev/null || true`).
- Delete lines 108-109 (the `_AMUX_LIB_DIR` comment and assignment) **only if** nothing else references `_AMUX_LIB_DIR`; check with `grep -n _AMUX_LIB_DIR scripts/lib/amux-config.sh` first and leave it if there are other users.
- Delete lines 129-131 (the `_amux_restamp` comment and function).
- Delete line 154 (`_amux_restamp` inside the `glyphs)` branch).
- Line 175: change the comment to `# amux_restore TYPE FILE -> re-apply a snapshot to the server.`
- Delete line 183 (`[ "$type" = glyphs ] && _amux_restamp`).

- [ ] **Step 6: Update the tests that asserted re-stamping**

In `tests/test-reload.sh`, replace the final assertion (line 14) with:

```bash
# prefix r migrates a live server off the old window-scoped state model
assert_contains "$(cat "$HERE/tmux/amux.conf")" "amux-migrate-state" \
  "prefix r reload migrates window-scoped leftovers"
# glyph changes need no re-stamping: nothing stamps glyphs any more
case "$(cat "$HERE/tmux/amux.conf")" in
  *amux-restamp*) assert_eq present absent "the retired re-stamper is gone from the conf" ;;
  *)              assert_eq ok ok          "the retired re-stamper is gone from the conf" ;;
esac
```

In `tests/test-settings.sh`, replace lines 64-70 with:

```bash
amux_cfg_set @amux-glyph-working "WW"
w="$(tmux -S "$AMUX_TEST_SOCK" display-message -p '#{window_id}')"
p="$(tmux -S "$AMUX_TEST_SOCK" display-message -p '#{pane_id}')"
tmux -S "$AMUX_TEST_SOCK" set-option -p -t "$p" @agent_state working
amux_apply_live "$HERE"
# A glyph change is live with NO re-stamping: the bar derives the glyph from
# @amux-glyph-<state> at render time, so there is nothing left to go stale.
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -gqv @amux-glyph-working)" "WW" \
  "apply_live re-sources the user conf (glyph override wins)"
assert_contains "$(tmux -S "$AMUX_TEST_SOCK" list-windows -a -F '#{E:@amux-tab-badge}')" "WW" \
  "the tab badge picks up the new glyph with no re-stamp"
```

Delete line 64's `export AMUX_RESTAMP_SOCK="$AMUX_TEST_SOCK"` and the same export on line 90.

Replace lines 110-115 with:

```bash
# glyphs preview is live for the tab badge, with nothing stamped
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-home "$HERE"
p="$(tmux -S "$AMUX_TEST_SOCK" display-message -p '#{pane_id}')"
tmux -S "$AMUX_TEST_SOCK" set-option -p -t "$p" @agent_state working
amux_preview_apply glyphs ascii
assert_contains "$(tmux -S "$AMUX_TEST_SOCK" list-windows -a -F '#{E:@amux-tab-badge}')" "[~]" \
  "preview_apply glyphs is live on the tab badge"
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/test-migrate-state.sh tests/test-reload.sh tests/test-settings.sh` individually — expected: all PASS.
Run: `/bin/bash tests/test-migrate-state.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed`.
Run: `grep -rn "restamp" scripts tmux tests bin` — expected: no matches.

- [ ] **Step 8: Commit**

```bash
git add -A scripts tmux tests
git commit -m "feat(amux): retire glyph re-stamping, migrate live servers on reload

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Status rollup counts agent panes

**Files:**
- Modify: `scripts/amux-status:20-47`
- Test: `tests/test-switcher.sh:15-29`, `tests/test-window-glyph.sh:30-33`

**Interfaces:**
- Consumes: pane-scoped `@agent_state`.
- Produces: unchanged stdout contract — `<glyph> <count>  ` per non-zero state, ordered blocked, working, done, idle, no colour codes.

- [ ] **Step 1: Update the failing tests**

In `tests/test-switcher.sh`, replace lines 15-26 with:

```bash
# rollup: counts AGENT PANES, not windows. Two agents in one window count twice;
# a plain shell counts not at all.
w0="$(T display -p '#{window_id}')"
p0="$(T display -p '#{pane_id}')"
p0b="$(T split-window -d -P -F '#{pane_id}' -t "$p0" 'sh -c "while :; do sleep 5; done"')"
p1="$(T new-window -d -PF '#{pane_id}')"
T new-window -d              # a window of plain shells — contributes nothing
T set-option -p -t "$p0"  @agent_state blocked
T set-option -p -t "$p0b" @agent_state idle
T set-option -p -t "$p1"  @agent_state working
out="$(AMUX_STATUS_SOCK="$AMUX_TEST_SOCK" "$HERE/scripts/amux-status" 2>/dev/null || true)"
assert_contains "$out" "🛑 1" "rollup shows one blocked (🛑 1)"
assert_contains "$out" "⏳ 1" "rollup shows one working (⏳ 1)"
assert_contains "$out" "💤 1" "rollup counts the idle AGENT pane, not the plain shells"
```

In `tests/test-window-glyph.sh`, replace lines 30-33 with:

```bash
# the rollup counts agents, not tabs: with no agent panes it stays empty rather
# than reporting every window as idle
out="$(AMUX_STATUS_SOCK="$sock" "$HERE/scripts/amux-status")"
assert_eq "$out" "" "rollup is empty when no pane is an agent"

# once a pane is an agent, its badge uses the configured idle glyph
p="$(T display-message -p '#{pane_id}')"
T set-option -p -t "$p" @agent_state idle
out="$(AMUX_STATUS_SOCK="$sock" "$HERE/scripts/amux-status")"
assert_contains "$out" "IDLEMARK" "status rollup idle badge uses the configured idle glyph"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test-switcher.sh`
Expected: FAIL — the rollup still counts windows, so the plain-shell window is counted idle and `💤 1` is wrong (it reports `💤 2`).

- [ ] **Step 3: Rewrite the counting loop**

In `scripts/amux-status`, replace lines 20-33 (from `b=0 w=0 d=0 i=0` through the `done < <(...)` line) with:

```bash
b=0 w=0 d=0 i=0
# Glyphs come from config so the rollup, the tab badge, and the switcher all
# derive from one source. Hardcoded values are last-resort fallbacks only.
gb="$(amux_status_tmux show-options -gqv @amux-glyph-blocked 2>/dev/null)"; [ -n "$gb" ] || gb="🛑"
gw="$(amux_status_tmux show-options -gqv @amux-glyph-working 2>/dev/null)"; [ -n "$gw" ] || gw="⏳"
gd="$(amux_status_tmux show-options -gqv @amux-glyph-done    2>/dev/null)"; [ -n "$gd" ] || gd="✅"
gi="$(amux_status_tmux show-options -gqv @amux-glyph-idle    2>/dev/null)"; [ -n "$gi" ] || gi="💤"

# Count AGENT PANES, not windows: two agents sharing a window count twice, and a
# pane with no state is a plain shell, not an idle agent, so it is skipped
# entirely. The rollup is therefore a count of agents rather than of tabs.
while IFS= read -r st; do
  case "$st" in
    blocked) b=$((b+1)) ;;
    working) w=$((w+1)) ;;
    done)    d=$((d+1)) ;;
    idle)    i=$((i+1)) ;;
    *)       ;;   # empty -> not an agent
  esac
done < <(amux_status_tmux list-panes -a -F '#{@agent_state}' 2>/dev/null)
```

Update the file's header comment (lines 2-11): it says "Rolls every window across the amux server up to badged counts" and explains reading glyphs "back off the windows". Change both to panes, and note that unstamped panes are skipped.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test-switcher.sh` — expected: all PASS.
Run: `bash tests/test-window-glyph.sh` — expected: all PASS.
Run: `/bin/bash tests/test-switcher.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/amux-status tests/test-switcher.sh tests/test-window-glyph.sh
git commit -m "feat(amux): status rollup counts agent panes, not windows

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Switcher lists panes, grouped by window

**Files:**
- Modify: `scripts/amux-switch` (full rewrite)
- Test: `tests/test-switcher.sh` (append)

**Interfaces:**
- Consumes: pane-scoped `@agent_state`, `@agent_since`.
- Produces: `AMUX_SWITCH_SOCK` (socket **path**; unset means `-L amux`) and `AMUX_SWITCH_DUMP` (when set to `1`, print the composed rows to stdout and exit 0 without launching fzf — this is what makes the switcher testable, since fzf needs a tty). Row format is four tab-separated fields: `session_id`, `window_id`, `pane_id`, display text. `pane_id` is empty on a window header row.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-switcher.sh`:

```bash
# --- switcher rows (fzf needs a tty, so dump the composed rows instead) ---
T set-option -g @amux-glyph-blocked "B"
T set-option -g @amux-glyph-working "W"
T set-option -g @amux-glyph-idle    "I"
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"

# Field-match with awk rather than grepping for literal tabs — a tab that gets
# mangled into spaces on edit would make these assertions quietly meaningless.
hdrs()  { printf '%s\n' "$rows" | awk -F'\t' -v w="$1" '$2==w && $3==""'  | wc -l | tr -d ' '; }
prows() { printf '%s\n' "$rows" | awk -F'\t' -v p="$1" '$3==p'; }

# w0 has two panes -> a header row plus one indented row per pane
assert_eq "$(hdrs "$w0")" "1" "a multi-pane window emits exactly one header row"
assert_eq "$(prows "$p0"  | wc -l | tr -d ' ')" "1" "the blocked pane appears as its own row"
assert_eq "$(prows "$p0b" | wc -l | tr -d ' ')" "1" "the sibling pane appears as its own row"

# a single-pane window collapses to ONE flat row — no header
w1id="$(T display-message -p -t "$p1" '#{window_id}')"
assert_eq "$(prows "$p1" | wc -l | tr -d ' ')" "1" "a single-pane window emits one row"
assert_eq "$(hdrs "$w1id")" "0" "a single-pane window emits no header row"

# every pane row carries window·command, so fzf filtering (which hides headers)
# leaves each row still self-describing
wname="$(T display-message -p -t "$p0b" '#{window_name}')"
assert_contains "$(prows "$p0b")" "$wname·" "a pane row names its window, so filtered rows keep context"

# a non-agent pane shows the idle glyph and no state word
T new-window -d
plain="$(T list-panes -a -F '#{pane_id} #{@agent_state}' | awk '$2==""{print $1; exit}')"
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
prow="$(prows "$plain")"
assert_contains "$prow" "I" "a non-agent pane row shows the idle glyph"
case "$prow" in *blocked*|*working*|*done*|*idle*)
    assert_eq "has-state" "none" "a non-agent pane row names no state" ;;
  *) assert_eq ok ok "a non-agent pane row names no state" ;;
esac

# rows are GROUPED: every window's rows form one contiguous run, so a header is
# never separated from the panes it introduces. If the sort were dropped, the
# runs would interleave and the de-duplicated count would exceed the unique one.
runs="$(printf '%s\n' "$rows" | cut -f2 | uniq | wc -l | tr -d ' ')"
uniq="$(printf '%s\n' "$rows" | cut -f2 | sort -u | wc -l | tr -d ' ')"
assert_eq "$runs" "$uniq" "each window's rows form one contiguous run"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-switcher.sh`
Expected: FAIL — `AMUX_SWITCH_DUMP` is not honoured, so `rows` is empty (or the script tries to run fzf).

- [ ] **Step 3: Rewrite `scripts/amux-switch`**

Replace the whole file with:

```bash
#!/usr/bin/env bash
# amux-switch — fzf popup to jump to any agent PANE across the amux server.
# Panes are the unit of agency, so this lists panes, grouped by window.
# Bound to `prefix + a`; run inside a display-popup.
#
# Layout: a single-pane window collapses to one flat row (the common case must
# not double in length). A window with two or more panes gets a header row plus
# one indented row per pane. Every pane row also carries "window·command",
# because fzf hides the headers the moment you type — each row has to stay
# self-describing on its own.
set -u

# Socket: the shared -L amux server in production. Tests point AMUX_SWITCH_SOCK
# at an isolated server (a socket PATH, so -S).
tmx() {
  if [ -n "${AMUX_SWITCH_SOCK:-}" ]; then tmux -S "$AMUX_SWITCH_SOCK" "$@"
  else tmux -L amux "$@"; fi
}

if [ -z "${AMUX_SWITCH_DUMP:-}" ] && ! command -v fzf >/dev/null 2>&1; then
  tmx display-message "amux: install fzf to use the agent switcher"
  exit 0
fi

now="$(date +%s)"

# Glyphs come from config, so the switcher and the status bar can never drift —
# both derive from @amux-glyph-<state>. Hardcoded values are last-resort only.
gb="$(tmx show-options -gqv @amux-glyph-blocked 2>/dev/null)"; [ -n "$gb" ] || gb="🛑"
gw="$(tmx show-options -gqv @amux-glyph-working 2>/dev/null)"; [ -n "$gw" ] || gw="⏳"
gd="$(tmx show-options -gqv @amux-glyph-done    2>/dev/null)"; [ -n "$gd" ] || gd="✅"
gi="$(tmx show-options -gqv @amux-glyph-idle    2>/dev/null)"; [ -n "$gi" ] || gi="💤"

# list-panes -a does NOT return panes in display order (observed %0 %2 %1), so
# sort explicitly: session name, then window index, then pane index.
raw="$(tmx list-panes -a -F '#{session_id}	#{session_name}	#{window_id}	#{window_index}	#{window_name}	#{window_panes}	#{pane_id}	#{pane_index}	#{pane_current_command}	#{b:pane_current_path}	#{@agent_state}	#{@agent_since}' 2>/dev/null \
  | sort -t'	' -k2,2 -k4,4n -k8,8n)"

# Hidden key fields: session_id, window_id, pane_id (empty on a header row).
rows="$(printf '%s\n' "$raw" | awk -F'\t' -v now="$now" -v gb="$gb" -v gw="$gw" -v gd="$gd" -v gi="$gi" '
  function glyph(s) {
    if (s == "blocked") return gb
    if (s == "working") return gw
    if (s == "done")    return gd
    return gi
  }
  {
    sid=$1; wid=$3; wname=$5; wpanes=$6+0; pid=$7; cmd=$9; path=$10; st=$11; since=$12
    # A pane with no state is a plain shell, not an idle agent: show the idle
    # glyph but no state word and no elapsed time.
    el = (st == "" || since == "") ? "--" : sprintf("%dm", int((now - since) / 60))
    if (wpanes <= 1) {
      printf "%s\t%s\t%s\t%s %-8s %4s  %-6s %s·%s  (%s)\n", sid, wid, pid, glyph(st), st, el, pid, wname, cmd, path
    } else {
      if (wid != lastwid) { printf "%s\t%s\t\t%s  (%s)\n", sid, wid, wname, path; lastwid = wid }
      printf "%s\t%s\t%s\t  %s %-8s %4s  %-6s %s·%s\n", sid, wid, pid, glyph(st), st, el, pid, wname, cmd
    }
  }')"

# Tests cannot drive fzf (it needs a tty), so allow dumping the composed rows.
if [ -n "${AMUX_SWITCH_DUMP:-}" ]; then printf '%s\n' "$rows"; exit 0; fi

sel="$(printf '%s\n' "$rows" | fzf --with-nth=4.. --delimiter='\t' --reverse --prompt='agent > ' --no-info)"
[ -n "$sel" ] || exit 0

sid="$(printf '%s' "$sel" | cut -f1)"
wid="$(printf '%s' "$sel" | cut -f2)"
pid="$(printf '%s' "$sel" | cut -f3)"
tmx switch-client -t "$sid"
tmx select-window -t "$wid"
# A header row has no pane id — selecting it lands on the window's active pane.
[ -n "$pid" ] && tmx select-pane -t "$pid"
exit 0
```

Note the literal tab characters in the `-F` string, the `sort -t` argument, and the awk `-F` — they must be real tabs, not `\t` escapes.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test-switcher.sh` — expected: all PASS.
Run: `/bin/bash tests/test-switcher.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/amux-switch tests/test-switcher.sh
git commit -m "feat(amux): switcher lists panes, grouped by window

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: `wait-done` is pane-precise; `status` lists panes

**Files:**
- Modify: `bin/amux:196-213`
- Test: `tests/test-coordination.sh` (append)

**Interfaces:**
- Consumes: pane-scoped `@agent_state`.
- Produces: `amux wait-done %N` blocks on that one pane; `amux wait-done @N` / `SESSION:INDEX` / bare name blocks until every agent pane in the window is `done` or `idle`. Exit 0 on success, 1 on timeout.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-coordination.sh`:

```bash
# --- wait-done is pane-precise ---
# The regression this guards: pane options are invisible to `show-options -wqv`,
# which returns empty — so a window-scoped read reports every agent "done".
wpane="$(T display-message -p -t "$recv" '#{pane_id}')"
sib="$(T split-window -d -P -F '#{pane_id}' -t "$wpane")"
T set-option -p -t "$sib" @agent_state working

# the busy pane blocks; a 1s timeout must fail rather than return success
"$AMUX" wait-done "$sib" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "wait-done on a working pane times out (does not read window scope)"

# its sibling is not an agent, so it is already done
"$AMUX" wait-done "$wpane" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a non-agent pane returns immediately"

# a window target aggregates: one working pane keeps the whole window busy
wid="$(T display-message -p -t "$recv" '#{window_id}')"
"$AMUX" wait-done "$wid" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "wait-done on a window waits for every agent pane"

# once that pane finishes, the window target returns
T set-option -p -t "$sib" @agent_state done
"$AMUX" wait-done "$wid" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a window returns once all agent panes are done"

# a window with no agents at all returns immediately
empty="$(T new-window -d -PF '#{window_id}')"
"$AMUX" wait-done "$empty" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a window with no agents returns immediately"

# --- status lists panes ---
T set-option -p -t "$sib" @agent_state blocked
out="$("$AMUX" status)"
assert_contains "$out" "$sib" "status lists the helper pane by its %N"
assert_contains "$out" "blocked" "status shows each pane's own state"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-coordination.sh`
Expected: FAIL on "wait-done on a working pane times out" — the current `show-options -wqv` read returns empty, falls into the `idle` branch, and exits 0 immediately.

- [ ] **Step 3: Rewrite `wait-done` and `status`**

In `bin/amux`, replace the `wait-done|wait)` branch (lines 196-207) with:

```bash
  wait-done|wait)
    raw="${2:?usage: amux wait-done [SESSION:]WINDOW [TIMEOUT_SEC]}"; timeout="${3:-0}"; waited=0
    tgt="$(target "$raw")"
    # A %N target is pane-precise; anything else aggregates the window's agent
    # panes. The two cases MUST branch on the target form: `list-panes -t %N`
    # lists that pane's whole WINDOW, not the single pane.
    # State is a PANE option, so it is read with display-message (which resolves
    # pane scope). `show-options -wqv` exits 0 with EMPTY output for a pane
    # option, so a `|| echo idle` fallback never fires and the empty string
    # matches neither done nor idle — the wait loop would hang until timeout.
    busy() {
      case "$tgt" in
        %*)
          case "$(t display-message -p -t "$tgt" '#{@agent_state}' 2>/dev/null)" in
            working|blocked) return 0 ;;
            *) return 1 ;;
          esac
          ;;
        *)
          # Command substitution, NOT a pipe into `grep -q`: bin/amux runs under
          # `set -o pipefail`, and grep exiting early can SIGPIPE list-panes, so
          # the pipeline would report failure even when a pane IS busy — and
          # wait-done would return immediately on a working agent.
          states="$(t list-panes -t "$tgt" -F '#{@agent_state}' 2>/dev/null || true)"
          case "$states" in
            *working*|*blocked*) return 0 ;;
            *) return 1 ;;
          esac
          ;;
      esac
    }
    while busy; do
      sleep 1; waited=$((waited + 1))
      if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
        echo "amux: timed out waiting for '$raw'" >&2; exit 1
      fi
    done
    exit 0
    ;;
```

In the `status)` branch, replace the `list-windows` line (line 212) with:

```bash
      t list-panes -a -F '    #{pane_id}  #{session_name}:#{window_index}.#{pane_index} #{window_name}/#{pane_current_command}  [#{?@agent_state,#{@agent_state},-}]'
```

Also update the usage comment at line 22 — `amux wait-done TGT [T]  block until TGT is done/idle (optional T-sec timeout)` becomes `block until TGT (a %N pane, or every agent pane in a window) is done/idle`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test-coordination.sh` — expected: all PASS.
Run: `/bin/bash tests/test-coordination.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/amux tests/test-coordination.sh
git commit -m "feat(amux): pane-precise wait-done; status lists panes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: `prefix + b` jumps to the blocked pane

**Files:**
- Create: `scripts/amux-next-blocked`
- Create: `tests/test-next-blocked.sh`
- Modify: `tmux/amux.conf` (the `bind b` line, ~line 116)

**Interfaces:**
- Consumes: pane-scoped `@agent_state`.
- Produces: `scripts/amux-next-blocked`, honouring `AMUX_NEXT_SOCK` (socket **path**; unset means the ambient server, which is what `run-shell` provides). Exits 0 whether or not anything was blocked.

- [ ] **Step 1: Write the failing test**

Create `tests/test-next-blocked.sh`:

```bash
#!/usr/bin/env bash
# prefix + b jumps to the next agent that needs you. With panes as the unit, it
# must select the right WINDOW *and* the right PANE inside it.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NEXT="$HERE/scripts/amux-next-blocked"
amux_test_server; trap amux_test_teardown EXIT
export AMUX_NEXT_SOCK="$AMUX_TEST_SOCK"
hold='sh -c "while :; do sleep 5; done"'

[ -x "$NEXT" ] && assert_eq ok ok "amux-next-blocked is executable" \
  || assert_eq "" exec "amux-next-blocked is executable"

# nothing blocked -> a silent no-op that changes no selection
w0="$(T display-message -p '#{window_id}')"
before="$(T display-message -p '#{window_id}')"
out="$("$NEXT" 2>&1)"; rc=$?
assert_eq "$rc" "0" "no blocked pane exits 0"
assert_eq "$out" "" "no blocked pane is silent"
assert_eq "$(T display-message -p '#{window_id}')" "$before" "no blocked pane changes nothing"

# a blocked pane in a NON-active window, and not the window's active pane
w1p="$(T new-window -d -P -F '#{pane_id}' "$hold")"
w1="$(T display-message -p -t "$w1p" '#{window_id}')"
w1b="$(T split-window -d -P -F '#{pane_id}' -t "$w1p" "$hold")"
T set-option -p -t "$w1b" @agent_state blocked

"$NEXT"
assert_eq "$(T display-message -p '#{window_id}')" "$w1" "jumps to the blocked pane's window"
assert_eq "$(T display-message -p '#{pane_id}')" "$w1b" "selects the blocked PANE, not the window's active one"

# only blocked counts — a working pane is not a jump target
T set-option -p -t "$w1b" @agent_state working
T select-window -t "$w0"
"$NEXT"
assert_eq "$(T display-message -p '#{window_id}')" "$w0" "a working pane is not a jump target"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-next-blocked.sh`
Expected: FAIL on "amux-next-blocked is executable" — the script does not exist.

- [ ] **Step 3: Create `scripts/amux-next-blocked`**

```bash
#!/usr/bin/env bash
# amux-next-blocked — select the first blocked agent PANE on the server.
#
# Bound to `prefix + b`. State lives on the pane, so jumping to the window is
# not enough: a window can hold several agents and only one of them is stuck.
# Silent no-op when nothing is blocked.
set -u
tmx() {
  if [ -n "${AMUX_NEXT_SOCK:-}" ]; then tmux -S "$AMUX_NEXT_SOCK" "$@"
  else tmux "$@"; fi
}

hit="$(tmx list-panes -a -F '#{@agent_state} #{window_id} #{pane_id}' 2>/dev/null \
  | awk '$1 == "blocked" { print $2, $3; exit }')"
[ -n "$hit" ] || exit 0

set -f; set -- $hit; set +f
tmx select-window -t "$1" 2>/dev/null || exit 0
tmx select-pane -t "$2" 2>/dev/null || true
exit 0
```

Then: `chmod +x scripts/amux-next-blocked`

- [ ] **Step 4: Rewire the binding**

In `tmux/amux.conf`, replace the `bind b run-shell "..."` line (~line 116) and its comment with:

```
# amux-specific: jump to the next agent that needs you. State is per-pane, so
# this selects the blocked PANE, not just its window.
bind b run-shell '$AMUX_HOME/scripts/amux-next-blocked'
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/test-next-blocked.sh` — expected: all PASS.
Run: `/bin/bash tests/test-next-blocked.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add scripts/amux-next-blocked tests/test-next-blocked.sh tmux/amux.conf
git commit -m "feat(amux): prefix+b selects the blocked pane, not just its window

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: tmux floor 3.2 and documentation

**Files:**
- Modify: `scripts/amux-doctor:1-17`, `README.md:37`, `:260-284`, `skills/amux/SKILL.md`, `bin/amux:16-22` (usage comments)
- Test: `tests/test-doctor.sh:11-33`

**Interfaces:**
- Consumes: everything above.
- Produces: no new interfaces.

- [ ] **Step 1: Pin the real floor before changing anything**

Run: `man tmux | grep -n "E:\|P:.*loop\|t/p" | head` and `grep -n "P:" /opt/homebrew/Cellar/tmux/*/CHANGES | head`.

The design assumes **3.2** covers `#{P:}` loops, `#{E:}`, and `#{t/p:}`. `#{E:}` is confirmed at 2.9 and pane options at 3.0. If you find evidence that `#{P:}` or `#{t/p:}` landed **later** than 3.2, use that version as the floor throughout this task instead, and say so in the commit message. Do not lower it below 3.2.

- [ ] **Step 2: Update the failing test**

In `tests/test-doctor.sh`, change line 16 from `echo "tmux 3.0a"` to `echo "tmux 3.1c"`, and line 21's label to `"doctor exits non-zero on tmux < 3.2"`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/test-doctor.sh`
Expected: FAIL on "doctor exits non-zero on tmux < 3.2" (want 1, got 0) — the doctor still accepts 3.1.

- [ ] **Step 4: Raise the floor in `scripts/amux-doctor`**

- Line 3: `# (tmux >= 3.2, truecolor). Optional checks warn.`
- Line 10: `# numeric compare: 3.2 is the floor (#{P:} pane loops, #{E:}, pane options)`
- Line 13: change `[ "${min:-0}" -ge 1 ]` to `[ "${min:-0}" -ge 2 ]`
- Line 14: `ok "tmux $ver (>= 3.2)"`
- Line 16: `bad "tmux $ver — need >= 3.2 (#{P:} pane loops, #{E:}, pane options)"`

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-doctor.sh` — expected: all PASS.

- [ ] **Step 6: Update the README**

- Line 37: `- \`tmux\` ≥ 3.2  (needs pane options, \`#{P:}\` pane loops, and \`display-popup\`)`
- Replace the second and third "How it works" bullets (lines 262-267) with:

```markdown
- `tmux/amux.conf` badges each window from its **panes**: one glyph per distinct
  agent state present, urgency-ordered and deduplicated, computed live from
  `#{P:}` so a pane dying never leaves a stale badge. Glyphs are shape-distinct
  (not just colour-distinct), so the bar still reads correctly if you're
  colourblind. Backgrounds mark only which window is **active**, which keeps
  every tab's text high-contrast.
- Claude hooks call `scripts/amux-agent-state <state>`, which stamps the **pane**
  identified by `$TMUX_PANE`, then repaints. Pane scope is what lets two agents
  share one window — `amux split` puts a second agent beside the first without
  either clobbering the other's badge. A pane is an agent only if it has been
  stamped, so a plain shell or a `tail -f` never badges anything.
```

- In the Layout block, delete the `scripts/amux-restamp` line and add, in alphabetical position:

```
scripts/amux-migrate-state # clear pre-pane-state window options from a running server (used by reload)
scripts/amux-next-blocked  # select the next blocked agent pane (prefix b)
```

- Update the `scripts/amux-switch` line to `# fzf agent switcher, panes grouped by window (prefix a)`.
- Update the `scripts/amux-status` line to `# status-bar roll-up of agent-pane counts`.

- [ ] **Step 7: Update the skill**

In `skills/amux/SKILL.md`, add to the section that explains targets:

```markdown
State is per-pane. A pane opened with `amux split` is a real agent: it has its
own badge, appears in the switcher, and is addressable by its `%N` for `send`,
`read`, and `wait-done`. `amux wait-done %N` waits on that one pane; giving it a
window target instead waits for **every** agent pane in that window.

A pane counts as an agent only once a hook has stamped it. A helper pane running
a shell command, a log tail, or a pager is not an agent and never shows a state.
```

Keep the existing spawn-vs-split guidance unchanged.

- [ ] **Step 8: Run the full suite and check for leaks**

Run: `bash tests/run.sh` — expected: `0 failed`.
Run: `grep -rn "restamp\|@agent_glyph" bin scripts tmux tests skills README.md` — expected: no matches.
Run: `grep -rniE "/Users/|@[a-z0-9.-]+\.(com|net|org)" README.md skills/amux/SKILL.md` — expected: no matches other than the `noreply@anthropic.com` trailer convention (which lives in commit messages, not tracked files).

- [ ] **Step 9: Commit**

```bash
git add scripts/amux-doctor tests/test-doctor.sh README.md skills/amux/SKILL.md bin/amux
git commit -m "docs(amux): per-pane state in the README and skill; tmux floor 3.2

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Manual verification (after Task 9)

The automated suite cannot see the rendered bar. Do this once, against a
**throwaway** server — never the live `-L amux` one:

```bash
sdir="$(mktemp -d /tmp/amx.XXXX)"
AMUX_SOCKET="$sdir/s" ./bin/amux spawn demo
# split a helper beside it, stamp both by hand, then attach and look:
AMUX_SOCKET="$sdir/s" ./bin/amux status
tmux -S "$sdir/s" attach
# expect: one tab badged with two glyphs, borders naming each pane's state,
#         prefix a listing the window with both panes nested under a header.
tmux -S "$sdir/s" kill-server; rm -rf "$sdir"
```

Confirm: the tab shows both glyphs; a plain shell pane adds no glyph; `prefix a`
groups the split window and collapses single-pane windows; `prefix b` lands on
the blocked pane; `prefix S` changes glyphs and the bar updates with no restamp.
