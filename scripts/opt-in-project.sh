#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../config/project-settings.json"

if [ $# -eq 0 ]; then
  TARGET="$(pwd)"
else
  TARGET="$1"
fi

if [ ! -d "$TARGET" ]; then
  echo "Error: $TARGET is not a directory"
  exit 1
fi

if [ -f "$TARGET/.claude/settings.json" ]; then
  echo "Already exists: $TARGET/.claude/settings.json"
  exit 0
fi

mkdir -p "$TARGET/.claude"
cp "$TEMPLATE" "$TARGET/.claude/settings.json"
echo "Created $TARGET/.claude/settings.json"
