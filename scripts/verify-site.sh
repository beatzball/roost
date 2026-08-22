#!/bin/sh
# verify-site.sh — probe a roost docs deployment.
#
#   scripts/verify-site.sh http://localhost:8080
#   ROOST_EXPECT_COMMIT=$(git rev-parse HEAD) scripts/verify-site.sh https://roosting.dev
#
# Used twice in CI: against the container built from this commit, and against
# production after a deploy. Same checks both times, so "it worked in CI" and
# "it works in production" mean the same thing.
#
# ROOST_EXPECT_COMMIT is the part that matters after a deploy. A Coolify
# webhook only *queues* a build, so probing immediately hits the OLD container
# and passes — a failed deploy then looks green. With it set, the probe retries
# until /version.json reports this exact commit, and fails if it never does.
#
# Env:
#   ROOST_EXPECT_COMMIT   require this commit to be the one being served
#   ROOST_PROBE_RETRIES   attempts (default 10)
#   ROOST_PROBE_DELAY     seconds between attempts (default 3)
set -eu

BASE="${1:?usage: verify-site.sh BASE_URL}"
BASE="${BASE%/}"
retries="${ROOST_PROBE_RETRIES:-10}"
delay="${ROOST_PROBE_DELAY:-3}"
expect="${ROOST_EXPECT_COMMIT:-}"

# Every page the site is supposed to serve. A deploy that drops one of these
# is broken even if the home page loads.
PAGES="/
/docs/getting-started
/docs/setup
/docs/using-roost
/docs/driving-a-fleet
/docs/state-badges
/docs/how-it-works
/docs/troubleshooting"

fail=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*" >&2; fail=1; }

status() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null || echo 000; }

# ---------------------------------------------------------------------------
# 1. Wait for the expected commit (or just for the site to answer at all)
# ---------------------------------------------------------------------------
printf 'verify-site: %s\n' "$BASE"
n=0
while :; do
  n=$((n + 1))
  served=$(curl -s --max-time 20 "$BASE/version.json" 2>/dev/null |
             sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$expect" ]; then
    [ "$(status "$BASE/")" = "200" ] && break
  elif [ "$served" = "$expect" ]; then
    note "serving $served"
    break
  fi
  if [ "$n" -ge "$retries" ]; then
    if [ -n "$expect" ]; then
      bad "after $n attempts the site is serving '${served:-<no version.json>}', expected '$expect'"
      bad "the deploy did not land — this is the old container"
    else
      bad "site did not respond after $n attempts"
    fi
    exit 1
  fi
  printf '  waiting (%s/%s) — serving %s\n' "$n" "$retries" "${served:-<nothing>}"
  sleep "$delay"
done

# ---------------------------------------------------------------------------
# 2. Every page, and the assets the pages depend on
# ---------------------------------------------------------------------------
printf '%s\n' "$PAGES" | while IFS= read -r page; do
  [ -n "$page" ] || continue
  code=$(status "$BASE$page")
  if [ "$code" = "200" ]; then note "200  $page"; else bad "$code  $page"; fi
done > /tmp/verify-site-pages.$$ 2>&1 || true
cat /tmp/verify-site-pages.$$
grep -q '✗' /tmp/verify-site-pages.$$ && fail=1
rm -f /tmp/verify-site-pages.$$

for asset in /logo.png /_litro/app.js; do
  code=$(status "$BASE$asset")
  if [ "$code" = "200" ]; then note "200  $asset"; else bad "$code  $asset"; fi
done

# A 404 that returns 200 means try_files is misconfigured and every typo looks
# like a real page.
code=$(status "$BASE/definitely-not-a-page")
if [ "$code" = "404" ]; then note "404  /definitely-not-a-page (as expected)"
else bad "unknown path returned $code, expected 404"; fi

[ "$fail" -eq 0 ] || { printf 'verify-site: FAILED\n' >&2; exit 1; }
printf 'verify-site: OK\n'
