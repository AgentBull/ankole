# Feishu and Lark Adapter

The Lark Adapter receives Feishu or Lark messages, sends Agent replies, and
imports organization users and departments. Chat bindings and identity providers
use separate settings, while all provider credentials remain on the control
plane.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the shared messaging, identity, and Plugin
contracts.

## Provider and Public Identity

On inbound events, the adapter reports an opaque `provider_conversation_id` and
`provider_message_id`, which `Conversations` resolves to a shared public
Conversation UUID and Message UUID. Every Agent observing that Feishu or Lark
chat within the same tenant reads those shared public records while running in
its own `conversation:<public UUID>` Session—a Binding defines an observation
and delivery route rather than owning the platform chat.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `lark-adapter` |
| API version | `1` |
| Signal adapter ID | `lark` |
| Signal configuration | `signals.lark.binding_configs.<id>` |
| Identity adapter ID | `lark` |
| Identity configuration | `principals.identity_providers.lark.<id>` |
| Connector ID | `lark` |
| Provider library | `plugins/lark_adapter/lib/feishu_openapi` |

The Signal adapter supports both `ai_colleague` bindings (routing to one AI
Colleague) and `sender_personal_assistant` shared Bot bindings (`agent_uid = nil`,
defaulting to `signal.channel.kind == 'im_dm'` and `unmatched_sender_policy = "manual_review"`,
resolving each matched active member and routing DMs to their Personal Assistant).
It supports all three group-message policies (`addressed_only`,
`observe_all`, and `may_intervene`), inbound capabilities `entry_receive`,
`entry_removed`, `reaction_add`, `reaction_remove`, and `action_event`, and
outbound capabilities `post_entry`, `reply_entry`, `edit_entry`, `delete_entry`,
`outbound_reconciliation`, `add_reaction`, `remove_reaction`, `divider`,
`card`, `form`, and `action_notice`.

On the identity side, the adapter supports OIDC authorization, OIDC code
exchange, full directory sync, and real-time directory sync.

## Product Names

Feishu serves mainland China, and Lark is its global edition. Ankole names a
configured identity provider or connector connection after the platform its
`domain` selects: a `feishu` configuration reads 飞书 in Simplified Chinese and
Feishu in every other locale, while a `lark` configuration reads Lark in every
locale. `Config.platform_name/1` owns that mapping, and the identity provider
and connector modules expose it through `platform_name/1`, so login buttons,
provider lists, and connection cards show the configured platform. The plugin
and adapter, including the adapter column of the chat binding list, read
飞书 / Lark in Simplified Chinese and Feishu / Lark elsewhere. Every `domain`
select offers the same two options: Feishu (Mainland China) and Lark (Global).

## Settings

Chat bindings configure these fields:

| Field | Purpose |
| --- | --- |
| `appID` | Required self-built application ID |
| `appSecret` | Required encrypted application secret |
| `domain` | Selects `feishu` or `lark` |
| `identityProvider` | References the identity provider that owns the Principal subject namespace; a single provider is adopted by default, several require a choice, `:standalone` keeps the adapter default |
| `userName` | Sets the outbound display name |

How the Agent treats unaddressed group messages is configured on the Signal
Binding itself. Both `signals.lark.binding_configs.<id>` and
`principals.identity_providers.lark.<id>` select or create a shared
`Ankole.Connectors` connection (`connector_auth_configs`, referenced via
`authConfigId` through `Ankole.Connectors.LegacyConfig`) that holds `appID`,
encrypted `appSecret`, and `domain`, while keeping behavior settings (`userName`,
`identityProvider`, `oidc.*`, and `sync.*`) in `AppConfigure`.

Before starting a chat connection owner, `ConnectionReconciler` fetches the bot
`open_id` from `bot/v3/info` inside the reconciler process and passes it only in
the owner's process-local chat consumer config as `runtimeBotOpenID`
(identity-only connections need no bot identity and skip this lookup).
`Ankole.Plugins.LarkAdapter.BotIdentity` caches each `(domain, appID)` lookup:

- Resolved `open_id` values cache for 24 hours.
- Failures cache until their retry deadline—honoring the provider's
  `Retry-After` or `x-ogw-ratelimit-reset` header when present, or backing off
  across `1`, `2`, `4`, `8`, `16`, and `30` minutes (both capped at 30 minutes).
  While a failure remains cached, the reconciler skips starting the owner and
  avoids extra provider calls, reporting the stable failure reason and retry
  timestamp; saving updated binding settings evicts the cached entry.

A single Agent may enable multiple Lark bindings, provided each enabled binding
claims a distinct `(domain, appID)` pair across the deployment (disabling a
binding releases its pair, and the binding save transaction validates ownership
before writing the binding or its configuration). Each binding persists behavior
settings under `signals.lark.binding_configs.<id>`, where `<id>` is the SHA-256
digest of `[tenant_id, binding_id]`, and links its `auth_config_id` to the
shared `connector_auth_configs` row.

## Connect to Feishu or Lark

Each `(domain, appID)` pair identifies one platform application.
`ConnectionReconciler` builds specs from stored settings alone
(`ConnectionReconciler.binding_spec/2`), resolves bot identity in
`owner_child_spec/3`, and hands each active pair to
`Ankole.Plugins.ConnectionLifecycle` to supervise a single temporary WebSocket
client: if a client exits, `ConnectionLifecycle` restarts that pair immediately
once and then waits 5 seconds and 30 seconds between subsequent attempts while
other pairs stay connected.

Chat bindings and real-time directory sync share one WebSocket whenever their
`(domain, appID)` pair and `appSecret` match; if two consumers supply
conflicting secrets for the same pair, Ankole marks that connection unavailable.
Restarts rebuild the active connection set from PostgreSQL.

The WebSocket client manages reconnects, keepalive pings, frame reassembly, and
event dispatch, acknowledging frames only after their handlers finish (provider
redeliveries are safe because control-plane writes are idempotent). In a
multi-node cluster, operators must pin each application connection to a single
node because the local process registry does not arbitrate connection ownership
across nodes.

## Receive Messages and Actions

Inbound messages, recalls, reactions, and card clicks normalize through
`Conversations.Observe`, which owns shared Messages and `ExternalMessageRef`
rows and enqueues required Agent work via `Ankole.Signals.accept_in_tx/1`.

Chats map to `provider_conversation_id` `lark:<encoded_chat_id>`, preserving the
original Feishu/Lark message ID and attaching root thread/reply IDs when
present. Direct messages and group messages carrying a structured @-mention of
the current bot count as explicit input; other group messages follow the
binding's group-message policy. Recalls emit `entry_removed`, emoji reactions
update stored message metadata without waking the Agent (keyed by operator
`user_id` when present, or `open_id` when Feishu omits `user_id`), and card
button/form actions always wake the Agent.

Every Lark identity path selects a primary immutable `external_id` in strict
priority order—`user_id`, then `union_id`, then `open_id`—never using mutable
contact addresses as the primary Lark `external_id`:

- Across message admission, directory sync, IM group membership, and card
  actions, the adapter binds whichever of those immutable IDs wins as primary
  and records the remaining Lark IDs as provider-scoped aliases on the same
  Principal in the same transaction (if an alias already belongs to another
  Principal, the entire transaction fails rather than reassigning the alias).
- External-organization collaborators who lack a local `user_id` fall back
  cleanly to `union_id` or `open_id`; only senders lacking all three immutable
  IDs are ignored. Both `enterprise_email` (`work_email`) and `email` bind under
  the `email` external-identity namespace.
- When sender lookup misses, the adapter's `author_hydrator` fetches the
  sender's Contact profile once to resolve `[user_id, union_id, open_id]` plus
  `email`, `mobile`, and `display_name` before identity admission proceeds.

During an inbound Turn, `<agent_environment_info>` exposes the public
Conversation UUID. Because Feishu message events omit sender display names,
identity admission projects any Contact-synced display name onto the event, and
for group turns the prompt renderer formats `speaker` as `name(uid)` (or
`uid(uid)` when no name is known). Identity admission uses an existing binding,
matching contact information, or the external primary ID to select or create a
Human within the binding's tenant. Provider-scoped Lark IDs and `email` bindings
keep their credential meaning when the Principal is renamed.

Inbound content covers plain text, rich posts, stickers, images, files, audio,
media, video, locations, shared chats, and shared user cards:

- Before starting a file download—including files listed in the top-level
  `files` array of a rich post—the adapter records a durable `pending`
  observation across every matching chat binding, allocates the numeric
  attachment ID, materializes the bytes once through
  `Ankole.Conversations.Attachments` into unified Drive ([Files](../Files.md))—storing
  an immutable `file_objects` row, freezing `object_id` on `message_attachments`,
  and linking the file into the conversation root (`/drive/ChatDrive`) while
  keeping provider message/file keys in adapter metadata—and then submits
  `complete` or `failed` under the same provider message ID (retaining the
  provider reference without local bytes on failure). The adapter also downloads
  the file of an unaddressed group message that the binding ignores. A later
  reply can promote that message, and the promoted Message then carries the
  stored file.
- The initial `pending` observation timestamp anchors the 1,200 ms batching
  quiet window so slow downloads do not push that window out. `Conversations`
  waits up to 4 seconds for downloads to finish before releasing queued work; if
  completion arrives later, `Conversations` patches the open Signal (retrying a
  replay-safe started turn, or opening a follow-up turn if external side effects
  already ran), while duplicate redeliveries with an identical content hash
  no-op without creating extra Signals or delaying ready work.
- When a user @-mentions the bot without attaching a file while referencing a
  recent upload, the adapter can attach up to three files sent by that same
  sender in the same chat within the preceding 120 seconds.

## Send Replies

Outbound execution processes only durable Delivery intents: posting, replying,
editing, deleting, reconciling (`outbound_reconciliation` verifies the recorded
provider message ID), updating reactions, posting dividers, and sending cards.
Text sends derive deterministic provider UUIDs from intent idempotency keys,
and image or file sends read immutable attachment bytes from `Ankole.Files` via
`object_id` (`delivery_attachments`) before uploading them. If a reply target message has been deleted, the adapter falls
back to posting directly to the chat; if Lark rejects a final edit due to its
message-edit cap, the adapter posts a new message instead.

Non-image files up to 30 MiB upload through Feishu's native IM file endpoint.
Larger files up to 100 MiB—or uploads rejected with provider error `234006`—fall
back to the application's Drive cloud-space root:

1. Following Feishu's
   [multipart upload protocol](https://open.feishu.cn/document/server-docs/docs/drive-v1/upload/multipart-upload-file-/introduction),
   the adapter opens a multipart upload transaction, uploads parts sequentially
   without concurrency, and commits the upload.
2. It grants `view` permission either to the group chat (`openchat` member) or
   to the DM recipient (`openid` member), fetches the Drive URL, sends a
   localized chat notice explaining that the file was uploaded to cloud space
   due to IM size limits, and records the cloud file token, URL, byte size, and
   block count on the confirmed Delivery intent (if permission grant or URL
   lookup fails after upload, the adapter attempts to delete the orphaned cloud
   file before returning the error).

Cloud-space fallback requires sufficient Drive storage plus the app scopes
`drive:drive.metadata:readonly`, `drive:file:upload`,
`docs:permission.member:create`, and `space:document:delete`. Missing blobs,
files over 100 MiB, unsupported attachment shapes, or cloud permission/quota/capacity
errors mark the Delivery intent as requiring operator action (for example,
`attachment_file_missing`) so `Conversations` blocks the row instead of retrying
forever; malformed multipart plans or invalid provider payloads fail
permanently, while transient errors follow standard retry backoff. Structured
logs (`lark_adapter.intent.large_file_upload_started`,
`..._completed`, `..._failed`, and `lark_adapter.intent.large_file_cleanup_failed`)
and the `[:ankole, :lark_adapter, :large_file_upload]` telemetry event report
duration, byte size, block count, outcome, failed stage, fallback reason, and
recipient member kind without leaking file contents or access URLs.

## Show a Live CardKit Reply

For visible Agent turns, `CardKit` manages an ordered chain of streaming preview
cards, coalescing updates to at most one provider sync per turn per second while
handling explicit Feishu rate limits per turn rather than funneling unrelated
chats through a global queue. Automatic cron wakes prepend a compact quoted note
naming the scheduled rule on their first card (omitted on manual cron runs).

When Markdown contains remote images, the downloader validates the URL and every
resolved IPv4/IPv6 hop (including redirects) before connecting—dialing the
checked IP directly while preserving the original `Host` header, TLS SNI, and
certificate hostname check. Cloud-metadata IPs are always blocked, private IPs
honor `security.ssrf_filter` (defaulting to allow intranet hosts), DNS or SSRF
blocks leave a plain text link, and image fetches cap at 20 MiB without
transport retries.

Card sizing targets stay below 24 KiB and 160 CardKit elements (at most five
Markdown tables per card and four per Markdown element), splitting source
Markdown into ~12 KiB pages with at most four answer tables without mutating the
stored Markdown; because page splits depend strictly on the answer prefix,
appending text never shifts an already sealed boundary, and only the active tail
card renders transient reasoning, tool progress, or interactive controls (if a
late revision would alter a closed card, terminal Delivery sends a clean
fallback).

Each mutation carries a strictly increasing sequence number (retrying an
identical mutation reuses its logical UUID and sequence; changed payloads
advance the sequence), persisted in the source Signal's CardKit checkpoint
alongside card IDs, message IDs, page slices, stream status, and last confirmed
presentation:

- Live streaming updates mutate CardKit elements in place, whereas finalizing a
  streamed card replaces the message with one closed inline card (a card created
  directly from an already finished turn stays in CardKit because its full body
  was sent in one shot).
- CardKit streams carry a nine-minute lease: known closed-stream errors reopen
  the stream, missing cards or element-topology conflicts replace the message in
  place with a single complete card, and multi-page overflows during refresh
  seal the current card via whole-message patch and append new page cards.
- After a process restart, recovery renders the active page as a complete card
  to replace the existing message, switches that page to whole-message edits,
  and resumes CardKit streaming on any subsequent overflow page. Terminal
  recovery always renders from the durable Delivery intent—even if the last
  CardKit checkpoint held an intermediate draft—recording a non-retry fallback
  and stopping preview updates whenever plain-text fallback is needed so the
  Delivery intent remains sole owner of terminal output (auth/permission errors
  mark `recovery_state` blocked until an operator updates the binding, which
  requeues both blocked previews and intents).
- A form clarification renders inside one CardKit `form` container: each
  field shows its label (marked optional when it is) and help text above an
  `input` (text and number), `date_picker`, `select_static`,
  `multi_select_static`, or a Yes/No `select_static` for a boolean, named by
  the field ID so that `form_value` keys match the field IDs. A secondary
  `open_url` button opens the same form in Pod. The callback response shows a
  rejected submission's notice as an error toast, and the card keeps the
  entered values for correction.
- When a user answers an interactive clarification card, the adapter rebuilds
  that card from the durable reply-interaction checkpoint—stripping buttons and
  forms and displaying the chosen or custom answer, or a form's answer summary,
  as plain text visible to all chat members (or stripping controls without an
  answer when superseded).

Because previews are ephemeral presentation, `Conversations` commits the final
public Agent Message only after the provider confirms the durable Delivery
intent.

## Use Lark Tools

The `lark` Agent Plugin supplies four generated Skills: messaging, approvals,
tasks, and calendars. Each Skill selects an explicit tool and calls MCPorter.
Applet routes and native Automation Jobs call the same Toolkit through
`AnkoleRuntime.mcp.call`. Connectors owns the tenant's application roots and
personal OAuth tokens; Workers receive only a short-lived internal Turn token.

The execution Principal determines which employee an operation represents.
Personal assistants act for their human owner. For APIs accepting an application
token and employee ID, the adapter uses the verified identity-provider binding
and injects that employee ID. APIs requiring personal OAuth return an actionable
consent link when authorization is missing. Members authorize in Pod's Connections
page, and an optional identity-provider setting combines personal scopes with
OIDC sign-in. Offboarding invalidates personal credentials and stops dependent
Jobs and subscriptions.

Approval, task, and calendar events become CloudEvents routed by Signal Bindings.
The packaged approval inbox Applet queries pending tasks, sends interactive
cards, and handles signed card callbacks through a personal Action. It checks
the clicking employee against that Action's human authority, performs the
selected approval operation, and writes the result back to the card.

## Import People and Departments

OIDC sign-in resolves Principals across `[user_id, union_id, open_id]` (granting
identity without automatically granting Site Console or Pod admin roles, which
still come from `AuthZ`). Full directory sync runs through `DirectoryAccess` to
persist users, departments, group memberships, and `email` bindings (covering
both `enterprise_email` and `email`), mapping `is_resigned` / `is_exited` to
`:offboarded`, `is_frozen` to `:suspended`, and cleared flags to `:healthy`
recovery. Real-time `contact.user.*` events (treating `contact.user.deleted_v3`
as a departure) forward `[user_id, union_id, open_id]` to
`DirectoryAccess.receive_event/2`, while incomplete user payloads, department
changes, or visibility-scope updates enqueue a full sync (disabling WebSocket
events leaves scheduled/manual full sync intact).

## Restart and Recovery

PostgreSQL persists all durable state across `Ankole.Connectors`, `AppConfigure`,
`Conversations`, `Files`, `Signals`, `Sessions`, `Principals`, and `AuthZ`, while
the adapter remains stateless across restarts—rebuilding WebSocket connections, refreshing stored IM
group metadata on startup, reconciling open CardKit checkpoints against
confirmed Delivery intents (closing any lingering open preview card with the
confirmed terminal presentation), and scrubbing sensitive data from failure logs
(logging only exception classes and source locations, redacting token-fetch
`details`, and returning a generic HTTP 500 on failed card callbacks).

## Tests

Automated tests cover the `feishu_openapi` client, plugin declarations,
WebSocket lifecycle, inbound normalization, outbound Delivery intents, CardKit
streaming and recovery, OIDC login, and directory sync; live acceptance tests
against Feishu or Lark require operator credentials and a real client.

Implementation paths:

- `plugins/lark_adapter/lib/ankole/plugins/lark_adapter.ex`
- `plugins/lark_adapter/lib/ankole/plugins/lark_adapter/`
- `plugins/lark_adapter/lib/feishu_openapi/`
