# Stable-id addressing + pane helpers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make amux agent targets drift-proof (stable tmux ids) and add `amux split` — a background helper pane in the current window with direction/source control for arbitrary layouts.

**Architecture:** `bin/amux` gains stable-id support: `target()` accepts `@N`/`%N`; `spawn`/`whoami` emit the pane id `%N` (instead of the drift-prone `session:index`); a new `split` subcommand creates a background pane and emits its `%N`; `status`/switcher surface `%N`. Friendly forms remain accepted as input (backward-compatible). One agent/helper = one pane, addressed by `%N`.

**Tech Stack:** bash (must run under bash 3.2), tmux (`-L amux` prod), fzf.

## Global Constraints

- **tmux 3.1 floor; bash 3.2 safe** — no `printf '\uXXXX'` (`\xHH` only); no bash4+ features.
- **Canonical emitted target = pane id `%N`.** `spawn`/`split`/`whoami` print `%N`. Consumers (`send`/`read`/`wait-done`/`split -t`) accept `%N`, `@N`, AND friendly forms (`session:index`, `session:window.pane`, bare name) — input is backward-compatible; only emitted format changes.
- **Never break a running agent / never touch the real `-L amux` server in tests** — all subcommands honor the `AMUX_SOCKET` seam (name→`-L`, path→`-S`).
- `bin/amux` runs under `set -euo pipefail` — guard expected-failure command substitutions; nothing aborts mid-operation.
- **No reference to any external competitor project** in any committed file or commit message.
- Verified mechanics (confirmed on a throwaway server): `new-window -d -P -F '#{pane_id}'` and `split-window -d -P -F '#{pane_id}'` print the new pane's `%N` without stealing focus; `send`/`read`/`show-options -w` all accept `%N`; the full-left-agent + stacked-right layout is built with `split -h` off the agent then `split -v -t <right-pane>`.

---

## File Structure

- Modify `bin/amux` — `target()` (accept ids), `spawn`/`whoami` (emit `%N`), new `split` branch, `status` (lead with `%N`), usage strings.
- Modify `scripts/amux-switch` — target column shows `%N`.
- Modify `tests/test-coordination.sh` — update whoami/spawn/switcher assertions to `%N`; add id-input assertions.
- Create `tests/test-panes.sh` — split behavior + layout.
- Modify `skills/amux/SKILL.md`, `README.md` — stable-id targets, `split`, layout, boundary.

---

### Task 1: `target()` accepts stable ids

**Files:**
- Modify: `bin/amux:71` (`target()`)
- Test: `tests/test-coordination.sh` (append)

**Interfaces:**
- Produces: `send`/`read`/`wait-done` accept a stable `%N` (pane) or `@N` (window) target, in addition to the existing friendly forms.

- [ ] **Step 1: Write the failing test** — append to `tests/test-coordination.sh`

```bash
# --- stable-id targets: send/read accept %N (pane) and @N (window) ---
recvpane="$(T display-message -p -t "$recv" '#{pane_id}')"   # %N
"$AMUX" send "$recvpane" "printf 'PID-%s\n' OK"
wait_for "$recvpane" 'PID-OK' \
  && assert_eq ok ok "send routes a %N pane-id target" \
  || assert_eq no-exec executed "send routes a %N pane-id target"
"$AMUX" read "$recvpane" 5 | grep -q 'PID-OK' \
  && assert_eq ok ok "read routes a %N pane-id target" \
  || assert_eq "" read "read routes a %N pane-id target"
recvwin="$(T display-message -p -t "$recv" '#{window_id}')"  # @N
"$AMUX" send "$recvwin" "printf 'WID-%s\n' OK"
wait_for "$recvwin" 'WID-OK' \
  && assert_eq ok ok "send routes an @N window-id target" \
  || assert_eq no-exec executed "send routes an @N window-id target"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-coordination.sh`
Expected: FAIL — `target()` turns `%N`/`@N` into `main:%N`/`main:@N`, so `send` errors with "no such target".

- [ ] **Step 3: Implement** — `bin/amux:71`

Replace:
```bash
target() { case "$1" in *:*) printf '%s' "$1" ;; *) printf '%s:%s' "$DEFAULT_SESSION" "$1" ;; esac; }
```
with:
```bash
# @N (window-id) / %N (pane-id) / anything with a colon → verbatim; a bare word → default session.
target() { case "$1" in @*|%*|*:*) printf '%s' "$1" ;; *) printf '%s:%s' "$DEFAULT_SESSION" "$1" ;; esac; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-coordination.sh` and `/bin/bash tests/test-coordination.sh`
Expected: PASS (existing assertions + the three new id-routing ones).

- [ ] **Step 5: Commit**

```bash
git add bin/amux tests/test-coordination.sh
git commit -m "feat(amux): accept stable tmux ids (@N window, %N pane) as targets"
```

---

### Task 2: `spawn` + `whoami` emit `%N`

**Files:**
- Modify: `bin/amux` (`whoami`, `spawn` branches)
- Test: `tests/test-coordination.sh` (update whoami/spawn assertions)

**Interfaces:**
- Consumes: `target()` id support (Task 1).
- Produces: `amux whoami` prints the caller's pane id `%N`; `amux spawn NAME [CMD]` prints the new window's pane id `%N`. Guards unchanged.

- [ ] **Step 1: Update the tests to expect `%N`** — in `tests/test-coordination.sh`

Replace the whoami block's assertion:
```bash
me="$(TMUX_PANE="$pane" "$AMUX" whoami)"
assert_eq "$me" "$recv" "whoami prints the caller's session:index"
```
with:
```bash
me="$(TMUX_PANE="$pane" "$AMUX" whoami)"
assert_eq "$me" "$pane" "whoami prints the caller's pane id (%N)"
```
(`$pane` is already `T display-message -p -t "$recv" '#{pane_id}'` earlier in the file.)

In the spawn block, replace the `contains ":"` / window-count assertions' target checks so they expect a pane id. Specifically change:
```bash
assert_contains "$new" ":" "spawn prints a session:index target"
```
to:
```bash
case "$new" in %*) assert_eq ok ok "spawn prints a stable pane id (%N)" ;; *) assert_eq "$new" "%..." "spawn prints a stable pane id (%N)" ;; esac
```
and change the resolve check to use pane scope:
```bash
[ -n "$(T display-message -p -t "$new" '#{pane_id}')" ] \
  && assert_eq ok ok "spawn's printed target resolves to a live pane" \
  || assert_eq "" live "spawn's printed target resolves to a live pane"
```
(Keep the `spawn creates a new window` window-count assertion and the no-focus-steal assertion as-is — those still hold.)

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-coordination.sh`
Expected: FAIL — `whoami`/`spawn` still emit `session:index`, so `$me != $pane` and `$new` has no `%`.

- [ ] **Step 3: Implement** — `bin/amux`

In `whoami`, change the format string:
```bash
    me="$(t display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>/dev/null || true)"
```
(and update the branch's leading comment to "prints the caller's pane id"). The `$TMUX_PANE` guard and the `[ -n "$me" ] || exit 1` fallback stay.

In `spawn`, change the emit format:
```bash
    t new-window -d -P -F '#{pane_id}' -t "=$sess:" -n "$name" -c "$PWD" "$@"
```
(the `-d`, `-t "=$sess:"`, `-n "$name"`, session logic all stay — only `-F` changes).

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-coordination.sh` and `/bin/bash tests/test-coordination.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/amux tests/test-coordination.sh
git commit -m "feat(amux): spawn/whoami emit stable pane ids (%N), drift-proof"
```

---

### Task 3: `amux split [-h|-v] [-t FROM] [CMD...]`

**Files:**
- Modify: `bin/amux` (new `split` branch; usage header + final usage string)
- Test: `tests/test-panes.sh` (new)

**Interfaces:**
- Consumes: `target()` id support (Task 1); `t()` seam.
- Produces: `amux split [-h|-v] [-t FROM] [CMD...]` — a background pane in the caller's (or FROM's) window; prints the new pane id `%N`. Guards on `$TMUX_PANE`/`-t`.

- [ ] **Step 1: Write the failing test** — `tests/test-panes.sh`

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
AMUX="$HERE/bin/amux"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_SOCKET="$sock"

wait_for() { local t="$1" p="$2" n=20; while [ "$n" -gt 0 ]; do T capture-pane -p -t "$t" 2>/dev/null | grep -q "$p" && return 0; sleep 0.2; n=$((n-1)); done; return 1; }

w="$(T display-message -p '#{window_id}')"
agent="$(T display-message -p '#{pane_id}')"

# split adds a background pane to the current window, prints %N, no focus steal
before="$(T list-panes -t "$w" | wc -l | tr -d ' ')"
active_before="$(T display-message -p -t "$w" '#{pane_id}')"
p="$(TMUX_PANE="$agent" "$AMUX" split)"
after="$(T list-panes -t "$w" | wc -l | tr -d ' ')"
assert_eq "$after" "$((before + 1))" "split adds a pane to the current window"
case "$p" in %*) assert_eq ok ok "split prints a stable pane id (%N)" ;; *) assert_eq "$p" "%..." "split prints a stable pane id (%N)" ;; esac
[ -n "$(T display-message -p -t "$p" '#{pane_id}')" ] \
  && assert_eq ok ok "split's target resolves to a live pane" || assert_eq "" live "split's target resolves to a live pane"
assert_eq "$(T display-message -p -t "$w" '#{pane_id}')" "$active_before" "split does not steal focus (active pane unchanged)"

# send/read work against the split pane's %N
"$AMUX" send "$p" "printf 'SPLIT-%s\n' OK"
wait_for "$p" 'SPLIT-OK' \
  && assert_eq ok ok "send/read reach a split pane by %N" || assert_eq no-exec executed "send/read reach a split pane by %N"

# CMD form runs and still prints a pane id
p2="$(TMUX_PANE="$agent" "$AMUX" split true)"
case "$p2" in %*) assert_eq ok ok "split CMD prints a pane id" ;; *) assert_eq "$p2" "%..." "split CMD prints a pane id" ;; esac

# guard: outside amux (no TMUX_PANE, no -t) exits 1
out="$(env -u TMUX_PANE "$AMUX" split 2>&1)"; rc=$?
assert_eq "$rc" "1" "split outside amux exits 1"
assert_contains "$out" "not inside an amux session" "split explains it's outside amux"

# layout: full-left agent + stacked-right via -h then -v -t <right>
w2="$(T new-window -P -F '#{window_id}')"
a2="$(T display-message -p -t "$w2" '#{pane_id}')"
r1="$(TMUX_PANE="$a2" "$AMUX" split -h)"
r2="$(TMUX_PANE="$a2" "$AMUX" split -v -t "$r1")"
assert_eq "$(T display-message -p -t "$a2" '#{pane_left}')" "0" "layout: agent pane on the left edge"
[ "$(T display-message -p -t "$r1" '#{pane_left}')" -gt 0 ] \
  && assert_eq ok ok "layout: right column is right of the agent" || assert_eq "" right "layout: right column is right of the agent"
[ "$(T display-message -p -t "$r2" '#{pane_top}')" -gt "$(T display-message -p -t "$r1" '#{pane_top}')" ] \
  && assert_eq ok ok "layout: right panes stack (r2 below r1)" || assert_eq "" stacked "layout: right panes stack (r2 below r1)"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-panes.sh`
Expected: FAIL — `split` is an unknown subcommand (hits the `*)` usage branch, nonzero).

- [ ] **Step 3: Implement the `split` branch** — `bin/amux` (add near `spawn)`)

```bash
  split)
    shift
    dir=""; from="${TMUX_PANE:-}"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -h) dir="-h"; shift ;;
        -v) dir="-v"; shift ;;
        -t) from="${2:?amux split: -t needs a target}"; shift 2 ;;
        --) shift; break ;;
        -*) echo "amux split: unknown flag '$1'" >&2; exit 2 ;;
        *)  break ;;
      esac
    done
    [ -n "$from" ] || { echo "amux split: not inside an amux session" >&2; exit 1; }
    # Background helper pane in FROM's window; -d = no focus steal; prints its %N.
    t split-window $dir -d -P -F '#{pane_id}' -t "$from" -c "$PWD" "$@"
    ;;
```

- [ ] **Step 4: Update usage** — `bin/amux`

In the usage-comment header, after the `amux spawn ...` line add:
```
#   amux split [-h|-v] [-t P] [CMD]  open a helper pane in the current window; prints its %N
```
Add `split` to the final `*)` usage string:
```bash
  *) echo "usage: amux [up|session NAME|new NAME [SESSION]|spawn NAME [CMD]|split [-h|-v] [-t P] [CMD]|whoami|ssh HOST|send TGT TEXT|read TGT [N]|wait-done TGT [T]|hooks|doctor|init|settings|status|kill [SESSION]]" >&2; exit 2 ;;
```

- [ ] **Step 5: Run tests (both bash versions)**

Run: `bash tests/test-panes.sh` and `/bin/bash tests/test-panes.sh`
Expected: PASS (all split + layout assertions).

- [ ] **Step 6: Commit**

```bash
git add bin/amux tests/test-panes.sh
git commit -m "feat(amux): split — background helper pane in the current window with layout control"
```

---

### Task 4: `status` + switcher surface `%N`

**Files:**
- Modify: `bin/amux` (`status` branch)
- Modify: `scripts/amux-switch` (target column)
- Test: `tests/test-coordination.sh` (update the switcher unit-check), add a `status` check

**Interfaces:**
- Produces: `amux status` window rows lead with the stable `%N` target; the switcher's visible target column shows `%N`.

- [ ] **Step 1: Update/add the failing tests** — `tests/test-coordination.sh`

Find the appended switcher unit-check (the block feeding a synthetic tab row through the awk, asserting `main:2`). Change its field-10 value from `main:2` to a pane id and assert that:
```bash
# fields: sid \t wid \t state \t since \t name \t cmd \t path \t glyph \t idleglyph \t %N
row="$(printf '$0\t@1\tidle\t\tapi\tzsh\tapi\t💤\t💤\t%%7\n')"
line="$(printf '%s' "$row" | awk -F'\t' -v now=100 '
  { st=$3; since=$4; el=(since==""?0:now-since); m=int(el/60);
    dot=($8!=""?$8:($9!=""?$9:"💤")); tgt=$10;
    printf "%s %-8s %3dm  %-14s %s  (%s/%s)\n", dot, st, m, tgt, $5, $6, $7 }')"
assert_contains "$line" "%7" "switcher row shows the %N send-target"
assert_contains "$line" "api" "switcher row still shows the window name"
```
And add a `status` check near the end (the test server has a session, so `status` prints window rows):
```bash
# status leads each window row with the stable %N target
"$AMUX" status | grep -qE '%[0-9]' \
  && assert_eq ok ok "amux status shows a stable %N target" \
  || assert_eq "" pane-id "amux status shows a stable %N target"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-coordination.sh`
Expected: FAIL — switcher still emits `session:index` (no `%7`); `status` has no `%N` column yet.

- [ ] **Step 3: Implement** — `scripts/amux-switch` and `bin/amux`

In `scripts/amux-switch`, change field 10 of the `-F` from `#{session_name}:#{window_index}` to `#{pane_id}`:
```
  -F '#{session_id}	#{window_id}	#{@agent_state}	#{@agent_since}	#{window_name}	#{pane_current_command}	#{b:pane_current_path}	#{@agent_glyph}	#{@amux-glyph-idle}	#{pane_id}')"
```
(the awk already renders `tgt=$10`; no awk change needed).

In `bin/amux` `status`, lead the window row with the active pane id:
```bash
      t list-windows -a -F '    #{pane_id}  #{session_name}:#I #{window_name}/#{pane_current_command}  [#{@agent_state}]'
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-coordination.sh` and `/bin/bash tests/test-coordination.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/amux scripts/amux-switch tests/test-coordination.sh
git commit -m "feat(amux): surface stable %N targets in status and the switcher"
```

---

### Task 5: SKILL + README + skill-integrity

**Files:**
- Modify: `skills/amux/SKILL.md`
- Modify: `README.md`
- Test: `tests/test-coordination.sh` (extend the skill-integrity command list with `split`)

**Interfaces:**
- Consumes: all prior tasks (`split`, `%N` emit/accept).

- [ ] **Step 1: Update the skill-integrity test** — `tests/test-coordination.sh`

In the skill-integrity loop, add `split` to the command list it checks:
```bash
for cmd in whoami spawn split send wait-done read status; do
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-coordination.sh`
Expected: FAIL — `skills/amux/SKILL.md` doesn't mention `amux split` yet.

- [ ] **Step 3: Update the SKILL** — `skills/amux/SKILL.md`

- Change target guidance to note **targets are stable ids** captured from
  `spawn`/`split`/`whoami` (they don't drift); friendly `session:index`/names
  still work when a human types them.
- Update the send example to capture-and-use an id:
  ```sh
  me="$(amux whoami)"
  helper="$(amux spawn claude)"        # a co-agent in its own window → its %N
  amux send "$helper" "[from $me] review the diff and reply with issues"
  amux wait-done "$helper" 120
  amux read "$helper" 40
  ```
- Add a "helpers in your current window" section:
  ```sh
  logs="$(amux split htop)"            # a helper pane beside you → its %N
  amux send "$logs" "…" ; amux read "$logs"
  ```
  and the layout note:
  ```sh
  # agent full-left, a stack of helpers on the right:
  r1="$(amux split -h claude)"         # right column
  r2="$(amux split -v -t "$r1" claude)"# stacked below r1
  ```
- **Boundary:** `spawn` (window) for a co-agent you `wait-done` on; `split`
  (pane) for helpers you `send`/`read` (pane state is shared with its window, so
  `wait-done` on a split pane is not per-pane).

- [ ] **Step 4: Update the README** — `README.md`

In the "Driving agents from inside amux" section: note targets are stable ids
(e.g. `%12`) captured from `spawn`/`split`/`whoami`, and add:
```markdown
- `amux split [-h|-v] [-t P] [cmd]` — a helper pane in your current window (prints its `%N`); compose layouts by splitting a specific pane
```
Keep the `spawn`-vs-`split` one-liner (window co-agent you wait-done on vs. pane helper you pipe to).

- [ ] **Step 5: Run the full suite (both bash) + confirm no forbidden term**

Run: `bash tests/run.sh` then `/bin/bash tests/run.sh`
Expected: both `N passed, 0 failed` (including `test-panes.sh` and the updated `test-coordination.sh`).
Also confirm no committed file names the barred external competitor project (a strict project rule) — a repo-wide grep for it must return nothing.

- [ ] **Step 6: Commit**

```bash
git add skills/amux/SKILL.md README.md tests/test-coordination.sh
git commit -m "docs(amux): stable-id targets, split helpers, and layouts in the skill + README"
```

---

## Self-Review notes (for the implementer)

- **Emit vs accept:** only `spawn`/`split`/`whoami` change what they PRINT (`%N`). `send`/`read`/`wait-done` change only what they ACCEPT (via `target()`), and still take the friendly forms — no existing human muscle-memory breaks.
- **`$dir` unquoted on purpose:** `t split-window $dir …` must word-split to nothing when `dir=""`; it's always set (default `""`), so `set -u` is satisfied.
- **`split` guard:** `from` defaults to `$TMUX_PANE`; empty (no pane, no `-t`) → exit 1. An explicit `-t` lets it run outside amux.
- **Cross-test updates:** Tasks 2 and 4 update assertions in the *already-passing* `tests/test-coordination.sh` because the emitted/ displayed format changed — that's expected, not a regression.
- **bash 3.2 / no `\u`:** the switcher emoji stay literal bytes; the SKILL is plain text.
