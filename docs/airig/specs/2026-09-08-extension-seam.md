# Spec — the roost extension seam

One small, versioned place where a third-party command can plug into roost, so
that new features live in their own repositories instead of growing `bin/roost`.

Agreed in chat on 2026-09-08. Decisions marked **[chosen]** were picked by the
user from options presented at design time.

## Problem

Every feature added to roost so far has landed in the core: a branch in
`bin/roost`, a line of help text, a `roost doctor` check, a `tests/` file the
suite runs forever, a page on the site. That tax is correct for `send`, `spawn`
and `status`, which are what roost *is*.

It is the wrong price for a feature nobody has proved yet.

The concrete case that started this: **bookmarks**. Mark a spot in any agent's
pane, attach a note, come back to it later. It might be excellent. It might be
noise. There is currently no way to find out that does not permanently enlarge
roost.

## Goal

A contract narrow enough to describe on one page, that lets

```sh
roost mark %200
```

run code that lives in a different repository, installed by the user, pinned to
a commit, and removable in one command that leaves no trace in the roost
checkout.

## Non-goals

- **Not a package manager.** No dependency resolution, no transitive installs,
  no build step. An extension is a directory with an executable in it.
- **Not a sandbox.** An extension runs with the user's full privileges, exactly
  like any other program they install. The guard is *pinning and consent*, not
  confinement. This is stated plainly in the docs; see "Trust".
- **No events in contract 1.** See "Contract 1 — commands only".
- **No registry, no curation.** Any GitHub repository, by `<org>/<repo>`.
- **Not a way to override core.** A core subcommand can never be shadowed.

## Two builds, two repositories

| # | What | Where | This spec |
|---|---|---|---|
| 1 | The extension seam + semver | `beatzball/roost` | **covers in full** |
| 2 | `roost mark` — the first extension | `beatzball/roost-mark` (new) | names the contract it must meet; gets its own spec |

Build 1 must land first: build 2 cannot be tested without it. Splitting the
repositories is the point of the exercise — after build 1, roost core contains
**zero lines** of bookmark code, forever.

Creating the `roost-mark` repository is a human action. Per `AGENTS.md` §4 no
subagent creates, renames or publishes a repository.

## Versioning

Two version numbers, deliberately separate. **[chosen]** — the user asked for
full semver *and* an API schema version, on the grounds that the dispatching
shape will change independently of the product.

### `ROOST_VERSION` — the product

Semver, in a `VERSION` file at the repository root, read by `bin/roost` and
reported by `roost --version`. Starts at `0.1.0`. Tagged `v0.1.0`. A
`CHANGELOG.md` is added in the same change, in Keep a Changelog shape.

This is new. There are **no git tags in this repository today**, so the release
process is part of build 1, not an assumption it can lean on.

### `ROOST_CONTRACT` — the seam

A single integer, currently `1`, hard-coded in `bin/roost`. It moves only when
the shape of extension wiring changes — not when roost gains a feature. Roost
may ship `0.9.0` still speaking contract `1`.

The split exists so that a contract bump is a deliberate, rare, breaking event
that can be reasoned about on its own, and so that ordinary roost releases
never invalidate an installed extension.

## Contract 1 — commands only

**[chosen]** over a variant that also delivered agent-state events. Roost's
state hook already fires on every tool call of every agent, so events are
reachable; they were deferred because contract 1 would have shipped an event
API with zero consumers and frozen its shape on the day it landed. The version
gate is precisely what makes adding them later safe: contract-1 extensions keep
working when contract 2 appears.

### Extension layout

```
roost-mark/
├── roost-ext.json          required, at the repository root
├── bin/
│   ├── roost-mark          executable, one per declared command
│   └── roost-marks
└── README.md
```

### `roost-ext.json`

```json
{
  "name": "mark",
  "contract": 1,
  "roost": ">=0.1.0 <0.2.0",
  "commands": ["mark", "marks"],
  "description": "Bookmark a spot in an agent pane, with a note."
}
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Install directory name. `[a-z][a-z0-9-]*`, max 32 chars. |
| `contract` | yes | Seam version this extension speaks. **Hard gate** — a mismatch refuses the install with the reason. |
| `roost` | no | Advisory semver range. A mismatch **warns and continues**; it never refuses. |
| `commands` | yes | Subcommands claimed. Each needs `bin/roost-<cmd>`, executable. |
| `description` | no | One line, shown by `roost ext list`. |

Parsed with the existing `scripts/lib/roost-json.sh`. No new dependency.

`roost` is advisory on purpose. A hard product-version gate would make every
roost release a compatibility event, which is the cost the contract integer
exists to avoid. Range support is deliberately tiny — `>=A.B.C <D.E.F`, `*`, or
absent. Anything else warns "unparsable range, skipping check" and continues,
so a fancy range can never harden into a refusal.

### Dispatch

In `bin/roost`, in the `*)` fallback of the existing subcommand `case` — the
branch that today prints usage and exits non-zero:

1. If `ROOST_NO_EXT` is set, or `@roost-ext-enabled` is `off`, fall through to
   today's usage error. Extensions are then completely inert.
2. Look up `$1` in the installed-command index.
3. Not found → today's usage error, unchanged.
4. Found → `exec` the extension binary with the remaining arguments.

**Core always wins.** The lookup happens only in the fallback branch, so an
extension can never shadow `send`, `spawn`, `status`, `read`, or any other
existing subcommand. A manifest claiming a core name is refused at *install*
time, with the collision named. This is a safety property, not a nicety: an
extension that could shadow `roost send` could silently intercept every message
between the user's agents.

Two extensions claiming the same command is refused at install time too, naming
the one that already holds it.

### Environment handed to an extension

```sh
ROOST_HOME        # the roost checkout
ROOST_SOCKET      # which tmux server, so the ext talks to the right fleet
ROOST_VERSION     # product version, so an ext can adapt
ROOST_CONTRACT    # seam version
ROOST_EXT_DIR     # this extension's own install directory (read-only by convention)
ROOST_EXT_STATE   # this extension's private state directory; created before exec
PATH              # with $ROOST_HOME/scripts prepended, as panes already get
```

`ROOST_EXT_STATE` is the answer to "where do I put my data". An extension that
writes anywhere else is not covered by `roost ext remove --purge`, and its
README must say so.

Exit status passes through unchanged. Extensions get no stdout/stderr wrapping.

## Where things live on disk

Nothing installs into the roost checkout. This is what makes the feature
rippable and what keeps `git status` clean in a repository people develop in.

```
${XDG_DATA_HOME:-$HOME/.local/share}/roost/ext/<name>/    the clone
${XDG_STATE_HOME:-$HOME/.local/state}/roost/ext/<name>/   the extension's data
${XDG_STATE_HOME:-$HOME/.local/state}/roost/ext.lock      what is installed, pinned
```

`ext.lock` is JSON, one entry per extension:

```json
{
  "mark": {
    "repo": "beatzball/roost-mark",
    "ref": "v0.1.0",
    "commit": "a3f91c2e5b7d4419c2f0aa18e6cd3b7f92104a6d",
    "contract": 1,
    "commands": ["mark", "marks"],
    "installed": "2026-09-08T10:14:22Z"
  }
}
```

Alongside it, a **plain-text command index**:

```
${XDG_STATE_HOME:-$HOME/.local/state}/roost/ext.index
```

one line per claimed command, written at install and removal time:

```
mark    mark    /absolute/path/to/ext/mark/bin/roost-mark
marks   mark    /absolute/path/to/ext/mark/bin/roost-marks
```

This is not duplication for its own sake. The dispatcher runs on **every
unrecognised `roost` subcommand**, including every typo, and `roost-json.sh`
opens by recording that neither `python3` nor `jq` is a runtime dependency of
roost. Parsing `ext.lock` to dispatch would quietly make one of them exactly
that. A `while read` over a small text file needs neither, and is faster than
starting an interpreter.

`ext.lock` stays the human- and tool-readable record; `ext.index` is the
dispatch path. Both are written in the same step, and `roost ext list` warns if
they disagree.

The lockfile, not the clone, is the source of truth for what is installed. A
half-deleted clone therefore degrades to "command not found", not to executing
something unexpected.

## Commands

### `roost ext install <org>/<repo> [--ref <tag|branch|sha>]`

**[chosen]**: pin and confirm, any repository, no curated registry. A vetted
list is a point-in-time claim that a repository can invalidate the next day;
pinning to a commit is what actually holds.

1. Resolve `--ref` (default: the repository's default branch) to a **full
   commit SHA** with `git ls-remote`.
2. Shallow-clone that SHA into a temporary directory.
3. Read and validate `roost-ext.json`. Refuse on: missing manifest, bad `name`,
   contract mismatch, a claimed command that collides with core or with an
   installed extension, a declared command with no executable at
   `bin/roost-<cmd>`.
4. Print the plan and **wait for `y/N`**:

```
  repo     github.com/beatzball/roost-mark
  ref      v0.1.0
  commit   a3f91c2...  (pinned)
  contract 1                       (roost speaks 1)     ok
  roost    >=0.1.0 <0.2.0          (you have 0.1.0)     ok
  claims   roost mark, roost marks

  This runs code from the internet as you, when you type those commands.
  Nothing runs during install.

  Install? [y/N]
```

5. Move the clone into place, create `ROOST_EXT_STATE`, write `ext.lock`.

Not a tty → refuse, unless `--yes` is passed. Silence is never consent.
**No post-install script is ever run.** Extension code executes only when the
user types one of its commands. This is why step 4 can honestly say "nothing
runs during install", and it must stay true.

### `roost ext list`

Name, version pin, commands claimed, and whether the clone is present.

### `roost ext info <name>`

The manifest, the lockfile entry, and the two directory paths.

### `roost ext update [<name>]`

Re-resolves the recorded `ref` to a SHA. If unchanged, says so and stops.
Otherwise shows the old and new commit, re-validates the manifest, and asks
`y/N` again. **Install never auto-updates.** A pin that silently moves is not a
pin.

### `roost ext remove <name> [--purge]`

Removes the clone and the lockfile entry. State under `ROOST_EXT_STATE` is
**kept** unless `--purge` is given, and the retained path is printed, so an
accidental removal does not destroy a year of bookmarks.

## Ripping it out

Three levels, cheapest first — this is the requirement that shaped the design.

1. **Turn it off**: `ROOST_NO_EXT=1`, or `set -g @roost-ext-enabled off` in
   `roost.conf`. The dispatcher becomes inert; no extension can run.
2. **Remove one extension**: `roost ext remove mark --purge`. Nothing of it
   remains, and the roost checkout never held any of it.
3. **Remove the seam**: revert the single pull request from build 1. It touches
   `bin/roost` (the fallback branch, `VERSION`, `CHANGELOG.md`), adds
   `scripts/roost-ext` and `scripts/lib/roost-ext.sh`, adds one test file, and
   adds one docs page. No core behaviour is rewritten, so the revert is clean.

Keeping the revert clean is a constraint on the implementation, not a hope: the
dispatcher is confined to the existing `*)` fallback and must not alter any
existing branch of the `case`.

## Trust

Stated plainly in the docs page, not buried:

> An extension is a program you install and run. Roost pins it to an exact
> commit and asks before installing, so you know what you are getting and it
> cannot change under you. It does not confine what the program can do once you
> run it. Install extensions from people you would take a shell script from.

## Oracle — automated

Everything above is shell behaviour that a test can assert. `tests/lib.sh`
already builds a throwaway tmux server per run.

`tests/test-ext.sh` covers:

- dispatch: an installed command runs; an unknown one gives the usual usage error
- **core is never shadowed**: a manifest claiming `send` is refused at install
- a second extension claiming an already-claimed command is refused
- contract mismatch refuses; an out-of-range `roost` range warns and continues
- an unparsable `roost` range warns and continues, never refuses
- the environment handed to an extension contains every variable listed above
- **dispatch needs no JSON tool**: with `python3` and `jq` both absent from
  `PATH`, an installed command still runs. This guards the standing decision in
  `scripts/lib/roost-json.sh` that neither is a roost runtime dependency
- `ROOST_NO_EXT=1` makes an installed command fall back to the usage error
- `remove` keeps state; `remove --purge` deletes it
- `update` on an unchanged ref reports no change and rewrites nothing
- a non-tty install refuses without `--yes`

### Test isolation — read `AGENTS.md` §8 before writing any of this

Two traps specific to this feature:

- **The real user's extensions must never be touched.** Redirect `HOME`,
  `XDG_DATA_HOME` and `XDG_STATE_HOME`. Copy the canary pattern in
  `tests/test-install.sh`: point the whole set at a directory nothing may write
  to, and fail at the end of the file if anything landed there.
- **No network.** `git ls-remote` and `git clone` must resolve against a local
  bare repository created in the temp directory and addressed as a `file://`
  URL. The `<org>/<repo>` to URL mapping therefore goes through one override
  point — `ROOST_EXT_GIT_BASE`, defaulting to `https://github.com/` — which the
  tests set. A test suite that reaches GitHub is flaky and, worse, would pass
  while the pinning logic was wrong.

Human-eye checks: none for build 1. The `y/N` prompt's wording is worth one
look at the end, batched, not gating any task.

## Risks

| Risk | Severity | Response |
|---|---|---|
| The seam is permanent core surface, added before any extension has proved its worth | medium | It is small and confined to the `*)` fallback; level-3 revert is one PR. Accepted knowingly. |
| Semver, tags and a changelog are a new ongoing obligation | medium | Real. It is the price of the `roost` range field, which the user chose over a bare contract integer. |
| An extension shadowing a core command could intercept fleet traffic | high | Structurally prevented: lookup lives only in the fallback, and install refuses core names. Both are tested. |
| `git ls-remote` against a compromised repository returns an attacker SHA | low | Consent step shows the SHA; pinning means it cannot change later. Not confinement — see "Trust". |
| Extension state grows without bound | low | Owned by the extension; `remove --purge` is the exit. |

Per `AGENTS.md` §11, anything left deferred at the end of build 1 goes into
`docs/known-gaps.md`, not into a chat summary.

## Build 2 — `roost mark`, in outline

Specified separately once the seam lands. Recorded here so the seam is designed
against a real consumer rather than an imagined one:

- `roost mark [<pane>] [--note]` — capture that pane's scrollback now.
  Capture with `capture-pane -p`, **without** `-e`: roost glyphs can be Nerd
  Font private-use codepoints that render as zero width, and escape sequences
  would fill every mark with junk.
- `--note` opens `$EDITOR` in a `display-popup`, over the pane. Capture and
  note are separate moments by design: capture must cost no typing, because the
  moment worth bookmarking is a moment the user is busy reading.
- `roost marks` — list, search, reopen.
- Harness-agnostic by construction: it reads a *pane*, so claude, codex,
  copilot, opencode and pi all work on day one, with no per-harness adapter.
- Later, per-harness adapters may upgrade a mark from pane text to the real
  transcript message. That is polish, not the foundation.
