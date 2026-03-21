# API Keys and Authentication

The guard rails sandbox blocks access to `~/.aws`, `~/.config/gh`, `~/.ssh`, and other credential stores. This is intentional — but it means Claude Code can't authenticate with external services unless you explicitly provide credentials.

This guide covers how to safely inject API keys and tokens into Claude Code sessions.

## The Problem

With guard rails active:
- `gh` commands fail because `~/.config/gh` is blocked
- AWS CLI fails because `~/.aws` is blocked
- Any tool that reads credentials from dotfiles under `~/` will fail

Environment variables are the primary mechanism for passing credentials, but they come with risks: any process Claude spawns can read them, and approved runtimes like `python` or `node` could exfiltrate them.

## Option 1: Parent Environment Variables

The simplest approach. Export tokens in your shell before launching Claude Code. All child processes inherit them automatically.

### GitHub CLI — from existing `gh auth login`

If you've already run `gh auth login`, the token is stored in `~/.config/gh/`. The sandbox blocks that path inside Claude Code, but the wrapper runs *before* the sandbox — so it can extract the token and pass it as an environment variable:

```bash
GH_TOKEN=$(gh auth token) claude
```

This pulls the token from your existing login session. No need to create or manage a separate PAT.

To automate this, add it to the wrapper function (see [updated wrapper](#using-the-wrapper-function) below).

### GitHub CLI — manual token

```bash
export GH_TOKEN="ghp_your_token_here"
claude
```

Or inline for a single session:

```bash
GH_TOKEN="ghp_your_token_here" claude
```

### AWS CLI

```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"
claude
```

### Generic pattern

```bash
export API_KEY="your-key"
claude
```

### Scoping tokens

Always create tokens with minimum required permissions:

| Service | Recommended scope |
|---------|------------------|
| GitHub (`GH_TOKEN`) | `repo`, `read:org` — skip `admin:*`, `delete_repo` |
| AWS | Read-only IAM policy, or scoped to specific services |
| npm | Read-only token unless publishing |

The permission deny rules block destructive GitHub operations (`gh repo delete`, `gh secret set`, etc.) even if the token allows them, but least-privilege tokens are still the right baseline.

## Option 2: 1Password CLI (`op`)

[1Password CLI](https://developer.1password.com/docs/cli/) injects secrets at runtime without persisting them in your shell history or environment. Secrets are fetched just-in-time and scoped to the process.

### Setup

1. Install the 1Password CLI: https://developer.1password.com/docs/cli/get-started
2. Enable the 1Password desktop app integration (Settings > Developer > CLI)
3. Sign in: `eval $(op signin)`

### Inject tokens into Claude Code

Use `op run` to inject secrets as environment variables for the duration of the session:

```bash
op run --env-file=.env.claude -- claude
```

Where `.env.claude` references 1Password secrets:

```bash
GH_TOKEN=op://Vault/GitHub CLI Token/credential
AWS_ACCESS_KEY_ID=op://Vault/AWS Dev/access_key_id
AWS_SECRET_ACCESS_KEY=op://Vault/AWS Dev/secret_access_key
```

**Do not commit `.env.claude`** — add it to `.gitignore`.

### Single secret inline

```bash
GH_TOKEN=$(op read "op://Vault/GitHub CLI Token/credential") claude
```

### Using the wrapper function

Update the `claude` wrapper in your `~/.bashrc` to automatically inject secrets via 1Password:

```bash
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

  # Auto-inject GH_TOKEN from existing gh auth login if not already set
  if [ -z "${GH_TOKEN:-}" ] && command -v gh &>/dev/null; then
    GH_TOKEN=$(gh auth token 2>/dev/null) && export GH_TOKEN
  fi

  # Inject secrets from 1Password if .env.claude exists and op is available
  if [ -f ".env.claude" ] && command -v op &>/dev/null; then
    op run --env-file=.env.claude -- command claude "$@"
  else
    command claude "$@"
  fi
}
```

This automatically picks up `.env.claude` in any project directory, so you can configure different credentials per repo.

## Option 3: Claude Code `env` Setting

Claude Code supports an `env` key in `settings.json` to set environment variables for sessions. You can use this in per-project settings:

```json
{
  "env": {
    "GH_TOKEN": "ghp_your_token_here"
  },
  "sandbox": {
    "filesystem": {
      "allowRead": ["."]
    }
  }
}
```

**Warning**: This stores the token in a file on disk. Use this only for non-sensitive values or in combination with `.gitignore` and `settings.local.json` (which is gitignored by convention):

```json
// .claude/settings.local.json — gitignored, local to your machine
{
  "env": {
    "GH_TOKEN": "ghp_your_token_here"
  }
}
```

## Option 4: Other Secret Managers

The same pattern works with any CLI-based secret manager:

### HashiCorp Vault

```bash
GH_TOKEN=$(vault kv get -field=token secret/github) claude
```

### AWS Secrets Manager

```bash
GH_TOKEN=$(aws secretsmanager get-secret-value --secret-id github-token --query SecretString --output text) claude
```

### macOS Keychain

```bash
GH_TOKEN=$(security find-generic-password -s "github-cli-token" -w) claude
```

### Bitwarden CLI

```bash
# Unlock the vault first (session key is required for bw get)
export BW_SESSION=$(bw unlock --raw)

GH_TOKEN=$(bw get password "GitHub CLI Token") claude
```

Or for a specific custom field:

```bash
GH_TOKEN=$(bw get item "GitHub CLI Token" | jq -r '.fields[] | select(.name=="token") | .value') claude
```

### pass (password-store)

```bash
GH_TOKEN=$(pass show github/cli-token) claude
```

## Security Considerations

### Environment variables are visible to all child processes

Once a token is in the environment, any process Claude spawns can read it. The guard rails mitigate this:
- `curl`, `wget`, `nc`, `ssh` are denied — preventing direct exfiltration
- `python`, `node` are in the `ask` tier — you approve before they run
- The PreToolUse hook catches bypass patterns

But approved runtimes (`python`, `node`) have full network access. If you approve `python` in a session with `GH_TOKEN` set, that Python process can read and transmit the token.

### Recommendations

1. **Use short-lived tokens** where possible (GitHub fine-grained PATs with expiry, AWS STS temporary credentials)
2. **Scope tokens narrowly** — only the permissions Claude actually needs
3. **Prefer `op run` or similar** over raw `export` — secrets don't persist in shell history or environment after the session ends
4. **Use per-project `.env.claude` files** — different repos get different credentials with different scopes
5. **Never commit credential files** — add `.env.claude` and `.claude/settings.local.json` to your global gitignore:
   ```bash
   echo ".env.claude" >> ~/.gitignore
   echo ".claude/settings.local.json" >> ~/.gitignore
   git config --global core.excludesFile ~/.gitignore
   ```
6. **Audit `ask`-tier approvals carefully** when secrets are in the environment — a `python` one-liner can read `$GH_TOKEN`
