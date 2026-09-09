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
- **Not a second home for existing commands.** The conformance fixture below
  rebuilds `roost status` as an extension to prove the contract is sufficient.
  It is a test fixture and is never published. A real `roost-status` extension
  would be a duplicate of a core command, maintained forever — the exact bloat
  this design exists to prevent.

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
  "needs": ["fleet"],
  "commands": ["mark", "marks"],
  "description": "Bookmark a spot in an agent pane, with a note."
}
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Install directory name. `[a-z][a-z0-9-]*`, max 32 chars. |
| `contract` | yes | Seam version this extension speaks. **Hard gate** — a mismatch refuses the install with the reason. |
| `roost` | no | Advisory semver range. A mismatch **warns and continues**; it never refuses. |
| `needs` | no | Authority requested. Absent or `[]` means none. The only value in contract 1 is `fleet`. See "Declared authority". |
| `commands` | yes | Subcommands claimed. Each needs `bin/roost-<cmd>`, executable. |
| `description` | no | One line, shown by `roost ext list`. |

Parsed with the existing `scripts/lib/roost-json.sh`. No new dependency.

`roost` is advisory on purpose. A hard product-version gate would make every
roost release a compatibility event, which is the cost the contract integer
exists to avoid. Range support is deliberately tiny — `>=A.B.C <D.E.F`, `*`, or
absent. Anything else warns "unparsable range, skipping check" and continues,
so a fancy range can never harden into a refusal.

### Declared authority

An extension is not merely "a program you chose to run". Roost hands it
`ROOST_SOCKET` and puts `$ROOST_HOME/scripts` on its `PATH`, and those two
together are a capability no ordinary installed program has:

- `roost read %N` on **any** pane — every agent's screen, including whatever
  keys, tokens, `.env` contents and source have scrolled past
- `roost send %N "..."` — inject a prompt into any agent, and those agents
  write files and run commands

That is the escalation worth controlling: not code execution, which the user
already accepted by installing it, but **the ability to puppet the fleet**.

So it is not granted by default. `needs` declares it:

| `needs` | What the extension is given |
|---|---|
| absent, or `[]` | No `ROOST_SOCKET`. No roost scripts on `PATH`. It gets its own directories and nothing else. |
| `["fleet"]` | `ROOST_SOCKET` and `$ROOST_HOME/scripts` on `PATH`, as above. |

An unknown value in `needs` **refuses the install**, naming it. This is the one
place the contract is deliberately strict rather than forgiving: a future
`needs` value silently ignored by an older roost would grant nothing while the
extension assumed it had everything, and the failure would surface as
corrupted behaviour rather than a clean refusal.

The consent block states the grant in words, not in field names — see
`roost ext install`.

`needs` exists in contract 1 precisely so it never has to be added later.
Adding an authority field after extensions exist would mean every extension
without it defaults to "everything", which is the wrong default arrived at
irreversibly.

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

Always:

```sh
ROOST_HOME        # the roost checkout
ROOST_VERSION     # product version, so an ext can adapt
ROOST_CONTRACT    # seam version
ROOST_EXT_DIR     # this extension's own install directory (read-only by convention)
ROOST_EXT_STATE   # this extension's private state directory; created before exec
```

Only when the manifest declares `"needs": ["fleet"]`:

```sh
ROOST_SOCKET      # which tmux server, so the ext talks to the right fleet
PATH              # with $ROOST_HOME/scripts prepended, as panes already get
```

Without `fleet`, `ROOST_SOCKET` is **unset**, not empty — an extension that
reads it gets an unset-variable failure rather than silently addressing the
default tmux server, which is the user's own ordinary tmux and the one thing
roost exists to leave alone.

The withholding happens in the dispatcher, at `exec` time. It is not a check
the extension can pass and then bypass: the variable is simply never in its
environment.

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
    "tree": "6b1d0c94f2a7e5318cd40b7a2f9e6c1d83b45209",
    "contract": 1,
    "needs": ["fleet"],
    "commands": ["mark", "marks"],
    "installed": "2026-09-08T10:14:22Z"
  }
}
```

`tree` is the commit's git tree hash, recorded so `roost ext verify` can prove
the installed directory still matches what was agreed to. `needs` is copied
from the manifest into the lockfile deliberately: the dispatcher must decide
what to grant without reading the extension's own files, because those files
are exactly what an attacker who reached the disk would edit.

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

1. Validate `<org>/<repo>` against
   `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`, refusing a leading `-` in either part,
   **before it reaches `git`**. See "Input handling".
2. Resolve `--ref` (default: the repository's default branch) to a **full
   commit SHA** with `git ls-remote`.
3. Clone that SHA into a temporary directory, hardened as "The install must
   actually run nothing" sets out: `--no-recurse-submodules`,
   `GIT_LFS_SKIP_SMUDGE=1`, `-c core.hooksPath=/dev/null`. Then verify the
   clone's `HEAD` is the SHA that was pinned, and refuse if it is not.
4. Read and validate `roost-ext.json`. Refuse on: missing manifest, bad `name`,
   contract mismatch, an unknown value in `needs`, a claimed command that
   collides with core or with an installed extension, a declared command with
   no executable at `bin/roost-<cmd>`, any path resolving outside the extension
   directory, any setuid or setgid bit.
5. Print the plan and **wait for `y/N`**:

```
  repo     github.com/beatzball/roost-mark
  ref      v0.1.0
  commit   a3f91c2...  (pinned)
  contract 1                       (roost speaks 1)     ok
  roost    >=0.1.0 <0.2.0          (you have 0.1.0)     ok
  claims   roost mark, roost marks

  This extension asks to drive your agents. If you install it, the code
  in it can read any pane's screen and send prompts to any agent, the
  same as you can.

  Roost has checked that this is the exact commit named above. It has
  NOT checked whether the code is honest. It cannot.

  Nothing runs during install. Code runs when you type those commands.

  Install? [y/N]
```

The authority paragraph is printed **only** when `needs` contains `fleet`, and
it is written in what the extension can do, not in the name of a field. An
extension with no `needs` gets a one-line "asks for no access to your agents"
instead. The paragraph about not checking honesty is printed always, because
the moment roost looks like it vouched for something is the moment this design
fails.

6. Move the clone into place, create `ROOST_EXT_STATE`, write `ext.lock`
   including `tree` and `needs`, regenerate `ext.index`.

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

Otherwise it shows the old and new commit **and the diff between them**,
re-validates the manifest, and asks `y/N` again. The diff is not a nicety: a
consent was given to code, not to a repository name, and a repository that
turns bad turns bad between two commits nobody was shown. Paged through
`$PAGER` when one is set and stdout is a tty; capped, with the number of
remaining files named, so a large diff cannot bury the prompt.

A `needs` that has **grown** since install is called out on its own line above
the prompt — an extension quietly acquiring `fleet` on an update is the exact
shape of the attack this field exists to make visible.

**Install never auto-updates.** A pin that silently moves is not a pin.

### `roost ext verify [<name>]`

Re-computes the tree hash of each installed extension and compares it with
`ext.lock`. Prints `ok` or names every file that differs, and exits non-zero if
any do.

This is what makes the pin mean something **on disk** rather than only at fetch
time. Without it, "pinned to a commit" describes what was downloaded once, not
what will run tonight. Cheap enough to suggest in the `list` output whenever
the lockfile and index disagree.

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

## Security

### What this design does not attempt

**Roost never claims an extension is safe.** There is no scanner, no lint, no
model review, and there must never be a line of output that reads like a
verdict. Shell code can fetch its payload at run time or hide it in base64; any
screen would pass a determined attacker and fail honest extensions, and a
"scanned: safe" badge is worse than printing nothing because people believe it.

Everything below is one of two things: **integrity** — it is exactly what you
agreed to — or **least authority** — it can reach less.

### Integrity

| Control | Where |
|---|---|
| Pin to a full 40-character commit SHA, resolved before anything is fetched | `install` |
| Verify the clone's `HEAD` equals the pinned SHA after cloning, and refuse otherwise | `install` |
| Record the commit's tree hash in `ext.lock`; `roost ext verify` re-computes it | `install`, `verify` |
| `update` shows the **diff**, not just a new SHA, before asking again | `update` |

The diff at update time is the control that matters most in practice. Consent
was given to *code*, not to a repository name, and a repository that turns bad
turns bad between two commits you were never shown.

### Least authority

`needs` — see "Declared authority". Absent by default, granted only when
declared, stated in words at the consent prompt.

### Input handling

`<org>/<repo>` is validated **before it reaches `git`**. Both parts must match
`^[A-Za-z0-9._-]+$`, and additionally:

- neither part may begin with `-`
- neither part may be exactly `.` or `..`

The second rule is not redundant, and an earlier draft of this spec got it
wrong. `.` is inside the character class, so the pattern **alone admits
`../..`** — while the sentence beside it claimed to block traversal. A regex
that looks like it enforces a rule, sitting next to prose asserting the rule,
is worse than no regex, because nobody re-reads it. Caught during
implementation; recorded here because the same trap waits for whoever widens
this pattern next.

Not theatre: the argument otherwise flows into a `git` command line, where
`../..` escapes the base, a `https://user:pass@host/` form smuggles
credentials, and a leading dash becomes a flag.

### The install must actually run nothing

The consent block promises "nothing runs during install". That promise is false
unless the clone is hardened, because git will happily execute code on the way
in:

- `--no-recurse-submodules` — a `.gitmodules` URL is another fetch, and can
  point anywhere
- `GIT_LFS_SKIP_SMUDGE=1` — an LFS smudge filter is a command
- `-c core.hooksPath=/dev/null` — belt and braces; hooks are not transferred by
  clone, but the clone is not the only path that reads a config
- after cloning, refuse the extension if any path resolves outside the
  extension directory (a symlink escape) or carries a setuid or setgid bit

Each of these is a line of code. Together they are the difference between a
true statement and a false one at the consent prompt.

### Deferred, and recorded in `docs/known-gaps.md`

- **Confinement.** Nothing stops a running extension from doing what any
  program the user runs could do. Real containment means a `sandbox-exec`
  profile on macOS and something else on Linux — large, platform-specific, and
  out of scope for a tmux tool. Naming it as absent is the honest position.
- **Pattern screening at consent** (`curl | sh`, writes to `~/.ssh`, `~/.aws`,
  `crontab`). Deliberately not in build 1. It is worth adding only as
  *information* — never a verdict, never a refusal, never the word "safe". It
  catches careless, not malicious.
- **No signature verification.** Pinning is the substitute.

### What the docs page says, plainly

> An extension is a program you install and run. Roost pins it to an exact
> commit, tells you what authority it asks for, and asks before installing — so
> you know what you are getting and it cannot change under you. Roost does not
> confine what the program can do once you run it, and it does not check
> whether the code is honest. Install extensions from people you would take a
> shell script from.

## Oracle — automated

Everything above is shell behaviour that a test can assert. `tests/lib.sh`
already builds a throwaway tmux server per run.

`tests/test-ext.sh` covers:

- dispatch: an installed command runs; an unknown one gives the usual usage error
- **core is never shadowed**: a manifest claiming `send` is refused at install
- a second extension claiming an already-claimed command is refused
- contract mismatch refuses; an out-of-range `roost` range warns and continues
- an unparsable `roost` range warns and continues, never refuses
- the environment handed to an extension contains every always-on variable
- **`needs` is enforced**: without `fleet`, `ROOST_SOCKET` is *unset* in the
  extension's environment (not empty) and `$ROOST_HOME/scripts` is not on its
  `PATH`; with `fleet`, both are present. Asserted from inside a stub extension
  that prints its own environment
- an unknown value in `needs` refuses the install, naming it
- **dispatch needs no JSON tool**: with `python3` and `jq` both absent from
  `PATH`, an installed command still runs. This guards the standing decision in
  `scripts/lib/roost-json.sh` that neither is a roost runtime dependency
- `ROOST_NO_EXT=1` makes an installed command fall back to the usage error
- `remove` keeps state; `remove --purge` deletes it
- `update` on an unchanged ref reports no change and rewrites nothing
- a non-tty install refuses without `--yes`
- `<org>/<repo>` refusals, each before `git` is invoked: a `../..` component, a
  leading `-` in either part, a `https://` URL, an embedded space
- the clone is hardened: a fixture repository carrying a `.gitmodules` is
  installed **without** fetching the submodule; a fixture whose tree contains a
  symlink pointing outside the extension directory is refused; a fixture with a
  setuid bit is refused
- `install` refuses when the cloned `HEAD` is not the SHA that was pinned
- `verify` reports `ok` on a fresh install, and after one byte is changed in an
  installed file it names that file and exits non-zero
- `update` prints a diff between the old and new commit before prompting
- `update` calls out a `needs` that grew from `[]` to `["fleet"]`, on its own
  line above the prompt

### Conformance — is the contract rich enough to build on?

Every assertion above asks whether the seam behaves as specified. None asks the
question that actually decides whether contract 1 was designed well: **could a
command roost already ships be rebuilt on it?** If not, the contract is missing
something, and the cheap moment to discover that is before an extension exists
that depends on the shape.

So `roost status` is reimplemented as a contract-1 extension, in
`tests/fixtures/ext-status/`, and its output is compared **byte for byte**
against the core command running against the same test server. It is chosen for
three reasons: it needs `ROOST_SOCKET`, so it exercises `needs: ["fleet"]` —
the newest and riskiest mechanism here; it is about ten lines of `list-sessions`
and `list-panes`, so writing it twice costs little; and its output is plain
text, which against a fixed set of panes makes the comparison a real automated
oracle rather than a person squinting.

The reimplementation must be **independent**. It may use only what the contract
hands it. It may not source anything from `$ROOST_HOME` the contract does not
name, and it may not shell out to `roost status`. A wrapper around the original
proves only that `exec` works.

Two companion fixtures carry the rest of the load:

- `tests/fixtures/ext-status-noneed/` — identical but with `needs` absent. It
  must **fail**, with an unset-variable error rather than quiet output from the
  wrong tmux server. This is the more valuable of the two: an authority never
  watched being refused is an authority that has not been tested.
- `tests/fixtures/ext-argv/` — prints its own `argv`. `roost status` takes no
  arguments, so nothing else here tests argument fidelity, and seams break on
  quoting far more often than on logic. `%200`, `sess:win`, `--force` and an
  argument containing spaces must all arrive intact and in order.

The comparison runs twice: once with the index hand-written, which tests the
**contract**, and once after a real `install` from a `file://` repository, which
tests the **pipeline** that delivers it.

Dispatch overhead is measured at the same time and recorded as a ratio **with
the method**. Never a bare figure: `AGENTS.md` §9 exists because bare figures
get quoted back later as if they were measurements.

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
| **Contract 1 turns out to be missing something an extension needs**, discovered only after extensions exist and the shape is frozen | medium | `roost status` is rebuilt on the contract and byte-compared, before any real extension is written. A contract that cannot express a command roost already ships is not finished. |
| Semver, tags and a changelog are a new ongoing obligation | medium | Real. It is the price of the `roost` range field, which the user chose over a bare contract integer. |
| An extension shadowing a core command could intercept fleet traffic | high | Structurally prevented: lookup lives only in the fallback, and install refuses core names. Both are tested. |
| `git ls-remote` against a compromised repository returns an attacker SHA | low | Consent step shows the SHA; pinning means it cannot change later. Not confinement — see "Security". |
| Extension state grows without bound | low | Owned by the extension; `remove --purge` is the exit. |
| **An extension reads every pane and puppets every agent** — keys, tokens and source scroll past in agent panes | **high** | Not granted by default. `needs: ["fleet"]` must be declared, is withheld at `exec` time rather than checked, is stated in words at consent, and is called out at `update` if it grows. |
| Git executes code during clone via submodules or LFS filters, making "nothing runs during install" a false promise | **high** | Hardened clone: `--no-recurse-submodules`, `GIT_LFS_SKIP_SMUDGE=1`, `core.hooksPath=/dev/null`, plus symlink-escape and setuid refusal. Each is tested against a fixture. |
| `<org>/<repo>` flows into a `git` command line | medium | Validated against a strict pattern before `git` is invoked; a leading `-` refused. Tested. |
| Someone edits an installed extension on disk after consent | medium | `roost ext verify` re-computes the tree hash against `ext.lock`. Detection, not prevention. |
| A user reads roost's checks as an endorsement of the code | medium | No output ever says "safe". The consent block states outright that roost has not checked whether the code is honest and cannot. |
| A running extension does anything the user could do | **accepted** | Unconfined by design. Recorded in `docs/known-gaps.md`, stated in the docs page. Real containment is out of scope for a tmux tool. |

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
