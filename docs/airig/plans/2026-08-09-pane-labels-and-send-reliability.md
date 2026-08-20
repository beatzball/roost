# Pane Labels + `send` Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give panes a stable human label instead of a churning process name, and stop `amux send` from failing silently when a TUI swallows its Enter.

**Architecture:** A new pane option `@amux-name`, set by `amux split -n` and `amux spawn`, is preferred over `#{pane_current_command}` everywhere a pane is labelled. `amux send` gains a bounded verify-and-retry around its submit, and exits non-zero when the text demonstrably never left the input line.

**Tech Stack:** bash (3.2-compatible), tmux ≥ 3.2 formats, no new dependencies.

## Global Constraints

- **bash 3.2 compatible.** macOS ships bash 3.2 as `/bin/bash`. No associative arrays, no `printf '\uXXXX'` (use `\xHH`), no `${var^^}`. An unbraced `$var` immediately followed by a multibyte character mis-tokenizes under bash 3.2 + UTF-8 — use `${var}`.
- **Tests must never touch the live server.** A real tmux server runs on socket NAME `amux` (`-L amux`) with the developer's agents in it. Tests use isolated `-S` sockets only, via `amux_test_server`.
- **Socket paths must be short** — the ~104-char unix socket limit silently corrupts long paths; build sockets under `mktemp -d /tmp/amx.XXXX`.
- **Glyph and label values may be invisible.** The developer runs the `nerd` glyph set: 3-byte Private Use Area codepoints that render as zero width in captured output. Never conclude a value is empty from how it prints — measure with `xxd -p` or `${#v}`.
- **Never round-trip a separator through tmux's format engine.** `#{a:N}` for N<32 is dropped, and a literal `0x1F` survives on tmux 3.6+ but returns as the four characters `\037` on 3.4. See the note in `scripts/amux-status`.
- **Suite stays green:** `bash tests/run.sh` must end with `0 failed`. Baseline is `198 passed, 0 failed`. Also run touched test files under `/bin/bash`.
- **Public repo.** No usernames, real names, `/Users/...` paths, or email addresses in tracked files.
- **Commit trailer is exactly this one line — no `Claude-Session:` trailer, ever:**
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```

---

### Task 1: Named panes

**Why:** `#{pane_current_command}` reports `2.1.222` for a Claude pane — the version string, which changes every release and means nothing to a reader. `pane_start_command` is empty for shell-started panes, and `pane_title` is a live task description that churns. There is no existing tmux field that is both stable and meaningful, so panes need an explicit name.

**Files:**
- Modify: `bin/amux` (the `split)` branch, the `spawn)` branch, the `status)` branch, and the usage comments at the top)
- Modify: `tmux/amux.conf` (`@amux-pane-border`, and the two `window-status-*-format` lines)
- Modify: `scripts/amux-switch` (the `list-panes -F` field list and the awk row builder)
- Test: `tests/test-panes.sh`, `tests/test-switcher.sh`

**Interfaces:**
- Produces: pane option `@amux-name` (a plain string, may contain spaces, may be unset).
- `amux split [-h|-v] [-t FROM] [-n NAME] [CMD...]` — `-n` sets `@amux-name` on the new pane. Still prints the new pane's `%N`.
- `amux spawn NAME [CMD...]` — additionally sets `@amux-name` to `NAME` on the window's pane. Unchanged output.
- Label resolution everywhere: `@amux-name` if non-empty, else `#{pane_current_command}`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-panes.sh`:

```bash
# --- named panes: a stable label beats a churning process name ---
# #{pane_current_command} reports a version string for some agents, so a pane
# can carry an explicit @amux-name that every label site prefers.
base="$(T display-message -p '#{pane_id}')"
named="$(TMUX_PANE="$base" "$AMUX" split -n reviewer)"
assert_eq "$(T show-options -pqv -t "$named" @amux-name)" "reviewer" \
  "split -n sets @amux-name on the new pane"
assert_eq "$(T show-options -pqv -t "$base" @amux-name)" "" \
  "split -n does not touch the source pane"

# without -n the option stays unset, so the label falls back to the command
plain="$(TMUX_PANE="$base" "$AMUX" split)"
assert_eq "$(T show-options -pqv -t "$plain" @amux-name)" "" \
  "split without -n leaves @amux-name unset"

# a name with a space survives (it is a label, not a token)
spaced="$(TMUX_PANE="$base" "$AMUX" split -n 'code reviewer')"
assert_eq "$(T show-options -pqv -t "$spaced" @amux-name)" "code reviewer" \
  "a pane name may contain spaces"

# -n needs an argument
out="$(TMUX_PANE="$base" "$AMUX" split -n 2>&1)"; rc=$?
assert_eq "$rc" "2" "split -n with no argument exits 2"

# spawn names its pane too, from the window name it already takes
sp="$(TMUX_PANE="$base" "$AMUX" spawn api-agent)"
assert_eq "$(T show-options -pqv -t "$sp" @amux-name)" "api-agent" \
  "spawn sets @amux-name from the window name"

# the border prefers the name over the command
border="$(T list-panes -a -F '#{pane_id}|#{E:@amux-pane-border}' | grep "^$named|" | cut -d'|' -f2)"
assert_contains "$border" "reviewer" "the pane border shows @amux-name when set"
plainborder="$(T list-panes -a -F '#{pane_id}|#{E:@amux-pane-border}' | grep "^$plain|" | cut -d'|' -f2)"
assert_contains "$plainborder" "$(T display-message -p -t "$plain" '#{pane_current_command}')" \
  "an unnamed pane's border falls back to the command"

# status prefers the name too
assert_contains "$("$AMUX" status)" "reviewer" "amux status shows @amux-name"
```

Append to `tests/test-switcher.sh`:

```bash
# --- switcher prefers @amux-name over the process name ---
T set-option -p -t "$p0" @amux-name "planner"
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
assert_contains "$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p0" '$3==p')" "planner" \
  "a named pane's switcher row shows the name"
T set-option -pu -t "$p0" @amux-name
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
cmd="$(T display-message -p -t "$p0" '#{pane_current_command}')"
assert_contains "$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p0" '$3==p')" "$cmd" \
  "an unnamed pane's switcher row falls back to the command"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test-panes.sh`
Expected: FAIL on "split -n sets @amux-name" — `-n` is currently an unknown flag, so `split` exits 2 and `$named` is empty.

- [ ] **Step 3: Add `-n` to `amux split`**

In `bin/amux`, in the `split)` branch, add a `name` variable and a `-n` case to the flag loop, then set the option after the pane is created. The pane id is already captured by `-P -F '#{pane_id}'`, so capture it into a variable rather than letting it print directly, set the option, then print it:

```bash
  split)
    shift
    dir=""; from="${TMUX_PANE:-}"; name=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -h) dir="-h"; shift ;;
        -v) dir="-v"; shift ;;
        -t) from="${2:?amux split: -t needs a target}"; shift 2 ;;
        -n) name="${2:?amux split: -n needs a name}"; shift 2 ;;
        --) shift; break ;;
        -*) echo "amux split: unknown flag '$1'" >&2; exit 2 ;;
        *)  break ;;
      esac
    done
    [ -n "$from" ] || { echo "amux split: not inside an amux session" >&2; exit 1; }
    # Background helper pane in FROM's window; -d = no focus steal; prints its %N.
    new="$(t split-window $dir -d -P -F '#{pane_id}' -t "$from" -c "$PWD" "$@")"
    # A label that survives what the process calls itself: #{pane_current_command}
    # reports a version string for some agents and changes every release.
    [ -n "$name" ] && t set-option -p -t "$new" @amux-name "$name"
    printf '%s\n' "$new"
    ;;
```

Note `${2:?...}` exits 1, not 2. The test expects 2 for a missing `-n` argument, so handle it explicitly instead:

```bash
        -n) [ "$#" -ge 2 ] || { echo "amux split: -n needs a name" >&2; exit 2; }
            name="$2"; shift 2 ;;
```

Apply the same explicit form to `-t` so the two flags behave alike, and update the test for `-t` if one exists.

- [ ] **Step 4: Name the pane in `amux spawn`**

In the `spawn)` branch, capture the printed pane id, set `@amux-name` to the window name, then print:

```bash
    new="$(t new-window -d -P -F '#{pane_id}' -t "=$sess:" -n "$name" -c "$PWD" "$@")"
    t set-option -p -t "$new" @amux-name "$name"
    printf '%s\n' "$new"
```

- [ ] **Step 5: Prefer the name in every label site**

`tmux/amux.conf`, in `@amux-pane-border`, replace the bare `#{pane_current_command}` with:

```
#{?@amux-name,#{@amux-name},#{pane_current_command}}
```

Do the same for the `#{pane_current_command}` in **both** `window-status-format` and `window-status-current-format`, so a tab labels its active pane the same way its border does.

`bin/amux`, in the `status)` branch, change the `list-panes` format's `#{pane_current_command}` to the same conditional.

`scripts/amux-switch`: add `#{@amux-name}` as a new field at the END of the `list-panes -F` list (appending keeps every existing field index valid — the sort keys and the awk field numbers must not shift), then in awk prefer it:

```awk
    nm=$13
    label = (nm != "" ? nm : cmd)
```

and use `label` in place of `cmd` in both `printf` branches.

- [ ] **Step 6: Update the usage text and docs**

`bin/amux` header comment: `amux split [-h|-v] [-t P] [-n NAME] [CMD]  open a helper pane in the current window; prints its %N`, and the same in the `usage:` line at the bottom.

`README.md`: mention `-n NAME` where `amux split` is documented.

`skills/amux/SKILL.md`: note that a spawned or split pane can carry a name, and that the name is what appears on its border and in the switcher — useful when several helpers are in one window.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/test-panes.sh` and `bash tests/test-switcher.sh` — expected: all PASS.
Run: `/bin/bash tests/test-panes.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed`.

- [ ] **Step 8: Commit**

```bash
git add bin/amux tmux/amux.conf scripts/amux-switch tests/test-panes.sh tests/test-switcher.sh README.md skills/amux/SKILL.md
git commit -m "feat(amux): name a pane with split -n; labels prefer it over the process name

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `amux send` verifies its submit

**Why:** `send` types the text, waits, and fires Enter. Against a cold TUI the Enter is swallowed and the text sits unsubmitted in the input box — observed live, three times in a row on a freshly booted agent. `send` exits 0 regardless, so the caller believes the message was delivered. Silent false success is the worst failure mode for a coordination primitive: a waiting agent hangs forever on a message that was never sent.

**Files:**
- Modify: `bin/amux` (the `send)` branch)
- Test: `tests/test-coordination.sh`

**Interfaces:**
- Consumes: `@amux-send-enter-delay` (existing, guarded).
- Produces: `@amux-send-retries` — how many extra Enters to try before giving up. Default 3. Guarded the same way the delay is: unset / non-numeric / negative all fall back to the default.
- `amux send` exits **0** when the text left the input line, **2** for a bad target (unchanged), and **1** when the text is still sitting unsubmitted after the retries, printing what happened to stderr.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-coordination.sh`:

```bash
# --- send verifies its submit ---
# The failure this guards: a cold TUI swallows the Enter, the text sits in the
# input box, and send exits 0 anyway — so a caller waits forever on a message
# that was never delivered.

# a normal shell submits on the first Enter and still exits 0
"$AMUX" send "$recv" "printf 'VERIFY-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send exits 0 when the text submits"
wait_for "$recv" 'VERIFY-OK' \
  && assert_eq ok ok "send still delivers normally" \
  || assert_eq no-exec executed "send still delivers normally"

# a garbage retry count falls back to the default rather than aborting
T set-option -g @amux-send-retries "not-a-number"
"$AMUX" send "$recv" "printf 'RETRY-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send survives a garbage @amux-send-retries"
wait_for "$recv" 'RETRY-OK' \
  && assert_eq ok ok "send still submits with a garbage retry count" \
  || assert_eq no-exec executed "send still submits with a garbage retry count"
T set-option -gu @amux-send-retries 2>/dev/null || true

# zero retries is honoured (one Enter, no verification loop) and still works
T set-option -g @amux-send-retries "0"
"$AMUX" send "$recv" "printf 'ZERO-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send with zero retries exits 0"
T set-option -gu @amux-send-retries 2>/dev/null || true
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test-coordination.sh`
Expected: the `@amux-send-retries` assertions fail or the option is simply ignored — confirm which, and say so in your report. If they pass trivially because the option is unread, that is still a RED for this task: the behavior does not exist yet.

- [ ] **Step 3: Implement verify-and-retry**

Replace the two-step submit at the end of the `send)` branch. The verification must be conservative: a **false "submitted"** is acceptable (worst case, current behavior), but a **false "not submitted"** must not fire extra Enters into a pane that already accepted the text, because that would run the previous command again in a shell.

The check: capture the pane, take its last non-blank line, and decide the text is still pending only if that line **contains the full sent text**. After a successful submit a shell's last line is the command's output or a fresh prompt, and a TUI's is its redrawn empty input — none of which contain the whole message.

```bash
    retries="$(t show-options -gqv @amux-send-retries 2>/dev/null)"
    case "$retries" in ''|*[!0-9]*) retries=3 ;; esac

    # Still pending? Only if the pane's last non-blank line still holds the whole
    # message. Conservative on purpose: guessing "not submitted" when it did
    # submit would re-fire Enter and re-run the previous command in a shell.
    pending() {
      last="$(t capture-pane -p -t "$tgt" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1)"
      case "$last" in *"$1"*) return 0 ;; *) return 1 ;; esac
    }

    t send-keys -t "$tgt" -l -- "$*"
    sleep "$delay" 2>/dev/null || true
    t send-keys -t "$tgt" Enter

    n="$retries"
    while [ "$n" -gt 0 ]; do
      sleep "$delay" 2>/dev/null || true
      pending "$*" || break
      # A cold TUI can swallow the first Enter entirely; try again.
      t send-keys -t "$tgt" Enter
      n=$((n - 1))
    done

    if [ "$retries" -gt 0 ] && pending "$*"; then
      echo "amux send: text typed into '$raw' but never submitted (tried $retries extra Enter(s))" >&2
      exit 1
    fi
```

Update the usage comment for `send` to mention that it verifies the submit and exits 1 if the text never left the input line.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test-coordination.sh` — expected: all PASS, including every pre-existing `send` assertion.
Run: `/bin/bash tests/test-coordination.sh` — expected: identical.
Run: `bash tests/run.sh` — expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/amux tests/test-coordination.sh
git commit -m "fix(amux): send verifies its submit instead of failing silently

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
