# Claude Code Guard Rails

Sandbox-first configuration for Claude Code that restricts its process tree to only access the current project directory. Prevents Claude Code from reading files in other repos, `~/.ssh`, `~/.aws`, or any other sensitive directories under your home folder.

## How It Works

A shell wrapper function launches Claude Code inside [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`), an OS-level sandbox. All child processes (including spawned agents and worktrees) inherit the same restrictions.

**Three-layer defense:**

1. **Bubblewrap sandbox** (external wrapper): OS-level filesystem isolation via mount namespaces. The home directory is replaced with an empty `tmpfs`, then only the project directory (`$PWD`) and toolchain paths are bind-mounted back in. Sensitive directories (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`) are never mounted at all — they don't exist inside the sandbox. This is the strongest layer — it applies to all child processes and cannot be bypassed from userspace.

2. **Permission rules** (`~/.claude/settings.json` + per-project): Defines which commands are auto-allowed, which require user confirmation (`ask`), and which are denied. Dangerous runtimes and tools that can exfiltrate data are in the `ask` category, requiring explicit approval each session.

3. **PreToolUse hook** (`~/.claude/hooks/validate-command.sh`): Shell-level validation that catches bypass patterns like piped commands, command chaining, `sed` execute modifiers, and `/proc/self/root` tricks. This layer runs independently of permission rules and provides defense-in-depth.

### Why an external bwrap wrapper?

Claude Code has a built-in sandbox, but it has a [mount ordering bug](https://github.com/anthropic-experimental/sandbox-runtime/blob/main/src/sandbox/linux-sandbox-utils.ts): the `allowRead` processing re-mounts paths with `--ro-bind` after `allowWrite` has already mounted them with `--bind` (read-write), making the project directory read-only for Bash commands. This means `git add`, `git commit`, `npm install`, and other write operations fail with "Read-only file system" even when `allowWrite: ["."]` is configured. The built-in Edit/Write tools bypass bwrap and work fine, but Bash commands see a read-only filesystem.

The external wrapper solves this by controlling mount order directly:

```
bwrap mount order:
  1.  --ro-bind / /              Read-only root (system, binaries, libs)
  2.  --tmpfs $HOME              Wipe home dir (blocks ~/.aws, etc.)
  3.  --bind $PWD $PWD           Project dir read-write (git, npm, etc.)
  4.  --bind ~/.claude            Claude config (session state)
  5.  --ro-bind settings/hooks   Protect guard rail config
  6.  SSH agent socket + pubkeys SSH auth without exposing private keys
  7.  D-Bus + keyring            Claude Code built-in auth
  8.  --ro-bind .gitconfig       Git user config
  9.  --ro-bind toolchains       Read-only nvm, cargo, etc.
  10. --bind .npm                npm cache read-write
  11. --bind /tmp                Worktrees and temp files
```

Inspired by [CaptainMcCrank/SandboxedClaudeCode](https://github.com/CaptainMcCrank/SandboxedClaudeCode).

### Where Settings Live

```
~/.claude/
├── settings.json          ← User-level (global)
│                            Permission rules, hooks config
│                            sandbox.enabled: false (bwrap is external)
│                            Installed by: install.sh
│
└── hooks/
    └── validate-command.sh ← PreToolUse hook
                              Installed by: install.sh

~/.bashrc
└── claude()               ← Wrapper function
                              Launches claude inside bwrap
                              Installed by: install.sh

~/repos/my-project/
└── .claude/
    └── settings.local.json ← Project-level (per-repo, not committed)
                              Guard rail permission overrides
                              Created by: wrapper function or opt-in script
```

### How Settings Apply

```
  ┌───────────────────────────────────────────┐
  │          bwrap wrapper (shell)             │
  │                                           │
  │  Filesystem isolation:                    │
  │    --ro-bind / /         (read-only root) │
  │    --tmpfs $HOME         (wipe home)      │
  │    --bind $PWD $PWD      (project rw)     │
  │    SSH agent socket      (sign, not read) │
  │    D-Bus + keyring       (Claude auth)    │
  │    --ro-bind toolchains  (nvm, cargo...) │
  │    --bind /tmp           (worktrees)      │
  │                                           │
  │  NOT mounted (invisible to Claude):       │
  │    ~/.ssh/id_* (private keys)  ~/.aws     │
  │    ~/.gnupg  ~/.config/gh                 │
  └─────────────────┬─────────────────────────┘
                    │
                    ▼
  ┌───────────────────────────────────────────┐
  │     Claude Code (inside sandbox)          │
  │                                           │
  │  ~/.claude/settings.json (user-level):    │
  │    permissions: deny/allow/ask rules      │
  │    hooks: PreToolUse validation           │
  │    sandbox.enabled: false                 │
  │                                           │
  │  .claude/settings.local.json (project):    │
  │    permissions: guard rail overrides      │
  └───────────────────────────────────────────┘
```

**Per-project opt-in:** Each repo gets a `.claude/settings.local.json` with guard rail permission overrides. The wrapper auto-creates one if missing. This file is local (not committed) — filesystem isolation is handled entirely by the bwrap wrapper.

### Access Matrix

| Resource | Allowed? | Why |
|----------|----------|-----|
| Files in current project | Yes (rw) | `--bind $PWD $PWD` mounts project read-write |
| Files in other repos | **No** | `--tmpfs $HOME` wipes `~/`, only `$PWD` is re-mounted |
| `~/.ssh/id_*` (private keys) | **No** | Not mounted — invisible inside sandbox |
| SSH agent socket | Yes | `SSH_AUTH_SOCK` forwarded — can sign, cannot read keys |
| `~/.ssh/known_hosts`, `*.pub` | Yes (ro) | `--ro-bind` for host verification |
| `~/.aws`, `~/.config/gh` | **No** | Not mounted — invisible inside sandbox |
| `~/.gnupg` | **No** | Not mounted (GPG support deferred — see issue #4) |
| D-Bus / keyring | Yes | Claude Code built-in auth works |
| `.gitconfig` | Yes (ro) | `--ro-bind` for git user config |
| System binaries (`/usr/bin`) | Yes (ro) | `--ro-bind / /` provides read-only system access |
| Node/Rust/Python toolchains | Yes (ro) | Explicitly `--ro-bind` mounted by wrapper |
| npm cache (`~/.npm`) | Yes (rw) | `--bind` for caching performance |
| `/tmp` (worktrees) | Yes (rw) | `--bind /tmp /tmp` |
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
- **Credential theft**: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh` are not mounted — they don't exist inside the sandbox
- **Casual exfiltration**: `curl` and `wget` are denied; `WebFetch` and `gh api` require approval
- **Destructive operations**: `sudo`, force push, `rm -rf /`, `mkfs` are denied
- **Common bypass patterns**: Pipe chains, command chaining, `sed -e`, `sort --compress-program`, `/proc/self/root` tricks are caught by the hook
- **Settings self-modification**: `~/.claude/settings.json` is `--ro-bind` mounted, preventing Claude from weakening its own guard rails
- **Hook tampering**: `~/.claude/hooks` is `--ro-bind` mounted, preventing Claude from overwriting validation scripts
- **Shell wrapper bypass**: `bash -c`, `sh -c`, `env`, `xargs` wrapping denied tools is caught by both permission deny rules and the hook
- **`find -exec` / `awk system()` bypass**: The hook inspects arguments to `find -exec` and `awk system()`/`popen()` for denied tools

### Architectural Limitations

These are inherent to the sandbox model and cannot be fully addressed by configuration alone:

- **Bubblewrap doesn't block network tools**: The sandbox restricts filesystem access under `~/` but does not prevent execution of network tools like `/usr/bin/curl`. Exfiltration prevention relies entirely on permission rules + the hook — not the sandbox itself.
- **Environment variables are exposed**: Even with perfect filesystem isolation, secrets in environment variables (`$GITHUB_TOKEN`, `$AWS_SECRET_ACCESS_KEY`, etc.) are readable by any process Claude spawns. Avoid exporting secrets in your shell profile, or unset them before running Claude.
- **`npm install` lifecycle scripts**: `npm install` is auto-allowed and executes `postinstall` scripts from `package.json`. A malicious project could exfiltrate env vars this way. The sandbox prevents reading `~/.aws` etc., but env vars with secrets are still exposed. Consider using `npm install --ignore-scripts` in untrusted projects.
- **`awk` and `find` are auto-allowed**: These tools can execute arbitrary commands via `awk system()` and `find -exec`. The hook inspects for denied tools in these contexts, but cannot catch all obfuscation. In high-security scenarios, consider moving them to the `ask` tier.
- **System SSH config is bypassed**: bwrap's user namespace only maps the calling user's UID — root-owned files (like `/etc/ssh/ssh_config.d/*`) appear as `nobody:nogroup` inside the sandbox, causing SSH's ownership check to fail. The wrapper sets `GIT_SSH_COMMAND="ssh -F /dev/null"` to skip the system SSH config. SSH defaults (port 22, ciphers, key exchange) are compiled into the binary and still apply. If you rely on system SSH config for GitHub access (e.g., proxy or custom port), git push will fail inside the sandbox.

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
1. Check that `bwrap` (bubblewrap) is installed
2. Install permission rules and hook config to `~/.claude/settings.json`
3. Install the PreToolUse validation hook to `~/.claude/hooks/validate-command.sh`
4. Add a `claude` bwrap wrapper function to `~/.bashrc`
5. Create `.claude/settings.local.json` in the current directory if missing

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

Each repo gets a `.claude/settings.local.json` for guard rail permission overrides:

```bash
./scripts/opt-in-project.sh /path/to/repo
```

Or do it manually:

```bash
mkdir -p /path/to/repo/.claude
cp config/project-settings.json /path/to/repo/.claude/settings.local.json
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

## API Keys and Authentication

The sandbox blocks `~/.config/gh`, `~/.aws`, and other credential stores. See **[docs/api-keys-and-auth.md](docs/api-keys-and-auth.md)** for how to inject tokens via parent environment variables, 1Password CLI, or other secret managers.

## Customization

### Adding Toolchain Paths

If you use additional toolchains under `~/`, add them to the `OPTIONAL_RO_BINDS` loop in `config/claude-wrapper.sh`:

```bash
for dir in "$HOME/.nvm" "$HOME/.npm" "$HOME/.cargo" "$HOME/.rustup" \
           "$HOME/.local/bin" "$HOME/.pyenv" "$HOME/.config/git" \
           "$HOME/.rbenv" "$HOME/.goenv" "$HOME/.sdkman"; do
  [ -d "$dir" ] && OPTIONAL_RO_BINDS="$OPTIONAL_RO_BINDS --ro-bind $dir $dir"
done
```

### Moving Commands Between Permission Tiers

If you trust a runtime in a specific project, you can move it from `ask` to `allow` in that project's `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(python3 *)"
    ]
  }
}
```

### Diagnosing Permission Errors

If a command fails with "Read-only file system", the bwrap wrapper is not mounting that path as writable. Check `config/claude-wrapper.sh` for the mount configuration.

If a command fails with "No such file or directory" for a path under `~/`, the `--tmpfs $HOME` mount is hiding it. Add a `--ro-bind` entry for the needed path in the wrapper.

## File Structure

```
.
├── README.md
├── install.sh              # Full installation script
├── uninstall.sh            # Restores previous settings
├── config/
│   ├── user-settings.json  # User-level permissions + hooks (~/.claude/settings.json)
│   ├── project-settings.json  # Template for per-project guard rail overrides
│   └── claude-wrapper.sh   # bwrap sandbox wrapper function
├── docs/
│   └── api-keys-and-auth.md  # Guide for configuring API keys and auth
├── hooks/
│   └── validate-command.sh # PreToolUse hook for bypass detection
└── scripts/
    ├── opt-in-project.sh   # Opt in a single project
    └── opt-in-all.sh       # Opt in all repos under a directory
```

## Requirements

- Claude Code on Linux
- [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`) — required
- Bash shell
- `jq` (recommended, for config merging during install)

## License

MIT
