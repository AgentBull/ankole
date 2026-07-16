# Unsupported operations and permission handling

This skill supports only the application bot. Reject any command that requires a person's identity. Common exclusions include personal Drive subscriptions, personal "recent" or "my files" views without a bot target, person-owned permission application flows, and creating a personal Wiki space.

Bot access is resource-scoped as well as scope-scoped. A tenant token does not make every tenant document visible. The resource must be owned by the app, explicitly shared with the bot/application, located in a visible space, or otherwise allowed by the endpoint.

On failure:

1. Preserve the structured error and inspect `permission_violations`, `console_url`, `error.code`, `error.message`, and `error.hint`.
2. For missing scopes, return the developer-console URL and exact bot scopes. Do not start an authorization flow.
3. For resource visibility, ask the operator to share the file/folder/space with the application or add the bot as a member.
4. For an absent injected token, report that this Agent has no available Lark signal binding; do not request credentials in chat.
5. Do not retry imports, creates, copies, or mutations unless the operation is idempotent or the first result is known not to have committed.

When a bot-capable API is absent from a shortcut, use the typed generated resource or raw `lark-cli api` mode after inspecting the official endpoint. Do not switch identities to fill the gap.
