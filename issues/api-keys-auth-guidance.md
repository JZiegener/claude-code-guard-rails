# Add guidance for configuring API keys and authentication mechanisms

**Status: Resolved** — see [docs/api-keys-and-auth.md](../docs/api-keys-and-auth.md)

## Summary

The guard rails settings need guidance on how to securely configure API keys and other authentication tokens (e.g., GitHub tokens, cloud provider credentials) so that Claude Code can use tools like `gh`, cloud CLIs, or other authenticated services.

## What was added

- **docs/api-keys-and-auth.md**: Comprehensive guide covering:
  - Passing tokens via parent environment variables
  - 1Password CLI integration (`op run`, `op read`, per-project `.env.claude` files)
  - Claude Code `env` setting in `settings.local.json`
  - Other secret managers (Vault, AWS Secrets Manager, macOS Keychain, pass)
  - Updated wrapper function with automatic 1Password injection
  - Security considerations and recommendations
- **README.md**: Added link to the guide in a new "API Keys and Authentication" section
