# Archived pull requests — `beatzball/amux`

These pull requests exist **only** in the archived `beatzball/amux`
repository. They are **not** present in `beatzball/roost`.

`roost` is a *new* repository, not a rename. A GitHub rename keeps the same
repository — same objects, same SHAs, same PRs, plus a redirect from the old
URL. That was rejected: pre-rewrite objects containing an absolute home path
were still being served after the history rewrite, and a redirect would have
kept them reachable. `beatzball/amux` was made private on 2026-08-19 instead,
which 404s anonymously and freezes forks at 0.

The cost of a fresh repository is that this discussion history does not carry
over. This file is the archive, captured 2026-08-20.

Absolute home paths in the bodies below have been replaced with
`/absolute/path/to`. Everything else is verbatim.

| PR | Merged | Title |
|---|---|---|
| #8 | 2026-08-20 | opencode adapter + an error state |
| #7 | 2026-08-15 | Label unnamed agent panes; clear remaining fix backlog |
| #6 | 2026-08-15 | Fix send falsely reporting "never submitted" for silent commands |
| #5 | 2026-08-14 | Named panes + send submit verification |
| #4 | 2026-08-09 | Per-pane agent state: panes are agents |
| #3 | 2026-08-08 | Stable-id agent targets + amux split (pane helpers & layouts) |
| #2 | 2026-08-04 | Agent coordination: reliable send, whoami, spawn, + portable skill |
| #1 | 2026-07-24 | amux settings: live-preview TUI, theme roster, glyph-fallback fixes |

---

## PR #8 — opencode adapter + an error state

**State:** merged · **Merged:** 2026-08-20 · **Author:** beatzball

Badges opencode panes the way Claude Code panes are already badged, and adds a fifth agent state for an agent that has stopped making progress.

## An `error` state

`error blocked working done idle`, ordered by urgency. `error` sorts first everywhere — tab badge, pane border, status rollup, switcher — and shares `blocked`'s desktop-notification path, because an agent that fell over needs you as much as one waiting on an answer.

The obvious reading of "error" — the agent crashed — turns out not to be the common case. For opencode the dominant trigger is an agent stuck retrying a provider it cannot reach, which upstream does not surface as an error at all. So the state reads better as *this agent will not make progress without you*.

`prefix b` now jumps to an errored pane, preferring it over blocked, so the notification has a target. `amux wait-done` exits non-zero on one rather than reporting a dead agent as finished.

## `amux state` as a public command

`scripts/amux-agent-state` becomes `amux state <state>`: one documented contract for every state source — the Claude hooks, this adapter, a future pi extension, or a user's own script. The script stays where it is, so hooks already configured by absolute path keep working untouched. Still a silent no-op outside an amux pane, which is what makes an adapter safe to leave installed.

## The opencode adapter

`adapters/opencode/amux.js`, symlinked into `~/.config/opencode/plugin/`. A harness can name its own pane through `AMUX_AGENT_NAME`, so an opencode pane reads `opencode` rather than inheriting the `claude` default.

**The event mapping is what a live opencode 1.18.15 was observed to emit, and it disagrees with opencode's published type definitions in four places.** Two matter:

- opencode declares a `permission.ask` hook. Registering it produces nothing when a permission dialog appears on screen — the `permission.asked` **event** is what fires. Everything therefore goes through the single `event` hook.
- `tool.execute.before` fires only when a tool runs, and only after the turn is underway. `session.status → busy` fires at prompt submit and covers turns that call no tool at all.

`session.error` fires for streaming failures and for `MessageAbortedError`, which is the user pressing Esc — mapped to `done`, because badging someone's own keystroke as a crash and notifying them about it would be worse than saying nothing. It does **not** fire for an unreachable provider ([opencode#17648](https://github.com/anomalyco/opencode/issues/17648), open) or a 429 ([opencode#10432](https://github.com/anomalyco/opencode/issues/10432), closed not-planned), so consecutive `retry` statuses are the primary `error` source.

## Testing

Three layers. 275 → **349 assertions**, green.

| layer | where | proves |
| --- | --- | --- |
| bash + isolated tmux servers | CI | the `error` state renders everywhere |
| Node harness, synthetic events | CI | the plugin's event mapping |
| `tests/live/opencode-smoke.sh` | by hand | real opencode, end to end |

The live layer exists because synthetic events drift from real ones, and it earned that on its first run: it found that **`error` was unreachable**. opencode interleaves `busy` with every `retry` (`busy, retry, busy, retry, …`), and the plugin reset its counter on `busy`, so it could never reach the threshold. A pane against a dead provider sat at `working` forever, and every offline test passed. A second finding followed — the badge flapped `working ↔ error` for the whole loop, re-notifying the desktop each cycle.

It needs no account: every XDG home is redirected to a scratch directory, so opencode drives a local ollama model with no credential reachable. What rules it out of CI is the model's size, not auth. It skips — never fails — when ollama or the model is absent, and it sits outside `tests/run.sh`'s glob so the suite cannot pick it up.

## Also in here

- `amux init` wrote **every glyph shifted by one position** — it unpacked four values from a five-element set, so `blocked` and `error` both rendered 💥 and the idle glyph was dropped entirely. Anyone running the documented first-run path was affected. The init test asserted the option *name* was present and never its value, so it passed throughout.
- `amux doctor` gains four informational checks: the plugin symlink (present, dangling, or pointing at a different checkout), a config predating the error glyph, and whether `amux` is on `PATH` at all. All warn; none can fail doctor.
- A real absolute home path was removed from `docs/debug-report-send-false-negative.md` — pre-existing, from an earlier PR, but this is a public repo.
- `docs/known-gaps.md` records what this branch knowingly leaves open, why, and what would close it.

## Known gaps

Two live risks are deferred deliberately, because the obvious fix in each case replaces a verified mechanism with an unverified one. Both are written up in `docs/known-gaps.md` with the experiment that would close them.

- **An opencode subagent may briefly badge the pane `done`.** The plugin does not filter events by `sessionID`. Unverified — and the natural guard fails in the wrong direction, leaving panes stuck on `working`, which is the failure this adapter already shipped once.
- **opencode already exposes `status.attempt`**, its own retry count, which would delete our hand-rolled counter and every reset rule with it. Worth doing after a live run confirms it increments as expected.

## Test plan

- [ ] `bash tests/run.sh` — 349 passed, 0 failed
- [ ] Green on bash 5 and bash 3.2, tmux 3.4 / 3.6 / 3.7b (CI)
- [ ] `bash tests/live/opencode-smoke.sh` — 5/5, run three consecutive times; case 2 reaches `error`, label reads `opencode`
- [ ] Skip path: `AMUX_LIVE_MODEL=definitely-not-a-model bash tests/live/opencode-smoke.sh` → one `SKIP:` line, exit 0
- [ ] `amux init` writes five glyph lines in urgency order
- [ ] `amux doctor` exits 0 with no opencode installed

---

## PR #7 — Label unnamed agent panes; clear remaining fix backlog

**State:** merged · **Merged:** 2026-08-15 · **Author:** beatzball

Clears the remaining backlog so feature work can start from a clean slate. Four small changes, one of which is a genuine behavior improvement and three of which are hygiene.

## An unnamed agent pane labels itself

Panes are labelled by `@amux-name`, falling back to `#{pane_current_command}` — which for a live Claude pane is its **version string** (`2.1.226`), changing every release and meaning nothing to a reader. `amux split -n NAME` and `amux spawn NAME` set a name, but only when someone remembers to pass one; an agent started by typing `claude` into a fresh pane still labelled as a version number.

`scripts/amux-agent-state` is the one place that *knows* a pane is running an agent — it is called by that agent's own hooks. It now stamps a label when it stamps state:

- new global option **`@amux-name-default`**, default `claude`
- it only ever **fills a gap** — an existing `@amux-name` from `-n` or `spawn` always wins
- a label containing a tab or newline **degrades to the default** rather than failing, because this hook runs on every `PostToolUse` and must never break the agent. That corruption is real: unguarded, it produces a two-line `amux status` entry and a *selectable* switcher row with empty key fields, so choosing it runs `switch-client -t ""`.

The hot path is unchanged: the unchanged-state early-bail still makes **exactly one** tmux call, verified with a `tmux`-counting `PATH` shim (7.6 ms/call). The label check is folded into the existing `display-message` format rather than added as a second round-trip. The extra work costs two calls once per pane, on its first state transition, and never again.

It uses `#{?#{==:#{@amux-name},},,X}` rather than `#{?@amux-name,…}` deliberately: tmux format truthiness treats the string `"0"` as **false**, a bug that has already bitten this project at four separate sites. A pane named `0` is correctly treated as named, and there is now a test pinning that.

## `@amux-send-retries` mis-read leading zeros

`"007"` clamped to 20 instead of 7. The 3-or-more-digit clamp exists for a real reason — an absurdly long digit string can make the numeric comparison itself misbehave — but it also caught ordinary zero-padded values. Now bounds length first, then strips leading zeros, with `"000"` landing on `0` rather than the empty string that would slip past a later `[ "$n" -gt 0 ]`.

## Test hygiene

- `tests/test-socket-seams.sh` and `tests/test-agent-state.sh` each created a secondary socket dir cleaned up only on the happy path; an early exit stranded it. Both now covered by their EXIT traps. (288 such dirs had accumulated on the developer's machine before the underlying leaks were fixed.)
- A regression test pins a `send` gap that was closed for free by the cursor conjunct: a pane with a blank prompt running a zero-output command used to report a false "never submitted", because the screen looked identical before and after a real submit. Nothing guarded it.
- A fixture readiness marker replaces a fixed `sleep`, closing a race where a slow interpreter start on a loaded runner would silently invert an assertion.

## Testing

256 → **274 assertions**, green on bash 5 and bash 3.2, 10 consecutive runs with no flake, and `/tmp/amx.*` delta zero across a full run.

Negative controls were run for the leading-zero clamp, the blank-prompt regression, the pane-named-`0` case, and the `"000"` assertion — each verified to **fail** against the unfixed behavior before being accepted. The `"000"` assertion originally passed either way: `[ "" -gt 0 ]` sits in condition position where `set -e` exempts it, so an empty value silently skipped the loop and still exited 0. It now asserts on the captured stderr, which is the only thing that actually differs.

The one exception is the fixture readiness fix, which is a load-dependent race and could not be staged deterministically — flagged rather than claimed.

---

## PR #6 — Fix send falsely reporting "never submitted" for silent commands

**State:** merged · **Merged:** 2026-08-15 · **Author:** beatzball

`amux send` reported **exit 1, "text typed but never submitted"** for messages that submitted perfectly well. A caller seeing that re-sends — so the command runs twice.

This was originally filed as a rare, load-dependent flake. It is neither rare nor load-dependent.

## Reproduction

```
default delay/retries (0.3s x 3 = ~0.9s window):
  instant command (true)        rc=0   the command DID execute
  slow: sleep 3 (silent 3s)     rc=1   the command DID execute   <-- false negative
  slow: sleep 3, delay=2        rc=0   the command DID execute
  echo starting; sleep 3        rc=0   the command DID execute
```

Deterministic. **Any command that stays silent for about a second reports failure.** Load only widened the set of commands that qualified, which is why it first appeared as a flake.

## Root cause

`pending()` decided "still pending" from two signals: the captured pane **text** being byte-identical to a pre-Enter snapshot, and the last non-blank line still containing the message.

Neither can distinguish **"the Enter was never accepted"** from **"the Enter was accepted and the command hasn't printed anything yet."** Both look like an unchanged screen. What actually decided the verdict was whether output arrived inside `retries × delay` — a property of the command, not of the submit.

A decorated interactive prompt hides this by redrawing on its own, which is the other reason it looked intermittent: whether you see it depends on your `PS1`.

## Fix

The tty echoes the newline through the line discipline the instant Enter is accepted, independent of when the command produces output. So the **cursor** reports submission; the screen reports output. Measured on an isolated socket:

| case | screen text | cursor |
| --- | --- | --- |
| shell, `sleep 3`, Enter accepted | unreliable | **moved** `10,1 → 0,2` |
| TUI swallows the Enter | unchanged | **unchanged** `11,0 → 11,0` |

Cursor position is added as a third conjunct: a message is still pending only if the cursor is unchanged **and** the text is unchanged **and** the last line still holds the message.

Deliberately an addition rather than a replacement. Requiring one more condition makes a false "not submitted" strictly harder to reach, which is the safe direction — a false "submitted" degrades to pre-verification behavior, while a false "not submitted" causes re-sends and fires spurious Enters into the pane.

## Testing

253 → **256 assertions**, green on bash 5 and bash 3.2, 20 consecutive runs with no flakiness.

The new test is a negative control: it fails against the unfixed code. Getting it to fail reliably took two empirically-discovered adjustments, both documented — a 5× margin between the command's silence and the retry window, and a plain `sh` receiver, because the tester's decorated prompt was masking the bug by redrawing.

The swallowed-Enter regression (`tests/fixtures/swallow-first-enter.py`) still passes, and the retry path was confirmed to still **fire** rather than merely still be green: the retry `send-keys` was instrumented, the suite run, and the counter showed exactly one firing for the swallowed-Enter test and zero for the new silent-command test.

Full investigation: `docs/debug-report-send-false-negative.md`.

---

## PR #5 — Named panes + send submit verification

**State:** merged · **Merged:** 2026-08-14 · **Author:** beatzball

Two follow-ups from watching per-pane state run live, plus the fallout from reviewing them.

## Named panes

Every place that labelled a pane used `#{pane_current_command}`. For a live Claude pane that reports **`2.1.222`** — its version string, which changes every release and tells a reader nothing. There is no existing tmux field that is both stable and meaningful: `pane_start_command` is empty for shell-started panes, and `pane_title` holds a task description that churns every few seconds.

So a pane can now carry a name:

```sh
amux split -n reviewer          # names the helper pane
amux spawn api-agent            # names its pane from the window name
```

`@amux-name` is preferred at the pane border, both tab formats, `amux status`, and the switcher, falling back to `#{pane_current_command}` when unset. Where a window already carries the same name, the duplicate suffix is suppressed — a spawned window reads `api-agent`, not `api-agent·api-agent`.

Names containing a tab or newline are rejected at `new`, `spawn`, and `split -n`: they previously produced a two-line `amux status` entry and a **selectable garbage row** in the switcher whose key fields were empty, so choosing it ran `switch-client -t ""`.

## `send` verifies its submit

`amux send` types text into a pane and presses Enter. Watched live, against a freshly booted agent, the Enter was swallowed three times running — the text sat unsubmitted and `send` exited 0 every time. Silent false success is the worst property a coordination primitive can have: the sender believes delivery happened and the receiver waits forever on a message that was never sent.

`send` now verifies and retries, and its exit codes mean something:

| exit | meaning | what to do |
| --- | --- | --- |
| 0 | delivered | — |
| 1 | typed but never submitted after retries | retry, or inspect the pane |
| 2 | bad target, or a dead pane | re-resolve the target |

A dead pane used to pass validation and silently swallow the message.

The check is deliberately **conservative**, and the asymmetry is the whole design. A false "submitted" degrades to the old behavior. A false "not submitted" fires a spurious Enter — and in a shell or REPL a bare Enter can re-run the last command, which is worse than the bug being fixed. So a message counts as pending only if the last non-blank line still holds the whole text **and** the pane capture is byte-identical to a snapshot taken between typing and Enter. The trade-off is documented at the decision: in an animating TUI the capture always differs, so the retry never fires there.

An empty message is a legitimate operation — a bare Enter is exactly what unsticks a swallowed submit — so it sends one Enter and skips verification. It previously fired four Enters and always reported failure, because `*""*` matches any string.

## Notes for review

Three defects reached `main`-bound commits before being caught, all in the same family and all invisible to line-by-line reading:

- An unguarded `set-option` after `new-window` aborted `amux spawn NAME CMD` under `set -euo pipefail` whenever the command exited fast enough for tmux to reap the pane first. Measured 0/6 failures before, 2/6 after. A task review looked straight at that line and passed it.
- `#{?@amux-name,…}` uses tmux format truthiness, so a pane named literally `0` fell back to the process name at four sites while the switcher showed it correctly.
- Parameter expansions splitting on a space silently failed against a tab-separated tmux format.

The tests were strengthened accordingly, and several existing ones were replaced because they asserted nothing discriminating — one passed identically with the feature removed.

`tests/run.sh` now fails loudly and names any test file that dies mid-run. It previously counted `^  PASS` lines, so a file dying partway through lowered the total and still reported success.

## Testing

227 → **250 assertions**, green on bash 5 and bash 3.2, and verified inside a **tmux 3.4** container — CI's exact version — which caught a version-specific bug that passed locally on 3.6. Every test runs against an isolated `-S` socket; two files that leaked their socket directories now clean up after themselves.

---

## PR #4 — Per-pane agent state: panes are agents

**State:** merged · **Merged:** 2026-08-09 · **Author:** beatzball

Makes the **pane** the unit of agency. `amux split` puts a second agent beside the first; until now both wrote state to the same window option, so the last hook to fire won and the tab lied about both of them. Everything downstream inherited that granularity — the switcher listed windows, the rollup counted windows, `wait-done` read a window option, `prefix + b` jumped to a window. A helper pane was unreachable and unobservable.

## What changed

| Area | Before | After |
|---|---|---|
| State | `set-option -w` (window) | `set-option -p` (pane) |
| Glyphs | stamped into `@agent_glyph` | derived from `@amux-glyph-<state>` at render time |
| Tab | one glyph per window | one glyph per **distinct** pane state, urgency-ordered, deduped |
| Panes | anonymous | each border badges its own state + since-time |
| `prefix a` | lists windows | lists panes, grouped by window |
| Rollup | counts windows | counts agent panes |
| `wait-done` | window option | pane-precise on `%N`; aggregates a window otherwise |
| `prefix b` | jumps to a window | selects the blocked **pane** |

A pane is an agent **iff** its pane-scoped `@agent_state` is non-empty. A plain shell, a `tail -f`, or a pager is not an agent and never badges anything — which is what keeps a split window's tab from smearing a spurious idle glyph.

## Deletions

`scripts/amux-restamp` and its four callers in the settings live-apply path are gone. Re-stamping existed only to rewrite stamped glyphs when the theme changed; with glyphs derived at render time there is nothing left to go stale, so a theme change is live everywhere immediately. That staleness was the original defect that started this line of work.

## Upgrading a running server

`scripts/amux-migrate-state` clears leftover window-scoped options, because option lookup falls back **pane → window → global** — a leftover window value would be inherited by every unstamped pane and badge plain shells as agents.

It is triggered by **sourcing the conf**, not by the keybinding. That distinction is load-bearing: when you press `prefix + r` on a running server, tmux executes the *old, already-parsed* binding, so wiring the migration into the new `bind r` would not have run it on the one upgrade that matters. Caught by the whole-branch review, with a regression test that fails if the trigger is removed.

## tmux floor

Raised 3.1 → 3.2 (`#{P:}` pane loops, `#{E:}`, pane options). `amux doctor` enforces it.

## Notes for review

Three tmux behaviours drove the design; all were verified by spike against a real server, and two are traps:

- `show-options -wqv` on a pane option **exits 0 with empty output**. Reading state that way makes a wait loop hang until timeout rather than fail loudly.
- A literal comma inside `#{P:...}` is parsed as the active/inactive separator, not as text. There is a regression guard for it.
- `list-panes -a` does not return panes in display order, so the switcher sorts explicitly.

## Testing

135 → **190 tests**, green on bash 5 and bash 3.2. Every test runs against an isolated `-S` socket; none can reach the shared `-L amux` server.

---

## PR #3 — Stable-id agent targets + amux split (pane helpers & layouts)

**State:** merged · **Merged:** 2026-08-08 · **Author:** beatzball

## What this adds

Makes amux agent targets **drift-proof** and adds **`amux split`** — a background helper pane in the current window, with layout control.

### Stable-id addressing (drift-proof)
- `amux spawn`, `amux split`, and `amux whoami` now **emit the stable pane id `%N`** instead of `session:index`. Stable ids are globally unique and never renumber, so a captured target keeps pointing at the same pane even after other windows/panes close (amux runs `renumber-windows on`, so the old `session:index` targets drifted).
- `amux send` / `read` / `wait-done` **accept `%N` and `@N` as well as the friendly forms** (`session:index`, `session:window.pane`, a bare window name) — so typing `amux send api "…"` by hand still works. Only the *emitted* target changed; input is fully backward-compatible.
- `amux status` and the `prefix a` switcher now surface the `%N` target next to the friendly name.

### `amux split [-h|-v] [-t FROM] [CMD...]`
- A **background** helper pane in the caller's current window (`-d`, no focus steal); prints the new pane's `%N`.
- `-h`/`-v` choose the split direction and `-t FROM` chooses which pane to split, so an agent can compose arbitrary layouts — e.g. **agent full-left with a stack of helpers on the right**:
  ```sh
  r1="$(amux split -h claude)"          # right column
  r2="$(amux split -v -t "$r1" claude)" # stacked below r1
  ```
- Guards on being inside amux (`$TMUX_PANE`, or an explicit `-t`).

### The `spawn` vs `split` boundary (documented in the skill)
- `amux spawn` (a **window**) for a co-agent you `wait-done` on — window-level agent state.
- `amux split` (a **pane**) for helpers you `send`/`read`/eyeball — pane state is shared with its window, so `wait-done` on a split pane reflects the window, not the pane. (Per-pane agent state is deliberately out of scope.)

### Docs
- `skills/amux/SKILL.md` + README updated: stable-id targets captured from `spawn`/`split`/`whoami`, the `split` flags and layout recipe, and the boundary.

## Under the hood
- `target()` passes `@N`/`%N` through; friendly forms still resolve as before.
- Fixes a worktree-execution note internally; `bin/amux` stays under `set -euo pipefail` with guarded calls.

## Testing
- New `tests/test-panes.sh` + extended `tests/test-coordination.sh`: prove execution (not just typed text), id routing (`%N`/`@N`), non-attaching spawn/split (active pane/window unchanged), the real full-left/stacked-right **geometry**, the delay-guard hardening, and guards.
- Full suite **135 passed / 0 failed** under bash 5 **and** bash 3.2; CI runs both OSes.

## Constraints honored
tmux 3.1 floor; bash-3.2 safe; guarded tmux calls / never break a running agent; tests use an isolated socket and never touch the real `-L amux` server.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

---

## PR #2 — Agent coordination: reliable send, whoami, spawn, + portable skill

**State:** merged · **Merged:** 2026-08-04 · **Author:** beatzball

## What this adds

Foundation for coordinating agents from **inside** amux — making agent-to-agent messaging reliable and discoverable, plus a portable skill so an LLM knows the loop. amux already had semantic agent states (`@agent_state`) and a blocking `wait-done`; this fills the gaps around them.

### Reliable `amux send`
- **Two-step submit** — types the text (`send-keys -l --`, literal), waits a beat (`@amux-send-enter-delay`, default `0.3s`), then a **separate** `Enter`. A single combined `send-keys "$*" Enter` can drop or race the submit in a full-screen TUI (the prompt sits unsent in the input box). The delay is guarded so no value can abort mid-send.
- **Target validation** — a typo'd target now fails loudly (exit 2, stderr) instead of silently delivering nothing.

### New primitives
- **`amux whoami`** — prints this agent's own canonical target (`session:index`); exit 1 with a message if not inside amux.
- **`amux spawn NAME [CMD]`** — creates a helper agent window **without attaching** (so an agent can spawn peers without hijacking its own terminal) and prints the new `session:index`. `amux new` stays the human "open and jump there" command.

### Discovery
- The **agent switcher** (`prefix a`) now shows each window's `session:index` — the exact `amux send` target — alongside the name.

### Portable skill
- **`skills/amux/SKILL.md`** — harness-agnostic, gated on `amux whoami` (only proceeds inside amux), teaching the loop: discover (`amux status`) → `spawn` → `send` → `wait-done` → `read`. Install with `npx skills add beatzball/amux --skill amux`, or paste it into an agent's instructions.

### Under the hood
- `bin/amux` gains an `AMUX_SOCKET` seam so the subcommands are testable against an isolated tmux server; production is unchanged (`-L amux`).
- Fixed a pre-existing latent bug: `new-window -t "=<numeric-session>"` failed with "index N in use" — both `spawn` and `new` now use `-t "=$sess:"`.

## Canonical target
`session:index` (e.g. `main:2`) everywhere — `send`, `whoami`, `spawn`, the switcher, and the skill all agree.

## Deferred (noted as hook points, not built)
Synchronous `amux ask` (send + wait-done + read), sender attribution (`[from …]`), event/subscribe push, pane-level addressing, an MCP server.

## Testing
- New `tests/test-coordination.sh` — proves *execution* (not just typed text), exit-2 validation, non-attaching spawn, whoami in/out of amux, delay hardening, and the switcher target column. Uses a poll (`wait_for`) so it doesn't flake on a loaded machine.
- Full suite **118 passed / 0 failed** under bash 5 **and** bash 3.2 (macOS `/bin/bash`); CI runs it on ubuntu + macos.

## Constraints honored
tmux 3.1 floor; bash-3.2 safe; guarded tmux calls / never break a running agent; tests use an isolated socket and never touch the real `-L amux` server.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

---

## PR #1 — amux settings: live-preview TUI, theme roster, glyph-fallback fixes

**State:** merged · **Merged:** 2026-07-24 · **Author:** beatzball

## What this adds

An on-the-fly settings experience for amux, plus a wider theme roster and two bug fixes surfaced while testing.

### `amux settings` — live settings TUI
- New `amux settings` subcommand and **`prefix S`** popup to change **theme / glyph set / separator / notifications** without re-running the whole `amux init` wizard.
- **Surgical, atomic config writes** — edits only the one `set -g @amux-…` line it changes (append if missing), preserving any hand-added config. Temp-file + `mv`, with file-mode preservation.
- Changes **apply live** to the running server (reload base + user conf, re-stamp, refresh) and persist to `~/.config/amux/amux.conf`. No-ops cleanly when no server is running.
- `bind r` now **re-stamps existing window glyphs** on reload, so a glyph/theme change is fully live in one keypress (new `scripts/amux-restamp`).

### Live preview
- The **theme / glyph / separator** pickers preview live: moving the cursor repaints the running bar, **Enter** commits, **Esc** reverts to the prior state. The currently-saved option is marked with a `✓`.
- The glyph picker renders each set's actual icons inline.

### Theme roster
- Three new, contrast-validated themes: **gruvbox**, **nord**, **rose-pine** (8 total). Every palette passes `tests/test-contrast.py` (WCAG text/bold + CIE76 ΔE ≥ 20 for logo-vs-active distinctness).

### Bug fixes
- **Unstamped windows showed `💤` regardless of the selected glyph set.** A new/unstamped window has no per-window `@agent_glyph`, so the formats fell back to a hardcoded global default. Fixed at all three render sites (tabs, status rollup, switcher) to fall back to the configured `@amux-glyph-idle` (floor-safe `#{?}`, no `#{E:}`). Regression test `tests/test-window-glyph.sh`.
- **Settings main-menu value column was ragged** (tab stops). Now fixed-width label padding so values align.

### Docs
- README: settings section (live preview, `prefix S`, `✓` marker), expanded theme list, and two screenshots (session overview + glyph-picker drilldown).

## Testing
- Full suite **93 passed / 0 failed** under bash 5 **and** bash 3.2 (macOS `/bin/bash`).
- Contrast validator: **8/8** themes pass.
- CI runs the suite + validator on ubuntu + macos.

## Notes
- Preserves the project constraints: tmux 3.1 floor, bash-3.2-safe (`\xHH`, no `printf '\uXXXX'`), guarded/always-exit-0 scripts, isolated test sockets (never touches the real `-L amux` server).
- Design specs and plans included under `docs/superpowers/`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

