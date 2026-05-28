# ToolSet And Tool

AIAgent tools are code-owned runtime capabilities exposed to the model when the
agent profile enables their ToolSet. Tool execution belongs inside AIAgent.
MailBox only delivered the triggering entry.

The implementation lives under `BullX.AIAgent.Tools.*`.

## Registry

`BullX.AIAgent.Tools.Registry` builds a request-time registry from:

- built-in ToolSets;
- enabled `:"bullx.ai_agent.toolset"` plugin extensions.

The registry does not persist Tool or ToolSet definitions and does not read the
agent profile. Profile filtering happens after registry construction.

ToolSet fields include:

- id;
- description;
- default enabled flag;
- disableable flag;
- availability;
- tool names.

Tool fields include:

- name;
- ToolSet id;
- description;
- parameter schema;
- strict flag;
- provider options;
- access: `ordinary` or `privileged`;
- parallel-safety flag;
- module;
- availability;
- timeout;
- retry config.

## Built-Ins

Current built-in ToolSets:

- `basic`: always enabled and not disableable.
- `web`: enabled by default and disableable.

Current built-in tools:

- `clarify`, ordinary access, non-parallel.
- `web_search`, ordinary access, parallel-safe, availability depends on web
  search provider config, timeout 75 seconds.
- `web_extract`, ordinary access, parallel-safe, availability depends on web
  extraction provider config.

## Profile Filtering

The agent profile can enable or disable ToolSets where the ToolSet is
disableable. It cannot change a tool's access level, schema, callback module, or
runtime safety metadata.

`effective_tool/3` distinguishes unknown, disabled, and unavailable tools.

## Execution

`BullX.AIAgent.Tools.Dispatcher` validates tool arguments through ReqLLM tool
schema execution, checks AIAgent ACL, builds a tool context, runs the tool
module, and persists tool results into the conversation.

Tool context includes an idempotency key built from:

- conversation id;
- assistant message id;
- tool call id;
- tool name;
- arguments.

## Clarify

`clarify` asks the current human-facing run for missing information. The visible
clarification output goes through IMGateway using the current reply address.

## Web Tools

Web tools use BullX-owned adapters configured through `BullX.Config.AIAgent`.
Current provider config supports web search and extraction provider selection
and provider-specific API keys.

## Invariants

- Tool definitions are code-owned.
- Agent profiles choose ToolSet availability, not tool contracts.
- ACL is enforced at execution time.
- Tool result persistence belongs to AIAgent conversations.
- Visible tool-driven IM output goes through IMGateway.
