# Probe: what tmux 3.8 changed for save and restore (#51, #191)

CI's macOS runner moved to tmux 3.8 (Homebrew stable) after Part 1 was
built on 3.2a, 3.4 and 3.6, and six cases in `tests/test-shape.sh` and
`tests/test-shape-place.sh` went red there. Each change below was measured
on a throwaway `-S` server under `/tmp/amx.*`, with tmux 3.8 and, as the
control, tmux 3.6, on the same Mac. No 3.7 build was measured; where a
change is dated 3.7 or 3.7b, that is from CHANGES alone.

How the 3.8 binary was had without touching the installed tmux (the live
server runs on it): `brew fetch tmux` downloads the bottle without
installing it; unpacked under a scratch directory, its library paths are
Homebrew placeholders (`@@HOMEBREW_PREFIX@@/opt/...`), set with
`install_name_tool -change` to the installed libevent, ncurses and
utf8proc, and to a jemalloc bottle unpacked the same way; then
`codesign -f -s -`. Only that directory went first on PATH for the runs.

What tmux's own CHANGES says, and what was measured:

## 1. Layouts are JSON (3.8)

CHANGES 3.8: "Layout strings now use a JSON subset format which includes
floating panes. The old format is still accepted; control mode clients
receive old layouts unless they set the new-layouts flag."

| | tmux 3.6 | tmux 3.8 |
|---|---|---|
| `#{window_layout}`, two panes side by side | `cf3a,200x50,0,0{100x50,0,0,0,99x50,101,0,1}` | `{"V":2,"L":{"t":"h","w":200,"h":50,"x":0,"y":0,"c":[{"t":"p","w":100,"h":50,"x":0,"y":0,"a":true,"i":0,"I":"%0"},{"t":"p","w":99,"h":50,"x":101,"y":0,"i":1,"I":"%1"}]}}` |
| `select-layout` of the printed string onto other panes | applies; only ids and checksum differ | applies; only the `"I"` ids differ (the source says `"I"` is ignored on parse) |
| `select-layout` of a valid old-form string | applies | applies, and prints JSON after |
| `#{window_layout}` while zoomed | the unzoomed layout | the unzoomed layout (probe 1.1 holds) |
| the string holds a space | no | no (the writer's space-split window line still works) |

The old form is given only to a control-mode client (`format.c`,
`LAYOUT_CUSTOM_OLD_FORMAT`), so a plain `display`/`list-windows` reads JSON.
**Rule (spec §3.2 `layout`):** save the layout as printed; restore gives it
to `select-layout` unchanged and reads the root cell's size from either form
(the first `"w"` and `"h"`, which tmux writes first). Before the fix restore
found no size in a JSON layout, made the session 80x24, and the saved layout
could not apply: "every layout is the saved one" and the zoomed-window case
failed.

## 2. `.` and `:` stay in a session name (3.7b by CHANGES; measured on 3.8)

CHANGES 3.7b: "Only forbid #( in names, allow #[, empty names, : and ."

| `new-session -s` | tmux 3.6 | tmux 3.8 |
|---|---|---|
| `v3.69-x` | stored `v3_69-x` | stored `v3.69-x` |
| `a:b`, `p.q:r` | not made | stored as given |

Probe 1.4's rule (tmux stores `.` and `:` as `_`) holds up to 3.7a only.
Restore used it to decide that a saved `v3.69-x` is the session `v3_69-x`;
on 3.8 those are two sessions.

## 3. A window name is stored escaped, like a session name (3.7 by CHANGES; measured on 3.8)

CHANGES 3.7: "Sanitize pane titles and window and session names more
consistently and strictly, prevents C0 characters and other invisible
characters causing problems."

| `new-window -n` | tmux 3.6 prints | tmux 3.8 prints |
|---|---|---|
| `a\b` | `a\b` | `a\\b` |
| `a\\b` | `a\\b` | `a\\\\b` |
| `a\$b` | `a\$b` | `a\\$b` |
| `sp ace`, `a$b`, `h#sh`, `q"x`, `s'q`, `trail `, `g🐓l`, `a#[b`, empty | as given | as given |
| `a#(b` | `a` | `a` |

`new-session -s` already did this on 3.6 (R8.3: `a\b` prints `a\\b`). On 3.8
window names do too, so a window name passed to `new-window -n` as saved
(R8.3's rule for windows) grows a backslash at every save and restore: the
"cycle 1 / cycle 2" cases.

## 4. A control byte in a window name is refused (3.7 by CHANGES; measured on 3.8)

Same CHANGES entry.

| `rename-window` | tmux 3.6 | tmux 3.8 |
|---|---|---|
| a name holding ESC | stored as the text `\033` | refused: `invalid window name`, exit 1, the name unchanged |
| a name holding a tab | stored as the text `\t` | refused the same way |

Probe 1.3's "tmux itself stores the ESC as text on every build" holds up
to 3.6 only. Nothing in save or restore depends on it: the writer already
drops a name it cannot hold, and on 3.8 such a name cannot exist.
