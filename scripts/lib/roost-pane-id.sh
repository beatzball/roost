# Stable pane addresses (#247). The tmux pane number is still the handle used
# for commands on a server. Keep stable addresses and their lookup here so a
# server selector can choose a socket before doing the same lookup later.

ROOST_PANE_ID_ALPHABET=0123456789abcdefghjkmnpqrstvwxyz

# The running check is s <- x*s XOR digit in GF(32), reduced modulo
# x^5 + x^2 + 1. Append x*s to make the final residue zero. A changed
# digit adds a nonzero difference multiplied by a power of x, which cannot
# become zero. Swapping distinct adjacent digits adds their nonzero XOR
# multiplied by (x+1) and a power of x, also nonzero. This includes a swap
# with the check digit. Separators and folded spellings encode no digit.
roost_pane_id__residue() {
  local digits="$1" i=0 s=0 prefix
  while [ "$i" -lt "${#digits}" ]; do
    prefix="${ROOST_PANE_ID_ALPHABET%%"${digits:i:1}"*}"
    s=$((s << 1))
    if [ "$s" -ge 32 ]; then s=$((s ^ 37)); fi
    s=$((s ^ ${#prefix}))
    i=$((i + 1))
  done
  ROOST_PANE_ID_RESIDUE="$s"
}

# Normalize into ROOST_PANE_ID. The prefix is syntax, not a check digit.
roost_pane_id_parse() {
  local LC_ALL=C compact="${1//-/}" digits
  ROOST_PANE_ID=""
  case "$compact" in *[ABCDEFGHIJKLMNOPQRSTUVWXYZilo]*)
    compact="$(printf '%s' "$compact" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZilo' 'abcdefgh1jk1mn0pqrstuvwxyz110')" ;;
  esac
  case "$compact" in p???????) ;; *) return 1 ;; esac
  digits="${compact#p}"
  case "$digits" in *[!0123456789abcdefghjkmnpqrstvwxyz]*) return 1 ;; esac
  roost_pane_id__residue "$digits"
  [ "$ROOST_PANE_ID_RESIDUE" = 0 ] || return 1
  ROOST_PANE_ID="p-${digits:0:3}-${digits:3:3}-${digits:6:1}"
}

# Reserve the address-shaped namespace. A name outside it, or a qualified
# tmux target, keeps its usual interpretation. In particular a wrong check
# character in this namespace must never fall back to a tmux name match.
roost_pane_id_target() {
  local LC_ALL=C compact="${1//-/}" body
  case "$1" in
    *:*|*.*) return 1 ;;
    [pP]-???-???-*) return 0 ;;
  esac
  case "$compact" in [pP]???????) ;; *) return 1 ;; esac
  body="${compact:1:6}"
  # A compact spelling uses the Crockford alphabet. Try its folded form
  # before treating a word like "postgres" as an ordinary window name.
  case "$body" in
    *[!0123456789ABCDEFGHJKMNPQRSTVWXYZabcdefghjkmnpqrstvwxyz]*) roost_pane_id_parse "$1" ;;
    *) return 0 ;;
  esac
}

roost_pane_id__new() {
  local bytes byte digits=""
  bytes="$(od -An -N6 -tu1 /dev/urandom)" || return 1
  for byte in $bytes; do digits="$digits${ROOST_PANE_ID_ALPHABET:byte%32:1}"; done
  [ "${#digits}" = 6 ] || return 1
  roost_pane_id__residue "${digits}0"
  ROOST_PANE_ID="p-${digits:0:3}-${digits:3:3}-${ROOST_PANE_ID_ALPHABET:ROOST_PANE_ID_RESIDUE:1}"
}

# An empty marker records each issued ID permanently. Bash noclobber creates
# it atomically, including when two separate tmux servers share this state
# directory. Bucket by the first two digits so no directory holds the whole
# set and allocation never reads a growing list. A process that dies after
# reservation burns the ID, which is safe even if tmux already stored it.
roost_pane_id__bucket() {
  local root="${XDG_STATE_HOME:-}"
  case "$root" in /*) ;; *)
    case "${HOME:-}" in /*) root="$HOME/.local/state" ;; *) return 1 ;; esac ;;
  esac
  [ -n "${root//\//}" ] || return 1
  ROOST_PANE_ID_BUCKET="$root/roost/pane-ids/${1:2:2}"
  (umask 077; mkdir -p "$ROOST_PANE_ID_BUCKET")
}

roost_pane_id__reserve() {
  (umask 077; set -C; : > "$ROOST_PANE_ID_BUCKET/$1") 2>/dev/null
}

# Resolve through pane-owned options only. Linked windows can show the same
# pane twice. Two distinct panes claiming an ID must never get a delivery.
roost_pane_id_find() {
  local tmux_call="$1" want="$2" rows pane stored
  ROOST_PANE_ID_PANE=""
  rows="$("$tmux_call" list-panes -a -F '#{pane_id} #{@roost-id}' 2>/dev/null)" || return 1
  while IFS=' ' read -r pane stored; do
    [ "$stored" = "$want" ] && [ "$pane" != "$ROOST_PANE_ID_PANE" ] || continue
    [ "$("$tmux_call" show-options -pqv -t "$pane" @roost-id 2>/dev/null)" = "$want" ] || continue
    [ -z "$ROOST_PANE_ID_PANE" ] || return 2
    ROOST_PANE_ID_PANE="$pane"
  done <<< "$rows"
  [ -n "$ROOST_PANE_ID_PANE" ]
}

# Put the duplicate check and stamp on one tmux command queue. The registry
# coordinates new IDs across servers. This check also covers a restore of an
# already issued ID and IDs already on this server from another state root.
# -o makes concurrent adoption of the same pane keep the first stamp.
roost_pane_id__stamp() {
  local tmux_call="$1" pane="$2" id="$3"
  case "$pane" in %*) ;; *) return 1 ;; esac
  case "${pane#%}" in ''|*[!0123456789]*) return 1 ;; esac
  "$tmux_call" if-shell -F -t "$pane" "#{m:* $id *,#{S:#{W:#{P: #{@roost-id} }}}}}" '' \
    "set-option -po -t $pane @roost-id $id" >/dev/null 2>&1 || return 1
  ROOST_PANE_ID="$("$tmux_call" show-options -pqv -t "$pane" @roost-id 2>/dev/null)"
}

# Adopt or allocate. A placing placeholder has yet to receive the ID from
# its shape block. Let restore assign it before SessionStart or status can.
roost_pane_id_ensure() {
  local tmux_call="$1" pane="$2" launch id tries=0
  ROOST_PANE_ID="" ROOST_PANE_ID_NEW=0
  [ -n "$pane" ] || return 1
  id="$("$tmux_call" show-options -pqv -t "$pane" @roost-id 2>/dev/null)" || return 1
  if [ -n "$id" ]; then roost_pane_id_parse "$id" && [ "$id" = "$ROOST_PANE_ID" ]; return; fi
  if [ "${3:-}" != restore ]; then
    launch="$("$tmux_call" display-message -p -t "$pane" '#{pane_start_command}' 2>/dev/null)" || return 1
    case "$launch" in *roost-placeholder*' --placing') return 1 ;; esac
  fi
  while [ "$tries" -lt 64 ]; do
    tries=$((tries + 1))
    roost_pane_id__new || return 1
    id="$ROOST_PANE_ID"
    ROOST_PANE_ID=""
    roost_pane_id__bucket "$id" || return 1
    if ! roost_pane_id__reserve "$id"; then
      [ -e "$ROOST_PANE_ID_BUCKET/$id" ] && continue
      return 1
    fi
    roost_pane_id__stamp "$tmux_call" "$pane" "$id" || return 1
    if [ -n "$ROOST_PANE_ID" ]; then
      ROOST_PANE_ID_NEW=1
      return 0
    fi
  done
  return 1
}

roost_pane_id_remember() {
  local id="$1"
  roost_pane_id__bucket "$id" || return 1
  roost_pane_id__reserve "$id" || [ -f "$ROOST_PANE_ID_BUCKET/$id" ]
}

roost_pane_id_restore() {
  local tmux_call="$1" pane="$2" id="$3"
  if [ -z "$id" ]; then roost_pane_id_ensure "$tmux_call" "$pane" restore; return; fi
  roost_pane_id_parse "$id" || return 1
  id="$ROOST_PANE_ID"
  roost_pane_id_remember "$id" || return 1
  roost_pane_id__stamp "$tmux_call" "$pane" "$id" && [ "$ROOST_PANE_ID" = "$id" ]
}
