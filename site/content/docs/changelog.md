---
title: Changelog
description: Every released version of roost, what it added, and what it fixed.
sidebar:
  order: 10
---

<!-- GENERATED FILE — do not edit.
     Source: CHANGELOG.md at the repository root.
     Regenerate: cd site && node scripts/sync-changelog.mjs -->

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- **`roost answer` takes the per-pane send lock.** A `send --force` and an
  `answer` aimed at one dialog could both land, because `answer` typed its key
  with nothing held (#181). It now takes the same lock `send` holds, just
  before its key, re-checks it at the key, and holds it through its confirm
  wait. When it cannot hold the lock — another command typing into the pane
  for the whole `@roost-send-lock-timeout` wait, a lock that cannot be named
  or made, or one taken from under the call — it exits 11 with nothing sent,
  and the call can simply be repeated.

## [0.9.0]

A human can now answer a blocked pane from anywhere. `roost answer --expect FP
%3 --approve`, `--option N` or `--deny` sends one measured key into the dialog
a pane is blocked on and waits to see it land, and `status --json` says which
dialog that is, so a board or a phone can tell "needs you" from "already
answered". And two `roost send`s at once no longer lose, merge or cross each
other's messages: every send has a buffer of its own and holds a per-pane lock
from before its first key to after the turn watch, so two workers reporting to
one coordinator in the same second both arrive, and two senders racing an idle
agent are never handed the same turn number.

Two things to know. **A second `send` to a pane that is being sent to waits**
— up to `@roost-send-lock-timeout` seconds, 60 by default — and then exits 1
with nothing typed, which is the "retry the same target" code. And **`roost
answer` does not take that lock yet**, so a `send --force` and an `answer`
aimed at one dialog can still both land; both are a person's verbs, and
docs/known-gaps.md lists it.

### Added

- **`roost answer`: answer a blocked pane's dialog from any shell (#142).**
  `roost answer --expect FP %3 --approve`, `--option N` or `--deny` sends one
  measured key into the dialog a pane is blocked on, once, and waits up to 3 s
  to see it land. It answers a Claude Code permission prompt for `Bash`,
  `Write` or `Edit` (`1` to approve, Escape to deny) and a Claude question
  with one choice and two to four options (the option's digit). Every other
  dialog, and every codex, opencode, copilot and pi dialog, is refused with
  exit 8 and nothing sent. `--expect` names the dialog you saw and is required
  to approve or pick an option, so the key cannot land on a newer dialog
  asking the same thing. It refuses a caller in an agent's pane (exit 9)
  unless `--force`; that is a guard against an accident, not a lock. Exit 10
  means the key was sent and not seen to land: do not answer again. roost
  still never answers a dialog on its own. `--json` prints one document.
- **`status --json` says which dialog a blocked pane shows.** Each pane gains
  `dialog`: a fingerprint that is new for each dialog, the harness, the kind
  (`permission`, `question` or `other`), how many options a question has, and
  `answered`, which says when `roost answer` answered it. A pane keeps its 🛑
  badge for as long as an approved tool runs, so `answered` is how a board
  tells "needs you" from "already answered". A codex dialog now records what
  it is about, as a Claude dialog does, except under codex 0.157.1's shared
  background process (#145).

### Fixed

- **Two `roost send`s at once no longer lose, merge or cross each other's
  messages.** Every send loaded its text into one shared tmux buffer and
  nothing kept two senders out of one input box, so two workers reporting to
  one coordinator in the same second could both exit 0 with one report never
  delivered, or one of them was told a healthy pane "may have died" (#175).
  Each send now has its own buffer and takes a per-pane lock, held from before
  the first key to after the turn watch, so two senders racing an idle agent
  can no longer both be handed the same turn number either. The lock is a
  directory beside the server's socket; a holder that was killed is taken
  over. A send that waits more than `@roost-send-lock-timeout` seconds
  (default 60) for another send to the same pane exits 1 with nothing
  submitted, so it is safe to retry.

## [0.8.0]

roost now updates itself. `roost upgrade` pulls the next release into the
checkout roost runs from, re-wires a running server, and runs the installer it
just fetched, so the `roost install` and `roost wiring on` that 0.7.0 asked for
on opencode 2 are one command now. `roost update` means the same thing. When a
plugin link points at a second copy of roost, `doctor` prints the exact command
and `install` relinks it from a plain checkout; from a git worktree both leave
the link alone and say so. `roost ssh` runs the remote roost in a login shell
and quotes every argument, so a remote that keeps roost under `~/.local/bin`
works, and a multi-word prompt arrives as typed. CI runs the test suite in
four shards per runner.

One thing to know. **`roost upgrade` refuses a dev tree, by design.** A
checkout on a branch, with local commits, or with changes to tracked files
gets the `curl ... | sh` line instead, and nothing is pulled into it.

### Added

- **`roost upgrade`: pull new roost code and wire every agent to it, in one
  command.** It runs `git pull --ff-only` in the checkout roost runs from,
  re-applies wiring on a running roost server, then runs the installer the pull
  just fetched, so a release that adds an adapter wires it in the same run. Its
  flags are the installer's, passed straight through: `--yes`, `--dry-run`,
  `--only`. The re-apply is what unsets roost's own `OPENCODE_CONFIG_DIR` on a
  server started before the upgrade when opencode is 2.x, so the opencode 2 case
  needs no `roost wiring on` afterwards; a server that is not running is wired
  when it next starts, and nothing is printed; a server started from another
  checkout, or one with wiring off, is skipped and a line says which.
  `--dry-run` skips the wiring step and prints a line saying so, makes the
  installer dry, and still pulls. Before anything touches the network it
  refuses, naming the rule, when the checkout is not a git checkout, is a
  worktree, is not on `main`, has no upstream, has local commits, or has
  uncommitted changes to tracked files (untracked files are fine). A failed pull
  wires nothing. A refusal prints the `curl ... | sh` line as the fallback,
  which still works on a machine with no roost at all. `roost update` now means
  `roost upgrade`; `roost install` stays the command that never fetches. The one
  thing to know: **a dev tree is refused, by design.** A checkout on a branch,
  or with commits that are not on its upstream, is somebody's working copy, and
  upgrade will not pull into it.

### Changed

- **A link to another copy of roost is roost's to fix.** A plugin link whose
  text names a roost adapter in a different checkout, and whose target still
  exists, used to read as `foreign` and be refused. It is now its own state,
  `other-checkout`. From a plain checkout `roost install` lists it as a relink
  (`relink PATH (was OLD)`, with `-> TARGET` on the next line), asks for it with
  the rest, does it under `--yes`, records the old target as the undo, and says
  in the summary what the link used to point at, because that is a second copy
  of roost. On opencode 2 the same goes for another copy's 1.x link. From a git
  worktree `install` refuses and says to run it from that copy or from the
  primary checkout, so a build pane running `roost install --yes` cannot take
  the live links from the checkout that owns them. If the old link cannot be
  removed, install fails rather than link into the other copy. `foreign` is
  unchanged: a stranger's file is still never touched, and codex's hook is still
  never rewritten. A Claude hook from another live copy of roost is treated the
  same way, replaced from a plain checkout and refused from a worktree; roost's
  two hook scripts are matched exactly, and the consent line says so before you
  answer. `roost validate` predicts the same: its offer says the link will be
  relinked from a plain checkout and left alone from a worktree.

- **CI runs the test suite in four shards per runner** (#169). A pull request
  waited 12 minutes for `test (macos-latest)` and 7 for Ubuntu, because the
  test files ran one after another. Each runner now runs four jobs,
  `test (<os>, 1/4)` to `test (<os>, 4/4)`, and the wait is the slowest of
  them. `tests/run.sh` does the split: `SHARD=k/n bash tests/run.sh` runs
  shard `k` of `n`, prints the same per-file lines and the same
  `N passed, M failed` summary for those files, and `--list` says which files
  a shard holds. Files are spread by measured seconds, longest first onto the
  lightest shard, so the 102-second file never shares a job with the
  65-second one. A plain `bash tests/run.sh` with no `SHARD` runs everything,
  exactly as before. A repository rule that named `test (macos-latest)` as a
  required check has to name the new jobs instead.

### Fixed

- **`roost doctor` prints the command when a plugin link is not this install.**
  The opencode 2, opencode 1, copilot and pi lines said "relink it to WANT" and
  gave no command. Each now ends in `rm "PATH" && ln -s "WANT" "PATH"`, and a
  link to another copy of roost is named as one, with `roost install` as the
  first thing to run. From a git worktree that line names the worktree and
  hands over no command, for the same reason `roost install` refuses there,
  and `roost validate`'s offer says the same. `doctor` prints an `rm` only for
  a symlink: for a file or directory it says to move it aside yourself.

- **`roost ssh` runs roost in the remote's login shell, and quotes every
  argument.** It was `ssh -t HOST roost ...`, which the remote ran in a plain
  non-login shell: no profile was read, so a `PATH` or `LANG` set there never
  arrived, `roost` was "command not found" on any machine that keeps it under
  `~/.local/bin` or a Homebrew prefix, `tmux` the same one step later, and a
  remote without a locale drew every badge as `_`. And ssh joins its arguments
  into one line, so a multi-word prompt had to be quoted twice. The remote
  line is now `"$SHELL" -lc 'roost ...'`, built one quoted argument at a time:
  `roost ssh devbox send %3 "review the diff"` arrives as those three words,
  and `user@host` destinations pass through as before. The docs gained a
  remote-agents checklist and three troubleshooting entries for the remaining
  ways a remote can be set up wrong.

## [0.7.0]

roost now works with opencode 2, and it gives a program enough to build on.
opencode 2 changed what a plugin is, so roost has a second adapter beside the
1.x one, and a pane running it badges, keeps its replies, and uses your own
configuration again rather than roost's empty one. For anything that watches
the fleet: every pane now carries who is in it — session id, directory,
harness, transcript — `roost events` streams every state change as one JSON
line, `roost send --from` records who sent each prompt, a Claude pane says how
many subagents it has out, and `roost close` ends one agent its own way and
closes only its pane. The `prefix a` switcher is live, with colour, a filter
and a preview of the agent's screen.

Three things to know. **If you run opencode 2: run `roost install` once**, and
`roost wiring on` once, and `unset OPENCODE_CONFIG_DIR` in any pane that was
already open; an old roost link makes opencode 2 say `1 plugin failed`, and
`roost doctor` names all three until they are done. **Every Claude install
needs `roost install` again** to wire the two subagent hooks, or the new
`subagents` field stays `null`. And `roost events` logs a closing pane only
after `prefix r` reloads the tmux config on a server that was already running.

### Added

- **`roost send --from LABEL`: who sent each prompt, kept beside the turn**
  (#56, the attribution half). Every send that names a turn now records who
  sent the prompt next to that turn's kept reply, as `replies/NNNNNN.sent_by`:
  the label you pass, else `pane:%N` for a send from a pane on this server,
  else `human`. `roost read --json` shows it as `sent_by`, and `roost send
  --json` says what it kept. A label is one word of at most 64 bytes that
  does not begin with a dash; anything else is refused with exit 2 before
  anything is pasted, and a bare `%N` is kept as `pane:%N` so one sender
  has one name. The text
  pasted into the agent is unchanged, and a send without the flag is
  byte-identical to before, so keep the `[from %N]` prefix until the envelope
  ships. A turn that ends with no reply (an API error, an interrupt) takes
  its label with it: the next turn to start drops it, so a prompt typed by
  hand after a failed send reads `sent_by: null`, never the sender's name.
  The first prompt into a fresh Claude pane keeps no label: it has no badge
  yet, so `send` does not number that turn. Nothing to do to get it.

- **`roost status --json` says how many subagents a Claude pane is running.**
  Each pane carries `subagents`: the number of subagents its agent has out
  right now, `0` once they have all finished, and `null` for a pane that has
  never run one — which is every pane of every other harness, since only
  Claude Code reports it. Two Claude hooks keep the count on the pane,
  `SubagentStart` and `SubagentStop`; `roost install` wires them, and `roost
  hooks` prints them. Neither changes a badge: a pane with helpers out reads
  whatever its own turn reads, as before. Three subagents started in one
  message are counted as three — the count is changed inside tmux, not read
  and written back by each hook. Run `roost install` again on a machine wired
  before this, or the field stays `null` there.

- **`roost close`: end one agent and close its pane** (#143). roost could open
  an agent and could not close one: `roost kill` takes a session or the whole
  server, so ending a single agent meant `tmux kill-pane` by hand, which kills
  the process mid-write and skips whatever the harness does on a clean exit.
  `roost close [--force] [--json] TGT [TIMEOUT_SEC]` types the harness's own
  exit command (`/exit` for Claude Code, opencode and copilot, `/quit` for
  codex and pi), waits up to 10 seconds for the agent to leave, then closes
  that pane and no other. It refuses a `working` or `blocked` agent unless you
  pass `--force`, which closes the pane without typing anything. It refuses a
  window with more than one pane as a target, and the last pane of a session
  (that is `roost kill SESSION`). If the harness opens a dialog while it
  exits, `close` stops and leaves the dialog for you; it never answers one. A
  pane where only a shell is left under an old badge is closed without typing
  anything. Kept replies stay, so `roost read %N` still works after a close.
  Exit 0 closed, 1 refused or timed out, 2 already gone. Nothing to do to get
  it.

- **`roost events`: every state change, as it happens** (#98). A program
  that wanted to know when an agent moved had to poll `roost status --json`.
  Now each change writes one JSON line to a log beside the kept replies, and
  `roost events` prints this server's lines, each with a cursor:
  `--since CURSOR` resumes after one, `--follow` keeps printing until the
  server stops, and `--pane %N` keeps one pane. A line names the server,
  pane, window, the agent's `session_id` when one is recorded, the states
  before and after, the turn (numbered as `roost send` numbers them) and a
  short reason: what a dialog asks for, or why a turn failed. It never
  holds prompt or reply text. A second dialog on a pane that is already
  blocked gets its own line; so does a 🛑 roost clears after you decline a
  dialog, and a pane closing — its program exiting, or a kill of its pane,
  window or session. A cursor the log has rotated away exits 3. Re-read
  `status --json` then. The log keeps at least `ROOST_EVENTS_KEEP` lines
  (default 5000). `ROOST_EVENTS=""` turns it off, and
  `roost forget --all` clears it. Reload roost's tmux config (`prefix r`)
  for closes to be logged on a server that was already running.

- **opencode 2 is supported** (#150). roost now has an adapter for opencode 2
  beside the one for 1.x. **If you run opencode 2: run `roost install` once.**
  It links the adapter at `~/.config/opencode/plugins/roost`, and removes
  roost's old 1.x link if you have one, because opencode 2 cannot load it and
  shows `1 plugin failed`. roost's automatic wiring does not reach opencode 2,
  so this is the one step. After it, an opencode 2 pane badges and `roost read`
  returns its replies as on 1.x, and the badge follows the chat on screen: a
  chat in a hidden tab shows nothing until you bring it to the front. Two
  things differ from 1.x. After you switch tabs, `roost read` has no reply for
  the pane until the chat now in front finishes a turn; it says so and shows
  the screen. And a reload of the adapter turns a finished chat's badge to
  idle, with no stored reply, until its next turn: a reload runs the adapter's
  setup again. Whether a roost update causes that reload in an opencode
  terminal that is already open was not measured.

- **Every pane says who is in it** (#141). `roost status --json` now carries
  `session_id`, `cwd`, `harness` and `transcript` on every pane, `null` where
  roost does not know, and the pane's record keeps the first three, so a
  program can show a conversation, open its transcript, or bring it back
  later. Claude Code is read at session start, codex at its first prompt, and
  the opencode, copilot and pi adapters call the new `roost identify`, which
  is a no-op outside roost. An opencode 2 pane is identified as the chat in
  front of its terminal, and follows a tab switch; it has no transcript. The
  key is `session_id`, not `session`, because `session` is already the tmux
  session name. Codex 0.157.1 runs every hook in one shared process that
  cannot name its pane, so a codex pane carries no identity rather than a
  wrong one. Where a value can be stale is in `docs/known-gaps.md`. Nothing
  to do to get it.

### Changed

- **The `prefix a` switcher is live.** It used to be a snapshot: a list taken
  when you opened it, with no colour. Now it reloads every two seconds while it
  is open, colours each agent's state, and shows the screen of the row under
  the cursor beside the list — so you can read what a blocked agent is asking
  before you jump to it. `Ctrl-f` steps a state filter (all, needs you,
  working, done) and `Ctrl-o` hides panes that are not agents. With more than
  one session, rows are grouped under a header per session. The popup is
  larger, 90% by 80%, to hold the preview. The live parts are tested on fzf 0.44
  and 0.74; an fzf too old for them keeps the plain list, and `roost doctor`
  now says which you have. Across a reload the cursor keeps its position rather than its row:
  following the row made fzf drop one `Enter` in ten, measured.

- **`roost doctor` checks opencode 2 on its own terms** (#150). opencode 2 has
  a new plugin format and does not load roost's 1.x adapter, and it reports
  that only in its own log, so the pane runs normally and never badges. doctor
  used to print `opencode plugin linked` on such a machine, or hand you an
  `ln -s` that could not help. It now checks the opencode 2 adapter's link —
  `opencode 2 plugin linked`, or the command that makes it — and names the two
  other things you can fix yourself: a pane that still has roost's
  `OPENCODE_CONFIG_DIR`, and the leftover 1.x plugin link that makes opencode 2
  show `1 plugin failed`. opencode 1.x is checked exactly as
  before. Finding the version starts opencode once with its directories pointed
  at a temp folder that is then removed: asked plainly, `opencode --version`
  creates its data directories, and a report should not be what first creates
  them.

### Fixed

- **opencode 2 in a roost pane uses your configuration again** (#154). roost
  wires opencode by setting `OPENCODE_CONFIG_DIR` in every pane. opencode 1.x
  reads that folder as well as your own; opencode 2 reads it *instead*, so
  inside roost it silently dropped your model, your providers and your
  permission rules, and ran on its defaults. roost now checks which opencode
  you have when the server starts and does not set the variable for 2.x.
  **If you run opencode 2: run `roost wiring on` once, and in any pane that was
  already open run `unset OPENCODE_CONFIG_DIR`** — a shell keeps what it was
  given, and `roost doctor` tells you when one still has it. opencode 1.x is
  wired exactly as before, with one exception: an `opencode` that is on your
  `PATH` but prints no version, or does not answer `--version` within five
  seconds, is no longer wired, because roost cannot tell it is not 2.x. It then
  badges through `roost install` instead. The five-second limit is there so that
  a hung `opencode` cannot stop a roost server from starting.

- **Docs pages are no longer blank at a trailing-slash URL** (#129). Every page
  under `/docs/` rendered as an empty dark screen if the address ended in a
  slash — `roosting.dev/docs/setup/` showed nothing, while
  `roosting.dev/docs/setup` was fine. The page answered 200, loaded every
  asset, logged no error and held the whole document in the DOM; it was simply
  never drawn, because the client router matches `/docs/:slug` exactly, so the
  page's own code was never loaded and the rule that hides an element until its
  code arrives never released it. The site now redirects the trailing-slash form
  to the clean one, and the client canonicalises the path as well, for hosts
  that do not. `scripts/verify-site.sh` asserts the redirect against the real
  container image on every CI run — a check that needs no browser, which
  matters, because nothing else CI runs could tell a rendered page from a blank
  one.
- **`roost wait-done` reports a dead agent as dead on tmux 3.8** (#165). With
  `remain-on-exit on`, a pane whose agent was killed mid-turn stays on screen
  as dead. On tmux 3.8, which Homebrew now installs, `wait-done` on that pane
  or its window exited 0 at once, as if the agent had finished, and a pane
  badged `error` exited 0 instead of 1. tmux 3.8 leaves a dead pane's process
  id empty, and that empty field pushed the badge out of what `wait-done`
  reads. It now exits 2 and says the pane is dead, and an `error` pane exits 1
  again, as on earlier tmux. Nothing to do but update.

## [0.6.1]

Two things that were wasting your machine's time. `roost forget --gone` could
hang for ever against a suspended tmux server while pinning a CPU core, because
the two-second bound it enforced gave up by asking politely — and a tmux client
spinning against a stopped server never hears that. And a codex pane printed a
warning naming your own `hooks.json` path on every single start, because roost
asked for a hook timeout codex was quietly clamping down anyway.

One thing to know, and only if you run codex: **run `roost install`** to pick up
the new `Interrupt` timeout, and `roost doctor` will keep saying so until you
do. On codex 0.154.0 that is the whole step. An older codex hashes a hook's
timeout, so it may ask "Hooks need review" once — answer "Trust all and
continue", for `Interrupt` alone. If it asks you nothing, the install worked.

### Fixed

- **`roost forget --gone` no longer hangs for ever on a suspended server**
  (#125). Checking whether a recorded server is still alive asks tmux and gives
  up after two seconds. It gave up by sending the polite signal — and a tmux
  client talking to a *suspended* server (`kill -STOP`, a debugger, a laptop
  resumed mid-connection) does not block; it spins, and while it spins it never
  acts on that signal. So the two-second bound was not a bound: the command
  never returned, and a CPU core stayed pinned at 100% until something else
  killed the client. Measured at 2 minutes 21 seconds of CPU and still running.
  The bound now escalates — polite signal, one second, then the one that cannot
  be ignored — so the worst case is three seconds. A server roost could not
  reach is still reported as "could not ask", never as gone, so no record is
  deleted on the strength of a timeout.

- **codex no longer warns about the `Interrupt` hook timeout on every start**
  (#123). Codex caps an Interrupt hook at 3 seconds. roost asked for 10, so
  codex clamped it and printed `warning: clamping Interrupt hook timeout to 3s
  in <your home>/.codex/hooks.json` every time it started — your home path on
  your screen, on a correct install. roost now asks for the 3 codex was giving
  it anyway.

  **Run `roost install` to pick it up.** On codex 0.154.0 that is the whole
  step: a `timeout` is not part of the hash codex stores when you trust a hook,
  so the new number lands under your existing trust entry and codex asks you
  nothing. An older codex does hash it — if "Hooks need review" appears, answer
  "Trust all and continue" once, for `Interrupt` alone, and until you do a codex
  dialog answered No or Esc leaves the pane 🛑. `roost doctor` reads the timeout
  out of your `hooks.json` and says so while the old number is still there. What
  the hook *does* is unchanged: three seconds before, three seconds now.

  (The first cut of this entry said the re-trust was certain. It was written
  from measurements on codex 0.150.1 and 0.151.0, where a timeout *was* hashed.
  Re-measured on 0.154.0 — with an appended command argument as the control, to
  prove the probe still sees a real change — it is not. `docs/known-gaps.md`
  carries the hashes.)

## [0.6.0]

roost now tells the truth faster and more often. A Claude Code permission
dialog is badged 🛑 as it opens — 72 ms, not six seconds — so `roost send` can
never paste into it, and a subagent's dialog, a failing tool after Yes, or a
background agent's tool result no longer moves or strands the badge.
`roost send` proves the target began a new turn and hands back its number, so
`wait-done --turn` and `read --turn` answer the prompt you sent, not the one
before it. A long reply from an adapter survives Linux by travelling on stdin.
And when you are attached over SSH, a blocked or errored agent reaches your own
terminal's notification, with nothing installed on the near side.

Two things to know: `send` into a pane whose `done`/`idle` badge was set by
hand, or whose agent has exited to a shell, now waits out a bound and exits 4
rather than 0; and existing installs need `roost install` again (or a server
restart for roost-owned wiring) to pick up the two new Claude hook entries —
`roost doctor` says so.

### Added

- **Notifications reach a human attached over SSH** (#46). When an agent is
  `blocked` or hits an `error`, roost now also writes the terminal's own
  notification escape sequence (OSC 9 by default; `777` and `99` are
  available) straight to each attached client's terminal, so a remote
  terminal that reads it raises a desktop banner with no app, no daemon and
  no account in the path. It is on by default only for a remote client (one
  whose session carries `SSH_CONNECTION` or `SSH_TTY`), decided per client
  from tmux's own record; `@roost-notify-osc on|off` overrides, and
  `@roost-notify-osc-codes` picks the sequences. Every write is bounded to
  one second and started in parallel, so a stalled link cannot hold up the
  agent's hook, and each sequence leads with a terminator so a terminal left
  mid-sequence by a killed write heals on the next one. Control-mode clients
  are skipped. A new docs page, Notifications, covers the backend chain and
  the no-vendor phone recipe (`@roost-notify-cmd` plus SSH over a private
  mesh network).
- **`roost send` proves the target began a new turn, and says which one**
  (#92). After the verified submit, `send` waits — bounded, ten seconds by
  default (`@roost-send-turn-timeout`, clamped to 120) — for the target to
  leave its finished badge, and prints one line, `%N TURN`: the pane the text
  reached and the turn it started. `roost wait-done --turn N` and
  `roost read --turn N` then tie the wait and the reply to that exact prompt,
  so a `wait-done` that begins before the target's hook has fired can no
  longer hand back the previous turn's reply as if it were the answer. `send`
  gained `--json` (`target`, `pane`, `turn`, `started`, `state`), and a new
  exit code **4**: the text was submitted but no turn began inside the bound,
  so do not send it again. A pane with no badge is not waited for and prints
  nothing; an errored turn prints no number, because it is never recorded.

### Changed

- `send` into a pane whose `done` or `idle` badge was set by hand, or whose
  agent has exited to a shell, now waits out the bound and exits 4 rather
  than 0.

### Fixed

- **A long reply from an adapter no longer dies on Linux** (#86). `roost reply`
  now also reads the reply from stdin — `roost reply -`, `roost reply --stdin`,
  or a pipe with no argument — and the opencode, pi and copilot adapters
  publish that way. Linux refuses a single command-line argument of 128 KiB or
  more, so a reply that long never reached roost there, while macOS carried it,
  which is why it was never seen on the development machine. The one-argument
  form is unchanged. A reply longer than a few KB, or one built from a file,
  belongs on stdin. The kept turn file holds every byte, trailing newlines
  included, on both paths.
- **A Claude Code permission dialog is badged 🛑 as it opens, not six seconds
  later** (#91). roost learned of a dialog from the `permission_prompt`
  Notification, which arrives 6.00 s after the dialog is drawn — and a dialog
  answered sooner was never badged at all. In that window `roost send` could
  not refuse, and pasted into the open dialog. Claude's `PermissionRequest`
  hook event fires about 10–16 ms after the dialog is drawn; roost now wires
  it (measured: `blocked` in 72 ms), keeps the Notification as the fallback
  for an older Claude, and records what the dialog is asking in
  `@roost-blocked-on` (`<tool>: <command or path>`, 120 characters) for a
  later display. The hook prints nothing: `PermissionRequest` is an event
  Claude acts on, and roost never answers for the human.
- **A subagent's dialog no longer flips the pane to ✅ done while it is still
  open.** A background agent's dialog ends the main turn with a `Stop` — 7 ms
  after, or 0.3 ms before, the dialog event; the order swaps between runs.
  Everything a dialog stamps is now one tmux command, and a `Stop` decides at
  the write, inside tmux, whether the pane is blocked; the first `Stop` under
  an open dialog is held back, a second always moves the pane.
- **A tool that fails after the human answers Yes no longer strands the pane
  at 🛑.** Claude sends `PostToolUseFailure`, not `PostToolUse`, for it; roost
  now wires that event too (eight Claude hook entries). `roost doctor` warns
  about a settings file or a roost-owned wiring file written before this
  change; `roost install` adds the missing entries.
- **A background agent's tool result no longer clears another agent's open
  dialog.** `PostToolUse` and `PostToolUseFailure` read `agent_id` while the
  pane is blocked, and a subagent's event leaves the badge alone.

## [0.5.0]

An agent's replies are now kept on disk, one file per turn. A long reply is no
longer cut short, an older turn can be read back, and a pane you closed still
has its last answer. Nothing you already do changes: the pane is still the truth,
and `roost read` on a pane with nothing kept prints exactly what it printed
before.

### Added

- **Every reply is kept whole** (#74, #42). Each turn is written to
  `${XDG_STATE_HOME:-~/.local/state}/roost/panes/`, beside the pane option roost
  already set. A reply longer than the 12 KB pane limit now reads back in full
  instead of being cut off without saying so.
- **`roost read --turn N`** reads one earlier turn. `N` counts from the first
  turn; `-N` counts back from the newest, so `-1` is the newest. The last **100**
  turns per pane are kept (`ROOST_RECORD_KEEP`).
- **A closed pane still answers.** `roost read %N` prints that pane's last reply,
  with a note saying the pane is gone. It works by pane id, on the same server
  boot that wrote it.
- **`roost forget`** deletes kept replies: `roost forget TGT` for one pane,
  `--gone` for every pane that is closed or whose server has stopped, `--all`
  for all of them. A closed pane's replies also delete themselves **30 days**
  after its last one (`ROOST_RECORD_DAYS`).
- **`--json` gained `turn` and `source`** on `roost read`, so a program can tell
  which turn it got and whether it came from the kept file or the pane. Existing
  fields are unchanged.

### Changed

- `roost read` prints a kept file **only while the pane still holds the reply
  that turn was written from**. If the pane has moved on, the pane wins and you
  get today's output. Nothing kept on disk can override a live pane.
- **A reply now prints as the agent wrote it, not as tmux stored it.** On tmux
  3.4 a `$` before a letter or `{` was stored as `\$`, so `$HOME` came back as
  `\$HOME`; from a shell with no UTF-8 locale, newlines, tabs and non-ASCII came
  back as `_`. Where a reply was kept, `read` now prints the real bytes. Where
  none was kept, it prints exactly what it printed before.
- Files roost writes are private to you: directories `0700`, files `0600`.

### How to turn it off

Set `ROOST_RECORD_DIR=""` and nothing is kept. Set it to a path to keep records
somewhere else. Everything lives under one directory you can delete in one
command.

### Known limits

Full list in `docs/known-gaps.md`. None of them reports a wrong reply as right —
where a limit bites, you get today's behaviour.

- A reply of **131,072 bytes or more** from opencode, pi or copilot is lost
  before roost runs, because Linux refuses an argument that long. The largest
  real reply measured was 24,675 bytes.
- Trailing newlines and NUL bytes are still dropped, as before.
- What ties a turn to its pane is a small record of what tmux stored, not the
  reply's own bytes — they cannot be compared exactly on every tmux version. So
  a turn file **edited by hand** is trusted and printed while the pane is
  unchanged. Only a changed length under a truncation marker is caught.
- Where nothing was kept — records off, or a write that failed — a reply that
  tmux rewrote still prints rewritten, exactly as before.
- A filesystem with no hard links keeps nothing.

## [0.4.1]

### Fixed

- **`roost wait-done` now spots an agent that died at a shell prompt** (#64).
  Before, if you started an agent by typing its name in a pane and it then died,
  the pane stayed alive, the badge stayed ⏳, and `wait-done` waited for its whole
  timeout. It now exits **2** and says the agent died, as it already did when a
  pane closes.

### Known limits

- **A Claude killed in the middle of a reply is not caught quickly.** Claude
  starts a `caffeinate` helper that can outlive it by up to about 5 minutes.
  Until that helper exits, `wait-done` behaves as before: it waits, then times
  out with exit 1. codex is caught in under a second.
- A wrapper program that outlives its agent is never caught.
- **Neither case ever reports a false "died".** The evidence for a quicker rule
  is in issue #72.

## [0.4.0]

Roost can now wire the agents in its own panes, instead of editing your files.
Nothing you already have stops working, and you can turn it off at any level.

### Added

- **Agents started inside a roost pane get roost's wiring** (#58), from files
  roost owns under `~/.config/roost/wiring/`. That includes an agent you type by
  hand, one from `roost spawn`, and one another agent starts. Nothing outside
  roost is affected.
  - **Claude Code** gets it through a small shim on the pane's PATH, which adds
    a hooks-only settings file.
  - **opencode** gets it through `OPENCODE_CONFIG_DIR`, which merges with your
    own config. Its plugin will not load twice.
  - **codex, pi and copilot are unchanged.** They still use `roost install`,
    because none of them can add config without moving your login too.
- **`roost wiring`** turns it on and off: `roost wiring on`, `roost wiring off`,
  `roost wiring off -t SESSION`, and `roost wiring remove`.
- **`roost doctor`** reports which wiring state you are in.

### How to back out

| scope | how |
|---|---|
| one run | `ROOST_NO_SHIM=1 claude` |
| one session | `roost wiring off -t SESSION` |
| the whole server | `roost wiring off`, or `set -g @roost-wiring-enabled off` |
| everything | `roost wiring remove`, then restart the server |

Your own tmux `default-command` also wins over roost's.

### Notes

- **Your existing `roost install` hooks can stay.** They name the same commands
  as the generated file, so each hook still runs once. `roost doctor` warns if
  they point at a different checkout.
- Panes opened before the upgrade keep their old shell until they are reopened.
- Known limits, including a `claude` alias to an absolute path, are in
  `docs/known-gaps.md`.

## [0.3.0]

One new feature: output that programs can read. No upgrade step is needed.

### Added

- **`--json` on `roost status`, `whoami`, `read`, `screen`, and `state`** (#41).
  Every document carries `"schema": 1`. Without `--json`, the output and every
  exit code are exactly as before.
  - `roost state STATE --json` sets the badge as before, then prints what
    actually landed, so a script can see a badge that did not stick.
  - Under `--json`, a command that fails prints nothing on stdout. The exit
    code and the error message are the same as without `--json`.
  - Under `--json`, a blank screen exits 0 with `"text": ""`. Without `--json`
    it still exits 1 for now (#69).

### Known limits

- `roost state STATE --json` reports `"recorded": false` when the badge is set
  for a whole window or globally rather than on the pane.
- `wait-done --json` is not included yet.
- Not yet measured with gawk, or with tmux 3.4.
- The full list is in `docs/known-gaps.md`.

## [0.2.2]

Two small fixes. No upgrade step is needed.

### Added

- **`roost doctor` now starts with the roost version** (#47). That is the
  report people paste into a bug. If the version cannot be read, it says so
  and says what failed.

### Fixed

- **`roost wait-done` no longer loops forever when its timeout is not a whole
  number** (#66). A value like `abc`, `1.5` or `-5` is now refused at once,
  with a message that names the bad value.

### Changed

- An **empty** timeout for `wait-done` is now refused. It used to mean "no
  limit". Leaving the timeout out still means no limit.
- A timeout with leading zeros is read as decimal: `010` is 10 seconds, not 8.

## [0.2.1]

Two more fixes to how roost reports an agent's state. One changes an exit code,
and one needs a step from you after you upgrade.

### Upgrade steps

- **Claude Code:** re-run `roost install`. It adds a `StopFailure` hook to
  Claude's settings. Until you do, a turn that fails on an API error still
  shows ⏳ working, and `roost doctor` says so. Claude hooks need no trust prompt.

### Changed

- **`roost wait-done` exits 2 when its target is gone or its agent died** (#54).
  Before, a pane or window that no longer existed made it exit **0**, so a dead
  helper looked finished. A script that treats any 0 as "finished" will now see
  2 for a dead helper. Exit 0 and 1 keep their meanings: done, and error or
  timeout. A pane seen ✅ done during the wait that then closes is still 0.

### Fixed

- **A Claude Code turn that fails on an API error now shows 💥 error, not ⏳
  working forever** (#55). This covers a rate limit, a server error, an unknown
  model and an unreachable API. `roost wait-done` exits 1 and names the kind of
  error, and `roost read` prints it.
- **`roost wait-done` no longer misses a one-shot agent's ✅ done.** It now
  checks every quarter second, because a one-shot pane can close about half a
  second after it finishes (#54).

### Known limits

- An agent killed **inside a shell** in its pane still makes `wait-done` time
  out with exit 1. The pane stays alive, so tmux cannot see the death. Tracked
  as a follow-up issue.
- Pressing Esc while Claude is still writing a reply leaves ⏳ working. Claude
  fires no hook for it.
- The full list is in `docs/known-gaps.md`.

## [0.2.0]

Two fixes to how roost reports an agent's state. Both change behaviour, and
one needs a step from you after you upgrade.

### Upgrade steps

- **codex:** codex asks "Hooks need review" once more, for a new `Interrupt`
  hook. Answer "Trust all and continue". Until you do, a declined permission
  dialog still leaves 🛑 blocked, and `roost doctor` says so.
- **Claude Code:** re-run `roost install`. It adds `--notification-hook` to the
  `Notification` hook. Without it, a Claude pane does not recover from a
  declined dialog.

### Fixed

- **A declined or dismissed permission dialog no longer leaves a pane 🛑
  blocked forever** (#62). Before, `roost send` refused the pane with exit 3,
  `roost wait-done` ran to its timeout, and `roost read` called a current reply
  stale.
  - codex: the new `Interrupt` hook moves the pane to 💤 idle.
  - Claude Code fires no hook at all when you answer No or press Esc. roost now
    reads Claude's own transcript when a command needs to know, and clears the
    badge only when the newest records are Claude's decline records for that
    same turn. It never reads the screen.
  - copilot 1.0.83 already recovers on Esc by itself.
- **A codex turn that ends with no reply now shows 💥 error, not ✅ done**
  (#53). `roost wait-done` exits 1 and names the reason, and `roost read`
  prints it.

### Added

- `roost doctor` names panes that have been 🛑 blocked for 10 minutes or more
  with no dialog on screen, as "may be stuck". It only reports. It never
  changes a badge.

### Known limits

- The codex 💥 error is inferred from a `Stop` with an empty reply. A real dead
  turn has not yet been captured live.
- Claude's transcript format is not a public contract. If a Claude upgrade
  changes its decline records, recovery quietly stops and the pane stays 🛑, as
  it did before this release. `tests/live/claude-decline-smoke.sh` catches that
  change when it is run.
- A Claude dialog answered in under about 6 seconds is never badged 🛑, because
  Claude's `Notification` hook arrives about 6 seconds after the dialog opens.
- `roost wait-done` exits 0 on an interrupted turn.
- The full list is in `docs/known-gaps.md`.

## [0.1.0]

The first numbered version. There is no earlier versioned history to
summarise: this entry marks where versioning starts, not a reconstruction of
everything that came before it.

Roost is a tmux wrapper for running and coordinating AI coding agents:

- Its own isolated tmux server (`-L roost`) with a badge per pane
  (💥 error · 🛑 blocked · ⏳ working · ✅ done · 💤 idle), driven by hooks for
  Claude Code and Codex and by an adapter for opencode, copilot and pi
- Session and window management (`up`, `session`, `new`, `spawn`, `split`,
  `whoami`, `status`, `kill`) and a status/switcher view that rolls up across
  every session on the server
- Agent-to-agent coordination: `send` (typed and verified, not just fired),
  `read`/`screen`, `reply`, and `wait-done` for blocking on another agent's
  state
- `ssh` to run roost against agents on a remote host, driven from here
- `install`/`update` to wire every installed agent (opencode, pi, copilot,
  claude, codex) to a checkout, `init` for first-time setup, and `settings`
  for live theme/glyph/notification changes
- `doctor` for preflight checks and `validate` for a fuller report a tester
  can hand back

### Extensions

- `roost ext` — install an extension from a GitHub repository, pinned to a full
  commit SHA, with `list`, `info`, `verify`, `update` and `remove`. An extension
  adds subcommands; a core command can never be shadowed by one.
- Extension contract 1: commands only. An extension declares in its manifest
  what authority it asks for, and roost withholds the socket and its own scripts
  unless the manifest asks for `fleet`. The declaration makes intent visible
  when you are asked to install; it does not confine what the extension does
  once it runs.
- Three ways to turn extensions off: `ROOST_NO_EXT` set to any non-empty value,
  `set -g @roost-ext-enabled off` in `roost.conf`, or `roost ext remove`.
- Docs: [Extensions](https://roosting.dev/docs/extensions) — what roost checks
  when you install one (that it is the exact commit you agreed to, and what the
  extension declared it wants to reach) and what it does not check (whether the
  code is honest, and what it does once you run it).
- Docs: [Writing an Extension](https://roosting.dev/docs/writing-an-extension) —
  the manifest schema, the environment a command is handed, the socket idiom,
  what declaring `fleet` costs your users, and how to install your own work from
  a bare repository on your disk before you publish it.
