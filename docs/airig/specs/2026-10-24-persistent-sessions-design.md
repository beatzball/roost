# Persistent sessions: a roost fleet survives a reboot — design for #191 (#57, #51, #192, #105)

Status: **draft for the human, 2026-10-24. Nothing built.** The four questions
in §9 are open; everything else is decided here with its reason, and will be
re-decided in the open if an answer in §9 moves it. Base: `main` at `83812b1`.

Measurements were taken on 2026-10-24 on throwaway `-S` sockets with every
home redirected, against Claude Code **2.1.310**, codex-cli **0.163.0**,
GitHub Copilot CLI **1.0.103** and pi **0.81.1**, on tmux 3.6, macOS 26.3
(§2). opencode 2.1.3 was **not run** (§2.5 says why). Anything not executed is
labelled *not measured*, and a single run says *once*. The probe scripts were
kept with the design work and are not committed.

**Size: Build.** Four issues, five harnesses, a new file format, two new
system services, and six verbs or flags. It does not fit a Change.

**Oracle: Automated for the shape, human-eye for the reboot.** A throwaway
named server under a redirected `HOME`, `XDG_STATE_HOME` and `TMUX_TMPDIR`:
build a fleet, save, kill the server by its `-S` path, restore, and compare
`status --json` before and after structurally (§8.1). The one thing no test
can do is reboot the machine; that stays a person's check, and §8.2 lists
every such item together so it is paid for once.

---

## The 2026-10-20 incident, and where each lesson is answered

About 38 agent panes across 13 roost sessions were open when the machine
rebooted. The server came back with empty shells. A hand-written script
recovered the Claude sessions; nothing recovered the rest. Each lesson, and the
section that answers it:

1. **The recovery source was Claude's own session files**, read for directory
   and id; only Claude came back. → §2 measures the resume command and the id's
   source for every harness, and §3.2 records the id per pane in the shape,
   from `@roost-session` (#141). §2.6 shows that today 13 of 32 live Claude
   panes carry **no** id; §5.6 says what restore does with such a pane, and §9
   Q4 asks whether to fall back to Claude's own store for them.
2. **Placement was guessed** from the directory. → §3 saves the real session
   name, window name and index, pane index, name and layout. Nothing is
   derived from a path again.
3. **Every pane id changed**, and every `roost send` between agents broke.
   → §5.4: each restored pane carries `@roost-was %OLD`, the shape directory
   keeps an old-to-new map for the restored server's life, and every verb that
   takes a target accepts an old id through it with one stderr line. Claude
   also learns its new id for free (§2.1, SessionStart).
4. **Restoring 35 agents at once was too heavy.** → §5.5: 2 s between
   resumes, agents after shells, `--recent` and `--only` selectors, and §9 Q1
   on whether agents come back at login or when a person first attaches.
5. **Some conversations came back outside their roost session.** → §5.1: a
   resume runs only in its own saved session and window, in its saved
   directory; a missing directory gives a shell and a note, never a resume
   somewhere else (§2.1 measured why).

---

## 1. What already exists, not re-derived

- **The pane record** (#74, `docs/airig/specs/2026-09-16-pane-record-design.md`):
  one directory per pane under `${XDG_STATE_HOME}/roost/panes/<boot>/<N>/`,
  plain files, no parser, written whole-or-nothing with `mktemp` + `mv`, no
  `flock` (macOS has none). It reserved `name`, `session`, `window`, `cwd`,
  `state`, `harness` and `session_id` for #51 and #57. Three are written today
  by `scripts/lib/roost-identity.sh`: `session_id`, `cwd`, `harness`.
- **Identity** (#141, `scripts/lib/roost-identity.sh`): `@roost-session`,
  `@roost-cwd`, `@roost-harness`, `@roost-transcript-path` on the pane, one
  tmux read then bail when unchanged, validated before they become an option
  or a path. Claude stamps at `SessionStart` (`scripts/roost-session-context`),
  codex at `UserPromptSubmit` (`adapters/codex/roost-codex-hook`), the other
  three through `roost identify`.
- **Liveness** (`roost_record_liveness`): a record is live only when the
  server at its socket answers the same boot key and pane id. Pane ids restart
  at `%0` on every server start (M1 there), which is why the boot key is in
  every path and why a saved `%N` can never be reused as an address (§5.4).
- **The events hooks** (`tmux/roost.conf`): `pane-exited[98]`,
  `after-kill-pane[98]`, `window-unlinked[98]`, `session-closed[98]` already
  run `roost events --reconcile` with `run-shell -b`. Save-on-change (§3.4)
  adds hooks in the same slot style; nothing new runs on `PostToolUse`.
- **`roost close`** (`scripts/lib/roost-close.sh`): the per-harness exit
  command table (`/exit`, `/quit`) and `roost_close_harness`, which reads a
  harness off `@roost-harness`, else `#{pane_current_command}` (Claude's is its
  version string), else `@roost-name`. The resume table (§2.7) sits beside it.
- **Wiring** (#58): a server started by `bin/roost` sets `default-command` to
  `scripts/roost-pane-shell`, and a command handed to `spawn` or `split` goes
  through it. A restored pane's command must go through it too (§5.1).
- **#105** (who may report a pane's state) is **not** a prerequisite. §5.3
  says why, from measurement.

---

## 2. Measurements

Method, unless a row says otherwise: a throwaway `-S` socket whose path ends in
`/roost` (so roost's hooks act on it), `HOME`, `XDG_*` and the harness's own
home variable at temp directories, this checkout's hooks or adapter installed
the way a user installs them, one prompt, then the exit command, then the
resume command in a new window, then the same resume from a different
directory, then a resume of an id that does not exist. Screens were captured;
pane options were read with `show-options -pqv`. "Identity" below means the
four `@roost-*` options.

### 2.1 Claude Code 2.1.310 — measured, with the fake Messages API

The rig of `tests/live/claude-background-smoke.sh`: a local stand-in for the
Messages API scripting a text reply, `--model haiku --permission-mode default
--setting-sources local --settings <file>`, the project trusted in the
throwaway `.claude.json`. The real `~/.claude/settings.json` was hashed before
and after and did not change; no project key was added to `~/.claude.json`.

| case | result |
|---|---|
| fresh start, one prompt | identity stamped at `SessionStart`: `session`, `harness=claude`, `cwd` (the launch directory), `transcript` under `~/.claude/projects/<cwd with / as ->/<id>.jsonl`. The transcript file exists and names the id. |
| `/exit` | exit 0, and Claude itself prints `Resume this session with: claude --resume <id>` |
| `claude --resume ID`, same directory | at its prompt in **1 s**. The old prompt and reply are on screen; the next request to the API carried 5 messages (the old conversation). `SessionStart` fired again with the **same** id and the same transcript, so identity re-stamps itself. No badge: `@agent_state` is empty until the first event. |
| `claude --resume ID`, a **different** trusted directory | **resumes anyway**, and files the transcript under the new directory's project folder (`projects/-...-other/<id>.jsonl`), `cwd` = the new directory. So a resume in the wrong directory does not fail — it silently moves the conversation's project. §5.1's rule follows from this. |
| `claude --resume ID`, a directory **not** trusted | the folder-trust dialog (`Quick safety check: Is this a project you created or one you trust? … ❯ No, exit / Yes, I trust this folder`). No hook fires, no identity, no badge. Left for a person. |
| `claude --resume` of an id that does not exist | `No conversation found with session ID: …`, exit 1, at once |
| `claude --session-id UUID` (minted by roost) | identity records exactly the minted id |
| `claude --resume ID --fork-session` | a **new** id; the old conversation is copied, the old id stays as it was |

Claude needs the project directory to be the same for the conversation to
stay with its project, and the trust answer to be on file for that directory.
Time to prompt was 1 s against the fake API; against the real API *not
measured*.

### 2.2 codex-cli 0.163.0 — measured, local model through the tool proxy

The rig of `tests/live/codex-smoke.sh`: `CODEX_HOME` at a temp directory,
`llama3.2:3b` through `tests/live/codex-tool-proxy.py`, the project
pre-trusted in `config.toml`, roost's five hooks in `hooks.json` and trusted
through the real "Hooks need review" prompt (`2`, Enter).

| case | result |
|---|---|
| fresh start, one prompt | badge `done` lands. **Identity is empty**: `@roost-session`, `@roost-harness`, `@roost-cwd` all unset. Two `codex app-server` processes ran under this `CODEX_HOME`, so the hooks' parent was the shared app-server and `adapters/codex/roost-codex-hook` skipped identity, as #145 and `docs/known-gaps.md` ("A second codex pane can badge the first") say. **So on 0.163.0 roost records no resume key for codex.** |
| where the id is | the rollout file: `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`. The uuid is the last 36 characters of the name; the file's first line (`session_meta`) carries the same `id` and the launch `cwd`. |
| `/quit` | exit 0; the two app-server processes **outlive** the TUI and the tmux server (known-gaps said so; seen again) |
| `codex resume ID`, same directory | at its prompt in 1 s with the old prompt and reply on screen. The resume **appended to the same rollout file** (still one file). The next turn's badge landed on **no pane**: the resumed TUI's hooks ran in the app-server the first TUI had started, whose `TMUX_PANE` named the pane that was already closed. That is #145 again, and §5.7 says what it means for a restore of several codex panes. |
| `codex resume ID`, a **different** directory | a **dialog**: `Working directory · resume — 1. Use session directory 2. Use current directory 3. Always use session directory 4. Always use current directory`. Left for a person. Avoided entirely by resuming in the session's own directory (§5.1). |
| `codex resume` of an id that does not exist | `ERROR: No saved session found with ID …`, exit 1, at once |
| `codex resume` with no id | a picker, **filtered to the current directory** (`Filter: Cwd / All`); from another directory it says `No sessions yet`. `--last` resumes the newest without the picker. |

Also seen, as in known-gaps: codex downloaded a 0.164.0 app-server into the
throwaway `CODEX_HOME/packages/` despite `check_for_update_on_startup =
false`. The probe killed its own app-servers by their environment's
`CODEX_HOME`; a restore test must do the same (§8.1).

On the live `-L roost` server today, 3 of 3 codex panes **do** carry a session
id (§2.6). The probe recorded none. Which codex version or start path those
three came from was not chased; the design does not rely on either outcome.

### 2.3 GitHub Copilot CLI 1.0.103 — measured, BYOK against a local model

The rig of `tests/live/copilot-smoke.sh`: `COPILOT_HOME` at a temp directory,
`COPILOT_PROVIDER_BASE_URL` at ollama, `COPILOT_OFFLINE=true`, the roost
extension symlinked, `EXTENSIONS` flag on. Every start asked two dialogs in
this empty home — folder trust and the extension's permission — and both were
answered with their first, this-session-only choice.

| case | result |
|---|---|
| fresh start, one prompt | identity: `session` (a UUID), `harness=copilot`, `cwd`; no transcript. The session lives in `$COPILOT_HOME/session-state/<id>/` (`events.jsonl`, `workspace.yaml`); `open-sessions-state.json` names it too. |
| `/exit` | exit 0 |
| `copilot --resume=ID`, same directory | at its prompt in 9 s (the two dialogs included), old prompt and reply on screen, the **same** id re-identified, next turn badges `done`. |
| `copilot --resume=ID`, a **different** directory | resumes, and identity reports `cwd` = the **session's saved** directory, not the one it was started in: copilot goes back to where the session lived (its help says the session working directory is the `--resume` one). No dialog beyond the two every start asked. |
| `--resume` of an id that does not exist | `Error: No session, task, or name matched '…'` with the five ways to resume listed, exit 1 |
| `copilot --session-id=UUID` (minted by roost) | identity records exactly the minted id |

### 2.4 pi 0.81.1 — measured, local model

The rig of `tests/live/pi-smoke.sh`: `PI_CODING_AGENT_DIR` at a temp
directory with an ollama provider, `PI_OFFLINE=1`, the roost extension
symlinked.

| case | result |
|---|---|
| fresh start, one prompt | identity: `session` (a UUIDv7), `harness=pi`, `cwd`, `transcript` = the session file `$PI_CODING_AGENT_DIR/sessions/--<cwd with / as ->--/<timestamp>_<id>.jsonl`. The file name holds the id. |
| `/quit` | exit 0 |
| `pi --session ID`, same directory | at its prompt in 5 s, old prompt on screen, same id re-identified, next turn `done`. |
| `pi --session ID`, a **different** directory | a **dialog**: `Session found in different project: <dir> — Fork this session into current directory? [y/N]`. No identity. Left for a person. |
| `pi --session PATH` (the session file), a different directory | resumes with no dialog; identity reports the session's own `cwd`. |
| `pi --session` of an id that does not exist | `No session found matching '…'`, exit 1 |
| `pi --session-id UUID` (minted by roost) | identity records exactly the minted id |

### 2.5 opencode 2.1.3 — not measured; opencode 1.x — not measured

**Why not run:** opencode 2 serves every TUI from **one background service
per user** (`opencode serve --service`), whatever directories are redirected.
`tests/live/opencode2-smoke.sh` measured on 2.0.22 that a TUI on redirected
homes sits at "Starting background server…" for ever while the user's own
service is alive, and this machine's own service was running throughout
(pid seen with `pgrep`). Stopping it would have stopped the author's real
opencode, which the rules forbid. The 1.x binary is no longer on this machine.

From `opencode --help` on 2.1.3, **not run**:

- `opencode --session ID` / `-s ID` for the TUI, `opencode run -s ID` for a
  non-interactive turn, `--continue`/`-c` for the newest session, `--fork`.
- **The flag says "Session ID to continue, or to create if it does not
  exist".** So a resume of a lost or mistyped id does not fail: it opens a new
  empty session under that id. The adapter's resume step must check the id
  exists first (`opencode session list` is in the help; its output shape is
  *not measured*), or `revive` will report success on an empty conversation.
- Where roost records the id: the 2.x adapter (`adapters/opencode/v2/tui.js`)
  calls `roost identify --session <sessionID> --cwd … --harness opencode`
  from the TUI's route; the 1.x plugin (`adapters/opencode/roost.js`) from the
  first `session.*` event. Both are built and tested in the suite; neither was
  exercised live for this design. No transcript path: opencode keeps
  conversations in its own database.
- What a resume does on screen, whether it opens a dialog in a different
  directory, and how long it takes: *not measured*.

### 2.6 The live server today, read-only

`roost status --json` on the author's live `-L roost` server, 2026-10-24:

| | count |
|---|---|
| sessions | 13 |
| panes | 47 |
| panes with a `@roost-name` | 46 |
| panes whose `harness` is `claude`, all with a `session_id` | 19 |
| panes whose `harness` is `codex`, all with a `session_id` | 3 |
| panes with **no** harness whose `command` is Claude's version string (`2.1.305`) | **13** |
| panes with no harness running a shell or a viewer (`bash`, `zsh`, `glow`) | 12 |

So 13 of 32 Claude panes carry no identity and no resume key. They are the
panes the 2026-10-20 script restored by typing `claude --resume` into a shell,
before #141's identity hook was on this machine (*inferred* from the dates;
not proven). A reboot today would lose exactly those 13 again unless the
design covers a Claude pane with no recorded id (§5.6, §9 Q4).

### 2.7 tmux facts this design rests on

- **A full listing is cheap.** `list-panes -a -F …` with the eleven fields the
  shape needs took 5 ms on the live server (47 panes); `list-windows -a`,
  4 ms. A save is one listing and one `mv` (§3.4 costs it).
- **Hooks available** on tmux 3.6, from `tmux(1)`: every command has an
  `after-<command>` hook (`after-new-window`, `after-split-window`,
  `after-new-session`, `after-rename-window`, `after-rename-session`,
  `after-kill-pane`, `after-respawn-pane`), plus `pane-exited`, `pane-died`,
  `window-unlinked`, `window-renamed`, `session-closed`, `session-renamed`,
  `window-layout-changed`, `client-attached`, `client-detached`. The `after-*`
  hooks exist on tmux 3.2 too (the floor roost checks); `window-layout-changed`
  fires on every resize and is **not** used (§3.4).
- **Pane ids restart at `%0`** on every server start and the boot key
  `#{start_time}-#{pid}` tells servers apart (pane-record M1, M3). A saved
  `%N` is history, never an address.
- **`respawn-pane -k` keeps the pane id** and changes `pane_pid` (M3 case 6).
  That is what lets `roost revive` on a live pane keep its `%N`.
- `#{pane_current_path}`, not `#{pane_path}`, carries the directory (M1).
- `select-layout` takes a `window_layout` string back (`tmux(1)`); whether it
  needs the pane count to match, and that it ignores the pane ids embedded in
  the string, is *inferred from the manual, not measured* — step 1's first
  probe.

### 2.8 The resume table

What each adapter's resume step runs, where the key comes from, and what to
expect on screen. The exit column is `scripts/lib/roost-close.sh`'s table.

| harness | resume by id | key recorded by roost today | source if roost has no key | on resume | dialogs a resume can open | exit |
|---|---|---|---|---|---|---|
| claude 2.1.310 | `claude --resume ID` in the session's directory | `@roost-session` at SessionStart; record `session_id` | `~/.claude/projects/<cwd encoded>/<id>.jsonl`, newest by mtime | prompt in 1 s (fake API), conversation on screen, same id | folder trust in an untrusted directory | `/exit` |
| codex 0.163.0 | `codex resume ID` in the session's directory | **none** under the shared app-server (#145) | `$CODEX_HOME/sessions/**/rollout-*-<id>.jsonl` whose `session_meta.cwd` is the pane's cwd, newest | prompt in 1 s, conversation on screen | "Working directory · resume" when the directory differs; "Hooks need review" when roost's hooks are not yet trusted | `/quit` |
| opencode 2.1.3 | `opencode -s ID` | `@roost-session` via `roost identify` (tested, not run live) | none usable: a database | *not measured*; **creates** the session if the id is unknown | *not measured* | `/exit` |
| copilot 1.0.103 | `copilot --resume=ID` (any directory; it returns to the session's own) | `@roost-session` via `roost identify` | `$COPILOT_HOME/session-state/<id>/` | prompt in 9 s, conversation on screen, same id | folder trust and extension permission on a home that has not answered them | `/exit` |
| pi 0.81.1 | `pi --session PATH` (the recorded transcript), else `pi --session ID` in the session's directory | `@roost-session` and `@roost-transcript-path` via `roost identify` | `$PI_CODING_AGENT_DIR/sessions/--<cwd encoded>--/*_<id>.jsonl` | prompt in 5 s, conversation on screen, same id | "Fork this session into current directory?" when the id is used from another directory | `/quit` |

Minting works on three: `claude --session-id`, `copilot --session-id`,
`pi --session-id` all accept a UUID roost chooses, and identity records it
(measured). codex and opencode do not take one. This design does **not** mint
at spawn: #141 already records the id the harness chose, and a minted id buys
nothing a recorded one does not — except for codex, where recording is broken
(#145) and minting is not offered. The one thing minting would add is a
resume key before the first prompt; §5.6 covers a pane that has none.

---

## 3. The saved shape

### 3.1 Where it lives

```
${ROOST_SHAPE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/roost/shapes}/<server>/
  shape              the newest save
  history/<stamp>    the saves before it, newest ROOST_SHAPE_KEEP (default 10)
  aliases/<boot>     the old-id → new-id map of the restore that made boot <boot>  (§5.4)
  persist            present when `roost persist on` has been run for this server  (§4.4)
```

`<server>` is the socket **name** for a `-L NAME` server (`roost` for the
default), which is what survives a reboot: the socket file under
`/tmp/tmux-UID/` does not. A `-S PATH` server is keyed by its path with `/`
written as `-` (the way Claude files a project), so a test server never shares
a key with the real one even when both are called `roost` — and every test
redirects `XDG_STATE_HOME` anyway, as the record tests do.

The state directory, beside `panes/` and `events/`, because it is machine
written state and `rm -rf ~/.local/state/roost` already means "forget
everything roost remembered". **§9 Q3** offers the config directory instead,
since the file is meant to be hand-edited. `ROOST_SHAPE_DIR` overrides the
whole path for tests; it must be absolute, and empty means "save nothing", the
rule `ROOST_RECORD_DIR` already has.

### 3.2 The format

Plain text, one `key value` per line, blocks separated by a blank line, read by
`while read -r key value` and `case` in bash 3.2 or dash — no JSON parser,
the rule the pane record chose and the reason it chose it. A value is the rest
of the line after the first space; it may hold spaces and `=`; it may not hold
a newline, a tab or a control character, which is exactly what
`roost_identity_valid` already refuses. Paths are absolute. The file is UTF-8.

```
roost-shape 1
server roost
socket /private/tmp/tmux-501/roost
boot 1792526903-7170
saved 2026-10-24T20:51:02Z
roost 0.10.0
tmux 3.6
host example.local

session roost
active 1

window roost:1
name roost
layout 2774,381x86,0,0{95x86,0,0,88,94x86,96,0,91,190x86,191,0,90}
active 1

pane roost:1.1
id %88
name promo
cwd /home/me/w/roost
harness claude
session_id 3fa32375-68cd-43c9-8bcf-fbb876b2db1e
transcript /home/me/.claude/projects/-home-me-w-roost/3fa32375-68cd-43c9-8bcf-fbb876b2db1e.jsonl
command 2.1.310
state done
active 1

pane roost:1.2
id %91
name linkedin
cwd /home/me/w/roost
command zsh
```

Rules, each with its reason:

- **`roost-shape 1`** is the first line. The schema rule is the pane record's:
  adding a key never moves the number; a reader ignores keys it does not know;
  the number moves only when an existing key changes meaning. A restore that
  finds a larger number, or no readable first line, **refuses and names the
  fault** and changes nothing (#51 requirement 7: never half-restore).
- **A block starts with `session`, `window` or `pane`** and its address;
  `window` is `SESSION:INDEX`, `pane` is `SESSION:WINDOW_INDEX.PANE_INDEX`.
  Indices are what tmux recreates in order; the saved `id` is kept only for
  §5.4's map and for `revive`, never used as a target.
- **Every pane block has `cwd`**; it always exists (`#{pane_current_path}`).
  `name` is `@roost-name` when set. `harness`, `session_id`, `transcript` are
  the identity options when set and are **absent, not empty, otherwise**: a
  reader tests presence. `command` is `#{pane_current_command}`, a **hint**
  only (pane-record M2: it is not stable), kept so a Claude pane with no
  identity can still be recognised by its version string
  (`roost_close_harness` already does this). `state` is `@agent_state` at the
  save and is **never restored** (§5.3); it is there so a person reading the
  file knows what the fleet was doing.
- **`parent`** (reserved, #99): `@roost-parent` when that lands. Not written
  until then.
- **Nothing a harness owns is in the file**: no transcript bytes, no replies,
  no scrollback. The record keeps replies; the harness keeps conversations.
- **Hand-editable** means a person can delete a pane block to not restore it,
  change a `cwd`, or rename a session, and `roost restore --dry-run` shows the
  result. A block with an unknown first word, or a value with a control
  character, is a named refusal of the whole file (requirement 7 again).
- Field names reuse the pane record's reserved names (`name`, `session`,
  `cwd`, `state`, `harness`, `session_id`), so the two never say one thing
  with two words.

### 3.3 Why a file of its own and not the pane records

The record is per pane, keyed by a boot that is gone, and it says nothing
about windows, layouts or which session a pane sat in; #51 forbade building
restore on continuous snapshotting of records. The shape is one file per
server a person can read top to bottom. What the two share is the identity
triple, and `save` reads it from the live pane options, not from the record;
`revive` of a **gone** pane (§4.1) is the one place the record is the source,
because the pane option died with the pane.

### 3.4 When it is written, and what it costs

**On change, not on a timer** (#192). Two kinds of writer, both running
`roost save --auto` for the server they are on:

| event | mechanism | why this one |
|---|---|---|
| a session is created or closed, renamed | `after-new-session[98]`, `session-closed[98]`, `after-rename-session[98]` | placement changed |
| a window is created, killed, unlinked, renamed | `after-new-window[98]`, `window-unlinked[98]`, `after-rename-window[98]` | placement or a name changed |
| a pane is split, exits, is killed, is respawned | `after-split-window[98]`, `pane-exited[98]`, `after-kill-pane[98]`, `after-respawn-pane[98]` | a pane came or went; `revive` uses respawn |
| `roost spawn`, `split`, `view` set `@roost-name` | a direct call at the end of each branch in `bin/roost` | a name changed with no tmux hook for it |
| `roost identify` writes (`ROOST_IDENTITY_WROTE=1`) | a direct call in `roost_identity_stamp`'s caller, only when it wrote | the resume key changed; when nothing changed the one-read-then-bail path is untouched |
| the user's own `roost save` | the verb | a person asked |

**Not** on `window-layout-changed` (every resize), not on `after-set-option`
(every badge), nothing on `PostToolUse`, nothing in `roost state`. A layout
change alone is therefore saved only with the next event of any other kind —
a resize made and then nothing else before a crash restores the previous
layout. Accepted: a layout is the least of what was lost on 2026-10-20.

**Cost.** Each hook runs `run-shell -b`, so the server does not wait. A save
is one `list-sessions`, one `list-windows -a`, one `list-panes -a` (4 to 5 ms
each on 47 panes, §2.7), a `mktemp`, a `printf` loop and one `mv`: *estimated*
under 50 ms per save on this machine, off every agent's path. Spawning ten
panes writes ten saves, each a complete snapshot; the last one wins. The
measurement step 4 must take: the time of `roost save --auto` at 47 panes,
and that 50 `roost state working` calls on a `working` pane write no shape
(the record test's hot-path shape).

**The two identity hooks are the only ones on an agent's path**, and both
already bail in one tmux read when nothing changed (#141); the save call is
behind the write, which is once per session start, or once per `/clear` or
resume.

### 3.5 How it is written atomically, and the history

`mktemp` in the shape directory, write, `mv` over `shape` (rename(2), the
record's rule). Before the `mv`, the current `shape` is hard-linked into
`history/<its saved stamp>` and the oldest beyond `ROOST_SHAPE_KEEP` removed.
Two saves at once both complete; a reader never sees a partial file.

**Why a history, and the one rule on reading it.** When a machine shuts down,
every process is signalled at about the same time. If the tmux server handles
some `pane-exited` hooks before it is itself killed, the newest save is a
**shrinking** fleet — a few shells, then nothing — and the save before the
shutdown is the one worth restoring. Whether tmux runs any hook during a macOS
shutdown or a Linux `systemctl poweroff` is **not measured**; the risk is
stated here so the builder does not learn it from a user. The reading rule,
to be checked in §8.2: starting from the newest save, while the save before it
is at most 30 s older **and** has more panes, step back; restore the first
save that breaks the chain. `roost restore --list` shows every save with its
stamp and counts, `--from STAMP` picks one by hand, and the at-login restore
prints which it chose and why.

---

## 4. The verbs

Exit codes: every roost verb today uses 0 to 11 among them (`send` 0–4 and 6,
`wait-done` 0, 1, 2, 5, `close` 0–2, `events` 3, `answer` 0 and 6–11,
`identify` 2). The new verbs keep only the three meanings every verb shares —
**0** did it, **1** refused or failed as the message says, **2** no such target
or no such file — and take their own meanings from **12 upward**, so a script
that tests a number can never read a new verb's code as an old verb's.

### 4.1 `roost revive [--new-window] TGT` (#57)

Bring back the conversation of one pane.

1. Resolve `TGT` (`%N`, `@N`, `[SESSION:]WINDOW`, or an old id through the
   alias map, §5.4). A live pane: read its `@roost-harness`, `@roost-session`,
   `@roost-cwd`, `@roost-transcript-path`; a gone `%N` on this boot: read the
   record's `harness`, `session_id`, `cwd` (§3.3).
2. No harness, or no key: exit **13**, `roost revive: '%5' has no recorded
   conversation (harness claude, no session id)` — and for Claude, if §9 Q4 is
   answered A, print the command the fallback would run, without running it.
3. The harness is not on `PATH`: exit **14**, naming it.
4. Build the command from the resume table (§2.8), through
   `scripts/roost-pane-shell` on a wired server, in the recorded `cwd`. The
   `cwd` is gone: exit **15**, `directory … no longer exists; not resuming
   elsewhere` (§2.1: Claude would silently re-file the conversation).
5. A live pane: `respawn-pane -k -c CWD` — the pane keeps its `%N` (§2.7), so
   nothing that addresses it breaks. Refused on a `working` or `blocked` pane
   unless `--force`, the `close` rule, because `-k` kills the agent mid-turn.
   A gone pane, or `--new-window`: `new-window -d` in the pane's old session
   (from the record's reserved `session` when written, else the caller's), and
   `@roost-was %OLD` on the new pane. Then `@roost-name` re-stamped.
6. Print `%NEW` on stdout (the new or kept id), one line on stderr with the
   command, exit 0. roost does **not** wait for the harness's prompt and does
   not answer anything it opens. `--json`: `{"pane","was","harness",
   "session_id","command","cwd"}`.

### 4.2 `roost save [--to FILE] [--auto]` (#51)

Write the server's shape (§3). Prints the path and `S sessions, W windows,
P panes, A with a conversation` on stderr; exit 0, or 1 when nothing could be
written (the directory refused, the server gone). `--auto` is what the hooks
call: it writes only when the server has at least one pane, says nothing, and
never fails loudly — the `run-shell -b` rule. `--to FILE` writes a copy
anywhere (a committed fleet file is **out of scope** here; §10 says why), and
is the way a person moves a shape between machines.

### 4.3 `roost restore [--from FILE|STAMP] [--list] [--dry-run] [--no-resume] [--only SEL ...] [--recent DAYS] [--pace SECONDS] [--json]` (#51)

Recreate the saved placement, then resume what has a key.

- **Refuse first.** Schema unknown or larger, a malformed block, a value with
  a control character: exit **16**, one line naming the line number and the
  fault, nothing done. No shape for this server: exit 2.
- **Server.** Not running: start it the way `ensure_session` does — `-f CONF
  new-session -d -s <first saved session> -c <that session's first cwd>`,
  then `roost wiring apply` and the first-pane respawn — so a restored server
  is wired like a started one. Running: use it.
- **Sessions.** One that exists is **skipped and named** (`roost restore:
  session 'litro' exists — skipped, 9 panes not restored`), and every window
  and pane inside it with it; a partial fleet is never merged into a live
  session (#51 requirement 4). Others are created in saved order.
- **Windows.** `new-window -d -n NAME -c CWD` for the first pane's `cwd`;
  then `split-window` for each further pane in index order with its own `cwd`;
  then `select-layout` with the saved layout (§2.7's inferred item; when it
  fails, the panes exist and the layout is tmux's default, with one stderr
  line). Pane names re-stamped; `@roost-was %OLD` on every pane; the alias
  map written (§5.4). Windows are made with their **shells**, through
  `default-command`, so a pane with no conversation is a shell in its old
  directory at this point.
- **Directories.** A `cwd` that no longer exists → the home directory **and**
  a stderr line per pane; such a pane is never resumed (§4.1 step 4).
- **Resumes.** Unless `--no-resume` (§9 Q2 decides the default), for each pane
  that has `harness` and `session_id`, in saved order, **shells first then
  agents**, `--pace` seconds apart (default **2**, the incident's number): run
  §4.1's steps 3 to 5 on the new pane. A missing harness leaves a shell with a
  note; a dialog is left on screen. `--recent DAYS` skips the resume (not the
  placement) of a pane whose transcript, when recorded, is older than DAYS by
  mtime; a pane with no transcript path is always resumed. `--only SEL`
  (repeatable) restricts both placement and resume to a session name, a
  `SESSION:WINDOW`, or an old `%N`.
- **Report**, stderr, then exit: `restored S sessions, W windows, P panes;
  resumed A agents; skipped K (existing); R not resumed (reasons listed
  above)`. Exit **0** when everything was placed and every agent with a key
  was launched; **12** when something was skipped as existing; **13** when a
  pane could not be resumed for a reason listed (the placement still
  happened); 12 wins over 13 when both. `--json` prints the same as one
  document: `{"restored":[{"was","pane","session","window","resumed",
  "reason"}],"skipped":[…],"from":STAMP}`.
- **`--dry-run`** prints the plan with the same words and exits with the code
  the real run would give before any resume. `--list` prints the history
  (§3.5) and exits 0.

### 4.4 `roost persist on|off|status [--name NAME]` (#192)

Bring the fleet back at login, opt in.

- **`on`**: write the `persist` marker in the server's shape directory, then
  install the user service and load it:
  - macOS: `~/Library/LaunchAgents/dev.roosting.roost.<server>.plist`,
    `RunAtLoad` true, `ProgramArguments` `[<this checkout>/bin/roost persist
    --at-login <server>]`, `EnvironmentVariables` with the caller's `PATH`,
    `LANG`/`LC_ALL` and `HOME` (a launchd job has a minimal environment, and
    tmux reads its locale once at start — the ssh page already records the
    `_` glyphs that follow a C locale), `StandardOutPath`/`StandardErrorPath`
    under the shape directory as `login.log`. Loaded with `launchctl
    bootstrap gui/$(id -u) PLIST`.
  - Linux: `~/.config/systemd/user/roost-persist@.service` with
    `ExecStart=<checkout>/bin/roost persist --at-login %i`, `Environment=`
    for the same three, `WantedBy=default.target`; `systemctl --user enable
    --now roost-persist@<server>`. A user instance that should start at boot
    without a login needs `loginctl enable-linger`; `persist on` prints that
    as a line, does not run it.
  - `--at-login NAME` is the hidden form the service runs: it waits up to 60 s
    for the socket directory to be writable, then does §4.3 for NAME with the
    history rule of §3.5, and writes what it did to `login.log`. **§9 Q1**
    decides whether it also resumes agents or leaves that to the first attach.
- **`off`**: `bootout`/`disable --now`, remove the unit file and the `persist`
  marker, **nothing else**: shapes and history stay (#192 requirement 2).
- **`status`**: `on`/`off`, the unit path, whether the loaded unit names
  **this** checkout (an upgrade or a relink moves checkouts; the unit must
  follow — `roost upgrade` gets one line to rewrite it when `persist` is on),
  the newest save's stamp and counts, the last `login.log` summary.
- A machine with neither launchd nor systemd: exit **17**, named.

### 4.5 What `roost doctor` reports

Three lines, in the existing `ok`/`warn` style, warning only:

- `persist: on for 'roost' (launchd, unit names this checkout; last save
  2026-10-24 20:51, 13 sessions / 47 panes; last login restore: 2026-10-20
  …)`, or `persist: off (roost persist on to restore the fleet at login)`.
- `warn`: the unit names another checkout; or its `PATH` lacks a harness the
  newest shape names; or `persist` is on and the newest save is older than the
  server's boot (hooks are not saving).
- `warn`: N panes on this server run a harness with no recorded conversation
  (the §2.6 count), with the harness names — the panes a reboot would lose.

---

## 5. Restore rules

### 5.1 A resume runs in its own place, or not at all

Every resume runs in the saved **session**, the saved **window**, the saved
**directory**, through `roost-pane-shell`. Measured reasons: Claude resumed
from another directory re-files the conversation under that directory (§2.1);
codex opens a "Working directory" dialog (§2.2); pi asks to fork (§2.4). A
missing directory is a shell at home with a note, never a resume at home.

### 5.2 Nothing is answered

A dialog a harness opens on resume — Claude's folder trust, codex's hooks
review or directory choice, copilot's two consents, pi's fork question — is
left on screen. roost does not detect it from the screen and does not report
it as `blocked`: those dialogs fire no hook, and a guess from the screen is the
#38 lesson. The restore report says how many agents were launched; `roost
status` shows which have badged since; a pane that has not is the one to look
at. `roost answer` stays a person's verb and gains nothing here.

### 5.3 Badges, and why #105 is not a prerequisite

A badge is a pane option. The server died, so **no pane option survives a
reboot**: there is nothing stale to read. Restore writes `@roost-name`,
`@roost-was` and nothing else; identity is re-stamped by the harness's own
first event (measured on all four: the resumed pane had no `@agent_state`
until then). The shape's `state` key is for a reader's eyes and is never
written back. So after a restore no badge can read as live that is not.

#105's two halves stay their own change: refusing a report from outside the
pane's tree does not touch restore, and marking a pane whose process is gone
would, after a restore, only ever mark a pane whose **resume** died — a real
want, not a prerequisite. One thing restore does take from #105's thinking:
a pane whose harness exited at once (a resume that failed, exit 1) is noticed
by `pane-exited` on a spawned pane and reads as gone; on a shell pane the
shell has the terminal back and `wait-done` already exits 2 (#64). **Step 4
of the turn-over design (#105) need not land first.**

### 5.4 Addressing after a restore: the map, and Claude's free note

The incident's third lesson. Three things, and the design picks all three
because each covers a case the others do not:

1. **`@roost-was %OLD`** on every restored pane. `roost status --json` gains
   `was` (null when none). A person or a coordinator who knows the old id
   finds the pane.
2. **The alias map**, `shapes/<server>/aliases/<new boot>`, one `%OLD %NEW`
   per line, written by restore. Every verb that resolves a target (`send`,
   `read`, `wait-done`, `screen`, `answer`, `close`, `revive`, `forget`) tries
   tmux first; when `%N` names no pane on this server and the map for **this
   boot** has it, the verb uses the new id and prints one stderr line, `roost
   send: %930 was restored as %34`. The map is read only for this boot's file,
   so a stale map from an older restore can never redirect a send. It lives as
   long as the server's shape directory does; a new restore writes a new file.
   Cost: one file read, only on the failure path tmux already took.
3. **Claude learns its new id for free.** `scripts/roost-session-context`
   injects "This pane is %NEW" at `SessionStart`, which fires on resume (§2.1).
   No other harness has a context hook roost wires, so the other four are
   **not** told; sending them a note would start a turn and spend tokens, and
   the map makes it unnecessary. A coordinator that wants its helpers told
   can `roost send` them itself.

A stable name per pane already exists: `@roost-name`. What does not exist is
addressing a pane **by** it, and this design does not add that (a window name
is already a target; a pane name would need a new target grammar). The map is
the answer to the incident; the name is the answer to a human reading
`status`.

### 5.5 Pacing and selection

`--pace` defaults to 2 s between resumes (what the incident script used on a
machine that had just booted, and which worked). Shells first, so the whole
placement is on screen in a second and the slow part is visible as it goes.
`--recent DAYS` and `--only SEL` (§4.3) choose; the default is everything the
shape holds, because the shape only ever holds what was open — the incident's
"recent versus all" came from reading Claude's whole history, not from a
shape. Memory per resumed agent is *not measured*; the incident's 35 were "too
heavy" without a number.

### 5.6 A pane with a harness and no key

The 13 Claude panes of §2.6, and every codex pane under #145. Restore places
the shell in its directory and prints `roost restore: %34 ran claude with no
recorded conversation; roost revive %34 cannot resume it`. For Claude, if
**§9 Q4** is answered A, restore (and `revive`) also prints the one command
the fallback would run — `claude --resume <newest id under
~/.claude/projects/<cwd>>` — and the person runs it. The fallback is never
run by roost: the newest transcript in a directory with several panes is a
guess, and a guessed resume into the wrong pane is what §5.1 exists to stop.

### 5.7 codex: one restore, one badge

Measured (§2.2): a resumed codex TUI's hooks run in the app-server the first
codex started, with that pane's `TMUX_PANE`. After a restore of several codex
panes, every codex badge lands on the **first restored codex pane**. roost
cannot fix that here; #145 owns it. The restore report says so when more than
one codex pane was resumed: `N codex panes resumed; until #145 their badges
all land on the first (…)`.

### 5.8 What roost never does

Store a transcript or a reply in the shape; answer a dialog; restore a badge;
restore scrollback; resume into a directory other than the saved one; merge
into a session that exists; start a service without `persist on`.

---

## 6. Build order

Each step ships alone and is worth something alone. Sizes are airig's.

| step | what | size | worth by itself |
|---|---|---|---|
| 1 | `roost save`, the shape format and its refusals, `roost restore` **placement only** (sessions, windows, layouts, names, directories), `--dry-run`, `--list`, `--only`, exit 12/16; the §2.7 `select-layout` probe first | M | #51 as written: the guess of lesson 2 is gone; a fleet's shape can be moved between machines by file |
| 2 | `roost revive TGT` with the resume table in the adapters' library (`scripts/lib/roost-resume.sh`, beside `roost-close.sh`), `respawn-pane -k`, the gone-pane path from the record, exit 13/14/15; the opencode existence check or an honest "not measured" refusal | M | #57: kill a pane, get the conversation back, same `%N` |
| 3 | restore resumes: §4.3's resume loop, pacing, `--recent`, `--no-resume`, `@roost-was`, the alias map and its use in every target-taking verb, `status --json` `was`, the codex note | M | lessons 3, 4 and 5 answered; a manual `roost restore` after a reboot does the whole job |
| 4 | save on change: the hooks in `tmux/roost.conf`, the direct calls in `spawn`/`split`/`view`/identify, the history ring and the shrink rule, the two cost measurements of §3.4, the §4.5 doctor warnings about saving | S | nobody has to remember `roost save`; a crash loses one change at most |
| 5 | `roost persist on/off/status`, the launchd plist and systemd unit, `--at-login`, `login.log`, `roost upgrade` rewriting the unit, the §4.5 doctor line, and the §8.2 human-eye reboot on macOS then Linux | M | #192: the fleet is back after a reboot without being asked |
| 6 | the Claude fallback of §5.6 (if Q4 = A), printed only | S | the 13 panes of §2.6 are not lost silently |

#145 (codex identity under the app-server) is **not** in this list; it is the
one thing that would make codex restore whole, and it is its own issue.

---

## 7. Changes to existing surfaces

- `status --json`: `was` on every pane (null when none); `schema` stays 1
  (additive). `status` human output: a `(was %930)` suffix on a restored pane
  for the server's first hour? No — a suffix on every restored pane, always;
  it is one word and it is the lesson.
- Every target-taking verb: the alias-map fallback (§5.4), one stderr line.
- `tmux/roost.conf`: the hooks of §3.4 in slot `[98]` style, next to the
  events hooks, same `run-shell -b … || :` shape.
- `bin/roost spawn|split|view`: one `roost save --auto` call after the name
  is stamped. `roost identify` and the two identity hooks: the same call
  behind `ROOST_IDENTITY_WROTE=1`.
- `roost doctor`: §4.5. `roost help`: the five verbs, the shape path, the
  bounds (`ROOST_SHAPE_KEEP`, `ROOST_SHAPE_DIR`), and that `rm -rf
  ~/.local/state/roost/shapes` forgets every shape.
- `roost upgrade`: when `persist` is on, rewrite the unit to the new checkout
  path and reload it; say so.
- `site/content/docs/using-roost.md` or a new `persistent-sessions.md`: the
  verbs, the file, what is and is not restored (#51 requirement 3: say plainly
  that conversations belong to the harness), and the dialogs a resume can open
  per harness (§2.8).

---

## 8. Test plan

### 8.1 Automated (the suite, CI on both platforms, a container before the PR)

A new `tests/test-shape.sh`, with the `roost_test_tmux_named_guard` pattern of
`tests/lib.sh` because this is the first suite file that must use a **named**
server (`-L` is the production shape, and §3.1 keys on the name): `TMUX_TMPDIR`
at a throwaway directory, `HOME`, `XDG_STATE_HOME`, `XDG_CONFIG_HOME`,
`ROOST_RECORD_DIR`, `ROOST_SHAPE_DIR` at temp directories, the install test's
canary on the real paths. No real harness: panes run `sh`, and a "harness" is
a stub on `PATH` named `claude` that records its argv and `cwd` to a file
and sleeps — so the resume **command** is asserted, not a model.

Red tests:

1. Build 2 sessions, 3 windows, 5 panes with names, directories and a split
   layout; stamp identity on two panes with `roost identify`; `save`; kill the
   server by its socket path; `restore`; `status --json` before and after
   compare on `session`, `window_name`, `window_index`, `pane_index`, `name`,
   `cwd`; the layout string compares; the shape file is byte-stable across
   `save` twice with no change.
2. Restore into a server where one saved session exists: it is skipped and
   named, exit 12, the other sessions placed, nothing added to the live one.
3. A pane whose `cwd` was removed: a shell at `$HOME`, the stderr line, not
   resumed, exit 13 when it had a key.
4. Resume: the stub `claude` is run with `--resume <id>` in the saved
   directory, 2 s apart (two agents, timestamps in the stub's file ≥ 2 s
   apart); `--no-resume` runs it zero times; `--recent 0` with an old
   transcript mtime runs it zero times; `--only SESSION` restores one session.
5. Hand-edited file: a deleted pane block is not restored; a renamed session
   is created under the new name; `roost-shape 2`, a block with an unknown
   word, and a value with a tab each refuse with exit 16 naming the line and
   create **nothing** (a listing before and after).
6. `revive %N` on a live stub pane: `respawn-pane` keeps the id (same `%N`
   before and after), the stub ran with `--resume <id>` in `cwd`; on a
   `working` pane: refused, exit 1, the agent untouched; on a gone `%N` with a
   record: a new window, `@roost-was`; no key: exit 13; harness off `PATH`:
   exit 14; `cwd` gone: exit 15.
7. The alias map: after a restore, `roost send %OLD "x"` reaches the new pane
   and prints the stderr line; `read %OLD` reads it; a `%OLD` not in the map
   gives today's exit 2; a map file from another boot is ignored.
8. Save on change: `spawn`, `split`, `rename-window`, `kill-pane`, `identify`
   each produce a new `shape` (mtime or content); 50 `roost state working`
   calls on a working pane produce none; `window-layout-changed` alone
   produces none; `history/` holds at most `ROOST_SHAPE_KEEP`; the shrink
   rule picks the save before a chain of smaller saves within 30 s.
9. `persist on` with `ROOST_PERSIST_WRITE_ONLY=1` (a test seam: write the
   unit, do not load it) writes a plist on macOS and a unit on Linux whose
   contents name this checkout, the server, and the caller's `PATH`; `off`
   removes it and leaves `shape` and `history/`; `status` reads it back;
   neither `launchctl` nor `systemctl` is called (a stub on `PATH` that fails
   loudly if called).
10. Degrade: `ROOST_SHAPE_DIR` relative or empty saves nothing and every hook
    still exits 0 within 5 s; a read-only shape directory makes `save --auto`
    silent and `save` exit 1.

Guards: byte-identical `status --json` for a server that was never restored
except `"was":null`; the record tests still pass with shapes on; the canary
`HOME` stays empty.

Mutations that must turn a test red: drop the `select-layout` (1); merge into
an existing session (2); resume in `$HOME` when `cwd` is gone (3); no pacing
(4); `mv -f` without `mktemp` (10's partial-file case); read the alias map
without checking the boot (7); save on `after-set-option` (8); load the unit
in a test (9).

Live, by hand, not in the suite, under `tests/live/`: `revive-smoke.sh` runs
`revive` against real Claude through the fake API rig and asserts the resumed
pane re-identifies the same id (the §2.1 shape); the codex, copilot and pi
smoke files each gain one resume case, and the codex one kills its own
app-servers by environment, as the probe did.

### 8.2 Human-eye, listed together

1. **A real reboot on macOS** with `persist on`: log in, `roost`, the same
   sessions, windows and names are there; each Claude pane is at its prompt
   with its conversation; `login.log` says what was chosen and why. Count the
   dialogs that opened and which harness opened them.
2. **A real reboot on Linux** (a VM is fine): the systemd unit ran, the same
   checks; without linger the unit starts at login, not at boot.
3. **The shutdown chain** (§3.5): after the macOS reboot, `roost restore
   --list` shows whether saves landed in the final seconds and whether the
   shrink rule picked the right one. This decides whether the rule stays.
4. **Claude's credentials under launchd**: a resume at login may hit the
   Keychain before the user has unlocked it, or prompt for Keychain access.
   What appears on screen, and whether the first-attach deferral (§9 Q1 B)
   avoids it.
5. **`roost upgrade` with `persist on`**: the unit follows the checkout.
6. **The codex note** (§5.7) with two real codex panes after a restore: the
   badges land where the note says they do.
7. **Reading the file**: a person opens `shape` cold and can say what the
   fleet was; edits one `cwd`; `--dry-run` says what they meant.

---

## 9. Decisions

Each with option A (the proposal) and B, and one line of why.

**Decided by the human on 2026-10-24: A, A, A, A.** Agents resume on first
attach, not at login (Q1); a manual restore resumes by default (Q2); the
saved shape lives under `XDG_STATE_HOME` (Q3); a Claude pane with no recorded
id gets a printed, never-run resume line (Q4).

**Q1. When do agents come back after a reboot?** Decided: A.
- **A.** `persist` restores **placement** at login and resumes agents when a
  person first attaches to that server (`roost`, `roost session NAME`), paced;
  `roost restore --resume` does it by hand any time.
- **B.** Everything at login, paced 2 s apart, with nobody watching.
- Why: a dialog on resume needs a person present (§5.2), a machine that just
  booted needs the headroom (lesson 4), and a Keychain prompt at login (§8.2
  item 4) is the kind of surprise that turns a feature off.

**Q2. Does a manual `roost restore` resume agents by default?** Decided: A.
- **A.** Yes: every pane with a recorded conversation is resumed; `--no-resume`
  places shells only.
- **B.** No: shells only; `--resume` opts in, as #51's text said.
- Why: a resume costs no tokens until a prompt is sent (measured: four
  harnesses sat at their prompt), #191's done line says "each agent resumed",
  and the fleet of shells is what the incident called useless; B is #51's
  original caution about cost, which the measurement removes.

**Q3. Where does the saved shape live?** Decided: A.
- **A.** `${XDG_STATE_HOME:-~/.local/state}/roost/shapes/<server>/`, beside the
  pane records and the event log, one `rm -rf` to forget everything.
- **B.** `${XDG_CONFIG_HOME:-~/.config}/roost/shapes/<server>/`, beside
  `roost.conf`, because a hand-editable file reads as config.
- Why: it is written by hooks many times a day and is history as much as
  intent, which is state; but it is the one roost file a person is invited to
  edit, which is config. Not beside the socket: `/tmp` does not survive the
  reboot the file exists for.

**Q4. A Claude pane with no recorded id (13 of 32 today, §2.6): fall back to
Claude's own store?** Decided: A.
- **A.** Print, never run: restore and `revive` show `claude --resume <newest
  id under ~/.claude/projects/<cwd>>` for such a pane and a person decides.
- **B.** No fallback: the pane is a shell in its directory with a note, and
  the fix is that identity now records every new session.
- Why: the incident recovered exactly these panes from that store, and the
  13 will exist until each is restarted; but the newest transcript in a
  directory with several panes is a guess, and roost does not resume on a
  guess.

**Decided, not asked**, because #191 decided it: persistence is **off until a
person runs `roost persist on`**, and `roost doctor` says which it is.

---

## 10. Out of scope, and risks

Out of scope, named so nobody reads them as forgotten:

- **A committed fleet file** (the 2026-09-21 comment on #51: one format for
  "save" and for "a teammate clones and runs one command"). The shape format
  is designed so it *can* be that file — `save --to` writes it, `restore
  --from` reads it, paths are the only machine-specific part — but a fleet
  file needs commands to launch, not conversations to resume, and that is a
  design of its own once this one is built.
- **Hibernate** (the 2026-09-21 comment on #57): end an idle agent, keep the
  key, resume on the next `send`. `revive` is the half it needs; the other
  half is a policy.
- **#145**, codex identity under the shared app-server. Without it codex
  restore is placement plus the rollout fallback.
- **Minting ids at spawn.** Works on three harnesses (§2.8); not needed while
  #141 records what the harness chose.
- **Restoring scrollback, badges, replies into the pane.** Replies are in the
  record already (`read %OLD` through the map still reads them, §5.4).
- **`roost ssh` remotes.** A remote's server is a server; `persist on` there
  is run there. Nothing here reaches across hosts.

Risks, most serious first:

- **Hooks during shutdown may save a shrinking fleet** (§3.5). *Not measured.*
  The history ring and the shrink rule are the mitigation; §8.2 item 3 decides
  whether the rule is right. Severity: high until measured — it is the one
  path that could make `persist` restore nothing after the very event it is
  for.
- **A resume into a dialog nobody sees** at login (§5.2, §9 Q1). The restore
  report and `status` are the only signals.
- **codex badges all land on one pane after a restore** (§5.7). Known, owned
  by #145, announced in the report.
- **opencode `-s ID` creates a session when the id is unknown** (§2.5). The
  adapter must check first; until measured, `revive` on opencode prints the
  command and asks the person to run it.
- **launchd's environment** is not the shell's: a `PATH` captured at `persist
  on` goes stale when a harness moves (a brew upgrade of codex moved its
  app-server already, known-gaps). `doctor` warns when the unit's `PATH` lacks
  a harness the shape names.
- **`select-layout` with a saved string** is inferred from the manual (§2.7).
  If it does not take the string back, step 1 falls back to splitting with
  `-p` percentages derived from the layout string, which is more code.
- **The 13 unidentified Claude panes** stay unidentified until each restarts;
  nothing here can reach into a running Claude to ask. Q4 is the only help.
