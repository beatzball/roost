# Rename `amux` → `roost`

Status: agreed, not started — **unblocked**
Date: 2026-08-16 (revised 2026-08-19)
Size: **Build** (changes interfaces outside this repo)
Base: `7bd1ed4` — post-history-rewrite `main`, with the OpenCode adapter merged

## Why

The name `amux` is unwinnable. A survey of GitHub found **89 repos named `amux`
and 11 named `atmux`**, of which **~46 are genuine AI-agent multiplexers**. Nine
are actively shipped. The leader (`mixpeek/amux`) has 350 stars and a Homebrew
tap; `andyrewlee/amux` has 146 and its own tap. Nineteen of the ~46 were pushed
within the last 30 days.

`roost` was chosen after checking GitHub, Homebrew core, npm, and domains:

- No dominant GitHub incumbent — the largest exact-name repo is a 61-star
  materials-science project, a different field entirely.
- Free in Homebrew core.
- `roosting.dev` available (the bare `roost.dev` is taken).

Runners-up were `escarp` and `butte` (near-zero GitHub collisions), rejected as
too obscure and as reading like "butt" respectively. `perch` was rejected
(Google Research, 381 stars). Any `-mux` suffix was rejected as re-entering the
crowded field.

The site will be `roosting.dev`. The CLI is `roost`. These deliberately differ;
that is normal and needs no reconciling.

## Oracle — how we know it worked

**Primarily automated.** The repo has 21 test files under `tests/`, a live
suite (`tests/live/opencode-smoke.sh`), and CI (`.github/workflows/ci.yml`).

| Check | Type | Asserts |
|---|---|---|
| `tests/run.sh` passes on the renamed tree | Automated | No behaviour changed |
| Grep gate | Automated | No `amux` outside the allowlist (below) |
| New: socket-guard test | Instrumented | `roost-agent-state` no-ops on an `amux` socket, and `amux-agent-state` no-ops on a `roost` socket |
| New: config-migration test | Instrumented | `roost init` reads a legacy `~/.config/amux/amux.conf` and writes `~/.config/roost/roost.conf` |
| Status bar across all 8 themes; glyph picker; fzf switcher; desktop notification | **Human-eye** | Rendering is unchanged |

The human-eye items are **batched into one pass at the end**, not run per task.
Tests must use isolated `-S` sockets and must never touch the live `-L` server.

## Decisions already made

1. **`roost` gets its own socket** (`tmux -L roost`). The existing `-L amux`
   server is never touched by the new code.
2. **`amux` keeps working during the transition**, and is deleted once the last
   `amux` session is drained and closed.
3. `docs/superpowers/` becomes `docs/airig/`.
4. **A new `beatzball/roost` repository is created and pushed to. The repo is
   NOT renamed.** `beatzball/amux` went **private** on 2026-08-19 and stays
   private; whether it is deleted is a later decision.

   *Superseded:* an earlier revision said the repo would be renamed and that
   "GitHub redirects the old URL, so this is low-risk and can happen at any
   point". Both halves were wrong, and the reason matters. **A GitHub rename
   keeps the same repository** — same objects, same SHAs, same PRs, plus a
   redirect. Pre-rewrite objects containing the maintainer's home path were
   still being served after the force-push, so a rename would have purged
   nothing and the redirect would have kept the leak reachable at the old URL.
   Going private 404s both (verified anonymously) and freezes forks at 0, which
   keeps a clean-delete option open instead of letting it expire on the first
   fork.

   The cutover is therefore **sequenced, not "any point"**: it happens after
   the clean history is ready to push and after PR archival (Decision 5).

5. **PR history does not carry to a new repository.** `#1`–`#8` (~28.7 KB of
   bodies, 0 issues) exist only in `beatzball/amux`. If that history is wanted,
   it is archived into the tree *before* cutover.

## Scope — eight namespaces

A rename here is not one substitution. These are independent, with different
blast radii.

| # | Namespace | Now | After | Transition |
|---|---|---|---|---|
| 1 | Command | `bin/amux` | `bin/roost` | both files present |
| 2 | Socket | `tmux -L amux` | `tmux -L roost` | separate servers, by design |
| 3 | Server config | `tmux/amux.conf` | `tmux/roost.conf` | both present |
| 4 | Scripts | `scripts/amux-*` (11 files) | `scripts/roost-*` | both present |
| 5 | tmux options | `@amux-*` (27) | `@roost-*` | per-server, no collision |
| 6 | Env vars | `AMUX_*` (21) | `ROOST_*` | internal only |
| 7 | OpenCode adapter | `adapters/opencode/amux.js` | `adapters/opencode/roost.js` | both symlinked, side by side |
| 8 | **Git remote** | `beatzball/amux` (private) | **new** `beatzball/roost` | a real substitution — **no redirect** |

Plus: `~/.config/amux/amux.conf` → `~/.config/roost/roost.conf`,
`skills/amux/SKILL.md` → `skills/roost/SKILL.md`, and 21 internal shell
functions prefixed `amux_` → `roost_`.

### Not renamed

`@agent_state` and `@agent_since` — the two pane options the hook actually
stamps — are **already unbranded**. They contain no product name and must stay
exactly as they are. This is load-bearing: it is why both servers can share one
hook mechanism, and renaming either one breaks running agents mid-turn.

### `@agent_glyph` is a tombstone, not a live option

Do not group `@agent_glyph` with the two above. **Nothing stamps it.** Glyphs
are derived at render time. Its only remaining appearances are cleanup:

- `tmux/amux.conf:42` — `set -gu @agent_glyph` (unset)
- `scripts/amux-migrate-state:27` — `set-option -wu` (unset) on old windows
- `tests/test-agent-state.sh:50` — asserts it *is never stamped*

It predates the OpenCode adapter — introduced by `ae9b749` ("Badge windows by
agent state") — and exists only to scrub stale state off servers started before
the per-pane-state move.

**But it is not a special case.** See "The migrate path is dead weight in
`roost`" below: `@agent_state` and `@agent_since` have window-scoped cleanup for
exactly the same reason, ending at exactly the same change. Singling out
`@agent_glyph` would be incoherent. All three go, or none do.

`@amux-glyph-error` is different: it is genuinely new in PR #8, it is live, and
it renames normally.

## The migrate path is dead weight in `roost`

`scripts/amux-migrate-state` does exactly one thing — unset the three
window-scoped legacy options on every window:

```sh
tmx set-option -wu -t "$win" @agent_state
tmx set-option -wu -t "$win" @agent_glyph
tmx set-option -wu -t "$win" @agent_since
```

Every global- and window-scoped appearance of these three options in the tree is
an **unset** (`-gu` / `-wu`). The only real writes are pane-scoped (`-p`), in the
hook. `tmux/amux.conf:96` and `:100` are reads inside format strings.

So the question is singular, and Decision 1 already answers it:

> Can a `roost` server inherit a live pre-per-pane `amux` server?

**No.** `roost` runs on its own socket (`-L roost`). A running old `amux` server
is a different server; `roost` never sees it and cannot reload it into itself.
No `roost` server can carry window-scoped state that no `roost` version ever
wrote.

**Therefore the `roost` half drops the entire migrate path.** The frozen `amux`
half keeps it untouched, so real legacy servers are still cleaned.

### Removal surface in the `roost` half

| File | What goes |
|---|---|
| `scripts/roost-migrate-state` | not created at all |
| `tmux/roost.conf` | `set -gu @agent_glyph` only (conf:42) — **not** conf:41, see below |
| `tmux/roost.conf` | the `if-shell` that runs the migration on every source (conf:58) |
| `tests/test-migrate-state.sh` | no `roost` counterpart |
| `tests/test-reload.sh` | the migration assertions (lines 13–15, 22–68) |
| `scripts/roost-doctor`, `scripts/lib/roost-config.sh` | comment references only |
| `README.md` | the "Upgrading a running server" paragraph |

There is no `bin/amux migrate-state` subcommand, so the CLI surface is unaffected.

### The two `set -gu` lines are NOT the same kind of line

`tmux/roost.conf` keeps `set -gu @agent_state` and drops `set -gu @agent_glyph`.
Dropping both "for consistency" is wrong, and the reasoning matters more than
the outcome:

| | `set -gu @agent_state` (conf:41) | `set -gu @agent_glyph` (conf:42) |
|---|---|---|
| Clears | a global from **any** source, including future ones | a value only a known past version wrote |
| Kind | live self-heal mechanism | tombstone |
| In `roost` | **keep** | drop, with the tombstone |

The load-bearing text is the conf comment at lines 36–38:

> Deleting these lines is not enough on a server that is already running —
> re-sourcing only adds and overwrites — so unset them explicitly.

That line is not documentation of a past schema. It is **the only mechanism
that removes a stray global from a live server.** Delete it and there is no way
back short of killing the server.

The failure mode survives the rename intact. `roost state` is a *documented
public command* (`bin/roost` usage, `README.md`, `skills/roost/SKILL.md`), so
third parties are actively invited to report state — the OpenCode adapter does
exactly this. A user or third-party integrator writing their own adapter can
plausibly reach for:

```sh
tmux set-option -g @agent_state working
```

Option lookup falls back pane → window → global, so from that moment **every
unstamped pane in every window badges as an agent** and the decidable predicate
collapses — silently, and looking plausible, which is this project's worst
failure shape. With conf:41 present, the next `prefix r` self-heals it.

The cost is asymmetric: keeping is one line with zero runtime cost; dropping
reintroduces an unrecoverable-without-restart failure in exchange for tidiness.

### Do not add a third unset for `@agent_since`

There is no `set -gu @agent_since` today and there must not be one. Every read
of `@agent_since` is nested inside an `@agent_state` guard — see the pane-border
format at conf:164 and its own comment at conf:157:

> Both the glyph and the trailing clause are guarded on `@agent_state`, and the
> timestamp additionally on `@agent_since`.

A stray global `@agent_since` alone therefore cannot badge anything. The
asymmetry is deliberate. **If a future change adds a third unset for symmetry,
that is the tell that this reasoning has drifted.**

### The `@amux_home` / `@amux-home` inconsistency

Both an underscore and a hyphen form exist today. **Do not normalise them during
the rename.** Keeping the rename purely mechanical is what makes it reviewable.
Normalising is a separate follow-up.

## Non-goals

- No behaviour changes. Not one.
- No normalising of the underscore/hyphen option inconsistency.
- No new features. The OpenCode harness work is a separate branch (below).
- No migration of a *running* `amux` server to `roost`. Old sessions drain and
  die on the old server.

## Design

### Coexistence, not aliasing

`bin/amux` must **not** become a symlink to `bin/roost`. If it did, typing
`amux` would start a `-L roost` server and orphan the running one.

Instead, during the transition the repo carries **both trees**: the existing
`amux` files stay byte-for-byte frozen, and the `roost` files are added
alongside. The old half receives no fixes — it only has to keep the running
session alive. Removing it at the end is a single `git rm`.

This duplicates ~1,400 lines for a few days. That is the price of not touching a
server with live agents on it, and it is worth paying.

### The hook problem, and why it is already solved

`~/.claude/settings.json` contains an absolute path:

```
/absolute/path/to/amux/scripts/amux-agent-state working
```

Every running agent calls this on **every tool call**. Renaming that file on
`main` breaks every live agent within seconds — no keypress involved. This, not
`prefix r`, is the real hazard.

The existing script already guards on the socket path:

```sh
sock="${TMUX%%,*}"
case "$sock" in
  */amux) ;;
  *) exit 0 ;;
esac
```

A `roost` server's socket ends in `/roost`, so `amux-agent-state` exits 0 there.
`roost-agent-state` will carry the mirrored guard (`*/roost`) and exit 0 on the
amux socket.

**Therefore both hooks can be registered in `settings.json` simultaneously and
will cleanly ignore each other.** No dispatcher and no flag day. Add the `roost`
hooks; remove the `amux` hooks from *this* machine's `settings.json` when the
old session closes.

That covers the config we can see. It does **not** cover configs we cannot — a
second machine, another checkout, or a third party who copied the hook snippet
from the README. Those are why `scripts/amux-agent-state` still becomes a
symlink at Phase 4 rather than disappearing with the rest of the `amux` half.
See "Compatibility shims".

### Config migration

`roost init` writes `~/.config/roost/roost.conf`. If that file is absent but
`~/.config/amux/amux.conf` exists, read the old one, translate `@amux-*` keys to
`@roost-*`, and write the new one. Never delete the old file — the running amux
server is still reading it.

### Grep gate allowlist

`grep -ri amux bin scripts tmux tests skills` must eventually return nothing.
**During** the transition it legitimately returns the frozen `amux` half. The
gate therefore runs in three modes:

| Mode | From | Allows |
|---|---|---|
| off | Phase 1 | the whole frozen `amux` half |
| shim-only | Phase 4 | `scripts/amux-agent-state`, `bin/amux`, `adapters/opencode/amux.js` — the three shims, and nothing else |
| strict | Phase 5 | nothing |

Strict mode cannot turn on at Phase 4, because the shims contain the old name
by design. Conflating "the old half is gone" with "the old name is gone" is
what the middle mode exists to prevent.

## Sequencing — resolved

This spec was originally gated on the OpenCode adapter merging first, because a
rename deletes and recreates every file that branch was modifying, and git
resolves that as delete-versus-modify.

**That gate is now cleared.** The adapter merged as PR #8 (`7bd1ed4`), and this
branch is rebased onto it. There is no longer a competing branch, so the rename
and the `docs/superpowers/` → `docs/airig/` move can both proceed.

What the merge added to this rename's scope:

- A seventh namespace — the OpenCode adapter (row 7 above).
- One new live option: `@amux-glyph-error`.
- Two env vars: `AMUX_AGENT_NAME`, `AMUX_LIVE_MODEL`.
- Six new test files, plus `tests/live/opencode-smoke.sh`.

### The OpenCode adapter — a second integration point, but not a live one

The adapter is designed to be reached by a user-made symlink outside this repo:

```
~/.config/opencode/plugin/amux.js  ->  <checkout>/adapters/opencode/amux.js
```

**This symlink now exists on this machine.** An earlier revision of this spec
recorded it as absent, and that was true when written — it was installed later
the same day, on `amux doctor`'s recommendation, while this spec was being
reviewed. The spec's own instruction to "verify the install status at execution
time rather than trusting this paragraph" was vindicated within hours.

So there are **two** live integration points, not one:

| path | referenced from | breaks how |
|---|---|---|
| `scripts/amux-agent-state` | `~/.claude/settings.json`, absolute, ×4 | every agent, next tool call |
| `adapters/opencode/amux.js` | `~/.config/opencode/plugin/amux.js` symlink | OpenCode agents stop badging, silently |

Both are outside the repo and neither can be updated by a rename. Both
therefore need a shim, and `adapters/opencode/amux.js` becomes the **third
shim** — a symlink to `roost.js`, kept through Phase 4 and deleted at Phase 5
with the other two.

This is exactly the dangling-symlink failure the `doctor` branch below was
written to catch, which is why that branch is kept rather than tidied away.

The adapter still needs the coexistence design for anyone who *has* installed
it: `roost.js` ships alongside `amux.js` under a different filename, each
invokes its own command by name (`execFile("roost", ...)` vs
`execFile("amux", ...)`), and each command's socket guard no-ops it on the
wrong server. `roost doctor` must check the new path. Verify the install status
again at execution time rather than trusting this paragraph — it records one
machine on one day.

## Compatibility shims

These are **two separate decisions**, not one. The original "should `bin/amux`
linger as a stub?" question was scoped to the less important file.

### `scripts/amux-agent-state` — a symlink, and it is not optional

`~/.claude/settings.json` references this script by **absolute path, four
times** — one per hook, verified on this machine:

| hook | argument |
|---|---|
| `UserPromptSubmit` | `working` |
| `Notification` | `blocked` |
| `PostToolUse` | `working` |
| `Stop` | `done` |

That file lives outside the repo. **No rename can update it.** Rename or delete
the script and every running agent fails on its next tool call.

So `scripts/amux-agent-state` stays at its old path. This is the difference
between a rename and an outage; a `bin/` stub does nothing for it.

**It must be a symlink, not a bash forwarder** — and that requires a fix to the
target script first.

#### Why not a forwarder

```sh
exec "$(dirname "$0")/roost-agent-state" "$@"   # rejected
```

A bash forwarder costs an **extra process spawn per hook invocation**,
interpreter startup included — measured at **~0.57 of a full tmux round trip**,
the very cost the script is written to avoid. A symlink costs nothing: the
kernel resolves it and no second process starts.

#### Prerequisite: the target must resolve symlinks, or notifications die silently

A symlink does not work as the code stands, and it fails **silently** —
`scripts/amux-agent-state:123`:

```sh
AMUX_NOTIFY_SOCK="$sock" "$(dirname "$0")/amux-notify" "amux · ${wname}" "$msg" || true
```

Reached through a symlink at the old path, `$0` is the *old* path, so `dirname`
yields the old sibling name. After the rename that file is gone, the call
misses, and the trailing `|| true` swallows the failure. **Desktop
notifications simply stop, with nothing in any log.**

`bin/amux:31-38` already carries the loop that fixes this, with the comment
"Resolve the repo root even when invoked via a symlink on `PATH`". The hook
script never needed one because nobody had symlinked it yet — the rename is
what creates that condition.

**Order of work: copy the `readlink` loop into `roost-agent-state` first, then
symlink.** That also makes the script correct under *any* symlink, which is the
general condition a rename introduces.

#### Audit: this pattern is repo-wide

Four scripts make sibling calls via `dirname "$0"` and **none** resolve
symlinks. Only `bin/amux` does.

| file | sibling calls | symlink-safe |
|---|---|---|
| `scripts/amux-agent-state` | 1 | no |
| `scripts/amux-doctor` | 4 | no |
| `scripts/amux-init` | 1 | no |
| `scripts/amux-settings` | 1 | no |

Only `amux-agent-state` is symlinked by this plan, so only it *must* be fixed.
The others are recorded because the same silent failure appears the moment any
other old path is ever symlinked.

**`amux-doctor` deserves the most attention of the three left alone.** It has
four call sites — the most — and `doctor` is what a user runs when something is
*already* broken. A silent sibling miss there fails at the worst possible
moment: the diagnostic tool quietly under-reports while the user is trying to
work out what is wrong. If any of the three gets the `readlink` loop
pre-emptively, make it that one.

### Record ratios, not milliseconds

The cost table above is deliberately unitless. An earlier draft of this spec
nearly recorded "≈7.6 ms per tmux round trip" as an established fact. That
figure came from a PR body written on a different machine under different load
and **did not reproduce**. Promoting a number that was true once, in a
document, into a standing fact is the same error this spec has had to correct
repeatedly.

Two independent runs on this machine — Darwin arm64, tmux 3.6, N=200, isolated
`-S` socket — landed at:

| | run A | run B |
|---|---|---|
| spawn ÷ round trip | 0.55 | 0.57 |
| round trip ÷ stderr | 32× | 31× |
| spawn ÷ stderr | 18× | 18× |

**The ratios agree. The absolute milliseconds differed by ~12% between the two
runs**, minutes apart on the same hardware. Ratios survive a machine change;
a naked millisecond figure rots and then gets quoted back with confidence.

If a future change needs these numbers, re-measure with a timing loop and
record the ratio and the method — hardware, tmux version, sample count — never
a bare figure.

#### Why the shim is silent — and why it is NOT a performance argument

The shim prints nothing. The reason matters, because the wrong reason misleads
whoever reads this next.

**Not** because stderr is expensive. The budget this file protects is **tmux
round trips** — fork plus socket — which is why the early bail is pinned at
exactly one call. `scripts/amux-status:32` names the same cost independently
("a fork+roundtrip every 2 seconds on a live bar").

Measured costs, as ratios (see "Record ratios, not milliseconds" below):

| operation | cost |
|---|---|
| tmux round trip | the unit — fork plus socket |
| bash process spawn | **~0.57** of a round trip |
| stderr write | **~1/31** of a round trip (≈1.5 orders of magnitude, not 3–4) |

Recording "hot path means no I/O of any kind" would be actively harmful: the
next person refuses a cheap write that is fine, and waves through an expensive
tmux call that is not.

The numbers also show the original trade was backwards. The stderr line that
was cut costs ~1/31 of a round trip; the forwarder spawn that was accepted
costs ~0.57 — **the rejected thing was ~18× cheaper than the accepted one.**
Replacing the forwarder with a symlink is the real win here. The silence is
correct too, but for the transcript-noise reason below, not for cost.

**The real reason:** Claude Code hook stderr can surface into the agent
transcript and the UI. `PostToolUse` fires on every tool call, so a deprecation
line is hundreds of lines of **context noise injected into the very agent being
badged**. That is a correctness and signal-to-noise argument, and it holds even
if the write were free.

The self-closing signal therefore lives in `doctor`, which runs once and on
demand.

### `bin/amux` — a stub, but convenience only

`amux` resolves here to a **regular file inside the repo's own `bin/`**
(install option A — that directory is on `PATH`, it is not a symlink into
`/usr/local/bin`). So after the rename, `PATH` already points at the right
directory and `roost` resolves immediately with no stub at all.

A stub therefore buys only muscle memory, shell history, aliases, and any agent
still holding an old `SKILL.md`. Real, but bounded. Ship it as a courtesy; it
may print its deprecation freely, since it is interactive and not on a hot path.

### All three shims are self-closing

A silently forwarding shim is **worse than none** — the migration never
completes, both names are carried indefinitely, and nothing signals who is
still on the old path.

`roost doctor` gains a check that greps `~/.claude/settings.json` for the old
`amux-agent-state` path and warns, naming the exact fix. That check is what
makes the deletion decidable instead of a guess.

#### Phase 5 trigger: the author's own configs, not "users"

An earlier draft said "delete once `doctor` stops firing **for real users**".
That is unfalsifiable — the project has effectively no users yet, so the
condition can never be observed and the shims would live forever by default.
Replacing an unobservable criterion with an observable one is the point of this
paragraph.

**The trigger is: `roost doctor` reports clean on every machine the author
uses.** Concretely — no machine's `~/.claude/settings.json` still references
`amux-agent-state`, and no `~/.config/opencode/plugin/amux.js` remains. That is
fully observable by one person in a few minutes, and it is the honest version
of what the original criterion was reaching for.

Third parties are covered by the shims continuing to exist right up until that
moment, plus the deprecation notice on `bin/amux`. If the project later gains
users whose configs cannot be inspected, this criterion is revisited — but it
is not written against a hypothetical population today.

### Keep the dangling-symlink check — it is not OpenCode-specific

PR #8 added a `doctor` branch for a symlink that is present but whose target is
gone (`[ -L "$p" ] && [ ! -e "$p" ]`), because renaming a file that users have
symlinked into another program's config directory breaks **silently at the far
end**.

That is precisely the failure a rename causes, and the pattern generalises past
OpenCode. The `roost` half keeps it, and the same shape covers the
`settings.json` check above. Do not treat it as adapter-specific detail to be
tidied away.

## Rollout phases

| Phase | Work | Exit criteria |
|---|---|---|
| 0 | ~~OpenCode branch merges to `main`~~ | **Done** — PR #8, `7bd1ed4` |
| 1 | Add the `roost` half alongside the frozen `amux` half, in a worktree | `tests/run.sh` green; both halves present |
| 2 | Move `docs/superpowers/` → `docs/airig/`; rename `skills/amux/` → `skills/roost/` | Links resolve |
| 3 | Add `roost` hooks to `settings.json` alongside the `amux` ones; start a `-L roost` server; run new work there | New agents badge correctly on `roost`; old agents still badge on `amux` |
| 4 | Old `amux` session drains and is killed. Delete the `amux` half, **keeping the three shims**. Rename the GitHub repo | Shim-only grep gate passes; human-eye batch passes |
| 5 | Later release. Delete all three shims; drop the `doctor` migration checks | `roost doctor` reports clean on **every machine the author uses** — see below; strict grep gate passes |

Phase 3 is the one that can run for days. Phases 1–2 are a single sitting.

## Risks

| Risk | Mitigation |
|---|---|
| Rename touches `main` while agents are live | All work in `.claude/worktrees/rename-to-roost`. `main` untouched until Phase 4. |
| A missed `amux` string in the roost half | Grep gate in strict mode at Phase 4 |
| `roost init` corrupts a live config | It only ever writes to `~/.config/roost/`; the old file is read-only to it |
| ~~Conflict with OpenCode~~ | Cleared — merged as PR #8 |
| `npx skills add beatzball/amux` hard-fails | **No mitigation available.** There is no redirect and the repo is already private, so anyone with that command in their own notes gets a 404 *today*. Updating the README is required, not "anyway" — and it only helps people who re-read it |
| PR history `#1`–`#8` lost at cutover | Archive bodies into the tree before pushing to the new repo — `gh pr list --state all --json number,title,body` |
| Worktree `origin` still points at the old repo after cutover | Repoint explicitly; no redirect will cover it. Preserve the SSH host alias `git@github.com-beatzball:` |
| Dangling `~/.config/opencode/plugin/amux.js` symlink | Not present on this machine — re-check at execution time. If installed: `roost.js` goes alongside, not over the top |
| Both OpenCode plugins fire, doubling process spawns per turn | Accepted. Transition-only, one extra `execFile` per state change |
| Dead `@agent_glyph` cleanup carried into `roost` by reflex | Named as an explicit decision, not a default — see Open Questions |
| A personal absolute home path leaks into a committed doc | History was rewritten once already to strip these. Grep for the home-directory prefix and the username before every commit |

## Open questions

None blocking. All three are resolved.

1. ~~Does `bin/roost` keep a `migrate-state` equivalent?~~ **Resolved: no.**
2. ~~Does the `roost` half drop the `@agent_glyph` cleanup?~~ **Resolved: yes —
   but the `@agent_state` unset stays.** See "The two `set -gu` lines are NOT
   the same kind of line".
3. ~~Should Phase 4 leave a `bin/amux` stub?~~ **Resolved, and it was scoped to
   the wrong file.** See "Compatibility shims" below.
