# Probe 6.1 — Claude's project folder name for `_`, a space and a non-ASCII byte

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 6.1.
Spec: §2.1 ("What the folder rule does with `_`, a space or a non-ASCII
byte is *not measured*"), §2.8's "source if roost has no key" column, §5.6.

## Method

The rig of Probe 2.1 (docs/airig/probes/persist-2-resume-flags.md), copied
into a probe script outside the repository:

- a throwaway `-S` socket under `mktemp -d /tmp/amx.XXXX`, never `-L roost`;
- `HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME` at temp directories,
  `CLAUDE_CONFIG_DIR` unset, so the store is the throwaway
  `$HOME/.claude/projects/`; a fake API key and every probe directory
  trusted in the throwaway `.claude.json`;
- a local stand-in for the Messages API that answers every request with the
  text `ok`;
- `claude --model haiku --permission-mode default --setting-sources local`,
  no `--settings` file (no hooks are needed to read a folder name);
- the real `~/.claude/settings.json` hashed and its mtime read before and
  after, and the project keys of the real `~/.claude.json` listed before and
  after. Nothing was typed into Claude but one prompt and `/exit`.

Claude Code 2.1.319, macOS, tmux 3.6. One window per directory: start
Claude in it, one prompt (`probe hello`), wait for its transcript, `/exit`.
Then list the throwaway `projects/` folder names (read with `od -c` as well
as `ls`, so a byte cannot hide) and read each transcript's first `cwd` with
the spec's own read, `grep -m1 -o '"cwd":"[^"]*"' FILE | head -n 1`.

The directories, each a leaf under `$D/p/` (`$D` is the throwaway
directory, `/private/tmp/amx.XXXX`; the paths are built with `printf`
octal escapes so the bytes are exact):

| leaf | bytes |
|---|---|
| `a_b` | `a _ b` |
| `a b` | `a`, one space, `b` |
| `aé` | `a`, `\303\251` (one character, two UTF-8 bytes) |
| `a.b` | control: `.` is known to be written `-` (§2.1) |
| `ab` | control: no character to rewrite |
| `a🐔b` | `a`, `\360\237\220\224` (one character, four UTF-8 bytes, two UTF-16 code units), `b` |
| 230 × `x` | a folder name past 200 characters |

The last two were added after the first run (which held only the first
five) to settle the two cases a per-character rule leaves open. Run once
each: the first run with five directories, the second with all seven; the
five shared cases came out the same both times.

## Result (second run)

```
== projects/ folders ==
<D>-p-a-          (from aé)
<D>-p-a--b        (from a🐔b)
<D>-p-a-b         (from a_b, a b and a.b: one folder, three transcripts)
<D>-p-ab          (from ab)
<D>-p-xxxx…xxxx-ptxsab     (207 characters in all)
== first cwd of each transcript ==
<D>-p-a--b -> "cwd":"$D/p/a🐔b"
<D>-p-a-   -> "cwd":"$D/p/aé"
<D>-p-a-b  -> "cwd":"$D/p/a b"
<D>-p-a-b  -> "cwd":"$D/p/a_b"
<D>-p-a-b  -> "cwd":"$D/p/a.b"
<D>-p-ab   -> "cwd":"$D/p/ab"
<D>-p-xxxx…xxxx-ptxsab -> "cwd":"$D/p/xxxx…xxxx"
```

`<D>` is `$D` written by the same rule: `-private-tmp-amx-XXXX`.

1. **`_`, a space and `.` each become `-`.** `a_b`, `a b` and `a.b` share
   one folder, `…-p-a-b`. The rule is many to one, so a folder name is never
   enough to say which directory a transcript belongs to; each transcript's
   own first `cwd` still names its directory exactly.
2. **A non-ASCII character becomes `-` per UTF-16 code unit, not per byte.**
   `é` (two bytes, one code unit) became one `-`; the emoji (four bytes, two
   code units) became `--`.
3. **A folder name longer than 200 characters is cut.** The 230-character
   leaf gave a name of the first 200 characters of the rewritten path, then
   `-` and six characters (`ptxsab`) that are not in the path: a hash this
   probe did not decode.

So the measured rule: **every UTF-16 code unit of the path that is not an
ASCII letter or digit is written `-`; when that is longer than 200
characters, the first 200 are kept and `-` plus a short suffix follow.**

## Guard lines

```
GUARD: settings.json hash unchanged
GUARD: settings.json mtime unchanged
GUARD: no project key added to ~/.claude.json
```

The same three lines closed both runs. The real `~/.claude.json` mtime was
also the same before and after both runs (it is written by every live
Claude session on this machine, so that line alone would not prove much).

## The plan's table, applied

- **A definite rewrite per character → Task 6.3's narrowing uses it.** This
  is that row. Judgement call, recorded: the rule is many to one (`_`, a
  space and `.` share a folder), which is "lossy" if read backwards. It is
  definite read forwards, which is the only way the narrowing reads it: a
  directory gives one folder name, roost opens only that folder, and every
  transcript in it is kept or dropped by its own first `cwd`, byte for byte
  (§5.6). A shared folder costs a few extra files read, never a wrong line.
  The spec already knew `/` and `.` collide and still named the narrowing.
- Task 6.3 writes the rule as measured: each ASCII byte that is not a
  letter or digit is `-`, each non-ASCII character is `-` (`--` for a
  four-byte one), counted without the locale. A name past 200 characters
  is looked up as its first 200 characters, `-`, and any suffix (a glob,
  since the suffix is not derived). A folder the rule still misses (a
  future Claude that changes the rule, a re-filed transcript under another
  directory's folder) only shortens the printed list (§5.6).
