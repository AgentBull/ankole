# Bot runtime contract

Ankole installs `lark-cli` in the Agent Computer image and injects the app ID and a refreshed tenant-token file derived from this Agent's available Lark signal binding. The application belongs to the digital employee; it is not the human operator's identity.

For an inbound Lark Turn, `<agent_environment_info>` includes the canonical `signal_channel_id`. Remove the leading `lark:` before passing that current chat ID to a CLI `--chat-id` flag. A group `speaker` uses `name(uid)` as defined by the Ankole system prompt. Do not search for, guess, or ask the user to repeat the current chat ID when it is present.

## Preflight

```bash
lark-cli --version
test -n "${LARKSUITE_CLI_APP_ID:-}" && test -n "${ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE:-}"
```

If either variable is absent, stop and report that this Agent has no available Lark signal binding. Do not run CLI setup, credential initialization, or interactive authorization commands.

Always run `lark-cli` through the one-shot `command` tool. The main agent does not expose a persistent shell across Turns, so every invocation must be self-contained.

## Every executable call

- Pass `--as bot` explicitly, even though the runtime default is also bot.
- Prefer `--format json`; use `--jq` only after confirming the returned shape.
- Success is process exit code zero or top-level `ok: true`. Do not look for a legacy top-level numeric code.
- Never read, print, persist, or copy the token file. Do not ask the operator for credentials already owned by the binding.
- Do not run the CLI self-update command; the Agent Computer image pins the supported version.
- Input and output paths must be relative to the current workspace. Use stdin or `@relative-file.json` for large payloads.
- Use `--dry-run` before a write when the request body or target is uncertain.
- Commands marked `high-risk-write` require explicit confirmation. Add `--yes` only after that confirmation.

The CLI help and schema bundled in the installed version are authoritative. Do not load the CLI's upstream skill pack: it includes personal-assistant authorization paths that do not apply to Ankole.
