# AIAgent ACL

AIAgent ACL decides whether an Agent Principal may process an invocation or run
a tool. It delegates policy decisions to `BullX.AuthZ`; it does not own a
separate permission store.

The implementation lives in `BullX.AIAgent.ACL`.

## Invocation Checks

For ordinary generation, AIAgent calls:

```elixir
BullX.AuthZ.authorize(caller, "ai_agent:<agent_uid>", "invoke", context)
```

The caller is the Principal resolved from IMGateway actor facts. Missing or
invalid callers are denied.

Setup-created AIAgents grant ordinary `invoke` to the built-in `all_humans`
computed group by default, so active Human Principals may invoke the initial
agent without per-user grants. The setup flow also keeps an agent self `invoke`
grant for self-addressed internal calls.

Privileged operations also require:

```text
action = "invoke_privileged"
resource = "ai_agent:<agent_uid>"
```

The current profile elevation strategy is only `deny`; unsupported strategies
are invalid profile configuration.

## Tool Checks

Tools declare access as `ordinary` or `privileged`.

Tool schemas can still be rendered to the model when a ToolSet is enabled, but
actual execution is checked by `BullX.AIAgent.Tools.Dispatcher` through the
AIAgent ACL boundary.

ACL denial writes a safe error result for the agent run or tool call. It is not
retried by MailBox.

## Context

AIAgent passes sanitized context to AuthZ. Context may include conversation,
mailbox, channel, scope, tool, and request information, but AuthZ remains the
only owner of grant evaluation.

## Invariants

- MailBox delivery is not permission to spend model/tool budget.
- AIAgent ACL is deny-by-default.
- Tool execution is checked at execution time, not only by hiding schemas.
- Privileged access is an additional grant, not a replacement for ordinary
  invocation checks.
