# Bot runtime contract

Ankole installs `lark-cli` in the Agent Computer image and injects the app ID and tenant token derived from this Agent's available Lark signal binding. The application belongs to the digital employee; it is not the human operator's identity.

For an inbound Lark Turn, `<agent_environment_info>` includes the canonical `signal_channel_id`. Remove the leading `lark:` before passing that current chat ID to a CLI `--chat-id` flag. Do not search for or guess the current chat ID when this value is present.

## Preflight

```bash
lark-cli --version
test -n "${LARKSUITE_CLI_APP_ID:-}" && test -n "${LARKSUITE_CLI_TENANT_ACCESS_TOKEN:-}"
```

If either variable is absent, stop and report that this Agent has no available Lark signal binding. Do not run CLI setup, credential initialization, or interactive authorization commands.

Always run `lark-cli` through the one-shot `command` tool. Do not run it in `interactive_terminal`: terminal sessions persist across Turns and retain the binding environment from when the session was created.

## Every executable call

- Pass `--as bot` explicitly, even though the runtime default is also bot.
- Prefer `--format json`; use `--jq` only after confirming the returned shape.
- Success is process exit code zero or top-level `ok: true`. Do not look for a legacy top-level numeric code.
- Never print, persist, copy, or inspect the tenant token. Do not ask the operator for credentials already owned by the binding.
- Do not run the CLI self-update command; the Agent Computer image pins the supported version.
- Input and output paths must be relative to the current workspace. Use stdin or `@relative-file.json` for large payloads.
- Use `--dry-run` before a write when the request body or target is uncertain.
- Commands marked `high-risk-write` require explicit confirmation. Add `--yes` only after that confirmation.

The CLI help and schema bundled in the installed version are authoritative. Do not load the CLI's upstream skill pack: it includes personal-assistant authorization paths that do not apply to Ankole.
