#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$HERE/scripts/amux-doctor"

# reports the running tmux version
out="$("$DOC" 2>&1 || true)"
assert_contains "$out" "tmux" "doctor reports on tmux"

# a faked old tmux makes the required check fail (non-zero exit)
marker="$(mktemp)"
shimdir="$(mktemp -d /tmp/amx.XXXX)"
cat > "$shimdir/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "-V" ] && { echo "tmux 3.0a"; exit 0; }
exit 0
EOF
chmod +x "$shimdir/tmux"
PATH="$shimdir:$PATH" "$DOC" >/dev/null 2>&1
assert_eq "$?" "1" "doctor exits non-zero on tmux < 3.1"
rm -rf "$shimdir"

# a faked new tmux passes the version gate
shimdir="$(mktemp -d /tmp/amx.XXXX)"
cat > "$shimdir/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "-V" ] && { echo "tmux 3.4"; exit 0; }
exit 0
EOF
chmod +x "$shimdir/tmux"
out="$(COLORTERM=truecolor PATH="$shimdir:$PATH" "$DOC" 2>&1)"
assert_contains "$out" "3.4" "doctor accepts tmux 3.4"
rm -rf "$shimdir"
