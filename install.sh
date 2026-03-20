#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SHELL_RC="$HOME/.bashrc"

echo "=== Claude Code Guard Rails Installer ==="
echo

# Step 1: Install user settings
echo "1. Installing user-level sandbox config..."
mkdir -p "$CLAUDE_DIR"

if [ -f "$CLAUDE_DIR/settings.json" ]; then
  # Preserve existing non-sandbox settings (env, model, teammateMode)
  if command -v jq &>/dev/null; then
    # Merge: keep existing top-level keys, overlay with guard rails config
    EXISTING="$CLAUDE_DIR/settings.json"
    TEMPLATE="$SCRIPT_DIR/config/user-settings.json"
    MERGED=$(jq -s '.[0] * .[1]' "$EXISTING" "$TEMPLATE")
    cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.bak"
    echo "$MERGED" > "$CLAUDE_DIR/settings.json"
    echo "   Merged with existing config (backup: settings.json.bak)"
  else
    cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.bak"
    cp "$SCRIPT_DIR/config/user-settings.json" "$CLAUDE_DIR/settings.json"
    echo "   Installed (backup: settings.json.bak)"
    echo "   Note: jq not found, existing settings were replaced instead of merged."
    echo "   Review ~/.claude/settings.json.bak for any settings to restore."
  fi
else
  cp "$SCRIPT_DIR/config/user-settings.json" "$CLAUDE_DIR/settings.json"
  echo "   Installed (no existing config found)"
fi

# Step 2: Install PreToolUse hook
echo "2. Installing PreToolUse validation hook..."
HOOKS_DIR="$CLAUDE_DIR/hooks"
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/hooks/validate-command.sh" "$HOOKS_DIR/validate-command.sh"
chmod +x "$HOOKS_DIR/validate-command.sh"

# Add hook config to settings.json
if command -v jq &>/dev/null; then
  HOOK_CONFIG='{"hooks":{"PreToolUse":[{"matcher":"Bash","command":"'"$HOOKS_DIR/validate-command.sh"'"}]}}'
  UPDATED=$(jq --argjson hook "$HOOK_CONFIG" '. * $hook' "$CLAUDE_DIR/settings.json")
  echo "$UPDATED" > "$CLAUDE_DIR/settings.json"
  echo "   Hook installed at $HOOKS_DIR/validate-command.sh"
  echo "   Hook config added to settings.json"
else
  echo "   Hook script installed at $HOOKS_DIR/validate-command.sh"
  echo "   WARNING: jq not found. You must manually add the hook to ~/.claude/settings.json:"
  echo '   "hooks": { "PreToolUse": [{ "matcher": "Bash", "command": "'"$HOOKS_DIR/validate-command.sh"'" }] }'
fi

# Step 3: Add wrapper function to shell rc
echo "3. Adding claude wrapper function to $SHELL_RC..."

if grep -q 'claude()' "$SHELL_RC" 2>/dev/null; then
  echo "   Wrapper function already exists in $SHELL_RC, skipping"
else
  {
    echo ""
    cat "$SCRIPT_DIR/config/claude-wrapper.sh"
  } >> "$SHELL_RC"
  echo "   Added to $SHELL_RC"
fi

# Step 4: Opt in current project
echo "4. Opting in current project..."
"$SCRIPT_DIR/scripts/opt-in-project.sh" "$SCRIPT_DIR"

echo
echo "=== Installation complete ==="
echo
echo "Next steps:"
echo "  1. Run: source $SHELL_RC"
echo "  2. Start a new Claude Code session to apply sandbox config"
echo "  3. Opt in other repos: ./scripts/opt-in-project.sh /path/to/repo"
echo "     Or all at once:     ./scripts/opt-in-all.sh ~/repos"
