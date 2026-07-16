# Bot runtime contract

Ankole injects the app ID and tenant token derived from this Agent's available Lark signal binding.

```bash
lark-cli --version
test -n "${LARKSUITE_CLI_APP_ID:-}" && test -n "${LARKSUITE_CLI_TENANT_ACCESS_TOKEN:-}"
```

If preflight fails, stop and report that this Agent has no available Lark signal binding. Do not initialize CLI credentials or start an interactive authorization flow.

Always run `lark-cli` through the one-shot `command` tool. Do not run it in `interactive_terminal`: terminal sessions persist across Turns and retain the binding environment from when the session was created.

Every executable call must use `--as bot --format json`. Decide success from exit code zero or top-level `ok: true`. Inspect `--help` and `schema` before constructing payloads. Use only relative paths for request files and outputs. Never print or persist the tenant token, and never ask the operator for credentials already owned by the binding.

Do not run the CLI self-update command; the Agent Computer image pins the supported version.

Use `--dry-run` for uncertain writes. A command marked `high-risk-write` is intentionally blocked without confirmation; add `--yes` only after the user has explicitly approved the concrete action.

Do not load the CLI's upstream skill pack because its personal-assistant authorization model does not apply to an Ankole digital employee.
