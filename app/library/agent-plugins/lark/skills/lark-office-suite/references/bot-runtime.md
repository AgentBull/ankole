# Bot runtime contract

Ankole injects `lark-cli` with the app ID and tenant token derived from this Agent's available Lark signal binding. The bot owns its cloud operations; it does not borrow the operator's storage identity.

```bash
lark-cli --version
test -n "${LARKSUITE_CLI_APP_ID:-}" && test -n "${LARKSUITE_CLI_TENANT_ACCESS_TOKEN:-}"
```

If preflight fails, stop and report that the Agent has no available Lark signal binding. Never run CLI setup or interactive authorization commands.

Always run `lark-cli` through the one-shot `command` tool. The main agent does not expose a persistent shell across Turns, so every invocation must be self-contained.

For every executable call:

- pass `--as bot --format json` explicitly;
- decide success from exit code zero or top-level `ok: true`;
- inspect command help and generated schema instead of guessing flags or request fields;
- use relative paths for `--file`, `--output`, `--output-dir`, and `@file` arguments;
- use `--dry-run` for uncertain writes;
- add `--yes` to a `high-risk-write` only after explicit confirmation;
- never print, persist, or request the tenant token.
- never run the CLI self-update command; the Agent Computer image pins the supported version.

Do not use the CLI's bundled top-level skills for routing, identity, setup, or authorization. A curated reference may direct you to one installed, version-matched content-format reference for payload grammar; in that case use only its syntax and block-lifecycle rules. This skill's bot-only runtime remains authoritative.
