#!/bin/sh
# Stamps a countable line per Enter it receives, so a test can prove exactly
# how many Enters actually reached the pane (not just that "some" did).
i=0
while IFS= read -r line; do
  i=$((i + 1))
  echo "ENTER-$i"
done
