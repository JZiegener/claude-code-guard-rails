#!/usr/bin/env bash
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SHELL_RC="$HOME/.bashrc"

echo "=== Claude Code Guard Rails Uninstaller ==="
echo

# Step 1: Restore user settings backup
echo "1. Restoring user settings..."
if [ -f "$CLAUDE_DIR/settings.json.bak" ]; then
  cp "$CLAUDE_DIR/settings.json.bak" "$CLAUDE_DIR/settings.json"
  echo "   Restored from settings.json.bak"
else
  echo "   No backup found at $CLAUDE_DIR/settings.json.bak"
  echo "   You may need to manually edit ~/.claude/settings.json"
fi

# Step 2: Remove hook script
echo "2. Removing PreToolUse hook..."
if [ -f "$CLAUDE_DIR/hooks/validate-command.sh" ]; then
  rm "$CLAUDE_DIR/hooks/validate-command.sh"
  echo "   Removed $CLAUDE_DIR/hooks/validate-command.sh"
  # Remove hooks dir if empty
  rmdir "$CLAUDE_DIR/hooks" 2>/dev/null && echo "   Removed empty hooks directory" || true
else
  echo "   Hook script not found, skipping"
fi

# Step 3: Remove wrapper function from shell rc
echo "3. Removing claude wrapper function from $SHELL_RC..."
if grep -q '# Claude Code wrapper' "$SHELL_RC" 2>/dev/null; then
  # Remove the wrapper block (comment + function)
  sed -i '/^# Claude Code wrapper/,/^}$/d' "$SHELL_RC"
  echo "   Removed from $SHELL_RC"
else
  echo "   Wrapper function not found in $SHELL_RC"
fi

echo
echo "=== Uninstall complete ==="
echo
echo "Next steps:"
echo "  1. Run: source $SHELL_RC"
echo "  2. Per-project .claude/settings.json files were left in place."
echo "     Remove them manually if desired."
