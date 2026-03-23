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

# --- gh api endpoint and method validation ---
# Validates gh api calls: blocks admin endpoints, destructive deletes,
# foreign-repo writes, graphql, and non-repo endpoints.
# Safe operations pass through to the settings tier (ask/allow).

if echo "$COMMAND" | grep -qP '^\s*gh\s+api\b'; then
  # Extract HTTP method (default GET if no -X/--method flag)
  GH_METHOD="GET"
  if echo "$COMMAND" | grep -qP '\s(-X|--method)\s+'; then
    GH_METHOD=$(echo "$COMMAND" | grep -oP '(?<=-X\s|--method\s)\s*\K[A-Z]+' | head -1)
  fi

  # Extract the endpoint by parsing arguments after 'gh api'.
  # Must handle flag ordering: gh api -X PATCH repos/... or gh api repos/... -X PATCH
  # Strategy: strip 'gh api', then walk tokens skipping flags and their values.
  GH_ARGS=$(echo "$COMMAND" | sed 's/^\s*gh\s\+api\s\+//')
  GH_ENDPOINT=""
  SKIP_NEXT=false
  # Flags that consume the next token as their value
  FLAG_WITH_VALUE="-X|--method|-H|--header|-f|--field|-F|--input|--jq|-q|--template|-t|-R|--repo|--cache"
  while IFS= read -r token; do
    if $SKIP_NEXT; then
      SKIP_NEXT=false
      continue
    fi
    # Skip flags that take a value (next token is consumed)
    if echo "$token" | grep -qP "^($FLAG_WITH_VALUE)$"; then
      SKIP_NEXT=true
      continue
    fi
    # Skip flags with = syntax (e.g., --method=PATCH, -f key=val)
    if echo "$token" | grep -qP '^-'; then
      continue
    fi
    # Skip HTTP method names that might appear after flag stripping
    if echo "$token" | grep -qP '^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$'; then
      continue
    fi
    # First non-flag, non-method token is the endpoint
    GH_ENDPOINT="$token"
    break
  done < <(echo "$GH_ARGS" | grep -oP '[^\s]+')
  GH_ENDPOINT="${GH_ENDPOINT#/}"  # strip leading slash

  # --- Block GraphQL (unverifiable scope) ---
  if [[ "$GH_ENDPOINT" == "graphql" ]] || echo "$COMMAND" | grep -qP '\bgraphql\b'; then
    echo '{"error": "Blocked: gh api graphql calls cannot be repo-verified. Use gh pr/gh issue commands instead, or get user approval for direct API access."}'
    exit 2
  fi

  # --- Block non-repo endpoints ---
  if [[ -n "$GH_ENDPOINT" ]] && ! echo "$GH_ENDPOINT" | grep -qP '^repos/'; then
    echo '{"error": "Blocked: gh api endpoint '"'$GH_ENDPOINT'"' is not a repos/ endpoint. Only repo-scoped API calls are permitted."}'
    exit 2
  fi

  # --- Block dangerous admin endpoints (any method, any repo) ---
  ADMIN_PATTERNS="settings|hooks|keys|actions/secrets|environments|collaborators|protection|rulesets|invitations|autolinks|topics|transfer|forks|import|pages|traffic|vulnerability-alerts"
  if echo "$GH_ENDPOINT" | grep -qP "^repos/[^/]+/[^/]+/($ADMIN_PATTERNS)"; then
    ADMIN_MATCH=$(echo "$GH_ENDPOINT" | grep -oP "^repos/[^/]+/[^/]+/\K($ADMIN_PATTERNS)")
    echo '{"error": "Blocked: gh api targeting admin endpoint '"'$ADMIN_MATCH'"'. Repository settings, hooks, keys, secrets, and access control endpoints are not permitted."}'
    exit 2
  fi

  # --- Block destructive comment deletion (any repo) ---
  if [[ "$GH_METHOD" == "DELETE" ]] && echo "$GH_ENDPOINT" | grep -qP '^repos/[^/]+/[^/]+/issues/comments/'; then
    echo '{"error": "Blocked: DELETE on issue comments is permanent and irreversible. Edit the comment instead using PATCH, or use gh issue/pr commands."}'
    exit 2
  fi

  # --- Block foreign-repo writes ---
  if [[ "$GH_METHOD" != "GET" ]] && [[ -n "$GH_ENDPOINT" ]]; then
    # Extract target owner/repo from endpoint
    API_OWNER_REPO=$(echo "$GH_ENDPOINT" | grep -oP '^repos/\K[^/]+/[^/]+' | tr '[:upper:]' '[:lower:]')

    if [[ -n "$API_OWNER_REPO" ]]; then
      # Determine current repo from git remote
      CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
      CURRENT_REPO=""
      if [[ -n "$CURRENT_REMOTE" ]]; then
        # Handle HTTPS: https://github.com/OWNER/REPO.git
        # Handle SSH: git@github.com:OWNER/REPO.git
        CURRENT_REPO=$(echo "$CURRENT_REMOTE" | sed -E 's#.*github\.com[:/]##; s/\.git$//' | tr '[:upper:]' '[:lower:]')
      fi

      if [[ -n "$CURRENT_REPO" ]] && [[ "$API_OWNER_REPO" != "$CURRENT_REPO" ]]; then
        echo '{"error": "Blocked: gh api '"$GH_METHOD"' targets foreign repo '"'$API_OWNER_REPO'"' but current repo is '"'$CURRENT_REPO'"'. Write operations to other repositories are not permitted."}'
        exit 2
      fi
    fi
  fi
fi

# All checks passed
exit 0
