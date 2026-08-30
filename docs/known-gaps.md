# Known gaps and follow-ups

Risks carried by what has shipped, and why each was left rather than fixed.
Not a wish list — the spec's "Out of scope" sections cover future work. This
file covers things that are already live and could surprise you.

The section headings carry the severity, so read them first. **Behaviour
changes** are things to know about, not defects. **Live risks** are the ones
that can actually bite. Each entry says plainly which it is — an entry that
reads like an alarm when it is merely a note is a bug in this file.

Keep it short. When an entry is fixed, delete it.

## Live risks

### A turn that ends at a permission dialog leaves `blocked` stamped forever

Answering **No** to a Claude Code permission dialog, or pressing Esc at one,
ends the turn without firing `PostToolUse` or `Stop`. `@agent_state` was
stamped `blocked` by the `Notification` hook and **nothing ever unstamps it**.

**Input:** a Claude Code pane at a permission dialog; the human answers `4. No`
(or presses Esc).
**Wrong output:** the dialog closes and the pane sits idle at an empty prompt,
but `roost send` still refuses it with exit 3 and the message *"a permission
dialog is open, and this text would be typed into it"* — when none is. The
target is unreachable to every roost coordination command until something else
stamps that pane.

Measured on Claude Code 2.1.251, on a throwaway `-S <tmpdir>/roost` server,
badge and screen captured in the same second:

```
t0=1788043147 t1=1788043147 span=0s  badge=[blocked]
grep 'Do you want'   -> 0
grep 'Esc to cancel' -> 0
  ⎿  Interrupted · What should Claude do instead?
❯
```

`@agent_since` stays frozen at the instant the `Notification` hook fired, which
is how a stale badge is told apart from a live one. Both triggers were re-run:
Esc held `blocked` for 97 s, `4. No` for 46 s, neither self-healing. Answering
**Yes** does clear it — the tool runs, `PostToolUse` fires, the pane goes
`working` then `done` — so the surviving hole is exactly *decline* and
*interrupt*, which the `roost hooks` comment in `bin/roost:240-241` and
`site/content/docs/state-badges.md` both describe only for the approve path.

**Three consumers read that badge, and all three are wrong on a stale one:**

- `roost send` — exit 3, forever (`bin/roost:346-350`).
- `roost wait-done` — `busy()` counts `blocked` as busy (`bin/roost:593-613`),
  so it blocks to its timeout and exits 1. The retry loop published at
  `site/content/docs/driving-a-fleet.md:111-117` retries **only** on exit 3, so
  it spins for as long as the script runs.
- `roost read` — prints *"is blocked — this reply is from its previous turn"*
  (`bin/roost:506-509`) about a reply that is in fact the current one.

**Why it is a live risk and not a note.** It needs a human keystroke to create,
but it bites later and unattended: an orchestrating agent that hands work to a
pane whose last dialog was declined never reaches it again, and the error text
it gets tells it to wait for a human who has already answered. Declining a
permission prompt is an everyday action, not an edge case.

**Why it is not worse than that.** It fails closed, never open: nothing is
typed into anything, the exit code is distinct, and the message it prints names
the escape hatch (`roost send --force`) in its own second line. A human typing
anything into the pane clears it on the next `UserPromptSubmit`.

**The same shape is now measured on codex and on copilot**, which widens this
from a Claude Code entry to a cross-harness one. Both adapters clear `blocked`
only on the harness's post-tool event, and declining fires no such event —
so nothing unstamps the pane, exactly as above. Measured by `roost validate`
on a throwaway `-S <tmpdir>/roost` server, codex-cli 0.151.0 and Copilot CLI
1.0.81, Esc at a real dialog:

```
codex    +58s badge=[blocked] since=1788058642
         +122s badge=[blocked] since=1788058642   age=64s, frozen
         screen: "✗ You canceled the request to run echo roost-validate-escalate"
                 "■ Conversation interrupted"      -- no dialog on screen
         roost send -> exit 3
copilot  +5s  badge=[blocked] since=1788058761
         +60s badge=[blocked] since=1788058761    age=59s, frozen
         roost send -> exit 3
```

**Re-measured on codex against its REAL provider**, not the local rig: an
OpenAI account signed in with ChatGPT, `gpt-5.6-luna`, no tool-stripping proxy
in the loop, hooks installed from `roost hooks codex` and trusted through
codex's own prompt. It reproduces identically, so this is not an artefact of a
small local model or of the rig that drives one:

```
+5s   badge=[blocked] since=1788078805
+68s  badge=[blocked] since=1788078805   age=63s, frozen
screen: "✗ You canceled the request to run echo roost-validate-escalate"
        "■ Conversation interrupted"     -- no dialog on screen
roost send -> exit 3
```

opencode does **not** have it, and that has now been measured twice: once
against local ollama and once against an opencode free cloud model over the
network. Both left `blocked` 1s after Esc, and `roost send` then exited 0. So
the hole is per adapter and tracks the event the adapter clears on, not
something general to roost and not something about the provider — which is what
makes the first candidate below (confirm the badge against the pane) the fix for
all three at once rather than three separate ones.

**Not fixed here, because the fix is a behaviour change to the guard**, and
that is its own task. Two candidates, neither implemented:

- Have the `send` guard confirm the badge against the pane before refusing —
  `capture-pane` and look for the dialog — and downgrade to a warning when the
  screen disagrees. That trades the guard's current "exact, no scraping"
  property (`bin/roost:338-340`) for freshness, so it needs deciding, not
  assuming.
- Have `roost doctor` report it. It reads no live pane state today, so this
  would be a new kind of check: list panes stamped `blocked` whose visible
  screen carries no dialog marker, and name them. Cheap, read-only, and it
  turns an invisible deadlock into a line of output.
### A codex pane reports a dead turn as ✅ done

Codex has exactly twelve hook events — `PreToolUse`, `PermissionRequest`,
`PostToolUse`, `PreCompact`, `PostCompact`, `SessionStart`, `SessionEnd`,
`UserPromptSubmit`, `SubagentStart`, `SubagentStop`, `Stop`, `Interrupt` —
enumerated out of the shipped binary and confirmed against live runs on 0.150.1
and 0.151.0. **None of them reports an error.**

A turn that never reaches the model still ends, and codex still fires `Stop`.
So `adapters/codex/roost-codex-hook` maps that ending to `done`, and the pane
says *"finished, go look"* about a turn that produced nothing. `roost read`
then serves whatever `last_assistant_message` the payload carried, which for a
dead turn is empty — so the reader falls back to scraping the screen and gets
the error text as chrome rather than as a state.

This is the `#13` bug shipped deliberately rather than by accident, and **a
wrong `done` is the worst wrong badge there is: every other one makes you look,
and this one makes you stop looking.** `roost wait-done` will report success on
a corpse, and `roost next-blocked` has nothing to jump to.

**Why it shipped anyway.** There is no signal to build it on. The only
candidate is an unmatched `PreToolUse` — a live turn whose tool call failed
showed five `PreToolUse` against four `PostToolUse` — and a heuristic built on
that mislabels a healthy turn `error`, which fires a desktop notification for
nothing. The adapter contract's §1 rules that out explicitly: do not invent a
state from a signal nobody has seen behave. Every other harness roost adapts
has a real failure declaration; codex does not, and inventing one is worse than
naming the gap. The Codex section of `site/content/docs/state-badges.md` states
it before a user trusts the badge.

### A codex adapter can be installed, correct, and silently switched off

`adapters/codex/roost-codex-hook` only runs once a human has answered *"Trust
all and continue"* at codex's `Hooks need review` prompt. Until then all four
hooks are skipped, and **codex says nothing about it**. This is the complete,
unedited stderr of a `codex exec` turn with untrusted hooks wired:

```
warning: clamping SessionEnd hook timeout to 3s in <scratch>/cxhome/hooks.json
warning: clamping Interrupt hook timeout to 3s in <scratch>/cxhome/hooks.json
warning: Model metadata for `granite4.2:3b` not found. ...
codex
alpha
```

Warnings about timeouts. A warning about model metadata. Nothing about four
hooks being skipped. Codex's own docs promise a startup warning pointing at
`/hooks` — true of the TUI, false of `codex exec`, which is where automation
lives.

**What that costs, precisely.** The same as the copilot entry below: an
unbadged pane is not `blocked`, so `roost send`'s exit-3 refusal never fires,
and a `send` aimed at a codex pane sitting at a permission dialog types into
that dialog and presses Enter on whatever is highlighted.

**Why it shipped anyway.** The gate is codex's and cannot be answered from this
side; `--dangerously-bypass-hook-trust` exists and roost does not use it or
suggest it. `roost doctor` does what can be done — it reads the trust entries
out of `$CODEX_HOME/config.toml` and counts them, so "installed" and "will run"
are reported as the different claims they are.

**The residual risk doctor cannot see.** A trust entry stores a *hash* of the
normalised handler. roost does not know codex's normalisation, so four present
entries are not proof that four hooks will fire: a `hooks.json` hand-edited
after trust was granted keeps its entries and loses its hooks. roost's own
answer is upstream of doctor — `roost hooks codex` emits handler objects frozen
at v1 that never change again, so a roost upgrade can never be the cause.

### A copilot pane can be badge-less, and nothing says so

`adapters/copilot/extension.mjs` only runs once **two** gates are past, and
neither one announces itself when it is not:

1. Copilot's extension system is behind a feature flag that is off by default.
   Without `copilot --experimental` or `{"enabledFeatureFlags":
   {"EXTENSIONS": true}}` in `~/.copilot/settings.json`, copilot does not read
   the first line of the adapter.
2. In interactive mode copilot asks the human, **once per directory**, to
   approve the extension — *"wants to: handle permission requests"*. Denying it
   prevents the extension loading. There is no global pre-approval, so every new
   worktree asks again.

In both cases the turn runs normally and copilot prints nothing about having
skipped anything. The pane simply stays unstamped, which roost renders exactly
like a shell.

**What that costs, precisely.** It is not only a missing badge. `roost send`
refuses a `blocked` target with exit 3 so that one agent cannot type into
another's permission dialog — and an unbadged pane is not blocked, so the
refusal never fires. A copilot pane whose extension never loaded, sitting at a
permission prompt, will take a `roost send` straight into that dialog and press
Enter on whatever is highlighted.

**Why it shipped anyway.** Both gates are copilot's, not roost's, and neither
can be worked around from this side: the feature flag is a preview switch in the
user's own config, and the consent is a TUI answer that persists nothing unless
the human picks "always allow in this directory". `roost doctor` does what can
be done — it reads `settings.json` for the flag and prints the exact fix, and it
states the consent gate rather than inferring an answer to it (`AGENTS.md` §9,
and the same discipline the adapter contract's T6 sets out). The install stanza
in `site/content/docs/state-badges.md` names both before a user trusts the badge.

### pi's `blocked` rides on an undocumented internal, and would fail silently

`adapters/pi/roost.ts` reaches `blocked` by wrapping the four blocking dialog
methods on `ctx.ui`. That works — and reaches *other* extensions' dialogs, which
is the whole point, since pi raises none of its own — only because `ctx.ui` is a
getter returning **one shared object** for every loaded extension
(`dist/core/extensions/runner.js:458`, pi 0.81.1). Verified live end to end: a
separate gate extension called `ctx.ui.confirm`, and the adapter badged the pane
`blocked` with the dialog on screen.

**That sharing is not a documented contract.** If pi ever gives each extension
its own `ctx.ui` — a reasonable isolation change — the wrap keeps working for
dialogs roost itself raises (none) and stops seeing everyone else's. There is no
crash and no error. The badge simply never appears again.

**What that costs, precisely.** Only users who have installed a permission gate
of their own are exposed, because a stock pi has no dialogs at all. For them the
failure is the "silently stuck" one the adapter contract's §3 names: the pane
reads `working` while a human stares at a prompt, `roost next-blocked` does not
find it, and `roost send` types into the dialog and presses Enter on whatever is
highlighted.

**Why it shipped anyway.** The alternative is not to offer `blocked` for pi at
all, and the mechanism was verified working against the shipped build rather
than inferred. `tests/live/pi-smoke.sh` asserts `blocked` against a real dialog
raised by a real second extension, so a pi upgrade that breaks it turns a silent
gap into a red test — that test is the mitigation, and it has to be run after
every pi upgrade for the mitigation to be real. The durable fix is upstream: a
`dialog_open` / `dialog_close` event would make this a supported integration
point rather than a reach into an internal.

### A `pi -p` or `--mode json` pane is never badged, on purpose

`adapters/pi/roost.ts` reports nothing unless `ctx.hasUI` is true — interactive
and RPC mode only. A pane where a human types `pi -p "…"` themselves stays
unstamped, which roost renders exactly like a shell.

**Why.** pi's sub-agent pattern (its shipped `examples/extensions/subagent/`)
runs each sub-agent as a **separate `pi --mode json -p --no-session` process**,
and a child inherits the parent's `$TMUX_PANE` and loads the same global
extensions. Measured live on 0.81.1 from inside a roost pane: the child logged
`TMUX_PANE=%114`, `mode=json`, `hasUI=false`. Ungated, every sub-agent badges
its **parent's** pane — `working` when it starts and `done` when it finishes,
while the parent is still working — and publishes its own answer as the pane's
reply. That is the adapter contract's T1 with two OS processes instead of one,
so no in-process filter can see across it.

**What the trade costs.** A `pi -p` pane reads as "not an agent": `roost
wait-done` against it returns immediately because it is never `working`, and
`roost read` falls back to scraping the screen with its stderr notice. A
coordinating agent that treats `pi -p` as a fleet member gets chrome where it
expected an answer.

**Why it shipped this way.** A wrong `done` from a sub-agent is worse than a
missing badge from a one-shot command, and there is no third signal available:
the child is indistinguishable from a hand-typed `pi -p` except by the one
property that says a human is attached. Tier 0 covers the gap —
`roost state working && pi -p "…" && roost state done` — and
`site/content/docs/state-badges.md` prints that line in the pi section.

## Behaviour changes

### `bin/roost` now addresses the roost server you are inside

With `ROOST_SOCKET` unset, every `roost` subcommand used to address the shared
`-L roost` server no matter which server the caller's own pane was on. It now
resolves in three steps — `ROOST_SOCKET`, then the server it is running inside,
then `-L roost` — the same order `roost-status`, `roost-switch` and
`roost-notify` already used, via `scripts/lib/roost-socket.sh`.

**This is the fix for a live risk, not a new one.** It is what makes `roost
reply` land on a non-default server, where the badge already did.

Only a socket path ending in `/roost` counts as "inside roost", so `roost
spawn` typed from a user's everyday tmux still means the roost server. Nothing
changes for the default single-server install: `-L roost` resolves to a path
ending in `/roost`, so both steps name the same server.

### `roost wait-done` exits non-zero on an errored target

`wait-done` no longer treats "stopped being busy" as success. An errored pane
makes it print `roost: '<target>' is in error state, not done` and exit 1.

**Nothing shipped broken, and no existing usage can break.** Before this
branch the state vocabulary was `blocked working done idle` and anything else
normalised to `idle`, so a pane could not be in `error` at all — the condition
this exit code fires on was unreachable. `wait-done` would have called an
errored agent finished only in the window between the commit that added `error`
and the commit that taught `wait-done` about it, both on this branch. There are
no programmatic callers outside this repo's own tests, and the README's
`for w in ...; do roost wait-done "$w"; done` loop is not `set -e` guarded.

**If you script against it:** a non-zero exit now means *error or timeout*,
distinguished by the message. `skills/roost/SKILL.md` says so, because agents
read that file to coordinate, and one that assumed "non-zero means timeout"
would retry a corpse. A `set -e` script will now stop on a dead agent rather
than continuing — the intended improvement, but a change in flow.

Failing loudly is the safe direction. The unsafe direction is a wrong success,
and `wait-done` can only refuse one if nothing upstream of it reports a failed
turn as `done` in the first place — which is why `adapters/opencode/roost.js`
swallows the `session.idle` that follows a `session.error`.

### opencode counts retries too, and we still count our own

`adapters/opencode/roost.js` hand-rolls a consecutive-`retry` counter.
opencode's `SessionStatus` carries `{type: "retry", attempt, message, next}`,
and `attempt` is upstream's own count. Measured on 1.18.20, two dead-provider
turns in one TUI session (`tests/live/opencode-smoke.sh` case 2 prints this):

```
    turn ended: attempts [1, 2, 3, 4, 5]
    turn ended: attempts [1, 2, 3, 4, 5]
```

So `attempt` is per session, increments once per retry, and restarts at 1 in
the next turn — the same rule our counter follows.

**Left as it is, and the entry it replaces overstated the prize.** Reading
`status.attempt` would not delete the counter: the `busy` branch is gated on
the count so the badge cannot flap during a retry loop, and `busy` events carry
no `attempt`, so a local number and its turn-boundary resets have to stay
either way. The change is one line (`retries += 1` becomes `retries = attempt`)
in exchange for a dependency on upstream's numbering, in the one code path that
has already produced a real bug here.

## Small deferred items

- A `roost.conf` produced by the legacy migration **before** it learned to
  backfill `@roost-glyph-error` still predates the error state, and migration
  cannot re-fire on it (it only runs while `roost.conf` is absent — an
  existing one always wins, because a running amux server may still be reading
  the old file). Nothing writes that value on their behalf. `roost doctor` now
  names the missing line, the glyph being inherited, and the exact fix
  (`roost settings`, re-pick the set), which is as far as a read-only check
  goes.
- `tests/pi-extension-harness.mjs` imports the adapter's `.ts` directly, which
  needs node >= 22.18 (or >= 23.6) for unflagged type stripping. On an older
  node the whole file prints one `SKIP` line and exits 0 — the honest degrade,
  but a whole harness quietly not running is exactly the shape this file's own
  "green is evidence about the tests" lesson warns about. `.github/workflows/ci.yml`
  pins node so CI cannot land there; a contributor on an older node can still
  skip it without noticing. Shipping the adapter as `.js` was the alternative and
  was rejected: pi's discovery glob only looks for `*.ts` and `*/index.ts`, so a
  `.js` adapter is a file pi never loads.
- `tests/live/codex-smoke.sh` runs a harness that can modify the machine it is
  tested on. A codex TUI being driven inside an isolated tmux socket ran
  `brew upgrade --cask codex` and replaced the host's binary mid-test — the tmux
  socket, `CODEX_HOME` and the XDG homes were all isolated and all held; a
  system package manager is not something a scratch directory contains. The test
  sets `check_for_update_on_startup = false`, which is codex's own switch rather
  than a boundary roost enforces. Full write-up, and what it means for the next
  harness, in `docs/airig/issues/2026-08-29-codex-upgrades-its-own-host.md`.
- The executable bit on `tests/test-*.sh` is split with nothing distinguishing
  the two groups: 11 files at mode 644 and 16 at 755, re-measured with
  `git ls-files -s tests/test-*.sh | grep -c '^100644'` (and `100755`) at
  `9738321`. It was 9 and 15 at the commit that fixed `test-doctor.sh` and
  `test-next-blocked.sh`, so the split is still growing. Cosmetic —
  `tests/run.sh` invokes `bash "$t"`, so no test has ever needed the bit.
  Left alone rather than swept, because a `chmod` across nine files that other
  branches are editing collides for no benefit.

## Process lessons

### Blast radius enumerated from memory misses consumers

The `error` state's blast radius was enumerated from recall and missed two
consumers. One of them, `scripts/roost-init` (then `amux-init`), shifted every
glyph by one position for anyone running the documented first-run path — and
the init test asserted the option *name* was present, never its value, so it
passed throughout. The other, `scripts/roost-next-blocked` (then
`amux-next-blocked`), left the notification that `error` fires with no jump
target.

For the next harness increment: derive the blast radius from `grep` over the
state vocabulary and the glyph accessor, not from memory. `grep -rn
roost_glyphset` finds all five positional consumers in one second.

### A fixture that stops where the feature does proves nothing (#12, #14)

`#12` shipped the opencode reply channel, and it published nothing on **any**
turn — not an edge case, every agent, straight back to `roost read` scraping the
screen. It sat on `main` through `#13` before anyone noticed.

The suite did not merely miss it. It could not see it:

```
tests/opencode-plugin-harness.mjs against the BROKEN adapter -> 44 passed, 0 failed
tests/opencode-plugin-harness.mjs against the FIXED  adapter -> 44 passed, 0 failed
```

Identical. 529 assertions green across the repo, feature dead.

The fixtures were built from a real recorded opencode turn, which is the right
instinct — and they were trimmed to the events the feature reads: the assistant
`message.updated`, its text parts, then `session.idle`. The live stream does not
stop there. opencode **re-announces** the assistant message twice *after* the
text parts, and the handler cleared the collected reply on every announcement,
so it was wiped a moment before the line that would have published it. The two
events that broke it were the two the fixture left out, because at fixture-writing
time they looked like noise after the interesting part.

Only the live two-pane check found it, and only after the merge.

**Two rules, both cheap:**

- A fixture derived from a recording replays the **whole recorded turn**, in
  order, trailing events included. Trimming a recording to the events you
  believe matter encodes the belief you are trying to test. Keep the recorded
  log line numbers in a comment so the next reader can check the fixture against
  the capture rather than against the code.
- A regression test is **run against the unfixed code first**, and its failure
  output goes in the pull request. A test written after the fix, that has never
  been seen red, is an assertion that the code does what it does. `#14` does
  this: five fixtures, 5 failed before the one-line change, 0 after.

The wider point is the one the entry above already makes in a different key:
green is evidence about the tests, not about the feature. When a mechanism has
never been exercised end to end outside its own harness, say so plainly at
review time rather than reading the count as coverage.
