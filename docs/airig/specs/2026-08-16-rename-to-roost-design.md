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

`@agent_state`, `@agent_since`, and `@agent_glyph` — the three pane options the
hook actually stamps — are **already unbranded**. They contain no product name
and must stay exactly as they are. This is load-bearing: it is why both servers
can share one hook mechanism.

(`@agent_glyph` and `@amux-glyph-error` both arrived with the OpenCode adapter
and its error state. The `@amux-` one renames; the `@agent_` one does not.)

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
will cleanly ignore each other.** No dispatcher, no shim, no flag day. Add the
`roost` hooks; remove the `amux` hooks when the old session closes.

### Config migration

`roost init` writes `~/.config/roost/roost.conf`. If that file is absent but
`~/.config/amux/amux.conf` exists, read the old one, translate `@amux-*` keys to
`@roost-*`, and write the new one. Never delete the old file — the running amux
server is still reading it.

### Grep gate allowlist

After the transition completes, `grep -ri amux bin scripts tmux tests skills`
must return nothing. **During** the transition it legitimately returns the
frozen `amux` half. The gate therefore runs in two modes, and the strict mode
turns on at Phase 4.

## Sequencing — resolved

This spec was originally gated on the OpenCode adapter merging first, because a
rename deletes and recreates every file that branch was modifying, and git
resolves that as delete-versus-modify.

**That gate is now cleared.** The adapter merged as PR #8 (`7bd1ed4`), and this
branch is rebased onto it. There is no longer a competing branch, so the rename
and the `docs/superpowers/` → `docs/airig/` move can both proceed.

What the merge added to this rename's scope:

- A seventh namespace — the OpenCode adapter (row 7 above).
- Two options: `@amux-glyph-error` (renames) and `@agent_glyph` (does not).
- Two env vars: `AMUX_AGENT_NAME`, `AMUX_LIVE_MODEL`.
- Six new test files, plus `tests/live/opencode-smoke.sh`.

### The OpenCode adapter is a second external integration point

Like the Claude hook, it lives outside this repo — a user-made symlink:

```
~/.config/opencode/plugin/amux.js  ->  <checkout>/adapters/opencode/amux.js
```

Rename the target and the symlink dangles. The plugin also invokes the command
**by name** (`execFile("amux", ...)`), so it depends on `amux` being on `PATH`.

The fix is the same shape as the Claude hook. `roost.js` is installed alongside
`amux.js` under a different filename; each delegates to its own command, and
each command's socket guard makes it a no-op on the wrong server. Both are
removed from the plugin directory at Phase 4.

## Rollout phases

| Phase | Work | Exit criteria |
|---|---|---|
| 0 | ~~OpenCode branch merges to `main`~~ | **Done** — PR #8, `7bd1ed4` |
| 1 | Add the `roost` half alongside the frozen `amux` half, in a worktree | `tests/run.sh` green; both halves present |
| 2 | Move `docs/superpowers/` → `docs/airig/`; rename `skills/amux/` → `skills/roost/` | Links resolve |
| 3 | Add `roost` hooks to `settings.json` alongside the `amux` ones; start a `-L roost` server; run new work there | New agents badge correctly on `roost`; old agents still badge on `amux` |
| 4 | Old `amux` session drains and is killed. Delete the `amux` half, remove the `amux` hooks, rename the GitHub repo | Strict grep gate passes; human-eye batch passes |

Phase 3 is the one that can run for days. Phases 1–2 are a single sitting.

## Risks

| Risk | Mitigation |
|---|---|
| Rename touches `main` while agents are live | All work in `.claude/worktrees/rename-to-roost`. `main` untouched until Phase 4. |
| A missed `amux` string in the roost half | Grep gate in strict mode at Phase 4 |
| `roost init` corrupts a live config | It only ever writes to `~/.config/roost/`; the old file is read-only to it |
| ~~Conflict with OpenCode~~ | Cleared — merged as PR #8 |
| GitHub rename breaks `npx skills add beatzball/amux` | GitHub redirects; update the README line in Phase 2 anyway |
| Dangling `~/.config/opencode/plugin/amux.js` symlink | `roost.js` installed alongside, not over the top; `roost doctor` checks both during transition |
| Both OpenCode plugins fire, doubling process spawns per turn | Accepted. Transition-only, one extra `execFile` per state change |
| A personal absolute home path leaks into a committed doc | History was rewritten once already to strip these. Grep for the home-directory prefix and the username before every commit |

## Open questions

None blocking. Two to settle during planning:

1. Does `bin/roost` keep a `roost migrate-state` equivalent, or is that dropped
   as amux-only history?
2. Should Phase 4 leave a stub `bin/amux` that prints "renamed to roost" for a
   release or two, rather than deleting outright?
