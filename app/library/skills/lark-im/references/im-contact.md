# IM and Contact

## Messages and chats

Start with `lark-cli im --help`. Prefer shortcuts for common workflows and typed resources for the rest.

Common bot-capable shortcuts include:

```bash
lark-cli im +chat-list --as bot --format json
lark-cli im +chat-search --query "project" --as bot --format json
lark-cli im +chat-members-list --chat-id oc_xxx --page-all --as bot --format json
lark-cli im +chat-messages-list --chat-id oc_xxx --page-all --as bot --format json
lark-cli im +messages-mget --message-ids om_xxx,om_yyy --as bot --format json
lark-cli im +threads-messages-list --thread-id omt_xxx --page-all --as bot --format json
lark-cli im +messages-send --chat-id oc_xxx --text "status update" --as bot --format json
lark-cli im +messages-reply --message-id om_xxx --text "acknowledged" --as bot --format json
lark-cli im +messages-resources-download --message-id om_xxx --file-key file_xxx --type file --output lark-downloads/report.pdf --as bot --format json
```

`+chat-list --as bot` lists group chats only; its P2P listing mode requires a user identity and is outside this skill. For the current inbound DM or group, derive the `oc_...` chat ID from the Turn's `signal_channel_id` as described in `bot-runtime.md`, then call `+chat-messages-list --chat-id ... --as bot` directly.

Use `+chat-create`, `+chat-update`, and typed `im chat.members` operations for group administration. Use typed resources under `im messages`, `im reactions`, `im pins`, `im chats`, and `im chat.*` for delete, forward, merge-forward, read-user, urgent, reaction, pin, manager, moderation, and member operations. Before any typed call:

```bash
lark-cli schema im.<resource>.<method>
lark-cli im <resource> <method> --help
```

Only proceed if command help lists bot identity. Bot visibility depends on app availability, chat membership, and whether the bot is owner or manager. A successful empty result does not imply the tenant has no matching messages or chats.

For direct messages, prefer `+messages-send --user-id <open_id>` when supported by command help. Include an idempotency key on retried sends. For cards, use the CLI's documented card input and validate the JSON; do not invent CardKit payload fields.

## Contact and directory

Start with `lark-cli contact --help`. Under the pinned CLI's bot identity, the curated Contact path resolves a user only when a stable ID is already known:

```bash
lark-cli contact +get-user --user-id ou_xxx --user-id-type open_id --as bot --format json
```

Do not use `contact +search-user` or `contact user_profiles batch_query`: in v1.0.69 they require user identity. Other typed Contact methods are in scope only when their generated schema explicitly includes `bot` in `_meta.access_tokens`; validate that before presenting the method as available.

Directory access is constrained by the application's availability range. When a known target cannot be resolved, distinguish `not found` from `outside app visibility` and `missing scope`; do not fall back to guessing an ID from a display name. If the caller only has an email, phone number, or display name, report that this bot-only CLI surface cannot safely resolve it rather than switching identity.
