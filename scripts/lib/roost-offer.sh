# roost-offer.sh — the restore offer (#191, Part 7): after a crash with
# `persist` off, a bare `roost` (and `roost session NAME`, `roost new`) asks
# whether to bring the saved fleet back, instead of opening an empty session.
#
#   roost: a saved fleet from 2 h ago (2026-10-24 20:51): 2 sessions, 3 windows, 4 panes; 1 of 2 agents would resume.
#     r restore it   p preview   n start fresh, do not ask again   l restore at login from now on: off
#     Enter starts fresh (nothing is restored without an r).
#
# The design is docs/airig/specs/2026-10-24-persistent-sessions-design.md
# §4.8 (revisions 6 to 9); the plan is
# docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Part 7.
#
# THE OFFER ADDS NO WAY TO RESTORE. Its `r` is §4.3's placement and §4.6's
# first-attach resume; its preview is §4.3's `--dry-run` tree, by the same
# functions and the same `--from STAMP-GEN` lookup (roost_restore_pick), so
# the offer, `r` and a second terminal's `roost restore --dry-run --from
# STAMP-GEN` are one code path.
#
# IT RUNS BEFORE THE SERVER STARTS. While a person thinks, the offer reads
# files only — the pin, closed/, declined — and starts nothing: no bootstrap
# session, no placeholder, no restoring/. So a script that starts the server
# meanwhile is never held waiting on a person.
#
# Sourced by bin/roost's attach verbs only, and only this file at first: the
# cheap checks (a person at a terminal, no server) run before the shape,
# restore and resume libraries are read. Uses bin/roost's `t`,
# `server_running`, SOCKET, _SOCKET_FLAG and ROOST_HOME. bash 3.2 safe and
# `set -u` clean (bin/roost runs on macOS /bin/bash under `set -euo
# pipefail`).

# The agent markers (§4.8, check 2c): any one set and non-empty means the
# caller is an agent's tool command, not a person, and the offer is skipped
# without waiting the no-answer bound. Only names a harness sets in its tool
# shell and a person's plain shell does not have:
#   Claude Code         CLAUDECODE, CLAUDE_CODE_ENTRYPOINT,
#                       CLAUDE_CODE_SESSION_ID, CLAUDE_CODE_CHILD_SESSION
#                       (measured, the spec's table)
#   codex               CODEX_THREAD_ID (confirmed on codex-cli 0.166.0)
#   GitHub Copilot CLI  COPILOT_CLI, COPILOT_AGENT_SESSION_ID (1.0.103)
#   pi                  PI_CODING_AGENT, AI_AGENT (1.5.0)
# The last three rows are Task 7.1's probe, docs/airig/probes/
# persist-7-markers.md. opencode is not measured and has none here.
# Not markers, on purpose: the config homes (CODEX_HOME, COPILOT_HOME,
# PI_CODING_AGENT_DIR, OPENCODE_CONFIG_DIR), which a person's own profile
# exports as often as a harness does, and TMUX and TMUX_PANE, which every
# person inside tmux has. The list is best effort: a marker skips a minute's
# wait; the 60 s bound (check 2d) is what keeps an unmarked agent from
# waiting for ever. A marker found later is one more name here.
ROOST_OFFER_MARKERS="CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CODEX_THREAD_ID COPILOT_CLI COPILOT_AGENT_SESSION_ID PI_CODING_AGENT AI_AGENT"

# roost_offer__person -> exit 0 when the caller is a person (§4.8 check 2,
# revision 7 item 2). A terminal alone does not prove one: an agent's tool
# command run with a pty passes `[ -t 0 ] && [ -t 1 ]`, and would then wait
# for a key. So all of:
#   (a) stdin and stdout are terminals: not a script, a pipe, or an agent's
#       plain tool shell;
#   (b) ROOST_NO_OFFER unset or empty, and no leading `--no-offer`
#       (ROOST_OFFER_FLAG_OFF, set by bin/roost): the switch for a script
#       that attaches through a pty on purpose;
#   (c) no agent marker set and non-empty.
# (d), the 60 s bound once the prompt is shown, is the prompt's own.
roost_offer__person() {
  local m v
  [ -t 0 ] && [ -t 1 ] || return 1
  [ -z "${ROOST_NO_OFFER:-}" ] || return 1
  [ "${ROOST_OFFER_FLAG_OFF:-0}" != 1 ] || return 1
  for m in $ROOST_OFFER_MARKERS; do
    eval "v=\${$m:-}"
    [ -z "$v" ] || return 1
  done
  return 0
}

# roost_offer__libs — the libraries the checks past the cheap ones need.
roost_offer__libs() {
  command -v roost_shape_saving >/dev/null 2>&1 || . "$ROOST_HOME/scripts/lib/roost-shape.sh"
  command -v roost_restore_pick >/dev/null 2>&1 || . "$ROOST_HOME/scripts/lib/roost-restore.sh"
  command -v roost_resume_listing >/dev/null 2>&1 || . "$ROOST_HOME/scripts/lib/roost-resume.sh"
  ROOST_RESUME_TFLAG="$_SOCKET_FLAG" ROOST_RESUME_TSOCK="$SOCKET"
  # Restore's own settings, never the environment's (the restore arm's
  # rule): the offer previews and places what a plain `roost restore --from
  # STAMP-GEN` would.
  ROOST_RESTORE_NORESUME=0 ROOST_RESTORE_RECENT=""
  ROOST_RESTORE_ONLY=()
}

# roost_offer_release — remove offer/, the pin with it, when this process
# holds it; nothing otherwise. Called last, just before the attach's `exec`
# (§4.8, revision 7, F N3: whoever waits on offer/ then always finds the
# server running), and by the trap on any other way out.
roost_offer_release() {
  [ "${ROOST_OFFER_HELD:-0}" = 1 ] || return 0
  ROOST_OFFER_HELD=0
  roost_shape_owner_drop "$ROOST_OFFER_SD/offer"
}

# roost_offer__lock SHAPEDIR -> exit 0 holding offer/ (ROOST_OFFER_HELD=1),
# 1 when this offer should not run (it could not be owned at all), 2 when a
# live owner held it and has now gone: the caller starts its checks again
# from the top, since the first terminal's answer has usually started the
# server (§4.8, "two terminals").
#
# offer/ is under §3.5's owner rule — pid and start time, never age — so a
# terminal closed mid-prompt (a dead owner) is taken over at once by the
# next `roost`, which pins afresh (`ln -f` replaces the old link). Not
# restoring/: that would make every save, and ensure_session's persist path,
# wait on a person who may have walked away; offer/ is read only by another
# offer and by --at-login's closed/ cleanup.
roost_offer__lock() {
  local sd="$1" r=0 next
  roost_shape_owner_take "$sd/offer" || r=$?
  case "$r" in
    0|2) ROOST_OFFER_HELD=1 ROOST_OFFER_SD="$sd"; return 0 ;;
    1) ;;
    *) return 1 ;;
  esac
  # §4.6's wait, worded the same: a line at once and then every 10 s, by the
  # clock (bash's SECONDS), never by counting turns. Ctrl-C gets a person
  # out; they held nothing.
  next="$SECONDS"
  while roost_shape_owner_live "$sd/offer"; do
    if [ "$SECONDS" -ge "$next" ]; then
      printf 'waiting for the restore offer in another terminal (pid %s)\n' "${ROOST_SHAPE_OWNER_PID:-?}" >&2
      next=$((SECONDS + 10))
    fi
    sleep 0.2
  done
  return 2
}

# roost_offer__pin -> exit 0 with the save §3.6 picks pinned in offer/:
# `offer/save` a hard link to it, `offer/stamp` its STAMP-GEN
# (ROOST_OFFER_STAMP); 1 when nothing can be pinned.
#
# From here on the offer acts on this ONE save and never reads `shape` again
# (§4.8, revision 7 item 1, F N10): a script may start the server and publish
# a fresh `shape` while a person reads, and `r`, `p` and `n` must still be
# about the fleet the person was shown. While the pin is held, the ring may
# prune the save's history/ name; the inode lives on in offer/save.
#
# `ln` takes a path, not an inode, so a save renamed over `shape` between
# the reading rule's read and the link would be pinned instead (revision 8,
# F N2): the header is read again from offer/save, and when its boot or gen
# differ from the save that was picked, the pick and the pin are done again,
# ONCE; a second mismatch ends the offer.
roost_offer__pin() {
  local sd="$ROOST_OFFER_SD" try=0 bg
  while [ "$try" -lt 2 ]; do
    try=$((try + 1))
    # §3.6 steps 1 to 3. Its step 3 line ("no shutdown record readable;
    # restoring the newest save") is not printed here: nothing is being
    # restored yet (F N7).
    roost_restore__reading_rule "$sd"
    [ -f "$ROOST_RESTORE_FILE" ] || return 1
    bg="$(roost_restore__bootgen "$ROOST_RESTORE_FILE")"
    ln -f "$ROOST_RESTORE_FILE" "$sd/offer/save" 2>/dev/null || return 1
    if [ "$(roost_restore__bootgen "$sd/offer/save")" = "$bg" ]; then
      ROOST_OFFER_STAMP="$(roost_restore__stampgen "$sd/offer/save")"
      ( umask 077; printf '%s\n' "$ROOST_OFFER_STAMP" > "$sd/offer/stamp" ) 2>/dev/null || return 1
      return 0
    fi
  done
  return 1
}

# roost_offer__tree OUT -> the pin's `--dry-run` tree in OUT, and
# ROOST_RESTORE_DRY_* its counts; exit 1 when §3.6 step 4 leaves nothing, or
# the save is refused. The tree is found by STAMP-GEN, through the lookup
# `roost restore --dry-run --from STAMP-GEN` uses (shape, history/,
# offer/save, declined), and treated as that lookup's save is: step 4
# applied for the pin's own boot, never as a `--from FILE`, which skips it
# (§3.6). One format, one code path: the preview IS the dry run (§4.8 `p`).
# Lines restore writes on stderr (a window that lost panes closed on
# purpose) go to OUT.err.
roost_offer__tree() {
  local out="$1" r=0
  : > "$out.err"
  roost_restore_pick "$ROOST_OFFER_SD" "$ROOST_OFFER_STAMP" 2>>"$out.err" || return 1
  roost_restore_prepare "$ROOST_RESTORE_FILE" "$ROOST_OFFER_SD" 2>>"$out.err" || r=$?
  if [ "$r" != 0 ]; then rm -rf "${ROOST_RESTORE_PD:-}"; return 1; fi
  roost_restore_dry_run > "$out" 2>>"$out.err" || true
  rm -rf "${ROOST_RESTORE_PD:-}"
  return 0
}

# roost_offer__checks KIND SESSION -> exit 0 when the offer is to be asked,
# holding offer/ with the pin in it and ROOST_OFFER_TREE written; 1 when
# `roost` goes on exactly as today (offer/ released, if it was taken).
#
# §4.8's checks, in its order, cheapest first. Check 1 (an attach verb) is
# the caller's: only bin/roost's attach arms call this. Check 2 (a person)
# ran before the libraries were read.
roost_offer__checks() {
  local root sd host fault r
  while :; do
    # 3. The server is not running: a running server is not a crash.
    server_running && return 1
    # 4. Saving is on: with ROOST_SHAPE_DIR= there is nothing to offer.
    root="$(roost_shape_saving)" || return 1
    sd="$root/$(roost_shape_key "$_SOCKET_FLAG" "$SOCKET")"
    # 5. The login service is off. With it on, ensure_session's §4.6 path
    # places the fleet by itself; asking as well would ask a question that
    # has already been answered.
    [ -e "$sd/persist" ] && return 1
    # Nothing saved: nothing to ask about (and no offer/ is made).
    [ -f "$sd/shape" ] || return 1
    # The lock, after check 5 and before check 6 reads a save. A live
    # owner that has gone: every check again from 3, since its answer has
    # usually started the server.
    r=0; roost_offer__lock "$sd" || r=$?
    case "$r" in
      0) break ;;
      2) continue ;;
      *) return 1 ;;
    esac
  done
  # 6. The pin, then §4.3's "refuse first" checks on it.
  roost_offer__pin || { roost_offer_release; return 1; }
  if ! roost_shape_check "$sd/offer/save"; then
    fault="$ROOST_SHAPE_FAULT"
    printf 'roost: the saved shape is unreadable (%s) - roost restore --list\n' "$fault" >&2
    roost_offer_release; return 1
  fi
  # A save from another machine resumes nothing here (§4.2), and a macOS
  # hostname can change with the network: one line says why (F N6), never
  # silence.
  host="$(roost_restore__hdr "$sd/offer/save" host)"
  if [ -n "$host" ] && [ "$host" != "$(uname -n)" ]; then
    printf 'roost: a fleet saved on %s is not offered here (roost restore --list)\n' "$host" >&2
    roost_offer_release; return 1
  fi
  # 7. Not the save `declined` names — by its header's boot AND gen: every
  # save of one server's run shares the boot, and a NEW save of the same
  # fleet is a new question (§8.1 test 12 (c)).
  if [ -f "$sd/declined" ] && [ "$(roost_restore__bootgen "$sd/declined")" = "$(roost_restore__bootgen "$sd/offer/save")" ]; then
    roost_offer_release; return 1
  fi
  # ...and, after §3.6 step 4 drops what closed/ names for the pin's boot,
  # something worth restoring: a pane with a key (resumable or not), or more
  # than one pane. A fleet closed on purpose leaves no pane, and one plain
  # shell is what `roost` is about to make anyway. "From an earlier boot"
  # needs no test: the server is not running, so every save is of a boot
  # that has ended.
  ROOST_OFFER_TREE="$sd/offer/tree"
  if ! roost_offer__tree "$ROOST_OFFER_TREE"; then roost_offer_release; return 1; fi
  if [ "${ROOST_RESTORE_DRY_K:-0}" -lt 1 ] && [ "${ROOST_RESTORE_DRY_P:-0}" -le 1 ]; then
    roost_offer_release; return 1
  fi
  return 0
}

# roost_offer__ago -> "2 h ago (2026-10-24 20:51)": the pin's `saved` against
# now (ROOST_TEST_NOW when set, the plan's seam), in epoch seconds, rounded
# to minutes, hours or days; then the moment itself in local time.
roost_offer__ago() {
  local sv then now d a when
  sv="$(roost_restore__hdr "$ROOST_OFFER_SD/offer/save" saved)"
  then="$(roost_restore__epoch "$sv")" || { printf 'at %s' "$sv"; return 0; }
  now="${ROOST_TEST_NOW:-$(date +%s)}"
  d=$((now - then)); [ "$d" -lt 0 ] && d=0
  if [ "$d" -lt 3600 ]; then a="$(( (d + 30) / 60 )) min"
  elif [ "$d" -lt 172800 ]; then a="$(( (d + 1800) / 3600 )) h"
  else a="$(( (d + 43200) / 86400 )) days"; fi
  when="$(date -r "$then" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$then" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$sv")"
  printf '%s ago (%s)' "$a" "$when"
}

# roost_offer__summary — the summary line and the keys (§4.8 "The prompt").
# The counts are the tree's: what §4.3 would place and resume from the pin
# after step 4. "would resume" counts the tree's `resume` panes; "of N"
# every pane with a key.
roost_offer__summary() {
  printf 'roost: a saved fleet from %s: %s sessions, %s windows, %s panes; %s of %s agents would resume.\n' \
    "$(roost_offer__ago)" "${ROOST_RESTORE_DRY_S:-0}" "${ROOST_RESTORE_DRY_W:-0}" "${ROOST_RESTORE_DRY_P:-0}" \
    "${ROOST_RESTORE_DRY_R:-0}" "${ROOST_RESTORE_DRY_K:-0}"
  roost_offer__keys
}
roost_offer__keys() {
  printf '  r restore it   p preview   n start fresh, do not ask again   l restore at login from now on: %s\n' "$ROOST_OFFER_L"
  printf '  Enter starts fresh (nothing is restored without an r).\n'
}

# roost_offer_ask KIND SESSION -> ROOST_OFFER_CHOICE: empty when no offer was
# asked (`roost` goes on exactly as today, with nothing printed), else the
# person's answer: r, n, enter or timeout. While a choice is set, offer/ is
# held, and the caller releases it (roost_offer_release) just before its
# `exec`. Ctrl-C, end of input, or any other way out releases it through the
# trap, starts nothing, declines nothing, and exits 130: leaving is not a
# decision, so the next `roost` asks again.
roost_offer_ask() {
  ROOST_OFFER_CHOICE="" ROOST_OFFER_HELD=0 ROOST_OFFER_L=off ROOST_OFFER_SD="" ROOST_OFFER_STAMP=""
  roost_offer__person || return 0
  roost_offer__libs
  trap 'roost_offer_release' EXIT
  trap 'roost_offer_release; exit 130' INT
  trap 'roost_offer_release; exit 143' TERM
  trap 'roost_offer_release; exit 129' HUP
  if ! roost_offer__checks "$1" "$2"; then
    trap - EXIT INT TERM HUP
    return 0
  fi
  roost_offer__summary
  roost_offer__prompt
  # `n` writes `declined` FIRST, before any server exists (§4.8: then
  # ensure_session, then the line, then the attach), so a login job that `l`
  # starts later meets a pin already declined.
  [ "$ROOST_OFFER_CHOICE" = n ] && roost_offer__decline
  return 0
}

# roost_offer__prompt -> ROOST_OFFER_CHOICE. One key at a time from stdin,
# which check 2 proved is a terminal; plain lines on stdout. No TUI library
# and no new dependency: bash 3.2's `read -rsn1`.
#
# The no-answer bound (check 2d) is on the FIRST read only (revision 8, F N1):
# one key proves a person, so every later read waits for ever, and a person
# who pressed `p` and is reading a long tree is not started fresh under
# them. An unattended pty never sends a key, so the net still closes in
# 60 s. ROOST_TEST_OFFER_TIMEOUT=SECONDS is the plan's seam for it.
roost_offer__prompt() {
  local k rc first=1 tmo="${ROOST_TEST_OFFER_TIMEOUT:-60}" t0
  case "$tmo" in ''|*[!0-9]*|0) tmo=60 ;; esac
  ROOST_OFFER_TMO="$tmo"
  while :; do
    rc=0 t0="$SECONDS"
    if [ "$first" = 1 ]; then IFS= read -rsn1 -t "$tmo" k || rc=$?
    else IFS= read -rsn1 k || rc=$?; fi
    # A timeout, told from end of input. bash 4 and later report a timeout
    # as a status above 128; bash 3.2 (macOS /bin/bash) reports 1 for both
    # (measured), so there the clock decides: a read that failed after the
    # whole bound timed out. SECONDS counts whole seconds, so a real timeout
    # reads at least tmo - 1; the input end that a closed terminal gives
    # comes at once.
    if [ "$first" = 1 ] && [ "$rc" != 0 ] && \
       { [ "$rc" -gt 128 ] || [ $((SECONDS - t0)) -ge $((tmo - 1)) ]; }; then
      ROOST_OFFER_CHOICE=timeout; return 0
    fi
    if [ "$rc" != 0 ]; then roost_offer_release; exit 130; fi
    first=0
    case "$k" in
      # Enter: start fresh, WITHOUT declining (revision 7, F N1). Nothing is
      # restored, and no agent launched, without an `r`; and a reflex Enter
      # through a familiar start must not silence the offer for good — only
      # `n` does that.
      "") ROOST_OFFER_CHOICE=enter; return 0 ;;
      n|N) ROOST_OFFER_CHOICE=n; return 0 ;;
      p|P) roost_offer__preview ;;
      # Any other key: the keys again.
      *) roost_offer__keys ;;
    esac
  done
}

# roost_offer__preview — `p`: the pin's `--dry-run` tree, the same text
# `roost restore --dry-run --from STAMP-GEN` prints, by the same functions
# and the same lookup (roost_offer__tree), worked out again now: a server a
# script started meanwhile changes what would be skipped (§8.1 test 12 (k2)).
# No pager: a long fleet scrolls, and the summary and keys are printed again
# under it so they are on screen.
roost_offer__preview() {
  if roost_offer__tree "$ROOST_OFFER_TREE"; then
    cat "$ROOST_OFFER_TREE.err" >&2
    cat "$ROOST_OFFER_TREE"
  else
    cat "$ROOST_OFFER_TREE.err" >&2
  fi
  roost_offer__summary
}

# roost_offer__decline — `n`: `declined`, a hard link to the pin, in the
# shape directory, 0600 like every file there. A link and not a line naming
# `boot` and `gen`, because a busy day's saves push the pinned save out of
# the 100-entry ring, and the `--from STAMP-GEN` line printed at `n` must
# keep working (roost_restore_pick looks at `declined` last). One fixed temp
# name, then a rename (revision 7, F N4): a `mktemp` name already exists, and
# a plain `ln` onto it fails; only the holder of offer/ writes it. Only the
# newest decline is kept: a second `n` replaces the first.
roost_offer__decline() {
  local sd="$ROOST_OFFER_SD"
  if ! ( umask 077; ln -f "$sd/offer/save" "$sd/declined.new" && mv -f "$sd/declined.new" "$sd/declined" ) 2>/dev/null; then
    rm -f "$sd/declined.new"
    printf 'roost: could not record the decline in %s; the offer may ask again\n' "$sd" >&2
  fi
}

# roost_offer__q WORD -> WORD, single-quoted when a shell would split it.
roost_offer__q() {
  case "$1" in
    ''|*[!A-Za-z0-9._/=+:@%-]*) roost_sq "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# roost_offer_lines SESSION — the lines `n`, Enter and No answer print
# before the attach (revision 8, F N6: after `exec tmux attach` nothing
# prints; a line printed before it is on screen again when the person
# detaches). Each names `--from STAMP-GEN`, never a bare `roost restore`:
# the fresh server saves at once, so from then on a bare restore picks the
# fresh fleet, and the old one is reached only by name.
#
# THE HINT (revision 7, C note). When the pin holds a session of the name
# the fresh server uses (SESSION: `main` for a bare `roost`), that restore
# would skip it as existing, and if every saved pane is in it, restore
# nothing. Renaming the fresh session frees the name and kills nothing; the
# client stays attached to it. Written with this server's own `-L NAME` or
# `-S PATH`, so it can be pasted as it is.
roost_offer_lines() {
  local s="$1" st="$ROOST_OFFER_STAMP"
  case "$ROOST_OFFER_CHOICE" in
    n) printf 'not restored; roost restore --from %s brings it back (doctor names it too)\n' "$st" ;;
    enter) printf 'not restored, not declined; roost restore --from %s brings it back\n' "$st" ;;
    timeout) printf 'roost: no answer in %s s; started fresh, nothing declined (roost restore --from %s brings it back)\n' \
               "$ROOST_OFFER_TMO" "$st" ;;
    *) return 0 ;;
  esac
  if grep -qxF "session $s" "$ROOST_OFFER_SD/offer/save" 2>/dev/null; then
    printf 'the saved "%s" is skipped while a "%s" runs: tmux %s %s rename-session -t %s %s, then roost restore --from %s\n' \
      "$s" "$s" "$_SOCKET_FLAG" "$(roost_offer__q "$SOCKET")" "$(roost_offer__q "$s")" "$(roost_offer__q "$s-fresh")" "$st"
  fi
}
