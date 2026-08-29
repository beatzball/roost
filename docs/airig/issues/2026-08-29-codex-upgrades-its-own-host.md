# Codex upgraded the machine it was being tested on, from inside the test

**MITIGATED, not fixed.** Any roost test that drives codex must set
`check_for_update_on_startup = false` in the scratch `config.toml` it writes.
That is a setting roost asks codex to respect, not a boundary roost enforces.

Found 2026-08-29 while building a roost adapter for the OpenAI Codex CLI.
Recorded here rather than in that adapter's own files because it is a fact
about running a live harness test at all, not about one adapter — it stands
whether or not roost ever ships codex support. Recorded at all because it
changes what "isolated" means for a live harness test, and because the
mitigation is one line that a future reader would otherwise delete as noise.

## What happened

A codex TUI was being driven inside a throwaway tmux socket, with `CODEX_HOME`
and all three XDG homes pointed at scratch directories, to capture a permission
dialog. The pane came back with this on screen instead:

```
  0.150.1 -> 0.151.0
==> Unlinking Binary '/opt/homebrew/bin/codex'
==> Linking Binary 'codex' to '/opt/homebrew/bin/codex'
==> Purging files for version 0.150.1 of Cask codex
🍺  codex was successfully upgraded!
==> Upgraded 1 outdated package
codex 0.150.1 -> 0.151.0
🎉 Update ran successfully! Please restart Codex.
```

`codex --version` afterwards: `codex-cli 0.151.0`. `/opt/homebrew/Caskroom/codex/`
afterwards: `0.151.0` only — the version under test had been purged.

Nobody ran `brew`. Codex offers the update in its TUI, and a keystroke aimed at
its prompt took it.

## Why it is worth a file

**The isolation held everywhere it was designed to hold, and that was not
enough.** tmux was on its own socket. Config, hook trust and session
transcripts were under a scratch `CODEX_HOME`. No credential was reachable. The
live `-L roost` server was never contacted. None of that has any bearing on a
system package manager, and the tool under test reached one.

Three consequences, in the order they bite:

1. **A live test can change its own subject halfway through.** Every
   measurement in this repo that names `codex-cli 0.150.1` was taken against a
   binary that no longer exists on this machine. The findings were re-driven on
   0.151.0 and held (see below), but that was luck, not method.
2. **"Skips rather than fails when the harness is absent" is not the only
   environment risk in `tests/live/`.** The rule the adapter contract states is
   about a *missing* harness. This is a *present* harness with write access to
   the machine.
3. **It generalises past codex.** Any agent CLI with a self-update path can do
   this. The question to ask of the next harness is not only "what does it read"
   but "what can it write, and did we tell it not to".

## The mitigation, and its exact limit

`check_for_update_on_startup = false` is a real key — `codex exec
--strict-config` accepts it, which is the check that distinguishes a supported
setting from a silently ignored one. It belongs in the scratch `config.toml`
that any codex live test writes. Where a codex adapter ships alongside this
file, `tests/live/codex-smoke.sh` is the file carrying the line.

What that buys: codex does not check for an update at startup, so there is no
prompt for a stray keystroke to hit.

What it does not buy: it is codex's own switch, honoured by codex. It is not a
sandbox. A future version could update on a different trigger, and the test
would not know. Nothing in this repo prevents codex from writing to
`/opt/homebrew` — only asking it not to, and only on the one path measured.

The honest summary is that a live harness test is running third-party software
with the user's own privileges, and the only real containment for that is the
one this repo does not have.

## The other live findings from the same session

Kept here rather than in `docs/known-gaps.md` because they are measurements,
not shipped risks. All were taken on this machine, on the versions named.

**Adding a hook event does not break the trust already granted (0.151.0).** The
adapter contract's §4 says the registration is frozen. That is right about
*editing*, and it turns out to be wrong about *growing*. A four-event
`hooks.json` was trusted through the TUI; `SessionEnd` was then added and the
file's md5 changed; on the next run the previously trusted handlers still
fired and the new one did not. Trust is keyed per handler —
`<hooks.json path>:<snake_case event>:<group>:<handler>` — so a new key is
simply a new untrusted entry. So a codex registration should emit only the
events it uses rather than pre-registering all twelve against a future need —
paying a process spawn per tool call today to buy an option that costs nothing
to take later is the wrong trade.

**`SessionEnd` is two different events depending on how codex is run
(0.150.1 and 0.151.0).** In the TUI it fires when codex exits: a two-turn
session fired `Stop` twice and `SessionEnd` once, on `^C`. Under `codex exec`
it fires in the same process 22ms, 25ms and 40ms after `Stop`, in three
separate captures. The scout's costing table mapped it to `idle`, which is
correct for the first reading and erases the `done` badge in the second. An
adapter must map it to nothing, and must carry a fixture that fails if someone
later maps it — the two readings look identical from the TUI, which is the whole
trap.

**Codex has exactly twelve hook events, and none of them is an error** —
`PreToolUse PermissionRequest PostToolUse PreCompact PostCompact SessionStart
SessionEnd UserPromptSubmit SubagentStart SubagentStop Stop Interrupt`,
enumerated from the shipped binary's own enum and consistent with every live
capture. So the `error` state is unreachable for codex, and an adapter that
ships anyway reports a dead turn as `done` — which is worth a Live risk entry in
`docs/known-gaps.md` rather than a heuristic built on the one weak signal there
is (a live turn whose tool call failed showed five `PreToolUse` against four
`PostToolUse`).

**Codex's own built-in ollama provider fails the same way a hand-written one
does (0.150.1).** `codex exec --oss --local-provider ollama` sends the same
`type: "namespace"` and `type: "web_search"` tool definitions ollama rejects,
and reports the resulting HTTP 500 as *"We're currently experiencing high
demand"*. There is no supported path around it: a codex live test against ollama
needs a local proxy that drops every tool whose `type` is not `"function"`.

**The reply channel needs no new code (0.150.1 and 0.151.0).** Codex's `Stop`
payload carries `last_assistant_message`, spelled exactly as Claude Code spells
it, so `scripts/roost-agent-state --stop-hook` parses it unchanged. Verified on
a single word, on a two-turn session, and on a reply containing newlines,
escaped double quotes and a fenced code block.
