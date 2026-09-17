# A per-pane record that outlives the pane (#74) — design

Status: **approved 2026-09-16 (D1 = B, D2 = H), built for #42 on the #74
branch.** Where building changed a decided detail, the section says so under
"Changed while building". Everything under
"Measured" was executed that day on throwaway sockets; anything not executed is
labelled *inferred* or *not measured*. No product code was written. The
scratch prototype used for the measurements is described in M4 and is not part
of the build.

The record is the base for #42 (durable replies), #51 (save and restore a
fleet) and #57 (revive a conversation). The next build is **#42 only**. So this
design sizes the record for #42 and reserves, by name, what #51 and #57 would
add — as new files in the same directory, never a new format.

## Decisions

- **D1 [chosen: B]: how a record is stored on disk.**
  - **A. One JSON object per pane** (the issue's proposal), rewritten whole on
    every turn, with a `replies: [...]` array.
  - **B. One directory per pane, plain files** — one raw file per turn, one
    small file per field. **Recommended.**
  Facts: see "The record" and M4, M6. In short: B needs no JSON parser in any
  reader, writes one turn's bytes per turn instead of the whole history, and
  its turn files are atomic and seekable by name. `python3` and `jq` are not
  runtime dependencies (`scripts/roost-doctor`), and `scripts/lib/roost-jsonout.sh`
  is an encoder only; A would need a decoder in `read`, or would make `read`
  depend on `python3`/`jq`. A's advantage is one file to look at or copy.
- **D2 [chosen: H]: where the reply is captured.**
  - **H. In the hook, at the end of a turn** — the two places that write
    `@roost-reply` today also write the turn file. **Recommended.**
  - **L. Lazily, for Claude only** — the 2026-09-14 comment on #42: record only
    Claude's `transcript_path`, and read the full reply out of Claude's own
    transcript at `read` time.
  Facts: H costs +7 to +17 ms per turn end (+7 to +16 at 2 KB, +17 at
  60 KB), and nothing on the per-tool-call path (M5). L costs nothing at turn end but parses a harness-internal JSONL
  format at every `read` (so `python3` or `jq` becomes required for `read`),
  and it covers only Claude: codex, opencode, pi and copilot would still need
  H. L still needs a hook write, of the path. A Claude pane can also hold more
  than one transcript over its life (`/clear` starts a new session —
  *inferred, not measured*), so "turn N of this pane" is not one file.

Everything else below is decided in this document, with the reason.

## The issue's proposal, checked

| proposed | finding | this design |
|---|---|---|
| path `<socket-name>__<pane-id>.json` | **pane ids restart at `%0` on every server start** (M1). A restarted server's `%0` would overwrite the dead server's `%0` history — the history #51 and #57 exist to read | the server's boot key is part of the path |
| `boot_id` = `#{start_time}:#{pid}` | both formats exist on tmux 3.3a, 3.4 and 3.6 (M1, M7) | kept, as the **directory name** `<start_time>-<pid>` (no `:` in a path) |
| `shell_pid` = `#{pane_pid}` in the liveness test | not needed: liveness asks the tmux server, which never reuses a pane id within one boot (M3). A stored pid is only a hazard | dropped; can be added later as a file |
| `command` = `#{pane_current_command}` in the liveness test | **changes during one agent's life** (M2), and reports Claude's version string, which changes every release | dropped. The #64 objection applies here too, for a stronger reason: this is an equality test, so any change marks a live record as history |
| writes under `flock` | **no `flock` on macOS** (M4); present on Ubuntu and busybox | no lock: `mktemp` + `ln` for a turn, `mktemp` + `mv` for a field (M4) |
| `reply` may hold > 12 KB and many turns | measured sizes in M6 | one raw file per turn, no cap in the file |
| `state, since, reason` in the record | the pane is the truth while it lives; after it is gone they describe nothing a reader can act on | not in #42; `state` reserved for #51 |
| `cwd, repo, branch, name` | #51 placement | reserved; `repo`/`branch` are derived from `cwd` at restore, so only `cwd` is reserved |
| `session_id` | #57 | reserved |
| `updated` | a file's mtime already says it | dropped |

**The #73 record is a different fact.** `@roost-agent-job` (`PGID:PANE_PID`)
answers "is the agent process in this live pane still running?" for
`wait-done`. This record answers "does this pane still exist on the server that
wrote it?". The first is only meaningful while the pane lives, so it is not
copied into the record and not duplicated by it.

## Measured

Machine: macOS 25.3 arm64, tmux 3.6, bash 3.2 for the hook. Linux: the
`roost-ci-ubuntu` image (tmux **3.3a**, `sh` is dash, bash 5.2) and the
`roost-tmux34` probe image (tmux **3.4**, `sh` is busybox). Every run used a
throwaway `-S` socket under `mktemp -d /tmp/amx.XXXX`. No live Claude or codex
run was needed, so no harness config was touched.

### M0. Every place a pane option is written today

| site | option | triggered by | how often | file write safe here? |
|---|---|---|---|---|
| `scripts/roost-agent-state` — unchanged-state bail (`[ "$state" = "$prev" ]`) | none, except `@roost-transcript` + `@agent_since` on a repeated Notification | Claude **PostToolUse** (every tool call), every repeated state from every adapter | many per turn | **no.** This is the hot path; it must stay one tmux read and exit. The record never reaches it |
| `roost-agent-state` — Stop, `done --stop-hook`, reply non-empty | `@roost-reply` set | Claude Stop; codex Stop via `adapters/codex/roost-codex-hook` | once per turn | **yes** — already spawns `python3`/`jq` once per turn; **#42 writes here** |
| `roost-agent-state` — Stop, reply empty; `error --stop-hook`; `idle --stop-hook`; `--stop-failure-hook` | `@roost-reply` unset | Claude Stop/StopFailure; codex Stop/Interrupt | at most once per turn | not needed: the pane now has no current reply, and history files stay |
| `roost-agent-state` — busy transition | `@roost-agent-job` set/unset (#73) | UserPromptSubmit, PermissionRequest, Notification | ≤ 2 per turn | not needed for #42 |
| `roost-agent-state` — every transition | `@roost-error-reason`, `@roost-transcript`, `@agent_state`, `@agent_since` | every state change | several per turn | not needed for #42 (`state` reserved for #51) |
| `roost-agent-state` — no name yet | `@roost-name` | first transition of an unnamed pane | once per pane | reserved for #51 |
| `bin/roost` `reply` | `@roost-reply` set | `adapters/opencode/roost.js`, `adapters/pi/roost.ts`, `adapters/copilot/extension.mjs` (`run(["reply", text])`), or a human | once per turn | **yes — #42 writes here** |
| `bin/roost` `spawn`, `split` | `@roost-name` | a human or a coordinator | once per pane | reserved for #51 |
| `scripts/lib/roost-unblock.sh` | unsets `@agent_state`, `@roost-reply`, `@roost-transcript`; sets `@roost-unblocked` | `send`, `wait-done`, `read` on a declined dialog (#38) | rare | not needed: an unset leaves history alone |

`scripts/amux-agent-state` is a symlink to `roost-agent-state`, so it is not a
separate site.

### M1. The boot key, and pane ids after a restart

```
== fresh server, first pane
pane=%0 start_time=1789545413 pid=84460 pane_pid=84462 cmd=bash start_cmd=[/bin/sh -i] path=
== restart the server on the same socket
old boot=1789545413-84460  new boot=1789545423-87219  first pane on new server=%0
```

Ubuntu (tmux 3.3a): `pane=%0 start_time=1789546096 pid=12 pane_pid=13 cmd=sh`,
and after a restart `first pane on new server=%0`. `#{pane_path}` is empty on
both without an OSC 7 shell, so #51 must use `#{pane_current_path}` for `cwd`.

### M2. `pane_current_command` is not stable during one agent run

A stand-in agent typed at `/bin/sh -i`: a script that runs `sleep 1.2`, then a
`perl` sleep, then `exec sleep 1.2`. Sampled every 0.3 s:

```
sh bash bash bash bash bash bash bash sleep sleep sleep sleep bash bash
```

The same agent under `bash -c 'agent; true'` read `bash` for all 14 samples.
So the value names whichever process tmux picks from the terminal's foreground
group at that instant, not the agent. The repository already records the other
half: a Claude pane reports Claude's own version string
(`scripts/roost-agent-state`, the labelling comment), which changes on every
update.

### M3. Liveness, and why a reused pid cannot fool it

The check is one tmux call to the socket the record names:

```sh
got="$(tmux -S "$socket" display-message -p -t "%$N" '#{start_time}-#{pid} #{pane_id}' 2>/dev/null)" \
  && [ "$got" = "$boot %$N" ]
```

Output on macOS tmux 3.6 (identical results on tmux 3.3a and 3.4, M7):

```
case 1: record for a pane that exists (boot=1789545450-92257 pane=%0 pane_pid=92258)
  -> LIVE
case 2: pane closed, and its pane_pid now 'belongs' to an unrelated live process
  stored pane=%1 pane_pid=92296; an unrelated sleep has pid 92400; kill -0 92400 -> alive
  (a kernel check on a recycled pane_pid would say alive; the tmux check below never looks at the pid)
  -> history
case 3: server restarted on the same socket; pane %0 exists again
  new boot=1789545452-92641 first pane=%0
  -> history
case 4: socket gone entirely
  -> history
case 5: positive control after restart — a record made with the NEW boot key
  -> LIVE
case 6: respawn-pane -k keeps pane id, changes pane_pid
  pane_pid 92790 -> 92877
  -> LIVE
```

Case 2 **simulates** reuse: a real pid wrap cannot be forced on demand (the
#64 design measured a full wrap at about 7 minutes on this machine). The point
it proves is structural: the check never passes a pid to the kernel, so a
recycled pid has nothing to match against.

What could still fool it, and why it is not handled:

- **A new server with the same pid, started in the same second** as the dead
  one, on the socket the record names. That needs a pid wrap inside one
  second. Not reachable in practice; stated here so nobody assumes it is
  impossible.
- **`respawn-pane -k`** (case 6) keeps the record live: same pane, new process.
  That is right for #42 — reply history belongs to the pane. #57 needs to know
  the agent changed, and gets that from `session_id`, not from liveness.

### M4. Writes without `flock`

```
macOS:   command -v flock -> (nothing)   /usr/bin/flock, /opt/homebrew/bin/flock: No such file
ubuntu:  /usr/bin/flock   tmux 3.3a  /bin/sh -> dash
tmux34:  /usr/bin/flock   tmux 3.4   /bin/sh -> busybox
```

The portable answer is no lock at all:

- **A turn** is written to `mktemp "$dir/replies/.tmp.XXXXXX"`, then linked
  into place with `ln TMP NNNNNN`. `link(2)` fails if the name exists, so two
  writers can never take the same number; the loser tries the next number.
  The temp file is then removed. A reader lists only `[0-9]` names, so it can
  never see a half-written turn.
- **A field** (`schema`, `socket`) is written to a `mktemp` file and `mv`ed
  over the name. `rename(2)` is atomic.

The scratch prototype hung twice while building this measurement, and both
causes are rules for the builder:

1. **`.tmp.$$` is not unique.** Inside a `( … ) &` subshell `$$` is the
   parent's pid, so forty writers shared one temp name and deleted each other's
   file. bash 3.2 has no `BASHPID`. Use `mktemp`.
2. **Retry only on a collision.** `ln` also fails when the source is gone, the
   disk is full or the filesystem is read-only; a loop that retries on every
   failure never ends. Retry only when `[ -e "$target" ]`, otherwise give up
   and leave the pane option to do its job.

Result, 40 separate writer processes on one pane at once, 20 KB each, then 40
more at 50 KB while a reader looped over the files:

```
macOS:  phase1: writers=40 turns=40 distinct_writers_found=40 leftover_tmp=0
        phase2: file_reads=1936 partial_reads=0 turns_now=80 leftover_tmp=0
ubuntu: phase1: writers=40 turns=40 distinct_writers_found=40 leftover_tmp=0
        phase2: file_reads=1960 partial_reads=0 turns_now=80 leftover_tmp=0
```

### M5. What a write costs in the hook

A scratch copy of `scripts/` with the Stop branch changed to take the boot key
(one `display-message`), append the turn, and set `@roost-reply` and the
pointer option in **one** tmux command (`… \; set-option -p … @roost-reply-turn N`).
Each cycle is `roost-agent-state working` then `roost-agent-state done
--stop-hook` with a real JSON payload, against a socket named `roost` (the
guard in `scripts/lib/roost-socket.sh` refuses any other name).

The first run of this harness **reported success while writing nothing**: its
socket was named `s`, the guard exited 0 at once, and the cycle looked cheap.
A positive control (the stored pane reply, and a file count) exposed it. The
numbers below are from the corrected run, with the control printed:

```
base: 92.8 ms per working+Stop cycle (N=100, reply=2000 bytes)
  control: base stored a pane reply of     2001 bytes
rec: 100.2 ms per working+Stop cycle (N=100, reply=2000 bytes)
base: 85.3 ms per working+Stop cycle (N=100, reply=2000 bytes)
rec: 100.8 ms per working+Stop cycle (N=100, reply=2000 bytes)
turns recorded by rec: 100  pane pointer: 200
pane value == file bytes (positive control)
base: 94.4 ms per working+Stop cycle (N=60, reply=60000 bytes)
  control: base stored a pane reply of    12339 bytes
rec: 111.6 ms per working+Stop cycle (N=60, reply=60000 bytes)
base: 95.0 ms per working+Stop cycle (N=60, reply=60000 bytes)
rec: 112.1 ms per working+Stop cycle (N=60, reply=60000 bytes)
```

- **+7 to +16 ms per turn end at 2 KB (100.2 − 92.8, 100.8 − 85.3), +17 ms at 60 KB**, on a cycle of 85 to
  95 ms that already includes a `python3` start. About 4 ms of it is the boot
  key read.
- **+0 on PostToolUse.** The write is inside the Stop branch, which the
  unchanged-state bail never reaches.
- `KEEP=100` held: 200 turns written, 100 files left.
- The 60 KB run's `pane.txt` and `file.txt` differ at byte 12289, which is the
  intended change: the pane holds the 12288-byte head and the marker, the file
  holds the whole reply.

### M6. How big a reply is, and how many turns a pane has

Method: every `$HOME/.claude/projects/**/*.jsonl` modified in the last 30 days;
a turn's reply is the byte length of the last assistant text record before the
next user prompt, which approximates Stop's `last_assistant_message`. Only
lengths were read out; no text was copied.

```
transcripts=403 turns=2026
bytes: median=1471 p90=2519 p99=9947 max=24675 total=3274516
over 12288 (today's cap): 10 (0.49%)
over 131072 (Linux single-argv limit): 0
turns per transcript: median=1 p90=7 p99=90 max=256
```

Claude only, one user, one month. Codex, opencode, pi and copilot were not
measured.

### M7. The same probes on Linux

M1, M3 and M4 were re-run in `roost-ci-ubuntu` (tmux 3.3a, dash) and M3 in
`roost-tmux34` (tmux 3.4, busybox), with identical results (outputs above).
Two more facts from the Ubuntu image:

```
== argv limit
131071-byte arg: ok
bash: line 7: /bin/true: Argument list too long
131072-byte arg: refused
== dash can read a turn byte-identically
0000000   a   ;  \n   "   q   "     303 251  \n
```

The first matters for the node adapters, which pass the reply to `roost reply`
as one argument: see Risks.

### M8. Tricky replies: the pane value and the file print the same bytes

Through the scratch hook, `printf '%s\n' "$(show-options @roost-reply)"`
against `printf '%s\n' "$(cat TURNFILE)"` — which is how `read` prints:

```
case 1 "return 0;"                     pane=    10 file=    10 read-output: identical
case 2 "case x;;"                      pane=     9 file=     9 read-output: identical
case 3 "line1\nline2\n\n\n"            pane=    12 file=    12 read-output: identical
case 4 "quotes \" ' \\ and $HOME `x`"  pane=    27 file=    27 read-output: identical
case 5 emoji, U+00E9, a tab            pane=    31 file=    31 read-output: identical
case 6 "#{pane_id} #[fg=red] 100%"     pane=    26 file=    26 read-output: identical
case 7 "x"*12288                       pane= 12289 file= 12289 read-output: identical
case 8 "y\n"*9000                      pane= 12338 file= 18000 read-output: DIFFER
```

Case 8 is the truncated case and is meant to differ. The file needs no
trailing-semicolon escape: it never passes through tmux's command parser.

## The record

### Where it lives

```
${ROOST_RECORD_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/roost/panes}/<start_time>-<server_pid>/<pane_number>/
```

Example: `~/.local/state/roost/panes/1789545413-84460/581/` for pane `%581`.

- **`$XDG_STATE_HOME/roost`, not `~/.config/roost`.** roost already keeps
  machine-written state there — `ext.lock`, `ext.index` and `ext/<name>/`
  (`scripts/lib/roost-ext.sh`, `roost_ext__roots`) — and `~/.config/roost`
  holds what a person edits (`roost.conf`) and what `roost wiring` generates.
  A reply history is state.
- **Its own subdirectory, `panes/`,** so it can be removed in one command
  without touching extensions: `rm -rf ~/.local/state/roost/panes`, or
  `roost forget --all`.
- **`ROOST_RECORD_DIR` overrides the whole path**, so a test points it at a
  temp dir and never touches a real one. It must be absolute; a relative or
  empty value means "do not record" (the pane option still works). An
  `XDG_STATE_HOME` that is not absolute is ignored, as the XDG spec says and
  as `scripts/roost-wiring` already does for `XDG_CONFIG_HOME`.
- **The boot key is the directory**, so every record of one server is one
  directory, and one server's records can be removed together.
- **The pane number without `%`**, so a path is never a `printf` format.
- The root (when roost creates it), each boot directory and each pane
  directory are `0700`, files `0600` (`mktemp` already does this): a record
  holds what an agent said. **Changed in review round 1:** the first build left
  the root `0755`. A `ROOST_RECORD_DIR` the user made keeps its own mode, and the
  parents of the root (`…/state/roost`, shared with extension state) are not
  touched.

### Files for #42 (schema 1)

| file | content | written | why #42 needs it |
|---|---|---|---|
| `schema` | `1` and a newline | when the record is created, and backfilled if missing | the version rule below |
| `socket` | the absolute socket path, from `$TMUX` | same | cleanup must know whether a record from **another** server is live (M3 asks that socket) |
| `replies/NNNNNN` | the raw bytes of one turn's reply, as stored today (see Risks on trailing newlines) | once per turn | durable, whole, seekable, prunable |

`NNNNNN` is the turn number, from `000001`, zero-padded to six digits so a
listing reads in order. **A turn file's name is digits only.** Readers skip any
name with a non-digit in it — that is what keeps `.tmp.XXXXXX` files and the
reserved `NNNNNN.<field>` sidecars invisible — and find the highest turn
numerically, not by glob order, so turn 1000000 (seven digits) still sorts
last. The builder seeds a `999999` file to test that.

And **one new pane option**, `@roost-reply-turn`: the turn number whose file
holds the reply now in `@roost-reply`. It is set in the same tmux command as
`@roost-reply`, so a reader never sees one without the other.

### Reserved names

Taken now, so nothing else uses them with another meaning. Nothing writes them
in #42.

| name | for | content |
|---|---|---|
| `name` | #51, and reading a gone pane by name | `@roost-name` at the last write |
| `session`, `window` | #51 | session name; `index name` |
| `cwd` | #51, #57 | `#{pane_current_path}` (not `pane_path`, empty per M1) |
| `state` | #51 | `@agent_state` at the last write |
| `harness` | #57 | `claude`, `codex`, `opencode`, `pi`, `copilot` |
| `session_id` | #57 | the harness's own conversation id, latest |
| `replies/NNNNNN.<field>` | #57 and later | a per-turn sidecar, e.g. `000007.session_id`. A #42 reader matches digits only, so sidecars are invisible to it |

### Schema version rule

- `schema` holds one integer. #42 writes `1`.
- **Adding a file never changes the number.** A reader ignores files it does
  not know. A writer backfills the files of its own schema that are missing
  (an `[ -e ]` test each, no fork), so a record made by an older roost gains
  new fields on its next write.
- **The number moves only when an existing file changes meaning or format.**
- A **reader** that finds a number it does not know, or no readable number,
  does not use the record: `read` prints what it prints today. A **writer**
  that finds a larger number writes nothing, so running an older roost never
  damages a newer one's record. `roost forget` removes a record whatever its
  number; deleting does not need to understand it.

## The write path

Two sites, both already once per turn, both already writing `@roost-reply`:

1. `scripts/roost-agent-state`, Stop with `done --stop-hook` and a non-empty
   reply (Claude, codex).
2. `bin/roost` `reply` (opencode, pi, copilot, a human).

In order, at each site:

1. Take the boot key: `display-message -p '#{start_time}-#{pid}'` on the same
   socket the site already uses. Empty → skip to step 5.
2. Resolve the record directory. `ROOST_RECORD_DIR` not absolute → skip to 5.
3. Create it if missing (`mkdir -p`, `0700`), and backfill `schema` and
   `socket` if missing. `schema` larger than 1 → skip to 5.
4. Write the turn (M4): `mktemp` in `replies/`, `printf '%s'` the reply, glob
   the highest number, `ln` to the next, retry only on a collision, remove the
   temp file. Then prune (below).
5. Set `@roost-reply` exactly as today, and — only if step 4 produced a turn
   number — `@roost-reply-turn` in **the same tmux command**. If step 4 did not
   run, the pointer is left as it is, for the reason in "Unset sites" below.

Every step carries `|| true` or its equivalent. A failed record write leaves
today's behaviour, never a failed hook.

**Order.** File first, pane second, state third. The existing rule — the reply
before `@agent_state`, so `wait-done` then `read` cannot land in a gap — still
holds, and a reader that sees the pointer always finds its file.

**Unset sites are unchanged.** When a turn ends with no reply, `@roost-reply`
is unset and the pointer is left alone. A pointer left from an earlier turn is
harmless: `read` uses it only while `@roost-reply` is set, and serves the file
only when it matches `@roost-reply` (the match check below) — and a file that
matches prints the same bytes. So an unset of the pointer could not be caught
by any test mutation, which in this repository means it is dead code; it is not
added, at the unset sites or at step 5.

**The hot path is not touched.** No new code runs before the unchanged-state
bail.

## Liveness

A record is **live** when the server at its `socket` answers
`#{start_time}-#{pid} #{pane_id}` with the record's boot key and pane id (M3).
The check never passes a pid to the kernel, so a reused pid cannot make history
look live. `#{pane_current_command}` and `#{pane_pid}` are not part of it (M2,
M3 case 6).

**Changed in review round 1 — three answers, not two.** The first build treated
every failure to ask as "not live", and a reviewer reproduced `forget --gone`
deleting a live pane's record at exit 0 with tmux off `PATH`, and with the
socket's directory unsearchable. `roost_record_liveness` now answers:

| answer | when |
|---|---|
| `live` | tmux printed exactly this boot key and pane id |
| `gone` | tmux printed another boot key, or this boot with no such pane; or failed with `no server running on` (a socket file a killed server left) or `(No such file or directory)` (the socket or its directory is not there) |
| `unknown` | no socket recorded; tmux not found; `(Permission denied)`, `(Operation not permitted)`, any other error or output; no answer within 2 seconds |

Only `gone` is ever deleted. `forget --gone` names each record it could not
check and counts them; the sweep keeps them silently. The 2-second bound is
there because a stopped server (`kill -STOP`) accepts the connection and never
answers, and the probe then hung (reproduced); macOS has no `timeout(1)`, so
the probe runs in the background beside a watchdog.

**Changed in review round 2 — nothing is decided from the filesystem.** The
round-1 fix still called a record gone when `[ -d ]` on the socket's directory
was false, and `test(1)` gives the same false for "not there" and "not allowed
to look". A locked grandparent directory, or a sandbox hiding `/tmp/tmux-UID`,
still deleted live records (reproduced). Now tmux is always asked, with
`LC_MESSAGES=C` pinned so its strerror text is matchable. Measured as a normal
user on macOS tmux 3.6, Alpine tmux 3.4 and Ubuntu tmux 3.3a: a locked parent or
grandparent gives `Permission denied`; a missing socket or directory gives `No
such file or directory`; a killed server's socket gives `no server running on`.

**Also found while fixing round 2:** a tmux client passes its stdout to the
server, so a stopped server holds a command substitution's pipe open and the
caller waits forever even after the watchdog kills the client. The probe writes
to a file instead — unlinked as soon as it is opened and read back through a
second descriptor, so a caller killed mid-probe leaves nothing behind.

**Changed in review round 1 — what counts as a record.** Every delete path
first checks `roost_record_is_record`: a pane-number directory, under a
boot-key directory, holding a `schema` file. A directory of the right shape
without one — even one holding `replies/` — is left alone. The first build
deleted by shape alone, and the reviewer reproduced all three paths removing a
directory roost never wrote.

`read` rarely needs this call: when the target resolves to a live pane,
`read` already knows the server and the boot key. The explicit check is for
cleanup, and later for `status --all`.

## The read path

`roost read` keeps reading the pane first. The record only answers what the
pane cannot: the bytes past the 12 KB cap, an earlier turn, and a pane that is
gone.

### A live pane, no `--turn`

1. The #38 unblock step, unchanged.
2. `reply="$(show-options -pqv @roost-reply)"`, unchanged. **Empty → today's
   screen fallback, unchanged, whatever files exist.** The pane says there is
   no current reply, and the pane wins.
3. Read `@roost-reply-turn` (pane scope, `-p`, for the reason the existing
   comment gives) and the boot key. Either empty, the record directory
   missing, `schema` not `1`, or the turn file missing → print `$reply` exactly
   as today.
4. **The match check.** Read the file with a sentinel, so no trailing byte is
   lost: `f="$(cat "$file"; printf x)"; f="${f%x}"`, then strip trailing
   newlines to match what the pane holds. Serve the file only if:
   - `$reply` equals it, **or**
   - `$reply` is **exactly** `roost_reply_encode` of the file's bytes, run with
     the `M` its marker `[roost: reply truncated — M of N bytes]` names: the
     same head, cut back to the same newline, and the same marker.

   **Changed in review round 1:** the first build checked only `N` and that
   the head was a prefix of the file, so a pane value with a shorter head, or a
   marker whose `M` did not match its head, still let the file through
   (reproduced by the reviewer without tmux). `M` comes from the marker, not the
   reader's `ROOST_REPLY_MAX`: a head a writer cut at another cap is still
   exactly that file's.
   Anything else → print `$reply` exactly as today. This is what makes "the
   pane wins" mechanical: a file can only ever replace a pane value it agrees
   with.
5. The staleness notice (`working|blocked|error`), unchanged.
6. Print with the same `printf '%s\n'` (or `render_stdin`).

**Byte-identical for today's users, by construction.** Without a record, steps
3–4 fall through to today's print. With a record and a reply under the cap, the
match check passes only when the file equals `$reply`, so the same bytes are
printed (M8, cases 1–7). The only visible change is the one #42 asks for: a
reply over the cap prints whole, without the truncation marker (M8, case 8).

On tmux 3.4 and 3.5a a reply containing control bytes or invalid UTF-8 is
stored rewritten (#41's "tmux that rewrites what it stores"), so the match fails
and the pane value is printed — today's output, including the 12 KB cap for
such a reply on those versions.

### `--turn N`

`roost read [--turn N] [-r|--render|--json] TGT [LINES]`, flags before the
target like the existing ones, each once, in any order.

- `N ≥ 1` is an absolute turn number. `N ≤ -1` counts back: `-1` is the newest
  recorded turn, `-2` the one before. `0` is a usage error.
- It reads the record only. It never falls back to the screen: the caller asked
  for a specific turn, and the screen is not that turn.
- It prints no staleness notice: the caller chose the turn.
- A turn that was pruned: exit 1, stderr
  `roost read: turn 3 of '%5' was pruned — turns 51 to 150 are kept (ROOST_RECORD_KEEP=100).`
- No record: exit 1, stderr `roost read: no recorded turns for '%5'.`
- A turn past the newest, or in a gap: exit 1, stderr
  `roost read: turn 9 of '%5' is not recorded — turns 3 to 5 are kept.`
- `--turn -K` with K larger than the number of kept turns reads as pruned when
  turn 1 is no longer kept, and as not recorded otherwise.
- A value that is not a non-zero integer, or a second `--turn`, is a usage
  error, exit 1. The usage line printed with it is the existing one, unchanged.

**Built note:** counting back sorts the kept turn numbers with one `sort -n`
fed from a variable (`roost_record_back`). The first version ran a `for` loop
holding a `case` inside `$(...)`, which bash 3.2 cannot parse.

### A gone pane

When `TGT` is a pane id (`%N`), tmux has no such pane, and the server `read`
talks to is running: take that server's boot key, and if
`<boot>/<N>/` exists, print its newest turn (or `--turn N`) with a notice on
stderr and exit 0:

```
roost read: '%581' is gone — this is its last recorded reply (turn 12).
```

A window name, `session:window` or `@N` for a gone window cannot be mapped to a
pane in #42 and keeps today's error. That is the `name` field's job later.
A record from an earlier server boot is not reachable by `%N` alone: `%0` on
this boot is a different pane (M1).

**Changed while building — "tmux has no such pane" is an empty `#{pane_id}`, not
a failed command.** On tmux 3.6, `display-message -p -t %N '#{start_time}-#{pid}
#{pane_id}'` for a pane that was closed exits 0 and prints the server's own
formats with an empty pane id. The first build treated a zero exit as "the pane
exists", and a closed pane never reached its record. `bin/roost`'s `record_for`
now calls a pane found only when the printed pane id is non-empty.

### Malformed or foreign records

Every case is **one warning line on stderr**, and the command then does exactly
what it would do with no record at all. The warning never decides the exit code.

| found | warning | then |
|---|---|---|
| no `schema` (but `replies/` exists), or not a plain integer | `roost read: the record for '%5' is unreadable (schema: x) — ignored.` | live pane: the pane value, exit unchanged. Gone pane: today's failure for a gone pane (exit 1, the usual notices). `--turn`: `no recorded turns`, exit 1 |
| `schema` greater than 1 | `roost read: the record for '%5' was written by a newer roost (schema 2) — ignored.` | the same |
| pointer names a missing file | none | the pane value |
| a directory with neither `schema` nor `replies/` | none — a writer may be creating it | treated as no record |

What the schema file held is printed only when it is at most 20 plain
characters; otherwise the warning says `?`.

`status` does not read records in #42, so it has nothing to warn about. When
#51 adds `status --all`, a malformed record is one warning line there, never
exit 1 — the rule is stated here so that build inherits it.

### `--json`

Additive only, so `ROOST_JSON_SCHEMA` stays 1 (the #41 rule: adding a field or
an enum value is not breaking):

- a new field `turn`: number or `null` — the turn whose file supplied `text`.
  It is present in **every** `read --json` document, the screen fallback
  included, so a consumer never tests for a missing key. This is the one byte
  difference a pane with no record shows: `"turn":null` after `error_reason`
  (measured by an old-versus-new comparison, 27 invocations, in the build
  report);
- `source` gains the value `"record"`, used for a gone pane and for `--turn`.
  A live pane served from its file keeps `"reply"`: it is the pane's reply.

## Growth and cleanup

**Per pane: the newest 100 turns** (`ROOST_RECORD_KEEP`, default 100). Pruned
at write time: after a turn is linked, the oldest files beyond the bound are
removed. Measured p99 is 90 turns per transcript, max 256 (M6). At the
measured p90 reply, 100 turns is about 250 KB; at the largest reply seen, about
2.5 MB.

**Across panes: records that are not live are removed after 30 days**
(`ROOST_RECORD_DAYS`, default 30). The sweep runs only when a **new** pane
record is created, which is once per pane, never once per turn: one
`find "$root" -mindepth 3 -maxdepth 3 -type d -name replies -mtime +30` — the
`replies/` directory, because linking a turn changes **its** mtime and not the
pane directory's — then the liveness call (M3) for each candidate, and
`rm -rf` of the pane directory only for history. A boot directory left empty is
removed too. A live pane is never swept, however old its last
reply.

No bytes-per-reply cap in the file. The largest reply measured was 24,675
bytes; the practical ceiling comes from the adapters (see Risks).

**Pruning is never silent; the sweep is documented, not reported.** (The first
draft said "nothing is removed silently", which review round 1 correctly called
untrue of the sweep.)

- `read --turn` names a pruned turn and the kept range (above).
- `roost help` states both bounds, their variables, where records live, and
  how to turn them off.

**Changed while building — two reports dropped.** The design also proposed a
hint on `read` for a gone pane whose record was swept, shown "when the record
directory for this boot has other panes but not this one", and a `roost doctor`
line. The hint was a guess: a closed shell pane that never had a record meets
the same condition, and would have been told its record was swept. It is not
built. The doctor line is left for a follow-up; the bounds are documented in
`roost help` instead.

**The command: `roost forget`.**

| form | removes | prints |
|---|---|---|
| `roost forget TGT` | that pane's record (live or gone, `%N` on this boot) | `roost forget: removed the record for '%5' (12 turns, 31 KB)`; no record: `roost forget: no record for '%5'.`, exit 1 |
| `roost forget --gone` | every record whose liveness check fails, on every boot | `roost forget: removed <boot>/<N> (K turns)` per record, then `roost forget: removed R records, kept L live.` |
| `roost forget --all` | every directory under the root shaped like a boot key, then the root if it is empty | `roost forget: removed N records under <root>` |

**Changed while building:** `--all` removes only boot-key-shaped directories,
not the whole root. A `ROOST_RECORD_DIR` pointed at the wrong directory by
mistake then loses nothing roost did not write. No argument, or an unknown
flag: `usage: roost forget TGT | --gone | --all`, exit 1.

`forget` never touches a pane option: the pane stays the truth, and its current
reply still reads.

## Test plan for the #42 build

**As built:** `tests/test-reply-record.sh`. Two suite-wide guards were added
that this plan did not name: `tests/lib.sh` exports `ROOST_RECORD_DIR=""` so no
existing test file records anything, and `tests/run.sh` fails the run if a
record appears in the real record directory during it whose socket no longer
exists (a test server's — a live agent's record names a socket that is still
there).

A new file, `tests/test-reply-record.sh`. It drives the hook with synthetic
payloads the way `tests/test-reply-channel.sh` does (CI has no `claude`), on a
socket **named `roost`** under `mktemp -d` (M5: any other name is a silent
no-op), with `ROOST_RECORD_DIR`, `HOME` and `XDG_STATE_HOME` in temp dirs.

### Red tests (fail on today's code)

1. A 60 KB reply through the Stop hook reads back whole with `roost read`;
   the same through `roost reply`.
2. Two turns; `read --turn 1` returns the first, `--turn -1` the second.
3. Quotes, newlines, a tab, non-ASCII and a trailing `;` round-trip
   byte-identical through the record (`cmp`, not string compare).
4. A gone pane: `kill-pane`, then `read %N` prints the last reply, the notice,
   exit 0.
5. `ROOST_RECORD_KEEP=3`, five turns: `replies/` holds 3–5; `--turn 1` exits 1
   naming the kept range.
6. `forget TGT`, `forget --gone`, `forget --all` each remove exactly what they
   say: a listing of `ROOST_RECORD_DIR` before and after, with a **live**
   record planted that `--gone` must leave.
7. Sweep: a history record with `replies/` touched to 31 days old is removed
   when a new pane record is created; a live one of the same age is kept.

### Guards (green today, must stay green)

8. **Byte-identical without a record.** Capture stdout, stderr and exit of
   `read` on today's code for: a reply set; no reply (screen fallback); a
   working pane with a stale reply; an error pane with a reason; `--json` of
   each. The same with `ROOST_RECORD_DIR` pointing at an empty directory must
   match exactly.
9. **The pane wins.** Files present, `@roost-reply` unset → screen fallback.
   `@roost-reply` set by hand to a different string with a valid pointer → the
   hand-set string is printed.
10. **Malformed.** `schema` = `x`, `99`, empty, missing → a live `read` prints
    the pane value, exit unchanged; a gone-pane `read` prints the message,
    exit 1.
11. **Restart.** Kill the server, start a new one on the same socket; `read %0`
    on the new server must **not** print the old server's `%0` record.
12. **Concurrency.** Two Stop hooks at once on one pane → two turns, no
    `.tmp` file left, each file whole.
13. **Degrade.** `ROOST_RECORD_DIR` relative, and a read-only directory: the
    hook exits 0 **within 5 s** (a watchdog in the test — the retry loop that
    hung in M4 must show up as a failure, not a stuck suite), and `@roost-reply`
    is still set.
14. **Hot path.** 50 `working` calls on a pane already `working` create no file
    and no directory.
15. **Nothing outside the directory.** A canary `HOME`/`XDG_STATE_HOME` that
    nothing may write to stays empty (the `tests/test-install.sh` canary shape).

### Mutations that must turn a test red

| mutation | test that goes red |
|---|---|
| remove the record write from the Stop branch | 1, 2, 4 |
| remove the record write from `bin/roost reply` | 1 (reply half) |
| `read` ignores the file | 1 |
| drop the match check (serve the file whenever a pointer exists) | 9 |
| serve the file when `@roost-reply` is empty | 9 |
| path without the boot key (`<socket>__<pane>`) | 11 |
| `mv -f` instead of `ln` for a turn | 12 |
| retry on every `ln` failure | 13 |
| prune disabled, or off by one | 5 |
| `forget --gone` skips the liveness check | 6 |
| sweep skips the liveness check | 7 |
| writer ignores a larger `schema` | a case in 10: a writer run against `schema` = 2 must leave the directory unchanged |

### Where they must run

The whole file runs in CI on both platforms. Before the PR, run it in an
Ubuntu container too (tmux 3.4 **and** 3.3a images exist locally), because
these differ there and nowhere else:

- 8 — tmux 3.4 and 3.5a rewrite control bytes; keep the golden cases to valid
  UTF-8, and add one control-byte case that asserts the pane value is printed;
- 11 — `#{start_time}` and pane-id reuse;
- 12, 13 — GNU `ln`, `mktemp` and `find -mtime`;
- 15 — the XDG paths;
- any helper the test runs under `sh` must be dash-clean.

## What #51 and #57 will add, and why it is additive

**#57 (revive a conversation)** adds, at the same two write sites plus
`spawn`/`split`: `harness`, `session_id` (and a per-turn
`replies/NNNNNN.session_id` sidecar if a pane can change conversations), and
`cwd`. `roost revive TGT` reads the record — live or history — and hands
`session_id` to the adapter's own resume command, as #57 asks. Each is a new
file in an existing directory: a #42 reader never lists them, a #42 writer
never touches them, and a #57 writer backfills them into #42-era records on
the next write. `schema` stays 1.

**#51 (save and restore a fleet)** is a user-run `save` that reads **live
tmux**, not records, and writes its own documented, hand-editable file — #51
forbids continuous snapshotting, so the record cannot be the save file. What
the record adds for #51 is the conversation half: `save` copies `harness`,
`session_id` and `cwd` from each live pane's record into the save file, so a
restore with an explicit relaunch flag can revive rather than start empty
shells. Optionally `name`, `session`, `window`, `state` — new files again —
let `roost status --all` list history across servers with the liveness check
and a warning line per malformed record. Nothing in the #42 layout changes for
either.

**What would not be additive**, and so is fixed now: the path (boot key and
pane number), raw bytes per turn with no encoding, the six-digit turn name and
its numeric sort, the pointer option's meaning, and the schema rule.

## Risks, and what was left out

### Risks

- **Replies now persist on disk** for up to 30 days after a pane is gone
  (records of live panes, indefinitely). Files are `0600` in a `0700`
  directory, under the user's own state directory. The user docs must say
  so, and name `roost forget --all`. *Severity: medium — a behaviour change
  a user should hear about.*
- **Node adapters pass the reply as one argv string.** Linux refuses a single
  argument of 131,072 bytes or more (M7). Such a reply fails `execFile` before
  roost runs, so neither the pane nor the record gets it, and `read` falls back
  to the screen with its notice. Today's behaviour, and loud. The largest reply
  measured was 24,675 bytes (Claude only). macOS allows about 1 MB total
  (*not measured here*). A `roost reply` stdin form would close it; left for a
  follow-up. *Severity: low.*
- **Trailing newlines and NUL bytes are still lost**, because the reply passes
  through `$(...)` and a bash variable before either store. The record is
  "whole" in length, not bit-exact at the end. Same as today. *Severity: low.*
- **A hook that fires twice** (the #58 migration case, two different command
  strings for one event) records the turn twice. The pane is unaffected;
  `--turn` numbers skip one. *Severity: low.*
- **A stale glob during pruning** could, in theory, let a writer link a number
  that pruning already freed, placing a turn out of order. It needs at least
  `ROOST_RECORD_KEEP` writes on one pane between one writer's glob and its
  `ln`. *Not reachable with one agent per pane; not tested.*
- **Boot-key collision** — a new server with the same pid in the same second
  (M3). *Not reachable in practice.*
- **tmux 3.4/3.5a**: a reply with control bytes or invalid UTF-8 keeps the
  12 KB cap on `read` there (the match check fails, the pane wins). *Severity:
  low; documented in known-gaps by the build.*

### Left out on purpose

- `status --all`, reading a gone pane by name, reading another boot's record —
  need `name` and a listing command; #51.
- `session_id`, `harness`, `cwd`, revive — #57.
- Any lock, daemon, queue, index or database.
- JSON on disk (D1 B), and the Claude-transcript read path (D2 H), pending the
  human's answer.
- `@roost-agent-job` in the record (#73's fact is about a live pane only).
- Changing how the hook gets the reply out of the payload.
