# roost-answer.sh — the dialog record a pane carries, and what `roost answer`
# (#142) needs to read it.
#
# Sourced by bin/roost (`answer`) and by scripts/lib/roost-jsonout.sh (`status
# --json`). Defines functions and runs nothing at source time; nothing here
# runs tmux, so tests/test-answer-keymap.sh checks every rule with no server.
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

# roost_answer__hex VALUE LEN -> 0 when VALUE is exactly LEN lowercase hex.
roost_answer__hex() {
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
  roost_answer__hex "${fp:-}" 12 || return 1
  case "${h:-}" in claude|codex) ;; *) return 1 ;; esac
  case "${k:-}" in permission|question|other) ;; *) return 1 ;; esac
  case "${o:-}" in [0123456789]) ;; *) return 1 ;; esac
  [ "$k" = question ] || [ "$o" = 0 ] || return 1
  roost_answer__hex "${dg:-}" 8 || return 1
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
  roost_answer__hex "${fp:-}" 12 || return 1
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
