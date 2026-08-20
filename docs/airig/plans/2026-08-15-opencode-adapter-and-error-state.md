# opencode Adapter + `error` State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Badge opencode agent panes with amux's state glyphs, and add a fifth state, `error`, for an agent that will not make progress without you.

**Architecture:** `scripts/amux-agent-state` is already harness-agnostic — it takes a state word and stamps the calling pane. This plan adds a fifth state word through every renderer, exposes the sink as a public `amux state` command, and ships an opencode plugin that calls it from opencode's event bus.

**Tech Stack:** bash 3.2+, tmux 3.2+ (CI floor 3.4), a single ES module for the plugin (runs under Bun inside opencode, tested under Node), bash test suite with isolated tmux servers.

**Spec:** `docs/superpowers/specs/2026-08-15-opencode-adapter-and-error-state.md`

## Global Constraints

- **bash 3.2 compatible.** macOS ships `/bin/bash` 3.2. No `${var^^}`, no associative arrays, no `printf '\u'`. Use `\xHH` byte escapes for non-ASCII in `printf`.
- **tmux 3.4 is the CI floor.** Do not use `#{a:N}` for N<32, and do not pack multiple option values into one `display-message` behind a control-byte separator — a literal `0x1F` comes back as the four characters `\037` on 3.4. One `show-options -gqv` per value.
- **tmux format truthiness treats the string `"0"` as false.** Never write `#{?@amux-name,...}`. Always `#{?#{==:#{@amux-name},},...}`. This has bitten this project at four sites.
- **A literal comma inside `#{P:...}` is the active/inactive separator, not text.** Loop bodies use a space.
- **Nested `#{E:}` inside `#{E:}` is not reliable here.** Inline the chain instead of factoring it into a second option.
- **`scripts/amux-agent-state` must never break the agent.** Every tmux call carries `2>/dev/null || true`. The unchanged-state hot path must stay at exactly **one** tmux invocation — there is a test pinning this.
- **Public repo.** Commits are authored `beatzball <38116726+beatzball@users.noreply.github.com>`. No usernames, real names, `/Users/...` paths, or email addresses in tracked files. **Never add a `Claude-Session:` trailer to any commit** — the history was rewritten once to remove them.
- **Never contact the live `-L amux` server.** Tests use isolated `-S <path>` sockets only. `scripts/amux-agent-state` only acts on a socket path ending in `/amux`, so tests that exercise it build `<tmpdir>/amux` directly.
- **Every new assertion needs a negative control** — run it against the unfixed code and watch it fail before accepting it. Three assertions in this project shipped with no discriminating power.
- **Do not merge, push, force-push, or interact with GitHub PRs.** Commit locally only.
- **Canonical state order is urgency order:** `error blocked working done idle`. Use it everywhere a list of states appears.

## Files

**Create:**
- `adapters/opencode/amux.js` — the plugin. One `event` handler, one debounced `amux state` call.
- `tests/opencode-plugin-harness.mjs` — fires synthetic events at the plugin, asserts the resulting `amux state` calls via a `PATH` shim.
- `tests/test-opencode-plugin.sh` — bash wrapper; skips when `node` is absent.
- `tests/test-error-state.sh` — the `error` state through every renderer.
- `tests/live/opencode-smoke.sh` — hand-run, drives real opencode against a local ollama model. Deliberately outside `tests/`'s flat `test-*.sh` glob.

**Modify:**
- `scripts/lib/amux-config.sh` — five glyphs per set; preview keys; preview apply.
- `scripts/amux-settings` — `apply_glyphs` writes five.
- `tmux/amux.conf` — `@amux-glyph-error` default; badge, busy, and pane-border chains.
- `scripts/amux-agent-state` — accept `error`; notify on it.
- `scripts/amux-status` — count and render `error`.
- `scripts/amux-switch` — `error` glyph in the awk row builder.
- `bin/amux` — `state` subcommand, header comment, usage string.
- `scripts/amux-doctor` — informational opencode plugin check.
- `README.md`, `skills/amux/SKILL.md` — document `amux state` and the opencode setup.

---

### Task 1: `error` as a fifth configurable state

Adds the glyph to config plumbing and teaches the state sink to accept and notify on `error`. Nothing renders it yet — that is Task 2.

**Files:**
- Modify: `scripts/lib/amux-config.sh:6-17` (`amux_glyphset`), `:96-104` (`amux_current_glyphset`), `:125-132` (`amux_preview_keys`), `:148-155` (`amux_preview_apply` glyphs arm)
- Modify: `scripts/amux-settings:40-46` (`apply_glyphs`)
- Modify: `tmux/amux.conf:61` (glyph defaults block)
- Modify: `scripts/amux-agent-state:28` (normalisation), `:95-103` (notify block)
- Test: `tests/test-settings.sh` (the only test that sources `scripts/lib/amux-config.sh`, and it already scratches `XDG_CONFIG_HOME`), `tests/test-agent-state.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `amux_glyphset NAME` now prints **five** space-separated glyphs in canonical order `error blocked working done idle`. The tmux option `@amux-glyph-error` exists with a default. `scripts/amux-agent-state error` is a valid invocation that stamps `@agent_state=error` and notifies.

- [ ] **Step 1: Write the failing glyph tests**

`tests/test-settings.sh:36` already pins the emoji set at four glyphs:

```bash
assert_eq "$(amux_glyphset emoji)" "🛑 ⏳ ✅ 💤" "glyphset emoji matches the four state emoji"
```

Replace that line with the five-glyph form, and add the new assertions
immediately after it — this block must stay **above** line 50's
`export AMUX_CONFIG_SOCK=...`, since everything here calls pure functions:

```bash
assert_eq "$(amux_glyphset emoji)" "💥 🛑 ⏳ ✅ 💤" "glyphset emoji matches the five state emoji"

# --- the error state's glyph ---
# Canonical order is urgency order (error blocked working done idle), the same
# order the tab badge and the status rollup use, so there is one order to
# remember across the codebase.
for gs in emoji orbs ascii nerd; do
  set -f; set -- $(amux_glyphset "$gs"); set +f
  assert_eq "$#" "5" "glyph set '$gs' has five glyphs"
done

# Every set's error glyph must differ from its other four, or two states render
# identically and the badge stops carrying information.
for gs in emoji orbs ascii nerd; do
  set -f; set -- $(amux_glyphset "$gs"); set +f
  dupes=0
  for g in "$2" "$3" "$4" "$5"; do [ "$g" = "$1" ] && dupes=$((dupes+1)); done
  assert_eq "$dupes" "0" "glyph set '$gs' error glyph is distinct from the other four"
done

assert_contains "$(amux_glyphset nerd)" "$(printf '\xef\x83\xa7')" \
  "glyphset nerd contains U+F0E7 (error)"

# A preview must snapshot and restore the error glyph too, or cancelling out of
# the glyph menu leaves the previewed set's error glyph behind.
assert_contains "$(amux_preview_keys glyphs)" "@amux-glyph-error" \
  "the glyphs preview covers @amux-glyph-error"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/test-settings.sh`
Expected: FAIL — `glyphset emoji matches the five state emoji` reports
`want [💥 🛑 ⏳ ✅ 💤] got [🛑 ⏳ ✅ 💤]`, `glyph set 'emoji' has five glyphs`
reports `want [5] got [4]`, the nerd U+F0E7 assertion fails, and the
preview-keys assertion fails.

- [ ] **Step 3: Add the fifth glyph to every set**

Replace `amux_glyphset` in `scripts/lib/amux-config.sh`:

```sh
# amux_glyphset NAME -> "error blocked working done idle" (space-separated).
# Urgency order, matching the tab badge and the status rollup, so there is a
# single canonical order for the five states across the codebase.
# \xHH bytes, not \uXXXX: bash 3.2's printf has no \u. Unknown -> emoji.
amux_glyphset() {
  case "$1" in
    orbs)  printf '%s %s %s %s %s' "🟣" "🔴" "🟡" "🔵" "🟢" ;;
    ascii) printf '%s %s %s %s %s' "[x]" "[!]" "[~]" "[+]" "[·]" ;;
    nerd)  printf '%s %s %s %s %s' \
             "$(printf '\xef\x83\xa7')" \
             "$(printf '\xef\x81\xb1')" "$(printf '\xef\x89\x92')" \
             "$(printf '\xef\x80\x8c')" "$(printf '\xef\x86\x86')" ;;
    *)     printf '%s %s %s %s %s' "💥" "🛑" "⏳" "✅" "💤" ;;
  esac
}
```

`\xef\x83\xa7` is U+F0E7, Nerd Font `nf-fa-bolt` — a power fault, which is what
this state usually means (see the spec: the dominant trigger is a provider the
agent cannot reach). Deliberately not the warning triangle U+F071 already used
for `blocked`.

- [ ] **Step 4: Preview the error glyph, and keep old configs identifiable**

In `scripts/lib/amux-config.sh`, add the key to the `glyphs` arm of `amux_preview_keys`:

```sh
    glyphs)    echo "@amux-glyph-error @amux-glyph-blocked @amux-glyph-working @amux-glyph-done @amux-glyph-idle" ;;
```

Replace the `glyphs` arm of `amux_preview_apply`:

```sh
    glyphs)
      set -f; set -- $(amux_glyphset "$value"); set +f
      [ "$#" -eq 5 ] || return 0
      amux_cfg_tmux set-option -g @amux-glyph-error   "$1" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-glyph-blocked "$2" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-glyph-working "$3" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-glyph-done    "$4" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-glyph-idle    "$5" 2>/dev/null || true
      ;;
```

Replace `amux_current_glyphset`:

```sh
# amux_current_glyphset -> name matching the current glyphs, else "custom".
#
# Matches on the FOUR original glyphs, not all five. Every config written
# before the error state existed has no @amux-glyph-error, and tmux/amux.conf
# supplies the emoji 💥 as the global default whatever set the user picked — so
# requiring a fifth match would report "custom" for every existing user until
# they re-picked. The cost is that a hand-customised error glyph alone does not
# make a set read as "custom"; that is the better trade.
amux_current_glyphset() {
  local cur g
  cur="$(amux_opt @amux-glyph-blocked) $(amux_opt @amux-glyph-working) $(amux_opt @amux-glyph-done) $(amux_opt @amux-glyph-idle)"
  for g in emoji orbs ascii nerd; do
    set -f; set -- $(amux_glyphset "$g"); set +f
    [ "$2 $3 $4 $5" = "$cur" ] && { printf '%s' "$g"; return; }
  done
  printf 'custom'
}
```

In `scripts/amux-settings`, replace `apply_glyphs`:

```sh
apply_glyphs() {
  set -f; set -- $(amux_glyphset "$1"); set +f
  amux_cfg_set @amux-glyph-error   "$1"
  amux_cfg_set @amux-glyph-blocked "$2"
  amux_cfg_set @amux-glyph-working "$3"
  amux_cfg_set @amux-glyph-done    "$4"
  amux_cfg_set @amux-glyph-idle    "$5"
}
```

- [ ] **Step 5: Pin the upgrade path with a test**

Add to `tests/test-settings.sh`, in the same pure-function block above
line 50's `export AMUX_CONFIG_SOCK=...`:

```bash
# An existing user's config file holds four glyphs and no error glyph. It must
# still identify as the set they picked, not fall back to "custom" the moment
# they upgrade.
#
# AMUX_CONFIG_SOCK points at a path with no server, so amux_opt falls through
# to the config file. Without it amux_cfg_tmux would address `-L amux` by name
# and this assertion would read the DEVELOPER'S LIVE SERVER.
(
  export AMUX_CONFIG_SOCK="/nonexistent/amx-no-server"
  set -f; set -- $(amux_glyphset nerd); set +f
  amux_cfg_set @amux-glyph-blocked "$2"
  amux_cfg_set @amux-glyph-working "$3"
  amux_cfg_set @amux-glyph-done    "$4"
  amux_cfg_set @amux-glyph-idle    "$5"
  printf '%s' "$(amux_current_glyphset)"
) > "$cfgdir/glyphset-out"
assert_eq "$(cat "$cfgdir/glyphset-out")" "nerd" \
  "a four-glyph config written before the error state still identifies as its set"

# ...and a genuinely mismatched config is still custom, so the assertion above
# is not just accepting everything.
(
  export AMUX_CONFIG_SOCK="/nonexistent/amx-no-server"
  amux_cfg_set @amux-glyph-blocked "Q"
  printf '%s' "$(amux_current_glyphset)"
) > "$cfgdir/glyphset-out2"
assert_eq "$(cat "$cfgdir/glyphset-out2")" "custom" \
  "a config matching no set still reports custom"

# leave the config file clean for the assertions further down this file
rm -f "$cfgdir/amux/amux.conf"
```

The subshells keep `AMUX_CONFIG_SOCK` out of the rest of the file, which sets
it to a real test socket at line 50.

- [ ] **Step 6: Run the settings tests**

Run: `bash tests/test-settings.sh`
Expected: PASS on every line. Confirm the run did **not** touch the live
server: `tmux -L amux show-options -gqv @amux-glyph-blocked` must still print
whatever it printed before the run.

- [ ] **Step 7: Write the failing agent-state tests**

Append to `tests/test-agent-state.sh`, before the dead-server block at the end:

```bash
# --- the error state ---
# error is a real state word, not folded into idle by the normaliser.
errp="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" error
assert_eq "$(pstate "$errp")" "error" "error is accepted as a state, not normalised to idle"

# an unrecognised word still lands on idle — the normaliser did not simply
# start passing everything through
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" banana
assert_eq "$(pstate "$errp")" "idle" "an unrecognised state is still normalised to idle"

# error shares blocked's notification path: an agent that will not progress
# without you is worth a ping whether it is waiting or broken. The window here
# is inactive (a second window was created above), so the ping should fire.
notif2="$sdir/notified-error"
tmux -S "$s" set-option -g @amux-notify-cmd "touch $notif2"
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" working
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" error
[ -f "$notif2" ] && assert_eq ok ok "error on an inactive window invokes amux-notify" \
  || assert_eq "" fired "error on an inactive window invokes amux-notify"

# but done still does NOT notify — it fires every turn and would be noise
notif3="$sdir/notified-done"
tmux -S "$s" set-option -g @amux-notify-cmd "touch $notif3"
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" done
[ -f "$notif3" ] && assert_eq fired "" "done does not notify" \
  || assert_eq ok ok "done does not notify"
```

- [ ] **Step 8: Run them and watch them fail**

Run: `bash tests/test-agent-state.sh`
Expected: FAIL on `error is accepted as a state, not normalised to idle` (`want [error] got [idle]`) and on the notify assertion.

- [ ] **Step 9: Accept and notify on `error`**

In `scripts/amux-agent-state`, replace line 28:

```sh
# Normalise: anything unrecognised is idle.
case "$state" in blocked|working|done|error) ;; *) state="idle" ;; esac
```

Replace the notify block (currently lines 95-103):

```sh
# Ping if an off-screen agent just became blocked (needs your input) or errored
# (will not progress without you — for opencode the usual cause is a provider
# it cannot reach, retrying forever). If the window is on screen the pane is
# visible, so no ping. `done` deliberately never notifies: it fires every turn
# and would be noise.
msg=""
case "$state" in
  blocked) msg="needs your input" ;;
  error)   msg="hit an error" ;;
esac
if [ -n "$msg" ]; then
  active="$(tmux -S "$sock" display-message -p -t "$TMUX_PANE" '#{window_active}' 2>/dev/null || echo 0)"
  if [ "$active" != "1" ]; then
    wname="$(tmux -S "$sock" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null || echo agent)"
    AMUX_NOTIFY_SOCK="$sock" "$(dirname "$0")/amux-notify" "amux · ${wname}" "$msg" || true
  fi
fi
```

`msg=""` before the `case` matters: the script runs under `set -u`, and an
unset `msg` would abort the hook on any state that is not blocked or error.

- [ ] **Step 10: Add the error glyph default to the tmux config**

In `tmux/amux.conf`, in the user-facing config block, add above `@amux-glyph-blocked`:

```
set -g @amux-glyph-error   "💥"
```

- [ ] **Step 11: Run the full suite**

Run: `bash tests/run.sh`
Expected: every test passes, and the count has grown. The one-tmux-call hot-path assertion in `test-agent-state.sh` must still pass — if it now reports 2, the notify block is running on the early-bail path and the change is wrong.

- [ ] **Step 12: Commit**

```bash
git add scripts/lib/amux-config.sh scripts/amux-settings scripts/amux-agent-state tmux/amux.conf tests/test-settings.sh tests/test-agent-state.sh
git commit -m "feat(amux): add error as a fifth agent state

The state sink accepts it and notifies on it, sharing blocked's path: an
agent that will not progress without you is worth a ping whether it is
waiting for an answer or stuck. done still never notifies.

Glyph sets grow to five, ordered by urgency (error blocked working done
idle) to match the badge and the rollup. amux_current_glyphset still
matches on the original four, so a config written before this change
keeps identifying as the set the user picked instead of reading custom."
```

---

### Task 2: Render `error` everywhere

The state now exists but is invisible. This wires it through all four renderers: the tab badge, the busy test, the pane border, the status rollup, and the switcher.

**Files:**
- Modify: `tmux/amux.conf:95` (`@amux-tab-badge`), `:99` (`@amux-tab-busy`), `:163` (`@amux-pane-border`)
- Modify: `scripts/amux-status:28` (counters), `:47-54` (glyph reads), `:59-67` (count loop), `:76-81` (output)
- Modify: `scripts/amux-switch:34-37` (glyph reads), `:51-57` (awk `glyph()`)
- Test: `tests/test-error-state.sh` (create)

**Interfaces:**
- Consumes: `@amux-glyph-error` and the `error` state word from Task 1.
- Produces: nothing new for later tasks — this task is purely rendering.

- [ ] **Step 1: Write the failing render test**

Create `tests/test-error-state.sh`:

```bash
#!/usr/bin/env bash
# The error state renders everywhere the other four do, and sorts first.
# error means "this agent will not make progress without you" — for opencode
# the usual cause is a provider it cannot reach, retrying forever.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"
T set-option -g @amux-glyph-error   "E"
T set-option -g @amux-glyph-blocked "B"
T set-option -g @amux-glyph-working "W"
T set-option -g @amux-glyph-done    "D"
T set-option -g @amux-glyph-idle    "I"

hold='sh -c "while :; do sleep 5; done"'
badge()  { T list-windows -a -F "#{window_id}|#{E:@amux-tab-badge}" | grep "^$1|" | cut -d'|' -f2; }
busy()   { T list-windows -a -F "#{window_id}|#{E:@amux-tab-busy}"  | grep "^$1|" | cut -d'|' -f2; }
border() { T list-panes   -a -F "#{pane_id}|#{E:@amux-pane-border}" | grep "^$1|" | cut -d'|' -f2; }

# --- tab badge ---
w1="$(T display-message -p '#{window_id}')"
p1="$(T display-message -p '#{pane_id}')"
T set-option -p -t "$p1" @agent_state error
assert_eq "$(badge "$w1")" "E" "an error pane badges its tab with the error glyph"
assert_eq "$(busy "$w1")"  "1" "a window with an error agent is busy"

# error sorts FIRST, ahead of blocked: a crashed agent outranks a waiting one
p2="$(T split-window -d -P -F '#{pane_id}' -t "$p1" "$hold")"
T set-option -p -t "$p2" @agent_state blocked
assert_eq "$(badge "$w1")" "EB" "error sorts ahead of blocked"

p3="$(T split-window -d -P -F '#{pane_id}' -t "$p1" "$hold")"
T set-option -p -t "$p3" @agent_state working
p4="$(T split-window -d -P -F '#{pane_id}' -t "$p1" "$hold")"
T set-option -p -t "$p4" @agent_state done
assert_eq "$(badge "$w1")" "EBWD" "all four urgent states render in urgency order"

# duplicates still dedupe now that a fifth arm exists
p5="$(T split-window -d -P -F '#{pane_id}' -t "$p1" "$hold")"
T set-option -p -t "$p5" @agent_state error
assert_eq "$(badge "$w1")" "EBWD" "two error panes dedupe to one glyph"

# --- pane border ---
assert_contains "$(border "$p1")" "E"     "an error pane's border shows the error glyph"
assert_contains "$(border "$p1")" "error" "an error pane's border names its state"

# --- status rollup ---
out="$(AMUX_STATUS_SOCK="$sock" "$HERE/scripts/amux-status")"
assert_contains "$out" "E 2" "the rollup counts error panes"
case "$out" in
  E*) assert_eq ok ok "the rollup lists error first" ;;
  *)  assert_eq "$out" "E first" "the rollup lists error first" ;;
esac

# --- switcher ---
rows="$(AMUX_SWITCH_SOCK="$sock" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
assert_contains "$rows" "E error" "the switcher renders the error glyph beside the state"

# --- the conf carries a default, so a server booted without a user config
# still has something to render rather than an empty badge ---
assert_contains "$(cat "$HERE/tmux/amux.conf")" "@amux-glyph-error" \
  "tmux/amux.conf ships a default error glyph"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/test-error-state.sh`
Expected: FAIL. `an error pane badges its tab with the error glyph` reports `want [E] got []` — the badge's `#{P:}` chain has no `error` arm, and an error-only window matches none of blocked/working/done/idle, so it renders nothing at all.

- [ ] **Step 3: Add the error arm to the tab badge and the busy test**

In `tmux/amux.conf`, replace the `@amux-tab-badge` line:

```
set -g @amux-tab-badge "#{?#{==:#{P:#{@agent_state}},},#{@amux-glyph-idle},#{?#{m:*error*,#{P:#{@agent_state} }},#{@amux-glyph-error},}#{?#{m:*blocked*,#{P:#{@agent_state} }},#{@amux-glyph-blocked},}#{?#{m:*working*,#{P:#{@agent_state} }},#{@amux-glyph-working},}#{?#{m:*done*,#{P:#{@agent_state} }},#{@amux-glyph-done},}#{?#{m:*idle*,#{P:#{@agent_state} }},#{@amux-glyph-idle},}}"
```

Replace the `@amux-tab-busy` line:

```
set -g @amux-tab-busy "#{||:#{m:*error*,#{P:#{@agent_state} }},#{||:#{m:*blocked*,#{P:#{@agent_state} }},#{||:#{m:*working*,#{P:#{@agent_state} }},#{m:*done*,#{P:#{@agent_state} }}}}}"
```

Keep the space separator inside every `#{P:...}` body — a literal comma there is
parsed as the active/inactive separator.

- [ ] **Step 4: Add the error arm to the pane border**

In `tmux/amux.conf`, replace the `@amux-pane-border` line:

```
set -g @amux-pane-border " #{?@agent_state,#{?#{==:#{@agent_state},error},#{@amux-glyph-error},#{?#{==:#{@agent_state},blocked},#{@amux-glyph-blocked},#{?#{==:#{@agent_state},working},#{@amux-glyph-working},#{?#{==:#{@agent_state},done},#{@amux-glyph-done},#{@amux-glyph-idle}}}}} ,}#{pane_id} #{?#{==:#{@amux-name},},#{pane_current_command},#{@amux-name}}#{?@agent_state, · #{@agent_state}#{?@agent_since, #{t/p:@agent_since},},} "
```

The chain stays inlined rather than factored into its own option — `#{E:}`
inside `#{E:}` relies on expansion depth that is not guaranteed here.

- [ ] **Step 5: Count and render error in the rollup**

In `scripts/amux-status`, replace `b=0 w=0 d=0 i=0` with:

```sh
e=0 b=0 w=0 d=0 i=0
```

Add a fifth glyph read alongside the other four, keeping one
`show-options -gqv` per value (packing them into one call breaks on tmux 3.4):

```sh
ge="$(amux_status_tmux show-options -gqv @amux-glyph-error   2>/dev/null)"
```

and its fallback beside the others:

```sh
[ -n "$ge" ] || ge="💥"
```

Add the arm to the count loop, above `blocked`:

```sh
    error)   e=$((e+1)) ;;
```

And to the output, above the blocked badge:

```sh
[ "$e" -gt 0 ] && out+="${ge} ${e}  "
```

- [ ] **Step 6: Add the error glyph to the switcher**

In `scripts/amux-switch`, add the read beside the other four:

```sh
ge="$(tmx show-options -gqv @amux-glyph-error   2>/dev/null)"; [ -n "$ge" ] || ge="💥"
```

Pass it into awk by adding `-v ge="$ge"` to the existing `-v` list, and add the
branch to `glyph()` above the `blocked` one:

```awk
    if (s == "error")   return ge
```

- [ ] **Step 7: Run the new test**

Run: `bash tests/test-error-state.sh`
Expected: PASS on every line.

- [ ] **Step 8: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green. `tests/test-pane-state.sh`'s existing `blocked sorts before working before done` assertion must still pass — inserting the error arm ahead of blocked must not disturb the existing order.

- [ ] **Step 9: Commit**

```bash
git add tmux/amux.conf scripts/amux-status scripts/amux-switch tests/test-error-state.sh
git commit -m "feat(amux): render the error state in every renderer

Tab badge, busy test, pane border, status rollup, and the switcher. error
sorts ahead of blocked everywhere: an agent that has stopped making
progress outranks one that is merely waiting on an answer.

The rollup reads a fifth glyph with its own show-options call rather than
packing five values into one display-message -- a control-byte separator
comes back as the literal characters \\037 on tmux 3.4."
```

---

### Task 3: `amux state` as a public command

Makes the state sink a documented interface instead of an internal hook target, so every future adapter has one contract to call.

**Files:**
- Modify: `bin/amux:22` (header comment block), `:109` (dispatch, insert before `doctor`), `:439` (usage string)
- Test: `tests/test-state-cmd.sh` (create)

**Interfaces:**
- Consumes: `scripts/amux-agent-state` accepting `error` (Task 1).
- Produces: `amux state <working|blocked|done|error|idle>` on `PATH`. This is what `adapters/opencode/amux.js` calls in Task 4. It reads `TMUX` and `TMUX_PANE` from the environment, exactly as the hook does, and is a silent no-op outside an amux pane.

- [ ] **Step 1: Write the failing test**

Create `tests/test-state-cmd.sh`:

```bash
#!/usr/bin/env bash
# `amux state` is the public contract every state source calls: the Claude
# hooks, the opencode plugin, a future pi extension, or a user's own script.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# amux-agent-state only acts on a socket path ending in /amux, so build one
# directly rather than via amux_test_server.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/amux"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
tmux -S "$s" -f /dev/null new-session -d
pane="$(tmux -S "$s" display -p '#{pane_id}')"
pstate() { tmux -S "$s" show-options -pqv -t "$pane" @agent_state; }

# it stamps the calling pane, same as the hook does
env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/amux" state working
assert_eq "$(pstate)" "working" "amux state stamps the calling pane"

env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/amux" state error
assert_eq "$(pstate)" "error" "amux state accepts the error state"

# outside tmux it is a silent no-op that exits 0 -- an adapter must be safe to
# leave installed when its agent runs outside amux
out="$(env -u TMUX -u TMUX_PANE "$HERE/bin/amux" state working 2>&1)"; rc=$?
assert_eq "$rc" "0" "amux state exits 0 outside tmux"
assert_eq "$out" "" "amux state prints nothing outside tmux"

# no argument is idle, not a usage error: the sink's own default
env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/amux" state
assert_eq "$(pstate)" "idle" "amux state with no argument means idle"

# it is advertised, or nobody will find it
usage="$("$HERE/bin/amux" not-a-command 2>&1 || true)"
assert_contains "$usage" "state" "amux state appears in the usage line"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/test-state-cmd.sh`
Expected: FAIL — `amux state stamps the calling pane` reports `want [working] got []`, because `state` falls through to the `*)` arm, which prints usage and exits 2.

- [ ] **Step 3: Add the dispatch arm**

In `bin/amux`, insert immediately before the `doctor)` arm:

```sh
  state)
    # The public state-reporting contract. Every state SOURCE calls this: the
    # Claude Code hooks below, adapters/opencode/amux.js, and anything a user
    # writes. It reads $TMUX and $TMUX_PANE to find the pane, and is a silent
    # no-op outside an amux server -- which is what makes an adapter safe to
    # leave installed when the agent runs somewhere else.
    exec "$AMUX_HOME/scripts/amux-agent-state" "${2:-idle}"
    ;;
```

- [ ] **Step 4: Document it in the header and the usage line**

In `bin/amux`, add to the header comment block, after the `amux hooks` line:

```
#   amux state STATE        report this pane's agent state (working|blocked|done|error|idle)
```

And in the final `*)` arm, insert `state STATE|` into the usage string immediately before `hooks`:

```sh
  *) echo "usage: amux [up|session NAME|new NAME [SESSION]|spawn NAME [CMD]|split [-h|-v] [-t P] [-n NAME] [CMD]|whoami|ssh HOST|send TGT TEXT|read TGT [N]|wait-done TGT [T]|state STATE|hooks|doctor|init|settings|status|kill [SESSION]]" >&2; exit 2 ;;
```

- [ ] **Step 5: Run the test**

Run: `bash tests/test-state-cmd.sh`
Expected: PASS on every line.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add bin/amux tests/test-state-cmd.sh
git commit -m "feat(amux): expose the state sink as amux state

One public contract for every state source -- the Claude hooks, the
opencode adapter, and anything a user writes -- instead of each one
reaching into scripts/ by path. The script stays where it is, so hooks
already configured keep working untouched.

Still a silent no-op outside an amux pane, which is what makes an
adapter safe to leave installed when the agent runs elsewhere."
```

---

### Task 4: The opencode plugin and its offline test

The adapter itself, plus the Node harness that proves the mapping without running opencode.

**Files:**
- Create: `adapters/opencode/amux.js`
- Create: `tests/opencode-plugin-harness.mjs`
- Create: `tests/test-opencode-plugin.sh`

**Interfaces:**
- Consumes: `amux state <state>` on `PATH` (Task 3).
- Produces: `adapters/opencode/amux.js` exporting `AmuxState`, an async function taking opencode's `PluginInput` (which it ignores) and returning `{ event }`. Task 5's live test symlinks this file; Task 6's doctor check looks for a symlink pointing at it.

- [ ] **Step 1: Write the plugin**

Create `adapters/opencode/amux.js`:

```js
// amux.js — report an opencode agent's state onto its tmux pane.
//
// Install by symlinking into opencode's plugin directory, so updating amux
// updates the plugin:
//
//   mkdir -p ~/.config/opencode/plugin
//   ln -s "$AMUX_HOME/adapters/opencode/amux.js" ~/.config/opencode/plugin/amux.js
//
// The plugin runs in opencode's own process, which is the process in the tmux
// pane, so `amux state` finds the right pane from $TMUX_PANE with nothing to
// pass around. (This does not hold for `opencode attach` against a detached
// `opencode serve` — the plugin would run in the server, not the pane.)
//
// Everything arrives through the single `event` hook. That is a deliberate
// choice against the type definitions: opencode declares a "permission.ask"
// hook, but registering it produces nothing when a permission dialog appears —
// the `permission.asked` EVENT is what actually fires.

// The state is derived from opencode's session status rather than from tool
// calls. `tool.execute.before` fires only when a tool runs, and only after the
// turn is underway, so a turn that answers without calling a tool would never
// show as working at all.
//
// Two consecutive retries mean error rather than one, because a single retry
// may be a blip that heals itself, and error fires a desktop notification.
const RETRY_THRESHOLD = 2

// node:child_process, not opencode's Bun `$` shell. It behaves identically
// under Bun (which runs the plugin) and under plain Node (which runs the
// offline test), so the test exercises the real invocation path instead of a
// mock. execFile also takes an argv array, so no shell quoting is involved.
import { execFile } from "node:child_process"

// Never throws. A missing amux, a dead tmux server, or a pane that went away
// must leave the pane unbadged, never break the agent being badged — the same
// discipline as the `|| true` on every tmux call in scripts/amux-agent-state.
const report = (state) =>
  new Promise((resolve) => {
    try {
      execFile("amux", ["state", state], { timeout: 5000 }, () => resolve())
    } catch {
      resolve()
    }
  })

export const AmuxState = async () => {
  // opencode emits session.status busy several times per turn. Holding the
  // last reported state keeps a turn to one process spawn per real transition.
  // This is separate from amux state's own unchanged-state early-bail, which
  // guards the tmux round trip rather than the spawn.
  let last = null
  let retries = 0

  const set = async (state) => {
    if (state === last) return
    last = state
    await report(state)
  }

  return {
    event: async ({ event }) => {
      switch (event?.type) {
        case "session.status": {
          const status = event.properties?.status?.type
          if (status === "busy") {
            retries = 0
            await set("working")
          } else if (status === "retry") {
            retries += 1
            await set(retries >= RETRY_THRESHOLD ? "error" : "working")
          }
          // status "idle" is ignored: session.idle follows it and is the
          // canonical end-of-turn signal.
          return
        }
        case "permission.asked":
          await set("blocked")
          return
        case "permission.replied":
          await set("working")
          return
        case "session.idle":
          retries = 0
          await set("done")
          return
        case "session.error": {
          retries = 0
          // MessageAbortedError is the user pressing Esc. Badging their own
          // keystroke as a crash — and pinging their desktop about it — would
          // be worse than saying nothing.
          const aborted = event.properties?.error?.name === "MessageAbortedError"
          await set(aborted ? "done" : "error")
          return
        }
      }
    },
  }
}
```

- [ ] **Step 2: Write the harness**

Create `tests/opencode-plugin-harness.mjs`:

```js
// Fire synthetic opencode events at adapters/opencode/amux.js and assert which
// `amux state` calls come out, with a recording shim standing in for amux on
// PATH. Runs offline, in milliseconds, with no model call.
//
// Prints "  PASS:" / "  FAIL:" lines so tests/run.sh counts them like any bash
// test, and always exits 0 — run.sh treats a non-zero exit as a crash.
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, chmodSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const HERE = fileURLToPath(new URL(".", import.meta.url))
// Short path: the ~104-char unix socket limit bites elsewhere in this suite,
// and /tmp/amx.* is the prefix its cleanup tooling knows about.
const dir = mkdtempSync("/tmp/amx.")
const log = join(dir, "calls")
const shim = join(dir, "amux")
writeFileSync(shim, `#!/bin/sh\nprintf '%s\\n' "$2" >> "${log}"\n`)
chmodSync(shim, 0o755)
const REAL_PATH = process.env.PATH
process.env.PATH = `${dir}:${REAL_PATH}`

let pass = 0
let fail = 0
const check = (got, want, what) => {
  if (got === want) {
    pass++
    console.log(`  PASS: ${what}`)
  } else {
    fail++
    console.log(`  FAIL: ${what}\n       want [${want}] got [${got}]`)
  }
}

const calls = () =>
  existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).join(",") : ""

const { AmuxState } = await import(join(HERE, "..", "adapters", "opencode", "amux.js"))

// A fresh plugin instance per case, so one case's debounce state cannot leak
// into the next and make a later assertion pass for the wrong reason.
const fresh = async () => {
  if (existsSync(log)) rmSync(log)
  const { event } = await AmuxState()
  return async (...events) => {
    for (const e of events) await event({ event: e })
  }
}
const status = (type) => ({ type: "session.status", properties: { status: { type } } })
const plain = (type) => ({ type, properties: {} })
const errored = (name) => ({ type: "session.error", properties: { error: { name } } })

let fire = await fresh()
await fire(status("busy"))
check(calls(), "working", "session.status busy reports working")

fire = await fresh()
await fire(status("busy"), status("busy"), status("busy"))
check(calls(), "working", "repeated busy events are debounced to one call")

fire = await fresh()
await fire(status("busy"), plain("permission.asked"), plain("permission.replied"), plain("session.idle"))
check(calls(), "working,blocked,working,done", "a full permission turn walks working -> blocked -> working -> done")

fire = await fresh()
await fire(status("busy"), status("retry"))
check(calls(), "working", "a single retry stays working — it may be a blip")

fire = await fresh()
await fire(status("busy"), status("retry"), status("retry"))
check(calls(), "working,error", "two consecutive retries report error")

fire = await fresh()
await fire(status("busy"), status("retry"), status("retry"), status("busy"))
check(calls(), "working,error,working", "recovering from a retry loop returns to working")

fire = await fresh()
await fire(status("busy"), status("retry"), status("busy"), status("retry"))
check(calls(), "working", "the retry counter resets on busy, so two non-consecutive retries are not an error")

fire = await fresh()
await fire(status("busy"), errored("MessageAbortedError"))
check(calls(), "working,done", "MessageAbortedError is the user pressing Esc, so it reports done")

fire = await fresh()
await fire(status("busy"), errored("APICallError"))
check(calls(), "working,error", "any other session.error reports error")

fire = await fresh()
await fire(plain("message.part.delta"), plain("file.edited"), status("idle"))
check(calls(), "", "unmapped events produce no call at all")

// A missing amux must leave the pane unbadged, never throw into opencode's
// event loop. PATH without the shim is the honest way to stage that.
process.env.PATH = "/nonexistent-amux-dir"
let threw = ""
try {
  const { event } = await AmuxState()
  await event({ event: status("busy") })
} catch (e) {
  threw = String(e && e.message ? e.message : e)
}
check(threw, "", "a missing amux on PATH does not throw into opencode")
process.env.PATH = `${dir}:${REAL_PATH}`

rmSync(dir, { recursive: true, force: true })
console.log(`  (${pass} passed, ${fail} failed in the opencode plugin harness)`)
process.exit(0)
```

- [ ] **Step 3: Write the bash wrapper**

Create `tests/test-opencode-plugin.sh`:

```bash
#!/usr/bin/env bash
# The opencode plugin's event mapping, tested without running opencode.
#
# Real opencode needs a model and is far too slow for CI; tests/live/ has the
# hand-run test that drives it for real. This one covers the whole mapping
# table offline in milliseconds.
#
# Gated on node in the same style as the python3-gated tests, so the suite
# degrades to a skip rather than a failure if node is ever absent.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: node not found — opencode plugin mapping tests skipped"
  exit 0
fi
exec node "$HERE/opencode-plugin-harness.mjs"
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `bash tests/test-opencode-plugin.sh`
Expected: PASS on all eleven lines.

- [ ] **Step 5: Prove the assertions discriminate**

Every assertion needs a negative control. Stage each break, confirm the named
test fails, then revert. Do all four:

```bash
# a) the debounce: remove the early return in `set`
#    -> "repeated busy events are debounced to one call" must FAIL
#       (want [working] got [working,working,working])
# b) the threshold: change RETRY_THRESHOLD to 1
#    -> "a single retry stays working" must FAIL
# c) the abort case: delete the MessageAbortedError branch, always report error
#    -> "MessageAbortedError is the user pressing Esc" must FAIL
# d) the counter reset: delete `retries = 0` from the busy arm
#    -> "the retry counter resets on busy" must FAIL
```

Run `bash tests/test-opencode-plugin.sh` after each edit, confirm the expected
line — and only that line — fails, then `git checkout adapters/opencode/amux.js`.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green, with the harness's assertions folded into the count.

- [ ] **Step 7: Commit**

```bash
git add adapters/opencode/amux.js tests/opencode-plugin-harness.mjs tests/test-opencode-plugin.sh
git commit -m "feat(amux): opencode adapter

A plugin that maps opencode's event bus onto amux states. Symlink it into
~/.config/opencode/plugin/ and an opencode pane badges like a Claude one.

The mapping is what a live opencode 1.18.15 was observed to emit, which
differs from its type definitions in four places -- see the spec. Most
notably it uses the permission.asked EVENT, because the declared
permission.ask HOOK never fires, and it derives working from session
status rather than tool calls, which miss any turn that calls no tool.

Uses node:child_process rather than opencode's Bun shell so the offline
test exercises the real invocation path instead of a mock."
```

---

### Task 5: The live smoke test

Closes the gap Task 4 leaves open: synthetic events drifting from opencode's real ones. Hand-run, never in CI.

**Files:**
- Create: `tests/live/opencode-smoke.sh`

**Interfaces:**
- Consumes: `adapters/opencode/amux.js` (Task 4), `amux state` (Task 3), the `error` state (Task 1).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the live test**

Create `tests/live/opencode-smoke.sh`:

```bash
#!/usr/bin/env bash
# Drive REAL opencode against a local model and assert the pane badges.
#
# NOT part of the suite: this directory is deliberately outside tests/'s flat
# test-*.sh glob, so tests/run.sh cannot pick it up. Run it by hand before
# merging adapter changes, and after any opencode upgrade.
#
#   bash tests/live/opencode-smoke.sh
#
# Needs opencode and a local ollama serving a tool-capable model. No account
# and no quota: every XDG home is redirected to a scratch directory, so no
# stored credential is even reachable. Skips -- never fails -- if either is
# missing.
#
# Isolation: its own tmux socket. The live -L amux server is never contacted.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
MODEL="${AMUX_LIVE_MODEL:-ornith:35b}"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }
command -v opencode >/dev/null 2>&1 || skip "opencode not installed"
command -v ollama   >/dev/null 2>&1 || skip "ollama not installed"
curl -s -m 5 http://localhost:11434/api/tags >/dev/null 2>&1 \
  || skip "ollama is not responding on :11434"
ollama list 2>/dev/null | grep -q "^${MODEL} " \
  || skip "model $MODEL not pulled (override with AMUX_LIVE_MODEL)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }

D="$(mktemp -d /tmp/amx.XXXX)"
# The socket path MUST end in /amux -- amux state is a no-op on any other
# socket, which is exactly what keeps it safe to wire into global hooks.
S="$D/amux"
trap 'tmux -S "$S" kill-server 2>/dev/null; rm -rf "$D"' EXIT

export XDG_CONFIG_HOME="$D/config" XDG_DATA_HOME="$D/data" XDG_CACHE_HOME="$D/cache"
mkdir -p "$XDG_CONFIG_HOME/opencode/plugin" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$D/proj"

# A SYMLINK, matching how a user installs it -- so this also proves opencode
# still follows symlinks when discovering plugins.
ln -s "$HERE/adapters/opencode/amux.js" "$XDG_CONFIG_HOME/opencode/plugin/amux.js"

write_config() {  # write_config <baseURL>
  cat > "$XDG_CONFIG_HOME/opencode/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama local",
      "options": { "baseURL": "$1" },
      "models": { "$MODEL": { "name": "$MODEL" } }
    }
  },
  "model": "ollama/$MODEL",
  "permission": { "bash": "ask" }
}
JSON
}

tmux -S "$S" -f /dev/null new-session -d -x 160 -y 45
tmux -S "$S" source-file "$HERE/tmux/amux.conf"
tmux -S "$S" set-option -g @amux-home "$HERE"

state() { tmux -S "$S" show-options -pqv -t "$1" @agent_state; }

# wait_state PANE WANT TIMEOUT -> 0 if the pane reaches WANT in time
wait_state() {
  local p="$1" want="$2" t="$3" n=0
  while [ "$n" -lt "$t" ]; do
    [ "$(state "$p")" = "$want" ] && return 0
    sleep 1; n=$((n+1))
  done
  return 1
}

# amux must be on PATH inside opencode's process, exactly as it is for a real
# user whose shell has bin/ on PATH.
launch() {  # launch -> prints the pane id
  tmux -S "$S" new-window -d -P -F '#{pane_id}' -c "$D/proj" \
    "PATH=$HERE/bin:$PATH opencode"
}

# --- case 1: a normal turn that must ask permission ---
write_config "http://localhost:11434/v1"
p="$(launch)"
if wait_state "$p" working 90; then ok "pane reaches working when the turn starts"
else no "pane reaches working when the turn starts (got '$(state "$p")')"; fi

sleep 3
tmux -S "$S" send-keys -t "$p" 'Use the bash tool to run: echo hello'
sleep 1
tmux -S "$S" send-keys -t "$p" Enter

if wait_state "$p" blocked 180; then ok "pane reaches blocked at the permission prompt"
else no "pane reaches blocked at the permission prompt (got '$(state "$p")')"; fi

tmux -S "$S" send-keys -t "$p" Enter    # approve: "Allow once" is the default

if wait_state "$p" done 180; then ok "pane reaches done when the turn ends"
else no "pane reaches done when the turn ends (got '$(state "$p")')"; fi

# the adapter must also label the pane, so the border stops showing a version
# string -- same gap the Claude hook fills
nm="$(tmux -S "$S" show-options -pqv -t "$p" @amux-name)"
[ -n "$nm" ] && ok "the adapter labels its pane ($nm)" || no "the adapter labels its pane"
tmux -S "$S" kill-window -t "$p" 2>/dev/null

# --- case 2: an unreachable provider must reach error ---
# This is the retry path. It is the only way to produce `error` on demand:
# opencode does not emit session.error for a provider it cannot reach, it
# retries forever (opencode#17648).
write_config "http://127.0.0.1:1/v1"
p2="$(launch)"
sleep 6
tmux -S "$S" send-keys -t "$p2" 'Write a haiku about tmux.'
sleep 1
tmux -S "$S" send-keys -t "$p2" Enter

if wait_state "$p2" error 120; then ok "an unreachable provider drives the pane to error"
else no "an unreachable provider drives the pane to error (got '$(state "$p2")')"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tests/live/opencode-smoke.sh
```

- [ ] **Step 3: Confirm the suite still cannot see it**

Run: `bash tests/run.sh 2>&1 | grep -c 'opencode-smoke'`
Expected: `0`. `tests/run.sh` globs `test-*.sh` in its own directory only, so a
subdirectory is invisible to it. If this prints anything but 0, the file is in
the wrong place.

- [ ] **Step 4: Run it for real**

Run: `bash tests/live/opencode-smoke.sh`
Expected: `5 passed, 0 failed`. On a machine without ollama it must print a
single `SKIP:` line and exit 0 — check that too, with:
`AMUX_LIVE_MODEL=definitely-not-a-model bash tests/live/opencode-smoke.sh`

If a case fails, the adapter's mapping is wrong for the current opencode — fix
`adapters/opencode/amux.js` and add the corrected case to the Node harness in
Task 4, so the regression is caught offline from then on.

- [ ] **Step 5: Commit**

```bash
git add tests/live/opencode-smoke.sh
git commit -m "test(amux): hand-run live test against real opencode

Drives real opencode against a local ollama model and asserts the pane
walks working -> blocked -> done, plus a second case that points the
provider at a dead port and asserts the pane reaches error.

Deliberately outside tests/'s flat test-*.sh glob so run.sh cannot pick
it up: the model is 21GB and a hosted runner can neither hold it nor
fetch it per run. It needs no account -- every XDG home is redirected to
a scratch dir, so no stored credential is reachable -- and skips rather
than fails when ollama or the model is absent.

This is the layer that catches what the offline harness cannot: every
one of the adapter's mapping corrections came from running opencode."
```

---

### Task 6: Doctor check and documentation

Makes the adapter discoverable. An undocumented manual test is one nobody runs, and an undocumented install step is one nobody completes.

**Files:**
- Modify: `scripts/amux-doctor:29-34` (after the Claude hooks check)
- Modify: `README.md` — the `## Enable the state badges (one-time)` section (line 243) and `### At-a-glance signals` (line 141)
- Modify: `skills/amux/SKILL.md`
- Test: `tests/test-doctor.sh`

**Interfaces:**
- Consumes: `adapters/opencode/amux.js` (Task 4), `amux state` (Task 3).
- Produces: nothing.

- [ ] **Step 1: Write the failing doctor test**

Append to `tests/test-doctor.sh`:

```bash
# --- the opencode adapter check ---
# Informational only: most users will not have opencode, and its absence must
# never fail the required-check exit code.
ocdir="$(mktemp -d /tmp/amx.XXXX)"
shimdir="$(mktemp -d /tmp/amx.XXXX)"
printf '#!/bin/sh\nexit 0\n' > "$shimdir/opencode"; chmod +x "$shimdir/opencode"

# opencode present, plugin not linked -> a warning naming the fix
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "opencode" "doctor mentions opencode when it is installed"
assert_contains "$out" "ln -s" "doctor prints the command that links the plugin"

# ...and it is still only a warning
COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" >/dev/null 2>&1
assert_eq "$?" "0" "a missing opencode plugin does not fail doctor"

# plugin linked -> reported as linked, with no install command
mkdir -p "$ocdir/opencode/plugin"
ln -s "$HERE/adapters/opencode/amux.js" "$ocdir/opencode/plugin/amux.js"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "opencode plugin linked" "doctor confirms a correctly linked plugin"
case "$out" in
  *"ln -s"*) assert_eq "prints-fix" "silent" "doctor stops printing the fix once linked" ;;
  *)         assert_eq ok ok "doctor stops printing the fix once linked" ;;
esac

# a link pointing at some OTHER amux checkout is worse than none -- it silently
# runs a different version's plugin
rm "$ocdir/opencode/plugin/amux.js"
printf 'not the real plugin\n' > "$ocdir/opencode/plugin/amux.js"
out="$(COLORTERM=truecolor XDG_CONFIG_HOME="$ocdir" PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "not this install" "doctor flags a plugin that is not this installation"

rm -rf "$ocdir" "$shimdir"
```

`tests/test-doctor.sh` does not currently define `HERE` as the repo root — it
defines `DOC`. Add `HERE="$(cd "$(dirname "$0")/.." && pwd)"` beside it.

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/test-doctor.sh`
Expected: FAIL — `doctor mentions opencode when it is installed` fails, because
`amux-doctor` says nothing about opencode at all.

- [ ] **Step 3: Add the check**

In `scripts/amux-doctor`, insert after the Claude hooks block and before the
notify-backend line:

```sh
# opencode adapter — informational. Most users will not have opencode, so a
# missing plugin is a warning, never a required failure.
if command -v opencode >/dev/null 2>&1; then
  ocplug="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugin/amux.js"
  ocwant="$(cd "$(dirname "$0")/.." && pwd)/adapters/opencode/amux.js"
  if [ ! -e "$ocplug" ]; then
    warn "opencode found, amux plugin not installed — run: mkdir -p \"$(dirname "$ocplug")\" && ln -s \"$ocwant\" \"$ocplug\""
  elif [ "$ocplug" -ef "$ocwant" ]; then
    ok "opencode plugin linked"
  else
    warn "opencode plugin at $ocplug is not this install — relink it to $ocwant"
  fi
fi
```

`-ef` compares the resolved files, so it follows the symlink and confirms the
link points at *this* checkout rather than merely existing.

- [ ] **Step 4: Run the doctor test**

Run: `bash tests/test-doctor.sh`
Expected: PASS on every line.

- [ ] **Step 5: Document the adapter in the README**

In `README.md`, at the end of the `## Enable the state badges (one-time)`
section, add:

````markdown
### Other agents

Badges are not Claude-only. Any agent can report its state through one public
command:

```sh
amux state working    # or: blocked, done, error, idle
```

It reads `$TMUX_PANE` to find its own pane, and does nothing at all outside an
amux session — so it is safe to wire into a global config.

**opencode** has an adapter in this repo. Symlink it into place:

```sh
mkdir -p ~/.config/opencode/plugin
ln -s "$AMUX_HOME/adapters/opencode/amux.js" ~/.config/opencode/plugin/amux.js
```

A symlink rather than a copy, so updating amux updates the plugin. Run
`amux doctor` to confirm it is linked.

`tests/live/opencode-smoke.sh` drives real opencode against a local model to
check the adapter end to end. It is not part of `tests/run.sh` — run it by hand
after an opencode upgrade.
````

In the `### At-a-glance signals` section, extend the desktop-notification
bullet: after "Only `blocked` notifies — `done` fires every turn and would be
noise", insert:

```markdown
`error` notifies too: an agent that has stopped making progress needs you just
as much as one waiting for an answer.
```

And in the same section's status-bar bullet, update the example glyph run from
`🛑4 ⏳1 ✅3` to `💥1 🛑4 ⏳1 ✅3` and the parenthetical to
`(error / blocked / working / done)`.

- [ ] **Step 6: Update the file-header comments that list the states**

Three header comments still advertise four states. Update each to five, in
canonical order:

- `bin/amux:7` — `# pane by state (💥 error · 🛑 blocked · ⏳ working · ✅ done · 💤 idle).`
- `tmux/amux.conf:9` — `# status bar badges it: 💥 error · 🛑 blocked/needs-you · ⏳ working · ✅ done · 💤 idle.`
- `scripts/amux-status:4` — `#   💥1 error  🛑3 blocked  ⏳1 working  ✅4 done  💤2 idle`

- [ ] **Step 7: Note self-reporting in the skill**

In `skills/amux/SKILL.md`, add a short section (place it beside the other
commands the skill documents):

```markdown
## Reporting your own state

If you are an agent running in an amux pane and your harness has no adapter,
you can badge yourself:

```sh
amux state working    # or: blocked, done, error, idle
```

Report `working` when you start a task, `blocked` when you need the human,
`error` if you cannot continue, and `done` when you finish. Outside an amux
pane the command does nothing, so it is always safe to call.
```

- [ ] **Step 8: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green.

- [ ] **Step 9: Check the docs for leaks**

Run: `git diff --cached; git status --short`
Confirm no absolute `/Users/...` path, username, real name, or email address
appears in any tracked file. `$AMUX_HOME` is the right placeholder in README
examples.

- [ ] **Step 10: Commit**

```bash
git add scripts/amux-doctor bin/amux tmux/amux.conf scripts/amux-status README.md skills/amux/SKILL.md tests/test-doctor.sh
git commit -m "docs(amux): document amux state and the opencode adapter

doctor gains an informational opencode check: whether the plugin is
linked, and whether it points at this checkout rather than merely
existing. Never a required failure -- most users will not have opencode.

README documents amux state as the public contract for any harness, the
opencode symlink, and the hand-run live test. SKILL.md tells an agent it
can badge itself. The state lists in three file headers grow to five."
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task:

| spec section | task |
| --- | --- |
| §1 `error` state — glyph, urgency order, notification | 1 (sink + glyph), 2 (render + order) |
| §1 blast radius — badge, busy, border, switcher, rollup, glyph sets, normalisation, settings preview | 1 (glyph sets, settings, normalisation), 2 (the four renderers) |
| §2 `amux state` public command | 3 |
| §3 adapter — delivery, invocation, event mapping, debounce, retry threshold, failure posture | 4 |
| §4 layer 1 (bash) | 1, 2 |
| §4 layer 2 (Node harness) | 4 |
| §4 layer 3 (live) | 5 |
| §4 negative controls | 4 step 5 explicitly; the write-test-first cycle covers the rest |
| §5 doctor + docs | 6 |

**Naming consistency.** `AmuxState` is the export in Task 4 and the import in
the harness. `RETRY_THRESHOLD` is named once and referenced by Task 4 step 5's
negative control. `@amux-glyph-error` is written by Task 1 and read by Task 2's
five consumers. `amux state` is created in Task 3 and called by Task 4's plugin,
Task 5's live test, and Task 6's docs. `amux_glyphset` returns five values in
canonical order and all three positional consumers were updated together in
Task 1 step 4.

**Ordering.** Task 4's plugin calls `amux state`, so Task 3 must land first.
Task 5 exercises `error` end to end, so Tasks 1, 2 and 4 must land first. Task 6
tests a symlink to `adapters/opencode/amux.js`, so Task 4 must land first. The
order as written satisfies all of these.

**Known gaps, deliberately out of scope.** `opencode attach` against a detached
`opencode serve` breaks the process/pane correspondence and is documented rather
than handled. Claude panes can never show `error`, since Claude Code's hooks have
no error event. Neither is a defect in this plan.
