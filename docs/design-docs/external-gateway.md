# External Gateway

External Gateway bridges external channels and BullX agents. It accepts normalized provider facts from channel adapters, updates the latest observed external projection, delivers only agent-relevant events to the directly bound agent, and executes explicit outbound side-effect intents written by that agent into the gateway outbox.

It is not an audit subsystem. Auditability is a low-priority byproduct here, not a design driver. The gateway should stay small enough that its runtime behavior can be explained from three owned surfaces:

- `external_rooms` and `external_messages`: latest observed provider-visible projection.
- `external_gateway_agent_events` and `external_gateway_input_tombstones`: short-lived PostgreSQL unlogged input window.
- `external_gateway_outbox` and Redis visible-output streams: provider side-effect execution and weak in-progress output visibility.

## Current Implementation

The implementation lives under `app/src/external-gateway/`.

- `runtime.ts` loads active agents, creates one adapter instance for each enabled agent external binding, passes the adapter a normalized `ExternalGatewayAdapterContext`, routes webhooks, drains ready agent events, calls the agent executor, and drains pending outbox rows.
- `core/events.ts` defines the plugin-facing normalized adapter contract: `emitMessage`, `emitMessageDeleted`, `emitReaction`, and `emitAction`.
- `handlers.ts` applies `group_message_mode`, writes projection, records tombstones, enqueues agent events, and computes the gateway-facing agent session id.
- `agent-events.ts` owns the unlogged input window, addressed-message batch window, process-local in-flight handoff, tombstones, and session/batch key helpers.
- `outbox.ts` executes provider-visible outbound operations. Provider failures are stored on the outbox row and must not turn an already accepted agent input into a failed input.
- `core/projection.ts` owns the latest-state projection sink for rooms, messages, deletes, and reactions.
- `core/visible-output-stream.ts` owns the Redis weak visible stream for in-progress output chunks.
- `testing/mock-im-adapter.ts` and `mock-im-integration.test.ts` are the user-story integration fixture.
- `packages/sdk/src/plugins.ts` exposes the structural plugin contract.
- `plugin/lark-adapter/src/index.ts` implements the Feishu/Lark adapter on that contract.

The database schema is in `app/src/common/db-schema/external-gateway.ts`. The migration creates `external_gateway_agent_events` and `external_gateway_input_tombstones` as unlogged tables. Drizzle's TypeScript schema does not express `UNLOGGED`, so the migration is the storage truth for that property.

Provider-specific gaps are recorded in [External Gateway provider limitations](./external-gateway-provider-limitations.md).

## Runtime Shape

One agent can have multiple external bindings. A binding belongs to exactly one agent. The same upstream room can still be observed by multiple agents through separate bindings, so the global agent-to-room relation is many-to-many, while each runtime unit is `agent + binding`.

Each binding has:

- `name`: the public route key used by `/api/agents/:agentUid/webhooks/:channel`.
- `adapter`: the registered adapter factory id.
- `group_message_mode`: `addressed_only`, `observe_all`, or `may_intervene`.

The runtime does not use Chat SDK queue, lock, cache, or state tables. Adapters call the normalized context directly. Startup builds adapters before the HTTP server accepts webhooks, and each webhook response waits until projection/input-window acceptance has completed unless an adapter explicitly uses a background option for a provider-specific reason.

Adapter implementations should normalize from the provider surface they actually receive at runtime. Do not add compatibility branches for both raw provider events and SDK-normalized events unless the real plugin execution path can deliver both shapes.

The plugin SDK contract should type the normalized room, message, lifecycle, reaction, and action fields. Provider raw payloads, provider SDK metadata, and formatted rich content may remain provider-specific values, but `emitMessage`, `emitMessageDeleted`, `emitReaction`, and `emitAction` must not be bare `unknown` entry points.

## End-to-End Flow

```text
provider webhook or long-connection event
  -> adapter validates and normalizes provider payload
  -> adapter calls ExternalGatewayAdapterContext.emit*
  -> handler applies binding policy and tombstone checks
  -> observed provider-visible facts update external_rooms/external_messages
  -> agent-relevant facts enter external_gateway_agent_events
  -> runtime drains ready events and calls the agent executor
  -> agent persists its durable effect and may enqueue pending outbox rows
  -> gateway marks the input done after agent acceptance
  -> external_gateway_outbox drains supported provider side effects
  -> successful visible outbound is projected into external_messages
  -> failed/unsupported outbound remains only in external_gateway_outbox
```

Production startup defaults to the AIAgent executor. It returns only durable acceptance: External Gateway marks the input `done` after the agent has persisted the relevant conversation effect and any required pending outbox rows. Provider send failure after that point stays on `external_gateway_outbox` and does not roll the input window back to `failed`.

`MockExternalGatewayAgentExecutor` remains a test fixture for External Gateway adapter/runtime coverage. It is not the production default and should not shape agent conversation semantics.

## Projection Contract

`external_rooms` and `external_messages` are a latest-state mirror of provider-visible facts BullX has observed. They are consumers of External Gateway, not part of Gateway routing state.

`external_rooms.id` is the adapter-normalized external room id. It is not scoped by agent uid, binding name, plugin id, or provider app id by the gateway. The adapter must therefore choose an id that is stable and unique enough for the provider realm it represents; the gateway treats that id as the projection identity and will not add hidden tenant or app scoping later.

`external_messages` stores one row per `(room_id, message_id)` and uses that pair as its primary key. It does not store `thread_id`: for the projection table, `thread_id` is derivable from the projected room and provider-visible message id rather than additional identity. Provider thread scope still exists in the gateway input window and outbox as `provider_thread_id`, where it is needed for batching and channel delivery.

Projection behavior:

- Receive upserts message text, formatted content, attachments, links, author, mentions, metadata, raw payload, and sent time.
- Deletes and recalls hard-delete the projected message because the table represents current visible state.
- Reactions update the message reaction map and preserve raw provider emoji keys when available.
- Re-projecting a message preserves existing reaction state.
- Unsupported or unserializable raw values are sanitized instead of crashing projection.
- Inbound edit events are not part of the current External Gateway contract.

`addressed_only` intentionally does not project non-addressed group messages. The projection is meant to match what BullX has chosen to observe for that binding, not to become a universal audit log.

## Agent Sessions

External Gateway still computes a gateway-facing operational session id from agent uid and external room id:

```text
<agent_uid>:external-room:<provider_room_id>
```

The same room always routes to the same gateway session. Different rooms route to different gateway sessions. `provider_thread_id` participates in batching, message context, and provider delivery, but it does not define the session boundary and is not duplicated in `external_messages`. Two Feishu thread messages in the same chat or two GitHub issue comments in the same room scope stay in one gateway session; a different chat, issue room, or repository room gets a different session. When multiple agents observe the same external room, the `agent_uid` prefix gives each agent its own gateway session.

AIAgent owns product conversation state in `ai_agent_conversations`, `ai_agent_messages`, and `ai_agent_llm_turns`. Its `conversation_key` uses `agent_uid + binding_name + provider_realm_id + provider_room_id`; it does not include provider thread or addressed/ambient lane. Daily Reset and `/new` create a new active `ai_agent_conversations.id` under the same key without changing the External Gateway session/projection identity.

## Binding Policy

`group_message_mode` is a channel binding policy, not a Feishu/Lark-specific rule.

| Mode | Non-addressed group receive | Projection | Agent delivery |
| --- | --- | --- | --- |
| `addressed_only` | Ignore | No | No |
| `observe_all` | Observe only | Yes | No |
| `may_intervene` | Observe as ambient | Yes | Direct ambient event |

DM messages are always addressed. Group messages are addressed when the adapter exposes a structured mention, reply-to-bot, application command, or provider-native bot invocation. Plain text containing `@` is not enough unless the adapter has normalized it into an addressed fact.

`may_intervene` does not use the addressed-message batch queue. It emits an ambient event directly. Any separate ambient queue, ambient batching, or intervention policy belongs inside the agent.

## Agent Event Types

External Gateway sends a small CloudEvents-style envelope to the agent. The envelope is a shape convention, not an external runtime dependency.

| Event | Projection behavior | Agent delivery | Gateway batching |
| --- | --- | --- | --- |
| Addressed DM/group `message.received` | Upsert message | `delivery_mode = addressed` | Batchable |
| Non-addressed group receive with `addressed_only` | No-op | None | None |
| Non-addressed group receive with `observe_all` | Upsert message | None | None |
| Non-addressed group receive with `may_intervene` | Upsert message | `delivery_mode = ambient` | Direct |
| `message.deleted` | Hard-delete projected message | Lifecycle only if prior receive reached agent | Direct |
| `message.recalled` | Hard-delete projected message | Lifecycle only if prior receive reached agent | Direct |
| `reaction.added` / `reaction.removed` | Update reaction map | None | None |
| `action` | Project only if adapter provides visible state | `delivery_mode = action` | Direct |
| `/new` / `/compress` / `/retry` / `/steer` / `/stop` text command | Project visible command message | `delivery_mode = command` typed stub | Direct |
| Image/file/attachment message | Upsert with attachment refs | Same as receive policy | Same as receive policy |
| Agent outbound `post` | Project after provider success | None | Outbox |
| Agent outbound `reply` | Project after provider success | None | Outbox |
| Agent outbound `edit` | Re-project edited bot message after provider success | None | Outbox |
| Agent outbound `delete` | Delete projection after provider success | None | Outbox |
| Agent outbound `reaction_add` / `reaction_remove` | Update reaction map after provider success | None | Outbox |
| Agent outbound `divider` / `card` | Project fallback visible text after provider success | None | Outbox |
| Streaming delta | Redis weak visible stream only | None | No durable projection |

GitHub issues, PRs, comments, and review comments map into these generic message lifecycle shapes. External Gateway should not add provider-specific event types unless they cannot be represented by this table.

## Command Stubs

`handlers.ts` recognizes `/new`, `/compress`, `/retry`, `/steer`, and `/stop` as visible text commands and emits a `slash_command` event with:

```json
{
  "name": "steer",
  "raw": "/steer be concise",
  "argsText": "be concise",
  "status": "stub"
}
```

External Gateway does not implement undo, steering, retry, stop, or assistant-output recall semantics. A command stub must not create, delete, recall, or edit provider-visible bot output on its own.

`/undo` is not a command. If a user wants to retract input, the provider recall/delete lifecycle event is the supported path.

## Input Window

`external_gateway_agent_events` is the operational input window from Gateway to Agent. PostgreSQL stores accepted pending facts, while the running gateway process owns short-lived in-flight work. There is no database lease state and no automatic failed retry loop.

Important columns:

- `agent_uid`, `binding_name`
- `provider_room_id`, `provider_thread_id`
- `provider_event_id`, `provider_message_id`
- `type`, `delivery_mode`
- `batch_key`, `actor_key`
- `payload`
- `status`, `available_at`

The primary key is `(agent_uid, binding_name, provider_event_id)`. There is no surrogate row id because provider event id is the operational identity for this input window.

Normal addressed receives use a short quiet window before delivery. When a new addressed receive is enqueued, pending receives with the same batch key get the same later `available_at`. When the runtime claims a ready batch, it claims only the contiguous same-actor prefix:

- `Alice, Alice, Alice` can become one delivery.
- `Alice, Bob, Alice` becomes three deliveries. The later Alice message must not jump over Bob.

Only addressed `message.received` events are batchable. Ambient, lifecycle, command, and action events are direct.

The status values are deliberately small:

- `pending`: accepted by the gateway and not yet delivered to the agent executor.
- `done`: accepted by the agent executor after durable agent effect/outbox rows are written. Outbound provider failures after this point belong to `external_gateway_outbox`.
- `failed`: the gateway could not hand the input to the agent executor. This is a terminal runtime fact, not an automatic retry state.

`external_gateway_input_tombstones` is a short-lived unlogged window for delete/recall events that arrive before the receive. Its primary key is `(agent_uid, binding_name, provider_room_id, provider_message_id)`, so a recall in one room cannot suppress a same-id message in another room. A tombstone prevents a late stale receive from re-projecting or waking the agent. Tombstones are operational state, not audit history.

## Outbound and Recovery Boundary

External Gateway executes only explicit agent outbound intents. It does not infer that a recalled user message should recall or delete prior bot output.

`external_gateway_outbox` uses `(agent_uid, binding_name, outbound_key)` as its primary key. `outbound_key` is the agent-supplied idempotency key for one provider-visible side effect, so a separate row id would not add identity.

Supported outbox behavior:

- `post`: requires adapter `post_message`; projects the bot message only after provider success.
- `reply`: requires adapter `reply_message`; projects the bot message only after provider success.
- `edit`: requires adapter `edit_message`; re-projects the bot message only after provider success.
- `delete`: requires adapter `delete_message`; deletes the projected target only after provider success.
- `reaction_add`: requires adapter `add_reaction`; updates the projected reaction map only after provider success.
- `reaction_remove`: requires adapter `remove_reaction`; updates the projected reaction map only after provider success.
- `divider`: requires adapter `divider` and posts through the adapter's message surface; projection stores fallback visible text.
- `card`: requires adapter `card` and posts through the adapter's message surface; projection stores fallback visible text until provider-native card projection is richer.
- unsupported operations are marked `unsupported` and do not change projection.
- provider failures do not fake visible state and do not make the already accepted input event failed.

Outbox rows also store `idempotency_key`, retry counters, last attempt/error fields, provider send started time, recovery state, and provider message id. If a process restarts after `platform_send_started_at`, the dispatcher first attempts adapter reconciliation when a `provider_message_id` exists. If the adapter cannot prove idempotency/reconciliation, the row becomes `failed + unknown_after_send` instead of blindly replaying a possibly delivered message. Adapters that support idempotent sends must reuse the same `idempotency_key` across retries.

Final assistant-message truth belongs to AIAgent. AIAgent owns turns, assistant messages, delivery metadata, summaries, and the rule for whether a user recall/delete should also delete bot output. For example, AIAgent can choose to delete only assistant outputs after the last compression summary. External Gateway cannot make that decision because it does not own turns or summaries.

Redis visible-output streams are weak progress only. They use `agentUid + sessionId + streamId` keys and are safe to lose. Final output recovery is through the agent/outbox boundary, not Redis.

The recovery boundary preserves the current ownership split: External Gateway delivers lifecycle facts to the agent, and then executes only the explicit outbound operation the agent returns. Source-message recall/delete semantics, transcript updates, and any decision to recall prior assistant output belong to AIAgent because it owns turns, summaries, and assistant-message truth.

## Feishu/Lark Adapter Boundary

The Lark plugin uses one shared long-connection consumer per `domain + appId`. Feishu/Lark long-connection delivery is cluster-mode: opening multiple clients for the same app id can split events randomly. Chat ingress and identity realtime sync therefore attach handlers to the same shared connection.

The chat-channel config includes the same `domain` field as identity-provider config. A Feishu app and a Lark app with the same `appId` are different connection realms, and chat plus identity realtime sync can share a connection only when both use the same `domain + appId`.

The adapter may use Lark SDK `LarkChannel` for supported IM behavior and register additional official events on the same SDK dispatcher when `LarkChannel` does not expose them. `im.message.recalled_v1` is supported through this path. Feishu/Lark message edit events are not supported because Feishu/Lark does not expose an official edit notification as of June 6, 2026.

## Edge Cases

The integration test fixture covers these contract cases:

- `addressed_only` ignores non-mentioned group messages and does not write projection.
- `observe_all` mirrors non-addressed group messages and does not wake the agent.
- `may_intervene` mirrors non-addressed group messages and emits direct ambient events.
- Literal `@Agent` text is not a structured mention.
- DM messages are addressed.
- Structured group mentions are addressed even in `addressed_only`.
- Consecutive same-actor addressed messages batch.
- A different actor breaks the batch.
- Same room with different provider threads keeps the same agent session.
- Different rooms produce different agent sessions.
- Recall/delete while an addressed receive is pending removes the pending input.
- Recall/delete before receive creates a tombstone so the stale receive is ignored.
- Recall tombstones are scoped by external room.
- Recall/delete of an observed-only message updates projection but does not wake the agent.
- Recall/delete of a delivered message emits lifecycle to the agent but does not delete bot output unless the agent returns a delete intent.
- Raw reaction keys survive projection and re-projection.
- Multiple bindings can see the same provider message id without collision when room ids differ.
- The same external room can fan out to multiple agents without duplicating projection rows.
- GitHub-like webhook facts map to generic receive/delete shapes.
- Final outbound posts are projected only after provider success.
- Provider outbound failure marks the outbox row failed while the accepted input stays done.
- Agent returned reaction, divider, and card intents execute only through declared adapter capabilities.
- `/undo` is treated as normal text, not a typed command.
- `/new`, `/compress`, `/retry`, `/steer`, and `/stop` are typed command events.
- Outbox edit/reply/idempotency/reconciliation options are passed through the SDK adapter contract.

## Verification

Run the user-story integration surface:

```sh
cd app && bun test src/external-gateway/mock-im-integration.test.ts
```

When changing schema, runtime dispatch, plugin adapter types, projection, or outbox behavior, also run:

```sh
cd app && bun run type-check
bun test src/external-gateway
cd ../plugin/lark-adapter && bun test
```
