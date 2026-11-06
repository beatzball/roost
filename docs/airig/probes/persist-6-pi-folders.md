# Probe 6.2 — pi's session folder for a dotted path

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 6.2.
Spec: §2.8's pi row ("pi's folder encoding for a path with a `.` is *not
measured* (probe in build step 6)").

## Method

The rig of `tests/live/pi-smoke.sh`, cut down and copied into a probe script
outside the repository:

- a throwaway `-S` socket under `mktemp -d /tmp/amx.XXXX`;
- `PI_CODING_AGENT_DIR` at a temp directory holding one ollama provider
  (`models.json`, `settings.json`), `HOME` at another temp directory,
  `PI_OFFLINE=1` and `PI_SKIP_VERSION_CHECK=1`; no roost extension (none is
  needed to read a folder name);
- a local ollama model, `llama3.2:3b` (the smoke's default model is not
  pulled on this machine; the model's answer does not matter here, only that
  pi writes its session file).

pi 1.5.0, macOS, tmux 3.6. One window per directory: start pi in it, one
prompt (`say hi`), wait for a new `.jsonl` under `sessions/`. Then list the
`sessions/` folder names and read each file's first `cwd`. `$D` below is the
throwaway directory, `/private/tmp/amx.XXXX`.

Directories: `$D/repo/.claude/worktrees/w1` (the shape of every roost
worktree, the case the plan names), and two extra, `$D/p/a_b` and
`$D/p/a b`, read in the same run for comparison with Probe 6.1.

Run twice; the same folder names both times. The first run is not counted
for isolation (see **Guard** below); the second is the result.

## Result (second run)

```
== sessions/ folders ==
--private-tmp-amx.XXXX-p-a b--
--private-tmp-amx.XXXX-p-a_b--
--private-tmp-amx.XXXX-repo-.claude-worktrees-w1--
== files and their cwd ==
--…-p-a b--/2026-11-06T06-31-34-209Z_<id>.jsonl -> "cwd":"$D/p/a b"
--…-repo-.claude-worktrees-w1--/2026-11-06T06-31-10-080Z_<id>.jsonl -> "cwd":"$D/repo/.claude/worktrees/w1"
--…-p-a_b--/2026-11-06T06-31-22-139Z_<id>.jsonl -> "cwd":"$D/p/a_b"
== first line of one ==
{"type":"session","version":3,"id":"<id>","timestamp":"…","cwd":"$D/p/a b"}
```

**pi's rule: the path with each `/` written `-`, wrapped in `--` … `--`.**
A `.` is kept (`-.claude-worktrees-w1`), and so are `_` and a space. So pi's
folder name is one to one for these paths, unlike Claude's (Probe 6.1).
Each session file's first line is a `session` record naming its own `cwd`,
and the file name is `<ISO time>_<id>.jsonl`, which §2.8's exact-id glob
(`sessions/*/*_<id>.jsonl`) already matches.

## Guard

After the first run, the real `~/.pi/agent` **directory** had a newer mtime
than the run's start (00:29:40, during the third directory's start), with no
file inside it changed and no entry added: something created and removed an
entry there. Two control runs that read the real directory's mtime every
2 s through a whole pi start and prompt (one in a plain directory, one in
`a b`) saw no change, and the full probe run again with the mtime read
before and after saw none either:

```
== guard: files under real ~/.pi newer than start ==
(end)
real ~/.pi/agent mtime before=1793946580 after=1793946580
```

So the one change is not reproduced by pi under this rig and was most likely
another process on this machine; it is recorded here rather than explained.
The result above is from the clean second run.

## The plan's table, applied

- **Any rule → recorded.** This file is the record. pi has no listing in
  §5.6 (only Claude and codex do), so nothing else changes: pi's resume
  reads the recorded session file or the exact-id glob, and never a folder
  name.
