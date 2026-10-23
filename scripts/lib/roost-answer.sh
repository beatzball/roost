# roost-answer.sh — the dialog record a pane carries, and what `roost answer`
# (#142) needs to read it.
#
# Sourced by bin/roost (`answer`) and by scripts/lib/roost-jsonout.sh (`status
# --json`). Defines functions and runs nothing at source time. Only
# roost_answer_send runs tmux, through bin/roost's `t`; the parsers and the key
# map run none, so tests/test-answer-keymap.sh checks every rule with no server.
#
# The design, and the measurement behind every rule, is
# docs/airig/specs/2026-09-30-roost-answer-design.md. Its §4 is the record, §5
# the key map, §8 what is recorded about who answered.
#
# --- the two pane options ---------------------------------------------------
#
#   @roost-dialog    "<fingerprint> <harness> <kind> <options> <digest>"
#                    written by the PermissionRequest hook
#                    (scripts/roost-agent-state, roost_stamp_blocked), in the
#                    same tmux command as the 🛑 stamp
#   @roost-answered  "<fingerprint> <epoch> <action> <by>"
#                    written by `roost answer`, in the same tmux command as the
#                    key it sends
#
# Both are removed wherever @roost-blocked-on is: when the pane leaves
# blocked, in the Stop guard's else branch, and in scripts/lib/roost-unblock.sh.
#
# A READER MUST CHECK EVERY WORD, here as at the write. A pane option is
# something anyone can `tmux set`, and these words end up spliced into a tmux
# format and printed as JSON. So a value that is not exactly the shape below is
# no record at all. Hex and digits are spelled out, never written as a range:
# bash 3.2 matches a range by the locale's collation, where a-f can include
# capitals.

# roost_answer_hex VALUE LEN -> 0 when VALUE is exactly LEN lowercase hex.
roost_answer_hex() {
  local LC_ALL=C
  case "$1" in ''|*[!0123456789abcdef]*) return 1 ;; esac
  [ "${#1}" -eq "$2" ]
}

# roost_answer_dialog_parse VALUE -> 0, setting ROOST_DIALOG_FP, _HARNESS,
# _KIND, _OPTIONS and _DIGEST; or 1 with all five empty.
#
#   fingerprint  12 lowercase hex, new for each dialog (§4.1)
#   harness      claude | codex
#   kind         permission | question | other
#   options      one digit; 0 for anything but a question
#   digest       8 lowercase hex
roost_answer_dialog_parse() {
  local LC_ALL=C fp h k o dg extra
  ROOST_DIALOG_FP="" ROOST_DIALOG_HARNESS="" ROOST_DIALOG_KIND="" ROOST_DIALOG_OPTIONS="" ROOST_DIALOG_DIGEST=""
  case "$1" in *$'\n'*|*$'\t'*) return 1 ;; esac
  read -r fp h k o dg extra <<EOF || true
$1
EOF
  [ -z "${extra:-}" ] || return 1
  roost_answer_hex "${fp:-}" 12 || return 1
  case "${h:-}" in claude|codex) ;; *) return 1 ;; esac
  case "${k:-}" in permission|question|other) ;; *) return 1 ;; esac
  case "${o:-}" in [0123456789]) ;; *) return 1 ;; esac
  [ "$k" = question ] || [ "$o" = 0 ] || return 1
  roost_answer_hex "${dg:-}" 8 || return 1
  ROOST_DIALOG_FP="$fp" ROOST_DIALOG_HARNESS="$h" ROOST_DIALOG_KIND="$k"
  ROOST_DIALOG_OPTIONS="$o" ROOST_DIALOG_DIGEST="$dg"
}

# roost_answer_answered_parse VALUE FINGERPRINT -> 0, setting ROOST_ANSWERED_AT,
# _ACTION (approve | deny | option), _OPTION (the digit, or "") and _BY; or 1.
#
# Only an answer to THIS dialog counts: a record whose fingerprint is not
# FINGERPRINT is no answer, whatever else it says. The hook removes the record
# with the dialog's, so that should never be seen; a reader does not rely on it.
#
#   epoch   digits, no leading zero (it is printed as a JSON number)
#   action  approve | deny | option1 .. option9
#   by      terminal | program | pane:%N
roost_answer_answered_parse() {
  local LC_ALL=C fp at act by extra
  ROOST_ANSWERED_AT="" ROOST_ANSWERED_ACTION="" ROOST_ANSWERED_OPTION="" ROOST_ANSWERED_BY=""
  case "$1" in *$'\n'*|*$'\t'*) return 1 ;; esac
  read -r fp at act by extra <<EOF || true
$1
EOF
  [ -z "${extra:-}" ] || return 1
  roost_answer_hex "${fp:-}" 12 || return 1
  [ "$fp" = "$2" ] || return 1
  case "${at:-}" in ''|*[!0123456789]*|0?*) return 1 ;; esac
  [ "${#at}" -le 12 ] || return 1
  case "${act:-}" in
    approve|deny) ROOST_ANSWERED_ACTION="$act" ;;
    option[123456789]) ROOST_ANSWERED_ACTION=option; ROOST_ANSWERED_OPTION="${act#option}" ;;
    *) return 1 ;;
  esac
  case "${by:-}" in
    terminal|program) ;;
    pane:%[0123456789]*) case "${by#pane:%}" in *[!0123456789]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  [ "${#by}" -le 32 ] || return 1
  ROOST_ANSWERED_AT="$at" ROOST_ANSWERED_BY="$by"
}

# roost_answer_dialog_json STATE DIALOG ANSWERED -> ROOST_ANSWER_JSON, the
# `dialog` value of one pane in `status --json` (§4.3):
#
#   null  when STATE is not blocked, or DIALOG is not a record
#   {"fingerprint":"…","harness":"…","kind":"…","options":N,"answered":null}
#   "answered" is {"at":N,"action":"approve|deny|option","option":N|null,"by":"…"}
#   once `roost answer` has answered THIS dialog
#
# Every word was checked by the parsers above, so none of them needs the JSON
# encoder: hex, fixed words, digits, and `pane:%N`.
roost_answer_dialog_json() {
  local LC_ALL=C ans=null opt=null
  ROOST_ANSWER_JSON=null
  [ "$1" = blocked ] || return 0
  roost_answer_dialog_parse "$2" || return 0
  if roost_answer_answered_parse "$3" "$ROOST_DIALOG_FP"; then
    [ -n "$ROOST_ANSWERED_OPTION" ] && opt="$ROOST_ANSWERED_OPTION"
    ans="{\"at\":$ROOST_ANSWERED_AT,\"action\":\"$ROOST_ANSWERED_ACTION\",\"option\":$opt,\"by\":\"$ROOST_ANSWERED_BY\"}"
  fi
  ROOST_ANSWER_JSON="{\"fingerprint\":\"$ROOST_DIALOG_FP\",\"harness\":\"$ROOST_DIALOG_HARNESS\",\"kind\":\"$ROOST_DIALOG_KIND\",\"options\":$ROOST_DIALOG_OPTIONS,\"answered\":$ans}"
}

# --- the key map (§5) ---------------------------------------------------------
#
# roost_answer_keys HARNESS KIND ACTION [N [OPTIONS]] -> 0, setting
# ROOST_ANSWER_KEY (one tmux key name), ROOST_ANSWER_MARK1 and
# ROOST_ANSWER_MARK2 (the two lines that must both be on the pane's visible
# screen); or 1, setting ROOST_ANSWER_REFUSAL to the sentence `roost answer`
# prints before it exits 8.
#
# A ROW IS A MEASUREMENT. Each one names the harness version and the section
# of the design that measured it. A new row needs a new measurement first: no
# row, no key. The map is NOT keyed by version number, because roost does not
# know which version is running for certain. What guards a changed dialog is
# the marker check (a reworded dialog is refused with exit 6, which is safe)
# and tests/live/answer-smoke.sh, which drives a real Claude through these rows
# and is run after every harness upgrade.
#
# roost never sends `2`, `p`, Tab or Enter to a dialog. `2` and `p` grant a
# standing permission on the dialogs measured; Enter follows the cursor, which
# a human may have moved; Tab amends. None of them has a row, and none ever may.
#
# NOT IN THIS CUT, by ruling: codex. Its command approval was measured on
# 0.157.1 (M3: `y` approves with no Enter, Escape declines and fires
# Interrupt), but on that version a second codex pane's hooks can stamp the
# FIRST pane (F1, #145), so the pane that reads blocked may not be the pane
# showing the dialog. The marker check would refuse that case, and refusing is
# not a fix. So codex has no row until #145 is understood, and every codex
# dialog is exit 8. The same for opencode, copilot and pi, whose dialogs were
# never measured.
roost_answer_keys() {
  local h="$1" k="$2" a="$3" n="${4:-}" opts="${5:-0}"
  ROOST_ANSWER_KEY="" ROOST_ANSWER_MARK1="" ROOST_ANSWER_MARK2="" ROOST_ANSWER_REFUSAL=""
  case "$h/$k/$a" in
    # Claude Code 2.1.283, M1: `1` approves with NO Enter (3 runs), and wins
    # over a cursor moved to "No" (once). The first option is "Yes" on every
    # shape measured: Bash with three options, Bash with `&` with two, Write.
    # Edit, on 2.1.309 (once, for #142's step 2): "Do you want to make this
    # edit to <file>?", the same three rows as Write, and `1` made the edit
    # with no Enter, the badge at `done` by +0.3 s.
    claude/permission/approve)
      ROOST_ANSWER_KEY=1 ;;
    # Claude Code 2.1.283, M1: Escape declines (once, with timing), and writes
    # the same three transcript records as "No". Edit on 2.1.309 (once): the
    # file was left as it was, and `send` then cleared the badge from the
    # transcript, as for Bash. A digit is never used to
    # deny: "No" is option 3 on one dialog and option 2 on another, and on the
    # first one option 2 is "Yes, and always allow".
    claude/permission/deny)
      ROOST_ANSWER_KEY=Escape ;;
    claude/permission/option)
      ROOST_ANSWER_REFUSAL="this is a permission prompt. Use --approve or --deny"
      return 1 ;;
    # Claude Code 2.1.283, M2: on ONE single-select question the digit N picks
    # option N and submits it, with NO Enter (once; PostToolUse's answers
    # named the option). Only the options the MODEL gave can be picked: Claude
    # adds "Type something." and "Chat about this" below them by itself, and
    # those open a text box or a chat, which this cut does not answer. On two
    # questions or a multi-select a digit does NOT submit -- it moves on or
    # ticks a box (M2, once each) -- which is why both are kind `other`.
    claude/question/option)
      case "$n" in ''|*[!0123456789]*) n=0 ;; esac
      case "$opts" in [0123456789]) ;; *) opts=0 ;; esac
      if [ "$n" -lt 1 ] || [ "$n" -gt "$opts" ] || [ "$n" -gt 9 ]; then
        ROOST_ANSWER_REFUSAL="option $n is not one of the $opts options the agent gave"
        return 1
      fi
      ROOST_ANSWER_KEY="$n" ;;
    # Claude Code 2.1.283, M2: Escape declines the question (once), with the
    # same three transcript records as a declined permission prompt.
    claude/question/deny)
      ROOST_ANSWER_KEY=Escape ;;
    claude/question/approve)
      ROOST_ANSWER_REFUSAL="this is a question with $opts options. Use --option N, or --deny"
      return 1 ;;
    *)
      ROOST_ANSWER_REFUSAL="no measured keys for this $h dialog. Answer at the pane"
      return 1 ;;
  esac
  # The marker: both lines must be on the visible screen. "Esc to cancel" is
  # on both Claude dialogs; the second line says which one it is.
  #   permission  "Do you want to"   Claude Code 2.1.283 (M1), and the same on
  #                                  2.1.309 for Bash and Edit
  #   question    "Enter to select"  Claude Code 2.1.283 (M2), the footer
  #                                  "Enter to select · ↑/↓ to navigate · Esc
  #                                  to cancel"
  ROOST_ANSWER_MARK1="Esc to cancel"
  case "$k" in
    question) ROOST_ANSWER_MARK2="Enter to select" ;;
    *) ROOST_ANSWER_MARK2="Do you want to" ;;
  esac
  return 0
}

# roost_answer_marked SCREEN -> 0 when both marker lines are in SCREEN. SCREEN
# is the pane's VISIBLE screen, captured with its wrapped lines joined
# (`capture-pane -p -J`), because a narrow pane that wraps a marker line would
# otherwise split it and miss (the design's §12.6).
roost_answer_marked() {
  case "$1" in *"$ROOST_ANSWER_MARK1"*) ;; *) return 1 ;; esac
  case "$1" in *"$ROOST_ANSWER_MARK2"*) ;; *) return 1 ;; esac
}

# --- the send (§3.1 step 9, M9) ----------------------------------------------
#
# roost_answer_send PANE FINGERPRINT KEY VALUE NONCE -> 0 when the key was sent,
# 1 when tmux refused the test and sent nothing, 2 when tmux itself failed.
#
# ONE tmux command tests and sends. tmux evaluates the test against the pane at
# the moment it runs, in the same command list as the send, so nothing can
# land between "this is still the dialog the caller named" and the key:
#
#   the pane reads blocked
#   AND @roost-dialog still begins with FINGERPRINT
#   AND @roost-answered does not (this dialog is not answered yet)
#   AND the pane is not in a mode (copy mode would take the key)
#
# When it holds, the same branch sends KEY, writes @roost-answered = VALUE
# ("<fingerprint> <epoch> <action> <by>", §8) and writes @roost-answer-nonce =
# NONCE. `if-shell` exits 0 whichever branch ran, so the caller learns which
# from the read that follows it in the same command: the nonce. Not
# @roost-answered itself: two `roost answer` calls on one dialog in one second
# from one place would write the same VALUE, and the one whose test failed
# would read the other's VALUE back and believe it had sent. A nonce is the
# caller's own, so only the caller that sent can read it back. Measured on tmux
# 3.6: a read chained after `if-shell` sees the branch's write. (A
# `display-message -p` INSIDE the branch printed twice and on the wrong branch
# in the same probe, so nothing here reads from inside it.)
#
# Every word spliced into the command was checked by the caller: PANE is %N,
# FINGERPRINT 12 hex, KEY a key name from the map above, VALUE hex, digits, a
# fixed word and `pane:%N`/terminal/program, NONCE digits and a dot.
roost_answer_send() {
  local pane="$1" fp="$2" key="$3" value="$4" nonce="$5" cond got
  cond="#{&&:#{==:#{@agent_state},blocked},#{&&:#{m:$fp *,#{@roost-dialog}},#{&&:#{?#{m:$fp *,#{@roost-answered}},,1},#{==:#{pane_in_mode},0}}}}"
  got="$(t if-shell -F -t "$pane" "$cond" \
    "send-keys -t $pane $key ; set-option -p -t $pane @roost-answered '$value' ; set-option -p -t $pane @roost-answer-nonce '$nonce'" \
    ';' display-message -p -t "$pane" '#{@roost-answer-nonce}' 2>/dev/null)" || {
    # The whole command failed. Ask once more whether the branch ran: tmux
    # stops a command list at its first error, so a nonce that is ours means
    # the key went in before whatever failed.
    got="$(t display-message -p -t "$pane" '#{@roost-answer-nonce}' 2>/dev/null || true)"
    [ "$got" = "$nonce" ] && return 0
    return 2
  }
  [ "$got" = "$nonce" ]
}
