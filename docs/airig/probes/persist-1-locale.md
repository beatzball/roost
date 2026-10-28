# Probe (review round 1, B4) — the caller's locale and what tmux prints

Date: 2026-10-28. Run count: once per build. tmux 3.2a (`ubuntu:22.04`), 3.4
(`ubuntu:24.04`), 3.6 (this Mac); throwaway `-S` servers, temp `HOME`, `$TMUX`
unset.

## Method

One pane option set to `n<ESC>l<TAB>g🐓$`, then read with `list-panes -F
'x#{q:@v}'` and `display -p '#{@v}'` under `LC_ALL=C.UTF-8`, `LC_ALL=C`, and
with `LC_ALL`, `LANG` and `LC_CTYPE` unset — each with and without tmux's
`-u` flag. Output as hex.

## Result

| caller | no flag | `-u` |
|---|---|---|
| `LC_ALL=C.UTF-8` | real bytes (3.4: ESC as its usual `\033`, `$` as `\$`) | the same |
| `LC_ALL=C` | ESC, TAB and each byte of the glyph printed as `_` (`6e5f6c5f675f5f`) | **the same bytes as UTF-8** |
| no locale | as `LC_ALL=C` | **the same bytes as UTF-8** |

Identical on all three builds. A client started inside tmux (`$TMUX` set)
assumes UTF-8 whatever the locale, which is why every run from a roost pane
passed before the fix.

## Outcome

Every tmux read in `scripts/lib/roost-shape.sh`, `scripts/lib/roost-restore.sh`
and `scripts/roost-placeholder` passes `-u`. No locale is detected or set, so
no fallback is needed. The shape tests run in the Ubuntu containers under
`C.UTF-8`, `C` and an unset locale.
