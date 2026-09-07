# Cut-off messages between roost agents: what was measured, and what was fixed

**Date:** 2026-09-07 · **Branch:** `worktree-cutoff` · **tmux 3.6, Darwin arm64.**
Every probe and every test builds its own throwaway `-S` socket. Nothing here
touched the live `-L roost` server except one `roost reply` onto this agent's
own pane.

Four findings. Three are fixed, one is reported. Every fix was written test-first
and then had the fix removed again to confirm the test comes back red — a test
that has only ever run against fixed code proves nothing about either.

---

## 0. The detectors, and the three that lied

A probe whose own setup is broken delivers nothing and reports nothing changed,
which is indistinguishable from the bug being absent. Three probes here had to
be thrown away, and each was caught only by a line asserting the probe could
still see what it was looking for:

1. **A byte-count detector that could not report a short delivery.** The pane
   ran `cat > FILE` and the probe did `: > FILE` between measurements. `cat`
   keeps its own file offset, so later writes landed past a hole and `wc -c`
   counted the hole. Measured "deliveries" grew monotonically — 1174 bytes for
   a 1024-byte send, 78427 for a 16333-byte send — and every row read as a
   pass. Fixed with a fresh pane and a fresh file per measurement.
2. **A "no python3, no jq" probe that stripped `PATH` by copying system
   binaries into a temp dir.** macOS SIGKILLs a copied signed binary. Every
   shell in that PATH died before running, and the probe's own "the strip
   bites" line reported success for a `sh` that never started. Fixed by leaving
   `PATH` alone and shimming `python3` and `jq` to `exit 1`, which reaches the
   identical branch.
3. **A cold-start fixture that echoed keys it was about to destroy.** The first
   version of `tests/fixtures/cold-start-tui.py` left the tty echoing during
   startup, so the doomed bytes were painted on screen — and a screen-based
   check would have found the very text that was about to cease to exist and
   called the delivery good. It now runs raw with echo OFF until takeover.

The rule that caught all three: before believing a negative result, plant the
thing you are looking for and prove the detector sees it. Every test file added
here starts with detector-proof assertions and fails loudly if they stop
holding.

---

## 1. PRIMARY — a ~3066-byte ceiling that is above tmux and below the agent

**Status: MEASURED by the coordinator (%54). Not fixed — but no longer silent;
see "What roost does about it" below.**

### The measurement, with its method

Two briefs sent to this pane with `roost send`, both cut:

| brief | bytes sent | cut at offset | what survived | `roost send` exit |
| --- | --- | --- | --- | --- |
| 1 | 3466 | 3067 | the last 399 bytes | **0** |
| 2 | 3502 | 3066 | the last 436 bytes | **0** |

Mid-word both times. **Head discarded, tail kept** — the opposite direction from
every truncation roost performs itself, all of which keep the head and mark the
cut.

**The control, and it is the part that matters.** The same 3502 bytes were
pushed through `send-keys -l` to a throwaway `-S` socket with a plain reader,
and again with that reader asleep for five seconds. **3501 of 3502 bytes arrived
both times.** So tmux delivers a message of this size, and delivers it to a
reader that is not yet reading. tmux is not the ceiling.

### What that rules in, and what it does not

**Established:** the loss is above tmux and below the agent's own handling of
the text. It is not the ~16344-byte `send-keys` command cap (finding 3), which
is more than four times larger and refuses the whole command rather than cutting
it.

**Strongly indicated:** a fixed boundary rather than a timing race. The
*discarded* prefix is near-constant across two different message lengths (3067
and 3066 from messages of 3466 and 3502). A takeover flush — the mechanism in
finding 2 — destroys whatever happens to have arrived by a moment in *time*, so
it would not land within one byte of the same offset twice.

**Not established, and not claimed:** that the ceiling is in the Claude Code TUI
input path specifically. The control reader was a plain one; it never performed
the raw-mode takeover flush that a TUI does, so it is a good control for tmux
and not a control for "what a TUI does to a large paste". The mechanism is
unmeasured. Per AGENTS.md §9, the shared location of the two losses is not
evidence that they are the same kind of thing.

**Unmeasured, and it decides the fix:** whether the ceiling repeats when the
same message is typed again. If the discard is one-time, retyping recovers the
message. If it is per-burst, retyping cannot.

### What roost does about it

Nothing delivers a 3502-byte message through a ceiling roost does not
understand. What the fix in finding 2 does do is make this loss **impossible to
miss**, because the check it added is on the message's HEAD — and the head is
exactly what this ceiling destroys:

- if retyping recovers the message, `roost send` delivers it whole and exits 0;
- if it does not, `roost send` never presses Enter, submits nothing, and exits 1
  saying it could not confirm the message arrived.

The one outcome that has been removed is the one that happened twice: exit 0
over a brief whose first 3066 bytes no longer exist.

`tests/test-send-readiness.sh` asserts that contract against a fixture that
destroys a fixed-size prefix (`tests/fixtures/cold-start-tui.py`, `HEADCUT_BYTES`),
after proving the fixture really does destroy the head and keep the tail. It
accepts either outcome above and rejects only a silent exit 0, because the
mechanism is not known and a test must not assert more than was measured.

### The follow-up this needs

**Measure the ceiling directly, then chunk under it.** Drive a real agent pane
with messages at 3000, 3100 and 3200 bytes and find the exact boundary; if it is
fixed, `roost send` should split a long message into pieces below it rather than
relying on retypes. Until then, the standing workaround stands and is now
explained rather than superstitious: write the briefing to a file and send the
path. That is why this reached the field as "cutoff messages when opening a
spawned window" and grew into passing files around — and the real cost, as the
user put it, is that agents stop having conversations.

---

### Measured against a live Claude Code pane (2026-09-07)

Driven with a copy of `bin/roost` at a temp path, against a real Claude Code
2.1.263 pane spawned into the live server. Three results, and the first two
change the picture.

**1. There is no fixed ~3066-byte input-path wall for a pane that is already
ready.** A 6000-byte probe was sent whose padding is an offset ruler — every 10
bytes spell out their own end offset — with the instruction at the TAIL, so it
survives a head cut and the model's answer names the cut point directly. Claude
answered with `000000001000000000200000000`: **offset zero. The head arrived.**

That is not what a fixed size ceiling does. Whatever cut the two briefs at 3067
and 3066 needs a condition this probe did not reproduce, and the obvious
candidate is the one finding 2 is about: those briefs went to a pane that had
just been spawned.

**2. Claude Code collapses a bulk `send-keys` into `[Pasted text #N]`
placeholders, and then the text is nowhere on screen.** Observed repeatedly; one
6000-byte send became six placeholders at once. This broke the fix in finding 2
against the very target it was written for: the head check reads the screen, the
head was never on the screen, so `roost send` retyped seven times and exited 1
having submitted nothing. Measured:

```
send exit=1
roost send: could not confirm the message reached '%183' within 15s — nothing was submitted
```

That trades a silent partial delivery for a loud total one, which is worse. Now
repaired: when the head cannot be found but the screen CHANGED, the keys were
accepted and only the content is unverifiable, so `send` submits and says on
stderr that it could not check the content. A pane that ate the keys and drew
nothing still fails — that distinction is the cold-start case and it is kept.

**3. The collapse is NOT deterministic by size, and the chunk size is
UNMEASURED.** A sweep of 40/500/900/1000/1024/1100/2048/2100/3066/4000/6000
bytes returned non-monotonic counts — 900 collapsed, 1024 and 3066 did not, 4000
did. A non-monotonic result from a size sweep means the detector is measuring
something other than size (timing, most likely), so no chunk-size number is
recorded here. The tempting arithmetic — 3066 = 3 x 1022, three whole chunks
eaten by a cold start, which would reconcile a timing race with a
near-constant offset — is a HYPOTHESIS with no measurement behind it. It is
written down so the next person tests it, not so they quote it.

A later live re-run appeared to confirm the repair end to end, but the pane's
input box still held text from the sweep above, so the message was contaminated
and that run proves nothing. It is recorded here rather than dropped because a
contaminated green is exactly the shape of result section 0 is about.

### What is still needed

Drive a FRESHLY SPAWNED Claude pane with the offset-ruler probe — the condition
the field reports and the one this session did not reproduce — and read the cut
offset straight off the model's answer. That is one turn, and it settles whether
finding 1 is finding 2 wearing a disguise.

---

## 2. The cold-start race: the front of a message is destroyed, silently

**Status: FIXED.** `bin/roost`, `tests/test-send-readiness.sh`,
`tests/fixtures/cold-start-tui.py`.

### The bug

`roost spawn` prints a pane id the moment the **pane** exists. The agent inside
it is not reading its terminal yet. When a TUI does start reading it takes the
tty over by putting it in raw mode and **discarding whatever is already
buffered** — that is how it avoids acting on keys meant for the shell it
replaced. Everything typed before that instant is destroyed, and the remainder
arrives looking exactly like a whole message.

**Measured in the field:** 3466 bytes sent to a freshly spawned Claude pane.
Roughly the last 450 bytes arrived. The **front** was gone. `roost send` exited
0 and reported delivery.

3466 bytes is nowhere near tmux's ~16344-byte command cap, so this is not a size
limit — it is a startup race. It is also why the workaround people arrived at
was "write a file and send the path": a file cannot be half-typed into a TUI
that is not awake yet. The real cost is not one lost brief; it is that agents
stop talking to each other and start passing files.

### Why the existing verification could not see it

`roost send` verified the **submit** and never the **content**. It asked whether
the input line had stopped holding the message — and a half-eaten message
satisfies that exactly as well as a whole one does.

### The fix

`bin/roost`'s `send` now, after typing and **before** pressing Enter:

- takes the message's **head** — the first 24 non-whitespace characters, which
  is the part a cold start eats and therefore the part worth looking for;
- checks it against the pane's screen with whitespace stripped from both sides,
  so a TUI wrapping a long line at its own width cannot break the match;
- if the head is not there, sends `C-u` and **retypes**, every two seconds, up
  to `@roost-send-ready-timeout` (default 15s, clamped to 120). Retyping is
  what fixes it: the first copy is *gone*, not late — the flush happened once,
  at takeover, so waiting alone never recovers it;
- if the head never appears, **exits 1 without ever pressing Enter**. Nothing is
  submitted, so a caller that retries cannot double-run anything.

Verification is skipped, not trusted, when the head is already on screen before
a key is typed (a very short message, or a pane still showing an earlier copy).
That degrades one send to the old behaviour; trusting it would manufacture a
false success, which is the failure being removed.

### Evidence

`tests/test-send-readiness.sh` drives `tests/fixtures/cold-start-tui.py`, which
models the sequence and nothing else: raw with echo off, a parameterised startup
delay, `tcflush(TCIFLUSH)` at takeover, then an input box that echoes, honours
`C-u`, and writes **submitted lines to a file** — never to the screen, so text
stuck in the input box can never be counted as a delivery.

| | before fix | after fix |
| --- | --- | --- |
| head reaches a pane that boots in 2s | **lost** | delivered |
| tail reaches it | **lost** | delivered |
| delivered exactly once (no double brief) | — | 1 |
| exit code for a pane that never becomes ready | **0** | **1**, "nothing was submitted" |

---

## 3. `roost send` blamed the pane for a message tmux refused

**Status: FIXED.** Same commit as finding 2.

`send-keys -l` is all-or-nothing — measured: 16340 bytes delivered whole, 16350
rejected, nothing ever half-typed — so this was never a silent cut. But the
message was `failed to type text into '%N' (pane may have died)`, and the pane
was alive, idle and blameless.

`send` now captures `send-keys`' stderr and tells the two causes apart. Over the
cap it says how many **bytes** the message was, names ~16344 as the ceiling, and
says to write the message to a file and send the path. The byte count is
computed under `LC_ALL=C`, because `${#msg}` under a UTF-8 locale would print a
character count — a number smaller than the limit, next to a message saying the
limit was exceeded.

---

## 4. A finished turn that records no reply serves the PREVIOUS turn's answer

**Status: FIXED for the Claude Stop hook and for errored panes. One route
remains open — see section 6.**

`bin/roost`'s `read` keyed its staleness notice on `@agent_state` being
`working|blocked`. `done` is not in that list, and `done` is exactly the state a
turn that finished without recording a reply is left in:
`scripts/roost-agent-state` wrote `@roost-reply` only `if [ -n "$reply" ]`, and
wrote the state unconditionally.

**Input → wrong output.** Turn 1 answers "TURN ONE REPLY". Turn 2 ends recording
nothing. `roost read %N` prints `TURN ONE REPLY`, exit 0, stderr empty, pane
badged `done`. The caller has no signal of any kind.

Measured before the fix, after proving the detector both ways (it warns on a
known-stale reply and stays silent on a known-fresh one):

```
payload {"last_assistant_message":""}                 state=done  stdout=[TURN ONE REPLY]  stderr=[]
payload {"session_id":"x","hook_event_name":"Stop"}   state=done  stdout=[TURN ONE REPLY]  stderr=[]
no working python3 and no jq                          state=done  stdout=[TURN ONE REPLY]  stderr=[]
pane badged error after a failed turn                 state=error stdout=[TURN ONE REPLY]  stderr=[]
```

The comment in `scripts/roost-agent-state` promised that a machine with neither
JSON reader "records nothing and `roost read` falls back to the screen — the
path that already announces itself". True on turn 1 only. From turn 2 on there
is a stored reply, so the announcing fallback was never reached.

### The fix, in two parts

1. **`scripts/roost-agent-state`** — when a Stop hook reaches `done` and
   extracts no reply, it now **unsets** `@roost-reply` instead of merely
   declining to write it. `read` then takes its self-announcing screen fallback.
   Inside the existing `--stop-hook`, `done` and `[ ! -t 0 ]` guards, so
   `PostToolUse`, a non-`done` state, and a human typing `roost state done` all
   still cannot clear a reply. All three are asserted.
2. **`bin/roost`** — `error` joins `working|blocked` in the staleness notice.
   The reason differs from theirs: those mean the turn has not finished, while
   `error` means it finished badly, and every adapter deliberately drops the
   half-built reply on that path. Either way the stored reply cannot be that
   turn's. This is the more ordinary of the two routes — a provider outage is a
   normal event where an interrupted turn is not.

### Evidence

`tests/test-reply-channel.sh`, 14 new assertions. Three payloads — the field
empty, the field absent, an unparseable body — each asserting four things: the
stale reply is gone, the pane is still badged `done`, `read` announces its
fallback on stderr, and turn 1's answer is not on stdout. Plus the errored-pane
notice, and three guards that the clear cannot fire where it should not.

Every case that existed before started from an **unset** `@roost-reply`, which
is why none of them could reach this bug. The new cases seed turn 1 first, and
that seeding is asserted on its own line: if it ever stops landing, the "stale
reply is gone" assertions would be testing an empty pane option and would pass
for no reason.

---

## 5. Three adapters carry a comment that is false at the top of its range

**Status: REPORTED, not fixed.** Needs a single ~1MB reply, and it is a route
into finding 4 rather than a bug of its own.

`adapters/opencode/roost.js:154`, `adapters/copilot/extension.mjs:73` and
`adapters/pi/roost.ts:67` each say:

> roost truncates to its own byte budget, so nothing is capped here — one place
> decides that.

That holds only while `execFile` can spawn. Measured (`getconf ARG_MAX` =
1048576): 1000000 bytes delivered, 1048576 threw `Error: spawn E2BIG` —
**synchronously**, so it lands in the adapters' `try { … } catch { resolve() }`
rather than their `() => resolve()` callback. It is caught, the promise
resolves, the turn reports `done`, and no reply is recorded. Storing the reply
is the one `run()` call whose failure is not cosmetic, and it is the one that
cannot report failure.

---

## 6. What is still open

- **An adapter turn that ends `done` having published nothing.** `bin/roost`'s
  `state` subcommand is `exec .../roost-agent-state "${2:-idle}"` — no
  `--stop-hook` — so opencode, copilot and pi never reach the clearing branch
  added in finding 4. Reproduced: `state=done`, `stdout=[TURN ONE REPLY]`,
  `stderr=[]`. The errored-pane half of this is now covered by the `error`
  notice; the `done` half is not. The fix wants a way for an adapter to say
  "this turn produced nothing" — `roost reply` with no text happens to store an
  empty value that `read` treats as absent, but nothing tests or documents that
  contract.
- **The three adapter comments** in finding 5.
- **`roost send ""`** — the bare-Enter form — skips the landing check, because
  there is no content to look for. A bare Enter into a pane that is not ready is
  still lost silently. Narrow, and it has no known caller that races a spawn.

---

## Verification summary

| | |
| --- | --- |
| `bash tests/run.sh` | **1309 passed, 0 failed, exit 0**, 34 files. Run twice; identical both times |
| `python3 tests/test-contrast.py` | exit 0 |
| `cd site && pnpm build` | exit 0; both edited pages prerendered |
| Red-first, per fix | cold-start verification: 6 FAIL with the fix out (the head-cut case among them), 7 detector proofs still green. Too-long message: 3 FAIL. Stale reply on `done`: 9 FAIL. Stale reply on `error`: 1 FAIL |

The file count on `run.sh` is checked as well as the totals, because per
AGENTS.md §8 a file that dies early lowers the PASS count without raising the
FAIL count.

## Changed

| File | What |
| --- | --- |
| `bin/roost` | landing verification and retype in `send`; accurate over-length message; `error` added to `read`'s staleness notice |
| `scripts/roost-agent-state` | clear `@roost-reply` when a finished turn records nothing |
| `tests/test-send-readiness.sh` | new — the cold-start race |
| `tests/fixtures/cold-start-tui.py` | new — the TUI startup model, plus a fixed-size head-cut mode for finding 1 |
| `tests/test-reply-channel.sh` | stale-reply cases that seed a previous turn first |
| `site/content/docs/driving-a-fleet.md` | cold starts, the send exit codes, reply staleness |
| `site/content/docs/troubleshooting.md` | "Only the end of my message arrived" |
