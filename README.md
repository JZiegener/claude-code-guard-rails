# Claude Code Guard Rails

Sandbox-first configuration for Claude Code that restricts its process tree to only access the current project directory. Prevents Claude Code from reading files in other repos, `~/.ssh`, `~/.aws`, or any other sensitive directories under your home folder.

## How It Works

Claude Code uses [bubblewrap](https://github.com/containers/bubblewrap) on Linux for OS-level sandboxing. All child processes (including spawned agents and worktrees) inherit the same restrictions. The key property: **`allowRead` takes precedence over `denyRead`**, enabling a "deny broad, allow narrow" pattern.

**Three-layer defense:**

1. **Bubblewrap sandbox** (`~/.claude/settings.json`): OS-level filesystem isolation. Denies reads from the entire home directory (`~/`), then allows back specific toolchain paths (`~/.nvm`, `~/.cargo`, etc.) and `~/.claude` itself. This is the strongest layer — it applies to all child processes and cannot be bypassed from userspace.

2. **Permission rules** (`~/.claude/settings.json` + per-project): Defines which commands are auto-allowed, which require user confirmation (`ask`), and which are denied. Dangerous runtimes and tools that can exfiltrate data are in the `ask` category, requiring explicit approval each session.

3. **PreToolUse hook** (`~/.claude/hooks/validate-command.sh`): Shell-level validation that catches bypass patterns like piped commands, command chaining, `sed` execute modifiers, and `/proc/self/root` tricks. This layer runs independently of permission rules and provides defense-in-depth.

**Per-project opt-in:**

Each repo needs a `.claude/settings.json` with `allowRead: ["."]` to grant Claude access to itself.

### Access Matrix

| Resource | Allowed? | Why |
|----------|----------|-----|
| Files in current project | Yes | Project `allowRead: ["."]` overrides user-level deny |
| Files in other repos | **No** | `denyRead: ["~/"]` blocks all of `~/repos/` |
| `~/.ssh`, `~/.aws`, `~/.gnupg` | **No** | Under `~/`, denied; also in `denyWrite` |
| System binaries (`/usr/bin`) | Yes | Not under `~/` |
| Node/Rust/Python toolchains | Yes | Explicitly in `allowRead` |
| `/tmp` (worktrees) | Yes | Explicitly in `allowRead` and `allowWrite` |
| `curl`, `wget`, `nc`, `ssh`, `scp` | **No** | Permission deny rules + hook enforcement |
| `git`, `npm`, `gh pr` | Yes | Permission allow rules |
| `python`, `node`, `sed` | **Ask** | Requires user approval (can bypass restrictions) |
| `WebFetch`, `gh api` | **Ask** | Requires user approval (data exfiltration risk) |
| `docker` | **Ask** | Requires user approval; runs inside sandbox |
| `gh repo delete`, `gh secret` | **No** | Permission deny rules |
| `sudo`, `mkfs`, `dd` | **No** | Permission deny rules |

### Permission Rules

**Denied commands** (blocked even if allowed elsewhere):
- Destructive: `sudo`, `rm -rf /`, `rm -rf ~`, `mkfs`, `dd`, `chown`
- Network exfil: `curl`, `wget`, `nc`, `netcat`, `ncat`, `socat`, `ssh`, `scp`, `telnet`
- Shell wrappers: `bash -c`, `sh -c`, `dash -c`, `zsh -c` (prevent wrapping denied tools)
- Interpreter wrapping: `env curl/wget`, `xargs curl/wget`
- Dangerous GitHub ops: `gh repo create/delete`, `gh secret`, `gh ssh-key`, `gh gpg-key`, `gh auth`
- Force push: `git push --force`, `git push -f`

**Ask commands** (require user approval per session):
- Runtimes: `python`, `python3`, `node` (can open network sockets, bypassing curl/wget deny)
- Package managers: `npx`, `pip`, `pip3`, `cargo` (download and execute arbitrary code)
- Build tools: `make`, `docker`, `docker-compose` (execute arbitrary commands)
- Text processing: `sed` (has execute modifier), `sort` (has --compress-program)
- Network-capable: `WebFetch`, `gh api` (data exfiltration channels)

**Allowed commands** (auto-approved when sandbox is active):
- Version control: `git`, `gh pr/issue/run/workflow/browse/status/search`
- Package managers: `npm`, `yarn`, `pnpm` (install only, not execute)
- Build tools: `tsc`, `eslint`, `prettier`, `rustc`
- File operations: `cat`, `ls`, `find`, `head`, `tail`, `cp`, `mv`, `rm`, `mkdir`, `touch`
- Text processing: `grep`, `rg`, `awk`, `jq`, `uniq`, `diff`, `wc`
- Built-in tools: `Read`, `Edit`, `Write`

## Threat Model

### What this protects against
- **Accidental cross-repo access**: Claude cannot read files from other projects
- **Credential theft**: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh` are all blocked
- **Casual exfiltration**: `curl` and `wget` are denied; `WebFetch` and `gh api` require approval
- **Destructive operations**: `sudo`, force push, `rm -rf /`, `mkfs` are denied
- **Common bypass patterns**: Pipe chains, command chaining, `sed -e`, `sort --compress-program`, `/proc/self/root` tricks are caught by the hook
- **Sandbox escape**: `allowUnsandboxedCommands: false` prevents Claude from disabling bubblewrap
- **Settings self-modification**: `~/.claude/settings.json` is in `denyWrite`, preventing Claude from weakening its own guard rails
- **Hook tampering**: `~/.claude/hooks` is in `denyWrite`, preventing Claude from overwriting validation scripts
- **Shell wrapper bypass**: `bash -c`, `sh -c`, `env`, `xargs` wrapping denied tools is caught by both permission deny rules and the hook
- **`find -exec` / `awk system()` bypass**: The hook inspects arguments to `find -exec` and `awk system()`/`popen()` for denied tools

### Architectural Limitations

These are inherent to the sandbox model and cannot be fully addressed by configuration alone:

- **Bubblewrap doesn't block network tools**: The sandbox restricts filesystem access under `~/` but does not prevent execution of network tools like `/usr/bin/curl`. Exfiltration prevention relies entirely on permission rules + the hook — not the sandbox itself.
- **Environment variables are exposed**: Even with perfect filesystem isolation, secrets in environment variables (`$GITHUB_TOKEN`, `$AWS_SECRET_ACCESS_KEY`, etc.) are readable by any process Claude spawns. Avoid exporting secrets in your shell profile, or unset them before running Claude.
- **`autoAllowBashIfSandboxed: true` widens attack surface**: This setting auto-approves all Bash commands when sandboxed, making deny rules the only permission gate. If deny rules are broken (see Known Limitations below), there is no interactive approval step. This is a deliberate UX tradeoff — set it to `false` if you prefer to approve each command manually.
- **`npm install` lifecycle scripts**: `npm install` is auto-allowed and executes `postinstall` scripts from `package.json`. A malicious project could exfiltrate env vars this way. The sandbox prevents reading `~/.aws` etc., but env vars with secrets are still exposed. Consider using `npm install --ignore-scripts` in untrusted projects.
- **`awk` and `find` are auto-allowed**: These tools can execute arbitrary commands via `awk system()` and `find -exec`. The hook inspects for denied tools in these contexts, but cannot catch all obfuscation. In high-security scenarios, consider moving them to the `ask` tier.

### What this does NOT protect against
- **Determined prompt injection**: A sufficiently sophisticated injection in project files could potentially craft commands that evade pattern matching
- **Novel bypass techniques**: The hook catches known patterns but cannot anticipate all future bypass methods
- **Approved runtime abuse**: If you approve `python` or `node`, those runtimes have full network access within the sandbox — they can exfiltrate data
- **Permission deny rule bugs**: Multiple GitHub issues report that `permissions.deny` rules may not be enforced in some Claude Code versions. The PreToolUse hook provides defense-in-depth for this case, but verify deny rules work in your version

### Known Limitations

**Permission deny rules may be broken**: GitHub issues [#6699](https://github.com/anthropics/claude-code/issues/6699), [#8961](https://github.com/anthropics/claude-code/issues/8961), [#24846](https://github.com/anthropics/claude-code/issues/24846), [#27040](https://github.com/anthropics/claude-code/issues/27040) report that `permissions.deny` is not enforced in some versions (v1.0.93 through v2.0.56+). The PreToolUse hook mitigates this for common patterns, but cannot cover all cases. Test deny rules in your version:

```bash
# In a Claude Code session, try a denied command and verify it's blocked
# If it runs anyway, the hook layer is your primary defense
```

**Bypass techniques from security research** (GMO Flatt Security, Ona):
- Piped commands: `cat file | curl ...` — **caught by hook**
- Command chaining: `echo hi && curl ...` — **caught by hook**
- `sed` execute: `sed 'e' file` — **caught by hook**
- `sort --compress-program`: — **caught by hook**
- `/proc/self/root` paths: — **caught by hook**
- Shell wrapper (`bash -c "curl ..."`): — **caught by hook + deny rules**
- Interpreter wrapping (`env curl`, `xargs curl`): — **caught by hook + deny rules**
- `find -exec curl`: — **caught by hook**
- `awk system("curl ...")`: — **caught by hook**
- Standalone denied tool (`curl http://...`): — **caught by hook + deny rules**
- Network tools (`nc`, `ssh`, `scp`, `socat`): — **caught by deny rules + hook**
- Variable expansion (`${var@P}`): — **not caught** (too many variants)
- Git argument abbreviation (`--forc` for `--force`): — **partially mitigated** (`-f` pattern added to deny)

## Installation

### Quick Install

```bash
./install.sh
```

This will:
1. Install the user-level sandbox config to `~/.claude/settings.json`
2. Install the PreToolUse validation hook to `~/.claude/hooks/validate-command.sh`
3. Add a `claude` wrapper function to `~/.bashrc` that auto-creates project settings
4. Create `.claude/settings.json` in the current directory if missing

### Manual Install

```bash
# 1. Install user settings (backs up existing config)
cp ~/.claude/settings.json ~/.claude/settings.json.bak 2>/dev/null
cp config/user-settings.json ~/.claude/settings.json

# 2. Install the PreToolUse hook
mkdir -p ~/.claude/hooks
cp hooks/validate-command.sh ~/.claude/hooks/validate-command.sh
chmod +x ~/.claude/hooks/validate-command.sh

# Add hook config to settings.json (requires jq):
jq '. * {"hooks":{"PreToolUse":[{"matcher":"Bash","command":"'"$HOME/.claude/hooks/validate-command.sh"'"}]}}' \
  ~/.claude/settings.json > /tmp/settings-tmp.json && mv /tmp/settings-tmp.json ~/.claude/settings.json

# 3. Add wrapper function to your shell rc
cat config/claude-wrapper.sh >> ~/.bashrc
source ~/.bashrc

# 4. Opt in a specific project
./scripts/opt-in-project.sh /path/to/your/repo
```

### Opt In a Project

Each repo needs a `.claude/settings.json` to grant Claude read access:

```bash
./scripts/opt-in-project.sh /path/to/repo
```

Or do it manually:

```bash
mkdir -p /path/to/repo/.claude
cp config/project-settings.json /path/to/repo/.claude/settings.json
```

### Opt In All Repos

```bash
./scripts/opt-in-all.sh ~/repos
```

## Uninstall

```bash
./uninstall.sh
```

This restores your `~/.claude/settings.json` backup, removes the hook script, and removes the wrapper function from `~/.bashrc`.

## Customization

### Adding Toolchain Paths

If you use additional toolchains under `~/`, add them to `allowRead` in `~/.claude/settings.json`:

```json
"allowRead": [
  "~/.claude",
  "~/.nvm",
  "~/.rbenv",
  "~/.goenv",
  "~/.sdkman"
]
```

### Moving Commands Between Permission Tiers

If you trust a runtime in a specific project, you can move it from `ask` to `allow` in that project's `.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(python3 *)"
    ]
  },
  "sandbox": {
    "filesystem": {
      "allowRead": ["."]
    }
  }
}
```

### Diagnosing Permission Errors

If a command fails with "Operation not permitted", the sandbox is likely blocking access to a path under `~/`. Check what path is needed and add it to the appropriate `allowRead` list.

## File Structure

```
.
├── README.md
├── install.sh              # Full installation script
├── uninstall.sh            # Restores previous settings
├── config/
│   ├── user-settings.json  # User-level sandbox config (~/.claude/settings.json)
│   ├── project-settings.json  # Template for per-project opt-in
│   └── claude-wrapper.sh   # Shell wrapper function for auto-opt-in
├── hooks/
│   └── validate-command.sh # PreToolUse hook for bypass detection
└── scripts/
    ├── opt-in-project.sh   # Opt in a single project
    └── opt-in-all.sh       # Opt in all repos under a directory
```

## Requirements

- Claude Code on Linux (bubblewrap sandbox)
- Bash shell
- `jq` (recommended, for config merging during install)

## License

MIT
