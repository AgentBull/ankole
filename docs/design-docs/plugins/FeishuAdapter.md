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
| Signal configuration | `signals.lark.binding_configs.<binding-digest>` |
| Identity adapter ID | `lark` |
| Identity configuration | `principals.identity_providers.lark.<id>` |
| Provider library | `plugins/lark_adapter/lib/feishu_openapi` |

The Signal adapter supports all three group-message policies (`addressed_only`,
`observe_all`, and `may_intervene`), inbound capabilities `entry_receive`,
`entry_removed`, `reaction_add`, `reaction_remove`, and `action_event`, and
outbound capabilities `post_entry`, `reply_entry`, `edit_entry`, `delete_entry`,
`outbound_reconciliation`, `add_reaction`, `remove_reaction`, `divider`, and
`card`.

On the identity side, the adapter supports OIDC authorization, OIDC code
exchange, full directory sync, and real-time directory sync.

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
Binding itself. Identity-provider settings share `appID`, `appSecret`, and
`domain`, using `oidc.*` keys for sign-in and `sync.*` keys for user and
department imports.

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
before writing the binding or its encrypted settings). Each binding persists
settings under `signals.lark.binding_configs.<binding-digest>`, where
`<binding-digest>` hashes the normalized Agent UID and binding name
(`Ankole.Upgrade202610` migrates `signals.lark.bindings.*` rows onto that key
while the `signals.lark.bindings` pattern stays registered for the upgrade
window).

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
`uid(uid)` when no name is known). Human Principal UIDs remain opaque UUIDv7s,
separate from provider-scoped Lark IDs and `email` bindings.

Inbound content covers plain text, rich posts, stickers, images, files, audio,
media, video, locations, shared chats, and shared user cards:

- Before starting a file download—including files listed in the top-level
  `files` array of a rich post—the adapter records a durable `pending`
  observation across every matching chat binding, allocates the numeric
  attachment ID, downloads the blob once into the file service
  ([Files](../Files.md)) under
  `chats/<public conversation UUID>/inbox/<digest>/<filename>` (where `<digest>`
  is the SHA-256 prefix and provider message/file keys stay in adapter metadata
  out of the path), and then submits `complete` or `failed` under the same
  provider message ID (retaining the provider reference without a local file on
  failure).
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
and image or file sends upload blob bytes read via `blob_ref` from the file
service first. If a reply target message has been deleted, the adapter falls
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
- When a user answers an interactive clarification card, the adapter rebuilds
  that card from the durable reply-interaction checkpoint—stripping buttons and
  forms and displaying the chosen or custom answer as plain text visible to all
  chat members (or stripping controls without an answer when superseded).

Because previews are ephemeral presentation, `Conversations` commits the final
public Agent Message only after the provider confirms the durable Delivery
intent.

## Let a Job Use Lark Tools

When the `lark` Agent Plugin is enabled, `WorkerEnv` resolves a bot tenant
access token at execution start from the current Signal route's Lark binding—or
implicitly from the Agent's sole available Lark binding (if multiple Lark
bindings are available and the execution carries no matching Lark route, or if
the routed binding is disabled or unavailable, `WorkerEnv` injects no Lark
variables rather than guessing another binding). Using stored provider identity
metadata to look up recipient `open_id` values for direct-message shortcuts,
`WorkerEnv` injects:

- `LARKSUITE_CLI_APP_ID`
- `LARKSUITE_CLI_TENANT_ACCESS_TOKEN`
- `LARKSUITE_CLI_BRAND`
- `LARKSUITE_CLI_DEFAULT_AS=bot`
- `LARKSUITE_CLI_STRICT_MODE=bot`

`WorkerEnv` never exposes `appSecret`, and Skills come exclusively from the
enabled Agent Plugin—configuring a `SignalBinding` supplies credentials without
enabling Skills on its own.

For user-scoped Feishu approvals, the `lark-approvals` Skill (`ankole-runtime: main`,
exposed only to human-initiated foreground Turns and never to unattended/scheduled
Turns or background Jobs—though foreground Turns may still delegate receipt
parsing, currency math, or data prep to a background Job) uses a separate
per-Human profile path:

- From `runtime_fabric.worker_auth_key`, the control plane derives an opaque
  HMAC-SHA256 `lark-cli` profile name—hashing `principal_uid` for access version
  `1`, or `principal_uid <> <<0>> <> decimal_access_version` for higher
  versions (rejecting any Human turn without a positive `access_version`)—and
  sends the Worker only the derived profile name and active-human marker, never
  raw Principal UIDs or version numbers. If a Human is disabled and later
  restored, their incremented `access_version` maps to a fresh profile requiring
  new PersonalAgent app setup and user login; older profiles remain on disk for
  already admitted runs while staying unreachable through the wrapper (without
  revoking tokens on Feishu's servers).
- Before invoking `lark-cli`, the Skill wrapper scrubs the bot `LARKSUITE_CLI_*`
  environment variables (including `LARKSUITE_CLI_STRICT_MODE=bot`, since env
  credentials override named profiles and each user profile sets
  `strict-mode=off` to hold both a user token and its PersonalAgent tenant
  token) and explicitly passes the derived profile, pinning `--as user` on
  approval reads/writes and `--as bot` on approval file uploads. Note that
  sender separation here is enforced by Skill wrapper convention rather than OS
  sandbox isolation, because all profiles share the Worker's `.lark-cli`
  directory under Ankole's trusted first-party extension model.
- Initial provisioning per `(principal, access_version)` runs three steps:
  1. PersonalAgent app registration creates a dedicated app and stores its
     credentials via `lark-cli profile add --app-secret-stdin` (never asking the
     user for an app secret or passing secrets via CLI args or `WorkerEnv`;
     registration errors surface HTTP status, provider code, and description).
  2. Before uploading approval attachments, the user enables and publishes
     `approval:approval` and `approval:instance.file` in the Feishu developer
     console (if an upload hits `app_scope_not_applied`, the Skill returns the
     console link and stops rather than mutating app scopes).
  3. OAuth device login (`auth login`, which never creates an app or grants app
     scopes) authorizes the user token.
- During both device flows, opaque device codes stay out of model context: the
  `begin` subcommand returns only user verification instructions and writes the
  device code with mode `0600` and an absolute expiry inside mode-`0700`
  `.lark-cli/.ankole-profile-state/<derived-profile>/app-registration.json` or
  `auth-login.json` (atomically replacing any prior file for that flow and
  deleting the file once completed, denied, expired, or invalid), so `complete`
  needs no device-code argument. A shared file lock serializes profile creation,
  policy repair, login, and logout, while approval queries, uploads, and
  submissions run lock-free in parallel across users.

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

PostgreSQL persists all durable state across `AppConfigure`, `Conversations`,
`Signals`, `Sessions`, `Principals`, and `AuthZ`, while the adapter remains
stateless across restarts—rebuilding WebSocket connections, refreshing stored IM
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
