# Persistent sessions: a roost fleet survives a reboot — design for #191 (#57, #51, #192, #105)

Status: **revision 10, 2026-10-25. Nothing built.** The four questions in §9
were decided by the human (A, A, A, A) and stand; revision 1 answered the
twelve blocking items of a three-reviewer read, revision 2 the fourteen of a
second, two-reviewer read, revision 3 the five of a third, revision 4 the
six of a fourth, and revision 5 the final read's three (§0), without moving
any decision. Revision 6 records the human's opt-in answer (only the login
service is opt-in; saving is always on) and adds a feature the human asked
for, the **restore offer** (§4.8). Revision 7 answers the offer's review:
four fixes and twelve notes, all inside §4.8 and its test 12 (§0).
Revision 8 answers its second read: a coordinator ruling on agents with
no marker, five fixes and eight notes, inside §4.4, §4.8 and test 12.
Revision 9 answers its third read: three fixes inside §4.4, §4.8, tests 9
and 12. Revision 10 answers the final read of the whole document: two
fixes (an `origin` line belongs to one claim; `--recent` holds past the
restore) and the notes of both reports (§0).
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

### Revision 4: the six blocking items of the fourth read

The same two reviewers read revision 3. Both kept the four decisions and
both said the placeholder is the right mechanism. Every item was a gap in
**who owns a pane, and when**: revision 3 added states one at a time and
they did not form one closed set. So revision 4 adds **one table** (§4.7,
"Who owns a pane"): every state, how it is proved, who may replace the pane,
and what a key does, with every transition between them. §4.1, §4.3 and §4.6
now point at its rows instead of restating rules. Each item changed a
section and added a test in §8.1 that the broken design fails. Items 5 and 6
were measured (§2.7, §2.10).

| # | item | answered in |
|---|---|---|
| 1 | `revive` of a pane a person **took** with a key skips the shell checks and kills the person's shell; the start command survives `exec`, so it cannot tell the two apart | §4.7 table row **taken**: the file name, not the start command, says whose the pane is, and `revive` from **taken** runs the shell checks; §4.1 steps 5a and 7; §8.1 test 6 "taken" |
| 2 | a placeholder that loses its rename to `bootstrap.used` or `%N.failed` starts a shell, which the winner then kills | §4.7: a placeholder starts a shell **only when its own rename wins**; a lost rename always names an owner who will replace the pane. The worker no longer respawns a failed pane at all: **failed, waiting** stays the placeholder, which shows the reason itself; §8.1 tests 2(h) and 11 "failed barrier" |
| 3 | placement creates ordinary shells first and respawns every one later, so a bare attach during placement can lose work | §4.3: **every** pane placement creates starts as a placeholder in its placing form, with its own `restoring/place.<n>` file; the per-pane step claims it by rename before it replaces it, and leaves a pane a key took; §4.7 rows **placing**; §8.1 test 2(i) |
| 4 | `--retry` cannot pass the start-command guard: a store miss had become a shell, a died resume runs the resume command | §4.6: each failed state has its own retry arrow and its own check (**failed, waiting** is still the placeholder; **failed, dead** is checked by `pane_dead`); **failed, changed** and **taken** are never retried; §8.1 test 11 "retry" |
| 5 | the quoted `default-command` value is used as argv[0] and the placeholder never starts | §4.3, §4.7: the placeholder runs by **its own path** as argv, never through that value; the shell it hands over is `default-shell -c "<default-command>"`, read at hand-over, which is also how a user's own `default-command` is kept; measured (§2.10); §8.1 test 1 "wired" |
| 6 | eight hooks in §2.7 and §3.4 do not exist on tmux 3.6 | §2.7 (measured: the list, and which hook each move fires), §3.4 (deleted; `window-linked` added; a direct save after every respawn; swap-pane, swap-window and a join that leaves its source window open named as gaps), §10; §8.1 test 8 "hooks" |

Every non-blocking note of the fourth read is triaged in Appendix D.

### Revision 5: the final read, three fixes and four notes

The fifth read was the last. The coordinator ruled the smallest fixes
only, and no new mechanism. Each fix is an arrow of §4.7's table, with the
§4.1, §4.6 and §3.5 text that points at it, and a red test in §8.1.

| # | item | answered in |
|---|---|---|
| 1 | a resume that exits 0 before identity lands (a declined first-start dialog) leaves no pane, and T19 read that as a person closing it and dropped the key | §4.7 T13b: `pane-exited` on a `.launching` file is `%N.failed exited` (row **failed, exited**), the claim released, the key kept for `revive %N`; T19 limited; §4.6 Release and Cancel, §4.1 steps 1 and 7, §3.5 step 2; §8.1 test 11 "a resume that exits 0" |
| 2 | an interrupted `revive` of a taken shell came back as **waiting**, and the worker replaced the shell | §4.7 T5 (an `origin` line appended after every winning claim), T8b (put back by origin; only `origin waiting` is **waiting**; no line is **failed, interrupted**, never automatic), T8c; §4.6 step 1 and "Interrupted halfway", §4.1 step 5a; §8.1 test 6 "interrupted" |
| 3 | a failed, dead retry that fails a read-only check, and a placeholder that crashes in failed, waiting, landed in no row | §4.7 T7 (stays **failed, dead**, the reason as extra text), T13a (failed, waiting added); §4.6 step 2, §3.5 step 2; §8.1 test 11 "retried while still broken" and "crashes while failed" |
| notes | `close` on a placeholder is `kill-pane` (F N1); `revive --new-window` from a pending file is refused (F N2); the `.failed` file's first line decides T14 or T16 (F N6); T2's changed-command fallback is **placing, taken** (C note) | §4.7 T19, T5, T14, T2; §4.1 step 5a; §4.6; §8.1 tests 2(j), 6, 11 |

Every other note of the fifth read is triaged in Appendix E.

### Revision 6: the opt-in answer, and the restore offer

No review read; two decisions by the human on 2026-10-25.

| # | item | answered in |
|---|---|---|
| 1 | the opt-in reading: **only the login service is opt-in; saving is always on** | §3.4, §3.4a and §9 now say decided, not flagged; nothing else moves, because the spec was already written to this reading |
| 2 | the human's words: "if there is a roost session saved, a crash happens, and roost persist on never was triggered, we should ask the user if they want to restore their previous session, and even allow them to see what that session looks like before (along with maybe a checkbox to say 'turn roost persist on going forward')" | §4.8 (new): when it is asked and when never, the prompt and its keys, the preview (one format with `restore --dry-run`, now pinned in §4.3), start fresh and the `declined` record, the races, and docs; §3.1 (`offer/`, `declined`); §4.3 (`--dry-run` tree); §4.4 and §4.6 (no automatic path restores a declined save); §4.5 (the doctor line); §5.8; §6 step 7; §7; §8.1 test 12, §8.2 item 8; §9 Q1 |

### Revision 7: the restore offer's review, four fixes and twelve notes

The sixth read covered §4.8 only. Each fix has a red test in §8.1 test 12.

| # | item | answered in |
|---|---|---|
| 1 | the offered save was not pinned: a script that starts the server mid-prompt publishes a fresh `shape`, and bare `r`, `p` and `n` then act on a fleet nobody saw | §4.8 checks 6 and 7 (the pin, `offer/save` and `offer/stamp`, taken under `offer/`), the lock paragraph (the pin kept against the ring and the `closed/` cleanup), the script race, `r`, `p` and `declined`; `--from STAMP-GEN` looks at `shape`, then `history/`, then `declined` (§4.3, §3.6); §3.6a's cleanup keeps the pin's boot; §3.1; tests 12(a), 12(k), 12(k2) |
| 2 | a pty is not a person: an agent's tool command with a pty passes the terminal checks and waits forever | §4.8 check 2 (terminals, `ROOST_NO_OFFER` and `--no-offer`, the agent markers, a 60 s bound that starts fresh and declines nothing), the marker table (Claude Code's four measured; codex, Copilot, pi and opencode none known, a build step 7 probe), **No answer**; §6 step 7; §10; tests 12(b) |
| 3 | test 12(g) compared mtimes, and its fixture forbade the second resume | test 12(g): its own fixture with two resumable keys, `ROOST_TEST_PLACE_HOLD` instead of the mtime; the shared fixture's gone-directory pane asserted unlaunched; `ROOST_TEST_NOW` read by the offer, and `ROOST_TEST_OFFER_TIMEOUT`, in §8.1's seam list |
| 4 | test 12(h) never exercised the automatic decline guard | test 12(h2), its own case through `--at-login` and through `ensure_session`'s self-restore; test 12(h3), `l` then `n` with a login job that really runs |
| notes | Enter does not decline (F N1); attach to the fleet's active session (F N2); `offer/` released last (F N3); `ln -f` (F N4); `roost new` asks (F N5); the other-host line (F N6); no step 3 line in the offer (F N7); `--list` marks `declined` (F N9); one pinned save (F N10); `main`, not `roost` (C); only the newest decline kept (C); a rename hint that works (C) | §4.8 throughout; §3.6; §10; Appendix F |

Every note is triaged in Appendix F.

### Revision 8: the restore offer's second review, a ruling, five fixes and eight notes

The seventh read covered §4.8 and test 12 only. Each fix has a red test in
§8.1 test 12.

| # | item | answered in |
|---|---|---|
| ruling | C B1, an agent with no marker still sees the prompt: **not blocking** (coordinator). The offer runs only on the attach verbs, which already end in `exec tmux attach`, so an agent that calls them in a pty already blocks for ever; the offer adds no new hang, and its 60 s bound ends it without a decline | §4.8 "Agents with no marker" (the reasoning), the docs line (known markers suppress it; any other caller times out in 60 s and declines nothing), the marker table (`CODEX_THREAD_ID`, seen once); test 12's `env -u` list is the smoke tests' full list (F N7) |
| 1 | `l` raced the fresh server's first save: `persist on`'s save was `--auto`, could leave only a want, and `RunAtLoad` could then place the crashed fleet after Enter + `l` | §4.4 `on`: its save waits for `lock/`'s live owner and returns only once published (also for `roost persist on` typed by hand); §3.4's table; §4.8 `l`; test 12(h3) with the planted `lock/` (revision 9), `l` + `n` and `l` + Enter |
| 2 | no test ran `r` against a closed pane | test 12(k3) |
| 3 | 12(k2) wanted one preview across two target states | test 12(k2): the same pin identity, the expected `main` collision, `%3` still out |
| 4 | the h3 Linux stub waited for `enable --now`, which §4.4 never sends | test 12(h3): the stub triggers on the real `enable UNIT` argv and records it; the write-only seam is off for this case |
| 5 | h2 forgot the bootstrap window | test 12(h2): compared with the ordinary fresh `spawn x sh` shape |
| notes | the 60 s bound ends at the first key (F N1); re-read the pin's header after `ln -f` (F N2); `--from STAMP-GEN` also looks at `offer/save` (F N3); `l` with No answer (F N4, reversed in revision 9); plant the `persist` marker in 12(h2) (F N5); the `n`, Enter and timeout lines before the `exec` (F N6); Enter's retry needs a re-plant (C); the pin's lifetime (C, nothing to change) | §4.8 throughout; §3.6; §4.3; Appendix G |

Every note is triaged in Appendix G.

### Revision 9: the restore offer's third review, three fixes

The eighth read covered §4.4, §4.8 and test 12. Each fix has a red test.

| # | item | answered in |
|---|---|---|
| C B1 | `l` then silence: the offer promised No answer would still enable the service after `l`; now `l` is a key that ends the 60 s bound, and the offer waits for `r`, `n` or Enter with nothing started or enabled | §4.8 `l` and **No answer**; Appendix G F N4 (reversed); test 12(g) |
| C B2 | `persist on` with the server stopped had no fleet to snapshot and waited on a publish that could not come | §4.4 `on` (decided once by `server_running`: stopped means no save, shape kept, service enabled, the existing `--at-login` path); §3.4's table; test 9 |
| F B1 | test 12(h3) relied on a race it could lose | test 12(h3) plants `lock/` with a `sleep` the test owns, in §3.5's pid-plus-start-time format, before the choice |
| note | 12(h3)'s `n` branch alone would not be red, since the decline guard stops the job; only the Enter branch places `work` (C) | test 12(h3); the revision 8 mutation list (fixed in revision 10) |

### Revision 10: the final read of the whole document, two fixes and the notes

Two readers read all of revision 9. One approved with seven notes; one
asked for two fixes and gave four notes. Each fix has a red test.

| # | item | answered in |
|---|---|---|
| C B1 | an `origin` line outlived its claim: T7, T8 and T8b put files back with it, so an older `origin waiting` survived into an interrupted `revive` of a taken shell, and T8b handed that shell to the worker | §4.7 T5 (an `origin` line belongs to one claim; every arrow out of **launching** removes it first; T6 and T15), T8b, the **launching** row; §4.6 pending record and "Interrupted halfway"; test 6 "an inherited origin", the hold `ROOST_TEST_REVIVE_HOLD_BEFORE_ORIGIN` |
| C B2 | `--recent` was lost at the next attach: placement wrote a plain pending file for a pane `--recent` skipped | §4.3 placement's "will be resumed" and `--recent`; §4.6 pending record; §5.5; test 4 "`--recent` holds at the next attach" |
| notes | status and §0 (F N1, C 1); lookup order with `offer/save` (F N2, C 2); 12(h3) named by its planted lock (F N3, C 1); a failed `on` removes what it wrote (F N4); two repo line references (F N5); "revisions 6 to 9" (F N6); "(superseded below)" in §9 Q1 (F N7); `failed, interrupted` in the refused-send list (C 2); test 4's placeholders and test 1's placement-only phase (C 3); the shared resume engine moved to build step 3 (C 4) | §0; status line; §6 steps 3, 5 and 7; §7; §4.4; §2.7; §4.8; §8.1 tests 1, 4, 12 and the mutation list; §9 Q1 |

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
- **Hooks available** on tmux 3.6 — **measured** (revision 4, item 6, once,
  each name tried with `set-hook -g NAME[98] 'run-shell -b true'` on a
  throwaway `-S` server under a temp `HOME`, `XDG_*` and `TMUX_TMPDIR`; a
  made-up name as the control, which failed). They **exist**:
  `after-new-session`, `after-new-window`, `after-split-window`,
  `after-kill-pane`, `after-rename-window`, `after-rename-session`,
  `after-select-layout`, `after-resize-pane`, `pane-exited`, `pane-died`,
  `window-linked`, `window-unlinked`, `window-renamed`, `session-closed`,
  `session-renamed`, `window-layout-changed`, `client-attached`,
  `client-detached`. They fail with `invalid option`:
  `after-respawn-pane`, `after-move-pane`, `after-join-pane`,
  `after-break-pane`, `after-swap-pane`, `after-move-window`,
  `after-swap-window`, `after-link-window`, `after-kill-window`,
  `after-kill-session`. Revision 3 listed the first eight of those as
  available "from `tmux(1)`" and installed them; that was read, not run,
  and it was wrong. A `kill-window`
  fires `window-unlinked`; a `kill-session` fires `session-closed` then
  `window-unlinked`; the death of a window's last pane fires `pane-exited`
  then `window-unlinked`. So by hook name a killed window and a window whose
  last process exited look the same, and revision 2's kill rule, keyed on
  `after-kill-*`, could not have seen either kill. Whether each name that
  exists on 3.6 also exists on tmux 3.2 (the floor roost checks) and 3.4
  (CI) is *not measured*; test 8 "hooks" loads the conf on CI's tmux, and
  build step 4 runs this probe on both first. `window-layout-changed` fires
  on every resize and is **not** used (§3.4).
- **Which hook a move, a swap and a respawn fire** (revision 4, measured,
  tmux 3.6, once, the same server, a `[97]` hook on each of the names above
  appending its name to a file): `break-pane` → `window-linked` (and
  `window-unlinked` too when it breaks a window's last pane);
  `move-window` → `window-linked` and `window-unlinked`; `link-window` →
  `window-linked`; `join-pane` or `move-pane` → `window-unlinked` only when
  the pane was its window's last, else **only** `window-layout-changed`;
  `swap-pane` → only `window-layout-changed`; `swap-window` → **nothing**;
  `respawn-pane -k` → **nothing** (neither `pane-exited` nor
  `after-kill-pane`; the Fable reviewer measured the same). `kill-pane` →
  `after-kill-pane`, the control. Revision 3 said `break-pane` fired
  `window-unlinked`; that holds only for a window's last pane.
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
  (`BEFORE=%0 %7 AFTER=%0`). `break-pane`, `move-window` and `join-pane`,
  where they fired `window-unlinked` at all (the bullet above says when),
  passed the same set in a different order, so no kill was read. A
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
  pane (measured on tmux 3.4 and 3.6 for #98; `tmux/roost.conf` l.272-274
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

**How the placeholder is started** (revision 4, item 5, measured, tmux 3.6,
macOS 26.3, once). A throwaway `-S` server whose socket path ends in
`/roost`, with `HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `TMUX_TMPDIR`,
`CLAUDE_SETTINGS`, `CODEX_HOME`, `COPILOT_HOME`, `PI_CODING_AGENT_DIR` and
`ROOST_RECORD_DIR` at temp paths, `remain-on-exit on` so a failure stays
visible, and **this checkout's own `scripts/roost-wiring apply`** run against
it, so the `default-command` value is the one wiring really writes:
`'<checkout>/scripts/roost-pane-shell'`, single quotes included
(`scripts/roost-wiring:80-87`). A stand-in placeholder wrote its argv to a
file.

| how the pane was respawned | result |
|---|---|
| `respawn-pane -k "<that value>" <placeholder> FILE wait` — revision 3's form, the value as argv[0] | `pane_dead=1`, status 1; the placeholder **never ran** (the codex reviewer's measurement, repeated with the real value) |
| `respawn-pane -k <checkout>/scripts/roost-pane-shell <placeholder> FILE wait` — the real path as argv[0], the control | alive, the placeholder ran with argv `FILE wait` |
| `respawn-pane -k "<that value>"` — one string, `ensure_session`'s form | alive, a login `bash`: the value is right as a **command string** and wrong only as argv |
| the placeholder hands over with `exec <default-shell> -c "<default-command>"`, both read from its own server at that moment | a `bash` whose `PATH` holds the shim directory at the same place as a pane respawned with the value directly (entry 12 of both, after the login profile) |
| the placeholder started **before** `roost wiring apply` (as the bootstrap is, `default-command` still empty), `apply` run, then a key | a wired shell: the shim directory on `PATH` at entry 12, `ROOST_TMUX` set (Fable N5's case) |
| a user's own `default-command 'exec /bin/sh'` set, then `apply` | `apply` kept the user's value (it replaces only its own); the placeholder, started by path, ran, and handed over to the user's command |
| `exec` inside a pane (`exec sh -c "exec sleep 30"`) | `#{pane_start_command}` still the original line; `#{pane_current_command}` `sleep` — the start command survives an `exec`, as the Fable reviewer measured, so it can never tell a taken shell from a placeholder (§4.7) |

So the placeholder is started by **its own path, as argv**, and never
through `default-command`'s value (§4.3, §4.7); a **shell** pane is still
started with that value as one string, the form that works; and the shell a
key hands over reads `default-shell` and `default-command` at the moment it
is handed over. Not measured: the 5-second wake of §4.7 step 1 (`stty raw
-echo min 0 time 50` with `dd`; the probe above blocked on the byte), and
`remain-on-exit failed` on the placeholder (§4.7) — both in the build step 1
probe, and under `dash` in step 5.

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
  offer/              present while a restore offer waits at a prompt, same owner rule (§4.8)
    save, stamp       the pin: a hard link to the offered save, and its STAMP-GEN      (§4.8)
  declined            a hard link to the newest save a person declined at the offer (§4.8)
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
- **A dotted session name** is the `_` one up to tmux 3.6, which stores
  `.` and `:` as `_` (probe 1.4); tmux 3.7 refuses it ("invalid session
  name"); from 3.7a it is its own name, which tmux keeps (CHANGES 3.7 ->
  3.7a; 3.7, 3.7a and 3.8 measured, `persist-1-tmux38.md`). Restore's
  "this session exists" test takes the rule from the server's version, and
  where tmux does not keep the dots restore makes the session under the `_`
  form, so a dotted saved name is made on 3.7 too.
- **`layout`** is `#{window_layout}` exactly as the server prints it: the
  `CSUM,WxH,X,Y...` form up to tmux 3.7, and from tmux 3.8 a JSON form,
  `{"V":2,"L":{"t":"h","w":200,"h":50,...}}` (built, measured:
  `docs/airig/probes/persist-1-tmux38.md`). Restore gives it to
  `select-layout` unchanged and reads the root cell's size from either form
  (§4.3 Server). tmux 3.8 still takes the older form, so a shape saved on
  an older tmux restores there; a 3.8 shape on an older tmux gets tmux's
  default layout and the one stderr line of §4.3 Windows.
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

**A read rule for `$` (2026-10-27, coordinator ruling R6, probe 1.3).** tmux
3.4 prints every `$` in a value with one backslash put before it — in
`show-options -v`, `display -p` and `list-panes -F` alike, with or without
`#{q:}` — so a pane in `a$b` reads `pane_current_path` `a\$b`, and
`@roost-name` and `@roost-cwd` the same; a backslash already there is not
doubled (`a\$b` reads `a\\$b`). tmux 3.2a and 3.6 print `$` bare. Measured
once on each build and re-run by the coordinator on 3.4
(docs/airig/probes/persist-1-control-bytes.md). So before it lists, the writer
learns once per run whether this server does it: it sets one pane option to
a known value holding `$`, reads it back, and unsets it. When the read comes
back with the backslash, the writer removes exactly one backslash before every
`$` in every value it reads, before any other rule of this section applies.
Without this a save on 3.4 would write a `cwd` that does not exist and a
`name` the person never typed.

**A session group (2026-10-28, coordinator ruling R7, the human's decision,
probe 1.2).** tmux lists a group (`new-session -t`) once per member, every
window and pane under each member's name with the same ids, on 3.2a, 3.4 and
3.6 (docs/airig/probes/persist-1-session-group.md); saved as a linked window,
it would come back as one independent copy per member. So a group is keyed
on `#{session_group}` — never `#{window_linked}`, which reads 0 for a group's
windows on 3.2a and 3.4 and 1 on 3.6 — and its **first member**, the lowest
session id, is saved in full; each **later member** is a `session` block
with only its own keys (`id`, `active`, and `active_window INDEX`, its own
current window) and one `group <first member's name>` line, and no window or
pane blocks. Restore makes the first member, then each later one with
`new-session -d -t =FIRST -s NAME`. A `group` line naming a session with no
full block in the file is an address with no parent: the whole file is
refused (exit 16), the rule above; `--only` of a later member alone joins a
first member already on the server, and is otherwise the same refusal. The
linked-window rule above still holds for a window linked by `link-window`
outside a group.

**What a listing cannot carry (2026-10-28, coordinator ruling R8, probe
1.3).** A newline in a free-text value cuts tmux's line-based listing on
every build; a listing line that does not start with its id (`%N`, `@N`,
`$N`) is a fault of that round, and the writer reads that object's values
one at a time with `display -p -t ID`, applying the control-byte rule to a
newline. tmux 3.4 also prints ESC and other control bytes in an option or
path as `\NNN` text; the writer learns this once per run as it does for `$`
(R6) and then treats any `\NNN` octal sequence in a free-text value as a
control byte — a literal `\033` a person typed is dropped too, the safe side.
A backslash in a session or window name is doubled by tmux at creation, and a
`$` stored as `\$` on 3.2a and 3.4; restore undoes that rewrite before
`new-session -s` and `new-window -n` where it can be undone exactly, and the
writer drops such a name (one stderr line) on a build where it cannot, so a
name never grows from one save and restore to the next.

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
| a window is created, closed (a `kill-window` included), renamed, moved, linked, or made by `break-pane` | `after-new-window[98]`, `window-linked[98]`, `window-unlinked[98]`, `after-rename-window[98]` | placement or a name changed. There is no `after-kill-window`, `after-move-window`, `after-link-window` or `after-break-pane` hook (§2.7, measured in revision 4): `move-window` fires `window-linked` and `window-unlinked`, `link-window` and `break-pane` fire `window-linked` |
| a pane is split, exits, dies under `remain-on-exit`, is killed, or joined or moved out of a window it was the last pane of | `after-split-window[98]`, `pane-exited[98]`, `pane-died[98]`, `after-kill-pane[98]`, `window-unlinked[98]` (the row above) | a pane came, went or changed place; `pane-died` is how a resume that exited at once is seen (§4.6). There is no `after-move-pane`, `after-join-pane` or `after-swap-pane` hook (§2.7) |
| a pane is respawned by roost: `revive`, a resume launch by the worker or a hand restore | a direct `save --auto --trigger respawn` at the end of each, in roost's own code (restore's per-pane step needs none: its final save covers placement, §3.5 step 4) | `respawn-pane -k` fires **no** hook at all (§2.7, measured), and revision 3's `after-respawn-pane` does not exist; the identity hook saves only once identity lands, so without this a revive into a dialog would not be saved |
| a layout is chosen or a pane resized **by command** | `after-select-layout[98]`, `after-resize-pane[98]` | a person meant it; a drag fires `window-layout-changed`, which is not used |
| `roost spawn`, `split`, `view` set `@roost-name` | a direct call at the end of each branch in `bin/roost` | a name changed with no tmux hook for it |
| `roost identify` writes (`ROOST_IDENTITY_WROTE=1`) | a direct call in `roost_identity_stamp`'s caller, only when it wrote | the resume key changed; when nothing changed the one-read-then-bail path is untouched |
| `roost close` has seen the pane go | a direct call at the end of `close`, `--trigger close`; **before** it sends the exit command, `close` writes `closed/<boot>/close.<N>` (§3.6a) | the removal was deliberate, and `pane-exited` cannot say so (§2.7); the `closed/` file, not this save, is what carries it (§3.6a) |
| `roost restore` has finished building | one call, `--trigger restore`, after the `restoring` marker is removed (§3.5) | one coherent save for the whole restore instead of sixty |
| `roost persist on` against a running server | one call, `--trigger persist-on`, **not** `--auto`: it waits for a live owner of `lock/` and returns only once its save is published (§4.4, revision 8); with the server stopped when `on` starts, no call, and the saved shape is kept (§4.4, revision 9) | a fleet that is already running is saved the moment persistence is wanted, and the unit is loaded only after that save is on disk |
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

**Not covered: three moves fire no hook this design uses** (revision 4,
item 6, measured, §2.7): `swap-pane` and a `join-pane` or `move-pane` that
leaves its source window with panes fire only `window-layout-changed`, and
`swap-window` fires nothing. Each is saved with the next event of any other
kind; a crash right after one restores the panes or windows in their places
from before it. Named in §10. Not covered by `window-layout-changed`, for
the reason below.

**Not** on `window-layout-changed` (every resize), not on `after-set-option`
(every badge), nothing on `PostToolUse`, nothing in `roost state`. A drag
resize alone is therefore saved only with the next event of any other kind —
a resize made and then nothing else before a crash restores the previous
layout. Accepted: a layout is the least of what was lost on 2026-10-20. A
shell that `cd`s has no hook either, so its `cwd` is stale until the next
event; accepted for the same reason, and said in the user page (§7).

**Saving is always on** once step 4 lands, with `ROOST_SHAPE_DIR=` the way to
turn it off. #191 decided that the **login service** is off until `roost
persist on`, and the human confirmed on 2026-10-25 that this is the only
opt-in: saving is not (§3.4a, §9). The shape itself costs under 50 ms per structural event and is
what makes a hand `roost restore` after a crash possible with `persist` off,
which is #51 on its own. `persist on` saves at once (the table), so a fleet
enabled and then crashed needs no later event to be on disk. `doctor` says
both halves in one line, `persist: saving on; login restore off (roost
persist on …)`, so "off" is never read as "nothing is written" (§4.5).
Saving with the service off is also what lets a bare `roost` **offer** the
last fleet after a crash (§4.8).

### 3.4a The one switch for saving

Whether a save is written is decided in **one function**,
`roost_shape_saving` in the shape library (`scripts/lib/roost-shape.sh`),
which every writer of §3.4 calls first and which prints the shape directory
or nothing. Today it reads only `ROOST_SHAPE_DIR` (unset: the default path;
empty or relative: nothing). The hooks, the direct calls and `roost save`
never test anything else.

**Decided by the human on 2026-10-25** (§9, the paragraph after Q4): only
the login service is opt-in, and saving is always on, so this function
reads `ROOST_SHAPE_DIR` and nothing else. The list below is kept as the
record of the one-place switch: if that answer were ever reversed and
**saving became opt-in too**, the function would also require the server's
`persist` marker, and these sections would change, and only these (and
§4.8, whose offer would then never appear, since it exists only for
`persist` off):

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
   the file; apply the pending changes this round's wants name (§4.7's
   table: a `pane-died.<%N>` renames that pane's `%N`, `%N.launching` or
   `%N.failed` (failed, waiting) file to `%N.failed died` and releases the
   claim its launch held — arrows T13 and T13a; a `pane-exited.<%N>` on a
   `%N.launching` file renames it to `%N.failed exited` and releases the
   claim, keeping the key — arrow T13b, not a cancel (revision 5)); compare its body to `shape`'s body (§3.2:
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
`persist-on`, `save`, `respawn`). Four triggers are **process deaths, or a
kill with no hook of its own** (revision 4, F N8): `pane-exited`,
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
   --list shows the others`. Inside the restore offer this line is not
   printed, since nothing is being restored yet (§4.8, revision 7).
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
counts and marks the one the rule would pick, and the one `declined`
names, listing that one last when the ring has dropped it (§4.8, revision
7); `--from STAMP-GEN` picks one by hand, looking at `shape`, then
`history/`, then `offer/save` (revision 8), then `declined`; the at-login restore writes which it chose and why to `login.log`.

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
`--at-login` removes directories for boots that no shape in the ring,
not `declined`, and not a live restore offer's pin (`offer/save`, §4.8,
revision 7) names.

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
   step 5a claims like the worker does; a gone `%N` whose file is
   `%N.failed exited` (§4.7 **failed, exited**, revision 5): that file's
   resume block, the pane being gone, so step 7's gone-pane path; a gone
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
   - **A pane with a pending file** — the pane first, then the
     conversation, the one order every launcher uses (revision 4, F N2).
     The pane is claimed by the `revive` arrow of §4.7's table for the
     state its file is in: **waiting** (`%N`, arrow T5), **failed,
     waiting** or **failed, dead** (`%N.failed`, T14, T16), **failed,
     interrupted** (`%N.failed`, T8c) and **taken** (`%N.taken`, T17) are
     each renamed to `%N.launching`, and the winner at once appends its
     `origin` line (§4.7 T5, revision 5). With `--new-window`, any of
     these is refused first, exit 13, `'%N' has a pending resume; revive
     it in place`, nothing renamed (revision 5, F N2). **failed,
     exited** has no pane to claim: its file is removed once the new
     window is launched (§4.7). The rename
     failing means the worker or a key got there first: exit **13**, `'%N'
     is already being resumed` or `'%N' was taken by a key; roost revive it
     again to resume`, nothing launched. **launching** and **launched**:
     exit 13, `'%N' is already being resumed`. **failed, changed** and
     **failed, replaced** have no `revive` arrow from their file: the pane
     runs a person's command or another conversation, so `revive` treats
     it as a pane with no pending file (§4.7's last row), with the checks
     of step 7. Revision 3 renamed `.taken` "the same way, since a person
     is asking now", and then skipped step 7's shell checks for it: the
     Fable reviewer's item 1. The rename proves only that no other
     launcher holds the pane; for **taken**, what is in the pane is the
     person's shell, and step 7 checks it as one.
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
   job. Which check applies is the **last column** ("checks before `-k`") of §4.7's
   table for the state step 5a renamed from (revision 4, item 1): **waiting**
   and **failed, waiting** — the start command is still the placeholder
   line written for the file and `pane_dead` is 0, and no shell check,
   because the rename proved no key arrived; **failed, dead** —
   `pane_dead` is 1; **taken**, **failed, interrupted** (revision 5),
   and a pane with no pending file whose command is a shell — the shell
   checks above. The start command is
   never the test for **taken**: it survives the `exec` that gave the
   person the shell (§2.10), so it reads the same as a placeholder's. A
   check that fails is arrow T9 (`%N.failed pane changed`, exit 1), except
   from **taken** and **failed, interrupted**, where it is T8: the file
   goes back to `%N.taken` (or `%N.failed interrupted`), the
   claim is released, and `revive` exits 1 (`--force` skips the shell
   checks, as for any shell pane). A gone pane, or
   `--new-window`: `new-window -d` in the pane's old session (from the
   record's reserved `session` when written, else the caller's), and
   `@roost-was %OLD` on the new pane. Then `@roost-name` re-stamped.
   `remain-on-exit failed` means a resume that still exits non-zero at
   once (a store that lied, a harness that changed its message) leaves a
   dead pane whose last screen says why, not a hole in the layout (a zero
   exit before identity leaves no pane: §4.7 T13b, revision 5); the next `revive` or
   `respawn-pane` on it clears it. Then `save --auto --trigger respawn`:
   `respawn-pane` fires no hook (§2.7, §3.4).
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
- **Which save.** §3.6's rule, unless `--from`. `--from STAMP-GEN` looks at
  `shape` first, then `history/`, then `offer/save`, then `declined`
  (§4.8, revisions 7 and 8).
- **Server.** Not running: start it the way `ensure_session` does — `-f CONF
  new-session -d -s <first saved session> -c <that session's first cwd>` with
  **`-x W -y H`**, `W` and `H` the largest root cell among that session's
  saved layouts (§2.7: a detached server is otherwise 80x24 and a stacked
  window cannot be built) **and the placeholder of §4.7 as its one pane's
  command**, in its placing form (`roost restore is placing this session -
  press any key for a shell`), watching the file `restoring/bootstrap`,
  which restore writes **before** `new-session` — then `roost wiring
  apply`. The placeholder is given **by its own path, as argv**
  (`<checkout>/scripts/roost-placeholder restoring/bootstrap --placing`),
  never through `default-command`'s value, which does not exist yet here
  and is shell syntax where it does (§2.10, revision 4 item 5); since it
  reads `default-command` only when it hands over, a key after `wiring
  apply` gets a wired shell (§2.10, F N5). Revision 3 drops the
  `@roost-bootstrap` pid marker: the file is the mark, and nothing but
  restore writes it (not `ensure_session`, §1). Running: use it.
- **Sessions.** A saved session whose name exists is **skipped and named**
  (`roost restore: session 'litro' exists — skipped, 9 panes not restored`),
  and every window and pane inside it with it; a partial fleet is never
  merged into a live session (#51 requirement 4) — **except a replaceable
  session**, defined by a positive mark, not by its look. Revision 3 (item
  1) makes the mark provable: a session is replaceable only when this run
  of restore created it (a dead run's bootstrap is settled into a shell by
  §4.7 arrow T2b, and is skipped like any session that exists) and wins `mv
  restoring/bootstrap restoring/bootstrap.used` — §4.7's arrow T2, the same
  rename race as every placing pane's, which the placeholder runs as `mv …
  bootstrap.taken` on the first key — and it still holds exactly one pane,
  the one restore made. A rename restore loses means a key arrived, and the
  pane is **placing, taken**: the person's shell. A rename restore wins
  means no key had arrived, and from then on a key loses and starts
  nothing (§4.7 row **placing, claimed**, revision 4 item 2), so the
  session restore then fills holds no shell of a person's. Eligibility therefore ends at the first
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
  -d -s NAME -x W -y H` for a detached server, so every session has room,
  each with a placing placeholder as its first pane's command (Windows,
  below). A session skipped because a key took the bootstrap is named by
  `restore --list` as `skipped: the bootstrap pane was taken by a key`, and
  comes back with `tmux kill-session -t NAME` then `roost restore --only
  NAME` (revision 4, F N6).
- **Every pane placement creates is roost's from its creation** (revision
  4, item 3). Revision 3 gave only the bootstrap a placeholder and created
  every other session, window and split as an ordinary login shell, which
  the per-pane step below then replaced unconditionally — so a person who
  attached with a bare `tmux attach` during placement (§4.6 allows it) and
  started a build in one of those shells lost it. Now restore writes
  `restoring/place.<n>` (`n` its own counter) **before** it creates each
  pane, and creates the pane with the placing placeholder as its command,
  by path as argv: `new-session … <checkout>/scripts/roost-placeholder
  restoring/place.<n> --placing`, the same for `new-window` and
  `split-window`. Every such pane is in §4.7's state **placing** until the
  per-pane step claims it. Built, each name carries its run's token
  (`place.<run>.<n>`, `bootstrap.<run>`; review round 2 of Part 1): a
  key's shell keeps its placing line for as long as the pane lives, and a
  later run's own `place.1` once matched it.
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
  blocks in order, **the per-pane step**, for **every** pane, the first
  included (§4.7 arrows T2 and T3):
  1. **Claim it**: `mv restoring/place.<n> restoring/place.<n>.used` (the
     bootstrap's file for the first pane). **Lost** — the file is
     `place.<n>.taken`, a key got there first — the pane is **placing,
     taken**, the person's shell: restore leaves it exactly as it is (its
     directory is the one it was created in), and that saved block is not
     placed into it. If the block had a key that would have been resumed,
     its pending file is written as `%N.taken` (§4.6's overlay keeps the
     key, as for any taken pane), and the report names it with `roost
     revive %N`. Revision 3 respawned every pane here unconditionally.
  2. **Won**: replace it. A pane that will be resumed (a key, not stale,
     its directory present, not `--no-resume`, and not skipped by
     `--recent`, revision 10, C B2) gets its pending file
     written **first** (§4.6), then `respawn-pane -k -c CWD
     <checkout>/scripts/roost-placeholder pending/<boot>/%N HARNESS`, so
     it **waits in a placeholder**, not a shell (§4.7) — the placeholder by
     **its own path, as argv** (revision 4, item 5). Any other pane gets
     `respawn-pane -k -c CWD "<default-command's value>"`, the value as
     **one string**, `ensure_session`'s form, read once with `show-options
     -gqv default-command` after `roost wiring apply` and **passed
     explicitly**, because a bare `respawn-pane` re-runs the pane's
     creation command — here the placing placeholder — and ignores
     `default-command` (a reviewer measured it on tmux 3.6;
     `bin/roost:199-208` says the same). When that value is empty (a
     server with wiring off), the command is `#{default-shell}` with `-l`
     as argv, what tmux runs for an empty `default-command`.

  Revision 3 appended the placeholder's words to that value, `"<value>"
  <placeholder> PENDING HARNESS`, and tmux then ran the quoted value as a
  file name: the pane died with status 1 and no placeholder ran (§2.10,
  measured with the value wiring really writes). A **user's own**
  `default-command`, which `roost wiring apply` keeps (§2.10), is used
  exactly where tmux would use it — for a shell pane, and for the shell a
  placeholder hands over (§4.7) — and never as the program that starts
  roost's own placeholder or a resume, which run by path as an argv
  (through `roost-pane-shell` on a wired server, §4.1 step 6). So creation
  order does not have to match cell order and every pane is a shell, or a
  placeholder, in its own saved directory, or a shell a person took;
  no agent has run in them yet. This step makes no `save --auto --trigger
  respawn` call: `restoring/` holds every save until restore's own final
  one (§3.5 step 4), which covers it. `select-layout` failing (`invalid layout` on
  an edited string)
  leaves tmux's default layout and one stderr line. `zoomed 1`: `resize-pane -Z` after the layout. Pane names re-stamped;
  `@roost-was %OLD` on every pane; the alias map written (§5.4); the saved
  active window and pane selected. A pane with no conversation is a shell
  in its old directory at this point.
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
  id leaves the pane **failed, waiting** (§4.7): still the placeholder,
  now showing the reason, and a key gives a shell (revision 4: revision 3
  respawned it into a shell, which item 2 showed could kill one a person
  had just been given); a dialog is left on screen. `--recent DAYS` skips the resume (not the placement) of a
  pane whose transcript, when recorded, is older than DAYS by mtime; a pane
  with no transcript path is always resumed. The skip is decided at
  **placement**, like `--no-resume` (revision 10, C B2): such a pane is not
  one that "will be resumed", so it gets a shell in its directory and **no
  pending file**, and no later attach can launch it. Revision 9 wrote its
  pending file and skipped it only in this loop, so the next attach's
  worker, which runs without `--recent`, launched the agent the person had
  left out. `--only SEL` (repeatable)
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
  **The plan is one tree** (revision 6, pinned so §4.8's preview reuses it
  and no second format exists): a first line naming the save and why it was
  picked, then each session, its windows indented under it, its panes under
  those, one line per pane with its index, `name`, directory, harness, and
  what restore would do with it:

  ```
  from 20261024T205102Z-4182 (the newest save; saved 2 h ago)
  session roost
    window 1 roost
      pane 1 promo     /home/me/w/roost       claude  resume
      pane 2 linkedin  /home/me/w/roost       -       shell
      pane 3 nested    /home/me/w/roost       -       shell, not resumed: stale (nested codex)
    window 2 build
      pane 1 api       /home/me/w/gone        codex   shell in ~, not resumed: directory gone
  session litro (exists - skipped, 9 panes not restored)
  ```

  The reasons are §5.6's and §5.1a's words: `stale (exited|nested|other
  HARNESS)`, `store miss`, `directory gone`, `harness missing`, `no key`.
  It reads files and the harness stores only: `--dry-run` **never starts a
  server**, and with no server running it skips nothing as existing. A pane
  removed by `closed/` (§3.6 step 4) is not shown; a window or session left
  empty by it is not either. Plain text, no pager, no colour when stdout is
  not a terminal.

### 4.4 `roost persist on|off|status [--name NAME]` (#192)

Bring the fleet back at login, opt in. One unit **per server**, never a
shared template, so `off` for one server touches nothing of another's.

- **`on`**: write the `persist` marker in the server's shape directory; write
  `service.env` (below); save once (`--trigger persist-on`) **when the
  server is running** (below); install the user service and load it.
  **With the server running when `on` starts, the save is published before
  the unit is loaded** (revision 8, F B1): it is not `--auto`, so when `lock/` has a
  live owner (an `after-new-session` hook's saver, which runs `-b` and
  can still hold it after `new-session` has returned) it does not leave a
  want and go on; it waits for that owner by §3.5's owner rule, then
  takes `lock/` and saves, and `on` goes on only once that save is
  published. Otherwise `RunAtLoad` (below) could run `--at-login` while
  `shape` is still the crashed save, skip the live `main`, and place every
  other saved session. This holds for `roost persist on` typed by hand as
  well as for the offer's `l` (§4.8), which always meets a running server.
  **With the server stopped when `on` starts** (revision 9, C B2), there is
  no live fleet to snapshot (§4.2), so the publish wait does not apply:
  `on` saves nothing, keeps the saved shape as it is, enables the service,
  and takes the existing `--at-login` path below (macOS: the loaded
  `RunAtLoad` job; Linux: `on` runs `--at-login` itself), with no live
  snapshot, so §3.6 picks the saved fleet. Which case applies is decided
  once, by `server_running` when `on` starts. A server that was running
  then and dies during the required save is not the stopped case: the save
  fails (§4.2, exit 1), and `on` fails before the load step, with the unit
  not loaded. A failed save also removes the `persist` marker and
  `service.env` that this `on` wrote, so a failed `on` leaves nothing
  behind: otherwise §4.8 check 5 would never ask again, `doctor` would read
  "login restore on" and `ensure_session` would run a login restore with no
  service behind it (revision 10, F N4):
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
    NAME with the reading rule of §3.6 **up to placement** — unless the
    save that rule picks is the one `declined` names (§4.8, revision 6):
    then it places nothing and writes one `login.log` line saying so,
    since a person said no to that fleet and no automatic path overrules
    them — (the pending
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
  (a new server asks before restoring; roost persist on to restore the
  fleet at login)`, or, with `ROOST_SHAPE_DIR=`, `persist: saving off
  (ROOST_SHAPE_DIR is empty); login restore off`. When `declined` exists
  (§4.8, revision 6) the line ends `; declined at the restore offer:
  20261024T205102Z-4182 (roost restore --from 20261024T205102Z-4182)`, so
  a "no" pressed in a hurry can still be found.
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
  directory present, not excluded by `--no-resume` or `--recent`, §4.3,
  revision 10), named by the new `%N` and written **before** that
  pane's placeholder starts, holding its resume block (`was`, `harness`,
  `session_id`, `transcript`, `cwd`, `session_cwd`, `session`, `window`)
  and **`order N`** (its place in the shape's pane order, which the loop
  walks). Revision 2's `pid` and `cursor` lines are gone (item 1): the
  file's own name is now the proof (§4.7), and a file rewritten after the
  placeholder started could race its rename. The one line added later is
  `origin STATE`, appended only by the launcher whose rename to
  `%N.launching` has already won (§4.7 T5, revision 5), so no placeholder
  races it; and it is removed again before the file leaves `.launching`
  by any arrow, so it never outlives its claim (§4.7 T5, revision 10).
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
  only plain `%N` files — and, with `--retry`, the `%N.failed` files whose
  state has a retry arrow in §4.7's table: **failed, waiting** and
  **failed, dead**, told apart by the file's first line (`died`, or a
  waiting reason; §4.7 T14, revision 5, F N6). The placeholders are already there, so straight to
  agents, `--pace` apart (§5.5 applies here too). For each pane, in this
  order, which is `revive`'s order too: **the pane first, then the
  conversation** (revision 4, F N2; revision 3 had the worker take them the
  other way round, and a `revive` meeting the worker on one pane could
  leave both backing off):
  1. **Claim the pane**: `mv` its file from the name it has to
     `%N.launching` (§4.7 arrows T5, T14, T16), then append `origin
     waiting` or `origin failed REASON` (revision 5; T8b reads it if this
     run dies). This is the rename the
     placeholder races on a key; if the worker loses, the pane is the
     person's (or another launcher's): move on, nothing touched.
  2. **Check, touching nothing else**: §4.1 steps 3 to 5 — the harness on
     `PATH`, the directory by §5.1, the key in the store, no live pane
     carrying it. A failure is arrow T7: `mv %N.launching %N.failed` with
     the reason written in, and **the pane is not touched** — it is still
     the placeholder, which shows the reason itself (§4.7 step 1). A
     retried **failed, dead** pane is still dead: its file keeps `died`
     as the first line and gains the reason as extra text, so it stays
     **failed, dead** (§4.7 T7, revision 5).
     Revision 3 renamed the file and then respawned the placeholder into a
     plain shell that printed the reason; a key in the gap between the two
     got a shell from the losing placeholder, and the respawn killed it
     (revision 4, item 2). With no respawn there is no gap.
  3. **Claim the conversation**: §4.1 step 5a's `mkdir
     claims/<boot>/<harness>-<session_id>` — the **one** claim every
     launcher takes, so a `revive` and a worker, or two workers, never
     launch one key twice. A live claim for another pane: arrow T7,
     `%N.failed duplicate of %M`, the pane untouched, so it too shows its
     reason and is not left saying "waiting" for ever (F N4).
  4. **Check the pane is what its state says**: the last ("checks before `-k`")
     column of §4.7's table for the state step 1 renamed from — from
     **waiting** or **failed, waiting**: `#{pane_start_command}` is the
     placeholder line written for this file and `pane_dead` is 0 (a person
     who respawned the pane with another command fails it; a bare
     `respawn-pane` restarts the same placeholder, which passes); from
     **failed, dead**: `pane_dead` is 1, whatever the start command (a
     dead pane holds no person's work). Fails: arrow T9, `%N.failed pane
     changed`, this run's claim released, the pane not touched.
  5. **Launch**, arrow T10: §4.1 steps 6 to 8, `respawn-pane -k` with the
     resume command, under `remain-on-exit failed`, then `save --auto
     --trigger respawn`.

  This is how `--retry` works (revision 4, item 3). Revision 3 sent a
  retried file through a check that only a placeholder could pass, after
  turning a store-miss pane into a shell and leaving a died one running the
  resume command, so both were refused as `pane changed`. Now a **failed,
  waiting** pane is still the placeholder, and a **failed, dead** pane is
  checked by `pane_dead`, so both recover; **taken**, **failed, changed**
  and **failed, replaced** have no retry arrow, so a retry never meets a
  person's shell or job.
  A key that arrives after step 1 finds the file renamed; the placeholder
  prints `resuming <harness> now` and waits to be replaced (§2.10), or
  shows the reason once step 2 or 3 has marked it failed.
  **Release** — arrows T11, T12, T13 of §4.7, each time only what that
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
  `%N.failed died` and the claim is released, so `--retry` can reach it;
  when the resume exits **0** before identity lands, no pane is left and
  `pane-exited` is arrow T13b, not a cancel: the file becomes `%N.failed
  exited`, the claim is released and the key kept, for `revive %N`
  (revision 5, F B1).
- **Cancel** — arrow T19. `pane-exited`, a kill by any route
  (`after-kill-pane`, or a pane in a `window-unlinked` or `session-closed`
  difference, §3.6a) and `roost close` on a pane with a pending file, in
  any state, remove it and release any claim it holds: a person who closed
  the pane did not want the agent. Except (revision 5): `pane-exited` on a
  `.launching` file is T13b, since identity has not landed and no person
  closed anything; and `roost close` on a **waiting**, **launching** or
  **failed** placeholder (or a failed, dead pane) is `kill-pane`, not the
  harness's exit keys, which the placeholder would read as a key (F N1).
  **Taking** a pane is not a cancel: a
  **taken** pane is a shell the person is using, and §4.6's overlay keeps
  its key until that pane goes.
- **Interrupted halfway** (the person detached and the server died, or the
  loop was killed): unclaimed files are still there for the next attach. A
  **launching** file whose launcher is gone is arrow T8b of §4.7: only the
  worker that holds `resuming/` puts it back, by its `origin` line —
  `%N` only for `origin waiting`; `%N.taken`, `%N.failed REASON`, or
  `%N.failed interrupted` when there is no line (revision 5, C B1) — with
  the `origin` line removed before the rename (revision 10, C B1), and
  releases that claim — no other process renames a `.launching` file it did not make, so
  a recovery can never take a file a new, live launcher has just claimed.
  `.launching`, `.failed` and `.taken` files are listed by `restore
  --list`, `status` and `doctor`; `roost restore --resume --retry` retries
  the failed states that have a retry arrow, and `roost revive %N` the
  states that have a `revive` arrow (§4.1 step 5a).
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
  same OS boot has the marker and is left alone. A save that `declined`
  names is not restored here either (§4.4's `--at-login` rule, revision 6).
  With `persist` **off**, `ensure_session` restores nothing by itself;
  a bare `roost` **asks** instead (§4.8).
- `pending/<boot>/` and `claims/<boot>/` for a boot that is gone are removed
  by the next `--at-login`, after its own pending files are written; `rm
  -rf` of the shape directory forgets them with the rest.

### 4.7 The placeholder: a pane roost can prove untouched

Three paths replace a pane with `respawn-pane -k` without a person naming
it: the resume loop (§4.6, at first attach and in a hand restore), and
placement (§4.3: the replaceable session, and since revision 4 every pane
placement creates). Revision 1 guarded only `working` and
`blocked` badges, which a plain shell never has. Revision 2 placed **shells**
and tried to prove from outside that nobody had used one: the same pid, a
shell, no child, and the cursor where it was. Both reviewers broke that
proof (revision 3, item 1): the cursor moves with nobody there, when the
prompt draws and when an attach resizes the window, so every pane failed;
and typed text followed by Ctrl-A puts the cursor back, so a half-typed
command passed and was destroyed. A live shell cannot be proven unused from
outside, because what a person typed is inside the shell.

So a pane that roost may still replace does **not** run a shell. It runs
`scripts/roost-placeholder`, a short POSIX `sh` program, started by **its
own path as argv** (`<checkout>/scripts/roost-placeholder FILE HARNESS`, or
`FILE --placing` for a pane placement made) — never through
`default-command`'s value, which is shell syntax (§2.10, revision 4 item
5) — and under `remain-on-exit failed`, so a placeholder that crashes
leaves a dead pane saying why instead of vanishing as if a person had
closed it (revision 4, F N3; arrow T13a below):

1. It prints the line for the state its file is in (the table: `waiting to
   resume <harness> - press any key for a shell`, `roost restore is placing
   this session - press any key for a shell`, `resuming <harness> now`, or
   `<harness> was not resumed: <reason> - press any key for a shell; roost
   restore --resume --retry tries again`), then waits for **one byte**
   from the terminal in raw mode, waking every 5 s (`stty raw -echo min 0
   time 50`, then `dd bs=1 count=1`) to read its file's name again and
   reprint the line when the state changed. That wake is how a **failed,
   waiting** pane shows its reason without being respawned (revision 4,
   item 2); a wake with no byte does nothing else. Nothing else ends the
   wait: no rc file runs (it is not a shell), a resize is not input, and an
   attach is not input (§2.10 measured both).
2. On a byte it reads and throws away whatever else was already typed,
   restores the terminal, then tries **its take arrow**: `mv FILE
   FILE.taken` from **waiting** or **placing**, `mv FILE.failed
   FILE.taken` from **failed, waiting** (T4, T6, T15).
   - **The rename wins**: the pane is the person's. It prints `this pane is
     yours; <harness> was not resumed (roost revive %N to resume it)` (and
     the reason, from a failed file), clears its pane's `remain-on-exit`
     (`tmux set -pu`, so the person's shell behaves like any other), and
     `exec`s what tmux would start in this pane now: `#{default-shell} -c
     "#{default-command}"`, both read from its own server at that moment,
     or `#{default-shell} -l` when `default-command` is empty. Read at that
     moment, so a bootstrap started before `roost wiring apply` hands over a
     wired shell, and a user's own `default-command` is what that user gets
     (both measured, §2.10). The bytes after the first are thrown away on
     purpose: half a word reaching a fresh shell would run as a different
     command.
   - **The rename loses**: it prints the line for the state the file is in
     now and **keeps waiting**; a later byte tries again. It **never**
     starts a shell after a lost rename (revision 4, item 2). Revision 3
     started one whenever the loser found no `.launching` file; but the
     name that beat it — `.launching`, `bootstrap.used` or `place.<n>.used`,
     or revision 3's `.failed` — always names an owner who is about to
     replace the pane, and that owner then killed the shell. Now every name
     a placeholder can lose to has an owner in the table, and the owner
     either replaces the pane or puts the file back to a name the next key
     can win.

**The proof** is the rename: a launcher's or restore's `mv` and the
placeholder's `mv … .taken` race on one file, rename(2) is atomic, and
exactly one wins. Who then owns the pane is read from **the file's name**,
never from the pane alone: `#{pane_start_command}` survives the `exec` that
hands a person the shell (§2.10, measured by the Fable reviewer and again
in revision 4), so a **taken** shell and a **waiting** placeholder have the
same start command, and `#{pane_current_command}` reads `bash` for both on
macOS. The start command is checked only to catch a person who
**respawned** a pane with another command, and only from the states whose
row says so.

What is **not** used, and why: `#{pane_current_command}` (above); the
cursor, measured to move by itself; `pane_pid`, which a bare `respawn-pane`
changes while the pane is still an unused placeholder.

#### Who owns a pane (revision 4)

Every pane that placement or a resume may replace is in exactly one of
these states. A builder builds from this table and the transitions after
it; §4.1, §4.3 and §4.6 point at its rows and arrows. **F** is a placing
file, `restoring/bootstrap` or `restoring/place.<n>`; **P** is a pending
file, `pending/<boot>/%N`. "Owner live" is §3.5's owner rule: a recorded
pid that runs with its recorded start time, never an age. "The placeholder
line" is the `#{pane_start_command}` restore or the worker wrote for that
file.

| state | proved by: the file, and the pane | who may replace the pane | a key in the pane | `roost send` | what a launcher or restore that renamed **from** this state checks before `-k` |
|---|---|---|---|---|---|
| **placing** | `F`; the placeholder line, `--placing` (alive, or dead if the placeholder crashed) | nobody until restore wins `F → F.used` (T2) | the placeholder wins `F → F.taken` (T4): a shell | refused | the placing line, the pane alive or dead (a dead one is a crashed placeholder and holds nothing) |
| **placing, claimed** | `F.used`; the placeholder line | restore, the live owner of `restoring/` (T3); after it dies, the restore that takes `restoring/` over (T2b) | rename lost: `roost restore is placing this pane`, keeps waiting, **no shell** | refused | — (no arrow leaves it by rename) |
| **placing, taken** | `F.taken`; any command | **nobody**: the person's shell; restore leaves it (§4.3), and when `restoring/` goes, the pane has no file (or `P` as `%N.taken`, §4.3) | the shell's | as for any pane | — |
| **waiting** | `P` as `%N`; the placeholder line, `pane_dead` 0 | nobody until a launcher wins `%N → %N.launching` (T5) | the placeholder wins `%N → %N.taken` (T6): a shell | refused | the placeholder line, `pane_dead` 0 |
| **launching** | `%N.launching`, with an `origin` line once the winner has written it (revision 5), removed before the file leaves this state (revision 10); the placeholder line | the launcher whose claim (or `resuming/`) is live (T7, T9, T10); when it is dead, only the worker holding `resuming/` (T8b), by the `origin` line | rename lost: `resuming <harness> now`, keeps waiting, **no shell** | refused | — (the launcher checks by the state it came from, §4.6 step 4) |
| **launched** | `%N.launching`; the resume command | **nobody**: the harness runs, perhaps in a dialog; the claim is held until T11–T13b | the harness's | refused unless `--force` (a dialog) | — |
| **failed, waiting** | `%N.failed`, its first line a reason: `harness missing`, `directory gone`, `store miss`, `duplicate of %M`; the placeholder line, `pane_dead` 0 | nobody automatically; `--retry` or `revive` by `%N.failed → %N.launching` (T14) | the placeholder wins `%N.failed → %N.taken` (T15): the reason, then a shell | refused | the placeholder line, `pane_dead` 0 |
| **failed, dead** | `%N.failed`, its first line `died` (any later line is extra text, such as a retry's failed check, T7); `pane_dead` 1 (a resume that exited non-zero, or a crashed placeholder, T13a) | nobody automatically; `--retry` or `revive` by `%N.failed → %N.launching` (T16) | none: tmux gives a dead pane no input | refused | `pane_dead` 1 |
| **failed, exited** | `%N.failed exited`; **no pane**: a resume exited 0 before identity landed, and `remain-on-exit failed` keeps only a non-zero exit (T13b, revision 5) | nobody: there is no pane; never retried; `revive %N` reads the file's key and launches in a new window, as for a gone pane (§4.1 steps 1 and 7), and removes the file once launched | — | — | — |
| **failed, interrupted** | `%N.failed interrupted`; the placeholder line, `pane_dead` 0 — a placeholder **or** a shell a key took, which the start command cannot tell apart (§2.10) | **nobody automatically**; never retried; only `revive`, a person naming the pane, by `%N.failed → %N.launching` (T8c, revision 5) | the placeholder, if it is one, wins `%N.failed → %N.taken` (T15) | refused | §4.1 step 7's shell checks, as from **taken** (a placeholder's own wait has a child, so it is refused unless `--force`; a key first makes it **taken**) |
| **failed, changed** | `%N.failed pane changed`; a command a person respawned | **nobody**; never retried; `revive` treats the pane as one with no file (last row) | that command's | as for any pane | — |
| **failed, replaced** | `%N.failed replaced`; another conversation, its own `@roost-session` | **nobody**; never retried; the file is a record until the pane goes | that harness's | as for any pane | — |
| **taken** | `%N.taken`; the person's shell (start command still the placeholder line) | **nobody automatically**; only `revive`, a person naming the pane, by `%N.taken → %N.launching` (T17) | the shell's | as for any pane | §4.1 step 7's shell checks: no child process, else exit 1 unless `--force` |
| **no file** | no `F`, no `P` | §4.1's rules: only `revive`, a person naming it | — | — | §4.1 step 7: the `working`/`blocked` rule, and the shell checks for a shell |

**Transitions.** Each is one rename (or one removal) by the actor named; a
rename that fails changes nothing and the actor does what its row says.

- **T1** restore writes `F`, then creates the pane with the placing
  placeholder: → **placing** (§4.3).
- **T2** restore's per-pane step wins `F → F.used`: → **placing,
  claimed**. Lost: the pane is **placing, taken**; restore leaves it.
  Won, but the pane no longer runs its placing line (a person respawned
  it by hand): restore renames `F.used → F.taken` and leaves it the same
  way → **placing, taken**, the person-owned row (revision 5, C note).
- **T2b** a restore that takes over a dead `restoring/` (§3.5) also takes
  the dead run's files: each `F.used`, and each `F` it wins, whose pane
  still runs its placing line, it respawns into a plain shell in that
  pane's directory (it has no saved block for it), then goes on with its
  own run. The dead run's bootstrap is settled the same way, so it now
  holds a shell and is **not** a replaceable session for the new run: its
  saved session is skipped and named, exit 12 (§4.3).
- **T3** restore, holding **placing, claimed**, respawns the pane: with a
  key, it writes `P` first and starts the waiting placeholder → **waiting**;
  without, a shell → **no file** when `restoring/` is removed.
- **T4** a key in **placing**: the placeholder wins `F → F.taken` →
  **placing, taken**.
- **T5** a launcher (the worker, a hand restore, `revive`) wins `%N →
  %N.launching` → **launching**. Every winning rename to `%N.launching`
  (T5, T14, T16, T17, T8c) is followed at once by the winner appending
  `origin STATE` to the file: `origin waiting`, `origin failed REASON`
  (the old first line) or `origin taken` — the one record of whose pane it
  was that outlives the launcher (revision 5, C B1). **An `origin` line
  belongs to one claim only** (revision 10, C B1): every actor that moves
  a file out of `%N.launching` to any other name (T7, T8, T8b, T9, T12,
  T13, T13a, T13b) first removes every `origin` line from it while it
  still holds the claim — a rewrite to a temporary file beside it, renamed
  over `%N.launching` — and only then renames it; T8b reads the line into
  its own memory before it removes it. So a `%N`, `%N.failed` or
  `%N.taken` file never carries an `origin` line, and a newly claimable
  file never has one. T6 and T15 are a placeholder's race and cannot
  rewrite a file before their rename; the rule means the file they win
  has no line, and should one be there, the placeholder removes it from
  the `.taken` file it now owns before it starts the shell. Without the
  rule an older attempt's `origin waiting` survives a later claim: a
  waiting pane fails its store check (T7), a key takes it (T15), and a
  `revive` of that shell (T17) that dies before its own append leaves
  the old line, which T8b would read as **waiting** and hand the shell to
  the worker. With it, that `revive` leaves no line, and T8b gives
  **failed, interrupted**. `revive --new-window`
  is refused, exit 13, `'%N' has a pending resume; revive it in place`,
  from every state with a pending file and a live pane (**waiting**,
  **failed, waiting**, **failed, dead**, **failed, interrupted**,
  **taken**), before any rename: the agent would land elsewhere, and
  `%N.launching` would wait for an identity that never lands on `%N`
  (revision 5, F N2).
- **T6** a key in **waiting**: `%N → %N.taken` → **taken**.
- **T7** the worker or a hand restore, in **launching**, finds a
  read-only check failing or the conversation claimed for another pane
  (`revive` makes its read-only checks before it renames anything, §4.1): `%N.launching → %N.failed`
  with the reason, its own claim (if taken) released, the pane untouched →
  **failed, waiting**. From an `origin failed died` claim (T16, a dead
  pane) it stays **failed, dead**: the first line stays `died` and the new
  reason is added as extra text on a later line; it is never relabelled
  **failed, waiting**, whose row needs a live placeholder (revision 5, C
  B2(a)).
- **T8** a `revive` whose conversation claim is refused (from any state),
  or whose step 7 shell checks fail from **taken** or **failed,
  interrupted**: the file goes back to the name it came from
  (**waiting**, **failed, waiting**, **failed, dead**, **failed,
  interrupted** or **taken**), its own claim released. (The worker's claim
  refusal is T7, `duplicate of %M`, since no person is asking.)
- **T8b** the worker holding `resuming/` finds **launching** with the
  placeholder line and a dead launcher: it puts the file back by its
  `origin` line and releases the dead claim. Only `origin waiting` goes
  back to `%N` → **waiting**. `origin taken` goes back to `%N.taken` →
  **taken**; `origin failed REASON` goes back to `%N.failed` with REASON
  as its first line → **failed, waiting**, **failed, dead** or **failed,
  interrupted**, by that line. No `origin` line (the launcher died
  between its rename and its append) proves nothing: `%N.failed
  interrupted` → **failed, interrupted**, never automatic. In every case
  the worker reads the line first and removes it before the rename (T5's
  rule, revision 10). Revision 4
  sent every interrupted claim back to `%N`, so a `revive` of a taken
  shell killed after T17 became a waiting pane that the worker replaced
  without the shell checks (revision 5, C B1). No other process renames a
  `.launching` file it did not make.
- **T8c** `revive` wins `%N.failed → %N.launching` from **failed,
  interrupted**; §4.1 step 7's shell checks then decide, as for T17:
  pass → T10, fail → T8 back to **failed, interrupted**.
- **T9** the launcher's check before `-k` fails: `%N.launching →
  %N.failed pane changed`, its claim released, the pane untouched →
  **failed, changed**. (From **taken**, `revive` takes T8 instead and
  exits 1.)
- **T10** the launcher respawns the pane with the resume command under
  `remain-on-exit failed`, then saves (`--trigger respawn`) → **launched**.
- **T11** identity lands on the pane with the same `session_id`: the file
  and the claim are removed → **no file**.
- **T12** identity lands with a different id → **failed, replaced**, the
  claim released.
- **T13** `pane-died` on **launched** (the saver, §3.5 step 2) → **failed,
  dead**, the claim released.
- **T13a** `pane-died` on **waiting**, on **launching** with the
  placeholder line, or on **failed, waiting** (the placeholder itself
  crashed, perhaps while it showed its reason) → **failed, dead**: the
  file is `%N.failed died` (the old reason kept as extra text), a claim
  released if one was held (revision 5, C B2(b) and F N4).
- **T13b** `pane-exited` on a `.launching` file (revision 5, F B1). A
  `.launching` file at that moment means identity has not landed (T11
  would have removed it, T12 renamed it): the harness quit, perhaps from
  a first-start dialog, with status 0, and `remain-on-exit failed` keeps
  only a non-zero exit, so the pane is gone. That is not a person closing
  the pane: `%N.launching → %N.failed exited`, the claim released, the key
  kept → **failed, exited**.
- **T14** `--retry` or `revive` wins `%N.failed → %N.launching` from
  **failed, waiting** → **launching**; the loop then runs every check again.
  The `.failed` file's **first line** decides T14 or T16: `died` is
  **failed, dead** (T16); `harness missing`, `directory gone`, `store
  miss` or `duplicate of %M` is **failed, waiting** (T14); any other
  (`pane changed`, `replaced`, `exited`, `interrupted`) has no retry
  arrow (revision 5, F N6).
- **T15** a key in **failed, waiting**: `%N.failed → %N.taken` →
  **taken**.
- **T16** `--retry` or `revive` wins `%N.failed → %N.launching` from
  **failed, dead** → **launching**, whose check is `pane_dead` 1.
- **T17** `revive` wins `%N.taken → %N.launching` from **taken**; step 7's
  shell checks then decide: pass → T10, fail → T8 back to **taken**.
- **T18** identity lands on a **taken** pane (the person started an agent
  in it): the file is removed → **no file** (revision 4, F N7).
- **T19** the pane exits, is killed by any route, or is closed with `roost
  close`, in any state: the file is removed and any claim it holds
  released (§4.6 Cancel). Two limits (revision 5): `pane-exited` on a
  `.launching` file is T13b, never T19, so in **launched** T19 is a kill
  or a `close`, not the harness quitting before identity; and `roost
  close` on a pane whose file is `%N`, `%N.launching` with the
  placeholder line, or `%N.failed` (**waiting**, **launching**, **failed,
  waiting**, **failed, dead**, **failed, interrupted**) is `kill-pane`,
  never the harness's exit keys, whose first byte would be a key that
  takes the pane (F N1).

Two rules fall out of the table and are what the reviewers' four ownership
items broke. **A placeholder starts a shell only when its own rename
wins** (items 2 and 3). **An automatic path replaces a pane only from a
state it reached by its own rename, after the check in that state's
row** (items 1 and 4): the worker and a hand restore touch only
**waiting**, and with `--retry` **failed, waiting** and **failed, dead**;
placement touches only **placing** it has claimed; only `revive`, a person
naming the pane, reaches **taken** and **failed, interrupted**, and then
with the shell checks.

The cost, said in Q1 and on the site page: until its turn, each agent pane
shows the waiting line instead of a prompt, and a person who wants a shell
there presses a key, which keeps that agent out of the automatic resume
(`roost revive %N` brings it back). During placement every pane shows the
placing line for the moment it takes. `roost send` refuses where the
table's column says so, the way it refuses a blocked target (unless
`--force`), so a coordinator's prompt is not thrown away as the "key" that
takes a pane.

### 4.8 The restore offer: a bare `roost` asks after a crash (revisions 6 to 9)

The human's request, 2026-10-25: when a fleet was saved, a crash happened,
and `roost persist on` was never run, **ask** whether to bring it back,
show what it held first, and offer to turn the login restore on from then
on. Today such a person gets an empty `roost` session and has to know that
`roost restore` exists. The offer adds no mechanism to restore itself: its
`r` is §4.3's placement and §4.6's first-attach resume, and its preview is
§4.3's `--dry-run` tree.

**When it is asked.** All of these, checked in this order, cheapest first,
before anything else `roost` does:

1. The verb is an **attach**: a bare `roost`, `roost session NAME`
   (`attach_session`, `bin/roost:219`), or `roost new` (`bin/roost:465-472`,
   which ends in an attach). The coordinator's shape said a bare `roost`;
   `roost session NAME` is the same person at the same terminal after the
   same crash, so it asks too. So does `roost new` (revision 7, F N5): it
   is typed by the same person, and if it did not ask, the server it starts
   would end the offer for good, since check 3 fails from then on.
   `roost spawn` and every other verb that calls `ensure_session` without
   attaching never ask: those are scripts and agents, not a person waiting
   to attach.
2. **A person, not a script** (revision 7, item 2). A terminal alone does
   not prove one: an agent's tool command run with a pty passes `[ -t 0 ]
   && [ -t 1 ]` (the codex reviewer ran it, once), and would then wait for
   a key forever. So all of these:
   - (a) stdin and stdout are both terminals (`[ -t 0 ] && [ -t 1 ]`). Not
     a terminal is a script, a pipe, or an agent's shell;
   - (b) `ROOST_NO_OFFER` is unset or empty, and no `--no-offer` came
     before the verb (`roost --no-offer`, `roost --no-offer session NAME`):
     the switch for a script that attaches through a pty on purpose;
   - (c) no agent-harness marker of the table below is set and non-empty;
   - (d) once the prompt is shown, a key arrives within **60 s**
     (**No answer**, below). This is the net for a harness with no known
     marker: it holds nothing for more than a minute, and declines nothing.
     The bound ends at the **first key** (revision 8, F N1): one key
     proves a person, so every later read has no timeout, and a person
     who presses `p` and reads a long tree is not started fresh under
     them. An unattended pty never sends a key, so the net still closes
     in 60 s.

   If (a), (b) or (c) fails: no offer, no line, and `roost` does exactly
   what it does today.
3. The **server is not running** (`server_running` false). A running server
   is not a crash to recover from.
4. Saving is on: `roost_shape_saving` (§3.4a) prints a directory. With
   `ROOST_SHAPE_DIR=` there is nothing to offer.
5. The login service is **off**: no `persist` marker (§4.4). With it on,
   §4.6's `ensure_session` path places the fleet by itself; asking as well
   would ask a question that has already been answered.

Here the offer takes **`offer/`** (the lock, below). From here on it acts
on **one** save, the **pin** (revision 7, item 1), and never reads `shape`
again (F N10):

6. §3.6's reading rule picks a save (shutdown evidence and all). Its
   step 3 line, `no shutdown record readable; restoring the newest save
   ...`, is not printed inside the offer, since nothing is being restored
   yet (F N7). The offer **pins** the save at once: `ln -f` of the inode it
   opened to `offer/save`, and the save's `STAMP-GEN`, from its header, in
   `offer/stamp`. `ln` takes a path, not an inode, so a save renamed over
   `shape` between the read and the link would be pinned instead
   (revision 8, F N2): after the `ln -f`, the offer re-reads
   `offer/save`'s header, and when its `boot` or `gen` differ from the
   save it picked, it picks again and pins again, **once**; a second
   mismatch ends the offer, and `roost` goes on as today. §4.3's "refuse first" checks run on `offer/save` (an
   unreadable save gives one stderr line, `roost: the saved shape is
   unreadable (line N: FAULT) - roost restore --list`, and no offer). Its
   `host` must be this machine (a save from elsewhere resumes nothing,
   §4.2); when it is not, one stderr line, `roost: a fleet saved on HOST
   is not offered here (roost restore --list)`, and no offer (F N6: a
   macOS hostname can change with the network, and silence would hide
   why).
7. The pin is not the save `declined` names (by its header's `boot` and
   `gen`), and, after §3.6 step 4 removes what `closed/` names for the
   pin's boot, it holds **something worth restoring**: at least one pane
   with a key (resumable or not), or more than one pane. A fleet closed on
   purpose offers nothing (step 4 leaves no pane), and a save of one plain
   shell is what `roost` is about to make anyway. "From an earlier boot"
   needs no test of its own: the server is not running, so every save is
   from a boot that has ended.

If 6 or 7 fails, `offer/` is released and `roost` goes on as today.

A crash and a normal reboot alike pass these. So does a `tmux kill-server`
typed by hand, which runs no hook (§3.6a) and cannot be told from a crash;
the offer is a question, so asking costs one key.

**The agent markers** (check 2c). Only the markers roost already knows, from
its adapters and its tests. The rule is "any one set and non-empty", so a
marker found later is one line.

| harness | marker | where the repo knows it | measured |
|---|---|---|---|
| Claude Code | `CLAUDECODE` | `tests/live/*-smoke.sh` clear it with `env -u` before they start a test Claude | **measured** once, 2026-10-25, in a Claude Code 2.1.310 tool shell: `printf '%s' "${CLAUDECODE-unset}"` printed `1`, and the same shell failed `[ -t 0 ]` and `[ -t 1 ]` |
| Claude Code | `CLAUDE_CODE_ENTRYPOINT` | the same `env -u` lists | **measured**, the same run: `cli` |
| Claude Code | `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION` | the same `env -u` lists | **measured**, the same run: both names present in `env` (values not read) |
| codex | `CODEX_THREAD_ID` | not in the repo; the adapter reads `CODEX_HOME`, `TMUX` and `TMUX_PANE`, and sets `ROOST_AGENT_NAME=codex` only for its own hook's child (`adapters/codex/roost-codex-hook:351-359`), never in a tool shell | **seen once, not measured across versions**: on 2026-10-25 the codex reviewer's tool shell, with a real pty, passed both terminal checks and had `CODEX_THREAD_ID` set and non-empty (value not printed). Build step 7's probe confirms it per version |
| GitHub Copilot CLI | none known | the adapter reads `COPILOT_HOME` and `TMUX_PANE` | **not measured**, probe in build step 7 |
| pi | none known | the adapter reads `PI_CODING_AGENT_DIR` and `TMUX_PANE` | **not measured**, probe in build step 7 |
| opencode | none known | the adapters read `OPENCODE_CONFIG_DIR` and `TMUX_PANE` | **not measured**, probe in build step 7 |

Not markers, on purpose: the config homes (`CODEX_HOME`, `COPILOT_HOME`,
`PI_CODING_AGENT_DIR`, `OPENCODE_CONFIG_DIR`), which a person's own shell
profile exports as often as a harness does, and `TMUX` and `TMUX_PANE`,
which every person inside tmux has. Step 7's probe runs `env` from each
harness's tool command, with a pty where the harness offers one, and adds
a variable that is set there and not in a plain login shell. Until then
Copilot, pi and opencode are held off by 2b and 2d only, and codex by one
marker seen once. The table is **best effort**: a marker is a way to skip
a minute's wait, not the guarantee that no prompt appears.

**Agents with no marker** (revision 8, coordinator ruling on C B1). An
agent of a harness the table does not cover, calling an attach verb
through a pty, sees the summary and waits up to 60 s. That is accepted,
and not a new hang: the offer runs only on the attach verbs (check 1),
and those already end in `exec tmux attach` (`attach_session`,
`bin/roost:219`, from the case arms at `bin/roost:457-472`), so such a
caller already blocks for ever today, attached to a session it cannot
leave. The offer puts its 60 s bound **in front** of that attach, starts
fresh, and declines nothing. Known markers, `ROOST_NO_OFFER` and
`--no-offer` suppress the prompt; for any other caller it times out.

**Where it runs: before the server starts** (against §4.3 and §4.7). The
offer reads files only — the pin, `closed/`, `declined`, the harness
stores for the preview — and starts nothing while it waits. So there is no
bootstrap session, no placeholder and no `restoring/` while a person
thinks, and §4.7's table gains **no row**: every pane that later exists is
made by a path that table already covers. After the answer:

- `r` runs §4.3 from the pin; when the server is still not running,
  §4.3's own **Server** step makes the bootstrap placeholder, under
  `restoring/`, as it does for a hand restore.
- `n` runs today's `ensure_session`, unchanged.

**The lock: `offer/`, under §3.5's owner rule** (pid and start time, never
age). The offer takes `mkdir offer` after check 5, before check 6 reads a
save, and keeps the pin inside it. It is released, the pin with it, **last,
just before the attach's `exec`** (revision 7, F N3): for `r`, after §4.3
has returned (the server is running and `restoring/` is gone) and after
`l`'s `persist on`; for `n`, Enter and No answer, after `ensure_session`
has returned, and for `n` after `declined` is written. So whoever waits on
`offer/` always finds the server running when it goes. On Ctrl-C, end of
input, or any other exit, a `trap` releases it, with nothing started. Not
`restoring/`: that would make every save, and `ensure_session` in §4.6's
persist path, wait on a person who may have walked away; `offer/` is read
only by another offer and by the cleanup below.

While the pin is held, nothing it needs can go: the ring may prune the
pinned save's `history/` name, but the inode lives on in `offer/save`; and
`--at-login`'s cleanup of `closed/` (§3.6a) keeps the pin's boot, so
§3.6 step 4 still has what it reads.

- **Two terminals typing `roost` at once** (a terminal app that reopens its
  tabs does this): the first takes `offer/` and asks. The second finds
  `offer/` with a live owner and prints `waiting for the restore offer in
  another terminal (pid N)` every 10 s, the wording of §4.6's wait; Ctrl-C
  leaves. When `offer/` goes, the second starts its own checks again from
  1: the server is now running (the first chose `r`, `n` or Enter, or got
  no answer), so it attaches and is not asked. If the first was Ctrl-C'd,
  nothing was started and nothing was declined, so the second asks. One
  offer, never two.
- **A dead owner** (the terminal was closed mid-prompt): the next `roost`
  takes `offer/` over by the owner rule, pins afresh (`ln -f` replaces the
  old link), and asks.
- **A script starting the server while a person is at the prompt**
  (`roost spawn` from an agent elsewhere): it does not read `offer/`, so it
  starts the server, and that server's `after-new-session` save publishes
  a fresh `shape` at once (§3.4). The pin is untouched. When the person
  answers, the offer checks `server_running` once more. `r` then restores
  **the pin** into the running server: §4.3's **Sessions** rule skips a
  pinned session whose name now exists (usually `main`, the default
  session, `bin/roost:158`) and names it, exit 12. `p` previews the pin and
  `n` declines the pin, never the fresh fleet the person did not see. A
  script is never held waiting on a person, and nothing is merged into a
  live session.

**The prompt.** Plain lines on stdout, which check 2 proved is a terminal,
and one key read from stdin with bash 3.2's `read -rsn1 -t 60` for the
first key and `read -rsn1` with no timeout after it (check 2d); no TUI
library and no new dependency. One summary line, the keys line, and the
default:

```
roost: a saved fleet from 2 h ago (2026-10-24 20:51): 13 sessions, 21 windows, 47 panes; 31 of 35 agents would resume.
  r restore it   p preview   n start fresh, do not ask again   l restore at login from now on: off
  Enter starts fresh (nothing is restored without an r).
```

The counts are what §4.3 would place and resume from the pin after step 4:
"would resume" is the `resume` lines of the `--dry-run` tree, so the store
check (§5.1a) and the stale rule (§3.2) are already in it; "of 35" counts
every pane with a key. "2 h ago" is `saved` against now in epoch seconds
(§3.6), rounded to minutes, hours or days. The keys:

- **`r` — restore.** §4.3 with the pin as its source and §3.6 step 4
  applied for the pin's boot: the treatment `--from STAMP-GEN` gets, not
  `--from FILE`'s, which skips step 4 (§3.6). It runs **up to placement**,
  the `--at-login` stop point: the pending record and its waiting
  placeholders are written, no agent is launched by `r` itself. Its report
  goes to the terminal, not to `login.log`, and no `login/<os-boot>` marker
  is written (that marker belongs to the service). Then `roost` attaches,
  and that attach fires `client-attached[98]` (§4.6), which starts the
  paced resume. This is Q1's rule exactly: placement now, agents at first
  attach, 2 s apart, with the person right there for any dialog. A restore
  that exits 12 or 13 prints its report and still attaches. **Which
  session** (revision 7, F N2): for a bare `roost`, when the restored
  fleet has no `main`, the attach goes to the pin's `active 1` session,
  with one line, `roost: attaching to "work", the restored fleet's active
  session (it has no "main")`; a person who just restored thirteen
  sessions should not land in a fourteenth, empty one. `roost session NAME`
  and `roost new` named their session, so a NAME not in the fleet is
  created by `ensure_session` as today.
- **`p` — preview.** Prints the `--dry-run` tree of the pin, with step 4
  applied: the same text `roost restore --dry-run --from STAMP-GEN` prints,
  and by the same call, since that lookup finds `offer/save` even when the
  ring has dropped the pin's `history/` name (revision 8, F N3; `r` uses
  the same lookup, so `r`, `p` and a second terminal's `--dry-run --from
  STAMP-GEN` during an offer are one code path) (§4.3's tree: session, window, pane; each pane's name, directory,
  harness, and `resume` or the reason it would not), then the summary and
  keys again. One format, one code path: the preview **is** the dry run.
  No pager; a long fleet scrolls, and the summary is printed again under
  it so the keys are on screen.
- **`n` — start fresh, and do not ask about this save again.** Writes
  `declined` (below), then runs today's `ensure_session`, prints one line,
  and only then attaches (revision 8, F N6: after `exec tmux attach`
  nothing prints; a line printed before it is on screen when the person
  detaches). The line: `not restored; roost restore --from 20261024T205102Z-4182
  brings it back (doctor names it too)`. Nothing is deleted: the shape,
  its history, `closed/` and the harness stores are untouched. That line
  names **`--from STAMP-GEN`**, not a bare `roost restore`, on purpose: the
  fresh server saves at once (its `after-new-session` hook), so from then
  on a bare `roost restore` picks the fresh fleet, and the declined save is
  only reached by name. **A hint that works** (revision 7, C note): when
  the pin holds a session of the name the fresh server uses (`main` for a
  bare `roost`), that restore would skip it, and if every saved pane is in
  it, restore nothing. So the line then adds `the saved "main" is skipped
  while a "main" runs: tmux -L roost rename-session -t main main-fresh,
  then roost restore --from 20261024T205102Z-4182`, with this server's own
  `-L NAME` or `-S PATH`. Renaming the fresh session frees the name and
  kills nothing; the client stays attached to it. The page says so.
- **`l` — toggle "restore at login from now on"**, shown `off` or `on`,
  starting `off`. It decides nothing by itself and launches nothing; it
  rides on the `r`, `n` or Enter that follows. `l` is a key, so it ends
  the 60 s bound (check 2d): **after `l`, the person must press `r`, `n`
  or Enter to finish** (revision 9, C B1), and until then the offer waits,
  with no server started and no service enabled. When it is on, the offer
  runs `roost persist on` (§4.4) **after** that choice has built its
  server — after `r`'s placement and `restoring/` has gone, or after
  `ensure_session` and, for `n`, after `declined` is written — and before
  the attach. That order matters on macOS: `RunAtLoad` runs `--at-login`
  at once (§4.4), and it must meet a live fleet and skip every session,
  not race a placement or find a server-less pin not yet declined. Order
  alone is not enough: the fresh server's `after-new-session` save runs
  `-b` and may not have landed when `ensure_session` returns. So
  `persist on`'s own save waits for that saver and is published before
  the unit is loaded (§4.4, revision 8, F B1), and `--at-login` then
  picks a save whose sessions all exist. Without that wait, Enter + `l`
  (nothing declined) would place the crashed fleet's
  other sessions, which §5.8 forbids. A
  failing `persist on` prints its own message and `roost: persist on
  failed; the fleet is restored this time only` (or `started fresh`), and
  the attach goes on: it is never fatal.
- **Enter — start fresh, without declining** (revision 7, F N1). The same
  as `n`, except that `declined` is **not** written, and the line reads
  `not restored, not declined; roost restore --from 20261024T205102Z-4182
  brings it back`, with the hint when it applies. Nothing is restored, and
  no agent is launched, without a yes: a person who presses Enter through
  a familiar start gets what `roost` has always done, and loses nothing.
  The opposite default would let one reflex keystroke bring back
  thirty-five agents and their dialogs. And a reflex Enter must not
  silence the offer for good: only `n` does that. **What not declining
  buys, plainly** (revision 8, C note): it does not mean a later bare
  `roost` offers the old fleet again. The fresh server saves at once, so
  its fleet becomes the newest save, and after its next crash §3.6 picks
  that one. The old fleet is then reached by the printed `--from` line;
  it is offered again only if it is again the save §3.6 picks (test
  12(i) makes it so by re-planting it). Not declining keeps the
  automatic paths and `--list` from treating it as turned down, nothing
  more. As with `n`, the line is printed before the attach (F N6).
- **No answer in 60 s** (check 2d): the same as Enter, with the line
  `roost: no answer in 60 s; started fresh, nothing declined (roost
  restore --from 20261024T205102Z-4182 brings it back)`. A person who
  walked away comes back to today's `roost`; an unattended caller with a
  pty and no known marker waits one minute, not forever. The line is
  printed before the attach (F N6). The 60 s apply only before the first
  key (check 2d).
- **Ctrl-C, or end of input**: `offer/` is removed, nothing is started,
  nothing is declined, `roost` exits 130. Leaving is not a decision, so
  the next `roost` asks again.
- **Any other key**: the keys line again.

**`declined`.** A hard link to the pin, in the shape directory, 0600 like
every file there: `ln -f offer/save declined.new && mv -f declined.new
declined` (revision 7, F N4: a `mktemp` name already exists, and a plain
`ln` onto it fails; one fixed name is safe, because only the holder of
`offer/` writes it). A link, not a line holding `boot` and `gen`, because
the fresh server's saves will push that save out of the 100-entry ring
within a busy day, and the line printed at `n` must keep working.
**`--from STAMP-GEN` looks at `shape` first, then `history/`, then
`offer/save`, then `declined`** (revision 7, F; `offer/save` revision 8,
F N3): the newest save is `shape` and has no
`history/` name until the next save lands (§3.5 step 2), and with the
server down no next save is coming. `offer/save` is matched by its
header's `STAMP-GEN`, like the others, and exists only while an offer
holds `offer/`: it covers the pin that has left the ring and is not yet
declined, so `r` and `p` need no private "file plus step 4" path. Check 7 reads `boot` and `gen` from
its header. **Only the newest decline is kept** (revision 7, C note): a
second `n` replaces the first, and when the first save has also left the
ring, the `--from` line printed for it stops working. `restore --list`
and `doctor` name the one that is kept. To keep an older one, copy
`declined` before the next `n`; `roost restore --from COPY` restores the
copy as a `--from FILE`, without step 4's filter, which is then the
caller's choice (§3.6). `declined`'s effects, and only these: the offer
does not ask about that save again; `--at-login` and `ensure_session`'s
self-restore (§4.4, §4.6) do not place it automatically, so ticking `l`
later never brings back a fleet a person turned down; `closed/` for its
boot is kept (§3.6a); and `restore --list` marks it `declined`, listing it
last when the ring has dropped it (F N9). A hand `roost restore --from` it
works as for any save, and step 4 still applies. `rm` of the file forgets
the decline; the shape directory's `rm -rf` forgets it with the rest.

**Docs** (§7): `getting-started.md` gains a short "If roost was not shut
down cleanly" paragraph under "First run", showing the prompt and its
keys, and saying that `roost persist on` makes it automatic. The
persistent-sessions page's persist section explains the offer beside the
login restore: which one runs when (`persist` off asks; on restores), that
a script without a terminal never sees it, that a known agent marker,
`ROOST_NO_OFFER` or `--no-offer` suppresses it, and that for any other
caller it times out in 60 s and declines nothing (revision 8, the
coordinator's ruling: the page never says an agent "never sees" it), that Enter and No answer start fresh
without declining and `n` declines, what `declined` is and that only the
newest is kept, how `--from` brings a declined fleet back, and the rename
hint for a saved `main`. `roost help` names the offer and `--no-offer` in
one line under `roost`. `doctor`'s line (§4.5) names a decline.

**What the offer does not change.** Q1 (agents at first attach), Q2 (a
restore resumes by default; `r` is a restore), Q3 (the files' place) and
Q4 (the printed listing, shown in the preview's reasons for a pane with no
key) all hold. `roost restore` typed by hand is unchanged and is never
asked about; its one change is `--from STAMP-GEN`'s lookup order above.

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
back uses `--only` or `--recent`. Both hold past the restore: a pane they
leave out is placed as a shell with no pending file, so a later attach
does not launch it either (§4.3, revision 10).

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
owner (§3.5); start a service without `persist on`; stop a service, ever;
restore from the offer without an `r`, ask it without a terminal, past a
known marker or past `ROOST_NO_OFFER`/`--no-offer`, hold any other
caller more than 60 s before its first key (revision 8 ruling), restore or
decline a save other than the one shown, or place a declined save by any
automatic path (§4.8).

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
| 1 | `roost save`, the shape format and its refusals (whitespace-exact parser, required keys, `id` lines, stale keys with `stale_reason`, `session_cwd`, `launch`, `zoomed`, linked windows, unknown-block skip), `roost restore` **placement only** (`-x W -y H`, largest-side splits across that side, `select-layout`, the per-pane step with `default-command` passed explicitly as one string, saved indices, `scripts/roost-placeholder` started by its own path as argv, every placed pane a placing placeholder with its `restoring/place.<n>` file, the **placing** rows and arrows T1–T4 of §4.7's table, and the replaceable bootstrap session by its `restoring/bootstrap` rename (§4.3, §4.7), `--dry-run`, `--list`, `--only`, exit 12/16). Probes first: what `#{pane_current_command}` reads under pi, copilot and opencode (§3.2); the placeholder's 5-second wake (`stty raw -echo min 0 time 50` with `dd`) and `remain-on-exit failed` on it, on macOS (§2.10) | M | #51 as written: the guess of lesson 2 is gone; a fleet's shape can be moved between machines by file |
| 2 | `roost revive TGT` with the resume table and the **store check** in the adapters' library (`scripts/lib/roost-resume.sh`, beside `roost-close.sh`), the `claims/<boot>/` claim taken before every launch and released only by its taker (§4.1 step 5a), the directory rule of §5.1 (the transcript's own `cwd`), the duplicate-id refusal with the in-place exemption, `exited` versus `nested`, option clearing and `remain-on-exit failed`, `respawn-pane -k` with its command, the gone-pane path from the record (which gains `transcript`) and the exact-id lookup, exit 13/14/15; the opencode existence check or an honest printed command. Probes first: whether `claude --resume` keeps model and permission mode (Appendix A, the launch-flags row); whether a transcript re-filed by a resume elsewhere keeps its first `cwd` (§5.1) | M | #57: kill a pane, get the conversation back, same `%N` |
| 3 | restore resumes: §4.3's resume loop, which **is** §4.6's shared resume engine run in the foreground, so its prerequisites land here (revision 10, C 4): the pending record (with `order`, written by placement for every pane that will be resumed, with `--no-resume` and `--recent` decided there), `claims/` taken by a hand restore (step 2 ships the directory with `revive`), the placeholder handshake of §4.7 — the waiting, launching, launched, failed and taken rows and arrows T5–T19, with the `origin` rule of T5 — `restore --resume` with `--retry`, and `send`'s refusal on a waiting pane; the arrows that a tmux hook or the saver drives (T13, T13a, T13b, and T19 on a kill) are wired when step 4's hooks land; pacing, `--recent`, `--no-resume`, `@roost-was`, the alias map and `was:%N` in every target-taking verb, `status --json` `was`, the codex note, the mid-turn line; the §2.9 RSS measurement of a resumed stub fleet against placement-only | M | lessons 3, 4 and 5 answered; a manual `roost restore` after a reboot does the whole job |
| 4 | save on change: the hooks in `tmux/roost.conf`, the direct calls in `spawn`/`split`/`view`/identify/`close`, the one switch of §3.4a, the one-saver protocol (`lock` with the owner rule, `want/` per trigger, `gen`, `restoring`), `trigger` lists, the `@roost-ids` refresh in every structural hook, the `closed/<boot>/` files (close, kill difference, death note) and the reading rule's step 4 by id, `pane-died[98]`, the 100-entry ring, the shutdown-record rule in epoch seconds, the three §3.4 cost measurements, the §4.5 doctor warnings about saving. Probes first: the Linux shutdown record (`last -x shutdown`, `journalctl --list-boots`); whether tmux runs `session-closed` hooks during a shutdown on a VM (a `SIGTERM` to the server ran none on macOS, §2.7); the kill-difference probe of §2.7 re-run on tmux 3.2 and 3.4 (Ubuntu CI); the revision 4 hook-name and move probes of §2.7 re-run on tmux 3.2 and 3.4 | S→M | nobody has to remember `roost save`; a crash loses one change at most; a shutdown does not restore what was closed on purpose |
| 5 | `roost persist on/off/status`, per-server plist and unit, `service.env`, `--at-login`, the overlay of all four pending file kinds, `claims/` taken by the worker, the `resuming/` lock, the attach worker over step 3's engine (the pending record, the §4.7 handshake and `restore --resume` ship in step 3, revision 10), the `client-attached` hook, `ensure_session`'s wait and self-restore, `login/<os-boot>`, `login.log`, `roost upgrade` rewriting the unit, the §4.5 doctor line, and the §8.2 human-eye reboot on macOS then Linux. Probe first, on a Linux VM: the unit's behaviour at `--at-login` exit, at `disable`, at logout with and without linger; and the §2.10 placeholder probe under `dash` in the Ubuntu container | M→L | #192: the fleet is back after a reboot without being asked, and the agents when someone is there |
| 6 | the printed store listings of §5.6 (Q4 = A) for Claude and codex. Probe first: what Claude's folder rule does with `_`, a space and a non-ASCII byte, and pi's folder rule for a path with a `.` (only the narrowing uses them; §5.6) | S | the 13 panes of §2.6 are not lost silently |
| 7 | the restore offer (§4.8, revisions 6 to 9): the seven checks in `attach_session` and `roost new`, with the agent markers, `ROOST_NO_OFFER`, `--no-offer` and the 60 s bound, `offer/` under the owner rule and the pin inside it, the prompt and its keys, `p` as `restore --dry-run` (whose tree §4.3 pins, and which step 1 already ships), `r` as placement from the pin then attach (to the fleet's active session when it has no `main`), `n` writing `declined` with the rename hint, Enter and No answer starting fresh without it, `l` running `persist on` after the choice, `--from STAMP-GEN` looking at `shape`, `history/`, `offer/save`, then `declined`, `--list` marking it, `--at-login` and `ensure_session` skipping a declined save, the doctor line, the getting-started paragraph and the page's persist section. This step's first task is the marker probe: `env` from each harness's tool command (codex, Copilot, pi, opencode), a pty where offered, against a plain login shell; any variable set only there joins §4.8's table. It also checks each marker in a shell nested inside the harness's tool shell, and its absence from a terminal a person opens outside the harness (revision 8, F N7), and confirms codex's `CODEX_THREAD_ID` on the version it runs. After step 5, because `r` leans on the pending record and `client-attached` for Q1, and `l` on `persist on` | S | a person whose machine crashed with `persist` off is asked instead of finding an empty session |

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
is answered (§2.7). Revision 4 keeps the order: the placing placeholders
and the placing rows of §4.7 land in step 1 with placement, the rest of
the table in step 5 with the worker; the hook list of step 4 shrinks to
names measured to exist. Revision 6 appends step 7, the restore offer;
the first six are unchanged. Revision 10 keeps the order and moves work
between steps: step 3's hand restore runs the same engine as the worker
(§4.3), so the pending record, the §4.7 handshake and `restore --resume`
move from step 5 into step 3, and step 5 keeps the login service, the
attach worker and its hook. #145 (codex identity under the app-server) is **not**
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
  for §4.6. Only hook names measured to exist (§2.7, revision 4): no
  `after-respawn-pane`, `after-move-*`, `after-swap-*`, `after-join-pane`,
  `after-break-pane` or `after-link-window` line.
- `bin/roost spawn|split|view`: `@roost-launch` set, then one `roost save
  --auto` call after the name is stamped. `roost identify` and the two
  identity hooks: the same call behind `ROOST_IDENTITY_WROTE=1`, which also
  clears a matching `pending/.../%N.launching` and its claim; the record
  writer in `scripts/lib/roost-identity.sh` also writes `transcript` when
  one was reported (§1). `roost close`: the `closed/<boot>/close.<N>` file
  before the exit command and its removal when the close fails (§3.6a), a
  save with `--trigger close` after the pane is gone, and the pending
  cancel. `ensure_session`: §4.6's wait and self-restore when `persist` is
  on, a declined save skipped (§4.8), and no bootstrap marker (revision 3,
  §1). `attach_session` (a bare `roost`, `roost session NAME`) and `roost
  new`: the restore offer's checks and prompt **before** `ensure_session`
  (§4.8, revisions 6 to 9), and a leading `--no-offer`; no other caller of
  `ensure_session` changes. `revive`, and every resume
  launch: `save --auto --trigger respawn` after the respawn (§3.4).
- `roost send` (and `answer`): a pane in a state whose `roost send`
  column in §4.7's table says refused — **placing**, **placing, claimed**,
  **waiting**, **launching**, **launched**, **failed, waiting**, **failed,
  dead**, **failed, interrupted** — is refused the way a blocked target is, unless `--force`.
- `scripts/roost-placeholder`: new (§4.7), started by its own path as
  argv, never through `default-command`'s value or `roost-pane-shell`;
  under `remain-on-exit failed`.
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
  to another machine resumes nothing without the harness stores. Its
  persist section explains the restore offer beside the login restore
  (§4.8's **Docs**).
- `site/content/docs/getting-started.md`: an "If roost was not shut down
  cleanly" paragraph under "First run" (§4.8). `roost restore --from
  STAMP-GEN`: looks at `shape`, then `history/`, then `offer/save`, then `declined`, so it
  finds a declined save when the ring has dropped it; `--list` marks it.

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
second stub `claude-exit1` exits 1 at once for the `remain-on-exit` case,
and a third, `claude-exit0` (revision 5), exits 0 at once without
identifying.
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
and `close` for every stamp they write, and by the restore offer for its
"ago" (revision 7). Revision 7 also adds `ROOST_TEST_OFFER_TIMEOUT=SECONDS`
(the offer's 60 s no-answer bound, §4.8 check 2d) and gives
`ROOST_SHUTDOWN_AT=` **empty** a meaning: no readable shutdown record
(§3.6 rule 3). Revision 4 adds three holds and one
log: `ROOST_TEST_PLACE_HOLD=FILE` (restore waits after a window's panes
are created and its layout applied, before the per-pane step),
`ROOST_TEST_PLACE_HOLD_AFTER_USED=FILE` (restore waits after winning `F →
F.used`, T2, before that pane's respawn), `ROOST_TEST_RESUME_HOLD_AFTER_FAILED=FILE`
(the worker waits after T7, `%N.launching → %N.failed`); and the
revision 5 hold `ROOST_TEST_REVIVE_HOLD=FILE` (`revive` waits after its
rename to `%N.launching`, the `origin` line and its conversation claim,
before step 7), and the revision 10 hold
`ROOST_TEST_REVIVE_HOLD_BEFORE_ORIGIN=FILE` (`revive` waits right after
that rename, before it appends its `origin` line); and the
redirected `HOME`'s `.bash_profile` and `.bashrc` each append
`$TMUX_PANE $$` to `$HOME/shells.log`, so "a shell started in this pane"
is read from a file, never guessed from `#{pane_current_command}`, which
reads `bash` for the placeholder too on macOS (§2.10).

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
   **Wired** (revision 2, item 10): every restored shell pane, **the first
   included**, has `roost-pane-shell` in `#{pane_start_command}` and
   `ROOST_TMUX` in its shell's environment (the stub `sh` prints it to a
   file at start). A bare `respawn-pane` leaves the first pane unwired (a
   reviewer measured it), so this is red against it.
   **Started at all** (revision 4, item 5): the server is wired by the
   real `scripts/roost-wiring apply` under the redirected
   `XDG_CONFIG_HOME`, so `default-command` holds the value wiring really
   writes, single quotes included — never a stub value with a bare path.
   This case reads the panes in a **placement-only phase** (revision 10,
   C 3): `restore --at-login` with no client attached, which stops before
   the resumes and leaves the pending record and its placeholders (§4.3),
   and nothing fires the worker until an attach; a plain `restore` would
   go on to launch the keyed panes by default, and the assertions below
   would race it. This case joins the suite with step 5, which ships
   `--at-login`.
   Every keyed pane's `#{pane_start_command}` begins with the
   placeholder's own absolute path and holds no `'`; one second after
   placement every pane has `pane_dead` 0 and every placeholder's screen
   shows its waiting line. Revision 3's form, the quoted value as argv[0],
   leaves every placeholder dead with status 1 (measured, §2.10), so this
   is red against it. **A user's own `default-command`**: the test's conf
   sets `default-command 'exec /bin/sh'` before `wiring apply`; `apply`
   keeps it, the unkeyed panes run it, every placeholder still starts, and
   a key in one hands over to the user's command: the pane is alive and
   `ps -o args= -p #{pane_pid}` reads `/bin/sh` (the placeholder's own
   pid, `exec`ed twice). A build that ran the placeholder through `default-command`'s
   value starts nothing here either.
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
   Revision 4 adds two, each with a real client attached:
   (h) **A key after restore has won** (item 2): restore held by
   `ROOST_TEST_PLACE_HOLD_AFTER_USED` right after it wins `bootstrap →
   bootstrap.used`; one key into the bootstrap pane; then, still held:
   `shells.log` has **no** line for that pane, the file is still
   `bootstrap.used`, and the screen shows `roost restore is placing this
   pane`. Release: the session is placed into, exit 0, and `shells.log`
   gains a line for that pane only when restore's own respawn starts a
   shell there (the saved first pane is a shell) — never one before it.
   Revision 3's placeholder found no `bootstrap.launching` and started a
   shell at the key, which restore then killed, so the "no line while
   held" assertion is red against it.
   (i) **A pane placement made, used during placement** (item 3): a shape
   of two sessions, the second with a two-pane window, one pane keyed;
   restore held by `ROOST_TEST_PLACE_HOLD` after the second session's
   window is built. The client selects that window; one key into the
   **unkeyed** pane, then `sleep 60` and Enter in the shell it hands over;
   one key into the **keyed** pane. Release: the unkeyed pane's file is
   `place.<n>.taken`, its `pane_pid` and the `sleep`'s pid are the same as
   before the release and both alive; the keyed pane is **not** given its
   placeholder, its pending file is `%N.taken`, the report names it with
   `roost revive %N`, and the stub log holds no launch for it; every other
   pane is placed as saved, exit 0. Revision 3 created that window's panes
   as login shells and respawned every pane unconditionally, so the
   `sleep` dies; red against it. The held bootstrap of (f) protected only
   the one pane revision 3 already guarded, so it could not catch this.
   Revision 5 adds one (C note): (j) **won, then changed**: restore held
   by `ROOST_TEST_PLACE_HOLD_AFTER_USED` after it wins `place.<n> →
   place.<n>.used` for an unkeyed pane; a person's `respawn-pane -k -t
   %N 'sleep 60'`; release: the file is `place.<n>.taken` (the
   person-owned row, T2), the `sleep` alive and its pane untouched, exit
   0. A build that leaves the file `place.<n>.used` puts the pane in no
   row; the file name is the assertion.
3. **Directories.** A pane whose `cwd` was removed: a shell at `$HOME`, the
   stderr line, not resumed, exit 13 when it had a key.
4. **Resume.** The stub `claude` is run with `--resume <id>` in the saved
   directory, 2 s apart (two agents, timestamps in the stub's file ≥ 2 s
   apart); `--no-resume` runs it zero times; `--recent 0` with an old
   transcript mtime runs it zero times; `--only SESSION` restores one
   session. **`--recent` holds at the next attach** (revision 10, C B2):
   after the `--recent 0` restore, the excluded pane is a shell (its
   `$HOME/shells.log` line) with no file under `pending/<boot>/`; attach
   a real client so the `client-attached` worker runs, wait two `--pace`
   intervals: the stub log is still empty and the pane is still that
   shell. Revision 9 wrote the plain pending file, and the attach
   launched it, so this is red against it. **Directory rule** (rewritten in revision 2, item 6): the stub
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
   two saved panes with one id: the first launched, the second left a
   **failed, waiting** placeholder (`%N.failed duplicate of %M`) showing
   the note, exit 13. **Stale:** a pane saved with `stale_session_id` is
   never launched and is named in the report. **Store miss:** a key with no
   file in the stub store is not launched, exit 13, the pane left a
   **failed, waiting** placeholder (`%N.failed store miss`), not a shell
   (§4.7; revision 10 corrects the wording, which revision 4's rule had
   already changed, C 3).
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
   Revision 4 cases (item 1), each red against revision 3, whose `revive`
   skipped step 7's shell checks for any pane with a pending file:
   **A taken pane in use**: a placed placeholder with key K; one key (its
   file becomes `%P.taken`, a shell); `sleep 60` and Enter in that shell;
   `roost revive %P` → exit 1, the `sleep`'s pid still alive, the file
   `%P.taken` again, no claim left in `claims/<boot>/`, nothing in the
   stub log. **The same pane idle** (the `sleep` killed, the shell at its
   prompt): `roost revive %P` → exit 0, the same `%P`, the stub run with
   `--resume K`. **`--force`** with the `sleep` running: launched. **The
   start command does not decide**: before each `revive` above, assert
   that `#{pane_start_command}` of the taken pane still equals the
   placeholder line — so a build that told the two apart by it would
   revive the busy pane; that is the measured fact (§2.10) the case rests
   on.
   Revision 5 cases (C B1, F N2): **A revive of a taken shell,
   interrupted** — the taken pane above with `sleep 60 &` and Enter (a
   job, the shell at its prompt); `roost revive %P` held by
   `ROOST_TEST_REVIVE_HOLD` right after T17 and its conversation claim
   (the file `%P.launching` with `origin taken`); `kill -9` the revive;
   attach a real client so the worker runs: the file is `%P.taken` again,
   the claim gone, the `sleep`'s pid and the shell's `pane_pid` the same
   and alive, and nothing in the stub log. Revision 4's T8b renamed the
   file to `%P` and the worker's waiting-row check (the placeholder line,
   `pane_dead` 0) passed the shell and replaced it, so this is red against
   it. **No origin line**: the same pane with its file planted as
   `%P.launching` without an `origin` line and a claim naming a dead pid:
   after the attach the file is `%P.failed interrupted`, the `sleep`
   alive, nothing launched, and `restore --resume --retry` launches
   nothing either. Revision 10 case (C B1): **an inherited origin** — a
   waiting pane `%P` whose key is missing from the stub store; attach, so
   the worker claims it, appends `origin waiting`, fails the store check
   (T7) and leaves `%P.failed store miss`: assert the file has **no**
   `origin` line. A key in the placeholder (T15): `%P.taken`, again with
   no `origin` line; then `sleep 60 &` and Enter. Put the key in the
   store and `roost revive %P` under a new hold,
   `ROOST_TEST_REVIVE_HOLD_BEFORE_ORIGIN=FILE` (`revive` waits right after
   its rename to `%P.launching`, **before** it appends its own `origin`
   line); `kill -9` the revive; attach a real client: the file is
   `%P.failed interrupted`, the `sleep`'s pid and the shell's `pane_pid`
   the same and alive, and nothing in the stub log. Revision 9 kept the
   worker's `origin waiting` through T7 and T15, so T8b read it, put the
   file back to `%P`, and the worker's waiting-row check passed the shell
   and replaced it; this is red against it. **`--new-window` from a pending file**: `roost revive
   --new-window %P` on a waiting placeholder exits 13 with `revive it in
   place`, the file still `%P`, no new window, nothing in the stub log; a
   build without the refusal leaves `%P.launching` saying "resuming now"
   for ever.
7. **Addressing.** After a restore, `roost send was:%OLD "x"` reaches the new
   pane and prints the stderr line; `read was:%OLD` reads the **old** boot's
   record; a bare `%OLD` that names a live pane delivers to **that** pane and
   prints the courtesy note; a bare `%N` that names nothing gives today's
   exit 2 with no redirect; a `was:%N` not in the map gives exit 2; two
   restores from two shapes with the same old `%N` make `was:%N` exit 2
   naming both `was:%N@BOOT` forms, and either form delivers; a map file
   from another boot is ignored; `close was:%OLD` closes the new pane.
8. **Save on change.** `spawn`, `split`, `rename-window`, `kill-pane`,
   `move-pane` of a window's last pane, `break-pane`, `move-window`,
   `link-window`, `select-layout`, `identify` and `revive` each produce a
   new `shape` (body or `gen`); 50 `roost state working` calls on a working pane produce none;
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
   exit; release: the **kill and close** files of `closed/<boot>/`, read
   with the death-note rule, name B and **only** B — no window, no
   session, no C — and a separate `died.<C>` note exists (revision 4,
   C N1: the directory holds that note by design, so the assertion is on
   what removes, not on every file); restore inside the window brings
   back C, its window and its session, and not B. Revision 2 appended C's window and session as
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
   as a person would and `kill-pane` it, release: the kill files of
   `closed/<B2>/` name exactly that pane's B2 id, nothing is written under
   `closed/<B1>/`, and no removal B1's shape implied is copied into B2
   (revision 4, C N2: the new pane's own number may itself be `%1`, which
   is no fault, so the oracle is by boot, not by number). Revision 2 compared B1's `shape` with
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
   **Hooks** (revision 4, item 6): load `tmux/roost.conf` into a
   throwaway server on the suite's own tmux (3.6 on the Mac, 3.4 on CI)
   with stderr captured: it is empty — no `invalid option` — and every
   `[98]` hook name the file sets is listed by `show-hooks -g`. Revision
   3's table names eight hooks that do not exist (§2.7, measured), so this
   is red against it. **What no hook covers**, asserted so a later change
   is seen: a `swap-pane`, a `swap-window`, and a `join-pane` from a
   window that keeps a pane each produce **no** new `shape` until the next
   other event, which then holds the new places; `respawn-pane -k` by
   hand produces none either, while `revive` does (its direct call).
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
   `status` reads it all back. **`on` with the server stopped** (revision
   9, C B2): plant a saved fleet of `main` and `work`, server down, and
   run `persist on` with the same recording stubs, which start `roost
   restore --at-login <inner>` on the load call as `RunAtLoad` does
   (test 12(h3)'s stubs; on Linux `on` runs it itself): `on` exits 0, the
   load call is logged, `shape` is still the planted save until the
   job's own `--trigger restore` save (no `persist-on` save in `history/`
   or in `shape`'s header between them), and the job places the planted
   `main` and `work`. A build that applies the publish wait here hangs or
   fails, and one that starts a fresh server to save first places only a
   fresh `main`: red.
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
    2 left it `.launching` for ever (and revision 4's "retry" below proves
    the retry **recovers** it, not only visits it). A stub that identifies with a
    **different** id: `%N.failed replaced`, the claim gone. **Interrupted
    after the claim**: kill the worker while `ROOST_TEST_RESUME_HOLD`
    holds it between steps 3 and 5: the next attach renames the `.launching` file back and launches
    it once.
    **A key after a failure is marked** (revision 4, item 2): a keyed pane
    whose key is not in the stub store; the worker held by
    `ROOST_TEST_RESUME_HOLD_AFTER_FAILED` right after T7 (`%N.failed store
    miss`). Within 6 s the placeholder's screen shows the reason, with no
    respawn (`pane_pid` unchanged, `shells.log` has no line for the pane).
    One key: the file is `%N.taken`, the screen shows the reason and then a
    shell, and `shells.log` gains one line; `sleep 60` and Enter in it.
    Release the worker and let the loop finish: the `sleep`'s pid is alive
    and the pane's `pane_pid` unchanged. Revision 3 respawned the pane into
    a reason shell after the rename, so the key either reached a shell that
    respawn then killed or a placeholder that started a shell on a lost
    rename; red against it. **The duplicate shows its reason** (F N4): the
    second pane of "Duplicate across workers" below shows `duplicate of
    %M` on screen, not the waiting line.
    **Retry recovers** (revision 4, item 3), each with the stub log's
    launch count read before and after: (A) **a repaired store miss** — a
    keyed pane whose key is missing from the stub store is `%N.failed
    store miss`, still the placeholder; add the key's file to the store;
    `restore --resume --retry` → the count is one higher, the pane runs the
    stub (its argv file names `--resume <id>`, `pane_dead` 0), and the file
    is gone once the stub identifies. (B) **a repaired launch** — the
    `claude-exit1` stub as the harness gives `%N.failed died` and a dead
    pane; put the good stub first on `PATH`; `--retry` → the count is one
    higher, `pane_dead` 0, the same `%N`. (C) **refused, a person's job** —
    the pane of (A) before the repair, taken with a key, `sleep 60` and
    Enter in its shell: `--retry` launches nothing, the `sleep` is alive,
    the file stays `%N.taken`. (D) **refused, a changed pane** — a person's
    `respawn-pane -k -t %N 'sleep 60'` before its turn gives `%N.failed
    pane changed`: `--retry` launches nothing and the `sleep` is alive.
    Revision 3 refused (A) and (B) as `pane changed`, since neither pane
    still ran the placeholder line; a build that skips the check for every
    failed file passes (A) and (B) and kills the `sleep` in (D). Each of
    (A)–(D) is red against one of them.
    **A crashed placeholder** (F N3): `kill -9` the placeholder of a
    waiting pane: the pane is dead with its last screen, not gone (that a
    signal counts as a failure for `remain-on-exit failed` is in the step 1
    probe; if it does not, the case uses a placeholder that exits 1); the
    file is `%N.failed died`; `--retry` with a good store launches it. Revision
    3 read the exit as a cancel and dropped the key.
    Revision 5 cases, each a composed path ending in a real recovery:
    **A resume that exits 0** (F B1): the `claude-exit0` stub as the
    harness: the pane is gone, the file is `%N.failed exited`, no claim
    left in `claims/<boot>/`, and `restore --list` names it; put the good
    stub first on `PATH`; `roost revive %N` opens a new window whose stub
    argv names `--resume <id>`, and the file is gone once it is launched.
    Revision 4's T19 removed the file and the claim on that `pane-exited`,
    leaving nothing to revive; red against it. **A dead pane retried while
    still broken** (C B2(a)): the `claude-exit1` stub gives `%N.failed
    died`; remove the key's file from the stub store; `--retry` → the
    launch count unchanged, the pane still dead, the file's first line
    still `died` with `store miss` on a later line; restore the key's file
    and put the good stub first; `--retry` again → the count one higher,
    `pane_dead` 0, the same `%N`. Revision 4 relabelled it **failed,
    waiting**, and the second retry's placeholder check then marked it
    `pane changed`; red against it. **A placeholder that crashes while
    failed** (C B2(b), F N4): a keyed pane whose key is missing gives
    `%N.failed store miss`, the placeholder showing it; `kill -9` the
    placeholder: the pane is dead, the file `%N.failed died`; restore the
    key's file; `--retry` → the count one higher, `pane_dead` 0. Revision
    4's T13a skipped **failed, waiting**, so the file kept `store miss`
    with a dead pane and the retry marked it `pane changed`; red against
    it. **The first line decides** (F N6): in each case above, `--retry`
    takes T16 where the first line is `died` and T14 where it is `store
    miss`, read from the stub log's argv and the file name after each
    step. **`close` on a waiting pane** (F N1): `roost close %N` on a
    placeholder whose file is `%N`: the pane is gone, `shells.log` has no
    line for it (a key would have started a shell), the file is removed,
    and `close` exits 0. A build that sent the exit keys made the pane a
    taken shell and `close` exited 1.
    **Taken, then an agent started in it** (F N7): a taken pane in which
    the stub is run by hand and identifies with a new id: the `%N.taken`
    file is removed.
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
12. **The restore offer** (§4.8, revisions 6 to 9). The terminal is real,
    not a flag: `roost` runs in a pane of a second throwaway server, as `env
    -u TMUX roost` (§8.1's opening, the way test 11 attaches a client), so
    stdin and stdout are a pty; keys go in with `send-keys`, and the screen
    is read with `capture-pane -p`. That pane clears §4.8's agent markers
    and every name the live smoke tests clear (revision 8, F N7: the full
    list of `tests/live/claude-decline-smoke.sh:101-103`, so a new Claude
    Code variable that later joins the table does not switch the offer off
    in CI): `env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u
    CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u
    CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_PID -u
    CLAUDE_EFFORT -u CLAUDE_CODE_MESSAGING_SOCKET -u
    CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED -u
    CODEX_THREAD_ID`, since the suite itself may run under Claude Code or
    codex, except where a case sets one. Every case plants an
    **earlier-boot shape** for the inner server and leaves the inner server
    not running. **The shared fixture**: two sessions, `main` and `work`
    (`main` is the default session, `bin/roost:158`, so a fresh server
    collides with it), four panes, two of them keyed to ids in the stub
    store, one of those with a gone directory. `persist on` is replaced by
    `ROOST_PERSIST_WRITE_ONLY=1` (test 9's seam) and, for the failure case,
    by a `launchctl`/`systemctl` stub that exits 1.
    (a) **Shown, and pinned**: the summary line names `2 sessions`, `4
    panes` and `1 of 2 agents would resume` and an age from
    `ROOST_TEST_NOW`; no inner server exists while it waits (`tmux -S
    <inner> ls` fails); `offer/` names the offer's pid; `offer/save` has
    the planted save's inode and `offer/stamp` its `STAMP-GEN`. From a
    second pane, `roost restore --dry-run --from STAMP-GEN` finds the
    planted save, which is `shape` and has no `history/` name (the
    `shape`-first lookup). `roost new x` with the server down asks too.
    (b) **Not shown without a person** (revision 7, item 2): `roost <
    /dev/null`, and `roost | cat`, each start the inner server with today's
    one session and print no summary line; `declined` is not written.
    **An unattended attach with a real pty and an agent marker**: in a
    pane of the same kind, `CLAUDECODE=1 roost`, and no key is ever sent:
    within 5 s the inner server exists with today's one session, the screen
    holds no summary line, and neither `declined` nor `offer/` exists. The
    same with `CODEX_THREAD_ID=x roost` (revision 8), with `ROOST_NO_OFFER=1
    roost`, and with `roost --no-offer`. **No
    answer**: `ROOST_TEST_OFFER_TIMEOUT=2 roost`, no key: the summary
    appears, then, 2 s later, the no-answer line; the inner server holds
    one fresh `main`; `declined` does not exist; `offer/` is gone. Kill the
    inner server by its `-S` path and re-plant the save as `shape` (`rm
    shape && ln SAVE shape`): `roost` asks again.
    (c) **Not shown when declined**: a `declined` linked to the planted
    save: no summary line. A **new** save of the same fleet (another `gen`)
    is asked about again.
    (d) **Not shown when the service is on**: the `persist` marker present
    and a `login/<os-boot>` marker absent: no prompt, and §4.6's
    self-restore places the fleet.
    (e) **Not shown when the fleet was closed on purpose**: `closed/<boot>/`
    names every planted pane: no prompt. A save holding one unkeyed shell:
    no prompt. `ROOST_SHAPE_DIR=`: no prompt. `roost spawn x sh` with the
    server down: no prompt. A save whose `host` is another machine: no
    prompt, and the `not offered here` line on stderr.
    (f) **`p` previews, then asks again**: after `p` the screen holds the
    exact text `roost restore --dry-run --from STAMP-GEN` prints for the
    same save (compared line for line with a separate run's stdout), the
    gone directory's pane reads `directory gone`, and below it the summary
    and keys line again; the inner server still does not exist. With
    `ROOST_SHUTDOWN_AT=` empty (no readable record, §3.6 rule 3), the
    screen holds no `restoring the newest save` line. **The bound ends at
    the first key** (revision 8, F N1): with `ROOST_TEST_OFFER_TIMEOUT=2`,
    `p` at once, then no key for 5 s: no no-answer line, no inner server,
    the keys line still on screen; then `n` writes `declined` as in (h).
    (g) **`l` then `r`**, with **its own fixture** (revision 7, item 3):
    two sessions, `main` and `work`, three panes, two of them keyed to
    resumable ids whose directories exist, one plain shell. `r` runs under
    `ROOST_TEST_PLACE_HOLD=FILE`. After `l` the keys line reads `on`; after
    `r`, while placement is held, `restoring/` exists and **neither** the
    unit file **nor** the `persist` marker exists; create FILE; then both
    exist and `restoring/` is gone. The inner server holds both saved
    sessions, and the stub log shows the two agents launched only **after**
    the attach, 2 s apart, each once (the `client-attached` hook, as test
    11). With the failing stub instead: `persist on failed` is on the
    screen and the client is attached anyway. With the **shared** fixture,
    `r` writes one pending file only: the gone-directory pane gets none
    and is never launched. **Which session** (F N2): a save whose sessions
    are `work` and `ops`, `active 1` on `ops`: after `r` from a bare
    `roost` the client is attached to `ops`, the screen names it, and no
    `main` exists. **`l` then silence** (revision 9, C B1): with
    `ROOST_TEST_OFFER_TIMEOUT=2`, `l` at once, then no key for 5 s: the
    offer still waits, the keys line reads `on`, no no-answer line is on
    the screen, no inner server exists, and no service is enabled (no
    `persist` marker, no unit file, no load call in the stub log). A build
    that times out after `l`, or that enables the service on it, is red.
    (h) **`n` records the decline**: `declined` is a hard link to the pin
    (the planted save's inode); the screen names `roost restore --from
    STAMP-GEN` and, since the save holds `main`, the rename hint; the inner
    server holds one fresh `main`. With `ROOST_SHAPE_KEEP=2` and five more
    saves (the ring has dropped the save), `restore --list` lists it last,
    marked `declined`. Then run the hint's two commands as printed: `main`
    and `work` are both restored from the save, and the fresh session is
    still there as `main-fresh`.
    (h2) **The automatic decline guard, its own case** (revision 7, item 4):
    after (h)'s `n`, stop the inner server by its `-S` path and make the
    declined save the one §3.6 picks: `rm shape && ln declined shape`;
    `restore --list` marks it both picked and `declined`. **Plant the
    `persist` marker file directly** (revision 8, F N5: through
    `ROOST_PERSIST_WRITE_ONLY=1`, `persist on` on Linux would run
    `--at-login` in the foreground with the server down, §4.4, running the
    guard before the test does and writing the `login/` marker), with no
    `login/<os-boot>` marker.
    `roost restore --at-login <inner>`: no saved session exists afterwards,
    and `login.log` names the decline. From the same state again (server
    stopped, `shape` re-planted, `login/` marker removed), `roost spawn x
    sh`, which goes through `ensure_session`'s self-restore: the server
    holds **the ordinary fresh `spawn x sh` shape** (revision 8, C B5): one
    `main` with its bootstrap window and the window `x`, compared by
    session names, window names and pane counts with a control run of
    `roost spawn x sh` on a third throwaway server with no shape directory;
    no `work` session exists, no pane carries a planted key or a
    `@roost-was`, and `login.log` names the decline.
    (h3) **`l` with a login job that really runs, and a planted lock**
    (revision 8, F B1 and C B4). The write-only seam is **off** for this
    case: `persist on` runs to its load step against stubs that record
    their argv. The macOS stub's `launchctl bootstrap gui/<uid> PLIST`
    and the Linux stub's `systemctl --user enable roost-persist-<inner>`
    — the real argv of §4.4, with no `--now` — each start `roost restore
    --at-login <inner>` at once in the background, as `RunAtLoad` does;
    the test asserts the recorded argv, and on Linux that it holds no
    `--now`. **The lock is planted** (revision 9, F B1), so no saver
    race decides the case: before sending the choice, the test starts a
    `sleep` it owns and writes the inner server's `lock/` with that
    `sleep`'s pid and start time, the format §3.5 step 1 reads. Every
    saver then meets a live owner, whichever starts first: the hook's
    `save --auto` leaves a want and exits, and a correct `persist on`
    waits. **`l` then `n`**: while the `sleep` lives, `declined` exists,
    the stub log shows no load call, no unit file exists, and `shape` is
    still the planted save. Kill the `sleep`; then `persist on` takes
    `lock/` over by the owner rule and saves the fresh fleet, the load
    call is logged, `login.log` shows the job ran and skipped every
    session, no pending file exists, and the inner server holds one fresh
    `main` only. **`l` then Enter**, with the same planted lock: the same
    assertions, except that `declined` does not exist; this is the case
    that has no decline to fall back on. Against a build whose `persist
    on` save is `--auto`, or that loads the unit without waiting for it,
    the unit loads while the `sleep` lives and `shape` is the crashed
    save, and the no-load assertion is red in both branches. Only the
    Enter branch can then place `work` with pending files: with `n`, the
    planted save is also `declined`, and §4.4's decline guard stops the
    job from placing it (revision 9, C note). Red every time, not only
    when the race is lost.
    (i) **Enter starts fresh without declining** (revision 7, F N1): the
    inner server holds one fresh `main`, the screen line says `not
    declined`, and `declined` does not exist; kill the inner server,
    re-plant the save as `shape`, and the next `roost` asks again.
    **Ctrl-C** exits 130, starts no server and writes no `declined`, and the
    next `roost` asks.
    (j) **Two terminals**: two panes run `roost` in the same second: one
    shows the summary, the other `waiting for the restore offer in another
    terminal`; `n` in the first; the second then attaches to the running
    server with no prompt, and `capture-pane` of the second never shows a
    summary line. Kill the first with `kill -9` mid-prompt instead: the
    second takes `offer/` over and asks.
    (k) **A script starts the server mid-prompt**: while (a) waits, `roost
    spawn x sh` from outside starts the inner server; the test waits,
    bounded at 10 s, until `shape`'s header names the inner server's live
    boot (the script's fresh save is published), and only then sends `r`:
    the report skips the saved `main` as existing (exit 12), restores
    `work` from the pin, and the client attaches.
    (k2) **The ring turns over while the offer waits**: plant
    `closed/<boot>/close.3` naming the planted fleet's plain-shell pane in `work`,
    `%3`, so the summary counts 3 panes. With `ROOST_SHAPE_KEEP=3`, while
    the offer waits, a script starts the inner server and makes six saves
    (`spawn` and `split`), so the pinned save has no `history/` name left,
    and a `roost restore --at-login <inner>` run meanwhile does its
    `closed/` cleanup. Then `p` (revision 8, C B3: the target state has
    changed, so the tree is not compared with the one captured before the
    churn): `offer/stamp` and `offer/save`'s inode are those of (a), the
    pin; the tree names the saved `main` as existing and skipped, the
    expected collision with the script's live `main`; its `work` block
    holds the same saved panes as before the churn, still without `%3`;
    and the tree is line for line what `roost restore --dry-run --from
    STAMP-GEN` prints from a second pane at the same moment, under the
    same `ROOST_TEST_NOW` (the same target state, and the lookup that
    finds `offer/save`, F N3). A preview of the fresh `shape` fails all
    of these. Then `n`: `declined` has the pin's inode, `closed/<boot>/`
    still exists, and `roost restore --from STAMP-GEN` restores `work`
    without `%3`.
    (k3) **`r` on a pin with a closed pane** (revision 8, C B2). Its own
    fixture: `main` holds `%1`, keyed to a resumable id; `work` holds
    `%2`, keyed to a resumable id, and `%3`, a plain shell; every
    directory exists. Plant `closed/<boot>/close.3` naming `%3`: the
    summary counts 2 sessions, 2 panes, `2 of 2 agents would resume`.
    Press `r`: the restored `work` has one pane, no pane carries
    `@roost-was %3`, `%2`'s pending file exists, and after the attach the
    stub log shows `%2`'s id launched once (and `%1`'s, 2 s apart). A
    build whose `r` restores `offer/save` as a plain `--from FILE`,
    skipping §3.6 step 4, places `%3`: red.

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
Revision 4 adds: skip the shell checks for a **taken** pane, or tell it
from a placeholder by its start command (6, a taken pane in use); start a
shell after a lost rename (2h, 11 a key after a failure is marked); respawn
a failed pane into a reason shell (11, the same case); create placed panes
as login shells, or respawn every placed pane without its rename (2i);
start the placeholder through `default-command`'s value, or test it with a
stub value (1, started at all); a retry check that only a placeholder can
pass (11 retry A, B), or no check at all for a failed file (11 retry D);
install a hook name that does not exist (8, hooks); read a placeholder's
exit as a cancel (11, a crashed placeholder). The one claim order (F N2)
has no red test of its own: the two orders differ only in a race between
a `revive` and the worker on one pane, which nothing here can plant on cue
without a seam inside `revive`; it is a rule of the table, and a review
item for the build.
Revision 6 adds: ask without testing stdin or stdout (12b); start the
server before the prompt (12a, the inner server exists); skip the
`declined` check, or match it by `boot` alone (12c, 12h); offer while the
`persist` marker is set (12d); offer before §3.6 step 4 (12e, closed on
purpose); a preview in its own format (12f); `r` that launches agents
itself instead of leaving them to the attach (12g, launched before the
attach); `persist on` before the placement (12g, the place hold); a
fatal `persist on` failure (12g); Enter as `r` (12i); record a decline on
Ctrl-C (12i); `restoring/` instead of `offer/`, or no lock (12j, and 12k:
the script waits on the person); `--from` that reads only `history/`
(12h, the ring dropped it).
Revision 7 adds: `r`, `p` or `n` reading `shape` instead of the pin (12k,
12k2); restore from the pin as a `--from FILE`, skipping step 4 (12k2's
manual restore, `%3` comes back; for the offer's own `r`, 12k3 since
revision 8, because 12k2 presses no `r`); no `closed/` kept for the pin's boot (12k2); a `--from
STAMP-GEN` lookup that skips `shape` (12a); offer on the terminal checks
alone (12b, the marker case); ignore `ROOST_NO_OFFER` or `--no-offer`
(12b); no timeout, or a timeout that declines (12b, no answer); Enter that
declines (12i); release `offer/` before the server runs (12j, the second
shows a summary); attach to a fresh `main` after `r` when the fleet has
none (12g, which session); a hint that restores nothing (12h); drop the
automatic decline guard (12h2, both the `--at-login` and the
`ensure_session` path); `persist on` before `declined` is written or
before `ensure_session` (12h3, the job places the fleet); `roost new`
that never asks (12a); a silent other-host skip (12e).
Revision 8 adds: `persist on`'s save as `--auto`, or a unit loaded
before that save is published (12h3, `l` + `n` and `l` + Enter with the
planted `lock/` of revision 9: only the Enter branch lets the job place
`work`; with `n`, the decline guard stops it); a Linux `persist on`
that sends `--now` (12h3, the recorded argv); the offer's `r` as a plain
`--from FILE` (12k3, `%3` comes back); a preview of the fresh `shape`
instead of the pin (12k2, against the same-moment dry run); a
`--from STAMP-GEN` lookup that misses `offer/save` (12k2, the second
pane's dry run finds nothing); a 60 s bound that restarts at every key
(12f, the no-answer line after `p`); `CODEX_THREAD_ID` ignored (12b). The
pin re-read after `ln -f` (F N2) has no red test of its own: planting a
rename between the read and the link needs a seam inside the offer; it
is a review item for the build, like revision 4's claim order.
Revision 10 adds: an `origin` line kept through T7 or T15 (test 6, "an
inherited origin": T8b hands the taken shell to the worker); a
`--recent` skip decided only in the foreground loop (test 4, the attach
after `--recent 0` launches the excluded agent).

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
8. **The restore offer after a real crash** (§4.8), `persist` off: on a
   throwaway `-L` server built for the check (never the live one), with
   its state redirected, `kill -9` the server's process (or ride item 1's
   real reboot with `persist` off), open a new terminal, type `ROOST_SOCKET=NAME
   roost`. Read the summary cold: can a person tell
   what they would get? Press `p`, read the tree, press `r`; the agents
   come up 2 s apart after the attach. Then once more with `n`, and
   check the line it prints brings the fleet back.

---

## 9. Decisions

Each with option A (the proposal) and B, and one line of why.

**Decided by the human on 2026-10-24: A, A, A, A.** Agents resume on first
attach, not at login (Q1); a manual restore resumes by default (Q2); the
saved shape lives under `XDG_STATE_HOME` (Q3); a Claude pane with no recorded
id gets a printed, never-run resume line (Q4). Revision 1 keeps all four;
Q1's A gained a mechanism, noted in its text. Revision 2 keeps all four;
each question says in its own text what revision 2 changed in practice.
Revision 3 keeps all four; Q1 and Q2 say what it changed. Revision 4
keeps all four; Q1 says what it changed. Revision 5 keeps all four.
Revision 6 keeps all four; Q1 says what the restore offer (§4.8) means
for it, and the opt-in reading below is now **decided by the human
(2026-10-25)**.

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
  and listed as `failed pane in use` (superseded below), and that agent comes back only when
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
- **What A means in practice after revision 4** (items 2, 3 and 4). Not
  *when* agents come back, which is still first attach, paced. Three things
  a person attaching early can now see: every pane placement makes shows
  `roost restore is placing this session - press any key for a shell` for
  the moment it takes, and a key there keeps that pane as the person's
  shell (its agent, if it had one, is then left out like any taken pane);
  an agent that cannot be resumed (a store miss, a missing harness) stays
  a waiting pane that **shows the reason** and gives a shell on a key,
  instead of becoming a shell by itself; and `roost restore --resume
  --retry` now really brings such an agent back once its cause is fixed.
  A key never produces a shell that roost then replaces.
- **What A means in practice after revision 6** (§4.8). With `persist`
  **off**, a bare `roost` after a crash now asks first. Its `r` is A
  exactly: placement now, then the attach that follows fires the paced
  resume, with the person at the terminal for any dialog. Nothing is
  restored without an `r`; Enter starts fresh. With `persist` on, nothing
  is asked and A works as before.

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

**Decided by the human on 2026-10-25: only the login service is opt-in;
saving is always on.** #191 said the login service is **off until a person
runs `roost persist on`**, and `roost doctor` says which it is. Revision 1
read that as the *service* only; the shape is saved on change from step 4
on regardless, because a hand `roost restore` after a crash needs it, it is
#51's own value (§3.4), and since revision 6 it is what the restore offer
(§4.8) reads. Revisions 1 to 5 flagged the reading for the human; both
second-round reviewers had found the spec itself unambiguous and placed the
ambiguity in #191's wording. The human confirmed the reading on 2026-10-25,
so it is no longer a flag. Revision 2's `doctor` wording (both halves,
`persist: saving on; login restore off`, §4.5) and its one switch for
saving (§3.4a) stay; §3.4a keeps its list of sections as the record of what
a reversal would touch.

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
- **Three moves are saved late** (revision 4, measured, §2.7, §3.4):
  `swap-pane`, `swap-window`, and a `join-pane` or `move-pane` that leaves
  its source window with panes, fire no hook roost uses, so each is saved
  with the next other event. A crash in between restores those panes or
  windows where they were before the move. `window-layout-changed` would
  see the pane moves but fires on every resize. Low: nothing is lost but
  a place, and any later event fixes it.
- **A key pressed in a waiting pane drops that agent from the automatic
  resume** (§4.7). By design, and said on screen and in Q1; `revive %N`
  brings it back. A person who presses keys in every pane before its turn
  gets shells everywhere. Low.
- **A "no" pressed in a hurry at the restore offer** (§4.8). Enter starts
  fresh by design but no longer declines (revision 7); only `n` does. The
  fleet is then reached by `roost restore --from STAMP-GEN`, which the
  offer prints and `doctor` repeats; a saved session whose name the fresh
  server took (usually `main`) is skipped by that restore, and the printed
  rename hint frees the name. Only the newest decline is kept. Low:
  nothing is deleted, and `declined` outlives the ring.
- **A harness with no known marker** (§4.8 check 2). Copilot, pi and
  opencode have no marker yet, and codex's `CODEX_THREAD_ID` was seen
  once; an unattended pty attach from one waits 60 s, then starts fresh
  and declines nothing. The attach it called already blocks for ever
  today, so this adds no hang (§4.8, revision 8 ruling). Build step 7's
  probe adds what it finds. Low.
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
| is auto saving gated by `persist on`? enable should save at once | one | **taken** as a clarification: saving is always on, the service is opt-in, `persist on` saves once (§3.4, §9); flagged for the human, and decided by the human on 2026-10-25 (revision 6) |
| the `read key value` loop loses whitespace; define duplicate keys and blank lines | one | **taken** (§3.2, test 5) |
| explicit window indices, `renumber-windows`, reuse the bootstrap window, restore active selections, test base-index holes | one | **taken** (§3.2, §4.3, test 1) |
| slash-to-hyphen keying of `-S` servers is not injective | one | **taken**: `path-<cksum>` (§3.1) |
| topology hooks (`move-pane`, `join-pane`, `break-pane`, swaps, `move-window`, `link-window`, `select-layout`, `resize-pane`) should save; a shell `cd` has no trigger | one | **taken** for the hooks (§3.4); the `cd` is accepted and said on the site (§3.4, §7). Revision 4: measured, most of those `after-*` hooks do not exist (§2.7); `window-linked` and `window-unlinked` cover the window moves, a direct call covers roost's respawns, and swaps and a join that leaves its window open are named gaps (§3.4, §10) |
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

---

## Appendix D. Triage of the fourth read's non-blocking notes

Revision 4. "F" is the Fable reviewer, "C" the codex reviewer; the numbers
are their own. F's B1, C's B1–B4 and F's N1 (promoted by the coordinator)
are the six items of §0.

| note | decision |
|---|---|
| F N1 — eight hooks do not exist on tmux 3.6 | **blocking**, item 6 (§2.7 measured, §3.4, §7, test 8 "hooks") |
| F N2 — the worker and `revive` take the two claims in opposite orders | **taken**: pane first, then the conversation, for every launcher (§4.6, §4.1 step 5a); no red test of its own, and §8.1's mutation paragraph says why |
| F N3 — a placeholder that exits by itself reads as a cancel | **taken**: placeholders run under `remain-on-exit failed`; a crash is arrow T13a, `%N.failed died`, and `--retry` reaches it (§4.7, test 11 "a crashed placeholder"); the taken shell clears the option so a person's own `exit` still closes the pane |
| F N4 — a `.failed duplicate` pane says "waiting" for ever | **taken**: no failed pane is respawned any more; the placeholder reads its file again every 5 s and shows the reason (§4.7 step 1, §4.6 step 3, test 11) |
| F N5 — the bootstrap placeholder starts before wiring | **taken**: the placeholder reads `default-command` when it hands over, so a key after `wiring apply` gets a wired shell (measured, §2.10; §4.3 Server) |
| F N6 — a key in the bootstrap skips the whole first session | **taken**: `restore --list` names it, and `kill-session` then `restore --only NAME` brings it back (§4.3 Sessions) |
| F N7 — a taken pane in which a person starts a fresh agent keeps its file | **taken**: arrow T18, the file is removed (§4.7, test 11) |
| F N8 — §3.6 calls `window-unlinked` and `session-closed` process deaths | **taken**: "process deaths, or a kill with no hook of its own" (§3.6) |
| C N1 — test 8(b2) asserts on every file under `closed/` | **taken**: the assertion is on the kill and close files after the death-note rule, plus a separate check that `died.<C>` exists (test 8(b2)) |
| C N2 — test 8(h) forbids overlapping numeric ids | **taken**: the oracle is by boot (test 8(h)) |
| the open question: what "off until `roost persist on`" covers | **unchanged**, still waiting on the human: saving on, login service opt-in (§3.4a, §9) |

## Appendix E. Triage of the fifth read's notes

Revision 5. "F" is the Fable reviewer, "C" the codex reviewer. F's B1 and
C's B1–B2 are the three fixes of §0; F N1, N2, N4 (with C B2(b)), N6 and
C's note are taken there. The coordinator ruled the rest not taken, as
round 5 was the last.

| note | decision |
|---|---|
| F N3 — **placing, claimed** with a dead owner has no exit by key | **not taken**: T2b already settles it in the next restore, and `ensure_session`'s self-restore runs one; a key-side takeover would be a new mechanism |
| F N5 — no `revive --new-window` arrow from **failed, changed**, **failed, replaced** or **taken** | **not taken**: a new arrow; the key is offered on the next boot (§4.6 overlay), and `revive` in place still works with step 7's checks |
| F N7 — the 5 s wake (`stty … time 50`, `dd`) is not measured | **not taken** as a text change: it is already named for the build step 1 probe (§4.7 step 1, §6), which must find a wake that returns before step 1 is done |

## Appendix F. Triage of the sixth read's notes

Revision 7. "F" is the Fable reviewer, "C" the codex reviewer. F's B1 and
B2 and C's B1–B4 are the four fixes of §0. Every note was taken.

| note | decision |
|---|---|
| F N1 — Enter writes `declined` | **taken**: Enter starts fresh without declining; only `n` declines (§4.8, test 12(i)) |
| F N2 — after `r` the attach lands in a fresh `main` | **taken**: a bare `roost` attaches to the pin's active session when the fleet has no `main`, with one line; a named session is created as today (§4.8 `r`, test 12(g)) |
| F N3 — when `offer/` is released | **taken**: last, just before the attach's `exec`, after the server runs (§4.8 lock, test 12(j)) |
| F N4 — `ln` onto a `mktemp` name fails | **taken**: `ln -f` to one fixed name under `offer/`, then `mv -f` (§4.8 `declined`) |
| F N5 — `roost new` attaches | **taken**: it asks, so the server it starts does not end the offer (§4.8 check 1, test 12(a)) |
| F N6 — a silent other-host skip | **taken**: one stderr line (§4.8 check 6, test 12(e)) |
| F N7 — "restoring the newest save" above the prompt | **taken**: not printed inside the offer (§3.6 rule 3, §4.8 check 6, test 12(f)) |
| F N8 — test 12(h)'s sequence | **taken** with item 4 (test 12(h2), `rm shape && ln declined shape`) |
| F N9 — `--list` and `declined` | **taken**: marked, and listed last when the ring dropped it (§3.6, §4.8, test 12(h)) |
| F N10 — checks 6 and 7 on different saves | **taken**: both act on the pin (§4.8) |
| C — the default session is `main` | **taken**: fixtures 12(h), 12(k) and the shared one plant `main` (§8.1); §4.8 and §10 say `main` |
| C — a second decline drops the first | **taken**: said plainly, with how to keep a copy (§4.8 `declined`, §10) |
| C — the hint restores nothing when every pane is in `main` | **taken**: the `n` line adds `rename-session -t main main-fresh`, then `--from`; the page shows it (§4.8 `n`, test 12(h)) |

## Appendix G. Triage of the seventh read's notes

Revision 8. "F" is the Fable reviewer, "C" the codex reviewer. F's B1 and
C's B2–B5 are the five fixes of §0; C's B1 is the coordinator's ruling
there. Every note was taken but one, which asked for no change.

| note | decision |
|---|---|
| F N1 — the 60 s bound restarts at every read | **taken**: it ends at the first key; later reads have no timeout (§4.8 check 2d, the prompt, No answer; test 12(f)) |
| F N2 — `ln -f` takes a path, so a save renamed over `shape` can be pinned instead | **taken**: re-read `offer/save`'s header after the link; on a `boot` or `gen` mismatch pick and pin again, once (§4.8 check 6); no red test, a review item (§8.1 mutation list) |
| F N3 — `--from STAMP-GEN` cannot see a pin that left the ring | **taken**: the lookup is `shape`, `history/`, `offer/save`, `declined`; `r`, `p` and a second terminal's dry run are one path (§3.6, §4.3, §4.8 `p` and `declined`; test 12(k2)) |
| F N4 — does `l` ride on No answer | **reversed in revision 9** (C B1): it cannot, because `l` is a key and ends the 60 s bound; after `l` the person presses `r`, `n` or Enter (§4.8 `l`, test 12(g)) |
| F N5 — 12(h2)'s write-only seam runs the guard early on Linux | **taken**: the `persist` marker file is planted directly (test 12(h2)) |
| F N6 — the `n` line is printed after the attach | **taken**: the `n`, Enter and No answer lines are printed before the `exec` (§4.8) |
| F N7 — the suite's `env -u` list | **taken** with the ruling: the smoke tests' full list, plus `CODEX_THREAD_ID` (§8.1 test 12); the nested-shell check joins build step 7's probe (§6) |
| C — Enter's retry claim depends on re-planting the save | **taken**: §4.8 Enter says plainly that not declining does not mean a later bare `roost` offers the old fleet again; the fresh fleet becomes newest |
| C — the pin's lifetime, close records, lookup order and decline boundary are explicit | **not taken**: an observation that asks for no change |
