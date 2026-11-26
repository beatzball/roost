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
  roost_pane_id_target "$1" || return 1
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
  # Compact forms keep the initial hyphen. Other p-prefixed words such as
  # "postgres" are ordinary window names regardless of their checksum.
  case "$1" in [pP]-*) return 0 ;; *) return 1 ;; esac
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

# Backfill a record that predates adoption. A later identity report writes
# its own ID, including when a different conversation takes over the pane.
roost_pane_id__backfill_record() (
  [ "${ROOST_RECORD_DIR-unset}" != "" ] || exit 0
  local tmux_call="$1" pane="$2" id="$3" row boot
  . "${BASH_SOURCE[0]%/*}/roost-record.sh"
  roost_record_root
  [ -n "$ROOST_RECORD_ROOT" ] || exit 0
  row="$("$tmux_call" display-message -p -t "$pane" '#{start_time}-#{pid} #{pane_id} #{@roost-id}' 2>/dev/null)" || exit 0
  boot="${row%% *}"
  [ "$row" = "$boot $pane $id" ] || exit 0
  roost_record_pane_dir "$boot" "$pane" && roost_record_schema "$ROOST_RECORD_PANE_DIR" || exit 0
  [ -f "$ROOST_RECORD_PANE_DIR/roost_id" ] || roost_record__put "$ROOST_RECORD_PANE_DIR/roost_id" "$id"$'\n'
)

# Resolve through pane-owned options only. Linked windows can show the same
# pane twice. Two distinct panes claiming an ID must never get a delivery.
roost_pane_id_find() {
  local tmux_call="$1" want="$2" rows pane stored boot
  ROOST_PANE_ID_PANE="" ROOST_PANE_ID_BOOT=""
  rows="$("$tmux_call" list-panes -a -F '#{pane_id} #{@roost-id} #{start_time}-#{pid}' 2>/dev/null)" || return 1
  while IFS=' ' read -r pane stored boot; do
    [ "$stored" = "$want" ] && [ "$pane" != "$ROOST_PANE_ID_PANE" ] || continue
    [ "$("$tmux_call" show-options -pqv -t "$pane" @roost-id 2>/dev/null)" = "$want" ] || continue
    [ -z "$ROOST_PANE_ID_PANE" ] || return 2
    [[ "$boot" =~ ^[0-9]+-[0-9]+$ ]] || continue
    ROOST_PANE_ID_PANE="$pane" ROOST_PANE_ID_BOOT="$boot"
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
      roost_pane_id__backfill_record "$tmux_call" "$pane" "$ROOST_PANE_ID" || true
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

# Move the original address in one server queue. A second visit to the same
# pane through a linked window is fine. A distinct claimant or a change of
# boot refuses the move, just as it would refuse a delivery.
roost_pane_id_move() {
  local tmux_call="$1" from="$2" to="$3" id="$4" boot="$5" fresh claims cond n
  for n in "$from" "$to"; do [[ "$n" =~ ^%[0-9]+$ ]] || return 1; done
  [[ "$boot" =~ ^[0-9]+-[0-9]+$ ]] || return 1
  roost_pane_id_parse "$id" && [ "$id" = "$ROOST_PANE_ID" ] || return 1
  for ((n=0; n<64; n++)); do
    roost_pane_id__new || return 1
    fresh="$ROOST_PANE_ID"
    roost_pane_id__bucket "$fresh" || return 1
    if roost_pane_id__reserve "$fresh"; then break; fi
    [ -e "$ROOST_PANE_ID_BUCKET/$fresh" ] || return 1
  done
  [ "$n" -lt 64 ] || return 1
  claims="#{S:#{W:#{P:#{?#{==:#{@roost-id},$id},#{?#{==:#{pane_id},$from},y,x},#{?#{==:#{@roost-id},$fresh},x,}}}}}"
  cond="#{&&:#{==:#{start_time}-#{pid}/#{pane_id},$boot/$to},#{m/r:^y+$,$claims}}"
  [ "$("$tmux_call" if-shell -F -t "$to" "$cond" \
    "set-option -p -t $from @roost-id $fresh ; set-option -p -t $to @roost-id $id ; display-message -p moved" '' 2>/dev/null)" = moved ]
}

roost_target_condition() {
  local cond="$1"
  if [ -n "${RW_STABLE_ID:-}" ]; then
    cond="#{&&:#{==:#{start_time}-#{pid}/#{pane_id}/#{@roost-id},$RW_STABLE_BOOT/$RW_TARGET/$RW_STABLE_ID},$cond}"
  fi
  printf '%s' "$cond"
}
