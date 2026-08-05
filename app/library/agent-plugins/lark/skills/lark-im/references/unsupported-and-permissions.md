# Unsupported operations and permission handling

This skill supports only application-bot calls. Reject any operation whose command help offers only a person's identity, even if the CLI contains the command.

Common exclusions include personal feed shortcuts and groups, personal message flags, personal mailbox state, personal calendar subscriptions, and shortcuts whose semantics are "my resources" without an explicit target supported for bot calls. Meeting or Minutes shortcuts that internally depend on a human's search history are also excluded unless installed help explicitly lists bot.

When an API call fails:

1. Preserve the structured error and inspect `error.code`, `error.message`, `error.hint`, `permission_violations`, and `console_url`.
2. For a missing scope, provide the returned developer-console URL and the exact missing bot scopes. Do not start an authorization flow.
3. For visibility or membership errors, explain which bot precondition is missing: application availability, chat membership, owner/manager role, resource sharing, or tenant boundary.
4. For `authentication/credential_unavailable`, report that the current binding credential could not be confirmed. Do not describe this as a missing scope, membership, or resource permission, and do not request credentials in chat.
5. Do not retry writes unless the command is documented as idempotent or an idempotency key was supplied.

An unavailable API is not permission to switch identities. Ask the operator to share the resource with the bot, add the bot to the target, or grant the application scope.
