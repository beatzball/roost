# roost-jsonout.sh — the `--json` output of status, read, screen, whoami and
# state (#41). docs/airig/specs/2026-09-15-json-output-design.md is the
# contract: every document, every field, and what counts as a breaking change.
#
# Sourced, not executed, `roost_jsonout_*` prefix. Sourced INSIDE each `--json`
# branch of bin/roost, never at the top, the way roost-reply.sh is sourced
# inside `reply`: a command that did not ask for JSON pays nothing, and `roost
# state` on an adapter's path pays nothing at all.
#
# Not roost-json.sh. That file EDITS config files with python3 or jq, and is
# allowed to because it backs a one-off setup command. This file is on the
# commands agents call all day, and neither python3 nor jq may be a runtime
# dependency of those, so it uses neither.
#
# The functions below that talk to tmux (roost_jsonout_list,
# roost_jsonout_screen, roost_jsonout_status) use bin/roost's own `t` wrapper
# and read its SOCKET, _SOCKET_FLAG and ROOST_JSON_SCHEMA, so the socket rule
# stays in one place. roost_jsonout_encode needs nothing but bash and awk, which
# is what lets tests/test-json-output.sh fuzz it on its own.
#
# NO TMUX CALL MAY RUN UNDER `local LC_ALL=C`. Several functions below need that
# local for byte-exact lengths and patterns (see roost_jsonout_encode), but when
# the caller's environment already EXPORTS LC_ALL -- macOS CI does -- the local
# copy is exported too, measured on bash 3.2 and 5.3. A tmux client started
# inside that scope then runs in the C locale, and tmux 3.4, 3.6 and 3.7c all
# replace every tab, newline and non-ASCII byte in what they print to such a
# client with `_`. `status --json` shipped that way first: the names read back
# as `t_x__e` on macOS CI and exactly everywhere LC_ALL was not exported. So
# tmux is called from functions that do not set the local, and the byte work is
# done in helpers that do.

# --- the encoder --------------------------------------------------------------
#
# WHY AWK AND NOT BASH. A pure-bash encoder was built and measured first, and it
# was correct and far too slow: `${s//pattern/rep}` is quadratic in the number
# of matches on bash 3.2, so a 12KB reply holding 2800 characters that need an
# escape took 2.0s (backslash 0.35s, quote 0.69s, newline 0.35s, each measured
# alone). A bash byte walker cost ~1.6s on 12KB of invalid bytes. And `[[ =~ ]]`
# with raw high bytes in the ERE rejected VALID multi-byte strings on macOS bash
# 3.2, so it could not even serve as a fast path. awk is already a dependency
# (`roost help` runs it), so one awk process per command adds nothing new, and
# the same 12KB costs 18-32ms including the fork.
#
# THE RULE, byte by byte:
#   `\` -> `\\`   `"` -> `\"`   BS TAB LF FF CR -> `\b \t \n \f \r`
#   every other byte 0x01-0x1F, and DEL -> `\u00XX`. DEL is legal raw JSON; it
#     is escaped so a document printed to a terminal cannot drive that terminal
#   well-formed UTF-8 (RFC 3629: no overlongs, no surrogates, nothing past
#     U+10FFFF) -> copied through unchanged
#   anything else -> U+FFFD, one per MAXIMAL SUBPART, and the value is marked
#     lossy. That is the Unicode/WHATWG replacement rule, and Python's
#     errors='replace' follows it too, which is what gives the test an oracle.
#     JSON has no byte escape -- \u00FF means U+00FF, not the byte 0xFF -- so a
#     lossless byte round trip is not possible inside a JSON string; replacing
#     and SAYING so is the honest option.
#
# NUL needs no rule: a bash string cannot hold one. bash 3.2 drops it silently
# and bash 5 drops it with a warning on stderr, before any value reaches here.
#
# THE FRAME. bash writes each value as <byte-length>:<bytes>, then one sentinel
# byte. A length prefix cannot be confused by anything a value contains, where
# any delimiter could be. The sentinel is there because awk reads records: a
# value ending in a newline would otherwise lose it at the end of input. awk
# prints one encoded string per line -- an encoded string can never contain a
# raw newline, so a line IS a value -- and then one line of lossy flags.
#
# Output is written piece by piece with printf rather than concatenated into a
# growing string, which keeps the walk linear. Runs of bytes that need nothing
# are copied in one substr.
#
# Fuzzed against Python's json module and strict UTF-8 decoding with every
# single byte 0x01-0xFF and 3000 random mixtures, 0 failures, on: macOS bash
# 3.2 + BSD awk 20200816, Ubuntu 24.04 bash 5.2 + mawk 1.3.4, Debian 11 bash
# 5.1 + mawk, and BusyBox 1.37 awk. gawk was NOT run (no network in the
# containers); tests/test-json-output.sh keeps proving whichever awk CI has.
ROOST_JSONOUT_AWK='
BEGIN {
  for (i = 1; i < 256; i++) {
    c = sprintf("%c", i); ord[c] = i
    if (i < 32 || i >= 127 || i == 34 || i == 92) special[c] = 1
  }
  for (i = 1; i < 32; i++) esc[sprintf("%c", i)] = sprintf("\\u%04x", i)
  esc[sprintf("%c", 127)] = "\\u007f"
  esc[sprintf("%c", 8)] = "\\b"; esc[sprintf("%c", 9)] = "\\t"; esc[sprintf("%c", 10)] = "\\n"
  esc[sprintf("%c", 12)] = "\\f"; esc[sprintf("%c", 13)] = "\\r"
  esc["\""] = "\\\""; esc["\\"] = "\\\\"
  ffd = sprintf("%c%c%c", 239, 191, 189)
}
{ buf = (NR == 1) ? $0 : buf "\n" $0 }
END {
  total = length(buf) - 1; pos = 1; flags = ""
  while (pos <= total) {
    # A frame that is not <digits>: with the bytes it promises EXITS rather than
    # guesses. The first version looped here forever when a length was wrong --
    # found by mutation, when dropping the `local LC_ALL=C` below made bash count
    # characters: every awk hung, and so did the roost command waiting on it.
    # Exiting early leaves too few lines, which roost_jsonout_encode reports.
    len = 0
    while ((d = substr(buf, pos, 1)) != ":") {
      if (pos > total || d !~ /^[0-9]$/) exit 1
      len = len * 10 + ord[d] - 48; pos++
    }
    if (pos + len > total) exit 1
    pos++; i = pos; end = pos + len; lossy = 0
    printf "\""
    while (i < end) {
      start = i
      while (i < end && !(substr(buf, i, 1) in special)) i++
      if (i > start) printf "%s", substr(buf, start, i - start)
      if (i >= end) break
      c = substr(buf, i, 1); b = ord[c]
      if (b < 128) { printf "%s", esc[c]; i++; continue }
      need = 0; lo = 128; hi = 191
      if (b >= 194 && b <= 223) need = 1
      else if (b == 224) { need = 2; lo = 160 }
      else if (b == 237) { need = 2; hi = 159 }
      else if (b >= 225 && b <= 239) need = 2
      else if (b == 240) { need = 3; lo = 144 }
      else if (b == 244) { need = 3; hi = 143 }
      else if (b >= 241 && b <= 243) need = 3
      k = 1
      while (k <= need && i + k < end) {
        cb = ord[substr(buf, i + k, 1)]
        if (cb < lo || cb > hi) break
        lo = 128; hi = 191; k++
      }
      if (need > 0 && k == need + 1) printf "%s", substr(buf, i, k)
      else { printf "%s", ffd; lossy = 1 }
      i += k
    }
    printf "\"\n"; flags = flags lossy; pos = end
  }
  printf "%s\n", flags
}'

# roost_jsonout_encode VALUE... -> ROOST_JSONOUT_STR[n], each a quoted JSON
# string, and ROOST_JSONOUT_LOSSY, one 0/1 per value. Returns 1 when awk did not
# hand back exactly one line per value plus the flag line, which is what a
# missing or crashed awk looks like; callers must call it inside `if` or `||`,
# because bin/roost runs under `set -e`.
#
# TWO BASH 5 TRAPS, both measured, both found because the fuzz harness fell into
# them before this file did. In a UTF-8 locale on bash 5.1/5.2:
#   1. `IFS= read -r -d ''` DROPS BYTES: a 19-byte value holding \x80\x01-style
#      sequences read back as 18.
#   2. pattern expansions REWRITE invalid bytes: `${t%x}` turned \xe0 into
#      \xc3\xa0 (the UTF-8 for a-grave) and moved a backslash ahead of a \xc2.
# Both were byte-exact under LC_ALL=C, and bash 3.2 showed neither. So every
# length, `read` and pattern in here runs under the `local LC_ALL=C` below --
# ${#v} is a BYTE count only because of it, the reply channel's own rule -- and
# nothing loads a raw value with `read`. Any code added here must keep both.
#
# awk gets its OWN `LC_ALL=C` on the command line. The `local` below switches
# bash's behaviour, but a local is exported to children only if LC_ALL was
# already in the environment, and with just LANG set awk would inherit a UTF-8
# locale. mawk and BSD awk walk bytes whatever the locale, so no test on CI can
# see that mistake; gawk would count characters and corrupt the frame. Keep it.
roost_jsonout_encode() {
  local LC_ALL=C
  local v line n=0
  ROOST_JSONOUT_STR=(); ROOST_JSONOUT_LOSSY=""
  while IFS= read -r line; do
    ROOST_JSONOUT_STR[n]="$line"; n=$((n + 1))
  done < <(
    { for v in "$@"; do printf '%d:%s' "${#v}" "$v"; done; printf 'x'; } \
      | LC_ALL=C awk "$ROOST_JSONOUT_AWK"
  )
  [ "$n" -eq $(($# + 1)) ] || return 1
  n=$((n - 1))
  ROOST_JSONOUT_LOSSY="${ROOST_JSONOUT_STR[n]}"
  unset "ROOST_JSONOUT_STR[n]"
}

# roost_jsonout_int VALUE -> ROOST_JSONOUT_INT: VALUE when it is a plain
# non-negative JSON integer, else the word null. A leading zero is refused
# because `007` is not a JSON number, and @agent_since is an option anyone can
# set to anything.
roost_jsonout_int() {
  local LC_ALL=C
  case "$1" in
    ''|*[!0-9]*|0?*) ROOST_JSONOUT_INT=null ;;
    *) ROOST_JSONOUT_INT="$1" ;;
  esac
}

# roost_jsonout_emit COMMAND KEY KIND VALUE [KEY KIND VALUE]...
#
# Prints ONE document on one line: "schema" and "command" first, then each key
# in the order given. Built in full and printed by a single printf, so a failure
# half-way can never leave half a document on stdout. Returns 1, printing
# nothing, when encoding failed.
#
#   s  string
#   z  string, or null when VALUE is empty
#   i  integer, or null when VALUE is not a plain non-negative integer
#   b  true when VALUE is 1, else false
#   t  string, then a "lossy" key saying whether invalid UTF-8 was replaced
#   T  as t, with "lossy" true whatever the encoder found -- for text tmux may
#      already have rewritten (roost_jsonout_looks_escaped)
#
# Every string value goes through ONE awk call, whatever the number of keys.
roost_jsonout_emit() {
  local LC_ALL=C
  local command="$1"; shift
  local -a keys kinds vals strs
  local i=0 j=0 n doc part
  keys=(); kinds=(); vals=(); strs=("$command")
  while [ "$#" -ge 3 ]; do
    keys[i]="$1"; kinds[i]="$2"; vals[i]="$3"; i=$((i + 1)); shift 3
  done
  n=$i; i=0; j=1
  while [ "$i" -lt "$n" ]; do
    case "${kinds[i]}" in
      s|t|T) strs[j]="${vals[i]}"; j=$((j + 1)) ;;
      z) if [ -n "${vals[i]}" ]; then strs[j]="${vals[i]}"; j=$((j + 1)); fi ;;
    esac
    i=$((i + 1))
  done
  roost_jsonout_encode "${strs[@]}" || return 1
  doc="{\"schema\":$ROOST_JSON_SCHEMA,\"command\":${ROOST_JSONOUT_STR[0]}"
  i=0; j=1
  while [ "$i" -lt "$n" ]; do
    case "${kinds[i]}" in
      s) part="${ROOST_JSONOUT_STR[j]}"; j=$((j + 1)) ;;
      t)
        part="${ROOST_JSONOUT_STR[j]}"
        if [ "${ROOST_JSONOUT_LOSSY:j:1}" = 1 ]; then part="$part,\"lossy\":true"; else part="$part,\"lossy\":false"; fi
        j=$((j + 1)) ;;
      T) part="${ROOST_JSONOUT_STR[j]},\"lossy\":true"; j=$((j + 1)) ;;
      z)
        if [ -n "${vals[i]}" ]; then part="${ROOST_JSONOUT_STR[j]}"; j=$((j + 1)); else part=null; fi ;;
      i) roost_jsonout_int "${vals[i]}"; part="$ROOST_JSONOUT_INT" ;;
      b) if [ "${vals[i]}" = 1 ]; then part=true; else part=false; fi ;;
    esac
    doc="$doc,\"${keys[i]}\":$part"
    i=$((i + 1))
  done
  printf '%s}\n' "$doc"
}

# roost_jsonout_fail CMD -> the one new failure line, for an encoder that did not
# answer. Exit 1 with nothing on stdout: it can only happen with --json, so it
# changes no existing exit code.
roost_jsonout_fail() {
  echo "roost $1: could not encode JSON output" >&2
  exit 1
}

# --- text tmux may already have rewritten ------------------------------------
#
# MEASURED (throwaway servers, every single byte 0x01-0xFF): tmux 3.4 and 3.5a
# rewrite every argument a CLIENT sends before the server keeps it. A control
# byte becomes `\a \b \v \f \r` or `\ooo`, DEL becomes `\177`, and each byte of
# invalid UTF-8 becomes `\ooo`. Tab, newline and valid UTF-8 are kept. A
# backslash is NOT escaped. tmux 3.6 and 3.7c keep the bytes as sent.
#
# So on 3.4/3.5a, a reply written with `roost reply` or by a hook through
# `tmux set-option` is stored already rewritten, and every reader -- human
# `roost read` included -- gets the escape text back. It CANNOT be decoded
# exactly: an agent that wrote the ESC byte and an agent that wrote the four
# characters `\033` (any shell snippet in a reply) are stored identically, and
# the second is far commoner. Decoding would corrupt that common case to rescue
# the rare one. So --json leaves the text exactly as tmux holds it, identical to
# what human `roost read` prints, and says "lossy": true whenever the text holds
# a sequence tmux writes and the server is one that writes them.
#
# A non-UTF-8 WRITER is worse and undetectable: tmux 3.4, 3.5a and 3.7c store
# tab, newline and every non-ASCII byte from such a client as `_`, which is an
# ordinary character. docs/known-gaps.md records it.

# roost_jsonout_looks_escaped TEXT -> 0 when TEXT holds `\` followed by three
# octal digits or by one of a b f r v: the sequences the escaper above writes.
# No tmux call, so LC_ALL=C is safe here.
roost_jsonout_looks_escaped() {
  local LC_ALL=C
  case "$1" in
    *\\[0-7][0-7][0-7]*|*\\[abfrv]*) return 0 ;;
  esac
  return 1
}

# roost_jsonout_server_escapes TARGET -> 0 when this tmux server stores
# client-sent control bytes as escape text. Asked of the server itself rather
# than of a version table, so a patched or backported tmux answers for itself.
# display-message only prints; it changes nothing. A server that stores bytes
# echoes the \x01 back (or `_`, to a non-UTF-8 client); an escaping one echoes
# the four characters `\001`. Only called when the text already looks escaped,
# so the common reply costs no extra tmux call. No `local LC_ALL=C`: it runs tmux.
roost_jsonout_server_escapes() {
  [ "$(t display-message -p -t "$1" $'\x01' 2>/dev/null || true)" = '\001' ]
}

# --- reading tmux without trusting a delimiter --------------------------------

# roost_jsonout_list NFIELDS ID-FORMAT ROW-FORMAT TMUX-LIST-ARGS...
#
# Sets ROOST_JSONOUT_IDS (one id per object) and ROOST_JSONOUT_ROWS (one row per
# id, the fields joined by TAB, in the same order). Returns 0 when the one-call
# rows can be trusted, 1 when the caller must read field by field instead --
# ROOST_JSONOUT_IDS is still set then -- and 2 when tmux refused the listing.
#
# WHY THIS EXISTS. Measured on tmux 3.6: #{window_name} and #{session_name} come
# back vis-escaped, but a user option like @roost-name comes back RAW, and a
# newline in it splits a record -- `list-panes -a` printed 4 lines for 3 panes.
# `roost spawn` and `split` refuse such names; any `tmux set -p` does not. A
# tab in it shifts every field after it. Human `roost status` has always
# printed that mangled; a JSON consumer must not get a pane that does not exist.
#
# So the one-call rows are accepted only when all of these hold:
#   - the id list read BEFORE and AFTER the rows is identical
#   - there is exactly one row per id
#   - every row has exactly NFIELDS-1 tabs
#   - row i starts with id i and a tab
# A tab or newline inside any field breaks the count or the tab check. Pane,
# window and session ids are never reused within a server's life, so identical
# before/after lists mean nothing came or went in between -- which closes the
# one forging route, a crafted name plus a pane dying mid-read.
#
# Ids themselves (%N, @N, $N) never contain a tab or a newline.
roost_jsonout_list() {
  # No `local LC_ALL=C` here: this function runs tmux. See the file header.
  local nf="$1" idf="$2" rowf="$3"; shift 3
  local before rows after
  ROOST_JSONOUT_IDS=(); ROOST_JSONOUT_ROWS=()
  before="$(t "$@" -F "$idf" 2>/dev/null)" || return 2
  rows="$(t "$@" -F "$rowf" 2>/dev/null)" || rows=""
  after="$(t "$@" -F "$idf" 2>/dev/null)" || after=""
  roost_jsonout__trust "$nf" "$before" "$rows" "$after"
}

# roost_jsonout__trust NFIELDS BEFORE ROWS AFTER -> the checks above, on text
# already read. Split out of roost_jsonout_list so the byte-exact `read` and
# pattern work runs under LC_ALL=C and no tmux call does.
roost_jsonout__trust() {
  local LC_ALL=C
  local nf="$1" before="$2" rows="$3" after="$4" line n=0 i=0 tabs
  # The fallback reads the LATEST list, so a pane that appeared mid-read is
  # listed and one that vanished is not.
  if [ -n "$after" ]; then
    while IFS= read -r line; do ROOST_JSONOUT_IDS[n]="$line"; n=$((n + 1)); done <<EOF
$after
EOF
  fi
  [ "$before" = "$after" ] || return 1
  [ "$n" -gt 0 ] || return 0
  while IFS= read -r line; do
    [ "$i" -lt "$n" ] || return 1
    tabs="${line//[!$'\t']/}"
    [ "${#tabs}" -eq $((nf - 1)) ] || return 1
    case "$line" in
      "${ROOST_JSONOUT_IDS[i]}"$'\t'*) ;;
      *) return 1 ;;
    esac
    ROOST_JSONOUT_ROWS[i]="$line"; i=$((i + 1))
  done <<EOF
$rows
EOF
  [ "$i" -eq "$n" ] || return 1
  return 0
}

# roost_jsonout_split ROW -> ROOST_JSONOUT_F[0..], split on TAB. Not `IFS=$'\t'
# read`: tab is IFS whitespace, so runs of tabs collapse and every empty field
# -- an unset @agent_state, an unset @roost-name -- would vanish and shift the
# rest left.
roost_jsonout_split() {
  local LC_ALL=C
  local rest="$1" k=0
  ROOST_JSONOUT_F=()
  while :; do
    case "$rest" in
      *$'\t'*) ROOST_JSONOUT_F[k]="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"; k=$((k + 1)) ;;
      *) ROOST_JSONOUT_F[k]="$rest"; return 0 ;;
    esac
  done
}

# --- screen -------------------------------------------------------------------

# roost_jsonout_screen TARGET LINES -> ROOST_JSONOUT_TEXT, the same lines
# bin/roost's screen_dump prints, without the final newline.
#
# It fails exactly where screen_dump fails -- a target tmux cannot find, a LINES
# tail refuses -- with the same message from the same program on stderr, with
# ONE exception: a blank screen. screen_dump's `grep -v` selects nothing there
# and exits 1, and under `pipefail` the command exits 1 with no output at all.
# The design settled that JSON mode answers that case with exit 0 and an empty
# "text": an idle pane is a result, not a failure. The human mode's exit 1 is
# untouched and tracked as its own bug.
roost_jsonout_screen() {
  local raw kept
  raw="$(t capture-pane -p -t "$1")" || return 1
  kept="$(printf '%s\n' "$raw" | grep -v '^[[:space:]]*$')" || kept=""
  ROOST_JSONOUT_TEXT="$(printf '%s\n' "$kept" | tail -n "$2")" || return 1
}

# --- status -------------------------------------------------------------------

# roost_jsonout_status -> the whole `roost status --json` document.
#
# Pane fields are read by format, exactly as the human `roost status` reads them
# (#{@agent_state}, #{@roost-name}), in both the one-call path and the fallback,
# so the two modes can never disagree about a value.
roost_jsonout_status() {
  # No `local LC_ALL=C` here: this function runs tmux. See the file header.
  # Nothing below needs it -- the byte work happens in roost_jsonout__trust,
  # roost_jsonout_split, roost_jsonout_int and roost_jsonout_encode, which set
  # it themselves.
  local kind=path trusted id k doc sep
  local -a strs s_name s_win s_att p_id p_sess p_wid p_widx p_wname p_pidx p_state p_since p_cmd p_name
  local ns=0 np=0 j
  case "$_SOCKET_FLAG" in -L) kind=name ;; esac
  strs=(status "$SOCKET" "$kind")

  if ! server_running; then
    roost_jsonout_encode "${strs[@]}" || roost_jsonout_fail status
    printf '{"schema":%s,"command":%s,"running":false,"socket":%s,"socket_kind":%s,"sessions":[],"panes":[]}\n' \
      "$ROOST_JSON_SCHEMA" "${ROOST_JSONOUT_STR[0]}" "${ROOST_JSONOUT_STR[1]}" "${ROOST_JSONOUT_STR[2]}"
    return 0
  fi

  # Sessions: id, name, windows, attached clients.
  trusted=0
  roost_jsonout_list 4 '#{session_id}' $'#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}' list-sessions && trusted=1 || true
  k=0
  while [ "$k" -lt "${#ROOST_JSONOUT_IDS[@]}" ]; do
    id="${ROOST_JSONOUT_IDS[k]}"
    if [ "$trusted" -eq 1 ]; then
      roost_jsonout_split "${ROOST_JSONOUT_ROWS[k]}"
    else
      # One field per call. A session that vanished between the listing and
      # here is dropped rather than reported with empty fields.
      ROOST_JSONOUT_F=("$(t display-message -p -t "$id" '#{session_id}' 2>/dev/null || true)")
      if [ "${ROOST_JSONOUT_F[0]}" != "$id" ]; then k=$((k + 1)); continue; fi
      ROOST_JSONOUT_F[1]="$(t display-message -p -t "$id" '#{session_name}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[2]="$(t display-message -p -t "$id" '#{session_windows}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[3]="$(t display-message -p -t "$id" '#{session_attached}' 2>/dev/null || true)"
    fi
    s_name[ns]="${ROOST_JSONOUT_F[1]}"; s_win[ns]="${ROOST_JSONOUT_F[2]}"; s_att[ns]="${ROOST_JSONOUT_F[3]}"
    ns=$((ns + 1)); k=$((k + 1))
  done

  # Panes: the ten fields of the design, in its order. The free-form ones --
  # state, command, name -- sit at the end only for readability; the tab check
  # guards every field wherever it is.
  trusted=0
  roost_jsonout_list 10 '#{pane_id}' $'#{pane_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{pane_index}\t#{@agent_state}\t#{@agent_since}\t#{pane_current_command}\t#{@roost-name}' list-panes -a && trusted=1 || true
  k=0
  while [ "$k" -lt "${#ROOST_JSONOUT_IDS[@]}" ]; do
    id="${ROOST_JSONOUT_IDS[k]}"
    if [ "$trusted" -eq 1 ]; then
      roost_jsonout_split "${ROOST_JSONOUT_ROWS[k]}"
    else
      ROOST_JSONOUT_F=("$(t display-message -p -t "$id" '#{pane_id}' 2>/dev/null || true)")
      if [ "${ROOST_JSONOUT_F[0]}" != "$id" ]; then k=$((k + 1)); continue; fi
      ROOST_JSONOUT_F[1]="$(t display-message -p -t "$id" '#{session_name}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[2]="$(t display-message -p -t "$id" '#{window_id}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[3]="$(t display-message -p -t "$id" '#{window_index}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[4]="$(t display-message -p -t "$id" '#{window_name}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[5]="$(t display-message -p -t "$id" '#{pane_index}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[6]="$(t display-message -p -t "$id" '#{@agent_state}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[7]="$(t display-message -p -t "$id" '#{@agent_since}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[8]="$(t display-message -p -t "$id" '#{pane_current_command}' 2>/dev/null || true)"
      ROOST_JSONOUT_F[9]="$(t display-message -p -t "$id" '#{@roost-name}' 2>/dev/null || true)"
    fi
    p_id[np]="${ROOST_JSONOUT_F[0]}"; p_sess[np]="${ROOST_JSONOUT_F[1]}"; p_wid[np]="${ROOST_JSONOUT_F[2]}"
    p_widx[np]="${ROOST_JSONOUT_F[3]}"; p_wname[np]="${ROOST_JSONOUT_F[4]}"; p_pidx[np]="${ROOST_JSONOUT_F[5]}"
    p_state[np]="${ROOST_JSONOUT_F[6]}"; p_since[np]="${ROOST_JSONOUT_F[7]}"; p_cmd[np]="${ROOST_JSONOUT_F[8]}"
    p_name[np]="${ROOST_JSONOUT_F[9]}"
    np=$((np + 1)); k=$((k + 1))
  done

  # Every string in the document, in document order, through ONE awk call.
  k=0; while [ "$k" -lt "$ns" ]; do strs+=("${s_name[k]}"); k=$((k + 1)); done
  k=0
  while [ "$k" -lt "$np" ]; do
    strs+=("${p_id[k]}" "${p_sess[k]}" "${p_wid[k]}" "${p_wname[k]}" "${p_state[k]}" "${p_cmd[k]}" "${p_name[k]}")
    k=$((k + 1))
  done
  roost_jsonout_encode "${strs[@]}" || roost_jsonout_fail status

  doc="{\"schema\":$ROOST_JSON_SCHEMA,\"command\":${ROOST_JSONOUT_STR[0]},\"running\":true,\"socket\":${ROOST_JSONOUT_STR[1]},\"socket_kind\":${ROOST_JSONOUT_STR[2]},\"sessions\":["
  j=3; k=0; sep=""
  while [ "$k" -lt "$ns" ]; do
    doc="$doc$sep{\"name\":${ROOST_JSONOUT_STR[j]}"; j=$((j + 1))
    roost_jsonout_int "${s_win[k]}"; doc="$doc,\"windows\":$ROOST_JSONOUT_INT"
    roost_jsonout_int "${s_att[k]}"; doc="$doc,\"attached_clients\":$ROOST_JSONOUT_INT}"
    sep=","; k=$((k + 1))
  done
  doc="$doc],\"panes\":["
  k=0; sep=""
  while [ "$k" -lt "$np" ]; do
    doc="$doc$sep{\"id\":${ROOST_JSONOUT_STR[j]},\"session\":${ROOST_JSONOUT_STR[j + 1]},\"window_id\":${ROOST_JSONOUT_STR[j + 2]}"
    roost_jsonout_int "${p_widx[k]}"; doc="$doc,\"window_index\":$ROOST_JSONOUT_INT"
    doc="$doc,\"window_name\":${ROOST_JSONOUT_STR[j + 3]}"
    roost_jsonout_int "${p_pidx[k]}"; doc="$doc,\"pane_index\":$ROOST_JSONOUT_INT"
    # name is null when unset OR empty: the human line treats both alike.
    if [ -n "${p_name[k]}" ]; then doc="$doc,\"name\":${ROOST_JSONOUT_STR[j + 6]}"; else doc="$doc,\"name\":null"; fi
    doc="$doc,\"command\":${ROOST_JSONOUT_STR[j + 5]}"
    if [ -n "${p_state[k]}" ]; then doc="$doc,\"state\":${ROOST_JSONOUT_STR[j + 4]}"; else doc="$doc,\"state\":null"; fi
    roost_jsonout_int "${p_since[k]}"; doc="$doc,\"since\":$ROOST_JSONOUT_INT}"
    j=$((j + 7)); sep=","; k=$((k + 1))
  done
  printf '%s]}\n' "$doc"
}
