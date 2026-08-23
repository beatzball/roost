# roost-reply.sh — the one place that decides what goes into @roost-reply.
#
# Sourced by BOTH bin/roost (the `reply` subcommand) and
# scripts/roost-agent-state (the Claude Stop hook). Two copies of a truncation
# rule would drift, and the failure when they did would be a reply that is
# stored by one path and rejected by the other — silently, since every tmux
# call on both paths carries `|| true`.

# The cap exists because tmux rejects an over-long COMMAND, not an over-long
# value. Measured on tmux 3.6 (Darwin arm64, isolated -S socket) by binary
# search: a value of 16332 bytes is accepted and 16333 is rejected, with the
# whole `set-option -p -t %N @roost-reply <value>` command line making up the
# difference to 16384. 12288 leaves ~4KB of headroom for the command prefix,
# for a longer pane id, and for any field added here later.
#
# This is a BYTE budget. Every length and slice below therefore runs under
# LC_ALL=C, because bash's ${#var} and ${var:0:n} count CHARACTERS in a UTF-8
# locale — one emoji is one character to bash and four bytes to tmux, so a
# character-counted cap of 12288 could hand tmux 49152 bytes and be refused.
ROOST_REPLY_MAX="${ROOST_REPLY_MAX:-12288}"

# roost_reply_encode TEXT — print the value to store, truncating if needed.
#
# Truncation keeps the HEAD and marks itself. A reply cut from the front reads
# as if it began mid-sentence and the reader cannot tell that from a genuinely
# odd answer; a marked head-cut is honest and still readable. Silence is the
# one option ruled out — a quietly shortened reply is the same class of bug as
# the scraped screen this whole mechanism replaces.
roost_reply_encode() {
  # `local LC_ALL=C` really does switch ${#t} to bytes — bash calls setlocale on
  # assignment — and `local` scopes it to this function, so the caller's locale
  # is untouched.
  local LC_ALL=C
  local text="$1" n head

  n=${#text}
  [ "$n" -le "$ROOST_REPLY_MAX" ] && { printf '%s' "$text"; return 0; }

  head="${text:0:$ROOST_REPLY_MAX}"
  # Cut back to the last newline in the slice. A newline is a single ASCII byte
  # and can never appear INSIDE a multi-byte UTF-8 sequence, so this boundary
  # is provably not mid-character — which slicing at an arbitrary byte offset
  # is not. It also lands the cut at the end of a line, which reads better than
  # the middle of a word.
  #
  # If the first ROOST_REPLY_MAX bytes contain no newline at all, the raw byte
  # cut stands and the final character may be split in half. That needs a
  # single line longer than 12KB, and the damage is one mangled glyph sitting
  # immediately above the truncation marker — visible, bounded, and far less
  # bad than dropping the whole reply.
  case "$head" in
    *$'\n'*) head="${head%$'\n'*}" ;;
  esac

  printf '%s\n[roost: reply truncated — %s of %s bytes]' "$head" "$ROOST_REPLY_MAX" "$n"
}

# Only the encoding lives here, not the tmux call. The two callers reach their
# server differently — bin/roost through its own `t()` wrapper, which may be
# holding a socket NAME (-L roost), and roost-agent-state through the socket
# PATH it lifts out of $TMUX — so a shared store helper would have to plumb the
# flag through and would save one line. The truncation rule is the part that
# must not drift; `set-option -p ... 2>/dev/null || true` is the local idiom in
# both files already.
