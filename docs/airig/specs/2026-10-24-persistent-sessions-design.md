# Persistent sessions: a roost fleet survives a reboot — design for #191 (#57, #51, #192, #105)

Status: **revision 1, 2026-10-24. Nothing built.** The four questions in §9
were decided by the human (A, A, A, A) and stand; revision 1 answers the
twelve blocking items of a three-reviewer read (§0) without moving any of
them, and says in Q1's own text where a fix changed what A means in practice.
Base: `main` at `83812b1`.

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

## 0. Revision 1: the twelve blocking items and where each is answered

Three reviewers read the draft after studying how other terminal tools handle
persistence (§11). Twelve items blocked; none argued against a §9 decision.

| # | item | answered in |
|---|---|---|
| 1 | concurrent saves publish an older snapshot last; one-second history stamps collide | §3.5 (one saver, `want`, `gen`), §8.1 test 8 |
| 2 | the shutdown "shrink" rule restores panes a person closed; a ten-entry ring cannot hold a fleet's teardown | §3.6 (`trigger`, ring of 100, the shutdown record), §8.1 test 8 |
| 3 | the resume directory has two sources and each is wrong in a case seen live | §3.2 `session_cwd`, §5.1, §8.1 test 4 |
| 4 | the shape trusts identity known to be wrong (a nested `codex exec`, an exited agent) | §3.2 stale keys, §5.6, §8.1 test 4 |
| 5 | a resume whose key the harness no longer holds kills the pane | §5.1a (the store check, `remain-on-exit failed`), §8.1 tests 4 and 6 |
| 6 | a detached server is 80x24, so the fourth stacked split fails | §4.3 Windows, §2.7, §8.1 test 1 |
| 7 | the systemd unit kills the server it restores; `persist off` ends a live fleet | §4.4, §8.1 test 9, §8.2 item 2 |
| 8 | one shared systemd template for every server: `off` for one removes all | §4.4 (per-server units), §8.1 test 9 |
| 9 | the login service may read a different state root | §4.4 `service.env`, §8.1 test 9 |
| 10 | the bootstrap session, or a `roost` typed before the login restore, collides with the saved session | §4.3 Server and Sessions, §4.6, §8.1 test 2 |
| 11 | placement-first (Q1 A) has no durable place for the pending resume keys | §4.6 (the pending record, `--resume`, `client-attached`), §9 Q1, §8.1 test 11 |
| 12 | old-to-new pane-id aliases collide inside the new boot | §5.4 (`was:%N`), §8.1 test 7 |

Every non-blocking item is triaged in Appendix A. §11 records what the review
learned from other tools, area by area.

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
   takes a target accepts an old id through `was:%OLD`. Claude also learns its
   new id for free (§2.1, SessionStart).
4. **Restoring 35 agents at once was too heavy.** → §5.5: 2 s between
   resumes, agents after shells, `--recent` and `--only` selectors, and §9 Q1
   on whether agents come back at login or when a person first attaches.
5. **Some conversations came back outside their roost session.** → §5.1: a
   resume runs only in its own saved session and window, in the directory
   its transcript belongs to; a missing directory gives a shell and a note,
   never a resume somewhere else (§2.1 measured why).

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
  three through `roost identify`. Two known gaps (`docs/known-gaps.md`,
  "A nested headless agent replaces the pane's identity" and "The identity
  outlives the agent") mean an identity option can name a harness the pane is
  not running; §3.2 checks for that at save time.
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
  version string), else `@roost-name`. The resume table (§2.8) sits beside it,
  and §3.2's agreement check reuses its command table.
- **Wiring** (#58): a server started by `bin/roost` sets `default-command` to
  `scripts/roost-pane-shell`, and a command handed to `spawn` or `split` goes
  through it. A restored pane's command must go through it too (§5.1).
  `roost-pane-shell` `exec`s its command, so a command that exits takes the
  pane with it — the fact behind §5.1a.
- **`ensure_session`** (`bin/roost`): starts a stopped server with
  `new-session -d -s NAME -c $PWD` and no `-x`/`-y`, wires it, and respawns the
  first pane through `default-command`. §4.3 builds a restored server the same
  way, with the size added, and §4.6 teaches it to wait for a login restore.
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
measured*. Claude's documentation says local transcripts are kept for 30 days
by default (`cleanupPeriodDays`), so a pane idle for a month resumes into the
exit 1 above — the everyday case behind §5.1a. *Not measured* here: whether
`--resume` keeps the model and permission mode the pane was started with
(Appendix A, the launch-flags row; a step 2 probe).

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

The review read two more panes on the same server, with `list-panes -F` and
`show-options -pqv` only, and both shape §3.2:

- One Claude pane's `#{pane_current_path}` is the repository root, its
  `@roost-cwd` is a worktree that has since been removed, and its
  `@roost-transcript-path` is filed under the **root** project. The shell
  moved; the conversation did not. Resuming it in `@roost-cwd` would re-file
  the conversation (§2.1) or refuse because the directory is gone.
- One pane runs Claude (its command is the version string) but carries
  `@roost-harness codex` and a codex session id from a `codex exec` its
  Claude ran — the nested-agent gap of known-gaps (#77). A restore that
  trusted those options would run `codex resume` in a scratchpad directory and
  lose the Claude conversation.

### 2.7 tmux facts this design rests on

- **A full listing is cheap.** `list-panes -a -F …` with the eleven fields the
  shape needs took 5 ms on the live server (47 panes); `list-windows -a`,
  4 ms. A save is one listing and one `mv` (§3.4 costs it).
- **Hooks available** on tmux 3.6, from `tmux(1)`: every command has an
  `after-<command>` hook (`after-new-window`, `after-split-window`,
  `after-new-session`, `after-rename-window`, `after-rename-session`,
  `after-kill-pane`, `after-kill-window`, `after-kill-session`,
  `after-respawn-pane`, `after-move-pane`, `after-join-pane`,
  `after-break-pane`, `after-swap-pane`, `after-move-window`,
  `after-swap-window`, `after-link-window`, `after-select-layout`,
  `after-resize-pane`), plus `pane-exited`, `pane-died`, `window-unlinked`,
  `window-renamed`, `session-closed`, `session-renamed`,
  `window-layout-changed`, `client-attached`, `client-detached`. The `after-*`
  hooks exist on tmux 3.2 too (the floor roost checks); `window-layout-changed`
  fires on every resize and is **not** used (§3.4).
- **A death and a kill fire different hooks** (measured on a throwaway
  socket, tmux 3.6, once): a process that exits on its own fires
  `pane-exited` and not `after-kill-pane`; `kill-pane` fires `after-kill-pane`
  and not `pane-exited`; `kill-window` fires `window-unlinked`. At
  `pane-exited` time the pane is already out of `#{window_panes}` and its pane
  options are no longer readable in the hook's format. §3.6's `trigger` key
  rests on the first fact; the third is why `roost close` saves for itself.
- **Pane ids restart at `%0`** on every server start and the boot key
  `#{start_time}-#{pid}` tells servers apart (pane-record M1, M3). A saved
  `%N` is history, never an address.
- **`respawn-pane -k` keeps the pane id** and changes `pane_pid` (M3 case 6).
  That is what lets `roost revive` on a live pane keep its `%N`. It also
  keeps every pane option, which is why §4.1 clears them.
- `#{pane_current_path}`, not `#{pane_path}`, carries the directory (M1).
- **`select-layout` takes a saved `window_layout` string back** (measured,
  once, tmux 3.6): with the same number of panes it applies, and the pane ids
  embedded in the string are ignored — the restored window's string differs
  from the saved one only in the ids and the leading checksum. With fewer
  panes: `have 2 panes but need 3`, nothing changes. With more: the extra
  panes keep a default layout, no error. A string whose number was edited by
  hand, or whose checksum was removed: `invalid layout`. The zoomed state is
  not in the string (`window_zoomed_flag` is separate). So restore creates
  exactly the saved pane count before `select-layout`, compares geometry with
  ids and checksum stripped (§8.1 test 1), and saves `zoomed` on its own.
- **A detached server is 80x24** (measured, once): `new-session -d` with no
  `-x`/`-y` gives an 80x24 window, and splitting the active pane in halves
  stops at four panes (`no space for new pane`). With `-x 381 -y 86` the same
  halving stops at six, and `split-window -l 2` on 24 lines stops at two,
  because each split halves (or shrinks) the pane that was just made. The
  limit is the pane being split, not the window: §4.3 sizes the session from
  the saved layout and splits the **largest** pane each time.

### 2.8 The resume table

What each adapter's resume step runs, where the key comes from, how the key
is checked before anything is launched (§5.1a), and what to expect on screen.
The exit column is `scripts/lib/roost-close.sh`'s table.

| harness | resume by id | key recorded by roost today | store check before launch | source if roost has no key | on resume | dialogs a resume can open | exit |
|---|---|---|---|---|---|---|---|
| claude 2.1.310 | `claude --resume ID` in the transcript's directory (§5.1) | `@roost-session` at SessionStart; record `session_id` | the recorded transcript file exists, else `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<cwd encoded>/<id>.jsonl` exists | `~/.claude/projects/<cwd encoded>/*.jsonl`, listed newest first (printed, never run: §5.6) | prompt in 1 s (fake API), conversation on screen, same id | folder trust in an untrusted directory | `/exit` |
| codex 0.163.0 | `codex resume ID` in the session's directory | **none** under the shared app-server (#145) | a `$CODEX_HOME/sessions/**/rollout-*-<id>.jsonl` exists | the rollout files whose `session_meta.cwd` is the pane's cwd, newest first (printed, never run: §5.6) | prompt in 1 s, conversation on screen | "Working directory · resume" when the directory differs; "Hooks need review" when roost's hooks are not yet trusted | `/quit` |
| opencode 2.1.3 | `opencode -s ID` | `@roost-session` via `roost identify` (tested, not run live) | `opencode session list` names the id — *not measured*; until it is, roost **prints** the command and does not run it | none usable: a database | *not measured*; **creates** the session if the id is unknown | *not measured* | `/exit` |
| copilot 1.0.103 | `copilot --resume=ID` (any directory; it returns to the session's own) | `@roost-session` via `roost identify` | `$COPILOT_HOME/session-state/<id>/` exists | `$COPILOT_HOME/session-state/*/workspace.yaml` naming the cwd (printed) | prompt in 9 s, conversation on screen, same id | folder trust and extension permission on a home that has not answered them | `/exit` |
| pi 0.81.1 | `pi --session PATH` (the recorded transcript), else `pi --session ID` in the session's directory | `@roost-session` and `@roost-transcript-path` via `roost identify` | the recorded session file exists, else `$PI_CODING_AGENT_DIR/sessions/--<cwd encoded>--/*_<id>.jsonl` | the same directory, newest first (printed) | prompt in 5 s, conversation on screen, same id | "Fork this session into current directory?" when the id is used from another directory | `/quit` |

The store paths honour the harness home variables (`CLAUDE_CONFIG_DIR`,
`CODEX_HOME`, `COPILOT_HOME`, `PI_CODING_AGENT_DIR`), which is why §4.4
records them for the login service.

Minting works on three: `claude --session-id`, `copilot --session-id`,
`pi --session-id` all accept a UUID roost chooses, and identity records it
(measured). codex and opencode do not take one. This design does **not** mint
at spawn: #141 already records the id the harness chose, and a minted id buys
nothing a recorded one does not — except for codex, where recording is broken
(#145) and minting is not offered. The one thing minting would add is a
resume key before the first prompt; §5.6 covers a pane that has none.

### 2.9 What a fleet weighs

Read on the live machine with `ps -axo rss=,comm=`, once, 2026-10-24: 43
processes named `claude`, 12.0 GB RSS in all, mean 278 MB, largest 606 MB
(the review's own read an hour earlier: 34 processes, 11.2 GB, mean 338 MB).
These are long-running agents, not freshly resumed ones; a resumed agent's
RSS before its first prompt is *not measured* (a step 3 measurement, against
placement-only as the baseline, reported as a ratio with this method). What
this says about the incident: 35 agents at rest are about 11 GB on a 128 GB
machine, so what was "too heavy" at boot was 35 cold starts at once, which
pacing spreads, not the resident set, which pacing does not reduce (§5.5).

---

## 3. The saved shape

### 3.1 Where it lives

```
${ROOST_SHAPE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/roost/shapes}/<server>/
  shape               the newest save
  history/<stamp>-<gen>  the saves before it, newest ROOST_SHAPE_KEEP (default 100)  (§3.6)
  gen                 the save counter, one integer                                 (§3.5)
  want                present while a save is wanted and the saver is busy          (§3.5)
  lock/               the saver's mkdir lock, holding the saver's pid               (§3.5)
  restoring/          present while a restore is building panes                     (§3.5)
  aliases/<boot>      the old-id → new-id map of the restore that made boot <boot>  (§5.4)
  pending/<boot>/     the resume keys of panes placed but not yet resumed           (§4.6)
  persist             present when `roost persist on` has been run for this server (§4.4)
  service.env         the roots and homes the login service runs with              (§4.4)
  login/<os-boot>     present once the login restore has run on this OS boot        (§4.6)
  login.log           what each login restore did, 0600, truncated at 1 MB          (§4.4)
```

`<server>` is the socket **name** for a `-L NAME` server (`roost` for the
default), which is what survives a reboot: the socket file under
`/tmp/tmux-UID/` does not. A `-S PATH` server is keyed `path-<cksum of PATH>`
(`cksum` is POSIX and on every machine roost runs on), because writing `/` as
`-` is not injective — `/a/b-c` and `/a-b/c` collide — and the header's
`socket` line keeps the readable path. A test server therefore never shares a
key with the real one even when both are called `roost`, and every test
redirects `XDG_STATE_HOME` anyway, as the record tests do.

The state directory, beside `panes/` and `events/`, because it is machine
written state and `rm -rf ~/.local/state/roost` already means "forget
everything roost remembered" (§9 Q3, decided A). What that forgets is the
shapes, the pending keys and the alias maps; the pane records beside them are
their own store, and every conversation stays in its harness's store
untouched. `ROOST_SHAPE_DIR` overrides the whole path for tests; it must be
absolute, and empty means "save nothing", the rule `ROOST_RECORD_DIR` already
has. The directory is created 0700 and every file in it is 0600 — `mktemp`
makes it so and a hard link keeps it, the record's rule — because the shape
lists every project directory, every session id and every transcript path,
and a session id alone is enough to `--resume` a conversation on a shared
machine.

### 3.2 The format

Plain text, one `key value` per line, blocks separated by a blank line, read
in bash 3.2 or dash with `IFS= read -r line`, the key as `${line%% *}` and the
value as `${line#* }` — no JSON parser, the rule the pane record chose and the
reason it chose it. A value is **everything** after the first space, kept
byte for byte: it may hold spaces, leading or trailing, and `=`; it may not
hold a newline, a tab or a control character, which is exactly what
`roost_identity_valid` already refuses. A key repeated inside one block is a
refusal (a hand-edit error, never something roost writes). Paths are
absolute. The file is UTF-8.

```
roost-shape 1
server roost
socket /private/tmp/tmux-501/roost
boot 1792526903-7170
saved 2026-10-24T20:51:02Z
gen 4182
trigger after-split-window
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
session_cwd /home/me/w/roost
harness claude
session_id 3fa32375-68cd-43c9-8bcf-fbb876b2db1e
transcript /home/me/.claude/projects/-home-me-w-roost/3fa32375-68cd-43c9-8bcf-fbb876b2db1e.jsonl
launch claude --model opus
command 2.1.310
state done
active 1

pane roost:1.2
id %91
name linkedin
cwd /home/me/w/roost
command zsh

pane roost:1.3
id %90
name nested
cwd /home/me/w/roost
session_cwd /tmp/claude-501/scratch
stale_harness codex
stale_session_id 01a16c68-7d1e-4f0a-9c34-2c1f2b7a9e10
command 2.1.310
```

Rules, each with its reason:

- **`roost-shape 1`** is the first line. The schema rule is the pane record's:
  adding a key or a block type never moves the number; a reader ignores keys
  it does not know and **skips a block whose first word it does not know,
  with one stderr line naming the line** (so a later roost's `parent` grouping
  or a fleet file's `command` block does not make an older roost refuse an
  additive file); the number moves only when an existing key or block changes
  meaning. A restore that finds a larger number, or no readable first line,
  **refuses and names the fault** and changes nothing (#51 requirement 7:
  never half-restore).
- **The header** carries `gen` and `trigger` (§3.5, §3.6) beside the stamp.
  Two saves are **the same** when everything after the header block is byte
  identical; the header alone never makes a save worth writing.
- **A block starts with `session`, `window` or `pane`** and its address;
  `window` is `SESSION:INDEX`, `pane` is `SESSION:WINDOW_INDEX.PANE_INDEX`.
  Indices are what tmux recreates, **at the saved index** (`new-window -t
  SESSION:INDEX`), so a sparse set and a `base-index` other than 0 come back
  as saved; the saved `id` is kept only for §5.4's map and for `revive`,
  never used as a target. Before the first tmux command, restore checks every
  window names a session block and every pane a window block, and that no
  address repeats.
- **Every pane block has `cwd`**, the shell's directory (`#{pane_current_path}`);
  it always exists. **`session_cwd`** is `@roost-cwd` when set: the directory
  the harness reported at its session start. The two differ when the shell
  moved after the agent started (§2.6's first live case), and §5.1 says
  which one a resume uses. `name` is `@roost-name` when set.
- **`harness`, `session_id`, `transcript` are written only when the pane's
  command agrees with the harness.** The agreement table is
  `roost_close_harness`'s: Claude is its version string, codex is `codex`; for
  pi, copilot and opencode what `#{pane_current_command}` reads is *not
  measured* (a step 1 probe) and until then those three pass on presence
  alone (§10 names the risk). When the command is a shell (`sh`, `bash`,
  `zsh`, `fish`, `dash`) the agent has exited; when it is another harness's,
  the identity is a nested agent's (§2.6's second case). In both cases the
  keys are written as **`stale_harness`, `stale_session_id`,
  `stale_transcript`**, so a reader sees what the pane last reported, and
  restore prints them and **never resumes them** (§5.6). The keys are
  **absent, not empty, otherwise**: a reader tests presence.
- **`launch`** is the command roost itself handed to `spawn`, `split` or
  `view` (kept in `@roost-launch` at that moment), with any `WORD=value` whose
  name contains `KEY`, `TOKEN`, `SECRET` or `PASSWORD` replaced by
  `WORD=…`. A hint for a person and for the restore report (§4.3), **never
  run** by restore: it is what the pane was started as, not what it is.
  Absent for a pane roost did not start.
- **`command`** is `#{pane_current_command}`, a **hint** only (pane-record M2:
  it is not stable), kept so a Claude pane with no identity can still be
  recognised by its version string. `state` is `@agent_state` at the save and
  is **never restored** (§5.3); it is there so a person reading the file
  knows what the fleet was doing, and so the report can say which agents
  were mid-turn (§4.3).
- **`zoomed 1`** on a window block when `#{window_zoomed_flag}` is set; the
  layout string does not carry it (§2.7).
- **`parent`** (reserved, #99): `@roost-parent` when that lands. Not written
  until then.
- **Nothing a harness owns is in the file**: no transcript bytes, no replies,
  no scrollback. The record keeps replies; the harness keeps conversations.
- **Nothing in the file is ever evaluated.** A harness name is looked up in
  the adapter table or refused; a session id must pass the adapter's own
  shape (a UUID for four of them); a directory is passed as an argument. A
  shape is data, from a file a person may have edited or copied from another
  machine.
- **Hand-editable** means a person **copies** `shape`, edits the copy, and
  runs `roost restore --from COPY` — because the next auto save overwrites
  `shape` itself. In the copy they can delete a pane block to not restore it,
  change a `cwd`, or rename a session (its windows' and panes' addresses must
  be renamed with it, or the check above refuses), and `--dry-run` shows the
  result. A value with a control character, a repeated key, or an address
  with no parent is a named refusal of the whole file (requirement 7 again).
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
because the pane option died with the pane. One more source: a pane placed by
a login restore and not yet resumed has no identity option, and `save` reads
its keys from the pending record (§4.6), so a shape written in that gap keeps
them.

### 3.4 When it is written, and what it costs

**On change, not on a timer** (#192). Two kinds of writer, both running
`roost save --auto --trigger NAME` for the server they are on:

| event | mechanism | why this one |
|---|---|---|
| a session is created or closed, renamed, killed | `after-new-session[98]`, `session-closed[98]`, `after-rename-session[98]`, `after-kill-session[98]` | placement changed |
| a window is created, killed, unlinked, renamed, moved, swapped, linked | `after-new-window[98]`, `after-kill-window[98]`, `window-unlinked[98]`, `after-rename-window[98]`, `after-move-window[98]`, `after-swap-window[98]`, `after-link-window[98]` | placement or a name changed |
| a pane is split, exits, is killed, respawned, moved, joined, broken out, swapped | `after-split-window[98]`, `pane-exited[98]`, `after-kill-pane[98]`, `after-respawn-pane[98]`, `after-move-pane[98]`, `after-join-pane[98]`, `after-break-pane[98]`, `after-swap-pane[98]` | a pane came, went or changed place; `revive` uses respawn |
| a layout is chosen or a pane resized **by command** | `after-select-layout[98]`, `after-resize-pane[98]` | a person meant it; a drag fires `window-layout-changed`, which is not used |
| `roost spawn`, `split`, `view` set `@roost-name` | a direct call at the end of each branch in `bin/roost` | a name changed with no tmux hook for it |
| `roost identify` writes (`ROOST_IDENTITY_WROTE=1`) | a direct call in `roost_identity_stamp`'s caller, only when it wrote | the resume key changed; when nothing changed the one-read-then-bail path is untouched |
| `roost close` has seen the pane go | a direct call at the end of `close`, `--trigger close` | the removal was deliberate, and `pane-exited` cannot say so (§2.7, §3.6) |
| `roost restore` has finished building | one call, `--trigger restore`, after the `restoring` marker is removed (§3.5) | one coherent save for the whole restore instead of sixty |
| `roost persist on` | one call, `--trigger persist-on` | a fleet that is already running is saved the moment persistence is wanted |
| the user's own `roost save` | the verb, `--trigger save` | a person asked |

**Not** on `window-layout-changed` (every resize), not on `after-set-option`
(every badge), nothing on `PostToolUse`, nothing in `roost state`. A drag
resize alone is therefore saved only with the next event of any other kind —
a resize made and then nothing else before a crash restores the previous
layout. Accepted: a layout is the least of what was lost on 2026-10-20. A
shell that `cd`s has no hook either, so its `cwd` is stale until the next
event; accepted for the same reason, and said in the user page (§7).

**Saving is always on** once step 4 lands, with `ROOST_SHAPE_DIR=` the way to
turn it off. #191 decided that the **login service** is off until `roost
persist on`; the shape itself costs under 50 ms per structural event and is
what makes a hand `roost restore` after a crash possible with `persist` off,
which is #51 on its own. `persist on` saves at once (the table), so a fleet
enabled and then crashed needs no later event to be on disk.

**Cost.** Each hook runs `run-shell -b`, so the server does not wait. A save
is one `list-sessions`, one `list-windows -a`, one `list-panes -a` (4 to 5 ms
each on 47 panes, §2.7), a `mktemp`, a `printf` loop and one `mv`: *estimated*
under 50 ms per save on this machine, off every agent's path. Spawning ten
panes wants ten saves; §3.5 makes that one saver writing at most a few times.
The measurements step 4 must take: the time of `roost save --auto` at 47
panes; the time and the number of files written for a burst of ten spawns in
one second; and that 50 `roost state working` calls on a `working` pane write
no shape (the record test's hot-path shape).

**The two identity hooks are the only ones on an agent's path**, and both
already bail in one tmux read when nothing changed (#141); the save call is
behind the write, which is once per session start, or once per `/clear` or
resume.

### 3.5 One saver per server, and how it writes

Ten hooks firing in one second must not publish an older listing last, and a
restore that is building sixty panes must not have its own file rewritten
under it sixty times. So there is one saver at a time per server, and the
rest only say that a save is wanted:

1. `save --auto` touches `want`, then tries `mkdir lock`. If the lock exists
   it exits 0 at once: the saver that holds it will see `want`. A lock whose
   pid (written inside it) is dead, or that is older than 10 s, is broken and
   taken over — a saver killed mid-write must not stop every later save.
2. The saver loops: remove `want`; list the server; **check consistency**
   (every pane's window and session appear in the other two listings, else
   list again — the three listings can straddle a split or a kill); build
   the file; compare its body to `shape`'s body (§3.2: everything after the
   header); if the same, write nothing; else `mktemp` in the shape directory,
   write, hard-link the current `shape` into `history/<stamp>-<gen>`, `mv`
   over `shape` (rename(2), the record's rule), increment `gen`. Then, while
   `want` exists, loop again. `gen` is the counter that makes two saves in
   one second two distinct history names and orders them.
3. `rmdir lock`. Then one more look: if `want` appeared between the last loop
   check and the `rmdir`, try `mkdir lock` again and go to 2; if that fails,
   another saver has it.
4. While `restoring/` exists (restore makes it before its first tmux command
   and removes it after its last, with its pid inside and the same 10 s
   dead-pid rule), `save --auto` touches `want` and exits without taking the
   lock; restore's own final save (§3.4) is what publishes the result.

A reader never sees a partial file; the newest `shape` is always the newest
listing that differed from the one before; and a burst is a few writes, not
ten. The pending record (§4.6) is read inside step 2, so a pane with no
identity whose `%N` has a pending key is written with that key.

Rename gives atomic **visibility**, not durability through a power loss: roost
does not `fsync` (no portable way from bash short of `sync`, which is the
whole machine). A save made in the last second or two before power is cut may
not be on disk; the history has the one before it. Said here so nobody claims
more.

### 3.6 The history, and which save a restore picks

**Why a history.** When a machine shuts down, every process is signalled at
about the same time. If the tmux server handles some `pane-exited` or
`session-closed` hooks before it is itself killed, the newest save is a
**shrinking** fleet — a few shells, then nothing — and the save before the
teardown is the one worth restoring. Whether tmux runs any hook during a
macOS shutdown or a Linux `systemctl poweroff` is **not measured** (the tmux
source queues `session-closed` for every session on SIGTERM, so it is
plausible); §8.2 item 3 decides it at the first real reboot. A fleet of 38
panes in 13 sessions tearing down fires more than fifty hooks, so the ring
keeps **100** saves by default (`ROOST_SHAPE_KEEP`; a shape is a few
kilobytes and a hard link costs nothing), enough for a whole fleet to go and
the save before it to still be there.

**`trigger`** in every header says what caused the save (§3.4's table: a
hook name, or `spawn`, `split`, `view`, `identify`, `close`, `restore`,
`persist-on`, `save`). Four triggers are **process deaths**: `pane-exited`,
`pane-died`, `session-closed`, `window-unlinked`. Every other trigger is
something a person or roost did on purpose — `after-kill-pane`,
`after-kill-window`, `after-kill-session` are kills typed or scripted, and
`roost close`'s own save after the pane is gone carries `close` (§2.7: the
`pane-exited` hook cannot tell a `/exit` roost sent from one a person typed,
so `close` says it for itself).

**The reading rule.** A restore with no `--from` picks:

1. The newest `shape`, unless there is **shutdown evidence**: the OS records
   the last shutdown, and the newest save's `trigger` is a process death
   within the shutdown window.
2. With shutdown evidence: the newest save, walking back through
   `history/`, whose `trigger` is **not** a process death, or that is older
   than the window. Every kill, every `roost close` and every structural
   change a person made before the shutdown is in such a save; only an
   agent whose `/exit` a person typed inside the window comes back one time
   too many, at its prompt, spending nothing.
3. No readable shutdown record: the newest `shape`, and one stderr line,
   `no shutdown record readable; restoring the newest save — roost restore
   --list shows the others`.

The shutdown record, measured on macOS 26.3 once: `last reboot` prints
`shutdown time Tue Oct 20 15:05` above `reboot time Tue Oct 20 15:06`, minute
resolution, so the window is the shutdown minute and the minute before it;
`sysctl kern.boottime` gives the boot second. On Linux the sources are `last
-x shutdown` where wtmp exists and `journalctl --list-boots` where it does
not; *not measured*, a step 4 probe, and until it lands Linux takes rule 3.

`roost restore --list` shows every save with its stamp, `gen`, `trigger` and
counts and marks the one the rule would pick; `--from STAMP-GEN` picks one by
hand; the at-login restore writes which it chose and why to `login.log`.
Closing the **last** session ends the server, so "an empty fleet" is never a
save; a person who wants nothing back after a reboot runs `roost persist off`
or removes `shape`.

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

1. Resolve `TGT` (`%N`, `@N`, `[SESSION:]WINDOW`, or an old id as `was:%N`,
   §5.4). A live pane: read its `@roost-harness`, `@roost-session`,
   `@roost-cwd`, `@roost-transcript-path`, and `#{pane_current_path}`; a pane
   placed by a restore and not yet resumed: its pending record (§4.6); a gone
   `%N` on this boot: the record's `harness`, `session_id`, `cwd` (§3.3).
2. The identity does not agree with the pane's command (§3.2's rule — a
   Claude pane carrying a codex key, or a shell carrying anything): exit
   **13**, the keys printed as stale, nothing resumed. No harness, or no key:
   exit **13**, `roost revive: '%5' has no recorded conversation (harness
   claude, no session id)` — and for Claude the §5.6 line listing what the
   store holds for that directory, printed, not run.
3. The harness is not on `PATH`: exit **14**, naming it.
4. Choose the directory by §5.1. The directory is gone: exit **15**,
   `directory … no longer exists; not resuming elsewhere` (§2.1: Claude would
   silently re-file the conversation).
5. **Check the store** (§5.1a, the column in §2.8). A miss: exit **13**,
   `roost revive: claude no longer holds 3fa3…; the pane is untouched`,
   and the pane is untouched — nothing has been killed yet. A key a live pane
   on this server already carries in `@roost-session`: exit **13**, naming
   that pane; one conversation is never open in two panes.
6. Build the command from the resume table (§2.8), through
   `scripts/roost-pane-shell` on a wired server, as an argv, never a string
   for a shell.
7. A live pane: clear every option the old process owned — `@agent_state`,
   the identity four, the reply and job options the record library writes —
   because `respawn-pane` keeps options (§2.7) and a resume into a trust
   dialog fires no hook that would overwrite an old `done`; keep
   `@roost-name`. Set `remain-on-exit failed` on the pane, then `respawn-pane
   -k -c CWD` — the pane keeps its `%N` (§2.7), so nothing that addresses it
   breaks. Refused on a `working` or `blocked` pane unless `--force`, the
   `close` rule, because `-k` kills the agent mid-turn. A gone pane, or
   `--new-window`: `new-window -d` in the pane's old session (from the
   record's reserved `session` when written, else the caller's), and
   `@roost-was %OLD` on the new pane. Then `@roost-name` re-stamped.
   `remain-on-exit failed` means a resume that still exits at once (a store
   that lied, a harness that changed its message) leaves a dead pane whose
   last screen says why, not a hole in the layout; the next `revive` or
   `respawn-pane` on it clears it.
8. Print `%NEW` on stdout (the new or kept id), one line on stderr with the
   command, exit 0. **Exit 0 means launched**, not resumed: roost does not
   wait for the harness's prompt and does not answer anything it opens; the
   harness's own first event re-stamps identity, and `roost status` shows it.
   `--json`: `{"pane","was","harness","session_id","command","cwd"}`.

### 4.2 `roost save [--to FILE] [--auto] [--trigger NAME]` (#51)

Write the server's shape (§3). Prints the path and `S sessions, W windows,
P panes, A with a conversation, K stale` on stderr; exit 0, or 1 when nothing
could be written (the directory refused, the server gone). `--auto` is what
the hooks call: it goes through the saver of §3.5, writes only when the
server has at least one pane and the body changed, says nothing, and never
fails loudly — the `run-shell -b` rule. `--trigger` names the cause in the
header (§3.6); the hooks pass their own name, the verbs theirs. `--to FILE`
writes a copy anywhere (a committed fleet file is **out of scope** here; §10
says why), and is the way a person moves a shape between machines; it
carries placement and keys, **not** the harness stores, credentials or
databases the keys point into, so a shape restored on another machine
resumes nothing unless those were moved too (§11).

### 4.3 `roost restore [--from FILE|STAMP-GEN] [--list] [--dry-run] [--no-resume] [--resume] [--only SEL ...] [--recent DAYS] [--pace SECONDS] [--json]` (#51)

Recreate the saved placement, then resume what has a key. `--resume` alone
is the **resume-only** form for panes already placed (§4.6); `--at-login` is
the hidden form the service runs (§4.4).

- **Refuse first.** Schema unknown or larger, a malformed block, a value with
  a control character, a repeated key, an address with no parent or a
  repeated address: exit **16**, one line naming the line number and the
  fault, nothing done. The whole file is read and checked before the first
  tmux command. No shape for this server: exit 2. A `--from FILE` whose
  `host` is not this machine: one stderr line, then carry on — the file is
  the caller's choice, and the **server** is always the caller's (`-L`/`-S`
  on the command line), never the file's `socket`.
- **Which save.** §3.6's rule, unless `--from`.
- **Server.** Not running: start it the way `ensure_session` does — `-f CONF
  new-session -d -s <first saved session> -c <that session's first cwd>` with
  **`-x W -y H`**, `W` and `H` the largest root cell among that session's
  saved layouts (§2.7: a detached server is otherwise 80x24 and a stacked
  window cannot be built) — then `roost wiring apply`, and mark the session
  `@roost-bootstrap 1`. Running: use it.
- **Sessions.** A saved session whose name exists is **skipped and named**
  (`roost restore: session 'litro' exists — skipped, 9 panes not restored`),
  and every window and pane inside it with it; a partial fleet is never
  merged into a live session (#51 requirement 4) — **except a replaceable
  session**: one that holds exactly one pane, running a shell, with no
  `@roost-name` and no `@roost-session`. That is restore's own bootstrap
  session, or the one `ensure_session` made for a person who typed `roost`
  before the login restore ran (§4.6). A replaceable session is **used**: its
  one window becomes the saved first window (renamed, resized), its one pane
  the saved first pane. Others are created in saved order with `new-session
  -d -s NAME -x W -y H` for a detached server, so every session has room.
- **Windows.** `new-window -d -t SESSION:INDEX -n NAME -c CWD` at the saved
  index (a sparse set and `base-index` come back as saved; `renumber-windows`
  on the user's conf would move them and is noted in `--dry-run`); then
  `split-window` **on the largest pane** of the window until the saved pane
  count exists (§2.7: splitting the newest pane halves it each time and stops
  at four on 24 lines; the largest always has room while the window can hold
  the count at all); then `select-layout` with the saved layout; then, walking
  the panes in index order against the saved pane blocks in order,
  `respawn-pane -k -c CWD` with `default-command` for each, so creation order
  does not have to match cell order and every pane is a shell in its own
  saved directory — the respawn `ensure_session` already does for the first
  pane, and nothing has run in them yet. `select-layout` failing (`invalid
  layout` on an edited string) leaves tmux's default layout and one stderr
  line. `zoomed 1`: `resize-pane -Z` after the layout. Pane names re-stamped;
  `@roost-was %OLD` on every pane; the alias map written (§5.4); the saved
  active window and pane selected. Windows are made with their **shells**,
  through `default-command`, so a pane with no conversation is a shell in its
  old directory at this point.
- **Directories.** A `cwd` that no longer exists → the home directory **and**
  a stderr line per pane; such a pane is never resumed (§4.1 step 4).
- **Resumes.** Unless `--no-resume` (§9 Q2: resume is the default), for each
  pane that has `harness` and `session_id` (never `stale_*`), in saved order,
  **shells first then agents**, `--pace` seconds apart (default **2**, the
  incident's number): run §4.1's steps 3 to 8 on the new pane, with the
  store check before anything is launched and a set of ids launched in this
  run so no id is launched twice (§5.1a). A missing harness, a store miss, a
  gone directory or a duplicate id leaves a shell with a note; a dialog is
  left on screen. `--recent DAYS` skips the resume (not the placement) of a
  pane whose transcript, when recorded, is older than DAYS by mtime; a pane
  with no transcript path is always resumed. `--only SEL` (repeatable)
  restricts both placement and resume to a session name, a `SESSION:WINDOW`,
  or an old `%N`. The `--at-login` form **stops before this step** and writes
  the pending record instead (§4.6); `--resume` **starts here**, from the
  pending record, on panes that already exist.
- **Report**, stderr, then exit: `restored S sessions, W windows, P panes;
  launched A agents; skipped K (existing); R not resumed (reasons listed
  above); M were working or blocked at the save — re-prompt by hand: %a %b`,
  then one line per pane not resumed, with its `launch` hint when it has one
  (`%34 was started as 'roost view preen README.md'`) and the §5.6 line for a
  pane with a stale or missing key. "Launched" is the honest word: exit 0
  means every command ran, not that every harness accepted its session
  (§4.1 step 8). Exit **0** when everything was placed and every agent with a
  key was launched; **12** when something was skipped as existing; **13**
  when a pane could not be resumed for a reason listed (the placement still
  happened); 12 wins over 13 when both. `--json` prints the same as one
  document: `{"restored":[{"was","pane","session","window","launched",
  "reason"}],"skipped":[…],"from":"STAMP-GEN"}`.
- **`--dry-run`** prints the plan with the same words and exits with the code
  the real run would give before any resume. `--list` prints the history
  (§3.6) and the pending record (§4.6) and exits 0.

### 4.4 `roost persist on|off|status [--name NAME]` (#192)

Bring the fleet back at login, opt in. One unit **per server**, never a
shared template, so `off` for one server touches nothing of another's.

- **`on`**: write the `persist` marker in the server's shape directory; write
  `service.env` (below); save once (`--trigger persist-on`); install the user
  service and load it:
  - **`service.env`** holds, one `NAME=value` per line, 0600: `HOME`, `PATH`,
    `LANG`/`LC_ALL`, the **resolved** `XDG_STATE_HOME`, `XDG_CONFIG_HOME` and
    `ROOST_SHAPE_DIR` (so the service reads the same roots the saves were
    written to — a custom state root is otherwise simply not found at login),
    `TMUX_TMPDIR` when set (it selects the socket namespace), and the harness
    home overrides when set: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
    `COPILOT_HOME`, `PI_CODING_AGENT_DIR`, `OPENCODE_CONFIG_DIR` (§2.8's
    store checks read them). **Never** any variable whose name contains
    `KEY`, `TOKEN`, `SECRET` or `PASSWORD`, whatever else is set: the service
    needs roots, not credentials. A launchd job and a systemd user service
    both start with a minimal environment, and tmux reads its locale once at
    start — the ssh page already records the `_` glyphs that follow a C
    locale.
  - macOS: `~/Library/LaunchAgents/dev.roosting.roost.<server>.plist`,
    `RunAtLoad` true, `ProgramArguments` `[<this checkout>/bin/roost persist
    --at-login <server>]`, `EnvironmentVariables` from `service.env`,
    `AbandonProcessGroup` true — launchd otherwise kills what is left of the
    job's process group when the job exits, and although the tmux server
    daemonizes into its own session, saying so in the plist costs one line
    and removes the question — `StandardOutPath`/`StandardErrorPath` at
    `login.log`. Loaded with `launchctl bootstrap gui/$(id -u) PLIST`.
  - Linux: `~/.config/systemd/user/roost-persist-<server>.service`, with
    `Type=oneshot`, `RemainAfterExit=yes`, `KillMode=process`,
    `EnvironmentFile=<shape dir>/service.env`, `ExecStart=<checkout>/bin/roost
    persist --at-login <server>`, `WantedBy=default.target`; `systemctl --user
    enable roost-persist-<server>` **without `--now`** (the unit runs at the
    next login; `on` then runs `--at-login` itself in the foreground when the
    server is not up, so the person sees the same thing a login would do).
    `Type=oneshot` with `RemainAfterExit` is what keeps systemd from treating
    the unit as finished when `--at-login` exits and killing its cgroup — the
    tmux server and every agent in it — under the default
    `KillMode=control-group`. `KillMode=process` is belt and braces: an
    explicit `stop` reaches only the main process, which has already exited.
    `<server>` must match `[A-Za-z0-9._-]+` or `on` refuses (exit 1) — unit
    names and plist labels are not escaped, they are refused. A user
    instance that should start at boot without a login needs `loginctl
    enable-linger`; `persist on` prints that as a line, does not run it.
    Whether a logout with `KillUserProcesses=yes` reaches a user service's
    tmux server is *not measured*; §8.2 item 2 includes a logout.
  - `--at-login NAME` is the hidden form the service runs. It writes
    `restoring/` first (so a `roost` typed meanwhile waits, §4.6), then waits
    up to 60 s for the socket directory to be writable, then does §4.3 for
    NAME with the reading rule of §3.6 **up to placement**, writes the pending
    record (§4.6), the `login/<os-boot>` marker, and what it did to
    `login.log`. It always exits 0 (a skipped session is a line in the log,
    not a failed login job). §9 Q1 (A): the agents come back at first attach.
- **`off`**: `launchctl bootout` on macOS; `systemctl --user disable` on
  Linux, **never `stop`, never `--now`** — `--now` stops the unit, and
  stopping a unit whose cgroup holds the fleet is how forty agents end at
  once; remove the unit file, the `persist` marker and `service.env`,
  **nothing else**: shapes, history and pending stay (#192 requirement 2).
  A second server's unit is a different file and is not touched.
- **`status`**: `on`/`off`, the unit path, whether the loaded unit names
  **this** checkout (an upgrade or a relink moves checkouts; the unit must
  follow — `roost upgrade` gets one line to rewrite it when `persist` is on),
  the roots in `service.env` and whether they match the caller's, the newest
  save's stamp, `gen`, `trigger` and counts, the pending record's counts, the
  last `login.log` summary.
- `login.log` is 0600, holds the restore report and the reading rule's
  choice, never a screen capture, and is truncated to its newest half when it
  passes 1 MB.
- A machine with neither launchd nor systemd: exit **17**, named.

### 4.5 What `roost doctor` reports

Three lines, in the existing `ok`/`warn` style, warning only:

- `persist: on for 'roost' (launchd, unit names this checkout; roots match;
  last save 2026-10-24 20:51 gen 4182 after-split-window, 13 sessions / 47
  panes; last login restore: 2026-10-20 …; 0 pending)`, or `persist: off
  (roost persist on to restore the fleet at login)`.
- `warn`: the unit names another checkout; or `service.env` names a root the
  caller does not have; or its `PATH` lacks a harness the newest shape names;
  or `persist` is on and the newest save is older than the server's boot
  (hooks are not saving); or a pending record from this boot still has
  unlaunched or failed panes.
- `warn`: N panes on this server run a harness with no recorded conversation
  (the §2.6 count), and M carry an identity that disagrees with their command
  (§3.2's stale case), with the harness names — the panes a reboot would
  lose or must not resume.

### 4.6 The pending record: placement at login, resume at first attach

§9 Q1 (A) splits a restore in two across time, and the keys have to live
somewhere durable in between — not in pane options, which a shell pane does
not have, and not in the shape, which §3.3 reads from live options. So:

- **`--at-login` writes `pending/<boot>/`** for the server it just built, one
  file per placed pane named by the new `%N`, holding that pane's resume
  block (`was`, `harness`, `session_id`, `transcript`, `cwd`, `session_cwd`,
  `session`, `window`). Only panes that would be resumed are written (a key,
  not stale, directory present).
- **Overlay.** `save --auto` (§3.5 step 2) writes a pane that has no
  `@roost-session` but has a pending file with the pending keys, plus
  `resume pending`. A structural save in the gap, and a second reboot before
  anyone attached, therefore keep every key (§8.1 test 11).
- **The trigger** is a tmux hook, `client-attached[98]`, running `roost
  restore --resume --auto` with `run-shell -b`: it fires for `roost`, `roost
  session NAME`, `roost ssh` and a bare `tmux -L roost attach` alike, and a
  **detach fires nothing** — detaching never restores or resumes anything.
  `--auto` is silent when there is nothing pending and takes the §3.5 lock,
  so two clients attaching in the same second run one loop.
- **`restore --resume`** walks `pending/<this boot>/` in saved order, shells
  are already there, so straight to agents, `--pace` apart (§5.5 applies here
  too). Each pane is **claimed** by `mv %N %N.launching` — atomic, so a pane
  is launched at most once however many loops run — then §4.1 steps 3 to 8.
  A launch that cannot happen (store miss, harness missing, duplicate id,
  directory gone) renames the file to `%N.failed` with the reason appended,
  and the pane stays a shell. The `.launching` file is removed when identity
  lands on that pane with the same `session_id` (the `identify` hook's save
  call does it), so a pane left in a trust dialog keeps its binding until a
  person answers, and the next `save` still writes the key.
- **Cancel.** `after-kill-pane` and `roost close` on a pane with a pending
  file remove it: a person who closed the shell did not want the agent.
- **Interrupted halfway** (the person detached and the server died, or the
  loop was killed): unclaimed files are still there for the next attach;
  `.launching` and `.failed` files are listed by `restore --list`, `status`
  and `doctor`, and `roost restore --resume` by hand retries `.failed` ones
  with `--retry`.
- **`ensure_session` and the login restore.** With `persist` on, a `roost`
  typed before the service has finished: when `restoring/` exists with a live
  pid, `ensure_session` waits up to 60 s for it to go, then attaches (the
  attach fires the hook). When the server is not running, a `shape` exists,
  `persist` is on and there is **no** `login/<os-boot>` marker for this OS
  boot (`sysctl kern.boottime` on macOS, `/proc/sys/kernel/random/boot_id`
  on Linux), `ensure_session` runs `--at-login` itself under the same lock
  before attaching — so a service that did not run, or has not run yet, is
  not a lost fleet. A server a person killed on purpose and restarted in the
  same OS boot has the marker and is left alone.
- `pending/<boot>/` for a boot that is gone is removed by the next
  `--at-login`; `rm -rf` of the shape directory forgets it with the rest.

---

## 5. Restore rules

### 5.1 A resume runs in its own place, or not at all

Every resume runs in the saved **session**, the saved **window**, and **one
directory chosen from the two the shape holds**, through `roost-pane-shell`.
Measured reasons: Claude resumed from another directory re-files the
conversation under that directory (§2.1); codex opens a "Working directory"
dialog (§2.2); pi asks to fork (§2.4). A missing directory is a shell at home
with a note, never a resume at home.

Which directory (§2.6's first live case: the shell in the repository root,
`@roost-cwd` an old worktree, the transcript filed under the root):

- **Claude and pi** encode the project directory in the transcript path.
  The resume directory is whichever of `session_cwd` and `cwd` encodes to the
  transcript's project folder (`/` written as `-`; pi wraps it in `--`).
  Neither matches, or no transcript recorded: **do not resume**; print the
  §5.6 line (the Q4 A rule). This is the one place a transcript path is
  read, and only its directory name.
- **codex**: `session_cwd` when present, else `cwd`; the rollout's own
  `session_meta.cwd` is the authority and a mismatch opens codex's dialog,
  which §5.2 leaves to the person.
- **copilot**: either; it returns to its session's own directory (§2.3).
- **opencode**: `session_cwd` when present, else `cwd`; *not measured*.

### 5.1a The key is checked in the store before anything is killed or launched

Every harness measured exits 1 at once when its id is unknown (§2.1–2.4), and
`roost-pane-shell` `exec`s the command, so the pane dies with it: `revive`
would have killed the shell with `respawn-pane -k` for nothing, and a restore
would lose a cell of its layout. Claude's own 30-day transcript cleanup makes
this the ordinary fate of a pane idle for a month, not a corner. So, before
`-k` or any launch, the adapter checks the key where the harness keeps it
(§2.8's column); a miss leaves the pane exactly as it was, exit 13, reason in
the report. The same step refuses an id that a live pane on this server
already carries in `@roost-session`, or that this run has already launched:
Claude accepts a second `--resume` of a live id (§2.1 shows no lock), and two
processes on one transcript is the failure other tools have written incident
notes about (§11). `remain-on-exit failed` on the pane during the launch is
the second net (§4.1 step 7).

### 5.2 Nothing is answered

A dialog a harness opens on resume — Claude's folder trust, codex's hooks
review or directory choice, copilot's two consents, pi's fork question — is
left on screen. roost does not detect it from the screen and does not report
it as `blocked`: those dialogs fire no hook, and a guess from the screen is the
#38 lesson. The restore report says how many agents were launched; `roost
status` shows which have badged since; a pane that has not is the one to look
at. `roost answer` stays a person's verb and gains nothing here.

### 5.3 Badges, and why #105 is not a prerequisite

A badge is a pane option. After a **reboot** no pane option survives: there
is nothing stale to read. Restore writes `@roost-name`, `@roost-was` and
nothing else; identity is re-stamped by the harness's own first event
(measured on all four: the resumed pane had no `@agent_state` until then).
The shape's `state` key is for a reader's eyes and the report's one line,
and is never written back. The other path, `revive` on a **live** pane, keeps
its options through `respawn-pane` (§2.7), so §4.1 step 7 clears them by
hand. After either path no badge can read as live that is not — with the two
limits §4.1 and §5.7 state: a resumed process can die (a dead pane says so),
and a resumed codex reports to the wrong pane until #145.

#105's two halves stay their own change: refusing a report from outside the
pane's tree does not touch restore, and marking a pane whose process is gone
would, after a restore, only ever mark a pane whose **resume** died — a real
want, not a prerequisite. One thing restore does take from #105's thinking:
a pane whose harness exited at once is noticed by `pane-exited` on a spawned
pane and reads as gone; on a shell pane the shell has the terminal back and
`wait-done` already exits 2 (#64). **Step 4 of the turn-over design (#105)
need not land first.**

### 5.4 Addressing after a restore: the map, `was:%N`, and Claude's free note

The incident's third lesson. Three things, and the design picks all three
because each covers a case the others do not:

1. **`@roost-was %OLD`** on every restored pane. `roost status --json` gains
   `was` (null when none). A person or a coordinator who knows the old id
   finds the pane.
2. **The alias map**, `shapes/<server>/aliases/<new boot>`, one `%OLD OLDBOOT
   %NEW` per line, appended by every restore into this boot. **A bare `%N`
   always means a pane of the running server and nothing else** — ids
   restart at `%0` (§2.7), so after a restore an old `%1` usually *exists* as
   some other pane, and a verb that silently redirected a miss would deliver
   to the wrong agent on a hit; checking the map first would only reverse
   which caller is wrong. A historical id is written **`was:%930`**, and every
   verb that resolves a target (`send`, `read`, `wait-done`, `screen`,
   `answer`, `close`, `revive`, `forget`) resolves it through **this boot's**
   map only, printing one stderr line, `roost send: was:%930 is %34`. Two
   lines for the same old id from different old boots (a restore of two
   shapes into one boot) make `was:%930` ambiguous: exit 2, naming both as
   `was:%930@OLDBOOT`, which is the unambiguous form. `was:%N` in the map but
   its pane gone: exit 2, today's message. A map file from another boot is
   never read. `read was:%930` reads the **old** boot's record (the map knows
   the old boot) — the replies the pane gave before the reboot, which the new
   pane's record does not have. One cheap courtesy for a stale coordinator:
   when a bare `%N` names a live pane **and** appears as an old id in this
   boot's map, the verb adds one stderr line, `note: %1 was also an old id;
   the pane that was %1 is now %0 (was:%1)`, and delivers to the live `%N` as
   asked. The site page (§7) says this plainly.
3. **Claude learns its new id for free.** `scripts/roost-session-context`
   injects "This pane is %NEW" at `SessionStart`, which fires on resume
   (§2.1), and adds "it was %OLD before a restore" when `@roost-was` is set.
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
machine that had just booted, and which worked; an agent-aware terminal app
paces at 750 ms, so 2 s is conservative, which is right for a machine that
just booted), and applies to the first-attach loop of §4.6 as much as to a
hand `roost restore`. Shells first, so the whole placement is on screen in a
second and the slow part is visible as it goes. `--recent DAYS` and `--only
SEL` (§4.3) choose; the default is everything the shape holds, because the
shape only ever holds what was open — the incident's "recent versus all" came
from reading Claude's whole history, not from a shape. §2.9 gives the memory
figure: pacing spreads the cold starts, which is what was heavy; the
resident set it does not change, and a person who wants fewer agents back
uses `--only` or `--recent`.

### 5.6 A pane with a harness and no usable key

The 13 Claude panes of §2.6, every codex pane under #145, and every pane
whose key is stale (§3.2). Restore places the shell in its directory and
prints `roost restore: %34 ran claude with no recorded conversation; roost
revive %34 cannot resume it`, or `%90 carries a stale codex key
(01a16c68…) from a nested agent; not resumed`. Then, by harness, the **store
listing** of §2.8's "source if roost has no key" column — for Claude every
transcript under `~/.claude/projects/<cwd encoded>/`, newest first, as
`claude --resume <id>` lines; for codex the rollouts whose `session_meta.cwd`
is the pane's directory, newest first — because several panes share one
directory and the newest is a guess. §9 Q4 (A): **printed, never run.** A
guessed resume into the wrong pane is what §5.1 exists to stop.

### 5.7 codex: one restore, one badge

Measured (§2.2): a resumed codex TUI's hooks run in the app-server the first
codex started, with that pane's `TMUX_PANE`. After a restore of several codex
panes, every codex badge lands on the **first restored codex pane**. roost
cannot fix that here; #145 owns it. The restore report says so when more than
one codex pane was resumed: `N codex panes resumed; until #145 their badges
all land on the first (…)`.

### 5.8 What roost never does

Store a transcript, a reply or scrollback in the shape — scrollback holds
pasted secrets and prompts, and an agent's own conversation comes back from
its harness; answer a dialog; restore a badge; resume into a directory other
than the one §5.1 chooses; resume an id the harness no longer holds, or one
already open in another pane; run a `launch` hint; merge into a session that
exists and is not replaceable; start a service without `persist on`; stop a
service, ever.

### 5.9 What survives what

| event | live process, PTY, scrollback | placement | conversation |
|---|---|---|---|
| a client detaches or the terminal closes | kept by tmux | kept | kept |
| the tmux server dies (kill, crash, reboot) | **lost** | restored from the shape | restored by the harness from its own store, where roost has a key and the store still holds it |
| a pane is killed or closed on purpose | lost | its cell is gone from the next save | the harness keeps it; `revive` cannot reach it (no record of a deliberate close), the store listing of §5.6 can |

In-flight tool calls, shell jobs, `ssh` connections and process memory are in
the first column only. A turn that was `working` at the save is lost with the
process; the report names such panes so a person can re-prompt (§4.3).

---

## 6. Build order

Each step ships alone and is worth something alone. Sizes are airig's. The
probes a step must run before its code are listed with it.

| step | what | size | worth by itself |
|---|---|---|---|
| 1 | `roost save`, the shape format and its refusals (whitespace-exact parser, stale keys, `session_cwd`, `launch`, `zoomed`, unknown-block skip), `roost restore` **placement only** (`-x W -y H`, largest-pane splits, `select-layout`, per-pane respawn, saved indices, replaceable sessions, `--dry-run`, `--list`, `--only`, exit 12/16). Probes first: what `#{pane_current_command}` reads under pi, copilot and opencode (§3.2) | M | #51 as written: the guess of lesson 2 is gone; a fleet's shape can be moved between machines by file |
| 2 | `roost revive TGT` with the resume table and the **store check** in the adapters' library (`scripts/lib/roost-resume.sh`, beside `roost-close.sh`), the directory rule of §5.1, the duplicate-id refusal, option clearing and `remain-on-exit failed`, `respawn-pane -k`, the gone-pane path from the record, exit 13/14/15; the opencode existence check or an honest printed command. Probe first: whether `claude --resume` keeps model and permission mode (Appendix A, the launch-flags row) | M | #57: kill a pane, get the conversation back, same `%N` |
| 3 | restore resumes: §4.3's resume loop, pacing, `--recent`, `--no-resume`, `@roost-was`, the alias map and `was:%N` in every target-taking verb, `status --json` `was`, the codex note, the mid-turn line; the §2.9 RSS measurement of a resumed stub fleet against placement-only | M | lessons 3, 4 and 5 answered; a manual `roost restore` after a reboot does the whole job |
| 4 | save on change: the hooks in `tmux/roost.conf`, the direct calls in `spawn`/`split`/`view`/identify/`close`, the one-saver protocol (`lock`, `want`, `gen`, `restoring`), `trigger`, the 100-entry ring, the shutdown-record rule, the three §3.4 cost measurements, the §4.5 doctor warnings about saving. Probes first: the Linux shutdown record (`last -x shutdown`, `journalctl --list-boots`); whether tmux runs `session-closed` hooks during a shutdown on a VM | S→M | nobody has to remember `roost save`; a crash loses one change at most; a shutdown does not restore what was closed on purpose |
| 5 | `roost persist on/off/status`, per-server plist and unit, `service.env`, `--at-login`, the pending record, `restore --resume`, the `client-attached` hook, `ensure_session`'s wait and self-restore, `login/<os-boot>`, `login.log`, `roost upgrade` rewriting the unit, the §4.5 doctor line, and the §8.2 human-eye reboot on macOS then Linux. Probe first, on a Linux VM: the unit's behaviour at `--at-login` exit, at `disable`, at logout with and without linger | M→L | #192: the fleet is back after a reboot without being asked, and the agents when someone is there |
| 6 | the printed store listings of §5.6 (Q4 = A) for Claude and codex | S | the 13 panes of §2.6 are not lost silently |

The order did not change in revision 1; steps 4 and 5 grew (the saver
protocol, the pending record) and step 2 gained the store check, which is
why their sizes moved. #145 (codex identity under the app-server) is **not**
in this list; it is the one thing that would make codex restore whole, and it
is its own issue.

---

## 7. Changes to existing surfaces

- `status --json`: `was` on every pane (null when none); `schema` stays 1
  (additive). `status` human output: a `(was %930)` suffix on every restored
  pane, always; it is one word and it is the lesson.
- Every target-taking verb: `was:%N` (§5.4), one stderr line; the courtesy
  note on a bare `%N` that is also an old id.
- `tmux/roost.conf`: the hooks of §3.4 in slot `[98]` style, next to the
  events hooks, same `run-shell -b … || :` shape; `client-attached[98]` for
  §4.6.
- `bin/roost spawn|split|view`: `@roost-launch` set, then one `roost save
  --auto` call after the name is stamped. `roost identify` and the two
  identity hooks: the same call behind `ROOST_IDENTITY_WROTE=1`, which also
  clears a matching `pending/.../%N.launching`. `roost close`: a save with
  `--trigger close` after the pane is gone, and the pending cancel.
  `ensure_session`: §4.6's wait and self-restore when `persist` is on.
- `scripts/roost-session-context`: the "was %OLD" sentence.
- `roost doctor`: §4.5. `roost help`: the five verbs, the shape path, the
  bounds (`ROOST_SHAPE_KEEP`, `ROOST_SHAPE_DIR`), `was:%N`, and that `rm -rf
  ~/.local/state/roost/shapes` forgets every shape and pending key, and
  nothing else.
- `roost upgrade`: when `persist` is on, rewrite the unit to the new checkout
  path and reload it; say so.
- `site/content/docs/using-roost.md` or a new `persistent-sessions.md`: the
  verbs, the file and how to edit a copy of it, what is and is not restored
  (#51 requirement 3: say plainly that conversations belong to the harness;
  scrollback is not saved on purpose; a `cd` in a shell is not seen until the
  next event), `was:%N` and why a bare `%N` after a restore may be a
  different pane, the dialogs a resume can open per harness (§2.8), and that
  a shape copied to another machine resumes nothing without the harness
  stores.

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
and sleeps — so the resume **command** is asserted, not a model. The stub's
"store" is a directory of files named by id under the redirected
`CLAUDE_CONFIG_DIR`, so the store check has something to hit and miss; a
second stub `claude-exit1` exits 1 at once for the `remain-on-exit` case.
Every server in this file is **detached** — there is no client — which is the
production shape of a login restore.

Red tests:

1. **Placement.** Build 2 sessions, 3 windows, 6 panes with names,
   directories and a split layout, one window of **six stacked panes** at
   `-x 200 -y 50`, one window at index 5 with `base-index 1`, one window
   zoomed; stamp identity on two panes with `roost identify`; `save`; kill the
   server by its socket path; `restore`; `status --json` before and after
   compare on `session`, `window_name`, `window_index`, `pane_index`, `name`,
   `cwd` — the **first** pane's `cwd` included; the layout strings compare
   **with the checksum and pane ids stripped**; the zoomed window is zoomed;
   `save` twice with no change writes one file (the body compare); the
   restored server's first window is `200x50`, not `80x24`.
2. **Existing and replaceable sessions.** Restore into a server where one
   saved session exists with a named pane: it is skipped and named, exit 12,
   the other sessions placed, nothing added to the live one. Start the server
   with `roost` first (one shell pane, no name) then `restore`: the saved
   `roost` session is **placed into it**, not skipped, exit 0, and the
   bootstrap pane's `cwd` is the saved first pane's.
3. **Directories.** A pane whose `cwd` was removed: a shell at `$HOME`, the
   stderr line, not resumed, exit 13 when it had a key.
4. **Resume.** The stub `claude` is run with `--resume <id>` in the saved
   directory, 2 s apart (two agents, timestamps in the stub's file ≥ 2 s
   apart); `--no-resume` runs it zero times; `--recent 0` with an old
   transcript mtime runs it zero times; `--only SESSION` restores one
   session. **Directory rule:** a pane whose identity `cwd` differs from its
   shell `cwd`, transcript filed under the shell's: the stub runs in the
   shell's directory; transcript under the identity's: in that one; under
   neither: not run, the §5.6 line printed. **Siblings:** two panes in one
   directory with different ids each get their own `--resume`. **Duplicate:**
   two saved panes with one id: the first launched, the second a shell with
   the note, exit 13. **Stale:** a pane saved with `stale_session_id` is
   never launched and is named in the report. **Store miss:** a key with no
   file in the stub store is not launched, exit 13, the pane a shell.
   **Mid-turn line:** a pane saved `state working` is named in the report.
5. **Hand-edited file.** A copy with a deleted pane block is not restored; a
   renamed session (addresses renamed with it) is created under the new name;
   a renamed session whose panes were not renamed refuses, exit 16; a block
   with an unknown first word is skipped with one stderr line and the rest
   restored; `roost-shape 2`, a repeated key, a value with a tab, a repeated
   address each refuse with exit 16 naming the line and create **nothing** (a
   listing before and after). **Whitespace:** a `name` with two leading and
   three trailing spaces round-trips byte for byte through `save` and
   `restore`.
6. **`revive`.** On a live stub pane: `respawn-pane` keeps the id (same `%N`
   before and after), `@agent_state` and the identity options are cleared
   before the respawn, the stub ran with `--resume <id>` in the chosen
   directory; on a `working` pane: refused, exit 1, the agent untouched; on a
   gone `%N` with a record: a new window, `@roost-was`; no key: exit 13;
   harness off `PATH`: exit 14; `cwd` gone: exit 15; **store miss: exit 13
   and the pane's process is the same pid as before** (nothing killed); an id
   a live pane carries: exit 13 naming it; the `claude-exit1` stub as the
   harness: the pane is dead, not gone (`pane_dead` 1, `remain-on-exit`), the
   window still has its pane count.
7. **Addressing.** After a restore, `roost send was:%OLD "x"` reaches the new
   pane and prints the stderr line; `read was:%OLD` reads the **old** boot's
   record; a bare `%OLD` that names a live pane delivers to **that** pane and
   prints the courtesy note; a bare `%N` that names nothing gives today's
   exit 2 with no redirect; a `was:%N` not in the map gives exit 2; two
   restores from two shapes with the same old `%N` make `was:%N` exit 2
   naming both `was:%N@BOOT` forms, and either form delivers; a map file
   from another boot is ignored; `close was:%OLD` closes the new pane.
8. **Save on change.** `spawn`, `split`, `rename-window`, `kill-pane`,
   `move-pane`, `select-layout`, `identify` each produce a new `shape` (body
   or `gen`); 50 `roost state working` calls on a working pane produce none;
   `window-layout-changed` alone produces none; **ten `spawn`s in parallel**
   end with a `shape` holding all ten panes and fewer than ten history files,
   every history name unique, `gen` monotonic; a `restoring/` marker with a
   live pid makes `save --auto` write nothing and leave `want`; a `lock/` with
   a dead pid is taken over; `history/` holds at most `ROOST_SHAPE_KEEP`;
   `trigger` is the hook's name, `close` after `roost close`, `save` after
   the verb. **The reading rule**, with a stub shutdown record (a test seam,
   `ROOST_SHUTDOWN_AT=EPOCH`): (a) a chain of `pane-exited` saves inside the
   window → the save before the chain is picked and named by `--list`; (b)
   `roost close` of three panes inside the window → the `close` save is
   picked, the closed panes do **not** come back; (c) no record → the newest
   save and the stderr line; (d) a chain of 60 death saves → still recoverable
   (the ring holds 100).
9. **`persist`.** `persist on` with `ROOST_PERSIST_WRITE_ONLY=1` (a test seam:
   write the unit, do not load it) under `XDG_STATE_HOME=/custom`,
   `CODEX_HOME=/x` and `MY_API_KEY=1` writes a plist on macOS and a unit on
   Linux whose contents name this checkout and the server, and a
   `service.env` naming `/custom`, `/x` and **not** `MY_API_KEY`; the unit has
   `Type=oneshot`, `RemainAfterExit=yes`, `KillMode=process` and no
   `ExecStop`; `on` saved once (`trigger persist-on`); `on` for server B then
   `off` for A leaves B's unit and `service.env` untouched and A's `shape`,
   `history/` and `pending/` in place; `off` called `disable` and **never**
   `stop` or `--now` (a `systemctl`/`launchctl` stub that records its argv and
   fails loudly on `stop`); a server name with a space or `/` refuses, exit 1;
   `status` reads it all back.
10. **Degrade.** `ROOST_SHAPE_DIR` relative or empty saves nothing and every
    hook still exits 0 within 5 s; a read-only shape directory makes `save
    --auto` silent and `save` exit 1; a reader running `restore --dry-run` in
    a loop while 20 saves land never sees a refusal (no partial file).
11. **The pending record.** `restore --at-login` on a shape with three keyed
    panes places shells, writes `pending/<boot>/` with three files and no
    `pending` for the unkeyed pane, launches nothing; a `spawn` then (a
    structural save in the gap) writes a `shape` whose three panes carry
    their keys and `resume pending`; kill the server, `--at-login` again from
    that shape (the second reboot): three pending files again; **attach** a
    client (`tmux attach -d` in the background, or the hook invoked
    directly): the three stubs are launched 2 s apart, each pending file is
    `.launching` and then gone once the stub's `roost identify` lands; two
    hooks fired in the same second launch each stub **once**; kill the loop
    after the first launch: one file gone, two still claimable, the next
    `--resume` launches exactly those two; `kill-pane` on a placed pane
    before attach removes its pending file and the attach launches two; a
    `.failed` file (store miss) is listed by `--list` and retried only with
    `--retry`; `ensure_session` with `persist` on, no server, a `shape` and
    no `login/<os-boot>` marker runs the placement itself; with the marker it
    does not. **Other host:** `--from` a file whose `host` differs prints the
    line and restores. **Two sockets:** a shape from server A restored into
    server B on the same machine, both with panes `%0`–`%3`, places into B
    only and B's map has A's ids.

Guards: byte-identical `status --json` for a server that was never restored
except `"was":null`; the record tests still pass with shapes on; the canary
`HOME` stays empty; the shape directory is 0700 and every file in it 0600.

Mutations that must turn a test red: drop the `select-layout` (1); drop
`-x`/`-y` (1, the six stacked panes); merge into an existing named session
(2); resume in `$HOME` when `cwd` is gone (3); no pacing (4); resume in
`session_cwd` without the transcript check (4); launch a `stale_*` key (4);
skip the store check (4, 6); `mv -f` without `mktemp` (10); redirect a bare
`%N` through the map (7); read the alias map without checking the boot (7);
save on `after-set-option` (8); drop the lock (8, ten spawns); step back over
a `close` save (8b); load the unit in a test (9); `--now` on `off` (9); read
live options instead of the pending record in the gap (11); claim with `cp`
instead of `mv` (11, two hooks).

Live, by hand, not in the suite, under `tests/live/`: `revive-smoke.sh` runs
`revive` against real Claude through the fake API rig and asserts the resumed
pane re-identifies the same id (the §2.1 shape) and that a deleted transcript
makes `revive` refuse with the pane untouched; the codex, copilot and pi
smoke files each gain one resume case, and the codex one kills its own
app-servers by environment, as the probe did.

### 8.2 Human-eye, listed together

1. **A real reboot on macOS** with `persist on`: log in, `roost`, the same
   sessions, windows and names are there as shells; the agents then come up
   2 s apart; each Claude pane is at its prompt with its conversation;
   `login.log` says which save was chosen and why; `restore --list` shows the
   pending record empty afterwards. Count the dialogs that opened and which
   harness opened them. Type `roost` **before** the service has run once, on
   a later reboot, and see the same result.
2. **A real reboot on Linux** (a VM is fine): the systemd unit ran, the same
   checks; without linger the unit starts at login, not at boot; **`roost
   persist off` while forty stub agents run ends none of them**; a logout
   and login with `KillUserProcesses` at its distribution default: say what
   survived.
3. **The shutdown chain** (§3.6): after the macOS reboot, `roost restore
   --list` shows whether saves landed in the final seconds, what their
   triggers were, whether `last reboot` carries the shutdown minute, and
   whether the reading rule picked the right one. This decides whether the
   rule stays.
4. **Claude's credentials at first attach**: a resume may hit the Keychain
   before the user has unlocked it, or prompt for Keychain access. What
   appears on screen; §9 Q1 (A) means a person is there to see it.
5. **`roost upgrade` with `persist on`**: the unit follows the checkout.
6. **The codex note** (§5.7) with two real codex panes after a restore: the
   badges land where the note says they do.
7. **Reading the file**: a person opens `shape` cold and can say what the
   fleet was; copies it, edits one `cwd`; `--dry-run --from COPY` says what
   they meant.

---

## 9. Decisions

Each with option A (the proposal) and B, and one line of why.

**Decided by the human on 2026-10-24: A, A, A, A.** Agents resume on first
attach, not at login (Q1); a manual restore resumes by default (Q2); the
saved shape lives under `XDG_STATE_HOME` (Q3); a Claude pane with no recorded
id gets a printed, never-run resume line (Q4). Revision 1 keeps all four;
Q1's A gained a mechanism, noted in its text.

**Q1. When do agents come back after a reboot?** Decided: A.
- **A.** `persist` restores **placement** at login and resumes agents when a
  person first attaches to that server (`roost`, `roost session NAME`), paced;
  `roost restore --resume` does it by hand any time.
- **B.** Everything at login, paced 2 s apart, with nobody watching.
- Why: a dialog on resume needs a person present (§5.2), a machine that just
  booted needs the headroom (lesson 4), and a Keychain prompt at login (§8.2
  item 4) is the kind of surprise that turns a feature off.
- **What A means in practice after revision 1** (item 11 of §0: the draft
  had no durable place for the keys between login and attach, and no
  trigger). The login restore writes a **pending record** per placed pane
  (§4.6), and a shape saved in the gap carries those keys, so a second reboot
  before anyone attaches loses nothing. "First attach" is the tmux
  `client-attached` hook: `roost`, `roost session NAME`, `roost ssh` and a
  bare `tmux -L roost attach` all count, a detach never does, and the whole
  pending set is claimed once, pane by pane, by whichever client came first;
  a second client in the same second starts nothing. The resume runs in the
  background, 2 s apart, while the person sees the shells come alive; a
  `roost` typed before the login service has finished waits for it, and a
  `roost` typed when the service never ran does the placement itself. None
  of this changes *when* agents come back — at first attach, not at login —
  which is what was decided; it says how.

**Q2. Does a manual `roost restore` resume agents by default?** Decided: A.
- **A.** Yes: every pane with a recorded conversation is resumed; `--no-resume`
  places shells only.
- **B.** No: shells only; `--resume` opts in, as #51's text said.
- Why: a resume costs no tokens until a prompt is sent (measured: four
  harnesses sat at their prompt), #191's done line says "each agent resumed",
  and the fleet of shells is what the incident called useless; B is #51's
  original caution about cost, which the measurement removes.
- Revision 1 adds the store check (§5.1a) and the stale-key rule (§3.2)
  before any resume, which narrows *what* is resumed by default to keys the
  harness still holds and that belong to the pane's own agent; the default
  itself is unchanged. `--resume` now also names the resume-only form of
  §4.6; `--no-resume` keeps its meaning.

**Q3. Where does the saved shape live?** Decided: A.
- **A.** `${XDG_STATE_HOME:-~/.local/state}/roost/shapes/<server>/`, beside the
  pane records and the event log, one `rm -rf` to forget everything.
- **B.** `${XDG_CONFIG_HOME:-~/.config}/roost/shapes/<server>/`, beside
  `roost.conf`, because a hand-editable file reads as config.
- Why: it is written by hooks many times a day and is history as much as
  intent, which is state; but it is the one roost file a person is invited to
  edit, which is config. Not beside the socket: `/tmp` does not survive the
  reboot the file exists for.
- Revision 1: the directory also holds the pending record, the alias maps
  and `service.env` (§3.1), and the login service is told the resolved root
  (§4.4), so A holds for a custom `XDG_STATE_HOME` too. Hand-editing is of a
  **copy** (§3.2), because the auto save owns `shape`.

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
- Revision 1: the printed list is **every** id under that directory, newest
  first, not only the newest (several panes share a directory), the same
  print exists for codex from its rollout files, and a pane with a **stale**
  key (§3.2) is treated as having none. Still never run.

**Decided, not asked**, because #191 decided it: the login service is **off
until a person runs `roost persist on`**, and `roost doctor` says which it
is. Revision 1 reads that as the *service*; the shape is saved on change from
step 4 on regardless, because a hand `roost restore` after a crash needs it
and it is #51's own value (§3.4). Flagged for the human in the revision
report in case the reading is wrong.

---

## 10. Out of scope, and risks

Out of scope, named so nobody reads them as forgotten:

- **A committed fleet file** (the 2026-09-21 comment on #51: one format for
  "save" and for "a teammate clones and runs one command"). The shape format
  is designed so it *can* be that file — `save --to` writes it, `restore
  --from` reads it, paths are the machine-specific part, the harness stores
  the machine-bound part — but a fleet file needs commands to launch, not
  conversations to resume, and that is a design of its own once this one is
  built. The `launch` hint is the seed.
- **Hibernate** (the 2026-09-21 comment on #57): end an idle agent, keep the
  key, resume on the next `send`. `revive` is the half it needs; the other
  half is a policy.
- **#145**, codex identity under the shared app-server. Without it codex
  restore is placement plus the printed rollout listing.
- **#77**, silencing a nested agent's hooks. §3.2's stale rule catches the
  symptom at save time; the cause is #77's.
- **Minting ids at spawn.** Works on three harnesses (§2.8); not needed while
  #141 records what the harness chose.
- **Carrying launch flags into a resume** (a `--model`, a permission mode).
  `launch` is saved and printed; whether a resume needs the flags is the
  step 2 probe (Appendix A, the launch-flags row), and an allowlist per adapter is a follow-up
  if it does.
- **Restoring scrollback, badges, replies into the pane.** Replies are in the
  record already (`read was:%OLD` reads them, §5.4).
- **Lazy, per-session resume at first attach** (resume the attached session's
  agents first, the others when selected). Appendix A, the per-session row, says why not now.
- **`roost ssh` remotes.** A remote's server is a server; `persist on` there
  is run there. Nothing here reaches across hosts; a local pane that ran
  `roost ssh HOST` comes back as a shell with its `launch` hint printed.

Risks, most serious first:

- **Hooks during shutdown may save a shrinking fleet** (§3.6). *Not
  measured.* The 100-entry ring, the `trigger` key and the shutdown-record
  rule are the mitigation; §8.2 item 3 decides whether the rule is right.
  Severity: medium now — whichever way the hooks go, a deliberate close is
  never undone and a full fleet fits the ring; what remains open is whether
  the OS record is reliable enough to lean on.
- **The identity agreement check is measured for two harnesses only** (§3.2):
  Claude and codex. pi, copilot and opencode pass on presence until the step
  1 probe says what their process reads, so a stale pi key on a pane back at
  its shell would still be resumed — into a harness that refuses an unknown
  id (§2.4), which the store check then catches first. Low.
- **A resume into a dialog nobody sees** (§5.2). Q1 A puts a person at the
  first attach; a `restore` run from a script still has nobody. The report,
  `status` and the pending record's `.launching` files are the signals.
- **codex badges all land on one pane after a restore** (§5.7). Known, owned
  by #145, announced in the report.
- **opencode `-s ID` creates a session when the id is unknown** (§2.5). The
  adapter must check first; until measured, `revive` on opencode prints the
  command and asks the person to run it.
- **The login service's environment goes stale.** `service.env` is written
  at `persist on`; a harness that moves (a brew upgrade of codex moved its
  app-server already, known-gaps) or a root that changes is found by `doctor`
  and `status`, not by the service. `persist on` again rewrites it.
- **Linux service behaviour is reasoned from the systemd manual, not run**
  (§4.4): `Type=oneshot` + `RemainAfterExit`, `KillMode=process`, `disable`
  without `--now`. The step 5 probe on a VM runs it before the code ships.
- **The 13 unidentified Claude panes** stay unidentified until each restarts;
  nothing here can reach into a running Claude to ask. Q4 is the only help.

---

## 11. What other tools do, and what roost takes

The review read six tools' documentation, source and trackers: a session
resurrection plugin for tmux and its autosave companion; a terminal
multiplexer with built-in session resurrection and a hand-editable layout
format; a GPU-rendered desktop multiplexer for coding agents with tmux
underneath; a daemon-backed multiplexer that calls itself reboot-proof; a
native macOS terminal app with agent-aware restore; and a PTY-daemon session
manager for AI command-line tools. Area by area, what they do and what roost
takes or rejects. No product is named here; the review reports hold the
references.

- **Detach and reattach.** Every server-based tool keeps processes alive
  across a client leaving; the desktop app has no detach at all. The
  multiplexer with built-in resurrection brings an exited session back when
  someone attaches to it, which is Q1 A's shape. *Taken:* attach as the
  trigger, through tmux's own `client-attached` hook so a bare attach counts
  (§4.6). *Taken from the PTY-daemon manager:* a resume is claimed exactly
  once, and a crash mid-loop loses the claim rather than doubling it (the
  `mv` claim of §4.6).
- **Remote and multi-machine.** Two tools sync a layout to the host that owns
  the processes so another machine can reattach; one transfers conversation
  state as a separate, best-effort step. None restores a conversation across
  hosts by copying a layout, because every harness store is local.
  *Rejected for now:* cross-host anything (§10, #85 is where it belongs).
  *Taken:* saying plainly that a copied shape carries keys and not stores
  (§4.2), and that the server is the caller's, never the file's (§4.3).
- **Process survival.** Nobody keeps a process across a reboot. The honest
  ones say so in a sentence; the resurrection tools re-run a saved command,
  one behind a "press Enter" banner, one from a short allowlist of
  well-behaved programs. *Taken:* the sentence (§5.9), and the saved command
  as a **printed** hint (`launch`, §3.2), never re-run — roost's panes are
  agents, and an agent is resumed by its own key or not at all.
- **Agent session resume.** The agent-aware tools capture ids from the
  harness's own hooks, as #141 does, and the two that wrote incident notes
  learned the same three things: a transcript probed by the pane's directory
  is unsound once a shell moves into a worktree; a key must be checked in
  the store before it is launched, because a bad resume exits and takes the
  pane; and two panes must never hold one session. *Taken, all three:*
  `session_cwd` and the transcript-directory rule (§5.1), the store check
  (§5.1a), the duplicate refusal (§5.1a). The desktop app sanitises the
  launch command it stores and drops secret-looking environment; *taken* for
  `launch` and for `service.env` (§3.2, §4.4). One tool appends the original
  spawn flags to the resume; *deferred* to a measurement (§10).
- **Scrollback.** Off by default in the resurrection tools, with a resource
  warning; on, bounded and best-effort in the desktop and daemon tools, one
  of which measured about a gigabyte of client memory for 37 panes of it.
  *Rejected:* scrollback in the shape (§5.8) — it holds secrets and prompts,
  and the harness replays the conversation. *Taken:* 0700/0600 on the shape
  directory, since the shape alone lists every project path and session id
  (§3.1).
- **Layout serialization.** One hand-edit-first format (a configuration
  language), one versioned JSON, one tab-separated text with no version and
  no atomic write; the tmux plugin has restored `window_layout` strings with
  `select-layout` for ten years, which is why §2.7's probe was low risk. The
  plugin treats a server holding one bare pane as "from scratch" and replaces
  it; the daemon tool funnels every snapshot trigger through one debounced
  writer because scattered triggers raced and lost layouts; the plugin drops
  a save identical to the last. *Taken:* the replaceable bootstrap session
  (§4.3), one saver per server with a want flag (§3.5), the body compare
  (§3.2). *Kept over all of them:* a line format a shell reads with no
  parser, a schema number, and whole-file validation before the first tmux
  command.
- **Overhead.** Timers everywhere else: every second, every minute, every
  fifteen minutes, or a 500 ms debounce with a 30 s safety save. The
  event-driven save with no timer and no daemon is the cheapest design in
  the field; the three listings cost 4 to 5 ms each on 47 panes. Two tools
  start restored processes lazily (the visible tab first) or in bounded
  waves; *not taken now* (Appendix A, the per-session row). The desktop app paces agent
  launches at 750 ms; roost keeps 2 s (§5.5) and now has the memory figure
  that says pacing is the right lever for cold starts and not for the
  resident set (§2.9).

---

## Appendix A. Triage of every non-blocking review item

Each item from the three reports, with *taken* (and where) or *not taken*
(and why, one line). Items that several reviewers raised are listed once.

| item | from | decision |
|---|---|---|
| a `cause`/`trigger` key per save; `roost close` saves with its own cause; sub-second history names | all three | **taken**: `trigger`, `close`, `<stamp>-<gen>` (§3.4, §3.5, §3.6) |
| an old `%N` that exists as a different pane after a restore misleads a stale `send`; print a line naming both; say it on the site | two | **taken**: the courtesy note and the site page (§5.4, §7); redirecting stays refused (item 12) |
| a writer skips its `mv` when `shape` is newer than its listing | one | **superseded**: one saver per server (§3.5) |
| write the resolved path of each harness binary into the unit | one | **not taken**: a resolved path goes stale faster than `PATH` when a harness is upgraded; `doctor` warns instead (§4.5) |
| record the memory figures as a ratio with the method | two | **taken**: §2.9, with the step 3 measurement of a resumed fleet |
| assert the restored layout string equals the saved one; show the "invalid layout" fallback | one | **taken** as geometry equality with ids and checksum stripped (the checksum covers the ids: §2.7); the fallback is in test 5 |
| Q4's printed fallback lists every id under the directory, newest first | one | **taken** (§5.6, Q4 text) |
| `client-attached` as the first-attach trigger; a one-shot pending marker | two | **taken**, as the pending record (§4.6) |
| `--from` a file whose `host` differs: one line, carry on | one | **taken** (§4.3) |
| save the command roost handed to `spawn`/`split`/`view` as a hint, printed never run | two | **taken**: `launch`, redacted (§3.2, §4.3) |
| carry an allowlist of launch flags into the resume; redact secrets from `pane_start_command` | one | **deferred**: measure first whether `--resume` keeps model and permission mode (step 2 probe, §10); `launch` is redacted already |
| never resume an id a live pane already carries | two | **taken** (§5.1a) |
| 0700 directories and 0600 files for the shape; say `mktemp` is why | two | **taken** (§3.1) |
| `login.log` never holds a screen capture; bound its growth; 0600 | two | **taken** (§4.4) |
| hand edits go to a copy; restore reads the whole file before its first tmux command; a `restoring` marker suppresses auto saves | one | **taken**, all three (§3.2, §3.5, §4.3) |
| `--pace` applies to the first-attach loop | one | **taken** (§4.6, §5.5) |
| §8.2 item 2 includes a logout, not only a reboot | one | **taken** (§8.2) |
| specify "first attach": store the pending resume, take it once | one | **taken** (§4.6) |
| resume the attached session's agents first, the rest when selected | one | **not taken now**: a `send` from a coordinator to a helper in a not-yet-resumed session would land on a shell; the fleet should be whole after one attach; `--only` exists for a hand restore; revisit if §8.2 item 1 shows memory pressure (§10) |
| the report names agents that were mid-turn at the save | one | **taken** (§4.3) |
| a printed rollout candidate for a codex pane with no key | one | **taken** (§5.6, §2.8) |
| unknown block types contradict the additive schema rule | one | **taken**: unknown blocks are skipped with a stderr line; the number moves only on a change of meaning (§3.2) |
| downgrade the `select-layout` risk; drop the `-p` fallback | one | **taken**: measured (§2.7), the fallback is gone from §10 |
| assert the first pane's `cwd` in test 1 | one | **taken** (§8.1 test 1) |
| add the two known-gaps identity items to §10 | one | **taken**: §1 names them, §3.2 answers them, §10 keeps the residual |
| say in §5.8 why scrollback is not saved | one | **taken** (§5.8, §7) |
| is auto saving gated by `persist on`? enable should save at once | one | **taken** as a clarification: saving is always on, the service is opt-in, `persist on` saves once (§3.4, §9); flagged for the human |
| the `read key value` loop loses whitespace; define duplicate keys and blank lines | one | **taken** (§3.2, test 5) |
| explicit window indices, `renumber-windows`, reuse the bootstrap window, restore active selections, test base-index holes | one | **taken** (§3.2, §4.3, test 1) |
| slash-to-hyphen keying of `-S` servers is not injective | one | **taken**: `path-<cksum>` (§3.1) |
| topology hooks (`move-pane`, `join-pane`, `break-pane`, swaps, `move-window`, `link-window`, `select-layout`, `resize-pane`) should save; a shell `cd` has no trigger | one | **taken** for the hooks (§3.4); the `cd` is accepted and said on the site (§3.4, §7) |
| two byte-identical saves versus an always-current stamp; a concurrent-reader assertion | one | **taken**: body identity excludes the header (§3.2); test 10's reader loop |
| `revive` must clear stale pane options before the new harness starts | one | **taken** (§4.1 step 7, test 6) |
| "launched" versus "resumed" in the report and exit codes | one | **taken** (§4.1 step 8, §4.3) |
| say whether rename alone is durable through power loss | one | **taken** as a statement, no `fsync` (§3.5) |
| systemd type, exit handling, escaping of names and paths | one | **taken**: oneshot, exit 0 always, names refused rather than escaped (§4.4) |
| never evaluate shape values; validate harness names and ids per adapter | one | **taken** (§3.2, §4.1 step 6) |
| say exactly what deleting shapes forgets | one | **taken** (§3.1, §7) |
| stale text: the preamble said the decisions were open; §4.3 had no `--resume` form; §8.2 item 4 said "Q1 B" | one | **taken**: all three fixed |
| a guarantee table: detach keeps, owner death loses, restore recovers | one | **taken** (§5.9) |
| tighten §5.3's "no badge can read as live" claim | one | **taken** (§5.3) |
| sibling-same-directory cases for every adapter | one | **taken** in the stub tests (test 4); the live smoke files gain one resume case each (§8.1) |
| validate parents, duplicate addresses and required fields before any mutation; define zoom, linked windows | one | **taken** (§3.2, §4.3); a window linked into two sessions is saved under each and comes back as two windows, said in the site page |
| measure RSS and peak CPU for 1, 10 and incident-sized fleets; give the attach worker a bound and retry | one | **taken** in part: the step 3 measurement (§2.9); the worker's bound is the pending set, its retry is `--retry` (§4.6); peak CPU is not measured and is not promised |
| a two-socket import test with identical numeric pane ids | one | **taken** (test 11) |
