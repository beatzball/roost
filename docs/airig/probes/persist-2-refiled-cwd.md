# Probe 2.2 — the first `cwd` of a re-filed Claude transcript

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 2.2.
Spec: §5.1 ("Whether a transcript that a resume elsewhere re-filed (§2.1)
still carries the old `cwd` on its first line is *not measured*").

## Method

The rig of Probe 2.1 (docs/airig/probes/persist-2-resume-flags.md): a
throwaway `-S` socket, redirected `HOME` / `XDG_*`, the fake Messages API,
`--setting-sources local --settings <file>` with this checkout's hooks, the
real settings hashed before and after. Three throwaway git repositories, A, B
and R (R with one commit, so a worktree can branch from it), all three
trusted in the throwaway `.claude.json`. `--model haiku --permission-mode
default`. Claude Code 2.1.316, macOS, tmux 3.6. Paths below are written with
`$D` for the throwaway directory.

**Part 1, re-filing.** Start in A, one prompt, `/exit`; `cd B`, `claude
--resume ID`, one prompt, `/exit`. Then list every transcript under
`projects/`, and read the first `"cwd":"…"` with the spec's own read,
`grep -m1 -o '"cwd":"[^"]*"' FILE | head -n 1`.

**Part 2, the worktree case.** Start in R. The fake API answers the prompt
with a `ToolSearch` call for `select:EnterWorktree` (in 2.1.316
`EnterWorktree` is a deferred tool, not in the first request's tool list),
then with `EnterWorktree {"name":"w1"}`; the settings allow `EnterWorktree`.
One more prompt inside the worktree. One file is written into the worktree
before `/exit`, because Claude removes a worktree with no changes at exit
without asking (seen in two earlier runs: "Worktree removed (no changes)");
with the change, it asks, and the probe picks "1. Keep worktree". Then
`claude --resume ID` from R, and again from `R/.claude/worktrees/w1`.

Part 1 ran seven times (each run of the probe script, while part 2 was being
made to work) with the same result each time. Part 2's final form ran once.

## Part 1 — result

```
-- transcripts after A:
./-private-tmp-amx-XXXX-A/<id>.jsonl
-- screen after resume from B:
❯ PROBE ONE
⏺ PROBE REPLY
-- transcripts after B:
./-private-tmp-amx-XXXX-A/<id>.jsonl
   first cwd = "cwd":"$D/A"; lines=47; cwd values:   17 "cwd":"$D/A"    6 "cwd":"$D/B"
```

- The resume from B **did not re-file** the conversation on 2.1.316: there is
  still one file, under A's project folder, and no folder for B. The lines
  the resumed session wrote carry `"cwd":"$D/B"`, appended to A's file.
- The first `cwd` is still **A**.

This differs from §2.1's measurement on 2.1.310 ("files the transcript under
the new directory's project folder"). Either way the first `cwd` line is A's.

**Table row:** "the first `cwd` is still A: §5.1's rule resumes in A, as
written." No code change.

## Part 2 — the worktree case — result

```
REQ toolsearch msgs=2
REQ enter-worktree msgs=5
REQ after-tool TOOL_RESULT:"Created worktree at “$D/R/.claude/worktrees/w1” on branch “worktree-w1”. The session is now working in the worktree. …"
   Exiting worktree session
   You have 1 uncommitted file. These will be lost if you remove the worktree.
   ❯ 1. Keep worktree    Stays at $D/R/.claude/worktrees/w1
     2. Remove worktree  All changes and commits will be lost.
Resume this session with:
claude --worktree "w1" --resume <id>
-- transcripts after worktree session:
./-private-tmp-amx-XXXX-R/<id>.jsonl
   first cwd = "cwd":"$D/R"; cwd values:   19 "cwd":"$D/R"   11 "cwd":"$D/R/.claude/worktrees/w1"
== resume <id> from $D/R
   RESULT: resumed, old prompt on screen
== resume <id> from $D/R/.claude/worktrees/w1
   RESULT: resumed, old prompt on screen
```

- **The transcript's folder:** R's project folder (where the session
  started), not a folder for the worktree. The session's lines after
  `EnterWorktree` carry the worktree's `cwd`, appended to the same file.
- **Its first `cwd`:** R.
- **Where `claude --resume ID` finds it:** from R, and from the worktree.
  Neither resume made a new project folder.
- Claude's own exit hint for a session that ended inside a worktree is
  `claude --worktree "w1" --resume <id>`. A plain `--resume` from R still
  found and opened the conversation. *Not measured:* which directory the
  session resumed from R then works in (R, or back in the worktree).

**Table row:** "worktree case, the resume works from the first `cwd`: §5.1
holds; Task 3.5 gains this fixture (a transcript … whose first `cwd` is R)
and asserts the stub runs in the first `cwd`." One correction for that
fixture, from this measurement: on 2.1.316 the transcript is filed under
**R's** folder, not the worktree's. A fixture under the worktree's folder
still tests §5.1's rule (it reads the first `cwd`, never the folder name),
so either placement is a fair fixture; this one is what was seen.

## Guard lines

```
GUARD: settings.json and codex config.toml unchanged
GUARD: no project key added to ~/.claude.json
```

The same two lines closed every run.
