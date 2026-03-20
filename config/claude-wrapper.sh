# Claude Code wrapper: auto-create .claude/settings.json (sandbox opt-in) if missing
claude() {
  if [ ! -f ".claude/settings.json" ]; then
    mkdir -p .claude
    cat > .claude/settings.json << 'SETTINGS'
{
  "permissions": {
    "ask": [
      "Bash(python *)",
      "Bash(python3 *)",
      "Bash(node *)",
      "Bash(npx *)",
      "Bash(sed *)",
      "Bash(docker *)",
      "WebFetch",
      "Bash(gh api *)"
    ]
  },
  "sandbox": {
    "filesystem": {
      "allowRead": ["."]
    }
  }
}
SETTINGS
    echo "Created .claude/settings.json (sandbox opt-in for this project)"
  fi
  command claude "$@"
}
