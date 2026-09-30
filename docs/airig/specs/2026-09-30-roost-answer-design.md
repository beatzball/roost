# `roost answer`: a human's verb to answer a dialog — design for #142

Status: **approved 2026-09-30. Nothing here is built.** The three questions
are decided by the human and listed, dated, in §11. §12 says what the
designer expects to break. Read §2 before anything else: two of the
measurements change what the issue asked for.

Base: `main` at `3fcccf1`. Measurements: Claude Code **2.1.283**, codex-cli
**0.157.1**, tmux **3.6**, macOS, 2026-09-30, one throwaway `-S` server
(§1). Anything not executed is labelled *not measured* or *inferred*. **"Once"
means one run**: it shows the shape can happen, not that it always does.

---

## 0. The short answer

- The command in the issue can be built, with one change to each of its
  items 2 and 4, because of what was measured.
- **A hash of the tool name, its input and the dialog kind is not a
  fingerprint.** Five times, a second dialog opened with the same tool and
  the same input as the one just answered, 0.2 s after it (M4). The
  fingerprint needs a part that is new for each dialog.
- **"The pane leaves `blocked`" is not a test that an approval landed.** After
  an approval, the pane reads `blocked`, with the same description, for as
  long as the approved tool runs: 25.09 s in the run here (M6). Nothing moves
  but the screen. So `answer` checks the screen too, before and after.
- **Deny is always Escape, never a digit.** "No" is option 3 in one dialog
  and option 2 in another, and in the first one option 2 is "Yes, and always
  allow" (M1).
- **The check for "the caller is a human" is a guard against an accident. It
  is not a lock.** One `env -u` defeats it (M8). The design says so in the
  docs and in the refusal.
- **Three things the human decided on 2026-09-30** (§11): only a pane an
  agent has reported from counts as an agent's pane; the screen may be
  evidence, narrowly; `--expect` is required to approve or to pick an
  option, and optional to deny.

---

## 1. The rig

One throwaway tmux server, `-S <tmp>/roost`, so roost's own hooks acted on
it. `HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_DATA_HOME`,
`XDG_CACHE_HOME`, `ROOST_RECORD_DIR` and `CODEX_HOME` all pointed into the
same temp directory. No account was used.

- **Claude Code:** a local stand-in for the Messages API
  (`ANTHROPIC_BASE_URL`), which scripts each reply: a `Bash` call, a `Write`
  call, an `AskUserQuestion` call. `--setting-sources local`, `--model haiku`
  on the command line, no slash command. Hooks: this checkout's
  `roost hooks claude`, plus one logger on 16 events that keeps each payload
  and its time.
- **codex:** a local stand-in for the Responses API (a `model_providers`
  entry), which scripts an `exec_command` call that asks for
  `require_escalated`. Started with `-a on-request -s read-only`. Hooks: this
  checkout's `roost hooks codex`, plus the same logger on all 12 events. The
  "Hooks need review" prompt was answered by keys, as
  `tests/live/codex-smoke.sh` does.
- **Timing:** one script records the time, sends the key with `send-keys`,
  then polls `@agent_state`, `@agent_since`, `@roost-blocked-on` and the
  visible screen every 10 ms. Each poll costs about 10 ms, so a time below is
  good to about 20 ms.

The user's own Claude settings file and codex config were hashed before and
after: unchanged. Raw logs were kept with the design work, not committed.

**Two things moved during the run, and both are recorded, not hidden.** The
machine's Claude Code updated itself from 2.1.283 to 2.1.285 while the rig
ran. The rig's Claude pane had started before that and stayed on 2.1.283; its
banner said so. The codex version read 0.157.1 before and after.

---

## 2. Measurements

### M1. Claude Code permission prompt (2.1.283)

Three shapes were on screen:

```
 Do you want to proceed?                    Bash, three options
 ❯ 1. Yes
   2. Yes, and always allow access to <dir> from this project
   3. No
 Esc to cancel · Tab to amend

 Do you want to proceed?                    Bash with `&`, TWO options
 ❯ 1. Yes
   2. No
 Esc to cancel · Tab to amend

 Do you want to create <file>?              Write, three options
 ❯ 1. Yes
   2. Yes, and switch to accept edits (...) for this session (shift+tab)
   3. No
 Esc to cancel · Tab to amend
```

| key | what it did | hooks after the key | badge |
|---|---|---|---|
| `1` | approved, **with no Enter** (3 runs, `Bash`) | `PostToolUse` +0.08 s when the tool is fast, then `PostToolBatch`, then `Stop` or the next dialog | left `blocked` at +0.10 to +0.17 s |
| `1` with the cursor on "3. No" | approved (once, `Write`). The digit wins over the cursor | `PostToolUse` +0.05 s | left `blocked` at +0.09 s |
| Enter, cursor on option 1 | approved (once) | as above | `working` at +0.10 s |
| `3` on a three-option dialog | declined (once) | **none** | stayed `blocked`. The next roost command cleared it from the transcript |
| Escape | declined (once with timing) | **none** | stayed `blocked`, as above |
| `y`, `n` | nothing. The dialog stayed (once each) | none | no change |

The dialog left the screen 12 to 76 ms after the key, in every run.

A decline wrote the three #38 records into the transcript, for `3` and for
Escape alike: 5 ms after the key for `3`, 55 ms for Escape. `roost
wait-done` then cleared the badge and exited 0.

**Not measured:** `2` (it grants a standing permission, so roost must never
send it), Tab, and the dialogs for `Edit`, `NotebookEdit`, `WebFetch` and an
MCP tool.

### M2. Claude Code question, one question, single select (2.1.283)

```
 ☐ Color
Which color do you want?
❯ 1. Red
  2. Green
  3. Blue
  4. Type something.
  5. Chat about this
Enter to select · ↑/↓ to navigate · Esc to cancel
```

The model gave three options. Claude added options 4 and 5 by itself.

| key | what it did | hooks after the key | badge |
|---|---|---|---|
| `2` | chose Green and submitted, **with no Enter** (once). `PostToolUse`'s `tool_response.answers` said `Green` | `PostToolUse` +0.03 s | `working` at +0.07 s |
| Down, Enter | chose Green and submitted (once) | the same | `working` at +0.07 s |
| Escape | declined the question (once). The same three transcript records as M1 | **none** | stayed `blocked`, then cleared from the transcript |

The question fires **`PermissionRequest`**, with `tool_name:
"AskUserQuestion"` and the whole `tool_input`: every question, every option
and `multiSelect`. So the dialog kind and the number of options are in the
hook payload. `@roost-blocked-on` read only `AskUserQuestion`.

Two other shapes, looked at once each, to see that a digit does **not**
submit them:

- **Two questions:** `1` answered the first question and moved to the second.
  The dialog stayed.
- **Multi-select:** `1` ticked a box. The dialog stayed, with a `Submit` row.

### M3. codex command approval (0.157.1)

```
  Would you like to run the following command?
  Reason: <the model's justification>
  $ mkdir cxdir-a1
› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `mkdir cxdir-a1` (p)
  3. No, and tell Codex what to do differently (esc)
  Press enter to confirm or esc to cancel
```

| key | what it did | hooks after the key | badge |
|---|---|---|---|
| `y` | approved, no Enter (3 runs) | `PostToolUse` +0.07 s, `Stop` +0.13 s | `working` at +0.12 s |
| `1` | approved, **no Enter** (once) | the same | the same |
| Enter, cursor on option 1 | approved (once) | the same | the same |
| Escape | declined (once) | `Interrupt` +0.035 s, no `Stop` | `idle` at +0.055 s |
| `3` | declined (once) | `Interrupt` +0.034 s, no `Stop` | `idle` at +0.053 s |

The dialog left the screen 13 to 15 ms after the key.

This differs from the "Hooks need review" prompt on 0.151.0, where a digit
only moved the cursor (`tests/live/codex-smoke.sh`). A digit's meaning is per
dialog and per version. It is never something to assume.

**Not measured:** `p` and `2` (a standing permission), and codex's
`request_user_input` tool, which is its question dialog.

### M4. What could make a fingerprint

| fact | Claude 2.1.283 | codex 0.157.1 |
|---|---|---|
| `PermissionRequest` carries the tool-use id | **no** | **no** |
| `PreToolUse` carries it (`tool_use_id`) | yes | yes |
| `PermissionRequest` carries | `tool_name`, `tool_input`, `prompt_id`, `transcript_path`, `permission_suggestions` | `tool_name` (`Bash`), `tool_input.command`, `turn_id`, `transcript_path` |
| the transcript holds the tool call, with its id, **before** the hook runs | yes: written 46 and 52 ms before (2 runs) | yes: `function_call` with `call_id` was there with the dialog open (once) |
| `@roost-blocked-on` | `Bash: mkdir …`, `Write: <path>`, `AskUserQuestion` | not recorded: the adapter stamps a flagless `blocked` |

**Two dialogs can be the same in every field but the id.** The stand-in
repeated a tool call, as a real model may. The second dialog had the same
`tool_name`, the same `tool_input` and the same `prompt_id`. Its
`PermissionRequest` came 0.15 to 0.18 s after the key that answered the
first (four runs with a fast tool), or 0.14 s after the slow tool ended
(once). Five times in all: `Bash` ×2, `Write` ×1, `AskUserQuestion` ×2. Only the transcript's tool-use id differed. (For
`Bash`, the text of option 2 on screen differed too.)

**`@agent_since` is not stable while one dialog is open.** The
`permission_prompt` Notification arrives 6.0 s after `PermissionRequest` and
moves the stamp. Seen three times.

**`tool_input` is not the same in every source.** For one `Write`, the hook
payload held an absolute `file_path` and the transcript held the relative
one the model sent.

### M5. How long until the badge changes

| answer | Claude | codex |
|---|---|---|
| approve, the tool is fast | `working` at +0.07 to +0.17 s | `working` at +0.11 to +0.12 s |
| approve, the tool is slow | **see M6** | **see M6** |
| decline | never by itself. The next `send`, `read` or `wait-done` clears it | `idle` at +0.053 to +0.055 s |
| the next dialog, when there is one | `blocked` again at +0.20 to +0.24 s | not measured |

### M6. After an approval, the pane reads `blocked` while the tool runs

Claude, a `sleep 25` approved with `1` (once):

| t (s) | what | badge |
|---|---|---|
| 0 | key `1` | `blocked`, `Bash: sleep 25 && …` |
| +0.012 | the dialog is gone from the screen | `blocked`, the same description |
| +0.012 to +25.05 | **no hook, no transcript record** | `blocked`, the same description |
| +25.054 | `PostToolUse` | `working` at +25.11 |

So for 25.09 s the pane said "a dialog is open", and none was. A `1` sent in
that time goes into the prompt box (M7).

codex, a `sleep 25` approved with `y` (once): the same until +10.2 s. Then
`Stop` fired, with no `PostToolUse` before it, because `exec_command` gave
control back to the model while the command ran. roost's `Stop` guard held
that `Stop` back. **The pane still read `blocked` 20 s later, with the turn
over**, until the next prompt.

Both are today's behaviour. A human who presses the key at the pane gets the
same badge. `roost answer` does not cause it, but it must not be fooled by
it.

### M7. A key sent when no dialog is open

`1` at an idle Claude prompt, and at an idle codex prompt: the digit is typed
into the prompt box and stays there (once each). It is not submitted. The
next `roost send` would paste after it.

Escape with no dialog was **not** sent in this run. From the turn-over
design, M5 and M6: Escape while Claude works interrupts the turn.

### M8. What the caller looks like

A probe script printed what a roost command can see. One run each.

| caller | `$TMUX` | `$TMUX_PANE` | stdin | controlling terminal | parent chain reaches |
|---|---|---|---|---|---|
| a human at a terminal with no tmux | unset | unset | tty | yes | not a roost pane |
| a human at a shell in **another** tmux server | the other socket | **`%0`** | tty | yes | the other server |
| a human at a shell pane **inside** roost | this socket | `%2` | tty | yes | the pane's process, 1 level up. The pane has **no** `@agent_state` |
| a Claude `Bash` call in a roost pane | this socket | `%1` | not a tty | **none** | the pane's process, 3 levels up. The pane read `working` |
| a codex `exec_command` call in a roost pane | this socket | `%4` | not a tty | **none** | the pane's process, 3 levels up |
| a Claude `Bash` call that detaches (`nohup … &`) | this socket | `%1` | not a tty | none | **pid 1**. The pane is not in the chain |
| a daemon started from a roost shell pane | this socket | `%2` | not a tty | none | **pid 1** |
| a program with no terminal and a clean environment | unset | unset | not a tty | none | pid 1 |

What follows from the table:

- `%0` exists on both servers. **`$TMUX_PANE` alone does not say which
  server.** The socket path in `$TMUX` must match too.
- An agent's tool call and a program with no terminal look the same on
  stdin. So "no terminal" cannot mean "agent".
- A human's shell pane inside roost and an agent's pane differ in one thing
  roost records: the agent's pane has a badge.
- The environment survives a detach. The parent chain does not. An agent
  that scrubs the environment **and** detaches shows nothing at all.

### M9. One tmux command can test and send (tmux 3.6)

```
tmux if-shell -F -t %2 '#{&&:#{==:#{@agent_state},},#{==:#{@fp},abc123}}' \
  "send-keys -t %2 -l MATCH ; set-option -p -t %2 @answered yes" \
  "set-option -p -t %2 @answered refused"
```

With the option equal, the text arrived in the pane and `@answered` read
`yes`. With it different, nothing was sent and it read `refused`. `if-shell`
exits 0 both times, so the caller reads the record back to learn which
branch ran. This is the shape of the `Stop` guard in
`scripts/roost-agent-state`, which already passes on CI's tmux 3.4.
**Not measured on 3.4 or 3.5a** with `send-keys` inside it.

### Found on the way, outside this issue

- **F1. On codex 0.157.1, a second codex pane badged the first pane**
  (once; filed as #145). Two codex panes shared one `CODEX_HOME`. The second one's six hook
  calls ran with `TMUX_PANE` of the **first** pane, and its tool call's
  parent chain led to the first pane's process. Both go through one shared
  `app-server` process that the first codex started. The first pane read
  `blocked` for a dialog that was on the second pane's screen.
- **F2.** The codex half of M6: a pane that reads `blocked` after its turn is
  over.
- **F3.** `@roost-blocked-on` for a question is only the tool name. The
  question text is in the same payload.

### Not measured

- Claude's dialogs for `Edit`, `NotebookEdit`, `WebFetch`, an MCP tool, and
  plan approval. A subagent's dialog. Two dialogs queued at once.
- A pane in tmux copy mode. `send-keys` then goes to copy mode, not to the
  agent (from the tmux manual, not run).
- tmux 3.4 and 3.5a. Linux. A container.
- opencode, copilot and pi dialogs.
- Any of M1 to M3 more often than the run counts given.

---

## 3. The command

```
roost answer [--json] [--force]  --expect FINGERPRINT  TGT --approve
roost answer [--json] [--force]  --expect FINGERPRINT  TGT --option N
roost answer [--json] [--force] [--expect FINGERPRINT] TGT --deny
```

- `--expect` is **required** for `--approve` and `--option`, and optional
  for `--deny` (decided, §11 Q3).

- Flags go **before** the target, as with `send`. Exactly one action goes
  **after** it.
- `TGT` is a `%N` pane, or a window. A window target means the one pane in
  that window that reads `blocked`. Two blocked panes in one window is a
  refusal that names both.
- `--text` from the issue is **not** in the first cut (§9).
- `--option N` is for a question. `--approve` is for a permission prompt.
  `--deny` works on both.

### 3.1 What it does, in order

1. Parse. `--approve` or `--option` with no `--expect`: exit 1, before
   anything is read. Resolve the target. No such target, or a dead pane:
   exit 2.
2. **Who is calling** (§7). An agent's pane, and no `--force`: exit 9.
3. Read the pane in one call: `@agent_state`, `@roost-dialog`,
   `@roost-answered`, `#{pane_in_mode}`.
4. Not `blocked`: exit 6. For a Claude pane, `roost_unblock_pane` runs first,
   as in `send`, so a declined dialog is "not blocked", not a target.
5. No dialog record, or `--expect` differs from the recorded fingerprint:
   exit 7.
6. The record says this dialog was already answered: exit 6.
7. Look up the keys for (harness, kind, action) in the key map (§5). No row:
   exit 8.
8. The dialog's marker text is not on the pane's visible screen, or the pane
   is in copy mode: exit 6.
9. **Send, in one tmux command** (M9). tmux tests again, in the same
   command, that the pane is `blocked`, the fingerprint is the same, the
   dialog is not yet answered and the pane is not in a mode. Then it sends
   the key and writes `@roost-answered`. If the test fails there, nothing is
   sent: exit 7.
10. **Confirm** (§6), inside the bound. Exit 0, or exit 10.
11. Write the record (§8). Print one line, or the JSON document.

Steps 3 to 8 send nothing. **One key group is sent, once, in step 9.** There
is no retry anywhere.

### 3.2 Exit codes

`send` owns 1 to 4 and `wait-done` owns 5. `answer` keeps 1 and 2 with their
`send` meanings and takes 6 to 10. It never exits 3, 4 or 5.

| exit | meaning | was a key sent | what to do |
|---|---|---|---|
| `0` | answered, and roost saw it land | yes | carry on |
| `1` (`usage:`) | a bad or missing argument | no | fix the call |
| `1` (`roost answer:`) | tmux failed before the send | no | retry is safe |
| `2` | no such target, or a dead pane | no | re-resolve the target |
| `6` | **nothing to answer**: not `blocked`, no dialog on screen, or already answered | no | read `status` again |
| `7` | **a different dialog**: `--expect` does not match, or the dialog changed before the send | no | show the human the new dialog |
| `8` | **no measured keys** for this harness, dialog kind or action | no | answer at the pane |
| `9` | **the caller is an agent** in a roost pane, and `--force` was not given | no | a human runs it, or passes `--force` |
| `10` | **sent, not confirmed** inside the bound | **yes** | **do not answer again.** `roost screen` the pane |

`10` is to `answer` what `4` is to `send`: the input went in, so a second try
is a second input.

### 3.3 Output

Plain, on stdout, one line: `%3 approve 3f9c1a2b7d4e`. That is the pane, the
action (`approve`, `deny`, or `option 2`) and the fingerprint answered.

A `--deny` without `--expect` prints one more line on **stderr** before the
send, so a person sees what they are denying:

```
roost answer: denying '%3': Bash: mkdir build
```

`--json`, one document, under the rules in `driving-a-fleet.md`:

```json
{"schema":1,"command":"answer","target":"api","pane":"%3","action":"approve","option":null,"fingerprint":"3f9c1a2b7d4e","harness":"claude","kind":"permission","confirmed":"state","state":"working","forced":false}
```

`confirmed` is `state`, `dialog`, `transcript` or `screen` (§6). A failure
prints nothing on stdout, exit 10 included, as `send --json` does for 4.

---

## 4. The fingerprint

### 4.1 What it is made of

**Twelve lowercase hex characters, new for each dialog, made by the hook
that stamps the dialog.** It is a token, not a hash of the content.

Why not the hash the #93 comment asked for: M4. Two dialogs were equal in
tool, input, kind and `prompt_id`. A caller shown the first would hold a
fingerprint that also fits the second.

Why not the harness's own tool-use id: `PermissionRequest` does not carry it
on either harness (M4). Reading it from the transcript is possible, but it
makes the fingerprint depend on a file format that is not a contract.

The rules:

- **Written only by the `PermissionRequest` path**, in the same tmux command
  as the stamp (`roost_stamp_blocked`). The `permission_prompt` Notification
  6 s later belongs to the same dialog and must not change it. It already
  leaves `@roost-blocked-on` alone for the same reason.
- **Kept, not replaced, when the same hook runs twice for one dialog.**
  Claude runs a hook once per settings source that names it. So the stamp
  also keeps a short digest of (tool name, tool input). If the pane already
  reads `blocked` and the stored digest is equal, the old token stays. In
  every flow measured, a real second dialog comes after the pane left
  `blocked` (M1, M2), and leaving `blocked` removes the record.
- **Removed wherever `@roost-blocked-on` is removed:** leaving `blocked`, the
  `Stop` guard's else branch, and `roost-unblock.sh`.
- The token comes from the JSON reader that already runs on this path, so
  there is no new process. With only `jq`, the shell makes it from `$RANDOM`.
  It must differ from the last dialog on this pane. It does not have to be
  secret.

### 4.2 Where it is stored

One pane option, one line, five words:

```
@roost-dialog = "<fingerprint> <harness> <kind> <options> <digest>"
                 3f9c1a2b7d4e  claude    question 3        9a0c51e2
```

- `harness`: `claude` or `codex`. The hook knows which it is. No other lane's
  work is needed for this.
- `kind`: `permission`, `question` or `other`.
  - `question` only when the payload is one question, `multiSelect` false,
    two to four options.
  - `permission` only for a tool whose dialog was measured: `Bash` and
    `Write` on Claude, the command approval on codex.
  - Everything else is `other`: a multi-select, two questions, a tool not yet
    measured, a payload no reader could parse.
- `options`: the number of options the **model** gave, for a question. `0`
  otherwise.

Every word is checked before it is written: hex, a fixed word, a digit.
Nothing from the payload reaches the option as text.

### 4.3 In `status --json`

One new field per pane, always present:

```json
"dialog": {"fingerprint":"3f9c1a2b7d4e","harness":"claude","kind":"question","options":3,"answered":null}
```

- `dialog` is `null` when the pane is not `blocked`, or has no record.
- `answered` is `null`, or `{"at":1790748772,"action":"approve","by":"terminal"}`
  once `roost answer` has answered this dialog (§8). It is how a reader tells
  "a dialog is open" from "blocked, and the approved tool is running" (M6).
- Additive, so `schema` stays 1.

The one-line summary stays #93's field. The options of a question stay in
the transcript, as the #93 comment says.

### 4.4 `--expect`

- A mismatch is **exit 7**. Nothing is sent. stderr names both values.
- `--expect` on a pane with no dialog record is also exit 7.
- The test runs twice: when `answer` reads the pane, and again inside the
  tmux command that sends the key (§3.1 step 9).
- **Required for `--approve` and `--option`** (decided, §11 Q3). An approval
  always names the dialog it approves. Without it: exit 1, nothing read,
  nothing sent.
- **Optional for `--deny`.** Then `answer` uses the fingerprint it just
  read, in the same two places, so the dialog cannot change between its own
  read and its own key. It can have changed since the **human** looked. A
  wrong deny costs a re-prompt. A wrong approve cannot be undone.

---

## 5. The key map

One function in a new `scripts/lib/roost-answer.sh`:
`roost_answer_keys HARNESS KIND ACTION [N]`. It sets the key and the marker,
or returns 1. It runs no tmux, so `tests/test-answer-keymap.sh` checks every
row, and every refusal, with no harness.

**Claude Code** (measured on 2.1.283)

| kind | action | key | source | why this key |
|---|---|---|---|---|
| `permission` | approve | `1` | M1 | confirms alone, and wins over a moved cursor. Enter follows the cursor, so it is not used |
| `permission` | deny | `Escape` | M1 | "No" is option 3 or option 2, and option 2 can be "always allow". A digit is never used to deny |
| `question` | option N | digit `N` | M2 | confirms alone. `N` must be 1 to `options`. Claude's own extra rows are refused |
| `question` | deny | `Escape` | M2 | declines the question |

Marker, both lines on the visible screen: `Esc to cancel`, and one of
`Do you want to` (permission) or `Enter to select` (question).

**codex** (measured on 0.157.1)

| kind | action | key | source | why this key |
|---|---|---|---|---|
| `permission` | approve | `y` | M3 | confirms alone, and is the letter the dialog prints. It does not depend on the order of the options |
| `permission` | deny | `Escape` | M3 | fires `Interrupt`, so the badge follows |

Marker: `Would you like to run the following command?` and `esc to cancel`.

Rules for the file:

- **A row is a measurement.** Each row names the version and the section
  here. A new row needs a new measurement first. No row, no key.
- **roost never sends `2`, `p`, Tab, or Enter** to a dialog.
- The map is **not** tied to a version number. roost does not know the
  version for certain. The guards are the marker (a changed dialog is
  refused) and a live test, `tests/live/answer-smoke.sh`, built from the rig
  in §1. Run it after every harness upgrade, as with the other live tests.

---

## 6. How "it landed" is confirmed

After the send, `answer` polls until the first proof, or the bound.

| action | proof | field | seen at |
|---|---|---|---|
| approve, option | `@agent_state` is `working` or `done` | `state` | +0.07 to +0.17 s |
| approve, option | `@roost-dialog` holds a new fingerprint | `dialog` | +0.20 to +0.24 s |
| approve, option | the marker is off the screen, **and** the pane still reads `blocked`, **and** (Claude) the transcript shows no decline | `screen` | +0.012 to +0.076 s |
| deny, Claude | `roost_unblock_pane` clears the pane from the transcript | `transcript` | records at +0.005 to +0.055 s |
| deny, codex | `@agent_state` is `idle` | `state` | +0.055 s |

**The proof must fit the action.** An approve that ends in a decline record,
or in codex `idle`, was not approved by this call: somebody at the pane got
there first. That is exit 10, and the message says what the pane shows.

The `screen` row is there because of M6. It is the only proof for an
approved slow tool. It is weaker than the others, and the JSON says which
proof was used.

**The bound:** `@roost-answer-timeout`, in seconds, default `3`, clamped to
1 to 30, read like `@roost-send-turn-timeout`. The slowest proof measured
was 0.24 s. No proof inside the bound: **exit 10**.

```
roost answer: the key was sent to '%3', and nothing confirmed it inside 3 s
roost answer: do NOT answer again. Look: roost screen %3
```

`answer` writes no state. Its only writes are `@roost-answered` and the log
(§8), and the unsets `roost_unblock_pane` already makes after a decline. In
the words of the turn-over design (§4.1), it is neither a report nor a
recovery. It is input, like `send`.

---

## 7. How "the caller is a human" is decided

### 7.1 What can be known

From M8. roost can see three things about its caller: the environment, the
parent chain, and whether there is a terminal.

| signal | what it proves | what defeats it |
|---|---|---|
| `$TMUX` names this server and `$TMUX_PANE` names a pane on it | the caller started in that pane, or inherited its environment | `env -u TMUX -u TMUX_PANE`. One line |
| the parent chain reaches a pane's process (#105's walk) | the caller is a live child of that pane | a detach: `nohup … &` reparents to pid 1 (measured) |
| no terminal on stdin | nothing. An agent's tool call and a web board look the same | — |
| the pane has a badge | an agent has reported from that pane | an agent with no adapter has no badge |

**No signal proves a human.** Each proves only "this call came from a place
where an agent runs". An agent that wants to get past the check can. The
check stops the accident: an agent that reads the skill, sees a blocked peer,
and tries the obvious command.

### 7.2 The rule

`answer` refuses, with exit 9, when **the caller is in an agent's pane**:

1. `$TMUX`'s socket path is this server's, **and** `$TMUX_PANE` is a pane on
   it (both, because of `%0` in M8), **and**
2. that pane is one **an agent has reported from**: its `@agent_state` is
   set, or, once #141 is built, it carries a session record (decided, §11
   Q1).

A person's shell pane inside roost has neither, so it passes with no flag.
**The cost, stated plainly: an agent in a harness with no adapter is not
caught.** Its pane has no badge, and roost cannot see it in any other way
either.

When #105's walk exists, a second test is added, and either one refuses: the
parent chain reaches the process of a pane on this server. That closes the
scrubbed environment. It does not close scrub plus detach, and nothing can.

The check runs before the pane is read, so a refused agent learns nothing
about the dialog from the refusal.

### 7.3 What `--force` means

`--force` means: **"a person decided this, and I am only the place it was
typed."** It skips the caller check and nothing else. Not `--expect`, not
the key map, not the marker, not the confirmation.

- It is recorded: `forced` in the log and in the JSON.
- The skill (`skills/roost/SKILL.md`) gets one line: an agent never runs
  `roost answer`, and never passes `--force` to it, unless its human told it
  to answer that dialog in this conversation.
- The docs say, in these words: *"roost cannot tell a person from a program.
  `answer` refuses a caller that sits in an agent's pane, so that an agent
  does not answer another agent's dialog by accident. A program that means
  to get past this check can. Do not treat it as a permission system."*

### 7.4 The rule that does not change

No hook, no adapter and no other roost command calls `answer`. A test reads
`scripts/`, `adapters/` and `bin/roost` and fails if any of them does, as
`tests/test-hook-source.sh` does for its own rule.

---

## 8. What is recorded about who answered

**On the pane**, written in the tmux command that sends the key:

```
@roost-answered = "<fingerprint> <epoch> <action> <by>"
                   3f9c1a2b7d4e  1790748772 approve terminal
```

`action` is `approve`, `deny` or `optionN`. `by` is `pane:%N` (the caller's
own pane, from the §7 check), `terminal` (a tty on stdin, not in a roost
pane) or `program` (no tty). It is removed with `@roost-dialog`.

This is what makes a second `answer` on the same dialog exit 6, and what
fills `dialog.answered` in `status --json`.

**On disk**, one line appended to a new file `answers` in the pane's record
directory (`scripts/lib/roost-record.sh`), after the confirmation:

```
<epoch> <fingerprint> <harness> <kind> <action> <by> forced=<0|1> confirmed=<state|dialog|transcript|screen|none> <@roost-blocked-on>
```

- Append only. With `ROOST_RECORD_DIR=""` nothing is written, as for
  replies. `roost forget` removes it with the rest of the record.
- It is **not** a per-turn sidecar. The turn that holds the dialog has no
  file yet: a turn file is written at `Stop`. #56 can use the same file for
  `send`.
- The summary is the last field because it is free text. It can hold a
  secret, as `scripts/roost-agent-state` already warns. The record directory
  is as private as the replies beside it.
- When `roost events` (#98) exists, an answer is one more line there.

`by` says where the command ran. It does not say who the person was. A
program that answers for many people would need a `--as NAME` label. Not in
the first cut.

---

## 9. What is refused in the first cut

Nothing is sent in any of these.

| case | exit | stderr |
|---|---|---|
| no action, two actions, `--option` with no number | 1 | `usage: roost answer [--json] [--force] [--expect FP] TGT --approve|--deny|--option N` |
| `--approve` or `--option` with no `--expect` | 1 | `roost answer: --approve and --option need --expect FINGERPRINT. Read it from roost status --json`, then the usage line |
| `--text` | 8 | `roost answer: --text is not supported yet. Answer at the pane` |
| no such target | 2 | `roost answer: no such target '<tgt>'` |
| dead pane | 2 | `roost answer: target '<tgt>' is a dead pane` |
| two blocked panes in a window target | 2 | `roost answer: '<tgt>' has more than one blocked pane (%3 %5). Name one` |
| caller in an agent's pane | 9 | `roost answer: this is a person's command, and it was called from an agent's pane (%7)`, then `roost answer: pass --force only if a person told you to answer this dialog` |
| pane not `blocked` | 6 | `roost answer: '<tgt>' is not blocked (it reads <state>). There is nothing to answer` |
| blocked, marker not on screen | 6 | `roost answer: '<tgt>' reads blocked, but no dialog is on its screen. Nothing was sent` |
| already answered | 6 | `roost answer: this dialog was already answered (<action>, <n> s ago). Nothing was sent` |
| pane in copy mode | 6 | `roost answer: '<tgt>' is in copy mode, so keys would not reach the agent. Nothing was sent` |
| `--expect` mismatch | 7 | `roost answer: '<tgt>' is now blocked on a different dialog (expected <a>, found <b>). Nothing was sent` |
| blocked, no dialog record | 7 with `--expect`, else 8 | `roost answer: '<tgt>' has no dialog record, so roost cannot tell which dialog this is` |
| kind `other` | 8 | `roost answer: no measured keys for this <harness> dialog. Answer at the pane` |
| harness with no map (opencode, copilot, pi) | 8 | the same line |
| `--approve` on a question | 8 | `roost answer: this is a question with <n> options. Use --option N, or --deny` |
| `--option N` on a permission prompt | 8 | `roost answer: this is a permission prompt. Use --approve or --deny` |
| `--option N`, N not in 1 to `options` | 8 | `roost answer: option <N> is not one of the <n> options the agent gave` |

Left for later, each measured first: multi-select, two or more questions,
options with previews, free text, plan approval, Claude's `Edit`,
`NotebookEdit`, `WebFetch` and MCP dialogs, codex `request_user_input`, a
subagent's dialog, and the three harnesses with no map.

---

## 10. Build order, and what each step is worth alone

Steps 1 and 2 touch `scripts/roost-agent-state` and the `status` part of
`scripts/lib/roost-jsonout.sh`. Both are in other Phase 0 lanes (#141, #98).
So this work starts after those merge.

0. **Docs only. Done on this branch.** M6, F2, F1 (as a pointer to #145)
   and the two-option dialog are in `docs/known-gaps.md`. *Worth:* they are
   live today, for a human at the pane too.
1. **The dialog record.** `@roost-dialog` from the Claude
   `PermissionRequest` path, and from the codex adapter, which starts to
   pass its payload. Removed with `@roost-blocked-on`. `status --json` gains
   `dialog`. Fixture tests from the payloads of this run. *Worth alone:* the
   #93 comment is done. A reader can tell a permission prompt from a
   question, and can tell when the dialog changed. Size: S–M.
2. **`roost answer --approve` and `--deny` for a Claude permission prompt.**
   The key map and its test, the guards, the one-command send, the
   confirmation, exit codes, the caller check from the environment,
   `@roost-answered`, the log, and `tests/live/answer-smoke.sh`. First,
   measure `Edit`, `WebFetch` and one MCP dialog, and add each that matches.
   *Worth:* the verb exists for the most common dialog. Size: M.
3. **`--option N`** for a Claude question. Step 1 also fixes F3 on the way.
   *Worth:* a question can be answered from elsewhere. Size: S.
4. **codex approve and deny.** Only after #145 (F1) is understood: today a
   second codex pane can stamp the wrong pane. The marker check would refuse that
   case, but refusing is not a fix. *Worth:* the second harness. Size: S,
   plus F1.
5. **`--json`**, the docs page (`site/content/docs/driving-a-fleet.md`: the
   command, the exit table, the words in §7.3), and the skill line. *Worth:*
   the first program that uses it can be written. Size: S.
6. **When #105's walk lands:** add the parent-chain test to §7.2. Size: S.

Step 1 does not need the rest. Steps 2 to 4 each ship alone. Step 5 can move
up beside step 2 if the first user is a program.

---

## 11. Decisions

**Every question is decided by the human.** Nothing below is a
recommendation. Each decision matched what the design proposed.

**Made by the human on 2026-09-30:**

- **Q1 — only a pane an agent has reported from.** For the caller check, a
  pane counts as an agent's pane only when an agent has reported from it. A
  person's shell pane inside roost passes without `--force`. The reason: a
  `--force` that has to be typed every time stops meaning anything. The
  cost, stated plainly: an agent in a harness with no adapter is not caught.
  The other option was "every pane on this server", the issue's words. §7.2
  is the rule.
- **Q2 — the screen may be evidence, narrowly.** The dialog's marker text
  must be on the **visible** screen, or `answer` refuses. The marker going
  away is one proof that an approval landed. The screen can refuse a send
  and can confirm one. It never permits a send by itself, and it never
  writes state. The measured reason: after an approval the pane reads
  `blocked` for the whole run of the tool (25.09 s, M6), so the badge cannot
  confirm anything. The other option was no screen at all. §3.1 step 8 and
  §6 are the rule.
- **Q3 — `--expect` is required for `--approve` and `--option`, and optional
  for `--deny`.** A second dialog can open a fraction of a second after the
  first closes, with the same summary (M4). A wrong deny costs a re-prompt.
  A wrong approve cannot be undone. The other option was optional
  everywhere, as the issue wrote it. §3 and §4.4 are the rule.

**Two things the measurements changed from the issue's text**, recorded with
the decisions on #142: the fingerprint is a token that is new for each
dialog (§4.1), and the exit codes start at 6, clear of `send` and
`wait-done` (§3.2).

**Still not measured, and not decisions:** the list at the end of §2. Step 2
starts with the Claude dialogs on it.

---

## 12. What I expect to go wrong (the designer's read, not a decision)

Most likely first.

1. **Readers will show "needs you" for a pane that was already answered.**
   M6 stays true after this work. A board must read `dialog.answered`, and
   the first one will not. Say it in the docs, next to `dialog`.
2. **The approve that lands on the next dialog.** A new dialog is on screen
   about 60 ms before its hook has written the new fingerprint (11 to 16 ms
   in the #91 measurements, plus the hook's own run). If someone answers the
   old dialog at the pane in that instant, `answer`'s key goes to the new
   one under the old fingerprint. The marker cannot tell the two apart. It
   needs two answers inside about 60 ms. Record it in known-gaps.
3. **A stray digit in the prompt box.** A person declines at the pane a few
   milliseconds before `answer` sends `1`. Claude fires no hook for a
   decline, so every guard still passes. The `1` is typed into the prompt
   (M7). §6 then reports exit 10, because the transcript shows a decline.
   The digit stays, and the next `send` pastes after it. roost must not
   send a key to clean up.
4. **The "same hook twice" rule in §4.1 is built from reasoning.** A
   subagent's dialog with the same tool and input, opened while the main
   dialog is still up, would keep the old fingerprint. Not measured. Measure
   it in step 1.
5. **The marker text is the harness's, not a contract.** The day it is
   reworded, every `answer` is exit 6 with "no dialog is on its screen".
   That is safe, and it will be reported as a bug in roost. The live test
   says which it is.
6. **A narrow pane wraps the dialog.** The marker lines here are short, but
   a marker split over two rows is a miss. Capture with joined lines, and
   test at 40 columns.
7. **codex.** F1 means the blocked pane may be the wrong pane. F2 means a
   codex pane can read `blocked` with the turn over. Step 4 waits for both
   (F1 is #145).
8. **`if-shell` with `send-keys` on tmux 3.4** is not measured (M9). Run the
   new tests in the Ubuntu image before the pull request.
9. **Exit 9 will surprise a person** who ran an agent in a pane, quit it,
   and now types in the same pane. By the Q1 decision the pane still counts,
   because it still has its badge.
   The refusal names the pane, and `--force` is the honest answer there.

---

## 13. What this design does not do

- It does not change any badge rule. `blocked` after an approval (M6) stays.
- It does not fix F1 (#145) or F2.
- It does not show the dialog to anyone. That is #93.
- It does not make `answer` safe against an agent that wants to call it.
