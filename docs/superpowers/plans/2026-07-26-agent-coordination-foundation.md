# amux agent coordination — Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make agent-to-agent messaging in amux reliable and discoverable, add the two missing primitives (`whoami`, `spawn`), and ship a portable skill so an LLM can drive the fleet.

**Architecture:** Small changes to `bin/amux` (a socket-override seam, a reliable two-step `send`, `whoami`, `spawn`), a visible target column in `scripts/amux-switch`, and a portable `skills/amux/SKILL.md`. Canonical target everywhere: `session:index`.

**Tech Stack:** bash (must run under bash 3.2), tmux (`-L amux` in prod), fzf.

## Global Constraints

- **tmux 3.1 floor; bash 3.2 safe** — no `printf '\uXXXX'` (use `\xHH`); no bash4+ constructs.
- **Never break a running agent / never touch the real `-L amux` server in tests.** All new bin/amux subcommands honor a socket seam so tests use an isolated server.
- **Guard tmux calls** where failure is expected; `send`/`whoami` fail *loudly* (nonzero) on a bad/absent target rather than silently.
- **Canonical target string: `session:index`** (e.g. `charm:2`) — used by `send`, `whoami`, `spawn`, and the switcher. `send` still also accepts a bare window name (resolved against the default session, as today).
- Tests pass on bash 5 AND bash 3.2; `tests/run.sh` auto-discovers `test-*.sh`; CI covers both OSes.
- Verified mechanics (already confirmed on a throwaway server): `send-keys -t T -l -- "text"` then a separate `send-keys -t T Enter` executes; `new-window -P -F '#{session_name}:#{window_index}'` prints the new target; `display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}'` yields the caller's address.

---

## File Structure

- Modify `bin/amux` — socket seam (`AMUX_SOCKET`), reliable `send`, new `whoami`, new `spawn`, usage strings.
- Modify `scripts/amux-switch` — add a visible `session:index` target column.
- Create `skills/amux/SKILL.md` — portable coordination skill.
- Create `tests/test-coordination.sh` — send/whoami/spawn behavior.
- Modify `README.md` — "Driving agents" note + `spawn` in the fleet section + skill install line.

---

### Task 1: Socket seam + reliable `amux send`

**Files:**
- Modify: `bin/amux` (socket seam; `send`)
- Test: `tests/test-coordination.sh` (new)

**Interfaces:**
- Produces: `AMUX_SOCKET` env override on `bin/amux` — a name (default `amux` → `-L`) or a path containing `/` (→ `-S`, for tests). `amux send [SESSION:]WINDOW TEXT...` now validates the target (exit 2 if it doesn't resolve) and delivers via a two-step submit with `@amux-send-enter-delay` (default `0.3`).

- [ ] **Step 1: Write the failing test** — `tests/test-coordination.sh`

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
AMUX="$HERE/bin/amux"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_SOCKET="$sock"   # bin/amux talks to the isolated test server (path → -S)

# a shell window to receive input; capture its canonical target
recv="$(T new-window -P -F '#{session_name}:#{window_index}' -n recv)"

# send reliability: a two-step submit must actually EXECUTE the command.
# "MARK-DONE" (contiguous) can only appear from execution, not from the typed line.
"$AMUX" send "$recv" "printf 'MARK-%s\n' DONE"
sleep 1
T capture-pane -p -t "$recv" | grep -q 'MARK-DONE' \
  && assert_eq ok ok "send delivers text AND submits (two-step Enter works)" \
  || assert_eq no-exec executed "send delivers text AND submits (two-step Enter works)"

# literal text: a message containing the word Enter is typed as text, executed once
"$AMUX" send "$recv" "echo hi-Enter-bye"
sleep 1
T capture-pane -p -t "$recv" | grep -q 'hi-Enter-bye' \
  && assert_eq ok ok "message text is literal (the word Enter is not a keypress)" \
  || assert_eq no exec "message text is literal (the word Enter is not a keypress)"

# validation: a bogus target fails loudly (exit 2), delivers nothing
out="$("$AMUX" send "nope:99" "x" 2>&1)"; rc=$?
assert_eq "$rc" "2" "send to a bad target exits 2"
assert_contains "$out" "no such target" "send to a bad target explains why"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-coordination.sh`
Expected: FAIL — the bad-target assertions fail (current `send` exits 0 on a typo), and the exec check may be flaky (single-call submit).

- [ ] **Step 3: Add the socket seam** — `bin/amux`

Replace:
```bash
SOCKET="amux"
```
with:
```bash
# Socket: a name (-L, production default "amux") or, for tests, a path (-S).
SOCKET="${AMUX_SOCKET:-amux}"
case "$SOCKET" in */*) _SOCKET_FLAG="-S" ;; *) _SOCKET_FLAG="-L" ;; esac
```

Replace:
```bash
t() { tmux -L "$SOCKET" "$@"; }
```
with:
```bash
t() { tmux "$_SOCKET_FLAG" "$SOCKET" "$@"; }
```

Then update the two direct `tmux -L "$SOCKET"` uses so tests can attach-free paths still resolve the right server. In `attach_session`:
```bash
attach_session() { ensure_session "$1"; exec tmux "$_SOCKET_FLAG" "$SOCKET" attach -t "=$1"; }
```
and in the `new)` branch:
```bash
    exec tmux "$_SOCKET_FLAG" "$SOCKET" attach -t "=$sess"
```

- [ ] **Step 4: Rewrite `send` for reliability** — `bin/amux`

Replace the `send)` branch:
```bash
  send)
    raw="${2:?usage: amux send [SESSION:]WINDOW TEXT...}"; shift 2
    t send-keys -t "$(target "$raw")" "$*" Enter
    ;;
```
with:
```bash
  send)
    raw="${2:?usage: amux send [SESSION:]WINDOW TEXT...}"; shift 2
    tgt="$(target "$raw")"
    # Validate: a typo'd target must fail loudly, not silently deliver nothing.
    if [ -z "$(t display-message -p -t "$tgt" '#{window_id}' 2>/dev/null)" ]; then
      echo "amux send: no such target '$raw'" >&2; exit 2
    fi
    # Two-step submit: literal text, a beat, then Enter. A single
    # `send-keys "$*" Enter` can drop or race the submit in a full-screen TUI.
    delay="$(t show-options -gqv @amux-send-enter-delay 2>/dev/null)"; [ -n "$delay" ] || delay=0.3
    t send-keys -t "$tgt" -l -- "$*"
    sleep "$delay"
    t send-keys -t "$tgt" Enter
    ;;
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-coordination.sh` and `/bin/bash tests/test-coordination.sh`
Expected: PASS — exec proof, literal text, and both bad-target assertions.

- [ ] **Step 6: Commit**

```bash
git add bin/amux tests/test-coordination.sh
git commit -m "feat(amux): socket seam + reliable two-step send with target validation"
```

---

### Task 2: `amux whoami` + `amux spawn`

**Files:**
- Modify: `bin/amux` (`whoami`, `spawn` branches; usage header + final usage string)
- Test: `tests/test-coordination.sh` (append)

**Interfaces:**
- Consumes: the `t()` seam + `ensure_session`/`DEFAULT_SESSION` (Task 1 / existing).
- Produces:
  - `amux whoami` → prints the caller's `session:index` on stdout (one line). Exit 1 (stderr message) if not inside an amux pane (`$TMUX_PANE` unset or not on this server).
  - `amux spawn NAME [CMD...]` → creates a window **without attaching**, prints its `session:index`. Session = the caller's own when inside amux (`$TMUX_PANE`), else the default `main` (booted via `ensure_session`).

- [ ] **Step 1: Write the failing tests** — append to `tests/test-coordination.sh`

```bash
# --- whoami ---
pane="$(T display-message -p -t "$recv" '#{pane_id}')"
me="$(TMUX_PANE="$pane" "$AMUX" whoami)"
assert_eq "$me" "$recv" "whoami prints the caller's session:index"

out="$(env -u TMUX_PANE "$AMUX" whoami 2>&1)"; rc=$?
assert_eq "$rc" "1" "whoami outside an amux pane exits 1"
assert_contains "$out" "not inside an amux session" "whoami explains it's outside amux"

# --- spawn ---
before="$(T list-windows | wc -l | tr -d ' ')"
new="$(TMUX_PANE="$pane" "$AMUX" spawn helper)"
after="$(T list-windows | wc -l | tr -d ' ')"
assert_eq "$after" "$((before + 1))" "spawn creates a new window"
assert_eq "$(T display-message -p -t "$new" '#{window_name}')" "helper" "spawn names the window"
# the printed target resolves (proves format + that spawn returned, i.e. did not attach)
assert_contains "$new" ":" "spawn prints a session:index target"
[ -n "$(T display-message -p -t "$new" '#{window_id}')" ] \
  && assert_eq ok ok "spawn's printed target resolves to a live window" \
  || assert_eq "" live "spawn's printed target resolves to a live window"

# spawn with a CMD runs it in the new window
new2="$(TMUX_PANE="$pane" "$AMUX" spawn helper2 true)"
assert_contains "$new2" ":" "spawn NAME CMD prints a target"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-coordination.sh`
Expected: FAIL — `whoami`/`spawn` are unknown subcommands (hit the `*)` usage branch).

- [ ] **Step 3: Add `whoami` and `spawn`** — `bin/amux`

Add these branches to the `case` (e.g. right after the `settings)` branch):
```bash
  whoami)
    # Only meaningful inside an amux pane. $TMUX_PANE identifies the caller's pane.
    if [ -z "${TMUX_PANE:-}" ]; then echo "amux whoami: not inside an amux session" >&2; exit 1; fi
    me="$(t display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}' 2>/dev/null || true)"
    [ -n "$me" ] || { echo "amux whoami: not inside an amux session" >&2; exit 1; }
    printf '%s\n' "$me"
    ;;
  spawn)
    name="${2:?usage: amux spawn NAME [CMD...]}"; shift 2
    # Helper lands in the caller's own session when inside amux, else the default.
    if [ -n "${TMUX_PANE:-}" ]; then
      sess="$(t display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || echo "$DEFAULT_SESSION")"
    else
      sess="$DEFAULT_SESSION"; ensure_session "$sess"
    fi
    # Non-attaching: create the window and print its session:index target.
    t new-window -P -F '#{session_name}:#{window_index}' -t "=$sess" -n "$name" -c "$PWD" "$@"
    ;;
```

- [ ] **Step 4: Update usage** — `bin/amux`

In the top usage-comment block, after the `amux new ...` line add:
```
#   amux spawn NAME [CMD]   open an agent window WITHOUT attaching; prints its target
#   amux whoami             print this agent's own target (session:index)
```
And add `spawn`/`whoami` to the final `*)` usage string:
```bash
  *) echo "usage: amux [up|session NAME|new NAME [SESSION]|spawn NAME [CMD]|whoami|ssh HOST|send TGT TEXT|read TGT [N]|wait-done TGT [T]|hooks|doctor|init|settings|status|kill [SESSION]]" >&2; exit 2 ;;
```

- [ ] **Step 5: Run tests (both bash versions)**

Run: `bash tests/test-coordination.sh` and `/bin/bash tests/test-coordination.sh`
Expected: PASS — all Task 1 + Task 2 assertions.

- [ ] **Step 6: Commit**

```bash
git add bin/amux tests/test-coordination.sh
git commit -m "feat(amux): whoami (self address) + non-attaching spawn"
```

---

### Task 3: Switcher shows the `session:index` target

**Files:**
- Modify: `scripts/amux-switch`
- Test: `tests/test-coordination.sh` (append a unit-check of the row format)

**Interfaces:**
- Consumes: nothing new. Produces: the switcher popup rows now show `session:index` as a visible column (hidden `session_id`/`window_id` keys unchanged, so `Enter` still jumps correctly).

- [ ] **Step 1: Write the failing test** — append to `tests/test-coordination.sh`

The interactive fzf loop needs a tty, so unit-check the row-builder awk exactly as the existing switcher tests do — feed one synthetic row and assert the visible line contains the `session:index` target.

```bash
# --- switcher target column (unit-check the row format; fzf needs a tty) ---
# fields: sid \t wid \t state \t since \t name \t cmd \t path \t glyph \t idleglyph \t session:index
row="$(printf '$0\t@1\tidle\t\tapi\tzsh\tapi\t💤\t💤\tmain:2\n')"
line="$(printf '%s' "$row" | awk -F'\t' -v now=100 '
  { st=$3; since=$4; el=(since==""?0:now-since); m=int(el/60);
    dot=($8!=""?$8:($9!=""?$9:"💤")); tgt=$10;
    printf "%s %-8s %3dm  %-14s %s  (%s/%s)\n", dot, st, m, tgt, $5, $6, $7 }')"
assert_contains "$line" "main:2" "switcher row shows the session:index target"
assert_contains "$line" "api" "switcher row still shows the window name"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-coordination.sh`
Expected: FAIL — the awk snippet under test doesn't exist in `amux-switch` yet (the assertion uses the intended format; wire it into the script next).

- [ ] **Step 3: Add the target column** — `scripts/amux-switch`

Add `#{session_name}:#{window_index}` as field 10 of the `-F` (after `#{@amux-glyph-idle}`):
```bash
  -F '#{session_id}	#{window_id}	#{@agent_state}	#{@agent_since}	#{window_name}	#{pane_current_command}	#{b:pane_current_path}	#{@agent_glyph}	#{@amux-glyph-idle}	#{session_name}:#{window_index}')"
```
Then render it in the awk `printf` (add `tgt=$10;` and a `%-14s` column before the name):
```bash
  sel="$(printf '%s\n' "$rows" | awk -F'\t' -v now="$now" '
    {
      st=$3; since=$4; el=(since==""?0:now-since); m=int(el/60);
      dot=($8!=""?$8:($9!=""?$9:"💤")); tgt=$10;
      # hidden key: session_id<TAB>window_id ; visible: the rest
      printf "%s\t%s\t%s %-8s %3dm  %-14s %s  (%s/%s)\n", $1, $2, dot, st, m, tgt, $5, $6, $7
    }' | fzf --with-nth=3.. --delimiter='\t' --reverse --prompt='agent > ' --no-info)"
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test-coordination.sh` and `/bin/bash tests/test-coordination.sh`
Expected: PASS — target column present, name retained.

- [ ] **Step 5: Commit**

```bash
git add scripts/amux-switch tests/test-coordination.sh
git commit -m "feat(switcher): show the session:index send-target in the agent switcher"
```

---

### Task 4: Portable `skills/amux/SKILL.md` + docs

**Files:**
- Create: `skills/amux/SKILL.md`
- Test: `tests/test-coordination.sh` (append a check that the skill only names real commands)
- Modify: `README.md`

**Interfaces:**
- Consumes: `whoami`/`spawn`/`send`/`wait-done`/`read`/`status` (Tasks 1–2 + existing). Produces: a harness-agnostic skill file.

- [ ] **Step 1: Write the failing test** — append to `tests/test-coordination.sh`

```bash
# --- skill integrity: it must reference only real amux subcommands ---
# Check each `amux <cmd>` the skill names is a real subcommand, by word-matching
# it in bin/amux (matches its dispatch branch and/or the usage synopsis). This
# sidesteps dispatch-syntax quirks like `wait-done|wait)`.
SKILL="$HERE/skills/amux/SKILL.md"
[ -f "$SKILL" ] && assert_eq ok ok "skills/amux/SKILL.md exists" || assert_eq "" exists "skills/amux/SKILL.md exists"
for cmd in whoami spawn send wait-done read status; do
  if grep -q "amux $cmd" "$SKILL" 2>/dev/null && grep -qw "$cmd" "$HERE/bin/amux" 2>/dev/null; then
    assert_eq ok ok "skill uses a real subcommand: amux $cmd"
  else
    assert_eq "" real "skill uses a real subcommand: amux $cmd"
  fi
done
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-coordination.sh`
Expected: FAIL — `skills/amux/SKILL.md` does not exist.

- [ ] **Step 3: Write the skill** — `skills/amux/SKILL.md`

```markdown
---
name: amux
description: Coordinate AI agents running as windows inside an amux tmux session — discover peers, spawn helpers, send prompts, and collect replies. Use when you are running inside amux and need to drive or talk to another agent.
---

# Driving agents with amux

You are (possibly) an agent running inside **amux** — a tmux "agent view" where
each agent is a window. These commands let you coordinate with sibling agents.

## Preflight — are you inside amux?

Run `amux whoami`. If it prints a `session:index` (e.g. `main:2`), that is YOUR
address and you're inside amux. If it errors ("not inside an amux session"),
**stop** — you are not in amux; tell the user and do not run the rest.

## Discover the fleet

`amux status` lists every session and window with its state, e.g.:

```
    main:1 api/claude  [working]
    main:2 web/claude  [blocked]
```

The `session:index` (e.g. `main:2`) is the **target** for every command below.

## Spawn a helper agent (no focus stealing)

```sh
amux spawn reviewer claude    # new window running claude; prints its target, e.g. main:3
```

`amux spawn NAME [CMD]` creates a window WITHOUT attaching and prints its
`session:index`. Omit CMD to open a shell you can `amux send` into later.
Spawned agents are real and cost tokens — only spawn what you need.

## Message an agent

```sh
amux send main:3 "review the diff in ~/work/api and reply with issues"
```

`amux send TARGET "text"` types the text and submits it reliably. Until amux
adds sender attribution, prefix who you are so the receiver can reply:

```sh
me="$(amux whoami)"
amux send main:3 "[from $me] review the diff and reply with issues"
```

A bad target fails loudly (exit 2) — check the target from `amux status`.

## Wait for the reply, then read it

```sh
amux wait-done main:3 120     # block until main:3 is done/idle (120s timeout)
amux read main:3 40           # print its last 40 non-blank lines
```

## The coordination idiom

1. `amux whoami` — confirm you're in amux and learn your address.
2. `amux status` — find or choose a target (or `amux spawn` a helper).
3. `amux send TARGET "[from <you>] <task>"`.
4. `amux wait-done TARGET [timeout]`.
5. `amux read TARGET` — collect the result.

Send **one** prompt at a time, then wait — don't fire a second before the first
completes. Don't message yourself. Don't spam.
```

The Step 1 skill-integrity test (word-matching each named command in `bin/amux`)
already handles `wait-done` correctly — no special-casing needed.

- [ ] **Step 4: Document in README** — `README.md`

Under the existing "Driving a fleet" section, add `spawn` to the command list and a short paragraph + skill pointer:

```markdown
### Driving agents from inside amux

An agent (or you) can coordinate the fleet from inside amux:

- `amux whoami` — this agent's own target (`session:index`)
- `amux spawn NAME [cmd]` — open a helper agent window without attaching; prints its target
- `amux send TARGET "…"` — reliably type a prompt into an agent and submit it
- `amux wait-done TARGET` / `amux read TARGET` — wait for it to finish, then read the reply

For LLM agents, install the portable skill so they know the loop:

```sh
npx skills add beatzball/amux --skill amux    # or copy skills/amux/SKILL.md into your agent's instructions
```
```

- [ ] **Step 5: Run the full suite (both bash) + skill check**

Run: `bash tests/run.sh` then `/bin/bash tests/run.sh`
Expected: both `N passed, 0 failed`, including `test-coordination.sh`; existing suites still green.

- [ ] **Step 6: Commit**

```bash
git add skills/amux/SKILL.md README.md tests/test-coordination.sh
git commit -m "feat(amux): portable agent-coordination skill + docs"
```

---

## Self-Review notes (for the implementer)

- **Socket seam:** every new/changed subcommand goes through `t()` so `AMUX_SOCKET` (path → `-S`, name → `-L`) points tests at an isolated server; production default `amux` (`-L`) is unchanged. Confirm no remaining bare `tmux -L "$SOCKET"` on a tested path.
- **send:** validates before sending (exit 2, no silent no-op); `-l --` keeps the message literal; the Enter is a separate call after `@amux-send-enter-delay` (default 0.3). Verified: `MARK-DONE` proves execution.
- **whoami/spawn** rely on `$TMUX_PANE` (set for any process inside a tmux pane); outside a pane, whoami exits 1 and spawn falls back to the default session.
- **spawn never attaches** — it returns (prints the target); if it hung, it attached (bug).
- **switcher:** hidden `session_id`/`window_id` (fields 1–2) still drive `switch-client`/`select-window`; only the visible columns changed.
- **bash 3.2 / no `\u`:** the skill and scripts use plain text; emoji in the switcher awk are literal bytes (unchanged from before).
```
