# AIAgent Core

AIAgent is the current implemented MailBox Agent type for AI colleague behavior.
It handles a `mailbox_entries` row, consumes normalized CloudEvents mail data,
persists conversation state, runs ACL checks, calls tools and LLM providers, and
sends visible IM output through IMGateway.

The implementation lives in `BullX.AIAgent` and `BullX.AIAgent.*`.

## Entry Point

MailBox dispatches entries for `agents.type = "ai_agent"` by calling:

```elixir
BullX.AIAgent.handle_mailbox_entry(invocation, entry)
```

`invocation.target_ref` is the Agent uid. The entry carries:

- `mailbox_session_id`
- `mailbox_entry_id`
- `cloud_event`
- `attention`
- optional `reply_address`

AIAgent loads the active agent Principal and validates
`agents.profile["ai_agent"]` through `BullX.AIAgent.Profile`.

## Event Handling

MailBox delivers source-neutral AIAgent input mail:

- `bullx.message.received`
- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`
- `bullx.command.invoked`

AIAgent dispatches by CloudEvents type and MailBox entry attention:

- `bullx.message.received` with `attention = addressed` appends a normal user
  message and may start generation.
- `bullx.message.received` with `attention = ambient` appends ambient context.
- `bullx.message.edited`, `bullx.message.recalled`, and
  `bullx.message.deleted` enter the source-neutral message revision handler.
- `bullx.command.invoked` enters the command handler.

Unsupported event types are ignored with telemetry instead of creating
conversation state.

Message revision handling is not prompt construction. AIAgent finds the existing
conversation message from provider refs, then applies the change only when the
target belongs to the current mailbox session and is still visible in the
branch rendered after the latest compatible compression. A latest addressed turn
with visible output may cancel generation, recall output, and republish the new
message content. Historical revisions add a stable ref marker to the original
message and append an introspection message describing the edit, recall, or
delete without immediately starting generation.

## Profile

An AIAgent profile is stored on the Agent Principal row and cast by
`BullX.AIAgent.Profile`.

Required profile fields:

- `ai_agent.main_llm`
- `ai_agent.mission`

Defaulted fields include:

- `compression_llm`: main LLM with low reasoning effort;
- `heavy_llm`: main LLM with high reasoning effort;
- `conversation_isolation_mode = :scene`;
- `unmentioned_group_messages = :observe_only`;
- daily reset enabled at `04:00` in `Etc/UTC`;
- context `max_turns = 50`;
- compression threshold ratio `0.70`;
- prompt cache enabled;
- time awareness granularity `:hour`;
- ACL elevation strategy `:deny`;
- generation lease TTL `600_000` ms;
- generation heartbeat interval `30_000` ms;
- generation max runtime `1_800_000` ms.

Setup currently creates a default profile with
`unmentioned_group_messages = "may_intervene"`.

## Conversation Identity

`BullX.AIAgent.ConversationKey` builds stable conversation keys from
`data.conversation_context` when present, falling back to the legacy normalized
channel/scope shape for callers that have not supplied that context yet:

- lane: addressed or ambient;
- agent uid;
- channel adapter;
- channel id;
- scope id;
- actor external account id when addressed actor isolation is configured.

The key does not include raw provider payload, MailBox entry id, or CloudEvents
subject. Ambient conversations always use scene isolation. Addressed
conversations use the profile's `conversation_isolation_mode`.

## Tables

`conversations` stores:

- `agent_uid`
- `conversation_key`
- `current_leaf_message_id`
- `ended_at`
- `generation`
- `metadata`

There can be only one active conversation for one agent and key.

`conversation_messages` stores a tree:

- `conversation_id`
- `parent_id`
- `role`: `user`, `assistant`, `tool`, or `im_ambient`
- `kind`: `normal`, `summary`, `introspection`, or `error`
- `status`: `generating` or `complete`
- `content`
- optional `covers_range`
- optional MailBox session and entry ids
- event source/id
- `metadata`

Inbound normal user and ambient messages are idempotent by `mailbox_entry_id`.
Ambient introspection messages are idempotent by an
`ambient_batch_idempotency_key` metadata field.

## Generation

`BullX.AIAgent.Runner` owns the model/tool loop.

Before generation it:

1. checks ACL for ordinary invocation;
2. acquires a generation lease stored in `conversations.generation`;
3. renders prompt messages;
4. expands enabled tools;
5. calls `BullX.LLM.chat/3` or `stream_chat/4`.

The loop persists assistant messages and tool result messages. Tool calls are
executed through `BullX.AIAgent.Tools.Dispatcher` with ACL enforcement and
idempotency context.

If provider context overflow is detected, Runner may call automatic compression
and retry rendering.

## Visible Output

Non-streaming visible output calls:

```elixir
BullX.IMGateway.send_message(attrs)
```

Streaming visible output uses `BullX.MailBox.StreamingOutput` to create a Redis
stream, then asks the adapter to consume the stream when the reply address
supports streaming. Chunks are stored in Redis with retention TTLs. The final
assistant message records delivery metadata.

## Commands

AIAgent handles canonical command names:

- `new`
- `compress`
- `retry`
- `steer`
- `stop`
- `undo`

IMGateway-direct commands such as `/root_init`, `/webauth`, `/command`, and
`/status` are handled before IMGateway handoff.

## Ambient Input

Ambient IM messages are stored as `im_ambient` conversation messages. When the
profile mode is `observe_only`, they become context only. When the mode is
`may_intervene`, ambient batching can produce an introspection message and start
generation when the batch policy decides to intervene.

Normal ambient messages are not rendered as regular prompt dialogue and are not
compressed as normal user/assistant exchange content.

## Invariants

- AIAgent owns its business state; MailBox only delivers entries.
- Visible IM output goes through IMGateway.
- Generation lease state is persisted on the conversation and can be inspected
  after process restart.
- Raw conversation messages are kept; summaries are overlay messages.
- Tool definitions are code-owned, while enabled ToolSets are profile-owned.
