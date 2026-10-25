# Persistent sessions: a roost fleet survives a reboot — design for #191 (#57, #51, #192, #105)

Status: **revision 3, 2026-10-25. Nothing built.** The four questions in §9
were decided by the human (A, A, A, A) and stand; revision 1 answered the
twelve blocking items of a three-reviewer read, revision 2 the fourteen of a
second, two-reviewer read, and revision 3 the five of a third (§0), without
moving any decision.
Where a fix changed what an A means in practice, that question's own text
says so. Base: `main` at `83812b1`.

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

### Revision 2: the fourteen blocking items of the second read

Two reviewers read revision 1 whole. Both kept the four §9 decisions. Each
item below changed a section and added or sharpened a test in §8.1 that the
broken design fails.

| # | item | answered in |
|---|---|---|
| 1 | body dedup and the `want` flag drop the deliberate `close`, so a closed pane comes back after a shutdown | §3.5 (`want/` keeps every trigger), §3.6a (the `closed/` record, applied to whichever save is picked), §8.1 test 8(b) |
| 2 | the paced first-attach loop `respawn-pane -k`s a shell a person has started using | §4.7 (the untouched-placeholder proof), §4.6, §9 Q1, §8.1 test 11 |
| 3 | a lock is stolen by age while its owner lives; the first-attach worker holds a lock for over 10 s | §3.5 (owner rule: pid **and** start time, never age), §4.6 (the worker's own `resuming/` lock), §8.1 tests 8 and 11 |
| 4 | "split the largest pane" fails on a valid wide layout | §4.3 Windows (split the pane with the largest side, across that side; measured), §2.7, §8.1 test 1 |
| 5 | the replaceable-session rule matches an ordinary live shell; `@roost-bootstrap` is never read | §4.3 Sessions (marker **and** placeholder proof), §1, §8.1 test 2 |
| 6 | Claude writes `.` as `-` in its project folder too, so no worktree pane would resume | §5.1 (the transcript's own `cwd`, never the folder name), §2.8, §5.6, §8.1 test 4 |
| 7 | `revive` refuses its own target as a duplicate | §4.1 step 5, §5.1a, §8.1 test 6 |
| 8 | a gone pane has no transcript, so §5.1 always refuses it | §4.1 step 1 (the record gains `transcript`; an exact-id lookup in the store), §5.1, §8.1 test 6 |
| 9 | `revive` refuses an agent that exited back to its shell, the #57 case | §3.2 (`stale_reason exited` or `nested`), §4.1 step 2, §8.1 tests 4 and 6 |
| 10 | a bare `respawn-pane` ignores `default-command`, so the first restored pane is unwired | §4.3 Windows (the command passed explicitly), §8.1 test 1 |
| 11 | `.launching` and `.failed` files are not named as overlay input | §4.6 Overlay, §8.1 test 11 |
| 12 | closing the last session on purpose restores it at the next boot | §3.6a (the `closed/` record covers the last pane too), §8.1 test 8(e) |
| 13 | duplicate keys across an interrupted worker | §4.6 (`claims/`, one per conversation, server-wide), §5.1a, §8.1 test 11 |
| 14 | test 11 passes with the `client-attached` hook deleted | §8.1 test 11 (a real client in a pty, no direct call) |

Every non-blocking note of the second read is triaged in Appendix B.

### Revision 3: the five blocking items of the third read

The same two reviewers read revision 2. Both kept the four decisions. Each
item changed a section and added a test in §8.1 that the broken design fails.
Item 1 was measured (§2.10), and the probes for items 2, 3 and 5 found that
two hooks revision 2 relied on do not exist (§2.7).

| # | item | answered in |
|---|---|---|
| 1 | the "pane untouched" proof is wrong both ways: the cursor moves with no person (a prompt drawing, an attach resizing), and typed text plus Ctrl-A leaves it where it was; a used bootstrap shell passes checks 1–3 | §4.7 rewritten: a pane waiting for its resume runs a roost **placeholder**, not a shell, and a key in it hands the pane to the person by an atomic rename the worker must win (measured, §2.10); the cursor check is gone; §4.3 bootstrap is a placeholder too; §8.1 tests 2 and 11 |
| 2 | `closed/` is compared by seconds, so a close in the second of the picked save is lost | §3.6 step 4: a removal is matched by **pane id**, never by time — ids are never reused inside one server (measured, §2.7) — so no ordering is needed; §8.1 test 8(b), 8(e), 8(g) |
| 3 | a window or session that closed because its last pane **died** is recorded as killed; a death between draining wants and listing is too | §3.6a: a kill is no longer found by comparing `shape` with a new listing. tmux takes the difference itself, **inside the removal hook**, against a pane list every structural hook refreshes, so a death refreshes it before any kill is weighed (measured, §2.7); only panes are recorded; §8.1 test 8(b2) |
| 4 | `revive` never claims the conversation, so two revives of one gone record both launch | §4.1 step 5a, §5.1a: **every** launcher takes the same `claims/` entry before it launches, and `revive` of a waiting pane takes its pending file first; §8.1 test 6 |
| 5 | the kill comparison runs across a boot change and writes old ids into the new boot's `closed/` | gone with item 3: there is no comparison with `shape`; the hook passes the running server's own boot key; §8.1 test 8(h) |

Every non-blocking note of the third read is triaged in Appendix C.

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
  by `scripts/lib/roost-identity.sh`: `session_id`, `cwd`, `harness`
  (lines 171-175). Revision 2 adds a fourth, `transcript`, written beside
  them when the harness reported one (Claude and pi), so a **gone** pane
  still has the file its resume directory is read from (§4.1 step 1). The
  addition is additive under the record's schema rule.
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
  first pane with `default-command`'s value **passed explicitly**
  (`bin/roost:199-208` records why: a bare `respawn-pane` re-runs the command
  the pane was created with and ignores `default-command`). §4.3 builds a
  restored server the same way, with the size added, and §4.6 teaches it to
  wait for a login restore or run it. Revision 2 had it mark its session
  `@roost-bootstrap`; revision 3 takes that back: `ensure_session` attaches
  at once, and nothing can prove that a live shell a person sees has not
  been used (§4.7), so its session is never replaceable. Only restore's own
  first pane, a placeholder, is (§4.3).
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

**The project folder's name is not "`/` as `-`"** (revision 2, measured
read-only by a reviewer on 2026-10-25, and counted by the coordinator):
`ls ~/.claude/projects | grep -c -- --claude-worktrees` printed 105, and a
worktree at `<repo>/.claude/worktrees/persist-design` is filed as
`-Users-<name>-w-beatzball-roost--claude-worktrees-persist-design` — the `.`
of `.claude` is written `-` too. Every roost worktree lives under
`.claude/worktrees/`. What the folder rule does with `_`, a space or a
non-ASCII byte is *not measured*. The transcript names its own directory
instead: the same reviewer counted `"cwd":"<the worktree path>"` 101 times in
one session's `.jsonl` (`grep -c '"cwd":"'`), from line 5 on. So roost never
derives a folder name to decide anything (§5.1).

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
- **Hooks available** on tmux 3.6, from `tmux(1)`: most commands have an
  `after-<command>` hook (`after-new-window`, `after-split-window`,
  `after-new-session`, `after-rename-window`, `after-rename-session`,
  `after-kill-pane`, `after-respawn-pane`, `after-move-pane`,
  `after-join-pane`, `after-break-pane`, `after-swap-pane`,
  `after-move-window`, `after-swap-window`, `after-link-window`,
  `after-select-layout`, `after-resize-pane`), plus `pane-exited`,
  `pane-died`, `window-unlinked`, `window-renamed`, `session-closed`,
  `session-renamed`, `window-layout-changed`, `client-attached`,
  `client-detached`. **Not every command has one** (revision 3, measured,
  tmux 3.6, once): `set-hook -g after-kill-window[98]` and
  `after-kill-session[98]` both fail with `invalid option`. A `kill-window`
  fires `window-unlinked`; a `kill-session` fires `session-closed` then
  `window-unlinked`; the death of a window's last pane fires `pane-exited`
  then `window-unlinked`. So by hook name a killed window and a window whose
  last process exited look the same, and revision 2's kill rule, keyed on
  `after-kill-*`, could not have seen either kill. The `after-*` hooks that
  exist on 3.6 exist on tmux 3.2 too (the floor roost checks);
  `window-layout-changed` fires on every resize and is **not** used (§3.4).
- **A kill is seen inside tmux, at hook time** (revision 3, measured, tmux
  3.6, once, on a throwaway `-L` server under a temp `TMUX_TMPDIR` and
  `HOME`). Every structural hook ran `set -gF @ids
  "#{S:#{W:#{P:#{pane_id} }}}"` (the server's pane ids, by tmux's own
  format loop); each removal hook — `after-kill-pane`, `window-unlinked`,
  `session-closed`, `pane-exited` — first ran `run-shell -b` with the old
  value and the new loop in its command, expanded **when the hook ran**, then
  refreshed. Results: `kill-pane %1` → `BEFORE=%0 %1 %2 %3 AFTER=%0 %2 %3`;
  `kill-session` of a session that was not the last → `session-closed
  BEFORE=%0 %1 %2 AFTER=%0 %1`, and the `window-unlinked` after it empty; a
  pane that died in its own window, and one in its own session →
  `pane-exited %3`, and the `window-unlinked` and `session-closed` after it
  each with BEFORE equal to AFTER; a death and a `kill-pane` one after the
  other within 20 ms → the kill's BEFORE no longer held the dead pane
  (`BEFORE=%0 %7 AFTER=%0`). `break-pane`, `move-window` and `join-pane`
  fired `window-unlinked` with the same set in a different order. A
  `SIGTERM` to the server, `kill-server`, and `kill-session` of the **last**
  session ran **no** hook at all. §3.6a rests on these.
- **Ids are never reused inside one server** (measured, the same probe):
  three `new-window`/`kill-window` pairs gave `@5 %8`, `@6 %9`, `@7 %10`;
  two `new-session`/`kill-session` pairs gave `$4 @8 %11`, `$5 @9 %12`. A
  pane id that is gone stays gone for the server's life, which is what
  lets §3.6 step 4 match a removal by id with no clock.
- **A death and a kill fire different hooks** (measured on a throwaway
  socket, tmux 3.6, once): a process that exits on its own fires
  `pane-exited` and not `after-kill-pane`; `kill-pane` fires `after-kill-pane`
  and not `pane-exited`; `kill-window` fires `window-unlinked`. At
  `pane-exited` time the pane is already out of `#{window_panes}` and its pane
  options are no longer readable in the hook's format. §3.6's `trigger` key
  rests on the first fact; the third is why `roost close` records its own
  intent (§3.6a). `pane-exited` names its pane in `#{hook_pane}`, and
  `kill-pane`, `kill-window` and `kill-session` fire hooks that name **no**
  pane (measured on tmux 3.4 and 3.6 for #98; `tmux/roost.conf` l.236-240
  records it), which is why §3.6a finds a killed pane by comparing listings.
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
  the saved layout.
- **The split direction matters as much as the pane** (revision 2; both
  reviewers measured the failure, then this design measured its rule, tmux
  3.6, once). Splitting the largest pane by area in tmux's default direction
  (`-v`) fails on a short wide window: a 200x10 session stops at split 4
  with `no space for new pane`, and on 381x24 `-v` stops at 9 panes where
  `-h` reaches 81. The rule §4.3 uses — split the pane whose **larger side**
  is the largest, **across that side** (`-h` when width ≥ height in cells,
  else `-v`) — reached the asked count in every case tried: 200x10 → 6 and
  30, 200x50 → 6, 80x24 → 12, 381x24 → 30, 381x86 → 40. A saved six-pane
  **stacked** layout at 200x50 applied with `select-layout` to six panes
  this rule built side by side, and the result matched the saved string but
  for ids and checksum; so did a six-pane side-by-side layout at 200x10. The
  probe ran on a throwaway `-L` server under a temp `TMUX_TMPDIR` and
  `HOME`, with `tmux -f /dev/null`, killed by name; it loops: list the panes
  as `#{pane_id} #{pane_width} #{pane_height}`, pick the largest side,
  `split-window -d -h|-v -t ID`, until the count or a refusal.

### 2.8 The resume table

What each adapter's resume step runs, where the key comes from, how the key
is checked before anything is launched (§5.1a), and what to expect on screen.
The exit column is `scripts/lib/roost-close.sh`'s table.

| harness | resume by id | key recorded by roost today | store check before launch | source if roost has no key | on resume | dialogs a resume can open | exit |
|---|---|---|---|---|---|---|---|
| claude 2.1.310 | `claude --resume ID` in the transcript's own `cwd` (§5.1) | `@roost-session` at SessionStart; record `session_id` and `transcript` | the recorded transcript file exists, else exactly one `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/<id>.jsonl` exists (a glob on the id, no folder name derived) | transcripts under `projects/`, narrowed by the measured folder rule and kept only when their own first `cwd` is the pane's directory, newest first (printed, never run: §5.6) | prompt in 1 s (fake API), conversation on screen, same id | folder trust in an untrusted directory | `/exit` |
| codex 0.163.0 | `codex resume ID` in the session's directory | **none** under the shared app-server (#145) | a `$CODEX_HOME/sessions/**/rollout-*-<id>.jsonl` exists | the rollout files whose `session_meta.cwd` is the pane's cwd, newest first (printed, never run: §5.6) | prompt in 1 s, conversation on screen | "Working directory · resume" when the directory differs; "Hooks need review" when roost's hooks are not yet trusted | `/quit` |
| opencode 2.1.3 | `opencode -s ID` | `@roost-session` via `roost identify` (tested, not run live) | `opencode session list` names the id — *not measured*; until it is, roost **prints** the command and does not run it | none usable: a database | *not measured*; **creates** the session if the id is unknown | *not measured* | `/exit` |
| copilot 1.0.103 | `copilot --resume=ID` (any directory; it returns to the session's own) | `@roost-session` via `roost identify` | `$COPILOT_HOME/session-state/<id>/` exists | `$COPILOT_HOME/session-state/*/workspace.yaml` naming the cwd (printed) | prompt in 9 s, conversation on screen, same id | folder trust and extension permission on a home that has not answered them | `/exit` |
| pi 0.81.1 | `pi --session PATH` (the recorded transcript; measured to resume with no dialog from any directory, §2.4), else `pi --session ID` in the session's directory | `@roost-session` and `@roost-transcript-path` via `roost identify`; record `transcript` | the recorded session file exists, else exactly one `$PI_CODING_AGENT_DIR/sessions/*/*_<id>.jsonl` (a glob on the id) | session files under `sessions/`, newest first (printed); pi's folder encoding for a path with a `.` is *not measured* (probe in build step 6) | prompt in 5 s, conversation on screen, same id | "Fork this session into current directory?" when the id is used from another directory | `/quit` |

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
this suggests about the incident, as a **hypothesis** the step 3
measurement tests, not a finding: 35 agents at rest are about 11 GB on a
128 GB machine, so what was "too heavy" at boot was more likely 35 cold
starts at once, which pacing spreads, than the resident set, which pacing
does not reduce (§5.5). RSS alone cannot show the cause.

### 2.10 A placeholder pane, measured (revision 3)

What §4.7 now rests on. Measured on tmux 3.6, macOS 26.3, once, on a
throwaway `-L` server with a second throwaway server for the client, under a
temp `TMUX_TMPDIR`, `HOME` (whose `.bashrc` printed a banner and set a
prompt) and `XDG_*`, both servers killed by name. The probe placeholder was
an 18-line `sh` script: print `waiting to resume claude - press any key for
a shell`, `stty raw -echo`, read one byte with `dd bs=1 count=1`, read and
throw away whatever else was typed (`stty -icanon min 0 time 0`, one more
`dd`), restore the terminal, then `mv PENDING PENDING.taken`; on success
print one line and `exec` an interactive shell, on failure print `resuming
claude now` and wait to be replaced.

| case | result |
|---|---|
| a **shell** pane, at placement and 1.5 s later | cursor `7,5` both times — this bash had drawn its prompt by the first read; the reviewer's zsh with a banner had not (`0 0`, then `54 12`), so the cursor says nothing |
| the placeholder, at placement and 1.5 s later | `pane_pid` unchanged; no rc file runs, so no banner; the pending file still `B` |
| a real client attached, 80x20, from a pane of the second server | the window went from 200x50 to **80x19**; both panes kept their `pane_pid`; the placeholder still waited; the pending files unchanged. **An attach is not a key.** |
| `send-keys -l 'echo keep-me'` then `C-a` into a placeholder (the reviewer's typed-text case) | the first byte ended the wait; the file became `C.taken`; a following worker `mv C C.launching` **failed** (`No such file or directory`); the shell started with an **empty** line (the rest of the text was thrown away; the `C-a`, which arrived after the drain, reached the shell, where it moves to the start of an empty line) |
| the worker claims first (`mv D D.launching`), then a key | the placeholder's own `mv` failed; it printed `resuming claude now` and did not start a shell; a `respawn-pane -k` then replaced it (`pane_pid` changed, `RESUMED` on screen) |
| Enter in a waiting placeholder | `B.taken`, a shell with the banner and its prompt, `pane_pid` unchanged (the shell was `exec`ed) |
| `#{pane_current_command}` of the placeholder | `sh` at once, then **`bash`** — macOS's `/bin/sh` runs bash — so the command name cannot tell a placeholder from a shell, and §4.7 does not use it |

So the rename is the proof: one `mv` of one file, raced by the worker and by
the person's first key, and exactly one of them wins. What was not measured:
the placeholder under Linux's `dash` as `sh` (its `dd` and `stty` are the
same POSIX tools; a step 5 test runs it in the Ubuntu container), and a key
that arrives between the worker's rename and its respawn, which is the
"resuming now" row by construction.

---

## 3. The saved shape

### 3.1 Where it lives

```
${ROOST_SHAPE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/roost/shapes}/<server>/
  shape               the newest save
  history/<stamp>-<gen>  the saves before it, newest ROOST_SHAPE_KEEP (default 100)  (§3.6)
  gen                 the save counter, one integer                                 (§3.5)
  want/<trigger>[.<pane>]  one file per wanted save while the saver is busy        (§3.5)
  lock/               the saver's mkdir lock, holding its pid and start time        (§3.5)
  restoring/          present while a restore is building panes, same owner rule    (§3.5)
  resuming/           the first-attach worker's own lock, same owner rule           (§4.6)
  closed/<boot>/      one file per removal on purpose, naming pane ids            (§3.6a)
  aliases/<boot>      the old-id → new-id map of the restore that made boot <boot>  (§5.4)
  pending/<boot>/     the resume keys of panes placed but not yet resumed           (§4.6)
  claims/<boot>/      one entry per conversation being launched, by any launcher    (§4.6)
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
shapes, the pending keys, the claims, the closed record and the alias maps;
the pane records beside them are
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
id $0
active 1

window roost:1
id @0
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
stale_reason nested
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
  `trigger` is every cause the save covered, space separated and sorted
  (`trigger after-kill-pane pane-exited`), because a saver that coalesced
  several wants must not keep only one (§3.5). Two saves are **the same**
  when everything after the header block is byte identical; the header alone
  never makes a save worth writing. That is safe because no decision rests
  on a save's label alone: a deliberate removal is recorded on its own, in
  `closed/` (§3.6a), whether or not its save was written.
- **Required keys.** Header: `roost-shape`, `server`, `boot`, `saved`,
  `gen`, `trigger`. `session`: its address and `id`. `window`: its address,
  `id`, `layout`. `pane`: its address, `id`, `cwd`. A block missing one is a
  named refusal of the whole file (exit 16), checked before the first tmux
  command. The `id` lines (`$N`, `@N`, `%N`) are history for §3.6a and §5.4,
  never a target.
- **A linked window** (one window in two sessions) is saved under each
  session, with the same `id`, and comes back as **two** windows: tmux has
  no way to recreate a link from a listing that names it twice, and a
  restore that linked them would need a rule for which copy owns the panes.
  The site page says so; test 5 pins it.
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
  `stale_transcript`**, with **`stale_reason exited`** (a shell; this rule
  holds for all five harnesses, because a shell name is known) or
  **`stale_reason nested`** (another harness's command), or **`stale_reason
  other`** (revision 3, F N5: any other command — an editor, a `sleep` —
  with the identity still set), so a reader sees what the pane last
  reported and why. Restore prints all three and **never resumes any**
  (§5.6): a person may have exited on purpose, and a nested key is not the
  pane's. `revive`, which a person asks for by pane, resumes `exited` and
  refuses `nested` and `other` (§4.1 step 2). The keys are **absent, not
  empty, otherwise**: a reader tests presence.
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
| a session is created or closed (a `kill-session` included), renamed | `after-new-session[98]`, `session-closed[98]`, `after-rename-session[98]` | placement changed. There is no `after-kill-session` hook (§2.7) |
| a window is created, closed (a `kill-window` included), renamed, moved, swapped, linked | `after-new-window[98]`, `window-unlinked[98]`, `after-rename-window[98]`, `after-move-window[98]`, `after-swap-window[98]`, `after-link-window[98]` | placement or a name changed. There is no `after-kill-window` hook (§2.7) |
| a pane is split, exits, dies under `remain-on-exit`, is killed, respawned, moved, joined, broken out, swapped | `after-split-window[98]`, `pane-exited[98]`, `pane-died[98]`, `after-kill-pane[98]`, `after-respawn-pane[98]`, `after-move-pane[98]`, `after-join-pane[98]`, `after-break-pane[98]`, `after-swap-pane[98]` | a pane came, went or changed place; `revive` uses respawn; `pane-died` is how a resume that exited at once is seen (§4.6) |
| a layout is chosen or a pane resized **by command** | `after-select-layout[98]`, `after-resize-pane[98]` | a person meant it; a drag fires `window-layout-changed`, which is not used |
| `roost spawn`, `split`, `view` set `@roost-name` | a direct call at the end of each branch in `bin/roost` | a name changed with no tmux hook for it |
| `roost identify` writes (`ROOST_IDENTITY_WROTE=1`) | a direct call in `roost_identity_stamp`'s caller, only when it wrote | the resume key changed; when nothing changed the one-read-then-bail path is untouched |
| `roost close` has seen the pane go | a direct call at the end of `close`, `--trigger close`; **before** it sends the exit command, `close` writes `closed/<boot>/close.<N>` (§3.6a) | the removal was deliberate, and `pane-exited` cannot say so (§2.7); the `closed/` file, not this save, is what carries it (§3.6a) |
| `roost restore` has finished building | one call, `--trigger restore`, after the `restoring` marker is removed (§3.5) | one coherent save for the whole restore instead of sixty |
| `roost persist on` | one call, `--trigger persist-on` | a fleet that is already running is saved the moment persistence is wanted |
| the user's own `roost save` | the verb, `--trigger save` | a person asked |

**The pane list, kept by tmux** (revision 3, items 3 and 5). Every hook in
the first three rows runs one more command, **synchronously and first**:
`set -gF @roost-ids "#{S:#{W:#{P:#{pane_id} }}}"`, the server's pane ids by
tmux's own format loop. It runs inside the server, costs no process, and is
what §3.6a's kill record is a difference against. The removal hooks
(`after-kill-pane`, `window-unlinked`, `session-closed`) put the **old**
value and the new loop into their `run-shell -b` command line before the
refresh, so both are expanded when the hook runs, not when the save runs
(§2.7 measured it); `pane-exited` passes `#{hook_pane}` as before. A hook
slot holds a command list, so this is one line per hook in `roost.conf`.

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
enabled and then crashed needs no later event to be on disk. `doctor` says
both halves in one line, `persist: saving on; login restore off (roost
persist on …)`, so "off" is never read as "nothing is written" (§4.5).

### 3.4a The one switch for saving

Whether a save is written is decided in **one function**,
`roost_shape_saving` in the shape library (`scripts/lib/roost-shape.sh`),
which every writer of §3.4 calls first and which prints the shape directory
or nothing. Today it reads only `ROOST_SHAPE_DIR` (unset: the default path;
empty or relative: nothing). The hooks, the direct calls and `roost save`
never test anything else.

The human has not yet confirmed this reading (§9, the paragraph after Q4).
If the answer is that **saving is opt-in too**, the function also requires
the server's `persist` marker, and these sections change, and only these:

- §3.4 — this paragraph and the one above: saving starts at `persist on`.
- §4.4 — `off` stops saving as well as the service (the shapes stay);
  `status` reports one state, not two.
- §4.5 — the doctor line becomes `persist: off (nothing saved; roost
  persist on …)`.
- §4.3 — `restore` with no shape gives exit 2 with a hint naming `persist
  on`.
- §5.9 — the "server dies" row says "restored from the shape **when
  persist was on**".
- §7 — `roost help` and the site page say saving needs `persist on`.
- §8.1 — test 8 runs with the marker set; test 10 gains "no marker, no
  shape".
- §9 — the paragraph after Q4.

`revive` of a live or gone pane (§4.1) reads pane options and the record,
not the shape, so it works either way.

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

1. `save --auto` first writes what only it knows (revision 3): a removal
   hook's kill difference goes to `closed/<boot>/` and a `pane-exited`
   pane's death note likewise (§3.6a), `<boot>` being the boot key the hook
   passed, which is the running server's. It does this before, and
   whatever happens to, the lock, so a held saver or a held `restoring/`
   never delays or drops it. Then it records **its own** want: it creates
   `want/` if missing and writes an empty file `want/<trigger>`, or
   `want/<trigger>.<%N>` when the hook named a pane (`pane-exited` and
   `pane-died` pass `#{hook_pane}`, §2.7). Then it tries `mkdir lock`. If the lock exists it exits 0 at once: the saver that
   holds it will see the want. A want is a file of its own, never a single
   flag, so coalescing keeps every cause (revision 2, item 1).
   **The owner rule** (revision 2, item 3): the lock holds the owner's pid
   and its start time (`ps -o lstart= -p PID`, read once when the lock is
   made). A lock is broken and taken over **only** when that pid is not
   running, or is running with a different start time (the pid was reused).
   **Never by age**: a saver that is slow, or stopped, keeps its lock, and
   the wants wait for it. A saver killed mid-write leaves a dead pid, which
   the next caller sees. A lock held by one live owner for over 60 s is a
   `doctor` warning naming the pid, not a takeover.
2. The saver loops: move `want/` aside atomically (`mv want want.<pid>`;
   a caller whose `touch` races the move fails, makes `want/` again and
   touches once more), read its file names as this round's triggers, remove
   it; list the server; **check consistency**
   (every pane's window and session appear in the other two listings, else
   list again — the three listings can straddle a split or a kill); build
   the file; apply the pending changes this round's wants name (§4.6: a
   `pane-died.<%N>` renames that pane's `.launching` file to `.failed
   died`); compare its body to `shape`'s body (§3.2:
   everything after the header); if the same, write nothing; else `mktemp`
   in the shape directory, write with every trigger of the round in the
   header, hard-link the current `shape` into `history/<stamp>-<gen>`, `mv`
   over `shape` (rename(2), the record's rule), increment `gen`. Then, while
   `want/` exists, loop again. `gen` is the counter that makes two saves in
   one second two distinct history names and orders them.
3. `rmdir lock`. Then one more look: if `want/` appeared between the last
   loop check and the `rmdir`, try `mkdir lock` again and go to 2; if that
   fails, another saver has it.
4. While `restoring/` exists (restore makes it before its first tmux command
   and removes it after its last, holding the restorer's pid and start time
   under the **same owner rule**, never age), `save --auto` writes its want
   and exits without taking the lock; restore's own final save (§3.4) is
   what publishes the result.

A reader never sees a partial file; the newest `shape` is always the newest
listing that differed from the one before; and a burst is a few writes, not
ten. The pending record (§4.6) is read inside step 2, so a pane with no
identity whose `%N` has a pending file — `%N`, `%N.launching`,
`%N.failed` or `%N.taken`, all four alike — is written with that key. The
saver never compares a listing with `shape` to decide what was removed; that
comparison is what crossed a boot change and named dead panes' windows as
killed in revision 2.

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
something a person or roost did on purpose — `after-kill-pane` is a kill
typed or scripted, and `roost close`'s own save after the pane is gone
carries `close`. A `kill-window` or `kill-session` has no hook of its own
(§2.7) and arrives as `window-unlinked` or `session-closed`, so its save is
**labelled** a death save; that is safe, because the label only steers
which save is picked and §3.6a, not the labels, keeps a deliberate removal
removed. A save whose `trigger` list holds **any** death is a death save —
so a coalesced `after-split-window pane-exited` round is one too, and inside
a shutdown window the reading rule walks past it (revision 3, F N10). That
costs at most the one split made in the same round as a death, during a
shutdown, and the split's pane was a fresh shell.

**The reading rule.** A restore with no `--from` picks:

1. The newest `shape`, unless there is **shutdown evidence**: the OS records
   the last shutdown, and the newest save is a death save within the
   shutdown window.
2. With shutdown evidence: the newest save, walking back through
   `history/`, that is **not** a death save, or that is older than the
   window.
3. No readable shutdown record: the newest `shape`, and one stderr line,
   `no shutdown record readable; restoring the newest save — roost restore
   --list shows the others`.
4. **Always, whichever save was picked** (and for `--from STAMP-GEN` too;
   not for `--from FILE`, which is the caller's own choice): remove from
   it every pane whose `id` a file in `closed/<boot>/` names, for that
   save's `boot` (§3.6a), **with no time comparison at all** (revision 3,
   item 2). A pane id is never reused inside one server (§2.7, measured), so
   a save of boot B that holds `%N` was listed while `%N` was alive, which
   is before its removal; a save that does not hold it has nothing to
   remove. Revision 2 compared seconds and lost a close in the picked
   save's own second; ordering by `gen` instead, as the review suggested,
   would still lose one case: a save whose listing was taken before the
   close and published after it carries a higher `gen` than the close saw.
   An id needs no order. A pane named only by a kill file and also by a
   death note is **not** removed (§3.6a's belt); a `close.` file removes it
   regardless. A window that lost panes this
   way takes tmux's default layout with one stderr line, since
   `select-layout` needs the saved count (§2.7); a window left with no
   pane, and a session left with no window, are not created. What remains
   is restored; if nothing remains, `restore` prints `nothing to restore:
   every saved pane was closed on purpose` and exits 0.

So every kill and every `roost close` stays done, whether or not its own
save was written or kept its label; only an agent whose `/exit` a person
**typed** inside the shutdown window comes back one time too many, at its
prompt, spending nothing.

The shutdown record, measured on macOS 26.3 once: `last reboot` prints
`shutdown time Tue Oct 20 15:05` above `reboot time Tue Oct 20 15:06`, minute
resolution, so the window is the shutdown minute and the minute before it;
`sysctl kern.boottime` gives the boot second. **Every comparison is in epoch
seconds**: `saved` is UTC (§3.2) and converts with `date -u`; `last reboot`
prints local time with no year, so the year is taken from the boot second
(`kern.boottime`), and a shutdown month later than the boot month means the
year before (a shutdown on 31 December, a boot on 1 January). The local
time converts with the machine's zone, as `last` wrote it. On Linux the sources are `last
-x shutdown` where wtmp exists and `journalctl --list-boots` where it does
not; *not measured*, a step 4 probe, and until it lands Linux takes rule 3.

`roost restore --list` shows every save with its stamp, `gen`, `trigger` and
counts and marks the one the rule would pick; `--from STAMP-GEN` picks one by
hand; the at-login restore writes which it chose and why to `login.log`.

### 3.6a The closed record: a deliberate removal stays removed

Revision 1 let a save's label carry "this was on purpose". Both reviewers
showed two ways to lose it: §3.2's body compare drops `close`'s save when the
`pane-exited` save already wrote the same body, and a single `want` flag
dropped the cause of every caller but one. And closing the **last** session
ends the server, so no save ever shows the fleet empty, and the next boot
restored what a person closed. So the intent is written down by itself, at
the moment it is known, in `closed/<boot>/` — a directory, one 0600 file
per removal, each naming **pane ids only**, `%N` per line, the ids of that
boot (revision 3: one file each, so a failed `close` can take its own claim
back without editing a file others append to; panes only, because a window
or session block left with no pane is dropped by step 4, and naming a
window would also drop a pane that had moved out of it before the kill):

- **`roost close`** writes `close.<N>` naming `%N` **before** it sends the
  exit command, and removes that file if the pane is still there when
  `close` gives up (its exit 1 or 2), so a failed close leaves no claim.
  This is roost's own code, so it holds whatever tmux runs at shutdown —
  including for the last pane of the last session.
- **A kill typed or scripted** — `kill-pane`, `kill-window`,
  `kill-session`. tmux names no pane in any of their hooks, and the last
  two have no `after-` hook at all (§2.7). So the difference is taken
  **inside tmux, at the moment of the removal hook**: `after-kill-pane`,
  `window-unlinked` and `session-closed` each pass the server's pane list
  as it stood after the previous structural event (`@roost-ids`, §3.4) and
  as it stands now; the hook's own process writes `kill.<stamp>-<pid>`
  naming the panes in the first and not the second (§3.5 step 1). A
  **death** never shows up there: its `pane-exited` hook refreshes
  `@roost-ids` first, so by the time any later hook compares, the dead pane
  is in neither list. Measured (§2.7): a pane dying in its own window, or
  its own session, gave an empty difference at the `window-unlinked` and
  `session-closed` that followed; a death followed within 20 ms by a
  `kill-pane` gave a difference holding only the killed pane; moves, breaks
  and joins gave none. Two guards: a difference whose new list is **empty**
  writes nothing (the server is ending; the last-session case below), and a
  difference is written for the boot key the hook itself passed, never a
  boot read from `shape` (item 5).
- **A death note.** `pane-exited`'s process writes `died.<N>`. Step 4 never
  removes a pane on a **kill** file's word when a death note names it. A
  `close.` file always wins: `roost close` ends in a death by design (the
  harness exits on its exit command), so a closed pane has both. This is the
  belt for the one ordering the bullet above does not prove: tmux runs a
  death's hook from its global queue and a typed kill's hook from the
  client's, and if a hook a **user** installed without `-b` held the global
  queue at that moment, the kill's difference could run first and name the
  dead pane. Read from the tmux source, not raced; the note costs one file.
- **The last session, and the server itself.** Measured (§2.7): `tmux
  kill-session` of the last session, `tmux kill-server`, and a `SIGTERM` to
  the server run **no** hook, so nothing here sees them; an `exit` typed in
  the last pane is the same case (not run, the same path in tmux). That is
  the named gap of §10, now measured rather than probed; the remedy is
  `roost close` or `roost persist off`. The same measurement is good news
  for §3.6: a server ended by `SIGTERM` at shutdown wrote no hook at all,
  so no teardown chain came from the server itself; only panes whose own
  processes died first can add death saves.
- **Automatic teardown writes no kill file.** A pane that died is never in
  a difference, and a `session-closed` or `window-unlinked` that followed
  only deaths has an empty difference, so a shutdown, a crash or a lost ssh
  leaves the fleet recoverable. Revision 2's residual — a kill during a
  shutdown's teardown recording unnamed deaths as kills — is gone with the
  listing comparison.

The reading rule's step 4 applies it to whatever save is picked. The
directory is read only for the boot a picked save names, and the next
`--at-login` removes directories for boots that no shape in the ring names.

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
   placed by a restore and not yet resumed: its pending record (§4.6), which
   step 5a claims like the worker does; a gone
   `%N` on this boot: the record's `harness`, `session_id`, `cwd` and, since
   revision 2, `transcript` (§1, §3.3). A record written before revision 2
   has no `transcript`; then the adapter's **exact-id lookup** supplies it —
   the one store file whose name carries that id (§2.8's store-check
   column: `projects/*/<id>.jsonl` for Claude, `sessions/*/*_<id>.jsonl` for
   pi), refused when there are none or more than one. That is the key's own
   file, not the newest file in a directory, so it is not a guess.
2. The identity does not agree with the pane's command (§3.2's rule):
   - **`nested`** — the command is another harness's (a Claude pane carrying
     a codex key) — or **`other`** (an editor, a `sleep`): exit **13**, the
     keys printed as stale, nothing resumed.
   - **`exited`** — the command is a shell and the identity is still on the
     pane: this is #57's everyday case (a Claude that crashed, or that a
     person `/exit`ed), so `revive` **carries on** with the identity as the
     key; step 5's store check still guards it, and step 7 treats the shell
     as a person's (it refuses when the shell has a child process, unless
     `--force`).

   No harness, or no key:
   exit **13**, `roost revive: '%5' has no recorded conversation (harness
   claude, no session id)` — and for Claude the §5.6 line listing what the
   store holds for that directory, printed, not run.
3. The harness is not on `PATH`: exit **14**, naming it.
4. Choose the directory by §5.1. The directory is gone: exit **15**,
   `directory … no longer exists; not resuming elsewhere` (§2.1: Claude would
   silently re-file the conversation).
5. **Check the store** (§5.1a, the column in §2.8). A miss: exit **13**,
   `roost revive: claude no longer holds 3fa3…; the pane is untouched`,
   and the pane is untouched — nothing has been killed yet. A key that
   **another** live pane on this server carries in `@roost-session`, or that
   a live claim in `claims/<boot>/` holds for another pane (§4.6): exit
   **13**, naming that pane; one conversation is never open in two panes.
   The **target pane itself** is exempt, for an in-place revive only: it is
   the pane being replaced, and step 7 ends its process before the resume
   starts. With `--new-window` there is no exemption — the target keeps
   running, so its own key counts as another owner and the answer is 13.
5a. **Claim, before anything is launched** (revision 3, item 4). Step 5
   only **looks** for an owner; revision 2 left `revive` there, so two
   revives of one gone record, the second while the first sat in a trust
   dialog with no identity yet, both launched. Now every launcher — this
   verb in place or in a new window, a hand restore, the first-attach
   worker — takes the same claim, the one §4.6 defines:
   - **A waiting pane** (one with a pending file `%N`): `mv %N
     %N.launching` first. It fails when the worker or the person's key
     (`%N.taken`, §4.7) got there first: exit **13**, `'%N' is already
     being resumed` or `'%N' was taken by a key; roost revive it again to
     resume`, nothing launched. A `.taken` or `.failed` file is renamed
     the same way, since a person is asking now.
   - **The conversation**: `mkdir claims/<boot>/<harness>-<session_id>`,
     and write into it this run's pid and start time (§3.5's owner rule)
     and the target pane id — for `--new-window` and a gone pane, the new
     pane's id once `new-window` has made it. `mkdir` failing means
     another claim exists: it is this pane's own (an in-place revive of a
     pane whose earlier launch never identified) — taken over; it names
     another pane that still exists, or no pane yet and a live claimer —
     exit **13** naming it, nothing launched, and the pending file (if
     this run renamed it) renamed back; it names a pane that is gone, or no
     pane and a dead claimer — stale, taken over.
   - **Release** only what this run took (revision 3, C N1): a refusal or a
     failure after the claim removes this run's claim and puts back this
     run's rename; a claim found and refused is never touched. A launch
     that succeeds keeps its claim until identity lands with the same id,
     the pane dies (`pane-died` under `remain-on-exit`, or `pane-exited`),
     or identity lands with a **different** id (§4.6).
6. Build the command from the resume table (§2.8), through
   `scripts/roost-pane-shell` on a wired server, as an argv, never a string
   for a shell.
7. A live pane: clear every option the old process owned — `@agent_state`,
   the identity four, the reply and job options the record library writes —
   because `respawn-pane` keeps options (§2.7) and a resume into a trust
   dialog fires no hook that would overwrite an old `done`; keep
   `@roost-name`. Set `remain-on-exit failed` on the pane, then `respawn-pane
   -k -c CWD <command>`, the command always passed (a bare `respawn-pane`
   re-runs the pane's creation command, §1) — the pane keeps its `%N`
   (§2.7), so nothing that addresses it breaks. Refused on a `working` or
   `blocked` pane unless `--force`, the `close` rule, because `-k` kills the
   agent mid-turn; refused the same way on a **shell** pane whose shell has
   a child process (`pgrep -P #{pane_pid}`), because that is a person's
   job. A **placeholder** pane (§4.7) needs neither check: step 5a's rename
   already proved no person took it. A gone pane, or
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
  window cannot be built) **and the placeholder of §4.7 as its one pane's
  command**, in bootstrap form (`roost restore is placing this session -
  press any key for a shell`), watching the file `restoring/bootstrap`,
  which restore writes **before** `new-session` — then `roost wiring
  apply`. Revision 3 drops the `@roost-bootstrap` pid marker: the file is
  the mark, and nothing but restore writes it (not `ensure_session`, §1).
  Running: use it.
- **Sessions.** A saved session whose name exists is **skipped and named**
  (`roost restore: session 'litro' exists — skipped, 9 panes not restored`),
  and every window and pane inside it with it; a partial fleet is never
  merged into a live session (#51 requirement 4) — **except a replaceable
  session**, defined by a positive mark, not by its look. Revision 3 (item
  1) makes the mark provable: a session is replaceable only when this run
  of restore created it and wins `mv restoring/bootstrap
  restoring/bootstrap.used` — the same rename race as §4.7's, which the
  placeholder runs as `mv … bootstrap.taken` on the first key — and it
  still holds exactly one pane, the one restore made. A rename restore
  loses means a key arrived. Eligibility therefore ends at the first
  input, which is the only thing a person can do to a placeholder; it does
  **not** end at an attach, because an attach is not use (§2.10 measured
  it: the pane, its pid and its wait unchanged), and ending it there would
  let a bare `tmux attach` during placement cost the whole first saved
  session. This is only ever restore's own first pane, used within the same
  run. A session `ensure_session` made, an ordinary one-shell session a
  person made, and a bootstrap a person has pressed a key in all fail the
  test and are skipped with exit 12. The one cost, said in the report and
  the site page: `roost` then `roost restore` typed **inside** it finds the
  saved session of the same name existing and skips it — revision 2 also
  could not replace that pane, since it was running the restore. Run
  `roost restore` from a plain terminal, or let `roost` do it at boot with
  `persist on` (§4.6). A replaceable session is **used**: its
  one window becomes the saved first window (renamed, resized), its one pane
  the saved first pane. Others are created in saved order with `new-session
  -d -s NAME -x W -y H` for a detached server, so every session has room.
- **Windows.** `new-window -d -t SESSION:INDEX -n NAME -c CWD` at the saved
  index (a sparse set and `base-index` come back as saved; `renumber-windows`
  on the user's conf would move them and is noted in `--dry-run`); then
  `split-window -d` until the saved pane count exists, each time on **the
  pane whose larger side is the largest, across that side** (`-h` when its
  width ≥ its height in cells, else `-v`). §2.7 measured why both halves
  matter: splitting the newest pane stops at four on 24 lines, and the
  largest pane split in tmux's default direction stops at four on a 200x10
  window; the rule reached every count tried. If a split is still refused,
  the window keeps the K panes it has, tmux's default layout, and one
  stderr line naming the saved panes not placed (exit 13); nothing else in
  the restore stops. The K panes take the **first K** saved pane blocks in
  order; each block after them is listed with its key and its §5.6 line, so
  its conversation is named and can be revived by hand, and gets **no**
  pending file (revision 3, F N9). Then `select-layout` with the saved
  layout; then, walking the panes in index order against the saved pane
  blocks in order, `respawn-pane -k -c CWD "<default-command's value>"` for
  **every** pane, the first included — or, for a pane that will be resumed
  (a key, not stale, its directory present, and not `--no-resume`), its
  pending file written **first** (§4.6) and then `respawn-pane -k -c CWD
  "<default-command's value>" <placeholder> PENDING HARNESS`, so the pane
  **waits in a placeholder**, not a shell (§4.7) — the value read once with
  `show-options -gqv
  default-command` after `roost wiring apply` and **passed explicitly**,
  because a bare `respawn-pane` re-runs the pane's creation command and
  ignores `default-command` (a reviewer measured it on tmux 3.6: the pane
  made before `default-command` was set did not run it; `bin/roost:199-208`
  says the same). So creation order does not have to match cell order and
  every pane is a wired shell, or a wired placeholder, in its own saved
  directory; no agent has run in them yet. `select-layout` failing (`invalid layout` on an edited string)
  leaves tmux's default layout and one stderr line. `zoomed 1`: `resize-pane -Z` after the layout. Pane names re-stamped;
  `@roost-was %OLD` on every pane; the alias map written (§5.4); the saved
  active window and pane selected. Windows are made with their **shells**,
  through `default-command`, so a pane with no conversation is a shell in its
  old directory at this point.
- **Directories.** A `cwd` that no longer exists → the home directory **and**
  a stderr line per pane; such a pane is never resumed (§4.1 step 4).
- **Resumes.** Unless `--no-resume` (§9 Q2: resume is the default), for each
  pane that has `harness` and `session_id` (never `stale_*`), in saved order,
  **shells first then agents**, `--pace` seconds apart (default **2**, the
  incident's number). Revision 3: a hand restore runs **the same loop as
  the first-attach worker** (§4.6), in the foreground, over the pending
  files placement just wrote — so the placeholder, the rename race, the
  store check and the claim per conversation in `claims/<boot>/` are one
  code path, and no id is launched twice, in this run or by any other
  launcher (§5.1a). A person who presses a key in a placeholder while a
  minute-long hand restore paces through the fleet keeps that pane as a
  shell. A missing harness, a store miss, a gone directory or a duplicate
  id leaves a shell with a note; a dialog is left on screen. `--recent DAYS` skips the resume (not the placement) of a
  pane whose transcript, when recorded, is older than DAYS by mtime; a pane
  with no transcript path is always resumed. `--only SEL` (repeatable)
  restricts both placement and resume to a session name, a `SESSION:WINDOW`,
  or an old `%N`. The `--at-login` form **stops before this step**, leaving
  the pending record and its placeholders for the first attach (§4.6);
  `--resume` **starts here**, from the pending record, on panes that
  already exist.
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
    `COPILOT_HOME`, `PI_CODING_AGENT_DIR` (§2.8's store checks read them),
    and `OPENCODE_CONFIG_DIR`. That last one is **not** what roost reads for
    opencode — the adapter table resolves opencode's home from
    `XDG_CONFIG_HOME` (`scripts/lib/roost-adapters.sh:34`), which is already
    in the file; `OPENCODE_CONFIG_DIR` is carried only so a resumed opencode
    finds the same wiring it was started with. **Never** any variable whose name contains
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
    `RunAtLoad` means the bootstrap **runs the job at once**: `--at-login`
    then meets the live fleet, skips every session as existing, writes a
    `login.log` line saying so, and writes the `login/<os-boot>` marker. The
    marker is right there: it means "this OS boot's fleet is accounted
    for", and without it a server the person later kills on purpose in the
    same boot would be rebuilt by `ensure_session` (§4.6).
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
    `restoring/` first, under §3.5's owner rule (so a `roost` typed
    meanwhile waits for a live owner however long it takes, §4.6), then
    waits up to 60 s for the socket directory to be writable, then does §4.3 for
    NAME with the reading rule of §3.6 **up to placement** (the pending
    record is written pane by pane during placement, each file before its
    placeholder starts, §4.6), then writes the `login/<os-boot>` marker and
    what it did to `login.log`. It always exits 0 (a skipped session is a line in the log,
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

Three lines, in the existing `ok`/`warn` style, warning only. The first
always names both halves, saving and the login restore, so "off" is never
read as "nothing is written" (the wording a reviewer proposed, taken as
is):

- `persist: saving on; login restore on for 'roost' (launchd, unit names
  this checkout; roots match; last save 2026-10-24 20:51 gen 4182
  after-split-window, 13 sessions / 47 panes; last login restore:
  2026-10-20 …; 0 pending)`, or `persist: saving on; login restore off
  (roost persist on to restore the fleet at login)`, or, with
  `ROOST_SHAPE_DIR=`, `persist: saving off (ROOST_SHAPE_DIR is empty);
  login restore off`.
- `warn`: the unit names another checkout; or `service.env` names a root the
  caller does not have; or its `PATH` lacks a harness the newest shape names;
  or `persist` is on and the newest save is older than the server's boot
  (hooks are not saving); or a pending record from this boot still has
  unlaunched or failed panes; or a `lock/`, `restoring/` or `resuming/`
  has had one live owner for over 60 s (its pid named; §3.5 never takes a
  live owner's lock by age).
- `warn`: N panes on this server run a harness with no recorded conversation
  (the §2.6 count), and M carry an identity that disagrees with their command
  (§3.2's stale case), with the harness names — the panes a reboot would
  lose or must not resume.

### 4.6 The pending record: placement at login, resume at first attach

§9 Q1 (A) splits a restore in two across time, and the keys have to live
somewhere durable in between — not in pane options, which a shell pane does
not have, and not in the shape, which §3.3 reads from live options. So:

- **Placement writes `pending/<boot>/`** (`--at-login` and a hand restore
  alike), one file per pane that will be resumed (a key, not stale,
  directory present), named by the new `%N` and written **before** that
  pane's placeholder starts, holding its resume block (`was`, `harness`,
  `session_id`, `transcript`, `cwd`, `session_cwd`, `session`, `window`)
  and **`order N`** (its place in the shape's pane order, which the loop
  walks). Revision 2's `pid` and `cursor` lines are gone (item 1): the
  file's own name is now the proof (§4.7), and a file rewritten after the
  placeholder started could race its rename.
- **Overlay.** `save --auto` (§3.5 step 2) writes a pane that has no
  `@roost-session` but has a pending file — **`%N`, `%N.launching`,
  `%N.failed` or `%N.taken`, all four alike** — with that file's keys, plus
  `resume pending` (or `resume failed REASON` for a `.failed` one, which a
  person may still fix by hand and retry, or `resume taken` for a pane a
  person took with a key: one key is not a decision to lose the
  conversation, so the next boot offers it again). A structural save in the gap, a pane
  left in a dialog, and a second reboot before anyone attached, therefore
  keep every key (§8.1 test 11). The next `--at-login` writes its pending
  files from that shape's `resume` panes before it removes the old boot's
  `pending/` directory.
- **The trigger** is a tmux hook, `client-attached[98]`, running `roost
  restore --resume --auto` with `run-shell -b`: it fires for `roost`, `roost
  session NAME`, `roost ssh` and a bare `tmux -L roost attach` alike, and a
  **detach fires nothing** — detaching never restores or resumes anything.
  `--auto` is silent when there is nothing pending. A bare `tmux attach`
  can fire it while `--at-login` is still placing (only `ensure_session`
  waits, §4.4); so `restore --resume --auto` first waits for
  `restoring/`'s live owner, as `ensure_session` does, and then runs
  (revision 3, F N6). Nothing could launch early anyway — the pending files
  appear one by one with their placeholders — but a worker that starts
  mid-placement would pace through half a fleet and stop.
- **The worker's own lock** (revision 2, item 3). The loop holds
  `resuming/`, not the saver's `lock/`, so saves go on while it paces
  through a fleet (38 agents at 2 s is over a minute), under §3.5's owner
  rule — pid and start time, **never age**. A second client attaching while
  a live worker holds it starts nothing; a worker that died leaves a dead
  pid, and the next attach takes over and continues from the unclaimed
  files.
- **`restore --resume`** walks `pending/<this boot>/` by `order`, taking
  only plain `%N` files; the placeholders are already there, so straight to
  agents, `--pace` apart (§5.5 applies here too). For each pane, in this
  order (revision 3 reorders it so that nothing is renamed until every
  read-only check has passed):
  1. **Check, touching nothing**: §4.1 steps 3 to 5 — the harness on
     `PATH`, the directory by §5.1, the key in the store, no live pane
     carrying it. A failure renames `%N` to `%N.failed` with the reason
     appended and, having won that rename, respawns the placeholder into a
     plain shell that prints the reason (§4.7); if the rename fails, a key
     took the pane first, and the loop moves on.
  2. **Claim the conversation**: §4.1 step 5a's `mkdir
     claims/<boot>/<harness>-<session_id>` — the **one** claim every
     launcher takes, so a `revive` and a worker, or two workers, never
     launch one key twice. A live claim for another pane: `%N.failed
     duplicate of %M`.
  3. **Claim the pane**: `mv %N %N.launching`. This is the rename the
     placeholder races on a key (§4.7); if the worker loses, the pane is
     the person's: release this run's conversation claim and move on,
     nothing touched.
  4. **Check it is still the placeholder roost started**:
     `#{pane_start_command}` is the placeholder line written for this file
     (a person who respawned the pane with another command fails it; a
     bare `respawn-pane` restarts the same placeholder, which is still
     waiting and passes). If not: `%N.failed pane changed`, the claim
     released, the pane not touched.
  5. §4.1 steps 6 to 8: `respawn-pane -k` with the resume command, under
     `remain-on-exit failed`.

  A key that arrives after step 3 finds the file gone; the placeholder
  prints `resuming <harness> now` and waits to be replaced (§2.10).
  **Release** (revision 3, F N1, F N8, C N1), each time only what that
  launch took: the `.launching` file and the claim are removed when
  identity lands on that pane with the **same** `session_id` (the
  `identify` hook's save call does it; from then on the live
  `@roost-session` is the owner §5.1a checks), so a pane left in a trust
  dialog keeps its binding and its claim until a person answers; when
  identity lands with a **different** id (a person answered "No, exit" and
  started a fresh agent), the file becomes `%N.failed replaced` and the
  claim is released; when the resume **dies** — `remain-on-exit failed`
  leaves a dead pane, and `pane-died[98]` (§3.4, measured to fire with
  `#{hook_pane}` by a reviewer on tmux 3.6) passes `%N` — the file becomes
  `%N.failed died` and the claim is released, so `--retry` can reach it.
- **Cancel.** `pane-exited`, a kill by any route (`after-kill-pane`, or a
  pane in a `window-unlinked` or `session-closed` difference, §3.6a) and
  `roost close` on a pane with a pending file remove it and release any claim it holds: a person
  who closed the pane did not want the agent. A `.taken` file is not a
  cancel: the pane is a shell the person is using, and §4.6's overlay keeps
  its key.
- **Interrupted halfway** (the person detached and the server died, or the
  loop was killed): unclaimed files are still there for the next attach. A
  `.launching` file whose pane still runs its placeholder (step 4's test)
  and whose launcher is gone (the `resuming/` owner, or the claimer in its
  claim, is dead) was claimed but never launched: the next worker renames
  it back to `%N` and releases that claim. `.launching`, `.failed` and
  `.taken` files are listed by `restore --list`, `status` and `doctor`;
  `roost restore --resume --retry` retries `.failed` ones, and `roost
  revive %N` resumes any of them.
- **`ensure_session` and the login restore.** With `persist` on, a `roost`
  typed before the service has finished: when `restoring/` has a live owner
  (§3.5's rule), `ensure_session` waits for it to go, printing `waiting for
  the login restore (pid N)` every 10 s, then attaches (the attach fires the
  hook). It never attaches early on a timer: a live owner is still
  building, and `--at-login` may spend 60 s on the socket wait alone. A
  person who wants out presses Ctrl-C; the restore carries on without them. When the server is not running, a `shape` exists,
  `persist` is on and there is **no** `login/<os-boot>` marker for this OS
  boot (`sysctl kern.boottime` on macOS, `/proc/sys/kernel/random/boot_id`
  on Linux), `ensure_session` runs `--at-login` itself under the same lock
  before attaching — so a service that did not run, or has not run yet, is
  not a lost fleet. A server a person killed on purpose and restarted in the
  same OS boot has the marker and is left alone.
- `pending/<boot>/` and `claims/<boot>/` for a boot that is gone are removed
  by the next `--at-login`, after its own pending files are written; `rm
  -rf` of the shape directory forgets them with the rest.

### 4.7 The placeholder: a pane roost can prove untouched

Three paths replace a pane with `respawn-pane -k` without a person naming
it: the resume loop (§4.6, at first attach and in a hand restore), and the
replaceable session (§4.3). Revision 1 guarded only `working` and
`blocked` badges, which a plain shell never has. Revision 2 placed **shells**
and tried to prove from outside that nobody had used one: the same pid, a
shell, no child, and the cursor where it was. Both reviewers broke that
proof (revision 3, item 1): the cursor moves with nobody there, when the
prompt draws and when an attach resizes the window, so every pane failed;
and typed text followed by Ctrl-A puts the cursor back, so a half-typed
command passed and was destroyed. A live shell cannot be proven unused from
outside, because what a person typed is inside the shell.

So a pane that waits for its resume does **not** run a shell. It runs
`scripts/roost-placeholder`, a short POSIX `sh` program, through
`roost-pane-shell`, with the pending file's path and the harness name:

1. It prints `waiting to resume <harness> - press any key for a shell` and
   reads **one byte** from the terminal in raw mode. Nothing else ends the
   wait: no rc file runs (it is not a shell), a resize is not input, and an
   attach is not input (§2.10 measured both).
2. On that byte it reads and throws away whatever else was already typed,
   restores the terminal, then runs `mv PENDING PENDING.taken`.
   - **The rename wins**: the pane is the person's. It prints `this pane is
     yours; <harness> was not resumed (roost revive %N to resume it)` and
     `exec`s `roost-pane-shell` with no argument, the user's wired login
     shell, in the same directory. The bytes after the first are thrown
     away on purpose: half a word reaching a fresh shell would run as a
     different command.
   - **The rename loses** and `PENDING.launching` exists: a launcher won
     first. It prints `resuming <harness> now` and waits to be replaced; a
     later key, once `.launching` is gone (the launch failed or was
     undone), gives the shell as above.
   - **The rename loses** for any other reason (the file is `.failed` or
     gone): it gives the shell as above.
3. The bootstrap form (§4.3) is the same program watching
   `restoring/bootstrap` with its own message.

**The proof** is the rename: the launcher's `mv PENDING PENDING.launching`
(§4.6 step 3, §4.1 step 5a) and the placeholder's `mv PENDING
PENDING.taken` race on one file, rename(2) is atomic, and exactly one wins.
A launcher that wins then checks `#{pane_start_command}` is still the
placeholder line it wrote (a person who respawned the pane with another
command fails that), and replaces the pane. A launcher that loses touches
nothing. A launcher that marks a file `.failed` before claiming (§4.6 step
1) has won the same race, so it may respawn that placeholder into a plain
shell with the reason printed: no key had arrived.

What is **not** used, and why: `#{pane_current_command}` reads `bash` for
the placeholder on macOS (its `/bin/sh` is bash, §2.10), so it cannot tell a
placeholder from a shell; the cursor, measured to move by itself; `pane_pid`,
which a bare `respawn-pane` changes while the pane is still an unused
placeholder.

**`revive` of an `exited` pane** is the one path that replaces a live
**shell**, and it is a person naming that pane: it keeps revision 2's
checks (a shell, no child process, else exit 1 unless `--force`), and the
person who asked owns any half-typed line in it.

The cost, said in Q1 and on the site page: until its turn, each agent pane
shows the waiting line instead of a prompt, and a person who wants a shell
there presses a key, which keeps that agent out of the automatic resume
(`roost revive %N` brings it back). A `roost send` to a pane whose file is
still `%N` or `.launching` refuses the way it refuses a blocked target
(unless `--force`), so a coordinator's prompt is not thrown away as the
"key" that cancels the resume.

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

- **Claude**: the transcript names its own directory. Revision 1 derived
  the project folder's name from a path, and §2.1 shows that rule is wrong
  for every worktree (the `.` of `.claude` is written `-` too). So roost
  **never derives a folder name to decide anything**. It reads the first
  `"cwd":"…"` value inside the transcript (`grep -m1 -o … | head -n 1`,
  since `grep -m1 -o` prints every match on the first matching line; no
  JSON parser; a value holding a JSON escape, `\`, is refused rather than
  decoded), and **that directory is the resume directory** when it exists
  (revision 3, F N4). The transcript is the conversation's own file, found
  by its exact id, so its `cwd` is the project by definition; revision 2
  also required it to equal `session_cwd` or `cwd`, which refused §2.6's
  live case for a gone pane (identity `cwd` a removed worktree, transcript
  under the root) — the case the record's `transcript` was added for. The
  directory gone, no transcript (none recorded and none found by the
  exact-id lookup of §4.1 step 1), or a transcript with no `cwd` line:
  **do not resume**; print the §5.6 line (the Q4 A rule). Whether a
  transcript that a resume elsewhere re-filed (§2.1) still carries the old
  `cwd` on its first line is *not measured* — probe in build step 2; if it
  does not, the rule resumes where the conversation was last filed, which
  is still its own project.
- **pi**: `pi --session PATH` with the recorded (or exactly looked up)
  session file. §2.4 measured that this resumes with no dialog from any
  directory and returns to the session's own `cwd`, so pi needs no folder
  rule; the launch directory is `session_cwd` when it exists, else `cwd`.
  No session file: **do not resume**, print the §5.6 line.
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
the report. The same step refuses an id that **another** live pane on this
server already carries in `@roost-session`, or that a live claim in
`claims/<boot>/` holds for another pane (§4.6) — which covers a launch still
sitting in a dialog with no identity yet, by this worker or one that died.
Revision 3 (item 4): a refusal needs a claim to find, so **every launcher
takes the claim before it launches** — `revive` in place, `revive
--new-window` and of a gone pane, a hand restore and the first-attach
worker alike (§4.1 step 5a) — and releases only a claim it took itself.
The pane being revived in place is not "another" (§4.1 step 5):
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
figure and its limit: pacing spreads the cold starts, which is the
**hypothesis** for what was heavy (a resumed fleet is not measured yet, step
3); the resident set it does not change, and a person who wants fewer agents
back uses `--only` or `--recent`.

### 5.6 A pane with a harness and no usable key

The 13 Claude panes of §2.6, every codex pane under #145, and every pane
whose key is stale (§3.2). Restore places the shell in its directory and
prints `roost restore: %34 ran claude with no recorded conversation; roost
revive %34 cannot resume it`, or `%90 carries a stale codex key
(01a16c68…) from a nested agent; not resumed`. Then, by harness, the **store
listing** of §2.8's "source if roost has no key" column — for Claude every
transcript whose own first `cwd` is the pane's directory, byte for byte,
newest first, as `claude --resume <id>` lines (the folder name, written
with the measured `/` and `.` → `-` rule, only narrows which files are
opened; a folder the rule misses only shortens a printed list); for codex
the rollouts whose `session_meta.cwd` is the pane's directory, newest first
— because several panes share one directory and the newest is a guess. A
pane with `stale_reason exited` gets the same line with its own stale id
first, so a person who wants it back types one command. §9 Q4 (A): **printed, never run.** A
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
exists and is not replaceable; replace a pane a person took with a key, or
a pane whose rename it lost (§4.7); respawn a live shell without a person
naming it (§4.7); launch a conversation without first taking its claim
(§5.1a); derive a
harness's folder name to decide a resume (§5.1); take a lock from a live
owner (§3.5); start a service without `persist on`; stop a service, ever.

### 5.9 What survives what

| event | live process, PTY, scrollback | placement | conversation |
|---|---|---|---|
| a client detaches or the terminal closes | kept by tmux | kept | kept |
| the tmux server dies (kill, crash, reboot) | **lost** | restored from the shape | restored by the harness from its own store, where roost has a key and the store still holds it |
| a pane is killed or closed on purpose | lost | gone, and stays gone: `closed/` removes it from whichever save a restore picks (§3.6a), the last pane of the last session included when closed with `roost close` | the harness keeps it; `revive` of the gone `%N` reaches it on the same boot (the record), the store listing of §5.6 after |

In-flight tool calls, shell jobs, `ssh` connections and process memory are in
the first column only. A turn that was `working` at the save is lost with the
process; the report names such panes so a person can re-prompt (§4.3).

---

## 6. Build order

Each step ships alone and is worth something alone. Sizes are airig's. The
probes a step must run before its code are listed with it.

| step | what | size | worth by itself |
|---|---|---|---|
| 1 | `roost save`, the shape format and its refusals (whitespace-exact parser, required keys, `id` lines, stale keys with `stale_reason`, `session_cwd`, `launch`, `zoomed`, linked windows, unknown-block skip), `roost restore` **placement only** (`-x W -y H`, largest-side splits across that side, `select-layout`, per-pane respawn with `default-command` passed explicitly, saved indices, `scripts/roost-placeholder` and the replaceable bootstrap session by its `restoring/bootstrap` rename (§4.3, §4.7), `--dry-run`, `--list`, `--only`, exit 12/16). Probes first: what `#{pane_current_command}` reads under pi, copilot and opencode (§3.2) | M | #51 as written: the guess of lesson 2 is gone; a fleet's shape can be moved between machines by file |
| 2 | `roost revive TGT` with the resume table and the **store check** in the adapters' library (`scripts/lib/roost-resume.sh`, beside `roost-close.sh`), the `claims/<boot>/` claim taken before every launch and released only by its taker (§4.1 step 5a), the directory rule of §5.1 (the transcript's own `cwd`), the duplicate-id refusal with the in-place exemption, `exited` versus `nested`, option clearing and `remain-on-exit failed`, `respawn-pane -k` with its command, the gone-pane path from the record (which gains `transcript`) and the exact-id lookup, exit 13/14/15; the opencode existence check or an honest printed command. Probes first: whether `claude --resume` keeps model and permission mode (Appendix A, the launch-flags row); whether a transcript re-filed by a resume elsewhere keeps its first `cwd` (§5.1) | M | #57: kill a pane, get the conversation back, same `%N` |
| 3 | restore resumes: §4.3's resume loop, pacing, `--recent`, `--no-resume`, `@roost-was`, the alias map and `was:%N` in every target-taking verb, `status --json` `was`, the codex note, the mid-turn line; the §2.9 RSS measurement of a resumed stub fleet against placement-only | M | lessons 3, 4 and 5 answered; a manual `roost restore` after a reboot does the whole job |
| 4 | save on change: the hooks in `tmux/roost.conf`, the direct calls in `spawn`/`split`/`view`/identify/`close`, the one switch of §3.4a, the one-saver protocol (`lock` with the owner rule, `want/` per trigger, `gen`, `restoring`), `trigger` lists, the `@roost-ids` refresh in every structural hook, the `closed/<boot>/` files (close, kill difference, death note) and the reading rule's step 4 by id, `pane-died[98]`, the 100-entry ring, the shutdown-record rule in epoch seconds, the three §3.4 cost measurements, the §4.5 doctor warnings about saving. Probes first: the Linux shutdown record (`last -x shutdown`, `journalctl --list-boots`); whether tmux runs `session-closed` hooks during a shutdown on a VM (a `SIGTERM` to the server ran none on macOS, §2.7); the kill-difference probe of §2.7 re-run on tmux 3.2 and 3.4 (Ubuntu CI) | S→M | nobody has to remember `roost save`; a crash loses one change at most; a shutdown does not restore what was closed on purpose |
| 5 | `roost persist on/off/status`, per-server plist and unit, `service.env`, `--at-login`, the pending record (with `order`), the overlay of all four pending file kinds, `claims/` taken by the worker and a hand restore (step 2 ships the directory with `revive`), the `resuming/` lock, the placeholder handshake of §4.7, `restore --resume`, `send`'s refusal on a waiting pane, the `client-attached` hook, `ensure_session`'s wait and self-restore, `login/<os-boot>`, `login.log`, `roost upgrade` rewriting the unit, the §4.5 doctor line, and the §8.2 human-eye reboot on macOS then Linux. Probe first, on a Linux VM: the unit's behaviour at `--at-login` exit, at `disable`, at logout with and without linger; and the §2.10 placeholder probe under `dash` in the Ubuntu container | M→L | #192: the fleet is back after a reboot without being asked, and the agents when someone is there |
| 6 | the printed store listings of §5.6 (Q4 = A) for Claude and codex. Probe first: what Claude's folder rule does with `_`, a space and a non-ASCII byte, and pi's folder rule for a path with a `.` (only the narrowing uses them; §5.6) | S | the 13 panes of §2.6 are not lost silently |

The order did not change in revision 1; steps 4 and 5 grew (the saver
protocol, the pending record) and step 2 gained the store check, which is
why their sizes moved. Revision 2 did not change the order or the sizes;
it added the probes named in steps 2, 4, 5 and 6, and moved work inside
steps (the `closed/` record into 4, claims and the §4.7 proof into 5, the
explicit respawn command into 1). Revision 3 keeps the order: the
placeholder program lands in step 1 (placement uses it), its handshake with
the worker in 5; step 2's `revive` takes a claim, and since `claims/`
arrives in step 5, step 2 ships the claim directory itself and step 5 reuses
it; step 4's kill rule is the hook difference, and its last-session probe
is answered (§2.7). #145 (codex identity under the app-server) is **not**
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
  events hooks, same `run-shell -b … || :` shape, `pane-exited` passing
  `#{hook_pane}` as the events hook already does; `client-attached[98]`
  for §4.6.
- `bin/roost spawn|split|view`: `@roost-launch` set, then one `roost save
  --auto` call after the name is stamped. `roost identify` and the two
  identity hooks: the same call behind `ROOST_IDENTITY_WROTE=1`, which also
  clears a matching `pending/.../%N.launching` and its claim; the record
  writer in `scripts/lib/roost-identity.sh` also writes `transcript` when
  one was reported (§1). `roost close`: the `closed/<boot>/close.<N>` file
  before the exit command and its removal when the close fails (§3.6a), a
  save with `--trigger close` after the pane is gone, and the pending
  cancel. `ensure_session`: §4.6's wait and self-restore when `persist` is
  on, and no bootstrap marker (revision 3, §1).
- `roost send` (and `answer`): a pane whose pending file is `%N` or
  `%N.launching` is refused the way a blocked target is, unless `--force`
  (§4.7).
- `scripts/roost-placeholder`: new (§4.7), run through `roost-pane-shell`.
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
  different pane, the dialogs a resume can open per harness (§2.8), that a
  linked window comes back as two windows (§3.2), and that a shape copied
  to another machine resumes nothing without the harness stores.

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
production shape of a login restore, **except** where a test attaches a real
client: from a pane of a second throwaway server, `env -u TMUX tmux -S
<inner socket> attach`, which gives the client a real pty the way
`tests/test-notify-osc.sh` already attaches real clients. A test that needs
a hook to fire on attach never calls the hook's command itself.

A test's seam is named where it is used: `ROOST_SHUTDOWN_AT=EPOCH` (a stub
shutdown record), `ROOST_PERSIST_WRITE_ONLY=1` (write the unit, do not load
it), and `ROOST_TEST_SAVE_HOLD=FILE` (a saver that holds `lock/` until FILE
exists, so a race is planted on cue instead of hoped for; this suite has a
macOS timing-flake history). Revision 3 adds four of the same kind:
`ROOST_TEST_SAVE_HOLD_AFTER_DRAIN=FILE` and `ROOST_TEST_SAVE_HOLD_AFTER_LIST=FILE`
(the saver waits after moving `want/` aside, or after listing), and
`ROOST_TEST_RESTORE_HOLD=FILE` (restore waits right after `new-session`,
holding `restoring/`), `ROOST_TEST_RESUME_HOLD=FILE` (the resume loop waits
after renaming a file to `.launching`, before its respawn); and one clock, `ROOST_TEST_NOW=EPOCH`, read by `save`
and `close` for every stamp they write.

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
   **Wide layout** (revision 2, item 4): a window of **six side-by-side
   panes** in a session saved at `-x 200 -y 10` restores with six panes and
   its layout string equal (ids and checksum stripped). A build that splits
   the largest pane in tmux's default direction stops at four there (both
   reviewers measured it), so this case is red against it; the stacked case
   alone is not.
   **Wired** (revision 2, item 10): every restored pane, **the first
   included**, has `roost-pane-shell` in `#{pane_start_command}` and
   `ROOST_TMUX` in its shell's environment (the stub `sh` prints it to a
   file at start). A bare `respawn-pane` leaves the first pane unwired (a
   reviewer measured it), so this is red against it.
2. **Existing and replaceable sessions.** Restore into a server where one
   saved session exists with a named pane: it is skipped and named, exit 12,
   the other sessions placed, nothing added to the live one. `restore` on a
   **stopped** server: its own bootstrap session is **placed into**, not
   skipped, exit 0, the first pane's `cwd` is the saved first pane's, and
   `restoring/bootstrap.used` is what is left. Revision 2 (item 5) added
   three cases that must be **skipped, exit 12, the pane's `pane_pid`
   unchanged**: (a) a one-shell unnamed session made with plain
   `new-session` whose shell has `sleep 60` running in the background; (b)
   the same with nothing running (an ordinary session is never replaced,
   busy or not); (c) a `roost`-started session with `sleep 60` typed into
   its shell. Revision 3 (item 1) adds, each skipped the same way: (d) a
   `roost`-started session whose shell has **pending input** — `send-keys
   -l 'echo keep-me'` then `C-a`, no Enter — and the screen still shows
   `echo keep-me` after the restore; (e) a `roost`-started session whose
   shell was **used and is idle again** — `cd /tmp` and Enter, `true` and
   Enter, no child left; (f) restore's **own** bootstrap with the restore
   held by `ROOST_TEST_RESTORE_HOLD` right after `new-session`, a real client
   attached and one key sent: the bootstrap file is `bootstrap.taken`, the
   pane is a shell with an empty line, the saved session of that name is
   skipped, exit 12. And one that must **still be placed into**: (g) the
   same held bootstrap with a real client attached at a **different size**
   (80x20 against a 200x50 save) and no key: exit 0. Revision 2's rule —
   the marker, one pane, the same pid, a shell, no child — replaces (d) and
   (e), because `ensure_session` set the marker and checks 1–3 pass, so
   both are red against it; (f) is red against any rule that cannot see a
   key; (g) is red against ending eligibility at an attach.
3. **Directories.** A pane whose `cwd` was removed: a shell at `$HOME`, the
   stderr line, not resumed, exit 13 when it had a key.
4. **Resume.** The stub `claude` is run with `--resume <id>` in the saved
   directory, 2 s apart (two agents, timestamps in the stub's file ≥ 2 s
   apart); `--no-resume` runs it zero times; `--recent 0` with an old
   transcript mtime runs it zero times; `--only SESSION` restores one
   session. **Directory rule** (rewritten in revision 2, item 6): the stub
   store's transcripts carry a `"cwd":"…"` line the way Claude's do, and
   sit in folders named by Claude's **measured** rule (`/` and `.` → `-`),
   not a rule the test invents. Every case uses a `cwd` **with a dot**,
   `…/repo/.claude/worktrees/w1`, the shape of every roost worktree. A pane
   whose identity `cwd` differs from its shell `cwd`, transcript `cwd` equal
   to the shell's: the stub runs in the shell's directory; equal to the
   identity's: in that one; equal to **neither** but an existing directory
   (revision 3, F N4: a gone pane whose identity `cwd` was a removed
   worktree, its transcript under the root): in the transcript's `cwd` —
   revision 2 refused it; the transcript's `cwd` a removed directory: not
   run, the §5.6 line printed. Revision 1's "`/` as `-`" rule matches no
   folder for these paths and resumes nothing, so the first two cases are
   red against it. A transcript whose `cwd` holds a `\` escape is refused,
   not decoded; a first line holding **two** `"cwd":"…"` values resumes in
   the first (`grep -m1 -o` alone prints both).
   **Exited and nested** (item 9, and C N4: the **saver** must classify, not
   a hand-made fixture): a live stub pane whose stub exited back to `sh`
   with its identity still set is saved by `save` itself with
   `stale_reason exited`; a pane running stub `claude` with `@roost-harness
   codex` stamped is saved with `stale_reason nested`; restore launches
   neither and names both. **Siblings:** two panes in one
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
   address, and a block missing a required key (a `window` with no `layout`,
   a `pane` with no `cwd`, a header with no `boot`) each refuse with exit 16
   naming the line and create **nothing** (a listing before and after). A
   window linked into two sessions is saved under each, with one `id`, and
   restores as two windows. **Whitespace:** a `name` with two leading and
   three trailing spaces round-trips byte for byte through `save` and
   `restore`.
6. **`revive`.** On a live stub pane: `respawn-pane` keeps the id (same `%N`
   before and after), `@agent_state` and the identity options are cleared
   before the respawn, the stub ran with `--resume <id>` in the chosen
   directory; on a `working` pane: refused, exit 1, the agent untouched; on a
   gone `%N` with a record: a new window, `@roost-was`; no key: exit 13;
   harness off `PATH`: exit 14; `cwd` gone: exit 15; **store miss: exit 13
   and the pane's process is the same pid as before** (nothing killed); an id
   **another** live pane carries: exit 13 naming it; the `claude-exit1` stub
   as the harness: the pane is dead, not gone (`pane_dead` 1,
   `remain-on-exit`), the window still has its pane count.
   Revision 2 cases, each red against revision 1:
   **Its own key** (item 7): the first case above — a live idle stub pane
   revived in place — must exit 0 with the same `%N`; revision 1's
   duplicate check refused it with 13. `revive --new-window` of the same
   live pane: exit 13 naming the pane itself, no new window.
   **Exited** (item 9): a live stub pane whose stub exited (shell back,
   identity still set) revives with the same `%N` and the stub's argv has
   `--resume <id>`; revision 1 gave 13. The same pane with `sleep 60`
   running in its shell: exit 1, the `sleep`'s pid still alive. A **nested**
   pane (stub `claude` running, `@roost-harness codex`): exit 13. An
   **`other`** pane (`sleep 60` in the foreground, identity still set):
   saved with `stale_reason other`, `revive` exit 13 (F N5).
   **Gone, no transcript in the record** (item 8): a gone `%N` whose record
   holds only `harness`, `session_id` and `cwd` (the shape written today,
   `scripts/lib/roost-identity.sh:171-175`), the stub store holding exactly
   one `<id>.jsonl` under a dotted-path folder: a new window, the stub run
   with `--resume <id>` in the transcript's `cwd`; revision 1 refused it at
   §5.1. Two files with that id in the store: exit 13, nothing launched. A
   record that has `transcript`: used directly, the store not searched.
   Revision 3 cases (item 4), each red against revision 2, whose `revive`
   looked for a claim and never took one:
   **Two revives of one gone record**: the stub never runs `roost
   identify` (a pane left in a dialog); `roost revive %OLD` → exit 0, a
   new window, `claims/<boot>/claude-<id>` naming it; `roost revive %OLD`
   again, sequentially → exit 13 naming the first new pane, no second
   window, the stub log holding **one** launch. Kill the first new pane:
   the claim is released (a `pane-exited` cancel), and a third `revive`
   launches. **Revive against a waiting pane**: a placed
   placeholder `%P` with key K and its pending file `%P`; `roost revive
   %P` → `%P.launching`, exit 0, and an attach after it launches nothing
   for `%P`. **Revive overlapping the worker**: placed panes `%P` and
   `%Q` with one key K, the stub never identifying; `revive %Q` first,
   then a real attach: the worker's claim for `%P` fails, `%P.failed
   duplicate of %Q`, one launch in the stub log. **Release only one's
   own** (C N1): with a live claim for `%Q`, a refused `revive` of a
   second pane carrying K leaves `claims/<boot>/claude-<K>` naming `%Q`,
   byte for byte.
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
   end with a `shape` holding all ten panes and **at most** ten history
   files, every history name unique, `gen` monotonic (revision 2, F N8:
   "fewer than ten" depended on timing). **Coalescing, on cue:** with
   `ROOST_TEST_SAVE_HOLD` holding the saver, make ten **real** changes
   (revision 3, C N2: ten `rename-window`s to ten names, each firing its
   hook), release: exactly one more history file, its body holding the
   tenth name, and its `trigger` lists every distinct trigger fired; then,
   held again, ten `roost save --auto --trigger save` with **no** change,
   release: no new history file (the body compare, §3.2), and `gen`
   unchanged. A `restoring/` marker with a live pid makes `save --auto` write
   nothing and leave its want; a `lock/` with a dead pid is taken over; a
   `lock/` whose pid is alive but whose recorded start time differs (a
   reused pid) is taken over. **Owner held past 10 s** (item 3): a saver
   held by the seam for 15 s, then a second `save --auto`: the second takes
   **no** lock and writes nothing, its want is there, and the held saver,
   once released, publishes it; revision 1's 10 s age rule put two savers on
   the file here. `history/` holds at most `ROOST_SHAPE_KEEP`; `trigger` is
   the hook's name, `close` after `roost close`, `save` after the verb.
   **The reading rule**, with the stub shutdown record: (a) a chain of
   `pane-exited` saves inside the window → the save before the chain is
   picked and named by `--list`; (b) **the planted race** (item 1): panes A
   and B run the stub; `roost close A` with the seam holding `close`'s own
   save until the `pane-exited` save for A has published; the newest
   `shape` is then a `pane-exited` save without A and `close`'s save writes
   nothing (same body) — assert both, so the race really happened; then,
   inside the window, restore: A does **not** come back, because
   `closed/<boot>/close.<A>` names it. Revision 1 walked back past the
   `pane-exited` save and restored A; so does a build that drops the
   `closed/` file. **Same second** (revision 3, item 2): the same race on a
   fixed clock (`ROOST_TEST_NOW=EPOCH` stamps both the save and the close
   with one second) — A still does not come back; revision 2's "later
   than" comparison restored it. (b2) **Overlap, rewritten** (item 3): B
   in window @1 beside a surviving pane; stub C alone in **its own window
   in its own session**. With the saver held, `kill-pane` B and let C
   exit; release: `closed/<boot>/` names B and **only** B — no window, no
   session, no C; restore inside the window brings back C, its window and
   its session, and not B. Revision 2 appended C's window and session as
   killed and lost C through them, so this is red against it; the old
   shared-window fixture passed with that bug. **Death in the gap**: hold
   the saver with `ROOST_TEST_SAVE_HOLD_AFTER_DRAIN=FILE` (a seam between
   moving `want/` aside and listing), let C exit, then `kill-pane` B,
   release: still only B. (c) no record → the newest save and the stderr
   line, `closed/` still applied; (d) a chain of 60 death saves → still
   recoverable (the ring holds 100); (e) **the last session** (item 12):
   with `persist` on, `roost close` the only pane of the only session; the
   server ends; with no shutdown record, `restore --at-login` places
   **nothing**, prints the "closed on purpose" line and exits 0; revision
   1 restored the session. The same with the fixed clock putting the last
   save and the close in **one second**: still nothing placed (revision 2
   placed the session). The same fleet torn down by deaths only (stub
   exits, no `close`, inside the window) is restored whole: automatic
   teardown writes no kill file. (f) **Epoch arithmetic** (F N7): a stub
   `last` on `PATH` printing a `shutdown time … Dec 31 23:59` line, and a
   stub boot second on 1 January, picks the window in the year before.
   (g) **A save in flight** (revision 3, item 2): hold the saver with
   `ROOST_TEST_SAVE_HOLD_AFTER_LIST=FILE` (a seam between listing and
   publishing) while A is still listed; `roost close A`; release, so the
   save that holds A is published **after** the close, with a higher `gen`
   than the close saw; let B die; restore inside the window picks the save
   holding A: A does not come back. Red against "later than", and against
   ordering by `gen`. (h) **A boot change** (item 5): a `shape` from boot
   B1 with panes `%0`–`%3`; kill the server; start boot B2 with
   `--at-login` held by `ROOST_TEST_RESTORE_HOLD`, `split-window` one pane
   as a person would and `kill-pane` it, release: `closed/<B2>/` names exactly that pane, and
   no file names any of B1's ids. Revision 2 compared B1's `shape` with
   B2's listing and recorded all four. (i) **Kills by every route**:
   `kill-window` of a two-pane window and `kill-session` of a session that
   is not the last each give a kill file naming exactly their panes, and
   the save that follows is labelled a death save (`window-unlinked`,
   `session-closed`); revision 2's `after-kill-window` and
   `after-kill-session` hooks do not exist (§2.7), so its build recorded
   neither. `break-pane`, `join-pane` and `move-window` give none. A
   `kill -TERM` of the server writes no kill file, and the next restore
   brings the whole fleet back. **The belt**: a kill file and a death note
   naming one pane (planted) → the pane is restored; a `close.` file and a
   death note naming one pane (what a real `roost close` leaves) → it is
   not.
9. **`persist`.** `persist on` with `ROOST_PERSIST_WRITE_ONLY=1` (a test seam:
   write the unit, do not load it) under `XDG_STATE_HOME=/custom`,
   `CODEX_HOME=/x` and `MY_API_KEY=1` writes a plist on macOS and a unit on
   Linux whose contents name this checkout and the server, and a
   `service.env` naming `/custom`, `/x` and **not** `MY_API_KEY`; the unit has
   `Type=oneshot`, `RemainAfterExit=yes`, `KillMode=process` and no
   `ExecStop`; `on` saved once (`trigger persist-on`); `on` for server B then
   `off` for A leaves B's unit and `service.env` untouched and A's `shape`,
   `history/` and `pending/` in place. A **second run, without the
   `ROOST_PERSIST_WRITE_ONLY` seam** and with a `systemctl`/`launchctl` stub
   first on `PATH` that records its argv and fails loudly on `stop`: `on`
   loads through the stub, and `off` called `disable` and **never** `stop`
   or `--now`; a server name with a space or `/` refuses, exit 1;
   `status` reads it all back.
10. **Degrade.** `ROOST_SHAPE_DIR` relative or empty saves nothing and every
    hook still exits 0 within 5 s; a read-only shape directory makes `save
    --auto` silent and `save` exit 1; a reader running `restore --dry-run` in
    a loop while 20 saves land never sees a refusal (no partial file).
11. **The pending record.** `restore --at-login` on a shape with three keyed
    panes places three **placeholders** (each `#{pane_start_command}` names
    `roost-placeholder` and its pending file) and one shell for the unkeyed
    pane, writes `pending/<boot>/` with three files and none for the unkeyed
    pane, launches nothing; a `spawn` then (a
    structural save in the gap) writes a `shape` whose three panes carry
    their keys and `resume pending`; kill the server, `--at-login` again from
    that shape (the second reboot): three pending files again, each with
    `order`.
    **A real attach** (revision 2, item 14): attach a real client from a
    pane of a second throwaway server (§8.1's opening), with the installed
    `client-attached[98]` hook and **no** direct call to `restore --resume`:
    the three stubs are launched 2 s apart, in `order`, and the stub log
    holds exactly three launches; each pending file is `.launching` and then
    gone once the stub's `roost identify` lands. The same case with the
    `client-attached[98]` line deleted from the test's conf launches
    **zero** — that is the check that the hook, not the test, starts the
    loop; revision 1 allowed calling the hook's command directly, which
    stays green with the hook deleted. A worker-only case may still call
    `restore --resume` directly, and is labelled as not covering the hook.
    **Two clients**: two real attaches in the same second launch each stub
    **once**. **Worker held past 10 s** (item 3): with `--pace 6` and three
    panes, a second attach at 12 s launches nothing extra, and `resuming/`
    still names the first worker. **Interrupted**: kill the loop after the
    first launch: one file gone, two still claimable, the next attach takes
    the dead worker's `resuming/` and launches exactly those two.
    **A pane taken** (revision 2 item 2, rewritten for revision 3 item 1),
    each case with `--pace 6` so a person acts before the pane's turn, and
    each red against the build it names:
    (a) `send-keys -l 'echo keep-me'` then `C-a`, no Enter, into one
    placeholder (the codex reviewer's case): its file is `%N.taken`, it is
    a shell whose line is empty, its `pane_pid` the same after the loop, the
    stub log has **two** launches — revision 2's four checks all passed
    here and the pane was replaced.
    (b) `sleep 60` and Enter into one placeholder: the first byte took it,
    so the same as (a), and the `sleep` never ran (it was thrown away with
    the rest of the line, as §4.7 says).
    (c) a person `respawn-pane -k -t %N 'sh'` before its turn: the file is
    `%N.failed pane changed`, the `sh` untouched — step 4's
    start-command test.
    (d) **must still launch** (the Fable reviewer's case): the redirected
    `HOME` holds a `.bashrc` and a `.zshrc` that print a banner and set a
    prompt, and the real client attaches at **80x20** against a shape saved
    at 200x50 — all three launch, and no file is `.taken` or `.failed`.
    Revision 2's check 4 failed every pane here (the cursor moved with the
    prompt and again with the resize), so this is red against it.
    (e) **the key loses**: a key sent to a placeholder right after its file
    became `.launching` (planted with `ROOST_TEST_RESUME_HOLD`, which
    holds the worker between its step 3 and step 5): the screen says `resuming
    claude now`, no shell starts, and the resume replaces it.
    (f) **`send` refuses a waiting pane**: `roost send %N "hi"` to a
    placeholder whose file is `%N` refuses as for a blocked target, and the
    file is still `%N`.
    **Released** (F N1, F N8): the `claude-exit1` stub as the harness: the
    pane is dead under `remain-on-exit`, `pane-died[98]` fires, the file is
    `%N.failed died`, the claim is gone, and `--retry` reaches it — revision
    2 left it `.launching` for ever. A stub that identifies with a
    **different** id: `%N.failed replaced`, the claim gone. **Interrupted
    after the claim**: kill the worker while `ROOST_TEST_RESUME_HOLD`
    holds it between steps 3 and 5: the next attach renames the `.launching` file back and launches
    it once.
    **Dialog keys survive** (item 11): a stub that never runs `roost
    identify` (a pane left in a dialog); after its launch, a `spawn` (a
    structural save): the shape carries its key with `resume pending`; then
    kill the server and `--at-login` again: its pending file is back. The
    same for a `.failed` pane, with `resume failed …`. A build that reads
    only `%N` files drops both keys.
    **Duplicate across workers** (item 13): two placed panes with one key, the
    stub never identifying; kill the worker right after the first launch;
    attach again: the second pane is **not** launched, its file is
    `%N.failed duplicate of %M`, and `claims/<boot>/` names the first pane;
    revision 1's per-run set launched it. Kill the first pane: its claim is
    released, and `--retry` then launches the second.
    `kill-pane` on a placed pane before attach removes its pending file and
    the attach launches two; a placed pane taken with a key and then
    `exit`ed (F N4) does the same through `pane-exited`; a `.failed` file (store miss) is listed by
    `--list` and retried only with `--retry`; `ensure_session` with `persist` on, no server, a `shape` and
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
Revision 2 adds: split the largest pane by area in the default direction
(1, wide layout); a bare `respawn-pane` (1, wired); drop the
`@roost-bootstrap` check from the replaceable rule (2a, 2b); drop the
placeholder proof (2c, 11 in use); derive Claude's folder from "`/` as `-`"
(4, dotted path); classify stale keys only in fixtures, not in `save` (4);
count the target as a duplicate (6, own key); treat `exited` as `nested` in
`revive` (6); refuse a gone pane with no recorded transcript (6); a single
`want` flag (8, coalescing); break a lock by age (8, owner held; 11, worker
held); drop the `closed/` line (8b, 8e); write `closed/` for a death (8e,
deaths only); read only `%N` pending files in the overlay (11, dialog
keys); a per-run duplicate set instead of `claims/` (11, duplicate across
workers); delete `client-attached[98]` (11, a real attach).
Revision 3 adds: place a shell instead of a placeholder (2d, 2e; 11a, 11b);
judge "untouched" by the cursor (11d, rc banner and resize); end bootstrap
eligibility at an attach (2g); skip the worker's rename and trust a
pre-check (11a, 11e); compare `closed/` with `saved` (8b same second, 8e
same second) or by `gen` (8g, a save in flight); record a missing window
or session as killed (8b2); compare `shape` with a new listing to find
kills (8b2 death in the gap, 8h boot change); hook `after-kill-window` or
`after-kill-session` (8i: they do not exist, nothing is recorded); let a
kill file outvote a death note, or a death note outvote a `close.` file
(8i, the belt); have `revive` look for a claim without taking one (6,
two revives); release a claim the run did not take (6, release only
one's own); no `pane-died[98]` (11, released); require the transcript's
`cwd` to equal `session_cwd` or `cwd` (4, neither).

Live, by hand, not in the suite, under `tests/live/`: `revive-smoke.sh` runs
`revive` against real Claude through the fake API rig and asserts the resumed
pane re-identifies the same id (the §2.1 shape) and that a deleted transcript
makes `revive` refuse with the pane untouched; the codex, copilot and pi
smoke files each gain one resume case, and the codex one kills its own
app-servers by environment, as the probe did.

### 8.2 Human-eye, listed together

1. **A real reboot on macOS** with `persist on`: log in, `roost`, the same
   sessions, windows and names are there, shells where there was no agent
   and the waiting line where there was; the agents then come up 2 s apart;
   pressing a key in one waiting pane before its turn gives a shell and
   that agent stays out; each Claude pane is at its prompt with its conversation;
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
Q1's A gained a mechanism, noted in its text. Revision 2 keeps all four;
each question says in its own text what revision 2 changed in practice.
Revision 3 keeps all four; Q1 and Q2 say what it changed.

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
- **What A means in practice after revision 2** (items 2, 3, 13, 14). The
  background loop no longer replaces every placed shell it reaches: a
  shell a person has started using before its turn — a command running in
  it, a respawn, or (if the step 5 probe allows) text typed — is left alone
  and listed as `failed pane in use`, and that agent comes back only when
  the person runs `roost revive %N` or `roost restore --resume --retry`.
  So "agents come back at first attach" now reads "every agent whose shell
  is still untouched when its turn comes". The loop holds its own lock
  (saves continue while it runs), a conversation is claimed once across
  any number of workers, and "first attach" is pinned by a test that
  attaches a real client.
- **What A means in practice after revision 3** (item 1, measured in
  §2.10). Revision 2's proof could not tell a used shell from an unused
  one, and would have marked every pane in use at the first attach. Now a
  pane that waits for its agent is not a shell at all: it shows `waiting to
  resume claude - press any key for a shell`. So after a reboot a person
  attaching sees the placement at once, every agent pane showing that line
  until its turn, and the agents replacing those lines 2 s apart — the
  same "at first attach, paced" that was decided. What changed is what
  "untouched" means: **any key** in a waiting pane gives that person a
  shell and leaves that agent out of the automatic resume (`roost revive
  %N` brings it back any time, and the next boot offers it again); an
  attach, a resize and the user's own rc files never count, because the
  placeholder runs none of them. Text typed into a waiting pane is not
  passed to the shell. The same placeholder is used by a hand `roost
  restore`, which now runs the same loop in the foreground.

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
- Revision 2: whichever save a restore picks, panes, windows and sessions
  removed on purpose are taken out of it first (§3.6a), so "every pane with
  a recorded conversation" means every such pane that was not closed or
  killed on purpose. Restore still never resumes a key marked `stale_reason
  exited`; `revive`, asked for one pane by a person, now does. The default
  itself is unchanged.
- Revision 3: "removed on purpose" is now decided by pane id, with no
  clock, and a kill is read from tmux's own before-and-after inside the
  hook, so a pane that died — alone in its window or its session — is
  never taken out of a restore as if it had been killed. A hand restore
  places waiting agents as placeholders and resumes them through the same
  loop as the first attach. The default itself is unchanged.

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
- Revision 2: the directory also holds `closed/`, `claims/`, `resuming/`
  and a `want/` directory (§3.1). The place is unchanged, and `rm -rf`
  still forgets all of it at once.

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
- Revision 2: the list holds only transcripts whose own first `cwd` is the
  pane's directory, byte for byte (§5.6); Claude's folder name only narrows
  which files are read, because the measured folder rule also rewrites `.`
  (§2.1). An `exited` pane's own stale id is listed first. Still printed,
  never run.

**Decided, not asked**, because #191 decided it: the login service is **off
until a person runs `roost persist on`**, and `roost doctor` says which it
is. Revision 1 reads that as the *service*; the shape is saved on change from
step 4 on regardless, because a hand `roost restore` after a crash needs it
and it is #51's own value (§3.4). Flagged for the human in the revision
report in case the reading is wrong. Both second-round reviewers found the
spec itself unambiguous here and placed the ambiguity in #191's own wording;
the question still waits on the human. Revision 2 keeps the reading, makes
`doctor` say both halves (`persist: saving on; login restore off`, §4.5),
and puts saving behind one switch, so the other answer is a change to one
function and the sections listed in §3.4a.

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
  Revision 3 measured one half (§2.7): a `SIGTERM` to the tmux server ran
  no hook, so a chain can only come from panes whose own processes died
  first.
  Severity: medium now — whichever way the hooks go, a deliberate close or
  kill is never undone (§3.6a: the `closed/` record, not a save's label)
  and a full fleet fits the ring; what remains open is whether the OS
  record is reliable enough to lean on.
- **A last session ended outside roost comes back** (§3.6a). Measured in
  revision 3 (§2.7): `tmux kill-session` of the last session and `tmux
  kill-server` run **no** hook, so no `closed/` file is written and the
  next boot restores that fleet; `exit` typed in the last pane is the same
  path (not run). `roost close` and `roost persist off` are the reliable
  ways to end a fleet for good; the site page says so. Medium, and now
  known rather than probed: no hook exists to close it.
- **A user hook that blocks tmux's global queue** (§3.6a). The kill
  difference is exact when a death's hook runs before a later kill's, which
  the measurement showed and the tmux source orders; a hook a user
  installed without `-b` could hold the death's hook back. The death note
  is the belt: such a pane is still restored. Low.
- **The identity agreement check is measured for two harnesses only** (§3.2):
  Claude and codex. The **shell** half of the rule needs no measurement and
  holds for all five: a pane whose command is a shell is `stale_reason
  exited` whatever its harness. What is unmeasured is the **nested** half
  for pi, copilot and opencode: until the step 1 probe says what their
  process reads, a pi pane whose identity a nested agent overwrote is not
  recognised and its key is trusted. The store check does not catch that
  case — a nested agent's key is real and its store holds it — so the
  probe is a shipping prerequisite of step 1, not a nicety. Low (it needs a
  nested agent inside one of those three).
- **A key pressed in a waiting pane drops that agent from the automatic
  resume** (§4.7). By design, and said on screen and in Q1; `revive %N`
  brings it back. A person who presses keys in every pane before its turn
  gets shells everywhere. Low.
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
  (§4.3), one saver per server with one want file per cause (§3.5), the body compare
  (§3.2). *Kept over all of them:* a line format a shell reads with no
  parser, a schema number, and whole-file validation before the first tmux
  command.
- **Overhead.** Timers everywhere else: every second, every minute, every
  fifteen minutes, or a 500 ms debounce with a 30 s safety save. The
  event-driven save with no timer and no daemon is *expected* to cost less
  than any of them at rest, since nothing runs between events; that is a
  reasoned claim, not a comparison anyone measured. The three listings cost
  4 to 5 ms each on 47 panes. Two tools
  start restored processes lazily (the visible tab first) or in bounded
  waves; *not taken now* (Appendix A, the per-session row). The desktop app paces agent
  launches at 750 ms; roost keeps 2 s (§5.5). The memory figure (§2.9) says
  pacing cannot reduce the resident set; that cold starts were the heavy
  part, so that pacing is the right lever, stays a hypothesis until step 3
  measures a resumed fleet.

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

---

## Appendix B. Triage of the second read's non-blocking notes

Revision 2. "F" is the Fable reviewer, "C" the codex reviewer; the numbers
are their own. Three of F's notes were ruled blocking by the coordinator and
are answered as items in §0.

| note | decision |
|---|---|
| F N1 — the split direction is unnamed | **blocking**, item 4 (§2.7, §4.3, test 1) |
| F N2 — the lock and `restoring/` are taken by age | **blocking**, item 3 (§3.5, §4.6, tests 8 and 11) |
| F N3 — `@roost-bootstrap` has no reader | **blocking**, item 5 (§4.3, §4.7, test 2) |
| F N4 — cancel a pending file on `pane-exited` too | **taken** (§4.6 Cancel, test 11) |
| F N5 — "saved order" has no key in the pending file | **taken**: `order N` in each file, the loop walks it (§4.6, test 11) |
| F N6 — macOS `RunAtLoad` runs the job at once; do not write the boot marker when nothing was placed | **taken** in part: the immediate run is said (§4.4). **Not taken**: skipping the marker, because the marker means "this boot's fleet is accounted for", and without it a server killed on purpose later in the same boot would be rebuilt by `ensure_session` |
| F N7 — the shutdown window mixes local time with no year and UTC | **taken**: epoch seconds, the year from the boot second (§3.6, test 8f) |
| F N8 — "fewer than ten history files" depends on timing | **taken**: "at most ten", plus coalescing proved with a held lock released on cue (test 8) |
| F N9 — `OPENCODE_CONFIG_DIR` versus the adapter table's `XDG_CONFIG_HOME` | **taken**: roost reads `XDG_CONFIG_HOME`; `OPENCODE_CONFIG_DIR` is carried for the resumed harness only (§4.4) |
| F N10 — test 9's seam and its stub run are two cases | **taken**: the stub run is the second run, without the seam (test 9) |
| F N11 — §2.7, §4.1 and §5.3 agree on option clearing | **no change**: the reviewer noted it as fine |
| C N1 — the incident's cause and "the cheapest design" are not measured | **taken**: both labelled as hypothesis or reasoned claim (§2.9, §11) |
| C N2 — the stale-rule wording for pi contradicts the risk paragraph | **taken**: the shell half holds for all five; the nested half for three harnesses is a step 1 shipping prerequisite, and the store check does not cover it (§3.2, §10) |
| C N3 — required fields and linked windows are claimed but not in the contract | **taken**: required keys per block, `id` lines, linked windows as two (§3.2, test 5) |
| C N4 — test the saver's own stale classification | **taken**: `save` itself must write `stale_reason exited` and `nested` from a live disagreement (test 4) |
| the open question: what "off until `roost persist on`" covers | **kept** as revision 1 read it (login service opt-in, saving on); the doctor wording taken from the merged review (§4.5); one switch, and the sections an opt-in answer would change (§3.4a) |

---

## Appendix C. Triage of the third read's non-blocking notes

Revision 3. "F" is the Fable reviewer, "C" the codex reviewer; the numbers
are their own. F's B1 and B2 and all four of C's blocking findings are the
five items of §0.

| note | decision |
|---|---|
| F N1 — a launch that dies stays `.launching`; install `pane-died[98]` | **taken**: the hook is in §3.4's table; the saver renames to `%N.failed died` and releases the claim (§3.5 step 2, §4.6 Release, test 11 "Released") |
| F N2 — a kill and a death in one round mark the death's window as killed | **taken**, as item 3: kills are a difference taken inside tmux and name panes only (§3.6a, test 8(b2)) |
| F N3 — `closed/` compares seconds | **taken**, as item 2, by id rather than by `gen` (§3.6 step 4, tests 8(b), 8(e), 8(g)) |
| F N4 — the Claude rule still requires the transcript's `cwd` to equal a pane directory; `grep -m1 -o` prints every match | **taken**: the transcript's own `cwd` is the resume directory when it exists; the first match only (§5.1, test 4) |
| F N5 — `stale_reason` has no value for a pane running neither a shell nor a harness | **taken**: `stale_reason other`, refused by `revive` (§3.2, §4.1 step 2, test 6) |
| F N6 — the worker can start during placement | **taken**: `restore --resume --auto` waits for `restoring/`'s live owner (§4.6 The trigger) |
| F N7 — `revive` on a pending pane does not claim | **taken**, as item 4 (§4.1 step 5a, test 6) |
| F N8 — identity landing with a different id leaves a stale claim | **taken**: `%N.failed replaced`, claim released (§4.6 Release, test 11) |
| F N9 — which saved blocks take the panes when a split is refused | **taken**: the first K in order; the rest listed with their §5.6 lines and no pending file (§4.3 Windows) |
| F N10 — a coalesced split-and-death round is a death save | **taken**: one sentence and its cost (§3.6) |
| F N11 — `@roost-bootstrap` stays on a restored session | **moot**: revision 3 drops the marker; the bootstrap mark is `restoring/bootstrap`, renamed once (§4.3) |
| C N1 — a duplicate failure must release only a claim the attempt acquired | **taken** (§4.1 step 5a Release, §4.6, test 6 "release only one's own") |
| C N2 — the coalescing test must make a real body change, and test the unchanged case | **taken** (test 8 coalescing) |
| C N3 — §5.5 and §11 state as fact what §2.9 calls a hypothesis | **taken**: both now say hypothesis, pending step 3's measurement (§5.5, §11) |
| the open question: what "off until `roost persist on`" covers | **unchanged**, still waiting on the human: saving on, login service opt-in (§3.4a, §9) |
