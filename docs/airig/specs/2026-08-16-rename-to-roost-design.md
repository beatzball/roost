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
4. The GitHub repo is renamed `beatzball/amux` → `beatzball/roost` (GitHub
   redirects the old URL, so this is low-risk and can happen at any point).

## Scope — six namespaces

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
forwarder at Phase 4 rather than disappearing with the rest of the `amux` half.
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
| shim-only | Phase 4 | `scripts/amux-agent-state` and `bin/amux` — the two shims, and nothing else |
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

**On this machine that symlink does not exist** — `~/.config/opencode/plugin/`
is absent, though `opencode` itself is installed. So renaming
`adapters/opencode/amux.js` breaks nothing today. Treat this as a packaging
concern, not a live hazard.

The one live hazard remains `scripts/amux-agent-state`, wired into
`~/.claude/settings.json` by absolute path and called by every running agent on
every tool call.

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

### `scripts/amux-agent-state` — a forwarder, and it is not optional

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

So `scripts/amux-agent-state` stays at its old path as a forwarder:

```sh
exec "$(dirname "$0")/roost-agent-state" "$@"
```

This is the difference between a rename and an outage. A `bin/` stub does
nothing for it.

**The forwarder must be silent.** `PostToolUse` fires on every tool call and
Claude blocks on the script exiting; the existing comment requires the hot path
be "ONE read, then bail". A per-invocation deprecation line on stderr would run
hundreds of times a session against a budget the file is explicitly written to
protect. The self-closing signal belongs in `doctor`, which runs once and on
demand — see below.

### `bin/amux` — a stub, but convenience only

`amux` resolves here to a **regular file inside the repo's own `bin/`**
(install option A — that directory is on `PATH`, it is not a symlink into
`/usr/local/bin`). So after the rename, `PATH` already points at the right
directory and `roost` resolves immediately with no stub at all.

A stub therefore buys only muscle memory, shell history, aliases, and any agent
still holding an old `SKILL.md`. Real, but bounded. Ship it as a courtesy; it
may print its deprecation freely, since it is interactive and not on a hot path.

### Both shims are self-closing

A silently forwarding shim is **worse than none** — the migration never
completes, both names are carried indefinitely, and nothing signals who is
still on the old path.

`roost doctor` gains a check that greps `~/.claude/settings.json` for the old
`amux-agent-state` path and warns, naming the exact fix. Both shims are deleted
in a later release once `doctor` stops firing. That check is what makes the
deletion decidable instead of a guess.

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
| 4 | Old `amux` session drains and is killed. Delete the `amux` half, **keeping the two shims**. Rename the GitHub repo | Shim-only grep gate passes; human-eye batch passes |
| 5 | Later release. Delete both shims; drop the `doctor` migration check | `doctor` has stopped firing for real users; strict grep gate passes |

Phase 3 is the one that can run for days. Phases 1–2 are a single sitting.

## Risks

| Risk | Mitigation |
|---|---|
| Rename touches `main` while agents are live | All work in `.claude/worktrees/rename-to-roost`. `main` untouched until Phase 4. |
| A missed `amux` string in the roost half | Grep gate in strict mode at Phase 4 |
| `roost init` corrupts a live config | It only ever writes to `~/.config/roost/`; the old file is read-only to it |
| ~~Conflict with OpenCode~~ | Cleared — merged as PR #8 |
| GitHub rename breaks `npx skills add beatzball/amux` | GitHub redirects; update the README line in Phase 2 anyway |
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
