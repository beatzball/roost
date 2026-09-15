# Design — roost-owned settings for every harness (#58)

Status: **agreed in outline, not yet planned.** Both decisions were answered on
2026-09-15 and are marked **[chosen]**. Everything under "Measured" was
executed that day; anything not executed is labelled *inferred* or *not
measured*.

## Goal

Any agent started inside a roost pane — typed by hand, started by `roost
spawn`, or started by another agent — gets roost's wiring from files under
`~/.config/roost/`, and nothing outside roost does. Roost does not edit the
user's own config files to achieve it, and the user can back out of it per
run, per shell, per session, for the whole server, or completely.

## Not this

- Removing the global install path (`roost install`). It stays, as the
  fallback for every harness and every case this design cannot reach.
- Anything the user has to delete by hand.

## Decisions

- **D1 [chosen]: A.** The Claude shim reaches hand-typed `claude` through a
  tmux `default-command`. Added requirement: a clear way to back out of the
  shim — see "Backing out".
- **D2 [chosen]: A.** Existing global Claude entries stay. M4b confirmed that
  identical commands from user settings and `--settings` run once. Doctor warns
  when the global entries point at a different checkout.

## Versions measured

macOS 26.3, tmux 3.6, Claude Code 2.1.272, codex-cli 0.154.0, opencode
1.18.30, bash 3.2 and zsh from the OS. fish is not installed: **not measured**.
All tmux probes ran on throwaway `-L`/`-S` sockets under a `mktemp -d`
`TMUX_TMPDIR`. Real Claude ran in an already-trusted directory, with
`--setting-sources local --settings <tmp>` except for the two authorised M4b
runs. Real codex ran with an isolated `HOME` and `CODEX_HOME` against a local
ollama model. opencode ran with an isolated `HOME` and XDG dirs on a free cloud
model.

## Measured

### M1. tmux never gives a client-created pane the server's global PATH

`bin/roost`'s `ensure_session` runs `set-environment -g PATH
"$ROOST_HOME/scripts:$PATH"`. That line does not reach the panes people use.

Method: start a server with `PATH=/SERVERSTART:...`, set the global PATH to
`/GLOBALMARK:...`, then create panes from clients whose own PATH carries a
distinct marker, and have each pane write its `$PATH` to a file.

| pane created by | PATH the pane got |
|---|---|
| `new-window` from a client (`PATH=/CLIENTMARK…`) | client's |
| `split-window` from a client | client's |
| `new-window -e PATH=/FROM-E…` from a client | **client's** — `-e PATH` is ignored; `-e BAR=…` in the same call was applied |
| `new-session` from a client | client's |
| `new-window` run inside `run-shell` (no outer client) | `/GLOBALMARK…` |
| `default-command 'env PATH=/FROM-DEFCMD:$PATH …'` | `/FROM-DEFCMD:` + client's |

A global variable that is not PATH (`FOO`) reached every pane.

Consistent with that, the Claude process in a live roost pane that `roost
spawn` created on this machine has no `$ROOST_HOME/scripts` anywhere in its
PATH (read from `ps eww` of that process), while `ROOST_HOME` and `TMUX` are
present.

Consequences:

- **Environment variables are a channel roost controls. PATH is not**, unless
  roost puts it into the command a pane runs.
- The "position 20 of 38" figure in the issue is what a login zsh does to a
  directory that *is* first on the inherited PATH (M2 reproduces exactly 20).
  It is not evidence that the server's PATH reached the pane.

### M2. Where a shim directory lands after shell startup

Method: each pane's command was `env PATH="<shim>:$PATH" <shell>`, so the shim
was first on the inherited PATH; then the user's real startup files ran; then
`command -v claude` and the index of each tool directory were read. A fake
`claude` in the shim printed `WRAPPER`, and typing `claude` at the prompt was
checked too.

| shell | shim | nvm (pi) | Homebrew (codex, opencode, copilot) | `~/.local/bin` (claude) | typed `claude` ran |
|---|---|---|---|---|---|
| `zsh -l -i` | 20 | 6 | 7 | 31 | shim |
| `zsh -i` | 7 | 6 | 14 | 37 | shim |
| `bash -l -i` | 12 | 18 | 19 | 25 | shim |
| `bash -i` | 1 | 7 | 8 | 31 | shim |
| `sh -c` command (the `roost spawn NAME CMD` shape) | 1 | 7 | 8 | 31 | shim |

The rule underneath: a shim beats a directory that the startup files append or
that is already later on the inherited PATH. It loses to a directory the
startup files prepend (nvm here) and, in a login zsh, to what macOS
`path_helper` hoists (Homebrew here). These numbers are **one machine's startup
files**. The design must not depend on them for anything but Claude, and
`roost doctor` must check the real answer in a real pane.

### M3. A shim can find the real binary without recursion, and can be switched off

A candidate POSIX `sh` shim was run against a fake `claude` that prints its
argv. It skips every PATH entry that holds a `.roost-shim` marker file and
`exec`s the first other `claude`.

Scope and recursion, with two shim directories (two checkouts) on PATH:

| case | result |
|---|---|
| inside a roost server (`${TMUX%%,*}` ends in `/roost`) | real claude, `--settings <file>` added |
| outside tmux | real claude, argv unchanged |
| inside a different tmux server | real claude, argv unchanged |
| `sh -c 'exec claude hi'` inside roost | `--settings` added |
| two shim directories on PATH | no recursion, one `--settings` |
| no real claude on PATH | `roost: no claude found on PATH`, exit 127 |
| user alias to an absolute path | **bypasses the shim** |
| settings file missing | real claude, argv unchanged |

Off switches, on a throwaway server whose socket path ends in `/roost`, with
two sessions:

| case | argv the real claude got |
|---|---|
| default | `--settings <file> hi` |
| `ROOST_NO_SHIM=1 claude hi` | `hi` |
| `export ROOST_NO_SHIM=1`, then a child `sh -c "claude child"` | `child` — the child is bypassed too |
| `ROOST_NO_SHIM= claude hi` (empty) | `--settings <file> hi` — empty is not a request |
| `set-environment -t other ROOST_NO_SHIM 1`, new pane in `other` | `hi` |
| same, new pane in `main` | `--settings <file> hi` — other sessions unaffected |
| `set-option -g @roost-shim off` (probe name), new pane | `hi` |
| option unset again, new pane | `--settings <file> hi` |
| option `off`, but `tmux` **not on the pane's PATH** | `--settings <file> hi` — the switch could not be read |

The first two server-switch runs read "not switched off" for a harness reason,
not a shim reason: the option was unset before the pane read it, then `tmux`
was not on the pane's PATH. The last row keeps that second cause as a real
finding: the shim must not depend on finding `tmux` on PATH.

### M4. Claude merges hook lists, deduplicates identical commands, and overrides only keys it sets

Method: a stamp hook appends `TAG EVENT` (and two env values) to a log.
`claude -p --model haiku` ran once per case. One source was
`.claude/settings.local.json` (standing in for user settings), the other was
`--settings`.

| case | result |
|---|---|
| C1 `--settings` only (positive control) | 1 stamp per event |
| C2 **identical** command string in both sources | **1** stamp per event |
| C3 different command strings in the two sources | 2 stamps per event (one each) |
| C4 `CLAUDE_CODE_MANAGED_SETTINGS_PATH=<dir>` holding `managed-settings.json` | its hook did **not** fire |
| C5 same variable pointing at the file | did **not** fire |
| O1 local sets `env.PROBE_A=local`, `env.PROBE_B=local`; `--settings` has **only** `hooks` | hook saw `A=local B=local` |
| O2 same local; `--settings` also sets `env.PROBE_B=flag` | hook saw `A=local B=flag` |

O1 and O2 show the override rule at the level that matters: a key `--settings`
sets wins for that key only, even inside one object; a key it does not set is
untouched. So a generated file that carries only `hooks` cannot change any
other setting.

`CLAUDE_CODE_MANAGED_SETTINGS_PATH` exists in the binary but did not load hooks
in either form; it is not a route. No additive Claude environment variable was
found.

### M4b. The same holds with the user's real settings (authorised, read-only)

Method: cwd the trusted directory, default setting sources (user settings
loaded), `--no-session-persistence`, `--model haiku`, `TMUX` and `TMUX_PANE`
unset so roost's hook scripts exit at their first guard.
`--output-format stream-json --verbose --include-hook-events` reports one
`hook_started` per hook that runs. `~/.claude/settings.json` was hashed before
and after each run and did not change.

Calibration first, on local settings: identical commands gave 1
`hook_started`, different commands gave 2 — matching the stamp files exactly.

Before the run, a script checked that all six entries `roost hooks claude`
prints for the primary checkout appear in the user's settings with identical
event, matcher and command. The one enabled plugin with a relevant hook adds
`Stop` only.

| run | `--settings` carried | SessionStart | UserPromptSubmit | Stop |
|---|---|---|---|---|
| 1 | all six roost entries | 1 | 1 | 1 |
| 2 (the one allowed repeat) | the same, **without** `UserPromptSubmit` | 1 | 1 | 1 |

Run 1 alone could not tell "deduplicated" from "user settings not loaded".
Run 2 settles it: `UserPromptSubmit` ran with no copy in `--settings`, so the
user source was loaded, and `SessionStart` — present identically in both —
ran once. The plugin's `Stop` hook did not start in `-p` in either run; that
does not affect the conclusion, which rests on the other two events.

### M5. opencode: `OPENCODE_CONFIG_DIR` is a complete route

Method: isolated home; the user's own config dir held `opencode.json` with a
marker and a stamp plugin; `OPENCODE_CONFIG_DIR` pointed at a directory whose
`plugin/roost.js` is a symlink to `adapters/opencode/roost.js`; `opencode run`
ran in a pane of a throwaway server whose socket path ends in `/roost`.

| case | `@agent_state` | user plugin | user `opencode.json` |
|---|---|---|---|
| config dir with roost.js | `working` → `done` | loaded | loaded |
| config dir empty (negative control) | never set | loaded | loaded |

A first run on a socket *not* named `roost` badged nothing — correctly, by
roost's socket rule — and is recorded here because it looked exactly like a
failure of the route.

**Double load.** With roost.js in the user's plugin dir *and* in the config
dir, opencode loaded it **twice in one process** — with the same basename,
with two names, and with both symlinks pointing at one file. Two copies of the
plugin means two `roost state` and two `roost reply` calls per event.

### M6. codex: `-c` supplies hooks but cannot supply trust

Method: isolated `HOME` and `CODEX_HOME`, local ollama, a stamp hook; hooks
inspected through the app-server `hooks/list` method and exercised with
`codex exec`.

| case | `hooks/list` | stamps on `exec` |
|---|---|---|
| `-c 'hooks.Stop=[{hooks=[{type="command",…}]}]'` | listed, `source: sessionFlags`, key `/<session-flags>/config.toml:stop:0:0`, `untrusted` | none |
| `hooks.json` in `CODEX_HOME` (control) | listed, `source: user`, `untrusted` | not run |
| `-c` hooks **and** `-c 'hooks.state."<key>".trusted_hash="<hash>"'` | still `untrusted` | none |
| `-c` hooks, same trust entry written into `CODEX_HOME/config.toml` (positive control) | `trusted` | `UserPromptSubmit` and `Stop` both fired |
| trusted as above, command string changed by one space | — | none |

So codex can take roost's hooks from a flag, but trust has to live in the
user's `config.toml`, written by codex's own prompt. The trust key for flag
hooks does not contain a path; the hash does, through the command string. *Not
measured:* whether the TUI's "Hooks need review" prompt appears for flag hooks,
and whether flag hooks plus the global `hooks.json` both fire.

### M7. pi and copilot: flag only

- **pi** (source, `dist/config.js`, `dist/core/resource-loader.js`): extensions
  are discovered in `<agent dir>/extensions` and `<cwd>/.pi/extensions`, plus
  packages named in settings. The only directory variable is
  `PI_CODING_AGENT_DIR`, which moves settings, auth, models and sessions
  together. `-e` is a flag.
- **copilot** (`copilot help environment`, and the variable names in the
  binary): `COPILOT_HOME` moves configuration and state together;
  `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` adds instructions only. `--plugin-dir` is
  a flag.
- On this machine both binaries resolve through directories that beat a shim
  in a login zsh (M2).

## Support table

| harness | route | reaches a hand-typed agent | robustness | cost | what the user does |
|---|---|---|---|---|---|
| claude | shim on PATH, adds `--settings ~/.config/roost/wiring/claude/settings.json` | yes, when the shim precedes claude's directory after startup (4 of 4 shells here) | medium: PATH order is per machine; an alias to an absolute path or the user's own `default-command` bypasses it | a shim script, a `default-command`, one generated file | nothing; `roost doctor` reports a bypass |
| opencode | `OPENCODE_CONFIG_DIR` in the roost server's global environment | yes, every pane and shell | high: an environment variable survives startup files; merged with the user's config | one variable, one symlink | nothing |
| codex | stays on `roost install` | — | a shim loses to Homebrew in login zsh here, and trust must be written into `~/.codex/config.toml` either way | — | today's install and trust prompt |
| pi | stays on `roost install` | — | no additive route; a shim loses to nvm here | — | today's install |
| copilot | stays on `roost install` | — | no additive route; a shim loses to Homebrew here | — | today's install |

## What roost's Claude settings file sets

The generated `~/.config/roost/wiring/claude/settings.json` has **exactly one
top-level key, `hooks`**, rendered by `roost_hooks_claude` — the same six
entries, byte for byte, that `roost install` writes for this checkout:

| event | matcher | command |
|---|---|---|
| `SessionStart` | `*` | `<checkout>/scripts/roost-session-context` |
| `UserPromptSubmit` | — | `<checkout>/scripts/roost-agent-state working` |
| `Notification` | `permission_prompt` | `<checkout>/scripts/roost-agent-state blocked --notification-hook` |
| `PostToolUse` | — | `<checkout>/scripts/roost-agent-state working` |
| `Stop` | — | `<checkout>/scripts/roost-agent-state done --stop-hook` |
| `StopFailure` | — | `<checkout>/scripts/roost-agent-state error --stop-failure-hook` |

What that means for the user's own settings, with the measurement behind each:

- **Every other key applies unchanged** — model, permissions, env, plugins,
  status line, and the rest. `--settings` overrides only keys it sets, per key
  even inside an object (M4 O1, O2). The file sets none of them.
- **The user's own hooks still run.** Hook lists merge across sources (M4 C3);
  a user hook on an event roost does not carry ran with user settings loaded
  (M4b run 2).
- **A roost hook the user already has from `roost install` runs once**, when it
  points at the same checkout (M4 C2, M4b).
- *Inferred, not measured:* a user `disableAllHooks: true` also disables
  roost's hooks. That is the user's setting winning, which is correct.

An implementation test must pin "one top-level key" so a later change cannot
quietly start overriding user settings.

## Backing out

The shim only ever **adds** `--settings`. Backing out means running the real
`claude` with no roost argument at all; the user's own settings then apply
exactly as they do outside roost.

### Per run: `ROOST_NO_SHIM=1 claude` **[chosen by this design]**

An environment variable, not a flag the shim strips. Why:

- It survives every way `claude` gets started: `exec`, a user alias named
  `claude`, a script, and an agent's tool. A flag only works when the person
  typing it controls the argv.
- It scopes naturally. The same name works per run, per shell (`export`), and
  per roost session (`set-environment -t`), and it reaches children (M3). A
  flag cannot do any of that.
- The shim never has to rewrite Claude's argv. A stripped flag is a name roost
  reserves inside another program's option space, and it breaks the day Claude
  ships an option of the same name.
- It matches roost's existing kill switch, `ROOST_NO_EXT`, including the rule
  that an **empty** value is not a request (M3, `ROOST_NO_SHIM=`).

Also always available, needing nothing from roost: run claude by its absolute
path (M3, alias row).

opencode has no shim. Its per-run equivalent is `env -u OPENCODE_CONFIG_DIR
opencode`. *Not measured with the variable unset;* the negative control used an
empty config dir and got no badge.

### Per shell

`export ROOST_NO_SHIM=1`. Every `claude` started from that shell, and from its
children, is the real one with no roost settings (M3).

### Per roost session: `roost wiring off -t SESSION`

Runs `set-environment -t SESSION ROOST_NO_SHIM 1` and `set-environment -t
SESSION -r OPENCODE_CONFIG_DIR`. New panes in that session start unwired; other
sessions are unaffected (M3 rows 5 and 6). Panes that already exist keep what
their shell inherited: to back out there, use the per-shell switch.
`roost wiring on -t SESSION` removes both entries from the session
environment. *Not measured:* `-r` for `OPENCODE_CONFIG_DIR`.

### Whole server: `set -g @roost-wiring-enabled off`

Same shape as the ext seam's `@roost-ext-enabled`. Two ways to set it:

- In the user's `~/.config/roost/roost.conf`, read when the server starts.
  `ensure_session` reads the option **after** sourcing the user's conf, and
  when it is `off` sets no `default-command`, no `OPENCODE_CONFIG_DIR`, and
  generates nothing. That server behaves exactly as today.
- At runtime, `roost wiring off` sets the option and unsets
  `OPENCODE_CONFIG_DIR` in the global environment. The shim reads the option
  live on every start, so it also covers panes that already exist (M3 row 7).
  New opencode panes start unwired; running opencode processes keep the plugin
  they loaded.

The shim must reach the server without relying on `tmux` being on the pane's
PATH (M3, last row). `ensure_session` exports the absolute path of the `tmux`
it is running as `ROOST_TMUX` in the global environment — a non-PATH variable,
which M1 shows reaches every pane — and the shim uses that. If the shim still
cannot ask the server, it keeps roost's settings on, and doctor reports the
switch as unreadable. Failing toward "on" keeps the default honest: the switch
is the exception the user asked for, and a silent drop of badges would be the
worse surprise.

### Order the shim checks, cheapest first

1. Not inside a roost server → real claude, unchanged.
2. `ROOST_NO_SHIM` non-empty → real claude, unchanged. No fork.
3. `@roost-wiring-enabled` is `off` → real claude, unchanged. One tmux round
   trip, once per claude start, not per tool call.
4. Settings file missing → real claude, unchanged.
5. Otherwise → real claude with `--settings <file>`.

## Full removal, back to today's behaviour

`roost wiring remove`:

1. Deletes `~/.config/roost/wiring/` — the only directory this design writes.
2. Writes `~/.config/roost/wiring.off`, a marker roost owns, so the next server
   start does not regenerate anything. `ensure_session` treats the marker
   exactly like `@roost-wiring-enabled off`.
3. On a running server, does what `roost wiring off` does.

After a server restart there is no `default-command`, no `OPENCODE_CONFIG_DIR`
and no generated file, which is today's behaviour exactly. Before a restart,
existing panes still carry the shim directory on PATH, and the shim passes
straight through (step 1 or 3 above).

`roost wiring on` reverses it: deletes the marker, clears the option on a
running server, and regenerates at once.

Neither command touches the user's `roost.conf`, `~/.claude`, or
`~/.config/opencode`. A `roost install` global setup, if present, keeps working
the whole time.

## What `roost doctor` shows in each state

| state | doctor line |
|---|---|
| on; `command -v claude` in this pane is the shim | ok — claude: roost settings via the shim |
| on; claude resolves elsewhere (alias, own `default-command`, PATH order) | warn — the shim is bypassed, with the path that won; badges then depend on the global install, whose state is shown next |
| `ROOST_NO_SHIM` set in this shell or session | info — bypassed by `ROOST_NO_SHIM` in this shell or session |
| `@roost-wiring-enabled off` on this server | info — wiring off for this server; `roost wiring on` to restore |
| `wiring.off` marker present, nothing generated | info — wiring removed; `roost wiring on` to restore |
| `ROOST_TMUX` missing or not executable | warn — the server switch cannot be read, so wiring stays on |
| global Claude entries point at **this** checkout | ok — both routes present; hooks run once (M4b) |
| global Claude entries point at a **different** checkout | warn — every hook runs twice; re-run `roost install --only claude` from this checkout |
| `OPENCODE_CONFIG_DIR` set to something that is not roost's | info — opencode uses that directory; roost's plugin comes only from the global install |
| settings file missing while wiring is on | warn — regenerated at next server start |

## Recommended plan

### Phase 1 — Claude and opencode

1. **Generated files, one directory per checkout.**
   `~/.config/roost/wiring/<checkout id>/` holds only what roost writes:
   `claude/settings.json` (only `hooks`, see above) and
   `opencode/plugin/roost.js` (a symlink to the checkout's adapter). One
   directory per checkout, because two servers started from two checkouts
   would otherwise overwrite each other's file (found in review). Each server
   exports its own as `ROOST_WIRING_DIR`, and the shim reads only that. It is
   regenerated atomically each time `ensure_session` boots a server, so a moved
   checkout heals at the next server start. The user's own
   `~/.config/roost/roost.conf` is beside it and is never touched.
2. **Claude shim.** A POSIX `sh` script in the checkout with the M3 logic and
   the check order above. Roost puts its directory first on PATH in two places,
   because M1 shows the server's PATH reaches neither:
   - `ensure_session` sets `default-command` to exec the user's `$SHELL` as a
     login shell with the shim directory prepended, unless wiring is off. A
     `default-command` in the user's own `roost.conf` wins; doctor reports it.
   - `spawn` and `split` prepend it to the command they run. `new` runs no
     command, so `default-command` covers it.
   - The first pane of a new server exists before wiring is applied, so
     `ensure_session` respawns it once wiring is on (found in review).
3. **opencode.** `ensure_session` sets `OPENCODE_CONFIG_DIR` on the server
   unless wiring is off or roost's own environment already has one (the user's
   choice wins, and that user stays on the global install).
4. **One copy of the opencode plugin.** `adapters/opencode/roost.js` returns an
   empty hook set when a process-global flag says it is already loaded. That
   makes M5's double load harmless whatever is installed where, so no removal
   is needed for opencode.
5. **Switches and commands.** `ROOST_NO_SHIM`, `@roost-wiring-enabled`,
   `ROOST_TMUX`, `roost wiring on|off [-t SESSION]`, `roost wiring remove`.
6. **Doctor.** The table above.

### Phase 2 — only if the human wants codex in panes typed by hand

A codex shim adding `-c hooks.*` works for `roost spawn` and for shells where
it wins on PATH. It still needs one trust grant stored by codex in the user's
config, and on this machine a login zsh finds Homebrew's codex first. Not
recommended now.

### Stays on today's global install

codex, pi, copilot — for the reasons in the support table.

## Migration for users who already ran `roost install`

- **claude [chosen: keep].** Nothing is removed. Identical entries run once
  (M4b). Doctor warns when the global entries point at a different checkout,
  the one case that runs every hook twice (M4 C3), and names the command that
  fixes it.
- **opencode.** Nothing to remove. The load guard (Phase 1, step 4) makes the
  old symlink and the new directory coexist. The old symlink can go with #48's
  uninstall.
- **Rollback of the new route.** `roost wiring remove`. The global install, if
  present, keeps working throughout.

## Coexistence with #64 (agent identity recorded by hooks)

- This design changes **where** hooks are registered, not **what** they run.
  The Claude hooks still call `scripts/roost-agent-state` and
  `scripts/roost-session-context`; codex keeps its frozen commands. An identity
  record added inside those scripts applies to both routes unchanged.
- The shim `exec`s the real binary, so no extra process sits between the pane's
  shell and the agent. Whatever process identity #64 records is the agent's own.
- **Constraint for #64:** deduplication depends on identical command strings.
  If #64 changes the Claude hook command strings (new arguments), the
  generated file and the global install must change together, or every Claude
  hook fires twice for anyone who has both.
- A `claude` started by an agent in the same pane gets the same wiring as
  today's global install gives it, and badges the same pane — unless that
  agent's environment carries `ROOST_NO_SHIM`. How #64 treats a child agent in
  one pane is #64's decision; this design does not change it.

## Open items

- *Not measured:* fish; codex's TUI trust prompt for flag hooks; codex flag
  hooks plus `hooks.json` together; `CLAUDE_CODE_PLUGIN_SEED_DIR`;
  `env -u OPENCODE_CONFIG_DIR` and `set-environment -r` for opencode;
  `disableAllHooks` with roost's file.
- The Claude shim is not reached by an alias to an absolute path (M3), or when
  the user's own `default-command` replaces roost's. Doctor reports both.
