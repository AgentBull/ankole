# AIAgent Core

AIAgent is the current implemented MailBox Agent type for AI colleague behavior.
It handles a `mailbox_entries` row, consumes normalized CloudEvents mail data,
persists conversation state, runs ACL checks, calls tools and LLM providers, and
sends visible assistant output through IMGateway.

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

Reply addresses, channel facts, and conversation context are read from
`entry.cloud_event["data"]`.

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
transcript rendered after the latest compatible compression. A latest addressed turn
with visible output may cancel generation, recall output, and republish the new
message content when the revised input is still deliverable. If the revised
payload is no longer addressed or ambient-deliverable, the revision only
cancels or recalls the already-triggered turn. Historical revisions add a stable
ref marker to the original message and append an introspection message
describing the edit, recall, or delete without immediately starting generation.

For coalesced IM batches, revision handling uses ordered batch item metadata to
update or remove only the affected source message. The effective lane is
recomputed after the revision; any active addressed item makes the whole batch
addressed. If no addressed item remains, only `engage_all` ambient remainder is
republished; ignored remainder does not create a new AIAgent turn.

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
- daily reset enabled at `04:00` in `Etc/UTC`;
- context `max_turns = 50`;
- compression threshold ratio `0.70`;
- prompt cache enabled;
- time awareness granularity `:hour`;
- ACL elevation strategy `:deny`;
- generation lease TTL `600_000` ms;
- generation heartbeat interval `30_000` ms;
- generation max runtime `1_800_000` ms.

## Conversation Identity

`BullX.AIAgent.ConversationKey` builds stable conversation keys from
`data.conversation_context` when present, falling back to the legacy normalized
channel/scope shape for callers that have not supplied that context yet:

- lane: addressed or ambient;
- agent uid;
- channel adapter;
- channel id;
- scope id;
- thread id;
- actor external account id when addressed actor isolation is configured.

The key does not include raw provider payload, MailBox entry id, or CloudEvents
subject. Ambient conversations always use scene isolation. Addressed
conversations use the profile's `conversation_isolation_mode`.

## Tables

`conversations` stores:

- `agent_uid`
- `conversation_key`
- `ended_at`
- `generation`
- `metadata`

There can be only one active conversation for one agent and key.

`conversation_messages` stores an append-only AIAgent transcript:

- `conversation_id`
- `role`: `user`, `assistant`, `tool`, or `im_ambient`
- `kind`: `normal`, `summary`, `introspection`, or `error`
- `status`: `generating` or `complete`
- `content`
- optional `covers_range`
- optional MailBox session id for the current processing window
- optional `metadata.transcript_effect` for superseded, undone, recalled,
  deleted, or interrupted rows
- event source/id
- `metadata`

Inbound normal user and ambient messages are idempotent by
`conversation_id + event_source + event_id`.
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
supports streaming. Chunks are UX preview state with retention TTLs, not
conversation facts. The complete assistant `Message` persisted after generation
is the durable fact for both streaming and non-streaming replies.

Server-side aborts such as `stop`, addressed edit, recall, or delete may
interrupt generation before a complete assistant message exists. Client stream
disconnects are UX interruptions only and do not cancel the server-side
generation by themselves.

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

AIAgent command feedback is control-plane output delivered through the current
IM reply address and is not mirrored to `im_messages`.

## Ambient Input

Ambient IM messages are stored as `im_ambient` conversation messages. The
source `group_message_mode` decides whether they are context only
(`observe_all`) or eligible for proactive intervention (`engage_all`).

Normal ambient messages are not rendered as regular prompt dialogue and are not
compressed as normal user/assistant exchange content.

## Invariants

- AIAgent owns its business state; MailBox only delivers entries.
- Visible assistant output goes through IMGateway.
- Generation lease state is persisted on the conversation and can be inspected
  after process restart.
- Raw conversation messages are kept; summaries are overlay messages.
- Tool definitions are code-owned, while enabled ToolSets are profile-owned.
