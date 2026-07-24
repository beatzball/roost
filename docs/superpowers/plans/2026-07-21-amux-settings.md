# amux settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `amux settings` — an fzf TUI that reads current appearance settings and applies each change live to the running amux server — plus make config reload re-stamp existing window glyphs.

**Architecture:** A thin fzf glue script (`amux-settings`) calls tested primitives in a sourced lib (`scripts/lib/amux-config.sh`): a surgical per-key config writer, glyph/separator maps (extracted from `amux-init` so the two can't drift), reverse-lookup helpers, and a live-apply function. A standalone `amux-restamp` re-stamps every window's `@agent_glyph` from the current glyph set; both the settings apply-path and `bind r` call it.

**Tech Stack:** POSIX-ish bash, tmux (server socket `-L amux`), fzf.

## Global Constraints

Copied verbatim from prior amux work — every task must honor these:

- **tmux version floor: 3.1.** Do not introduce features newer than that.
- **bash 3.2 (macOS `/bin/bash`) has no `printf '\uXXXX'`.** Write all non-ASCII glyphs/wedges as UTF-8 byte escapes `\xHH` (e.g. wedge `\xee\x82\xb0`, nerd-blocked `\xef\x81\xb1`). A literal `\u...` in output is a bug CI (bash 5) will not catch.
- **PUA / emoji bytes must never be typed into a file via a normal edit** — they vanish. Produce them with `printf '\xHH...'`.
- **Never break a running agent.** All scripts: `set -u`, guard every tmux call (`... 2>/dev/null || true`), always `exit 0` on the hook/side paths.
- **Config writes are atomic:** write a temp file in the target directory, then `mv` over the target. Never truncate-in-place.
- **The amux server socket is `-L amux`** (name, not path). Scripts that talk to it expose a socket-override env for tests.
- **Option naming:** user-facing options are dash-form `@amux-*`; per-window runtime state is underscore-form `@agent_state` / `@agent_glyph`.
- Tests run under bash 5 **and** bash 3.2, on ubuntu + macos (CI). `tests/run.sh` auto-discovers `tests/test-*.sh`.

---

## File Structure

- Create `scripts/lib/amux-config.sh` — sourced (non-executable) helpers: `amux_cfg_path`, `amux_cfg_set`, `amux_glyphset`, `amux_sep`, `amux_cfg_tmux`, `amux_opt`, `amux_current_theme`, `amux_current_glyphset`, `amux_apply_live`. Depends on `amux-themes.sh` being sourced alongside.
- Create `scripts/amux-restamp` — executable; re-stamp `@agent_glyph` on every window.
- Create `scripts/amux-settings` — executable; fzf glue.
- Modify `scripts/amux-init` — source the lib, use `amux_glyphset` / `amux_sep` instead of inline maps (output byte-identical).
- Modify `bin/amux` — add `settings)` subcommand + usage lines.
- Modify `tmux/amux.conf` — `bind r` gains a restamp step; add `bind S` popup.
- Create `tests/test-restamp.sh`, `tests/test-settings.sh`.
- Modify `tests/test-reload.sh` — assert `bind r` wires the restamp.
- Modify `README.md` — document `amux settings` + `prefix S`.

---

### Task 1: Config lib — surgical writer + glyph/sep maps

**Files:**
- Create: `scripts/lib/amux-config.sh`
- Test: `tests/test-settings.sh`

**Interfaces:**
- Consumes: `amux-themes.sh` (`amux_theme`, `amux_theme_names`) sourced by the caller.
- Produces:
  - `amux_cfg_path` → echoes `$XDG_CONFIG_HOME/amux/amux.conf` (or `$HOME/.config/...`).
  - `amux_cfg_set KEY VALUE` → surgically set one `set -g KEY "VALUE"` line in that file (replace if present, append if not), atomic; creates file + one-line header if absent.
  - `amux_glyphset NAME` → echo 4 glyphs `blocked working done idle`, space-separated (`emoji`/`orbs`/`ascii`/`nerd`; unknown → emoji).
  - `amux_sep NAME` → `triangle` → the U+E0B0 wedge bytes; anything else → empty.

- [ ] **Step 1: Write the failing test** — `tests/test-settings.sh`

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/amux-themes.sh"
. "$HERE/scripts/lib/amux-config.sh"

cfgdir="$(mktemp -d /tmp/amx.XXXX)"; export XDG_CONFIG_HOME="$cfgdir"
trap 'rm -rf "$cfgdir"' EXIT
conf="$cfgdir/amux/amux.conf"

# writer creates the file and writes the key
amux_cfg_set @amux-color-bar-bg "#111111"
assert_contains "$(cat "$conf")" 'set -g @amux-color-bar-bg "#111111"' "cfg_set writes the key"

# replace-in-place, no dup, custom lines preserved
printf 'bind X kill-window\n' >> "$conf"
amux_cfg_set @amux-color-bar-bg "#222222"
assert_contains "$(cat "$conf")" 'set -g @amux-color-bar-bg "#222222"' "cfg_set replaces existing key"
assert_eq "$(grep -c '@amux-color-bar-bg' "$conf")" "1" "cfg_set does not duplicate the key"
assert_contains "$(cat "$conf")" 'bind X kill-window' "cfg_set preserves custom lines"

# append when key absent
amux_cfg_set @amux-notify-backend "tmux"
assert_contains "$(cat "$conf")" 'set -g @amux-notify-backend "tmux"' "cfg_set appends a missing key"

# glyphset parity + real bytes (bash 3.2: no \u)
gs="$(amux_glyphset nerd)"
case "$gs" in *'\u'*) assert_eq escape bytes "glyphset writes real bytes, not \\u" ;; *) assert_eq ok ok "glyphset writes real bytes, not \\u" ;; esac
assert_contains "$gs" "$(printf '\xef\x81\xb1')" "glyphset nerd contains U+F071 (blocked)"
assert_eq "$(amux_glyphset emoji)" "🛑 ⏳ ✅ 💤" "glyphset emoji matches the four state emoji"

# sep map
assert_eq "$(amux_sep none)" "" "sep none is empty"
assert_eq "$(amux_sep triangle)" "$(printf '\xee\x82\xb0')" "sep triangle is the U+E0B0 wedge"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL — `amux_cfg_set: command not found` (lib does not exist yet).

- [ ] **Step 3: Write minimal implementation** — `scripts/lib/amux-config.sh`

```bash
# amux-config.sh — sourced helpers shared by amux-init and amux-settings.
# No side effects on source. Requires amux-themes.sh sourced alongside.

amux_cfg_path() { printf '%s/amux/amux.conf' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# amux_glyphset NAME -> "blocked working done idle" (space-separated).
# \xHH bytes, not \uXXXX: bash 3.2's printf has no \u. Unknown -> emoji.
amux_glyphset() {
  case "$1" in
    orbs)  printf '%s %s %s %s' "🔴" "🟡" "🔵" "🟢" ;;
    ascii) printf '%s %s %s %s' "[!]" "[~]" "[+]" "[·]" ;;
    nerd)  printf '%s %s %s %s' \
             "$(printf '\xef\x81\xb1')" "$(printf '\xef\x89\x92')" \
             "$(printf '\xef\x80\x8c')" "$(printf '\xef\x86\x86')" ;;
    *)     printf '%s %s %s %s' "🛑" "⏳" "✅" "💤" ;;
  esac
}

# amux_sep NAME -> wedge bytes for "triangle", empty otherwise.
amux_sep() { case "$1" in triangle) printf '\xee\x82\xb0' ;; *) printf '' ;; esac; }

# amux_cfg_set KEY VALUE -> surgically set one `set -g KEY "VALUE"` line,
# preserving every other line. Atomic (temp in same dir + mv).
amux_cfg_set() {
  local key="$1" val="$2" target dir tmp line
  target="$(amux_cfg_path)"; dir="$(dirname "$target")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.amux.XXXXXX")" || return 1
  line="set -g $key \"$val\""
  if [ -f "$target" ] && grep -q "^set -g $key " "$target" 2>/dev/null; then
    AMUX_K="$key" AMUX_L="$line" awk '
      $0 ~ ("^set -g " ENVIRON["AMUX_K"] " ") { print ENVIRON["AMUX_L"]; next }
      { print }' "$target" > "$tmp"
  elif [ -f "$target" ]; then
    cat "$target" > "$tmp"; printf '%s\n' "$line" >> "$tmp"
  else
    printf '%s\n' "# Generated by amux. Re-run amux init/settings or edit by hand." > "$tmp"
    printf '%s\n' "$line" >> "$tmp"
  fi
  mv "$tmp" "$target"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-settings.sh` and `/bin/bash tests/test-settings.sh` (bash 3.2 on macOS)
Expected: PASS — all assertions (`local` is fine in bash 3.2).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/amux-config.sh tests/test-settings.sh
git commit -m "feat(settings): config lib — surgical writer + glyph/sep maps"
```

---

### Task 2: Refactor amux-init onto the shared maps

**Files:**
- Modify: `scripts/amux-init` (source lib; replace inline sep + glyph maps)
- Test: `tests/test-init.sh` (existing — must still pass, output byte-identical)

**Interfaces:**
- Consumes: `amux_glyphset`, `amux_sep` from Task 1.
- Produces: no new interface. Behavior/bytes unchanged.

- [ ] **Step 1: Run the existing init test to confirm the baseline passes**

Run: `bash tests/test-init.sh`
Expected: PASS (this is the guardrail we must keep green).

- [ ] **Step 2: Source the lib in amux-init**

In `scripts/amux-init`, after the existing `. "$HERE/amux-themes.sh"` line, add:

```bash
. "$HERE/lib/amux-config.sh"
```

- [ ] **Step 3: Replace the inline separator map**

Replace:

```bash
pl="$(ask 'Does this look like a triangle?  (y/N)')"   # caller shows the wedge
case "$pl" in y|Y) sep="$(printf '\xee\x82\xb0')" ;; *) sep="" ;; esac
```

with:

```bash
pl="$(ask 'Does this look like a triangle?  (y/N)')"   # caller shows the wedge
case "$pl" in y|Y) sep="$(amux_sep triangle)" ;; *) sep="$(amux_sep none)" ;; esac
```

- [ ] **Step 4: Replace the inline glyph-set map**

Replace:

```bash
gset="$(ask 'Glyph set? emoji/orbs/ascii/nerd [emoji]')"; gset="${gset:-emoji}"
case "$gset" in
  orbs)  gb="🔴" gw="🟡" gd="🔵" gi="🟢" ;;
  ascii) gb="[!]" gw="[~]" gd="[+]" gi="[·]" ;;
  # \xHH (not \uXXXX): bash 3.2's printf (macOS /bin/bash) has no \u support
  # and would write the literal escape text into the config.
  nerd)  gb="$(printf '\xef\x81\xb1')" gw="$(printf '\xef\x89\x92')" gd="$(printf '\xef\x80\x8c')" gi="$(printf '\xef\x86\x86')" ;;
  *)     gb="🛑" gw="⏳" gd="✅" gi="💤" ;;
esac
```

with (note `set -f` disables globbing so the ascii `[!]`/`[+]`/`[~]` tokens are not treated as filename patterns):

```bash
gset="$(ask 'Glyph set? emoji/orbs/ascii/nerd [emoji]')"; gset="${gset:-emoji}"
# set -f: the ascii glyphs ([!] [~] [+]) are glob patterns; disable pathname
# expansion around the word-split so they stay literal.
set -f; set -- $(amux_glyphset "$gset"); set +f
gb="$1" gw="$2" gd="$3" gi="$4"
```

- [ ] **Step 5: Run the init test (both bash versions) to verify parity**

Run: `bash tests/test-init.sh` and `/bin/bash tests/test-init.sh`
Expected: PASS — same glyph bytes, same sep bytes, light/dark defaults unchanged.

- [ ] **Step 6: Commit**

```bash
git add scripts/amux-init
git commit -m "refactor(init): use shared amux_glyphset/amux_sep maps"
```

---

### Task 3: amux-restamp + reload wiring

**Files:**
- Create: `scripts/amux-restamp`
- Modify: `tmux/amux.conf` (`bind r` restamp step; add `bind S`)
- Create: `tests/test-restamp.sh`
- Modify: `tests/test-reload.sh` (assert restamp wired into `bind r`)

**Interfaces:**
- Produces: `scripts/amux-restamp` — reads `@agent_state` per window, sets `@agent_glyph` from `@amux-glyph-<state>` (fallback idle glyph). Socket override: `AMUX_RESTAMP_SOCK` (default `-L amux`).

- [ ] **Step 1: Write the failing test** — `tests/test-restamp.sh`

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
RESTAMP="$HERE/scripts/amux-restamp"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_RESTAMP_SOCK="$sock"

T set-option -g @amux-glyph-blocked "B"
T set-option -g @amux-glyph-working "W"
T set-option -g @amux-glyph-done    "D"
T set-option -g @amux-glyph-idle    "I"

w1="$(T display-message -p '#{window_id}')"
T set-option -w -t "$w1" @agent_state working
T set-option -w -t "$w1" @agent_glyph "STALE"

T new-window
w2="$(T list-windows -F '#{window_id}' | tail -1)"
T set-option -w -t "$w2" @agent_state ""
T set-option -w -t "$w2" @agent_glyph "STALE2"

"$RESTAMP"

assert_eq "$(T show-options -wqv -t "$w1" @agent_glyph)" "W" "restamp maps working -> W"
assert_eq "$(T show-options -wqv -t "$w2" @agent_glyph)" "I" "restamp falls back to idle glyph for empty state"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-restamp.sh`
Expected: FAIL — `amux-restamp: No such file or directory`.

- [ ] **Step 3: Write minimal implementation** — `scripts/amux-restamp`

```bash
#!/usr/bin/env bash
# amux-restamp — re-stamp every window's @agent_glyph from the current
# @amux-glyph-<state> set, so a glyph/theme change is live without waiting for
# each agent's next state transition. Idempotent; never changes @agent_state.
set -u
tmx() { if [ -n "${AMUX_RESTAMP_SOCK:-}" ]; then tmux -S "$AMUX_RESTAMP_SOCK" "$@"; else tmux -L amux "$@"; fi; }

tmx has-session 2>/dev/null || exit 0
idle="$(tmx show-options -gqv @amux-glyph-idle 2>/dev/null || true)"
tmx list-windows -a -F '#{window_id}|#{@agent_state}' 2>/dev/null | \
while IFS='|' read -r win state; do
  [ -n "$state" ] || state=idle
  g="$(tmx show-options -gqv "@amux-glyph-$state" 2>/dev/null || true)"
  [ -n "$g" ] || g="$idle"
  [ -n "$g" ] || continue
  tmx set-option -w -t "$win" @agent_glyph "$g" 2>/dev/null || true
done
exit 0
```

Then make it executable:

```bash
chmod +x scripts/amux-restamp
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-restamp.sh` and `/bin/bash tests/test-restamp.sh`
Expected: PASS (both assertions).

- [ ] **Step 5: Wire restamp into `bind r` and add `bind S`** — `tmux/amux.conf`

Replace the existing `bind r` line:

```
bind r source-file -F "#{@amux-home}/tmux/amux.conf" \; source-file -qF "#{@amux-user-conf}" \; display "amux config reloaded"
```

with (adds a restamp run-shell; `$AMUX_HOME` is the proven single-quoted shell-env pattern used by `bind a`):

```
bind r source-file -F "#{@amux-home}/tmux/amux.conf" \; source-file -qF "#{@amux-user-conf}" \; run-shell '$AMUX_HOME/scripts/amux-restamp' \; display "amux config reloaded"
```

Then, next to the `bind a` popup near the end of the file, add:

```
# amux settings TUI (change theme/glyphs/separator/notifications live)
bind S display-popup -E -w 60% -h 50% '$AMUX_HOME/scripts/amux-settings'
```

- [ ] **Step 6: Extend the reload test** — append to `tests/test-reload.sh`

```bash
# prefix r also re-stamps existing window glyphs (glyph/theme change is live)
assert_contains "$(cat "$HERE/tmux/amux.conf")" "amux-restamp" "prefix r reload re-stamps glyphs"
```

- [ ] **Step 7: Run reload test**

Run: `bash tests/test-reload.sh`
Expected: PASS (existing assertion + the new restamp-wiring assertion).

- [ ] **Step 8: Commit**

```bash
git add scripts/amux-restamp tmux/amux.conf tests/test-restamp.sh tests/test-reload.sh
git commit -m "feat(settings): amux-restamp; bind r re-stamps glyphs; bind S popup"
```

---

### Task 4: Reverse-lookup + live-apply helpers

**Files:**
- Modify: `scripts/lib/amux-config.sh` (add `amux_cfg_tmux`, `amux_opt`, `amux_current_theme`, `amux_current_glyphset`, `amux_apply_live`)
- Modify: `tests/test-settings.sh` (append reverse-lookup + apply-live tests)

**Interfaces:**
- Consumes: `amux_theme`, `amux_theme_names`, `amux_glyphset`, `amux_cfg_path` (Task 1); `amux-restamp` (Task 3).
- Produces:
  - `amux_cfg_tmux ARGS…` → run tmux against `$AMUX_CONFIG_SOCK` if set, else `-L amux`.
  - `amux_opt KEY` → current value: from the running server if up, else parsed from the config file, else empty.
  - `amux_current_theme` → theme name matching the 6 current colors, else `custom`.
  - `amux_current_glyphset` → glyph-set name matching the 4 current glyphs, else `custom`.
  - `amux_apply_live HOME` → if server up: source base + user conf, run `amux-restamp`, `refresh-client -S`. No-op if no server.

- [ ] **Step 1: Write the failing tests** — append to `tests/test-settings.sh`

```bash
# reverse-lookup against a running server
amux_test_server; export AMUX_CONFIG_SOCK="$AMUX_TEST_SOCK"
tmux -S "$AMUX_TEST_SOCK" source-file "$HERE/tmux/amux.conf" >/dev/null 2>&1
set -f; set -- $(amux_theme tokyonight-storm); set +f
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-bar-bg    "$1"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-bar-fg    "$2"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-logo-bg   "$3"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-active-bg "$4"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-active-fg "$5"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-idle-fg   "$6"
assert_eq "$(amux_current_theme)" "tokyonight-storm" "current_theme reverse-lookup matches"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-bar-bg "#abcdef"
assert_eq "$(amux_current_theme)" "custom" "current_theme returns custom when off-tuple"

# apply_live re-stamps on a running server
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-home "$HERE"
export AMUX_RESTAMP_SOCK="$AMUX_TEST_SOCK"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-glyph-working "WW"
w="$(tmux -S "$AMUX_TEST_SOCK" display-message -p '#{window_id}')"
tmux -S "$AMUX_TEST_SOCK" set-option -w -t "$w" @agent_state working
tmux -S "$AMUX_TEST_SOCK" set-option -w -t "$w" @agent_glyph "OLD"
amux_apply_live "$HERE"
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -wqv -t "$w" @agent_glyph)" "WW" "apply_live re-stamps via amux-restamp"
tmux -S "$AMUX_TEST_SOCK" kill-server 2>/dev/null
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL — `amux_current_theme: command not found`.

- [ ] **Step 3: Add the helpers** — append to `scripts/lib/amux-config.sh`

```bash
# amux_cfg_tmux ARGS -> talk to the test socket if set, else the amux server.
amux_cfg_tmux() {
  if [ -n "${AMUX_CONFIG_SOCK:-}" ]; then tmux -S "$AMUX_CONFIG_SOCK" "$@"
  else tmux -L amux "$@"; fi
}

# amux_opt KEY -> current value: from the running server, else the config file.
amux_opt() {
  local key="$1" target line v
  if amux_cfg_tmux has-session 2>/dev/null; then
    amux_cfg_tmux show-options -gqv "$key" 2>/dev/null; return
  fi
  target="$(amux_cfg_path)"; [ -f "$target" ] || return 0
  line="$(grep "^set -g $key " "$target" 2>/dev/null | tail -1)"
  case "$line" in
    *\"*) v="${line#*\"}"; v="${v%\"}"; printf '%s' "$v" ;;
    *) : ;;
  esac
}

# amux_current_theme -> name matching the current 6 colours, else "custom".
amux_current_theme() {
  local cur t
  cur="$(amux_opt @amux-color-bar-bg) $(amux_opt @amux-color-bar-fg) $(amux_opt @amux-color-logo-bg) $(amux_opt @amux-color-active-bg) $(amux_opt @amux-color-active-fg) $(amux_opt @amux-color-idle-fg)"
  for t in $(amux_theme_names); do
    [ "$(amux_theme "$t")" = "$cur" ] && { printf '%s' "$t"; return; }
  done
  printf 'custom'
}

# amux_current_glyphset -> name matching the current 4 glyphs, else "custom".
amux_current_glyphset() {
  local cur g
  cur="$(amux_opt @amux-glyph-blocked) $(amux_opt @amux-glyph-working) $(amux_opt @amux-glyph-done) $(amux_opt @amux-glyph-idle)"
  for g in emoji orbs ascii nerd; do
    [ "$(amux_glyphset "$g")" = "$cur" ] && { printf '%s' "$g"; return; }
  done
  printf 'custom'
}

# amux_apply_live HOME -> reload the running server + re-stamp glyphs. No server -> no-op.
amux_apply_live() {
  local home="$1"
  amux_cfg_tmux has-session 2>/dev/null || return 0
  amux_cfg_tmux source-file -F "#{@amux-home}/tmux/amux.conf" 2>/dev/null || \
    amux_cfg_tmux source-file "$home/tmux/amux.conf" 2>/dev/null || true
  amux_cfg_tmux source-file -qF "#{@amux-user-conf}" 2>/dev/null || true
  "$home/scripts/amux-restamp" 2>/dev/null || true
  amux_cfg_tmux refresh-client -S 2>/dev/null || true
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-settings.sh` and `/bin/bash tests/test-settings.sh`
Expected: PASS — all Task 1 assertions plus the four new ones.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/amux-config.sh tests/test-settings.sh
git commit -m "feat(settings): reverse-lookup + live-apply helpers"
```

---

### Task 5: amux-settings TUI + wiring + docs

**Files:**
- Create: `scripts/amux-settings`
- Modify: `bin/amux` (`settings)` subcommand + usage header + usage-line)
- Modify: `tests/test-settings.sh` (append wiring + fzf-missing smoke tests)
- Modify: `README.md`

**Interfaces:**
- Consumes: all of `amux-config.sh` (Tasks 1, 4), `amux-themes.sh`, `amux-restamp` (Task 3). `AMUX_FZF` overrides the fzf binary (test seam; default `fzf`).

- [ ] **Step 1: Write the failing smoke tests** — append to `tests/test-settings.sh`

```bash
# fzf-missing: prints an install hint, exits 0 (no crash)
out="$(AMUX_FZF=definitely-not-fzf "$HERE/scripts/amux-settings" </dev/null 2>&1)"; rc=$?
assert_contains "$out" "install fzf" "amux-settings prints install hint when fzf is absent"
assert_eq "$rc" "0" "amux-settings exits 0 when fzf is absent"

# wiring: bin/amux dispatches 'settings'; amux.conf binds S to the TUI
assert_contains "$(cat "$HERE/bin/amux")" "amux-settings" "bin/amux dispatches settings"
assert_contains "$(cat "$HERE/tmux/amux.conf")" "bind S" "amux.conf binds prefix S to settings"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL — `amux-settings: No such file or directory`.

- [ ] **Step 3: Write the TUI** — `scripts/amux-settings`

```bash
#!/usr/bin/env bash
# amux settings — fzf TUI to change amux appearance live. Reads current values;
# each pick writes the config, reloads the running server, and re-stamps glyphs.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/amux-themes.sh"
. "$HERE/lib/amux-config.sh"

FZF="${AMUX_FZF:-fzf}"
if ! command -v "$FZF" >/dev/null 2>&1; then
  echo "install fzf to use amux settings" >&2; exit 0
fi

pick() { "$FZF" --reverse --no-info --prompt="$1 > "; }

apply_theme() {
  set -f; set -- $(amux_theme "$1"); set +f
  amux_cfg_set @amux-color-bar-bg    "$1"
  amux_cfg_set @amux-color-bar-fg    "$2"
  amux_cfg_set @amux-color-logo-bg   "$3"
  amux_cfg_set @amux-color-active-bg "$4"
  amux_cfg_set @amux-color-active-fg "$5"
  amux_cfg_set @amux-color-idle-fg   "$6"
}
apply_glyphs() {
  set -f; set -- $(amux_glyphset "$1"); set +f
  amux_cfg_set @amux-glyph-blocked "$1"
  amux_cfg_set @amux-glyph-working "$2"
  amux_cfg_set @amux-glyph-done    "$3"
  amux_cfg_set @amux-glyph-idle    "$4"
}

while :; do
  ct="$(amux_current_theme)"; cg="$(amux_current_glyphset)"
  cs="$(amux_opt @amux-sep-left)"; [ -n "$cs" ] && cs=triangle || cs=none
  cn="$(amux_opt @amux-notify-backend)"; [ "$cn" = tmux ] && cn=off || cn=on
  sel="$(printf 'theme\t%s\nglyphs\t%s\nseparator\t%s\nnotifications\t%s\nquit\t\n' \
        "$ct" "$cg" "$cs" "$cn" \
        | "$FZF" --reverse --no-info --with-nth=1,2 --delimiter='\t' --prompt='settings > ' | cut -f1)"
  case "$sel" in
    theme)   v="$(amux_theme_names | pick theme)"; [ -n "$v" ] && apply_theme "$v" ;;
    glyphs)  v="$(printf 'emoji\norbs\nascii\nnerd\n' | pick glyphs)"; [ -n "$v" ] && apply_glyphs "$v" ;;
    separator) v="$(printf 'triangle\nnone\n' | pick separator)"
               [ -n "$v" ] && { s="$(amux_sep "$v")"; amux_cfg_set @amux-sep-left "$s"; amux_cfg_set @amux-sep-right "$s"; } ;;
    notifications) v="$(printf 'on\noff\n' | pick notifications)"
               [ -n "$v" ] && { [ "$v" = off ] && nb=tmux || nb=auto; amux_cfg_set @amux-notify-backend "$nb"; } ;;
    quit|"") break ;;
  esac
  case "$sel" in ""|quit) : ;; *) amux_apply_live "$ROOT" ;; esac
done
```

Then make it executable:

```bash
chmod +x scripts/amux-settings
```

- [ ] **Step 4: Wire `bin/amux`**

In `bin/amux`, add the subcommand after the `init)` block:

```bash
  settings)
    exec "$AMUX_HOME/scripts/amux-settings"
    ;;
```

In the usage comment header (the `#   amux init ...` block near the top), add a line under it:

```
#   amux settings           change theme/glyphs/separator/notifications, live
```

And add `settings` to the final usage string in the `*)` case:

```bash
  *) echo "usage: amux [up|session NAME|new NAME [SESSION]|ssh HOST|send TGT TEXT|read TGT [N]|wait-done TGT [T]|hooks|doctor|init|settings|status|kill [SESSION]]" >&2; exit 2 ;;
```

- [ ] **Step 5: Run the smoke tests (both bash versions)**

Run: `bash tests/test-settings.sh` and `/bin/bash tests/test-settings.sh`
Expected: PASS — fzf-missing hint + exit 0, and both wiring assertions.

- [ ] **Step 6: Document in README**

In `README.md`, under the Setup/Usage section (near where `amux init` is described), add:

```markdown
### Changing settings later

`amux settings` opens an fzf menu to change the **theme**, **glyph set**,
**separator**, and **notifications** — one at a time. Each pick applies live to
the running server (no restart) and is saved to `~/.config/amux/amux.conf`.
Inside amux, press **`prefix S`** (`Ctrl-s S`) to open it right where you are.

Unlike `amux init` (which regenerates the whole config), `amux settings` edits
just the one line it changes, leaving any hand-added config untouched.
```

Also add `settings` to any command table/list in the README that enumerates the subcommands (search for `amux init` and `amux doctor` to find it).

- [ ] **Step 7: Run the full suite**

Run: `bash tests/run.sh` then `/bin/bash tests/run.sh`
Expected: `N passed, 0 failed` on both — including the new `test-restamp.sh` and `test-settings.sh`, with `test-init.sh` and `test-reload.sh` still green.

- [ ] **Step 8: Commit**

```bash
git add scripts/amux-settings bin/amux tests/test-settings.sh README.md
git commit -m "feat(settings): amux settings fzf TUI, bin/amux + prefix S wiring, docs"
```

---

## Self-Review notes (for the implementer)

- **Byte-safety:** every glyph/wedge in `amux-config.sh` comes from `printf '\xHH'` — never a literal in a source edit, never `\uXXXX`. Verify with `grep -n '\\u' scripts/lib/amux-config.sh scripts/amux-*` → no matches.
- **noglob:** every `set -- $(amux_glyphset …)` / `$(amux_theme …)` is wrapped in `set -f` / `set +f` (ascii glyphs `[!] [~] [+]` are glob patterns).
- **Atomicity:** `amux_cfg_set` writes a temp in the target dir and `mv`s — never truncates the live config.
- **No server = no crash:** `amux_apply_live` and `amux-restamp` both `has-session`-guard and return/exit 0; `amux settings` still writes the config file with no server running.
- **Test socket seams:** `AMUX_CONFIG_SOCK` (lib), `AMUX_RESTAMP_SOCK` (restamp), `AMUX_FZF` (settings) keep everything drivable without touching the real `-L amux` server.
```
