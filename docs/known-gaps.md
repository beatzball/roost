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
dialog is open, and this text would be pasted into it"* — when none is. The
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
*interrupt*, which the `roost hooks` comment in `bin/roost:339-340` and
`site/content/docs/state-badges.md` both describe only for the approve path.

**Three consumers read that badge, and all three are wrong on a stale one:**

- `roost send` — exit 3, forever (`bin/roost:429-433`).
- `roost wait-done` — `busy()` counts `blocked` as busy (`bin/roost:676-696`),
  so it blocks to its timeout and exits 1. The retry loop published at
  `site/content/docs/driving-a-fleet.md:111-117` retries **only** on exit 3, so
  it spins for as long as the script runs.
- `roost read` — prints *"is blocked — this reply is from its previous turn"*
  (`bin/roost:589-592`) about a reply that is in fact the current one.

**Why it is a live risk and not a note.** It needs a human keystroke to create,
but it bites later and unattended: an orchestrating agent that hands work to a
pane whose last dialog was declined never reaches it again, and the error text
it gets tells it to wait for a human who has already answered. Declining a
permission prompt is an everyday action, not an edge case.

**Why it is not worse than that.** It fails closed, never open: nothing is
pasted into anything, the exit code is distinct, and the message it prints names
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
  property (`bin/roost:422-424`) for freshness, so it needs deciding, not
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
and a `send` aimed at a codex pane sitting at a permission dialog pastes into
that dialog and presses Enter on whatever is highlighted.

**Why it shipped anyway.** The gate is codex's and cannot be answered from this
side; `--dangerously-bypass-hook-trust` exists and roost does not use it or
suggest it. This is one of the only two steps `roost install` cannot do (see
the behaviour-change note below): the installer writes `hooks.json` and then
prints this step on every run, including the runs that wrote nothing.
`roost doctor` does the rest of what can be done — it reads the trust entries
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
   the first line of the adapter. **`roost install` writes that flag**, so a
   machine wired by it is past this one; a machine wired by hand may not be.
2. In interactive mode copilot asks the human, **once per directory**, to
   approve the extension — *"wants to: handle permission requests"*. Denying it
   prevents the extension loading. There is no global pre-approval, so every new
   worktree asks again. This is one of the only two steps `roost install` cannot
   do (see the behaviour-change note below).

In both cases the turn runs normally and copilot prints nothing about having
skipped anything. The pane simply stays unstamped, which roost renders exactly
like a shell.

**What that costs, precisely.** It is not only a missing badge. `roost send`
refuses a `blocked` target with exit 3 so that one agent cannot paste into
another's permission dialog — and an unbadged pane is not blocked, so the
refusal never fires. A copilot pane whose extension never loaded, sitting at a
permission prompt, will take a `roost send` straight into that dialog and press
Enter on whatever is highlighted.

**Why it shipped anyway.** Both gates are copilot's, not roost's. The flag is a
switch in the user's own config, so `roost install` now sets it — that half is
no longer manual. The consent is a TUI answer that persists nothing unless the
human picks "always allow in this directory", and no tool can answer it from
here. `roost doctor` does what can be done — it reads `settings.json` for the
flag and prints the exact fix, and it states the consent gate rather than
inferring an answer to it (`AGENTS.md` §9, and the same discipline the adapter
contract's T6 sets out). The install stanza in
`site/content/docs/state-badges.md` names both before a user trusts the badge.

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
find it, and `roost send` pastes into the dialog and presses Enter on whatever is
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

### An opencode pane on a retrying-but-alive provider wears `error` mid-turn

`adapters/opencode/roost.js` badges `error` at the second `retry` of a turn and
then holds it. `RETRY_THRESHOLD` is 2 (`adapters/opencode/roost.js:38`), the
count is raised in the `retry` branch (`:323-325`), and the `busy` branch is
gated on `retries < RETRY_THRESHOLD` (`:319`) — so once the threshold trips,
nothing reports `working` again until the turn ends. The gate is deliberate and
the comment above it is right: opencode re-announces `busy` before every retry,
so an ungated `busy` would flap the badge working/error around the whole retry
loop and re-notify on each cycle (`:293-305`). `session.idle` resets the counter
and stamps `done`.

The threshold was tuned against a **dead** provider, where the retries never
stop and `error` is correct and useful. A **rate-limited but alive** provider is
indistinguishable from a dead one until the turn ends — so on a free tier, where
retries are routine, a pane wears `error` through most of a turn that is
working fine.

**Input:** an opencode pane on a free cloud model (OpenCode Zen,
`nemotron-3-ultra-free`), one ordinary turn.
**Wrong output:** the pane badges 💥 `error` for minutes while the spinner
animates, the context grows and tool calls land — and `roost wait-done` against
it exits 1 with `is in error state, not done` (`bin/roost:719-722`), reporting a
healthy turn as a corpse to whatever is coordinating it. One desktop
notification fires with it (`scripts/roost-agent-state:201-220`); `set` bails on
an unchanged state (`adapters/opencode/roost.js:208-212`), so it is one ping per
turn, not one per retry.

Measured from opencode's own log (`~/.local/share/opencode/log/opencode.log`),
five entries across roughly two minutes of one turn:

```
23:47:14 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
23:48:12 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
23:48:23 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
23:48:26 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
23:49:22 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
```

opencode retried each one and carried on. The turn was healthy throughout.

**This is a third shape of wrong badge, not either of the two already here.**
It is not the stranded `blocked` at the top of this section: that one needs a
human keystroke, never self-heals, and outlives the turn. It is not a stale
badge either — `@agent_since` advances and the adapter is still reporting. The
badge is *accurate about the turn as a whole* and wrong about the present
moment, which is the only thing a glanceable badge is for.

**Why it is a live risk and not a note.** It costs no keystroke to create — a
free tier produces it on ordinary turns — and the consumer that acts on `error`
acts on it wrongly: `wait-done` stops the moment it sees the badge, so a
coordinating agent abandons a turn that would have finished on its own.

**Why it is not worse than that.** It self-heals at the end of every turn:
`session.idle` resets the counter and stamps `done`, so nothing is left stranded
and no pane is unreachable the way a stuck `blocked` one is. It fails loud
rather than silent — the opposite direction from the codex wrong-`done` entry
above — and it costs one notification, not one per retry.

**The fix is deliberately not in this PR.** #27 is the installer; this is an
adapter change carrying its own risk, in the one code path that has already
produced a real bug here (see *opencode counts retries too* below). Two
directions, neither decided:

- Let a genuine sign of forward progress after the retries — a tool call,
  output tokens — return the badge to `working`. It preserves the dead-provider
  behaviour and kills the false red. It has to be a one-way latch within the
  turn rather than a plain reset of the counter, or it reintroduces exactly the
  flapping `:293-305` exists to prevent.
- Leave the logic alone and add a distinct state meaning "struggling but
  alive", reserving `error` for actually dead. That is a new entry in the state
  vocabulary — glyphs, `wait-done`, notifications, the adapter contract — so it
  is by far the larger of the two.

### A space in the checkout path silently un-wires every claude hook

**Input:** install roost into a path containing a space, e.g.
`/opt/My Tools/roost`.
**Wrong output:** the hook command is written into `settings.json` unquoted, so
the shell that runs it splits on the space and tries to execute `/opt/My`. The
hook never fires and the pane never badges. The merge itself returns rc 0 and
reports *"merged"* — nothing is printed anywhere. The same unquoted
interpolation is where a path containing a `"` would break the JSON document.

### The two JSON engines disagree about `{"hooks": null}`

**Input:** a `settings.json` whose `hooks` key is explicitly `null`.
**Wrong output:** which engine is installed decides what happens. `python3`
exits 1 with a raw Python type error as its message; `jq` exits 0 and writes
the file successfully. A user hitting this gets a different outcome on two
machines with the same roost, and the python message names an internal type
rather than the file.

### The other-checkout refusal is checked at plan time, not at write time

`scripts/roost-install` refuses to edit a config wired to a different checkout,
but only while building its plan. The symlink write loop re-checks
`roost_adapter_state` immediately before each `ln -s`; the JSON write loop
calls `roost_json_merge` with no such re-check. A config that becomes
another checkout's between the plan and the write is edited anyway. Small
window, small fix, listed so it is not rediscovered.

### A hardlinked settings.json is silently disconnected

**Input:** a `~/.claude/settings.json` that is a hard link (link count 2), as
some dotfile setups produce.
**Wrong output:** the merge writes a temp file and `mv`s it over the target,
which replaces the inode. The link count drops to 1 and the other name now
points at the old content. Nothing warns. The atomic write is deliberate and
correct for the crash case, so this is a real trade rather than an oversight —
but an unwarned one.

### A mis-quoted default in the patch argument

One default in the merge path is a 14-byte string where an object was meant.
It is inert today because every live caller passes the argument explicitly, so
the default is never taken. Recorded because "inert today" is a property of
the callers, not of the code.

### Nothing confines an extension once it runs

**A live risk, and a deliberate one.** `roost ext` installs code from a git
repository and runs it when you type its command. Roost pins the commit and
asks first; it does not sandbox what runs. An extension can do anything the
user can — read any file, use any key, reach the network.

Real containment means a `sandbox-exec` profile on macOS and something else
entirely on Linux: large, platform-specific, and out of scope for a tmux tool.
Naming it as absent is the honest position, and every piece of user-facing
wording has to survive that. Nothing roost prints may read as a verdict on an
extension's code, and the word "safe" must never appear in it.

### `needs` is a declaration, not a boundary, and cannot be made one

**A live risk about what the field means, not a defect in it.** A manifest
declaring `"needs": ["fleet"]` is given `ROOST_SOCKET`, `ROOST_SOCKET_FLAG` and
roost's scripts on `PATH`; one that declares nothing is given none of them. That
withholding is real and it prevents nothing.

An extension is nearly always run from inside a roost pane, and such a pane
already carries the fleet before the dispatcher runs: `$TMUX` holds the socket
path verbatim, and `bin/roost` puts `$ROOST_HOME/scripts` on the session `PATH`
for every pane it starts. The default socket is the guessable name `roost`
besides. Scrubbing `$TMUX` and rewriting `PATH` would close the first two and
not the third: no arrangement of environment variables stops a program running
`tmux -L roost list-panes`.

So `needs` buys visibility at consent time (and again at `update`, when it
grows) and removes the convenient path. It does not buy prevention. The consent
block says so in as many words — *"An extension that did NOT ask can still reach
them if it tries"* — and the docs page says it again, because the value of the
field rests on users knowing its limit.

### `roost ext verify` does not cover the clone's `.git`

**A live risk, and the cost of a correct exclusion.** An installed extension
keeps a full `.git`, whose ref state changes on every fetch; without the
exclusion every ordinary git operation inside an extension would make `verify`
report a change that is not one. Measured: `git checkout -b` and `git gc` inside
an installed clone leave `verify` reporting `ok`, which is what we want.

What it costs: a payload written to `.git/hooks/post-checkout` or
`.git/payload.sh` inside an installed extension is invisible to `verify`, which
reports `ok`. That is honest — `ok` means "matches what was recorded", and
install recorded with the same exclusion — but it is a region of the tree
integrity does not cover. Nothing roost does today executes from there: the
dispatcher execs only `bin/roost-<cmd>`, every git call sets `GIT_DIR` to a
throwaway object database, and the wrapper forces `core.hooksPath=/dev/null`.
The docs page states the limit rather than implying `ok` covers everything.

### `install` and `verify` run whatever clean filter the user's gitconfig names

**A live risk, small, and it is the user's own code.** `roost_ext_tree_hash`
hashes an extension's tree with `git add`, and `git add` runs any clean filter
configured in the user's own `~/.gitconfig`. No blanket switch exists to turn
filters off, so both `install` and `verify` execute it. Measured: a filter
configured in the user's gitconfig ran three times during one install.

It is named because the consent block promises *"Nothing runs during install"*,
and that sentence is about the extension's code. Anyone tightening that promise
should know this is the one thing it does not cover. The docs page carries the
same qualification.

### The control-character refusal does not cover Unicode bidi formatting

**A live risk, narrow.** Manifest text shown at consent is refused if it
contains any C0 control character or DEL, which closes the ESC repaint that
made the consent block display a commit other than the one installed. It does
**not** refuse Unicode bidi formatting characters (`U+202A`–`U+202E`,
`U+2066`–`U+2069`).

Two free-text fields carry the exposure, and they are not equally visible.
`roost` (capped at 64) is **printed inside the consent block**, on the
`roost  >=A.B.C <D.E.F  (you have X)  ok` row; `description` (capped at 200) is
not in that block at all — `roost ext install` prints `repo`, `ref`, `commit`,
`contract`, `roost` and `claims` (`scripts/roost-ext:2091`–`:2104`) — and
surfaces only in `roost ext info`'s manifest dump. So this gap does reach the
consent prompt. Do not read it as leaving that prompt untouched.

What it cannot do is forge the commit row, and the reason is **per-line**: the
bidi algorithm resolves each line on its own, so no formatting character in the
`roost` row or in a `description` can reorder any other line, including the
`commit` row above it. The exposure is one line reordering itself.

Left open rather than closed because refusing the class would refuse legitimate
right-to-left text, and a tool that cannot describe itself in Arabic or Hebrew
is a worse outcome than a line that can reorder itself. Named as absent rather
than implied closed.

### The two JSON engines disagree about a leading-zero `contract`

**A live risk, narrow.** `contract` is the one hard gate in an extension's
manifest: a version this roost does not speak refuses the install. Which JSON
engine is on the machine decides whether a leading-zero contract passes it.

**Input:** a manifest whose `contract` is written `001` (also `01`, `0001`).
**Wrong output:** on a machine with `jq` and no `python3`, that reads as
contract `1`, matches `ROOST_CONTRACT`, and the extension installs. On a
machine with `python3`, the same manifest is refused before the gate is
reached, with *"could not be read as JSON"*. Same roost, same repository, two
outcomes.

A leading zero is not valid JSON — python3 is right and jq is lenient. The
divergence cannot be closed in the engines: by the time either expression sees
a number, jq has consumed the literal and `001` is indistinguishable from `1`
in its value model. Closing it would mean roost carrying its own JSON parser,
or refusing every number, and neither is worth it for a manifest nobody writes
by hand twice.

Not an escalation — a contract of `001` is a contract of 1, and an extension
that installs this way gets exactly the authority its `needs` declared and the
consent block showed. What it costs is the promise that two users comparing
notes get the same answer. Every other number form was made to agree (see
`roost_ext__manifest_py`'s `json.load`); this one is named as absent rather
than implied closed, and `tests/test-ext.sh` asserts the **divergence**, so it
turns red if either engine ever changes.

### `roost install` reads back its own TAB row with the fields shifted

**A live risk that is benign today — and pre-existing, not from the extension
branch. It is recorded here rather than fixed there.**

`scripts/roost-install` emits a seven-field TAB row at `:781` (and `:784`) whose
sixth field, `json_dead`, is **empty on every ordinary install**. It reads that
row back at `:995` with:

```sh
while IFS="$TAB" read -r h real cfg kept replaced dead label; do
```

Tab is IFS whitespace, so `read` squeezes the two consecutive tabs and every
field after the gap shifts left by one: `dead` receives the label text and
`label` receives nothing. Measured on the exact producer and consumer strings:

```
row:  h<TAB>real<TAB>cfg<TAB>1<TAB>0<TAB><TAB>roost's four Claude hooks
read: dead=[roost's four Claude hooks]  label=[]
cut:  -f6=[]  -f7=[roost's four Claude hooks]
```

Why it is benign **today**: `label` is never read in that loop, and `dead` is
passed on only as `${dead:+"$dead"}` to `roost_json_merge`, where a deaddir of
`roost's four Claude hooks` matches no hook command and changes nothing. It
stops being benign the moment `label` is used, a label string starts resembling
a hook command, or the deaddir match loosens.

`scripts/roost-switch` produces TAB rows the same way but consumes them with
`cut -f` (`:85`–`:87`), which does not squeeze, so it is unaffected. The same
class of bug was found and fixed inside the extension branch, which is how this
one was noticed. The fix here is to read with `IFS=` unset over `read -d` — or
to stop emitting an empty interior field — and it belongs in a branch that owns
`roost-install`.

## Behaviour changes

### A moved or re-cloned checkout still needs codex wired by hand

**A note, not a defect — the claude half of this is fixed.** roost now asks
whether the checkout a hook names still EXISTS, which separates two cases that
used to look identical. A hook pointing at a checkout that is gone is roost's
own and broken, so it is replaced — the same treatment a dangling symlink has
always had. A hook pointing at a checkout that is still there belongs to
somebody who meant it, and is left alone.

`roost doctor` no longer reports the broken case as healthy. Its claude branch
compares the wired command against this checkout's own path, which its codex
branch had always done.

**Codex is still refused, on purpose.** Codex stores a hash of each hook
handler in `config.toml` and silently skips any handler whose hash no longer
matches — nothing on stdout, on stderr, or in the TUI. Rewriting one to point
at the new checkout would un-badge a machine that had already granted trust,
which is worse than leaving it. What changed is only the words: roost says the
checkout no longer exists rather than blaming "a different checkout", which
sent people looking for a checkout that was not there.

**What you do:** run `roost hooks codex` and copy the object into
`$CODEX_HOME/hooks.json` yourself, then answer codex's trust prompt.

### Wiring is part of installing now, and two prompts are all that is left

**A note, not a defect.** Pointing roost at your agents used to be a separate
manual step per harness. `curl … | sh` now does it in the same step as the
`PATH` line, and `roost install` — alias `roost update`, the same code path —
is the re-run for later: a harness installed since, a moved or re-cloned
checkout, a release that adds an adapter. Neither fetches new roost code.

**The only two steps `roost install` cannot do are prompts**, and it prints
both on every run, including runs that wrote nothing:

- codex — *"Trust all and continue"* at its `Hooks need review` prompt.
- copilot — the per-directory *"wants to: handle permission requests"*.

Neither can be answered from this side, and neither leaves anything on disk to
detect, so both are stated rather than inferred. They are listed because they
are permanent, not because they are outstanding work. What each costs on a
machine where nobody has answered it is a different question, and it is a live
risk that stays above: *"A codex adapter can be installed, correct, and
silently switched off"* and *"A copilot pane can be badge-less, and nothing
says so"*.

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

- **No signature verification of an extension.** Pinning to a full commit SHA,
  and recording the tree hash `roost ext verify` re-checks, is the substitute:
  it proves what runs is what was agreed to, and says nothing about who wrote
  it. Deliberate for build 1.
- **No pattern screening at consent** (`curl | sh`, writes to `~/.ssh`,
  `~/.aws`, `crontab`). Deliberately absent. If it is ever added it must be
  *information only* — never a refusal, never a verdict, and never the word
  "safe". It would catch careless, not malicious, and a screen users believe is
  worse than no screen at all.
- **Extension events are contract 2, with no consumer yet.** Contract 1 is
  commands only. Roost's state hook already fires on every tool call, so events
  are reachable; shipping an event API with no consumer would have frozen its
  shape on the day it landed. The contract integer is what makes adding them
  later non-breaking.
- **`roost doctor` does not check extensions.** It reports nothing about
  `ext.lock`, a clone that is missing, or a lockfile that disagrees with
  `ext.index`. `roost ext list` warns on the disagreement and `roost ext verify`
  answers the integrity question, but neither is on the path a user takes when
  something is wrong and they reach for `doctor`.
- **The `roost` range parser handles three forms only** — `>=A.B.C <D.E.F`, `*`,
  and absent. Anything else warns "unparsable range, skipping check" and
  continues. Deliberately tiny: the field is advisory, so a fancier range must
  never be able to harden into a refusal. Whoever widens it inherits that rule.
- **`roost_test_tmux_named_guard` protects only the three test files that call
  it**, and cannot detect its own absence in a fourth. It refuses unless
  `TMUX_TMPDIR` is set, exists, and sits under a temp root — which is what keeps
  a `tmux -L <name>` in a test away from the live agents' socket directory — but
  a new test file that uses `-L` and forgets the call gets no warning from
  anything. Closing it mechanically is a CI grep for `tmux -L` under `tests/`
  with no nearby guard call; it has not been written.
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
- `roost validate` now reports adapter links from the installer's own record
  (`roost install --records`) rather than from the disk, which fixed two
  divergences between "is it linked" and "did this run link it". One shape is
  left, and it is wording in the report rather than anything the run does to
  the machine: a candidate the installer reached no verdict on — a write that
  failed, or an installer that could not start — lands in the same bucket as a
  path roost refused to touch, and §1 renders that bucket as *"Something that
  is not this checkout's adapter already sits at each path below"*, sending the
  tester to look for a conflicting file that is not there. Measured by making
  the write fail (`chmod 555` on the adapter's parent directory): the record
  line comes back `failed<TAB>opencode<TAB><path>`, and validate files anything
  that is not `wrote` or `unchanged` under `BLOCKED_LINKS`. Two things keep it
  small — the run prints `could NOT link <path>` on stdout as it happens, and
  §5 re-reads the disk, so for the same harness it says *"the adapter is not
  linked — run: mkdir -p … && ln -s …"*. The two sections disagree and the one
  carrying the fix is the correct one. Left because the honest fix is a fourth
  bucket in `report_install` ("this run could not link it"), a report change
  with its own test file, and because reaching it at all needs a directory
  roost can read but not write.
- The executable bit on `tests/test-*.sh` is split with nothing distinguishing
  the two groups: 11 files at mode 644 and 16 at 755, re-measured with
  `git ls-files -s tests/test-*.sh | grep -c '^100644'` (and `100755`) at
  `9738321`. It was 9 and 15 at the commit that fixed `test-doctor.sh` and
  `test-next-blocked.sh`, so the split is still growing. Cosmetic —
  `tests/run.sh` invokes `bash "$t"`, so no test has ever needed the bit.
  Left alone rather than swept, because a `chmod` across nine files that other
  branches are editing collides for no benefit.

## Process lessons

### A sweep done from a review's list is not a sweep

PR #29 changed one phrase across the repo after #31 replaced typing with
pasting. Three review rounds running, a reviewer returned with more sites:
five, then about fifteen — two of them in the very file whose section had just
been rewritten — then five more, plus two the author found alongside them. Each
round the listed sites were fixed and the job called done.

Only `fc6c30c` ran a `grep` over the whole tree instead of working from the
report, and that is the commit that actually closed it.

**And the mirror of it, in the very next commit.** Sweeping a phrase without
reading each site produced the opposite error: `394f314` changed four comments
in `tests/live/*-smoke.sh` to say "delivered" when those scripts use raw
`tmux send-keys`, not `roost send`. "Typed" was correct there, and
load-bearing — the race those comments explain exists *because* keystrokes
reach a TUI that has not rendered. Reverted in `fbb805f`.

Neither half is reading the code: taking a list on trust, or taking a phrase on
trust. A sweep finds the candidates; only the surrounding code says which are
real.

**Commits, not round numbers.** This entry named ordinals twice and had them
wrong both times — which is the failure it is about. A SHA cannot drift.

### A mutation that fails to apply reports the fix as unnecessary

Six mutations across PR #29 earned their keep. A seventh lied: its anchor
string did not match, so nothing was mutated, the suite stayed green, and the
result read exactly like "this fix was not needed". Every mutation since
asserts its own anchor before running.

Two of the six found what the tests could not. One showed a flag-consuming
loop was dead code, because removing it turned nothing red. One showed an
assertion passing for the wrong reason — it checked only that the exit code was
non-zero, and the command failed for an unrelated cause. Three assertions in
that file were checking status where they meant to check the message.

**A test that cannot fail and a fix that is not needed look identical from
here.** Only a mutation proven to have been applied tells them apart.

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
