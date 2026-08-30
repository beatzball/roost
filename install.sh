#!/bin/sh
# roost installer — clone (if needed) and put `roost` on your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/beatzball/roost/main/install.sh | sh
#   ./install.sh                      # from inside a clone
#   ./install.sh --symlink            # symlink into a PATH dir instead
#   ./install.sh --dry-run            # print what would happen, change nothing
#   ./install.sh --no-wire            # place roost, but do not wire the agents
#
# Deliberately POSIX sh, not bash. The piped-from-curl form runs under
# whatever /bin/sh is, and on Debian derivatives that is dash -- a bashism here
# would break the one install path most people use.
#
# roost itself still requires bash; this script only has to *place* it.
set -eu

REPO_URL="https://github.com/beatzball/roost.git"
DEFAULT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/roost"

mode=path          # path | symlink
dry=0
dir=""
link_dir=""
wire=1
# What the wiring step ended up doing, for the closing block to report
# honestly. off (--no-wire) | dry | asked (a human answered the installer's
# own prompt, so only they know what they said) | wired | failed.
wire_state=off
# Filled in by whichever mode placed roost, so the closing block can name what
# actually happened rather than guessing.
placed="roost is installed"
reload="Next:"

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf 'roost install: %s\n' "$*" >&2; exit 1; }

# `eval` on a command we build ourselves, so --dry-run can print instead of run.
run() {
  if [ "$dry" -eq 1 ]; then printf '  would run: %s\n' "$*"; else eval "$@"; fi
}

usage() {
  cat <<'USAGE'
usage: install.sh [--dir PATH] [--symlink [DIR]] [--dry-run] [--no-wire]

  --dir PATH        where to clone roost (default: ~/.local/share/roost)
  --symlink [DIR]   symlink bin/roost into DIR instead of editing a shell rc
                    (default: the first writable directory already on PATH)
  --dry-run         print what would happen, change nothing
  --no-wire         do not wire your agents; place roost and stop. Run
                    `roost install` yourself whenever you want that done
  -h, --help        this text
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     dir="${2:?--dir needs a path}"; shift 2 ;;
    --dir=*)   dir="${1#--dir=}"; shift ;;
    --symlink) mode=symlink
               # An optional value: only consume the next argument when it is
               # not itself a flag, so `--symlink --dry-run` still works.
               case "${2:-}" in -*|'') shift ;; *) link_dir="$2"; shift 2 ;; esac ;;
    --symlink=*) mode=symlink; link_dir="${1#--symlink=}"; shift ;;
    --dry-run) dry=1; shift ;;
    --no-wire) wire=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Locate or fetch the checkout
# ---------------------------------------------------------------------------

# Running from inside a clone? Then install THAT, rather than cloning a second
# copy somewhere else and leaving the user with two.
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -z "$dir" ] && [ -x "$here/bin/roost" ] && [ -f "$here/tmux/roost.conf" ]; then
  dir="$here"
  say "roost: installing from this checkout"
  info "$dir"
else
  dir="${dir:-$DEFAULT_DIR}"
  if [ -x "$dir/bin/roost" ]; then
    say "roost: already cloned"
    info "$dir"
    run "git -C '$dir' pull --ff-only --quiet" || warn "could not update; keeping what is there"
  else
    command -v git >/dev/null 2>&1 || die "git is required to clone roost"
    say "roost: cloning"
    info "$REPO_URL -> $dir"
    run "mkdir -p '$(dirname "$dir")'"
    run "git clone --quiet '$REPO_URL' '$dir'"
  fi
fi

bin_dir="$dir/bin"
[ "$dry" -eq 1 ] || [ -x "$bin_dir/roost" ] || die "no executable at $bin_dir/roost"

# ---------------------------------------------------------------------------
# 2. Wiring, shared by both placement modes below
# ---------------------------------------------------------------------------

# Placing `roost` on PATH is only half an install: until each harness has
# roost's adapter, no pane badges and the thing looks broken. `roost install`
# is the command that does that half, and running it here is the difference
# between one step and three. Editing a dotfile without being asked is already
# what the PATH step does, so this is the same liberty, not a new one.
#
# Invoked by absolute path, never as `roost install`: the rc line appended
# below does not affect THIS shell, and in --symlink mode the link directory
# may not be on PATH at all.

# The block printed before an unattended wiring run. Loud on purpose -- this
# is the one path where nobody was asked, so the user has to be able to read
# what happened and undo it.
wire_notice() {
  say ""
  say "  ------------------------------------------------------------------"
  say "  WIRING YOUR AGENTS -- nothing to answer, so nothing will be asked"
  say ""
  say "  This install is piped (curl | sh), so stdin is the script itself"
  say "  and a prompt here would eat the rest of it. Wiring therefore runs"
  say "  unattended, exactly as \`roost install --yes\` would."
  say ""
  # The list is complete on purpose, EXTENSIONS included. This is the one path
  # where nobody was asked, so this block is the whole of what the user has to
  # check the run against -- and the flag is a write in a file the symlink half
  # never touches, backed up like any other. A notice that under-lists what it
  # writes is worse than no notice: it reads as an inventory.
  say "  It touches only harnesses you already have installed, and only"
  say "  their own agent config: one symlink each for opencode, pi and"
  say "  copilot, roost's hook merged into claude's and codex's settings,"
  say "  and copilot's EXTENSIONS feature flag turned on."
  say "  Every file it edits is backed up first, beside itself, as"
  say "  .roost-bak-<timestamp>. Anything that is not roost's own is left"
  say "  exactly as it was found and reported instead."
  say ""
  say "  Skip this entirely: re-run install.sh with --no-wire."
  say "  ------------------------------------------------------------------"
  say ""
}

wire_agents() {
  [ "$wire" -eq 1 ] || { wire_state=off; return 0; }

  # --dry-run against a checkout that was never cloned: there is no binary to
  # invoke, and creating one to ask would be the opposite of a dry run.
  if [ ! -x "$bin_dir/roost" ]; then
    say ""
    printf '  would run: %s install --dry-run\n' "$bin_dir/roost"
    wire_state=dry
    return 0
  fi

  say ""
  say "roost: wiring your agents"

  # --dry-run reaches the installer's OWN --dry-run rather than skipping the
  # step. Skipping it would make the one flag whose job is to show the whole
  # plan the one flag that hides half of it.
  if [ "$dry" -eq 1 ]; then
    wire_state=dry
    # stdin from /dev/null for the same reason as the unattended branch below:
    # under `cat install.sh | sh` this script's stdin IS the rest of the
    # script, and a dry run must not be able to eat it either.
    "$bin_dir/roost" install --dry-run </dev/null || wire_failed $?
    return 0
  fi

  if [ -t 0 ]; then
    # A terminal: let the installer ask for itself. Its prompt lists every
    # file it is about to touch, which is better than anything paraphrased
    # here -- and only the person who answered it knows what they said, which
    # is why this state is `asked` and not `wired`.
    wire_state=asked
    "$bin_dir/roost" install || wire_failed $?
  else
    wire_notice
    wire_state=wired
    # stdin from /dev/null, not inherited. Under `curl | sh` this script's
    # stdin is the remaining bytes of the script, and a child that read even
    # one of them would truncate the installer mid-run. --yes means the
    # installer asks nothing today; this makes that structural rather than a
    # promise about someone else's file.
    "$bin_dir/roost" install --yes </dev/null || wire_failed $?
  fi
}

# A failed wiring run must not undo a PATH step that already worked. roost is
# placed and usable; say what is missing and how to finish it.
wire_failed() {
  wire_state=failed
  warn "roost install exited $1 -- see its output above"
}

# The closing block. It reports what the wiring step actually did, because
# "Done" followed by advice that ignores it is how the old three-step install
# read.
next_steps() {
  say ""
  case "$wire_state" in
    off)
      say "Done. $placed. Your agents were not wired: --no-wire."
      say "$reload"
      info "roost install   # wire your agents to this checkout"
      info "roost doctor    # tmux version, truecolor, fzf, and the badge hooks"
      ;;
    dry)
      say "Done. Nothing was written: this was a --dry-run."
      ;;
    failed)
      say "Done. $placed, but the wiring did not finish."
      say "$reload"
      info "roost install   # finish wiring your agents"
      info "roost doctor    # tmux version, truecolor, fzf, and the badge hooks"
      ;;
    asked)
      say "Done. $placed, and the wiring above is as you answered it."
      say "$reload"
      info "roost doctor    # tmux version, truecolor, fzf, and the badge hooks"
      ;;
    *)
      say "Done. $placed, and the agents listed above are wired to it."
      say "$reload"
      info "roost doctor    # tmux version, truecolor, fzf, and the badge hooks"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 3a. Symlink mode
# ---------------------------------------------------------------------------

if [ "$mode" = symlink ]; then
  if [ -z "$link_dir" ]; then
    # Prefer a directory already on PATH that we can actually write to.
    # /usr/local/bin is the traditional answer and is frequently root-owned,
    # which is why this checks rather than assuming.
    for cand in "$HOME/.local/bin" /usr/local/bin /opt/homebrew/bin; do
      case ":$PATH:" in *":$cand:"*) [ -w "$cand" ] && { link_dir="$cand"; break; } ;; esac
    done
    [ -n "$link_dir" ] || die "no writable directory on PATH; pass one: --symlink DIR"
  fi
  [ -d "$link_dir" ] || run "mkdir -p '$link_dir'"
  say ""
  say "roost: linking"
  info "$link_dir/roost -> $bin_dir/roost"
  run "ln -sf '$bin_dir/roost' '$link_dir/roost'"
  case ":$PATH:" in
    *":$link_dir:"*) ;;
    *) warn "$link_dir is not on your PATH — add it, or re-run without --symlink" ;;
  esac
  placed="roost is linked into $link_dir"
  wire_agents
  next_steps
  exit 0
fi

# ---------------------------------------------------------------------------
# 3b. PATH mode — work out which rc file this user's shell actually reads
# ---------------------------------------------------------------------------

# $SHELL is the login shell, which is what owns the rc file we want to edit.
# The shell running this script is often /bin/sh via the curl pipe, so it is
# the wrong thing to look at.
shell_name=$(basename "${SHELL:-}")

case "$shell_name" in
  zsh)
    # ZDOTDIR relocates zsh's whole dotfile directory; honouring it is the
    # difference between configuring the user's zsh and writing a file they
    # will never source.
    rc="${ZDOTDIR:-$HOME}/.zshrc"
    line="export PATH=\"$bin_dir:\$PATH\""
    ;;
  bash)
    # macOS terminals start LOGIN shells, which read ~/.bash_profile and never
    # ~/.bashrc; most Linux terminals do the opposite. Prefer whichever the
    # user already has, then fall back per platform.
    if [ -f "$HOME/.bashrc" ] && [ "$(uname -s)" != Darwin ]; then
      rc="$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
      rc="$HOME/.bash_profile"
    elif [ -f "$HOME/.bashrc" ]; then
      rc="$HOME/.bashrc"
    elif [ "$(uname -s)" = Darwin ]; then
      rc="$HOME/.bash_profile"
    else
      rc="$HOME/.bashrc"
    fi
    line="export PATH=\"$bin_dir:\$PATH\""
    ;;
  fish)
    rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
    # fish has no `export`; fish_add_path is idempotent by design.
    line="fish_add_path $bin_dir"
    ;;
  *)
    say ""
    warn "unrecognised shell: ${shell_name:-unknown}"
    say "  Add this to your shell's startup file by hand:"
    say ""
    info "export PATH=\"$bin_dir:\$PATH\""
    say ""
    exit 0
    ;;
esac

say ""
say "roost: shell is $shell_name"
info "$rc"

# Already there? Say so and stop -- re-running the installer must not stack up
# duplicate PATH entries.
if [ -f "$rc" ] && grep -qF "$bin_dir" "$rc" 2>/dev/null; then
  info "already on PATH in that file — nothing to do"
else
  run "mkdir -p '$(dirname "$rc")'"
  if [ "$dry" -eq 1 ]; then
    printf '  would append: %s\n' "$line"
  else
    # A blank line first so this never lands glued to the user's last line.
    printf '\n# roost — https://roosting.dev\n%s\n' "$line" >> "$rc"
    info "added to PATH"
  fi
fi

placed="roost is on your PATH"
reload="Open a new terminal (or: exec $shell_name), then:"
wire_agents
next_steps
