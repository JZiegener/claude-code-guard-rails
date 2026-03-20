#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPT_IN="$SCRIPT_DIR/opt-in-project.sh"

if [ $# -eq 0 ]; then
  PARENT="$HOME/repos"
else
  PARENT="$1"
fi

if [ ! -d "$PARENT" ]; then
  echo "Error: $PARENT is not a directory"
  exit 1
fi

count=0
for repo in "$PARENT"/*/; do
  [ -d "$repo" ] || continue
  if [ ! -f "$repo/.claude/settings.json" ]; then
    "$OPT_IN" "$repo"
    ((count++))
  fi
done

echo "Done. Opted in $count new repos."
