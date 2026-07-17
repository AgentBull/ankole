# DingTalk Adapter

The DingTalk (钉钉) adapter connects a DingTalk enterprise-internal application to
Ankole as both a **SignalsGateway chat adapter** (`signals_gateway.adapter`) and a
**Principals identity/login provider** (`principals.identity_provider`) over one
Stream-mode long connection. Its capability face is trimmed to what the DingTalk
robot API actually offers; the differences from a full IM adapter (e.g. Lark) are
platform realities, declared explicitly rather than simulated.

Source lives in `plugins/dingtalk_adapter/` (control-plane plugin) and
`libs/dingtalk_openapi/` (the thin provider client). Module-specific schemas and
platform facts are in `internals/docs/DingTalkAdapter.zh.md`.

## Names

| Name | Value |
|---|---|
| Plugin id | `dingtalk-adapter` |
| Chat adapter id | `dingtalk` |
| Identity provider id | `dingtalk` |
| Default chat binding name | `dingtalk` |
| Default platform subject namespace | `dingtalk-main` |
| Elixir namespace | `Ankole.Plugins.DingTalkAdapter`, `DingTalkOpenAPI` |

## Control Plane Plugin Declaration

`Ankole.Plugins.DingTalkAdapter` implements `Ankole.Plugins.Plugin` and declares
two adapters sharing one connection:

- **`signals_gateway.adapter`** — `config_module: Config`, `ingress_module:
  Inbound`, `outbox_module: Outbox`, `reply_preview_module: AICard`,
  `connection_supervisor: ConnectionSupervisor`.
  - `supported_group_message_modes: ["addressed_only"]` — **DingTalk supports
    `addressed_only` and nothing else.** The platform delivers a group message to
    an enterprise-internal robot only when the bot is @-mentioned (DMs always
    arrive), so `observe_all` and `may_intervene` cannot exist on DingTalk: the
    bot never sees unaddressed group traffic, and no polling or second product
    line simulates it. The console offers only this mode, config validation
    rejects any other value, and use cases that require reading unaddressed
    group messages (e.g. passive weekly topic digests) need a channel on a
    platform that can observe them.
  - `inbound_capabilities: ["entry_receive", "action_event"]`.
  - `outbound_capabilities: ["post_entry", "delete_entry", "card"]`.
- **`principals.identity_provider`** — `module: IdentityProvider`,
  `connection_reconciler: ConnectionReconciler`, `capabilities:
  ["oidc_authorization", "oidc_code_exchange", "directory_full_sync",
  "directory_realtime_sync"]`.

Plugin `children` install a unique `Registry`, a `DynamicSupervisor`, and the
`ConnectionReconciler`. There is no startup group sync (DingTalk exposes no
"robot's groups" API); channel mirrors are built lazily on first inbound message.

## Setup Fields

Chat binding (`signals_gateway.dingtalk.bindings.<agent_uid>`):

| Field | Type | Required | Default | Notes |
|---|---|---|---|---|
| `clientId` | string | yes | | Enterprise app AppKey (also the Stream `clientId`). |
| `clientSecret` | secret | yes | | AppSecret; encrypted at rest. |
| `robotCode` | string | no | = `clientId` | Robot code override for special cases. |
| `cardTemplateId` | string | no | | AI card template id (schema: `plugins/dingtalk_adapter/priv/card_template/README.md`); empty degrades AI replies to Markdown. |
| `group_message_mode` | select | yes | `addressed_only` | The only value the platform can honour; modeled for the binding policy. |
| `platformSubjectNamespace` | string | no | `dingtalk-main` | |
| `userName` | string | no | `钉钉 / DingTalk` | Outbound display name / card title fallback. |
| `baseURL` | string | no | | Overrides both API domains (local end-to-end only). |

Identity provider (`principals.identity_providers.dingtalk.<id>`) adds
`oidc.enabled`, `oidc.scope` (`openid` / `openid corpid`), `sync.contacts`,
`sync.websocket`, and `sync.pageSize` (1..100). `sync.websocket` is forced off when
`sync.contacts` is off.

One agent gets at most one enabled DingTalk binding, and one `clientId` cannot be
assigned to two agents (`Config.validate_binding_assignment/3`).

## Runtime Connection

`DingTalkOpenAPI.Stream.Client` owns one Stream-mode connection per `{"dingtalk",
clientId}`:

1. Register: `POST /v1.0/gateway/connections/open` with `{clientId, clientSecret,
   subscriptions, ua, localIp}` → `{endpoint, ticket}`. The ticket is ~90s and
   single-use, so it is always fetched fresh and never cached.
2. Upgrade a WebSocket at `{endpoint}/connect?ticket=...`.
3. Route JSON text frames by `type`:
   - SYSTEM `ping` → echo the `opaque` payload with the same `messageId`,
     synchronously on the WS loop.
   - SYSTEM `disconnect` → the server is rebalancing; re-register and reconnect at
     once, letting the old socket close.
   - EVENT / CALLBACK → dispatch in a supervised task; the ack is written only
     after the handler (gateway ingress) commits.

Acks follow the protocol: EVENT → `{"status": "SUCCESS" | "LATER"}`, CALLBACK →
`{code, data: {"response": ...}}`, unregistered CALLBACK topic → `404`. A crashed
dispatch is not acked, so the platform re-delivers; ingress idempotency (the
`actor_events` unique constraint on `source_event_id`) makes re-delivery safe.
Reconnect uses exponential backoff (1s → 60s) with a fresh ticket each attempt.

`ConnectionReconciler` derives one connection per app from enabled chat bindings
plus active identity providers, merging their consumers. The `Dispatcher`
registers the message + card CALLBACK topics only when a chat consumer is present
and the contact EVENT types only when an identity consumer with realtime sync is
present, so a single-purpose connection never over-subscribes.

## Provider Identity

The canonical platform subject is the enterprise `userid`, which arrives on chat
inbound as `senderStaffId` and on login as the resolved directory `userid` — so a
person who chats and a person who logs in map to one Principal.

A chat message without `senderStaffId` (external group member, or an app not yet
published) is **fail-closed**: it is logged and ignored rather than mapped onto an
unactionable encrypted `senderId`.

## Channel And Thread Identity

- `signal_channel_id` = `dingtalk:<url-encoded conversationId>`.
- Channel kind: `conversationType` `"1"` → `im_dm`, `"2"` → `im_group`.
- `reply_mode` = `:channel` — DingTalk has no anchored reply, so outbound goes to
  the conversation, not a specific entry.
- `provider_thread_id` and `reply_to_source_entry_id` are always `nil` (no threads,
  no reply parent in the callback).
- Group channel names come from `conversationTitle` (best effort). For a DM the
  counterpart `userid` is recorded in channel metadata (`dm_user_id`) so outbound
  DMs can address the recipient.

## Inbound Events

Robot message CALLBACK (`/v1.0/im/bot/messages/get`) normalizes to `emit_entry`:

- Text (`text.content`) and rich text (`content.richText[]` joined verbatim)
  become the entry text. A voice message keeps its text empty — the platform's
  ASR transcript rides the attachment descriptor, never the mirror, so the
  mirror only ever records what the user actually typed.
- A leading `@<token>` is stripped only when the at-list attributes it to the
  bot alone (the payload carries no bot display name to match against); a
  message opening with `@someone-else` keeps its text intact, and interior `@`
  is always left untouched.
- `explicit?` is true for every DM and for a group message with `isInAtList`.
- Empty/unsupported bodies with no attachments are ignored.

DingTalk's robot callback face has **no** recall, edit, or reaction events, so
`entry_removed`, `edit_entry`, and reactions are not declared. A user recalling a
message leaves the mirror stale — a recorded provider limitation, not a gateway
failure.

## Attachments

`picture`/`audio`/`video`/`file` and rich-text image segments carry a
`downloadCode` that resolves to a **short-lived** URL. Attachments are materialized
before ingress: the bytes are pulled immediately via `POST
/v1.0/robot/messageFiles/download` and stored in worker user-files; the mirror and
actor events never persist a `downloadCode` or temporary URL. Audio attachments
keep their ASR `recognition` in the descriptor so the model reads it without
transcription.

## Actions

Card button clicks arrive as a CALLBACK (`/v1.0/card/instances/callback`) and
become `emit_action`. The button params are extracted from the callback's
`content → cardPrivateData → params` nesting (bare shapes tolerated), and a
managed value — the portable `ankole.interactive_output.action.v1` protocol the
card renders into every control — passes through structurally, with string-typed
integers restored at the provider edge. Dedup identity is semantic: the same
control on the same interaction version is one logical answer however often the
platform redelivers it, while a different press on the same card is a distinct
actor event. The operator `userId` is required (missing → ignored); Principal
authorization is re-verified on the callback path — a visible button is not
permission.

## Recall

`delete_entry` recalls by `processQueryKey` (the id returned on send), via
`/v1.0/robot/groupMessages/recall` (group) or `/v1.0/robot/otoMessages/batchRecall`
(DM). An entry not sent by this adapter (no `processQueryKey`) returns
`:unsupported_target`.

## Outbound

`post_entry`:

- Text is degraded to DingTalk's Markdown subset and split under the `msgParam`
  byte budget, then sent as `sampleMarkdown` (formatted) or `sampleText` (plain).
- A single attachment is uploaded to the old-domain media endpoint and sent as
  `sampleImageMsg` (image) or `sampleFile` (a listed office/archive type);
  unsupported extensions return `:unsupported_file_type` rather than silently
  reshaping.
- DM sends target the `dm_user_id` recorded on the channel; group sends use the
  `conversationId` as `openConversationId`.

`card`:

- A card outbox row renders its `interactive_output` into the standard template
  (`InteractiveCard`) and delivers one instance keyed by an `outTrackId` derived
  from the row's idempotency key, so a retry re-delivers the same instance.
  Without a configured `cardTemplateId` the row's `fallback_visible_text` posts
  as a plain message instead of parking the row unsupported.

DingTalk provides no message edit, no reply anchor, no divider system message, and
no history query, so `edit_entry`, `reply_entry`, `divider`, and
`outbound_reconciliation` are not declared. `/robot/*/send` has no idempotency
parameter, so a crash after send but before recording `processQueryKey` leaves a
documented duplicate window; card instances are idempotent by `outTrackId`. A
`flowControlledStaffIdList` on a DM send surfaces as a retryable rate-limit
error. Split text chunks close and reopen code fences at display time only —
the durable source stays byte-exact.

These differences are provider capability limits, not exceptions to Ankole's
cross-provider user stories. The adapter exposes the strongest real DingTalk
path available and must not synthesize recall, edit, thread, or reconciliation
signals that the platform cannot provide.

## Streaming AI Card

`AICard` implements the `reply_preview_module` lifecycle against DingTalk's
template-hosted card model. The operator builds the standard Ankole AI card
template on the card platform (variable schema and build guide:
`plugins/dingtalk_adapter/priv/card_template/README.md`) and supplies its
`cardTemplateId`; Ankole injects the fixed variable set where `answer` is the
streaming Markdown variable, and drives the native typing/finished/error states.

- **Idempotent reconcile.** `open`, `update`, and `finalize` each run one reconcile
  of the current answer against the durable page ledger. Pages are keyed by a
  deterministic `outTrackId` (`ankole:<actor_event_id>:<page_index>`), so
  create/deliver/stream are replay-safe and a control-plane restart resumes the
  same cards.
- **Create + deliver.** A page that does not yet exist is created and delivered via
  `POST /v1.0/card/instances/createAndDeliver` (`callbackType: "STREAM"`) into the
  card open space — `dtv1.card//IM_GROUP.{conversationId}` for a group,
  `dtv1.card//IM_ROBOT.{userId}` for a DM.
- **Stream.** The `answer` variable is written with `PUT /v1.0/card/streaming`
  (`isFull: true`, mandatory for Markdown variables), matching Ankole's accumulated
  answer-snapshot model. The transient `thought` streams on its own key, digest-
  gated so an unchanged draft costs no write. A failed turn finalizes with
  `isError`; `awaiting_input` finalizes without sealing so template buttons stay
  live.
- **Pagination.** Past the conservative single-card source budget the chain rolls
  onto a continuation card. Sealed pages are immutable: their byte-exact source
  slices are pinned in the ledger, only the remainder after the sealed prefix is
  ever re-split, and an unchanged page receives no provider write of any kind —
  a sealed (finalized) card is never streamed again. Page boundaries close and
  reopen code fences at display time while durable source math stays lossless.
- **Finalize.** The tail page finalizes its stream and writes the terminal card
  structure (thought and activity blanked) with `PUT /v1.0/card/instances`,
  carrying only the tail page's slice.
- **Degrade — terminal only, once.** A working-mode sync **never posts plain
  messages**: a missing `cardTemplateId`, a permanent `param.contentUnsafe`
  rejection, or an answer rewrite behind the sealed prefix marks the reply
  degraded and returns a non-retryable error that disables the transient preview
  for the turn. The durable terminal delivery then falls back to plain
  `sampleMarkdown`/`sampleText` messages, split under the same byte budget, with
  every delivered chunk ledgered in the checkpoint so an outbox retry never
  re-sends one.
- **Refresh.** The optional `refresh` callback repaints the checkpointed
  presentation (which never carries a thought) onto the tail card — this is how
  the host's thought-lease sweeper strips stale reasoning after a crash and how
  resolved interactions repaint their locked controls.

The checkpoint on the actor event carries the page ledger (per-page
`outTrackId`, byte-exact source slice, sealed flag), streaming state, the last
renderer-safe `ReplyPresentation`, the degraded flag and plain-chunk ledger, and
— while a thought is visible — a `cleanup_at` lease deadline.

## Identity Provider

`IdentityProvider` implements login and directory sync:

- **Login.** authorize page → redirect `authCode` → `POST
  /v1.0/oauth2/userAccessToken` (with `corpId`) → `GET /v1.0/contact/users/me`
  (unionId) → `POST topapi/user/getbyunionid` (enterprise `userid`) → `POST
  topapi/v2/user/get` (hydrate). A `unionId` with no employee (`60121`) fails the
  login closed.
- **Full sync.** BFS the department tree from root id `1` via
  `topapi/v2/department/listsub`, materializing a directory group per department,
  then page users per department via `topapi/v2/user/list` and upsert each. Email
  prefers `org_email`; department membership is refreshed from `dept_id_list`.
  Permission gaps skip-and-warn rather than emptying the directory.
- **Realtime.** Contact EVENT frames carry only id lists. `user_add_org` /
  `user_modify_org` / `user_active_org` re-query each `userid` and upsert;
  `user_leave_org` disables the named subjects directly (a full sync only
  upserts and would leave a departed Principal active), falling back to a full
  sync when a disable is guard-refused; a missing id, a department change, or an
  org removal enqueues a full sync (source `dingtalk_contact_event`, with the
  shared event-triggered dedup window). Admin changes are metadata-only and
  ignored.

## Capability Comparison

| Contract face | DingTalk | Nature of difference |
|---|---|---|
| Inbound `entry_receive` | ✅ (group narrowed to addressed) | platform |
| Inbound `entry_removed` / reactions | ❌ | platform has no such events |
| Inbound `action_event` (card callback) | ✅ | equal |
| Outbound `post_entry` / `delete_entry` | ✅ | equal |
| Outbound `card` | ✅ | template-hosted instance (needs `cardTemplateId`; falls back to text) |
| Outbound `reply_entry` / `edit_entry` / reactions / `divider` | ❌ | platform has no such API |
| Outbound `outbound_reconciliation` | ❌ | no history query |
| Streaming AI reply | ✅ AI card | equal (template-hosted, smaller page budget) |
| Identity login + directory (full + realtime) | ✅ | equal |
| Skills face | ❌ | no official DingTalk CLI; separate future work |

## Invariants

- At-least-once inbound: commit before ack; `source_event_id` uses the message
  entity id (not the transport frame id) so re-delivery is idempotent.
- No `downloadCode` or temporary media URL is ever persisted.
- The enterprise `userid` is the sole canonical platform subject; a subject without
  one is never fabricated from an encrypted id.
- AI card mutations are serialized by the checkpoint owner; button callbacks
  re-verify the Principal.

## Status

Implemented and unit-tested: the provider client (`libs/dingtalk_openapi`), the
chat adapter (inbound, outbox text/attachment/recall/card, error classification),
the AI card lifecycle (streaming, pagination with immutable sealed pages,
degrade-once plain fallback, restart recovery, refresh), and the identity
provider (login chain, directory full sync, contact events including departure
disable). End-to-end: a fake DingTalk platform plus the transport suite exist;
the main-flow and lifecycle suites remain. A real-tenant smoke pass must confirm
the platform shapes listed as unverified in
`internals/docs/DingTalkAdapter.zh.md` §13 (card open-space and `cardData`
variable mapping, streaming size limits and rewrites to finalized cards,
template import, `sampleFile` type list, and card callback param passthrough).
