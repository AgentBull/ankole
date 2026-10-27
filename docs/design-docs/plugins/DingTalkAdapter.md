# DingTalk Adapter

The DingTalk Adapter connects one DingTalk enterprise application to Ankole to
receive robot messages, send Agent replies, and synchronize DingTalk users and
departments. A single DingTalk Stream connection can carry both messaging and
directory events, while all provider credentials stay on the control plane.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the shared messaging, identity, and Plugin
contracts.

## Provider and Public Identity

On inbound events, the adapter reports an opaque `provider_conversation_id` and
`provider_message_id`, which `Conversations` resolves to a shared public
Conversation UUID and Message UUID. Every Agent observing that DingTalk
conversation within the same tenant reads those shared public records while
running in its own `conversation:<public UUID>` Session—a Binding defines an
observation and delivery route rather than owning the DingTalk room.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `dingtalk-adapter` |
| API version | `1` |
| Signal adapter ID | `dingtalk` |
| Signal configuration | `signals.dingtalk.bindings.<agent_uid>` |
| Identity adapter ID | `dingtalk` |
| Identity configuration | `principals.identity_providers.dingtalk.<id>` |
| Provider library | `plugins/dingtalk_adapter/lib/dingtalk_openapi` |

Because DingTalk delivers only @-mentioned group messages to enterprise robots,
the Signal adapter supports only `addressed_only` mode. Inbound capabilities are
`entry_receive` and `action_event`, and outbound capabilities are `post_entry`,
`delete_entry`, and `card`.

On the identity side, the adapter supports OIDC authorization, OIDC code
exchange, full directory sync, and real-time directory sync.

## Settings

Chat bindings configure these fields:

| Field | Purpose |
| --- | --- |
| `clientId` | Required enterprise application key |
| `clientSecret` | Required encrypted application secret |
| `robotCode` | Overrides the robot code |
| `cardTemplateId` | Selects the DingTalk AI card template |
| `group_message_mode` | Must be `addressed_only` |
| `identityProvider` | References the identity provider that owns the Principal subject namespace; a single provider is adopted by default, several require a choice, `:standalone` keeps the adapter default |
| `userName` | Sets the outbound display name |

Identity-provider configurations share the same `clientId` and `clientSecret`,
using `oidc.*` keys for sign-in and `sync.*` keys for user and department
imports.

Each Agent may enable at most one DingTalk binding, and a single `clientId`
cannot be assigned to two Agents; the binding save transaction enforces both
constraints before committing.

## Connect to DingTalk

`ConnectionReconciler` derives one Stream connection per DingTalk application so
chat bindings and real-time directory sync can share a single socket.
`Ankole.Plugins.ConnectionLifecycle` supervises one temporary Stream client per
connection key: if a client exits, `ConnectionLifecycle` restarts that key
immediately once and then backs off to 5 seconds and 30 seconds while leaving
other connections undisturbed.

Before opening each WebSocket session, the client requests a fresh Stream
ticket, then handles keepalive pings, disconnects, event frames, and card
callbacks. The client acknowledges each Stream frame only after its handler
commits; if the process crashes beforehand, DingTalk redelivers the frame and
Ankole's durable deduplication keys prevent duplicate records.

## Receive Messages

Robot message callbacks map to `entry_receive`, and interactive card callbacks
map to `action_event`. Direct messages always count as explicit input, while
group messages must include a DingTalk @-mention of the robot.

The adapter formats `provider_conversation_id` as
`dingtalk:<encoded_conversation_id>`. Because DingTalk's robot callback stream
exposes no anchored reply metadata, both provider thread ID and reply target
remain empty, and DingTalk emits no inbound edit, recall, or reaction events on
this path.

For sender attribution, the adapter reads the enterprise `senderStaffId`,
ignoring any callback that lacks `senderStaffId` and never treating an opaque
encrypted DingTalk user token as a Principal identity.

DingTalk delivers attachments as short-lived download codes. During ingress, the
adapter downloads each attachment immediately and writes the bytes to the file
service ([Files](../Files.md)); if downloading or storing fails, the adapter
logs the error and records the message without attachment bytes, never
persisting temporary download codes or ephemeral URLs.

## Send Replies

Outbound execution processes only durable Delivery intents: posting Markdown
text, uploading a single media attachment, recalling a message sent earlier by
the adapter, or rendering a template card.

Prose text converts to DingTalk's Markdown dialect—splitting long replies across
multiple DingTalk messages when needed—while the Rust kernel uses CommonMark
byte spans to keep fenced, indented, and inline code blocks untouched (live AI
Card streams apply their own paging and rendering rules). Supported attachment
types upload through DingTalk's media API, whereas unsupported file types fail
before the adapter reads blob bytes. Recalling an outbound message requires the
`processQueryKey` returned when the adapter originally sent it; targets missing
that key are rejected.

Because DingTalk's robot send endpoint offers neither caller-supplied
idempotency keys nor outbound message history queries, a crash right after an
HTTP send can produce a duplicate message on retry, and the adapter cannot
reconcile an uncertain send outcome.

## Show a Live AI Card

Operators who enable live reply previews build and publish the DingTalk card
template documented in `plugins/dingtalk_adapter/priv/card_template/README.md`
and set `cardTemplateId` on the binding. At runtime, `AICard` renders streaming
previews against that template using a deterministic `outTrackId` per card page.
DingTalk tracks card lifecycle on its side: a streamed card remains open until
the adapter sends `isFinalize` (or `isError` for a failed state).

The source Signal's checkpoint serves as the durable page ledger, storing each
page's source Markdown, `outTrackId`, sealed flag, last recoverable presentation,
and any active thought-cleanup deadline (`cleanup_at`, computed via
`PreviewAdapter.put_thought_lease/4` from the adapter's lease duration and
final-state flag, and cleared on final updates or updates without visible
reasoning). Once a page is sealed, it never changes—only the open tail page
accepts streaming Markdown updates—while provider-specific stream deadlines and
page-rollover rules stay inside the adapter.

In-progress AI Card updates never fall back to plain chat messages mid-turn. If
`cardTemplateId` is unset, DingTalk rejects the card payload, or a late revision
would mutate an already sealed page, the durable terminal Delivery sends plain
text instead, recording each delivered text chunk in the checkpoint so retries
resume cleanly after the last confirmed chunk.

## Import People and Departments

During OIDC sign-in, the adapter resolves the user's enterprise `staffId` before
returning a Principal. Full directory sync paginates through all departments,
users, and memberships under the active identity-provider configuration, failing
the sync if any page returns a missing or repeated cursor.

Real-time user events re-fetch the user's current DingTalk profile before
applying updates through `DirectoryAccess`, deduplicating deliveries on
`(eventId, userId)` and recording `eventBornTime` when present (if `eventId` is
missing, the handler fails so DingTalk Stream redelivers). User departures
record a provider restriction—even for the last active Human administrator—and
block unknown subjects from future admission; if a departure event omits user
IDs, the adapter logs it for operator review and enqueues a full sync, just as
department mutations and organization removals do.

A complete, error-free full sync snapshot can supply evidence to clear a
provider restriction after operator review, whereas OIDC sign-in and partial
real-time events cannot. No sync automatically restores an offboarded Human,
lifts a manual restriction, or disables members absent from a snapshot; see
[Human Offboarding](../HumanOffboarding.md).

## Restart and Recovery

Across restarts, durable state lives in PostgreSQL: `AppConfigure` holds
encrypted credentials, `Conversations` holds public Messages and Delivery
intents, `Signals` holds accepted stimuli, `Sessions` drives execution recovery,
and `Principals` / `AuthZ` store people, groups, memberships, and grants. Agent
Computer never receives DingTalk credentials. When a control-plane node
restarts, `ConnectionLifecycle` re-establishes Stream sockets automatically, and
running a full directory sync repairs any suspected identity drift.

## Tests

Automated tests cover the OpenAPI client, Stream frame dispatch, event
normalization, Delivery intent execution, AI Card checkpointing, OIDC sign-in,
and directory sync; end-to-end verification against live DingTalk servers
requires operator credentials and a published AI Card template.

Implementation paths:

- `plugins/dingtalk_adapter/lib/ankole/plugins/dingtalk_adapter.ex`
- `plugins/dingtalk_adapter/lib/ankole/plugins/dingtalk_adapter/`
- `plugins/dingtalk_adapter/lib/dingtalk_openapi/`
