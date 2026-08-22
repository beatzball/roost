#!/bin/sh
# roost installer — clone (if needed) and put `roost` on your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/beatzball/roost/main/install.sh | sh
#   ./install.sh                      # from inside a clone
#   ./install.sh --symlink            # symlink into a PATH dir instead
#   ./install.sh --dry-run            # print what would happen, change nothing
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
usage: install.sh [--dir PATH] [--symlink [DIR]] [--dry-run]

  --dir PATH        where to clone roost (default: ~/.local/share/roost)
  --symlink [DIR]   symlink bin/roost into DIR instead of editing a shell rc
                    (default: the first writable directory already on PATH)
  --dry-run         print what would happen, change nothing
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
# 2a. Symlink mode
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
  say ""
  say "Done. Next:"
  info "roost doctor    # check tmux version, truecolor, fzf, hooks"
  info "roost init      # pick a theme and print the Claude Code hooks"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2b. PATH mode — work out which rc file this user's shell actually reads
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

say ""
say "Done. Open a new terminal (or: exec $shell_name), then:"
info "roost doctor    # check tmux version, truecolor, fzf, hooks"
info "roost init      # pick a theme and print the Claude Code hooks"
