# Probe 1.3 — control bytes and odd characters in names and directories

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 1.3.
Date: 2026-10-27. Run count: once per build for the full table; the `$` rows
were run a second time, with a control, by a separate script (same result).

**Outcome: STOP.** An ordinary name — one holding `$` — does not round-trip
through `#{q:}` and an unescape on tmux 3.4 (the CI build, `ubuntu:24.04`).
That is the last row of the task's table. Part 1 stops here, before Task 1.4.

## Method

On each build, a throwaway server (`-S` socket in a temp directory, temp
`HOME`, `-f /dev/null`, a `keeper` session so the server outlives each case).
For each value: a session made as `rsN`, then `rename-session` to the value;
`rename-window` of its window to the value; `set -p @roost-name` on its pane
to the value; a directory `<temp>/dN<value>` made with `mkdir` and entered by
a pane's shell (`new-window -e PD=<dir> 'cd "$PD" && exec sleep 600'`). Each
is read four ways: `display -p '#{F}'`, `display -p '#{q:F}'`, `list-panes -F
'#{pane_id} #{F}'` and `list-panes -F '#{pane_id} #{q:F}'` (the line taken by
pane id). "Round-trips" means: the `list-panes` `#{q:F}` value, unescaped by
dropping one backslash before each character (`sed 's/\\\(.\)/\1/g'`), equals
the value given. Then a session is made again from the session name as
`list-sessions` reads it, and the two stored names compared (does a save and
restore cycle drift?). Every value is printed as hex (`od -An -tx1`): `09`
tab, `0a` newline, `1b` ESC, `01` SOH, `5c` backslash, `24` `$`.

The containers ran `apt-get install -y -qq tmux procps` and a probe script
copied in from a temp directory (no mount of the worktree), with
`LANG=C.UTF-8 LC_ALL=C.UTF-8`; the Mac run had `LANG=en_US.UTF-8`.

A first version of the script read with `display -p` only and with `sed -n l`
as the visible form; `sed -n l` prints a backslash differently on GNU and BSD,
so the table below comes from the hex run only.

## Result: control bytes

Values `a<byte>b`. "kept" = read back byte for byte; "text" = tmux stores the
byte as escape text (`\t`, `\n`, `\033`, `\001`); "cut" = the line-based
listing ends at the byte.

| field | tmux 3.2a | tmux 3.4 | tmux 3.6 (Mac) |
|---|---|---|---|
| session name (`new-session -s`, `rename-session`): tab, newline, ESC, SOH | accepted, stored as text (`615c7462` for tab) | same | same |
| window name (`rename-window`): all four | accepted, stored as text | same | same |
| `@roost-name`: tab | kept (`610962`) | kept | kept |
| `@roost-name`: newline | `display -p` kept; `list-panes` line **cut** (`61`) | same | same |
| `@roost-name`: ESC, SOH | kept (`611b62`, `610162`) | read as **text** (`615c30333362`, `615c30303162`) | kept |
| `pane_current_path`: tab | kept | kept | kept |
| `pane_current_path`: newline | `list-panes` line **cut** | same | same |
| `pane_current_path`: ESC, SOH | kept | read as **text** | kept |
| `#{q:}` of a control byte | left as is (no backslash added) | same | same |

## Result: ordinary names

Values `a b`, `a$b`, `a\b`, `a'b`, `a"b`, `a#b`, `ab ` (trailing space),
`a🐓b`.

| value | field | tmux 3.2a | tmux 3.4 | tmux 3.6 (Mac) |
|---|---|---|---|---|
| space, `'`, `"`, `#`, trailing space, glyph | every field | round-trips | round-trips | round-trips |
| `a$b` | session and window name | stored as `a\$b` (`615c2462`); `q:` + unescape gives `a\$b`, **not** the input | read as `a\\$b` (`615c5c2462`); **does not** round-trip | round-trips |
| `a$b` | `@roost-name`, `@roost-cwd`, `pane_current_path` | round-trips | read as `a\$b` (`615c2462`) by `show-options -v`, `display -p` and `list-panes -F` alike; **does not** round-trip | round-trips |
| `a\b` | session and window name | stored as `a\\b`; does not round-trip | same | same |
| `a\b` | `@roost-name`, `pane_current_path` | round-trips | round-trips | round-trips |
| re-create a session from its stored name | `a$b` | drifts: `a\$b` → `a\\\$b` | drifts: `a\\$b` → `a\\\\\\$b` | `a$b` stays |

The `$` control run (second script, same three builds) read `@roost-name`,
`@roost-cwd` and `pane_current_path` for `a$b`, `a\$b`, `a${HOME}b` and `ab`:

```
tmux 3.4
input=612462            show-options=615c2462            path==dir:NO  @roost-cwd==dir:NO
input=615c2462          show-options=615c5c2462          path==dir:NO  @roost-cwd==dir:NO
input=61247b484f4d457d62 show-options=615c247b484f4d457d62 path==dir:NO @roost-cwd==dir:NO
input=6162              show-options=6162                path==dir:yes @roost-cwd==dir:yes
tmux 3.2a and tmux 3.6: every value read back byte for byte, path==dir:yes, @roost-cwd==dir:yes
```

So on tmux 3.4 every `$` in a value tmux prints comes out with one backslash
put before it, and a backslash already there is not doubled. The read is the
same with and without `#{q:}` around it, and through `show-options -v`, so no
read form avoids it.

## What this means

- **The stop row applies.** A directory holding `$` is an ordinary path (the
  task names it, and one tool's own reader refused exactly that). On tmux 3.4
  `roost save` would write `cwd a\$b` for a pane in `a$b`; restore would place
  the shell in a directory that does not exist, and §3.2's `cwd` "always
  exists" no longer holds. The same holds for `session_cwd` (`@roost-cwd`)
  and `name` (`@roost-name`).
- The mapping on 3.4 looks invertible (delete one backslash before each `$`),
  but only on 3.4; 3.2a and 3.6 print `$` bare. A reader would have to know
  which build printed the file, or test the server first. That is a new rule
  the spec does not state, so it is the coordinator's call, not the builder's.
- **Not part of the stop, recorded for Task 1.9:**
  - session and window names: tmux itself turns a control byte into escape
    text on all three builds (row "tmux refuses or rewrites control bytes in a
    session name: nothing to do for sessions"); a window name the same.
  - a backslash in a session or window name is doubled by tmux on all three,
    and a `$` in one is stored as `\$` on 3.2a and 3.4, so a save and restore
    cycle adds backslashes each time. Not a control byte; outside the table.
  - `@roost-name` and `pane_current_path` keep a tab, ESC and SOH as raw bytes
    on 3.2a and 3.6 (rows "drop that `name` key" and "`cwd` as the home
    directory"). A **newline** cuts the `list-panes` line instead, so a writer
    that reads a line listing cannot see the byte to apply its rule.
  - roost already reads `@roost-cwd` today (outside this plan); on tmux 3.4 a
    directory holding `$` already reads wrong there.
