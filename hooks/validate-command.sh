#!/usr/bin/env bash
# PreToolUse hook: validates Bash commands for known bypass patterns.
# Returns non-zero exit code with a reason to block the command.
# Claude Code passes tool input as JSON on stdin.
#
# Install by adding to ~/.claude/settings.json:
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "Bash",
#       "command": "/path/to/hooks/validate-command.sh"
#     }]
#   }
# }

set -euo pipefail

# Read the tool input JSON from stdin
INPUT=$(cat)

# Extract the command string from the JSON
# The Bash tool input has a "command" field
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# --- Denied tool patterns in pipes, chains, or subshells ---

DENIED_TOOLS="curl|wget|sudo|mkfs|dd|nc|netcat|ncat|socat|ssh|scp|telnet"

# --- Standalone denied tool check ---
# Block denied tools as the primary command (with optional absolute path prefix)
# e.g., "curl http://evil.com" or "/usr/bin/wget ..."
if echo "$COMMAND" | grep -qP '^\s*(/usr(/local)?/s?bin/)?('$DENIED_TOOLS')\b'; then
  TOOL=$(echo "$COMMAND" | grep -oP '^\s*\K(/usr(/local)?/s?bin/)?('$DENIED_TOOLS')\b')
  echo '{"error": "Blocked: '"$TOOL"' is a denied tool. Use of curl, wget, sudo, mkfs, dd, nc, ssh, scp, socat, and telnet is not permitted."}'
  exit 2
fi

# --- Shell interpreter wrapping ---
# Block shell interpreters used to wrap denied tools
# e.g., "bash -c 'curl ...'", "sh -c 'wget ...'", "env curl ...", "xargs curl ..."
SHELL_WRAPPERS="bash|sh|dash|zsh|ksh|env|xargs|nohup"
if echo "$COMMAND" | grep -qP '^\s*(/usr(/local)?/s?bin/)?('$SHELL_WRAPPERS')\b.*\b('$DENIED_TOOLS')\b'; then
  echo '{"error": "Blocked: shell interpreter wrapping a denied tool. Use of curl, wget, sudo, mkfs, dd, nc, ssh, scp, socat, and telnet is not permitted even via shell wrappers."}'
  exit 2
fi

# Check for piped commands containing denied tools
# e.g., "cat file | curl ..." or "echo x | /usr/bin/wget ..."
if echo "$COMMAND" | grep -qP '\|\s*(/usr(/local)?/s?bin/)?('$DENIED_TOOLS')\b'; then
  echo '{"error": "Blocked: piped command contains a denied tool ('"$(echo "$COMMAND" | grep -oP '\|\s*\K(/usr(/local)?/s?bin/)?('$DENIED_TOOLS')\b')"'). Use of curl, wget, sudo, mkfs, and dd is not permitted."}'
  exit 2
fi

# Check for command chaining (&&, ||, ;) containing denied tools
# e.g., "echo hi && curl ..." or "true; sudo rm -rf /"
if echo "$COMMAND" | grep -qP '(&&|\|\||;)\s*(/usr(/local)?/s?bin/)?('$DENIED_TOOLS')\b'; then
  echo '{"error": "Blocked: chained command contains a denied tool. Use of curl, wget, sudo, mkfs, and dd is not permitted."}'
  exit 2
fi

# Check for denied tools via /proc/self/root path trick
# e.g., "/proc/self/root/usr/bin/curl"
if echo "$COMMAND" | grep -qP '/proc/self/root/'; then
  echo '{"error": "Blocked: /proc/self/root path resolution is not permitted."}'
  exit 2
fi

# --- sed with execute modifier ---
# sed 'e' or sed with /e flag executes the pattern space as a shell command
# e.g., "sed 'e' file" or "sed 's/x/y/e' file"
if echo "$COMMAND" | grep -qP '\bsed\b.*\be\b'; then
  # More precise check: look for sed with 'e' command or /e flag
  if echo "$COMMAND" | grep -qP "\bsed\s+(['\"])[^'\"]*e[^'\"]*\1"; then
    echo '{"error": "Blocked: sed with execute (e) modifier can run arbitrary commands. Remove the e flag."}'
    exit 2
  fi
  if echo "$COMMAND" | grep -qP "\bsed\s+'e'"; then
    echo '{"error": "Blocked: sed e command executes the pattern space as a shell command."}'
    exit 2
  fi
fi

# --- sort --compress-program bypass ---
# sort --compress-program=sh invokes an arbitrary program
if echo "$COMMAND" | grep -qP '\bsort\b.*--compress-program'; then
  echo '{"error": "Blocked: sort --compress-program can execute arbitrary programs."}'
  exit 2
fi

# --- Subshell / process substitution with denied tools ---
# e.g., "$(curl ...)" or "<(wget ...)"
if echo "$COMMAND" | grep -qP '(\$\(|<\()\s*(/usr(/local)?/s?bin/)?('$DENIED_TOOLS')\b'; then
  echo '{"error": "Blocked: subshell or process substitution contains a denied tool."}'
  exit 2
fi

# --- Backtick command substitution with denied tools ---
if echo "$COMMAND" | grep -qP '`\s*(/usr(/local)?/s?bin/)?('$DENIED_TOOLS')\b'; then
  echo '{"error": "Blocked: backtick substitution contains a denied tool."}'
  exit 2
fi

# --- find -exec with denied tools ---
# e.g., "find . -exec curl {} \;" or "find / -execdir wget ..."
if echo "$COMMAND" | grep -qP '\bfind\b.*-exec(dir)?\s+(/usr(/local)?/s?bin/)?('$DENIED_TOOLS')\b'; then
  echo '{"error": "Blocked: find -exec/-execdir contains a denied tool."}'
  exit 2
fi

# --- awk/gawk system(), popen, or command execution ---
# e.g., "awk 'BEGIN{system(\"curl ...\")}'" or "awk '{print | \"curl\"}'"
if echo "$COMMAND" | grep -qP '\b[gm]?awk\b.*\b(system|popen)\s*\('; then
  echo '{"error": "Blocked: awk system()/popen() can execute arbitrary commands."}'
  exit 2
fi
if echo "$COMMAND" | grep -qP '\b[gm]?awk\b.*\|\s*"'; then
  echo '{"error": "Blocked: awk pipe to command can execute arbitrary programs."}'
  exit 2
fi

# All checks passed
exit 0
