#!/usr/bin/env bash
# `roost ssh HOST ARGS...` must reach the remote as a LOGIN shell running
# roost with exactly the words it was given. Two things went wrong before:
# `ssh -t HOST roost "$@"` ran in a non-login shell, so a PATH or LANG set in
# the remote's profile never arrived and roost itself was "command not found";
# and ssh's join of its arguments into one line split a multi-word prompt.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

work="$(mktemp -d /tmp/amx.XXXX)"
trap 'rm -rf "$work"' EXIT

# A fake ssh that records its arguments, one per line, and runs nothing.
mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<EOF
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done > "$work/ssh.args"
EOF
chmod +x "$work/bin/ssh"

# --- what ssh is handed ------------------------------------------------------

PATH="$work/bin:$PATH" "$ROOST" ssh deploy@devbox send %3 "review the diff" >/dev/null 2>&1
args="$(cat "$work/ssh.args")"
assert_eq "$(sed -n 1p "$work/ssh.args")" "-t" "ssh gets -t first, for the remote tmux"
assert_eq "$(sed -n 2p "$work/ssh.args")" "deploy@devbox" "the destination is passed through untouched, user@host included"
assert_eq "$(wc -l < "$work/ssh.args" | tr -d ' ')" "3" "everything after the host is ONE remote command line"
line="$(sed -n 3p "$work/ssh.args")"
assert_prefix "$line" '"$SHELL" -lc ' "the remote line starts that user's own login shell"
assert_contains "$line" "'review the diff'" "a multi-word prompt is quoted as one word"

"$ROOST" ssh 2>/dev/null
assert_eq "$?" "1" "ssh with no host is a usage error"

# --- what the remote shell makes of it ---------------------------------------
#
# Run the recorded line the way sshd would: through a shell's -c. The fake
# roost it finds is only on PATH through ~/.profile, so if the line were not a
# login shell the command would not be found at all -- which is the bug.

mkdir -p "$work/home" "$work/remote-bin"
cat > "$work/remote-bin/roost" <<EOF
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done > "$work/roost.args"
EOF
chmod +x "$work/remote-bin/roost"
printf 'PATH="%s:$PATH"\n' "$work/remote-bin" > "$work/home/.profile"

tricky="it's \"quoted\" and \$HOME stays literal"
PATH="$work/bin:$PATH" "$ROOST" ssh devbox send %3 "$tricky" --json >/dev/null 2>&1
line="$(sed -n 3p "$work/ssh.args")"
rm -f "$work/roost.args"
( cd "$work" && HOME="$work/home" SHELL=/bin/sh PATH="/usr/bin:/bin" /bin/sh -c "$line" )
assert_eq "$([ -e "$work/roost.args" ] && echo found)" "found" "roost is found through the remote profile, i.e. a login shell ran"
assert_eq "$(sed -n 1p "$work/roost.args")" "send" "first word arrives"
assert_eq "$(sed -n 2p "$work/roost.args")" "%3" "pane id arrives"
assert_eq "$(sed -n 3p "$work/roost.args")" "$tricky" "quotes, apostrophes and \$ arrive byte-for-byte as one word"
assert_eq "$(sed -n 4p "$work/roost.args")" "--json" "a flag after the prompt stays a separate word"
assert_eq "$(wc -l < "$work/roost.args" | tr -d ' ')" "4" "no extra words were made"

# No arguments at all: the remote runs bare `roost`, which attaches its view.
PATH="$work/bin:$PATH" "$ROOST" ssh devbox >/dev/null 2>&1
line="$(sed -n 3p "$work/ssh.args")"
assert_eq "$line" "\"\$SHELL\" -lc 'roost'" "no args means a bare roost on the remote"
