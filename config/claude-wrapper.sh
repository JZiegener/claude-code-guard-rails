# Claude Code wrapper: launches claude inside a bubblewrap sandbox with
# read-write project access, credential isolation, and auto project opt-in.
#
# Why external bwrap instead of Claude Code's built-in sandbox?
# Claude Code's sandbox has a mount ordering bug: allowRead re-mounts
# override allowWrite bind mounts, making the project directory read-only
# for Bash commands (git, npm, etc.) even when allowWrite: ["."] is set.
# See: https://github.com/CaptainMcCrank/SandboxedClaudeCode
claude() {
  # Auto-create project .claude/settings.json if missing
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
  }
}
SETTINGS
    echo "Created .claude/settings.json (permission overrides for this project)"
  fi

  # Auto-inject GH_TOKEN from existing gh auth login if not already set
  if [ -z "${GH_TOKEN:-}" ] && command -v gh &>/dev/null; then
    GH_TOKEN=$(gh auth token 2>/dev/null) && export GH_TOKEN
  fi

  # --- SSH agent socket forwarding ---
  # Forward the agent socket so Claude can sign SSH operations (git push, etc.)
  # Private keys (~/.ssh/id_*) are NEVER mounted — only the agent socket and
  # public keys for host verification.
  local SSH_BINDS=""
  local SSH_ENV=""
  if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    SSH_BINDS="--bind $(dirname "$SSH_AUTH_SOCK") $(dirname "$SSH_AUTH_SOCK")"
    SSH_ENV="--setenv SSH_AUTH_SOCK $SSH_AUTH_SOCK"
  fi
  for pubkey in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [ -f "$pubkey" ] && SSH_BINDS="$SSH_BINDS --ro-bind $pubkey $pubkey"
  done
  [ -f "$HOME/.ssh/known_hosts" ] && SSH_BINDS="$SSH_BINDS --ro-bind $HOME/.ssh/known_hosts $HOME/.ssh/known_hosts"

  # --- D-Bus / GNOME Keyring ---
  # Claude Code stores auth tokens in the system keyring via D-Bus.
  # Without this, Claude's built-in authentication won't work.
  local DBUS_BINDS=""
  local DBUS_ENV=""
  local KEYRING_BINDS=""
  local XDG_RUNTIME="/run/user/$(id -u)"
  if [ -S "$XDG_RUNTIME/bus" ]; then
    DBUS_BINDS="--bind $XDG_RUNTIME/bus $XDG_RUNTIME/bus"
    DBUS_ENV="--setenv DBUS_SESSION_BUS_ADDRESS unix:path=$XDG_RUNTIME/bus"
  fi
  if [ -d "$XDG_RUNTIME/keyring" ]; then
    KEYRING_BINDS="--bind $XDG_RUNTIME/keyring $XDG_RUNTIME/keyring"
  fi

  # --- Git config ---
  local GITCONFIG_BIND=""
  [ -f "$HOME/.gitconfig" ] && GITCONFIG_BIND="--ro-bind $HOME/.gitconfig $HOME/.gitconfig"

  # --- Claude global config ---
  local CLAUDE_JSON_BIND=""
  [ -f "$HOME/.claude.json" ] && CLAUDE_JSON_BIND="--bind $HOME/.claude.json $HOME/.claude.json"

  # --- Toolchain paths (read-only except npm cache) ---
  local OPTIONAL_RO_BINDS=""
  for dir in "$HOME/.nvm" "$HOME/.cargo" "$HOME/.rustup" \
             "$HOME/.local/bin" "$HOME/.pyenv" "$HOME/.config/git"; do
    [ -d "$dir" ] && OPTIONAL_RO_BINDS="$OPTIONAL_RO_BINDS --ro-bind $dir $dir"
  done
  # npm cache needs write access for caching
  local NPM_BIND=""
  [ -d "$HOME/.npm" ] && NPM_BIND="--bind $HOME/.npm $HOME/.npm"

  # --- Claude binary ---
  # Resolve the real path of the claude binary. type -P finds the binary
  # on PATH (ignoring this wrapper function), readlink -f follows symlinks.
  # If the binary lives under $HOME (e.g. ~/.local/bin/claude symlinked to
  # ~/.local/share/claude/versions/X.Y.Z), we need to mount both the
  # symlink's directory and the target's directory back into the sandbox
  # since --tmpfs $HOME wipes everything.
  local CLAUDE_BIN
  CLAUDE_BIN="$(type -P claude)"
  local CLAUDE_REAL
  CLAUDE_REAL="$(readlink -f "$CLAUDE_BIN")"
  local CLAUDE_BINDS=""
  # Mount symlink's parent directory if under $HOME
  local CLAUDE_BIN_DIR
  CLAUDE_BIN_DIR="$(dirname "$CLAUDE_BIN")"
  if [[ "$CLAUDE_BIN_DIR" == "$HOME"* ]]; then
    CLAUDE_BINDS="--ro-bind $CLAUDE_BIN_DIR $CLAUDE_BIN_DIR"
  fi
  # Mount target's parent directory if different and under $HOME
  local CLAUDE_REAL_DIR
  CLAUDE_REAL_DIR="$(dirname "$CLAUDE_REAL")"
  if [[ "$CLAUDE_REAL_DIR" == "$HOME"* ]] && [ "$CLAUDE_REAL_DIR" != "$CLAUDE_BIN_DIR" ]; then
    CLAUDE_BINDS="$CLAUDE_BINDS --ro-bind $CLAUDE_REAL_DIR $CLAUDE_REAL_DIR"
  fi

  # --- Env var passthrough ---
  local EXTRA_ENV=""
  [ -n "${GH_TOKEN:-}" ] && EXTRA_ENV="$EXTRA_ENV --setenv GH_TOKEN $GH_TOKEN"

  # Launch claude inside bubblewrap
  #
  # Mount order:
  #   1. --ro-bind / /              Read-only root (system, binaries, libs)
  #   2. --tmpfs $HOME              Wipe home dir (blocks ~/.aws, etc.)
  #   3. --bind $PWD $PWD           Project dir read-write (git, npm, etc.)
  #   4. --bind $HOME/.claude       Claude config read-write (session state)
  #   5. --ro-bind settings/hooks   Protect guard rail config from modification
  #   6. SSH agent socket + pubkeys SSH auth without exposing private keys
  #   7. D-Bus + keyring            Claude Code built-in auth
  #   8. --ro-bind .gitconfig       Git user config
  #   9. --ro-bind toolchains       Read-only nvm, cargo, etc.
  #  10. --bind .npm                npm cache read-write
  #  11. --bind /tmp                Worktrees and temp files
  #
  # NOT mounted (invisible inside sandbox):
  #   ~/.ssh/id_*  (private keys)   ~/.aws          ~/.gnupg
  #   ~/.config/gh (gh auth state)  ~/other-repos
  bwrap \
    --ro-bind / / \
    --tmpfs "$HOME" \
    $CLAUDE_BINDS \
    --bind "$PWD" "$PWD" \
    --bind "$HOME/.claude" "$HOME/.claude" \
    --ro-bind "$HOME/.claude/settings.json" "$HOME/.claude/settings.json" \
    --ro-bind "$HOME/.claude/hooks" "$HOME/.claude/hooks" \
    $CLAUDE_JSON_BIND \
    $SSH_BINDS \
    $DBUS_BINDS \
    $KEYRING_BINDS \
    $GITCONFIG_BIND \
    $OPTIONAL_RO_BINDS \
    $NPM_BIND \
    --bind /tmp /tmp \
    --dev /dev \
    --proc /proc \
    --setenv HOME "$HOME" \
    --setenv USER "$USER" \
    $SSH_ENV \
    $DBUS_ENV \
    $EXTRA_ENV \
    --share-net \
    --unshare-pid \
    --die-with-parent \
    --chdir "$PWD" \
    "$(type -P claude)" "$@"
}
