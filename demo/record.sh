#!/usr/bin/env bash
# Record one demo, from a clean environment.
#
#   ./demo/record.sh first-run
#   ./demo/record.sh hero
#
# Always use this rather than running a prep script and vhs by hand: it
# re-runs itself under `env -i` (see demo_reexec_clean in demo/lib.sh), and it
# refuses to finish if any pane shows the home path, username or an email.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"
demo_reexec_clean "$here/record.sh" "$@"

cd "$here/.."

case "${1:-}" in
  first-run) bash "$here/prep.sh";       tape=demo/first-run.tape ;;
  flock)     bash "$here/prep.sh";       tape=demo/flock.tape ;;
  hero)      bash "$here/seed-fleet.sh"; tape=demo/roost-hero.tape ;;
  *) echo "usage: demo/record.sh first-run|flock|hero" >&2; exit 2 ;;
esac

# A failed recording must not leave the demo server up: with live agents on it,
# it keeps spending tokens until someone notices.
if ! vhs "$tape"; then
  echo "demo: vhs failed; stopping the demo server." >&2
  demo_stop
  exit 1
fi

# Everything a frame can show came through a pane on the demo server, so search
# every pane's full history before the server goes away.
if ! demo_scan_panes; then
  echo "demo: FOUND personal details in a pane -- do not publish this recording." >&2
  demo_stop
  exit 1
fi
demo_stop
echo "demo: recorded $tape; no home path, username or email in any pane."
