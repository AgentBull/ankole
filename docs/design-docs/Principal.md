# Principal

`Ankole.Principals` is the root Ash domain for Principals, Agent and Human
profiles, external identities, site credentials, Pod invitations, access
restrictions, audit events, and pending identity-mapping requests, backed by
PostgreSQL tables and native constraints. Across the platform, the Principal UID
codec and the tenant-qualified `ActorRef` codec serve as the single contract for
identity and attribution.

Every aggregate write in `Ankole.Principals` runs inside
`Repo.transact_top_level/2`, which opens the transaction and enforces lock order
while individual Ash resource actions run inside it. Aggregate operations cover:

- Creating, enabling, disabling, updating, or deleting an Agent
- Creating or updating a Human
- Binding a personal site credential
- Upserting a platform subject
- Changing Human access or offboarding state
- Recording and reviewing identity-mapping requests
- Classifying and cleaning up affected work
- Accepting a Pod invitation
- Creating a member's personal assistant on first use and renaming a Principal

Console `/api/v2` endpoints call generic actions on `Principal` and
`MappingRequest`. When another domain needs to compose Principal steps inside
its own open transaction, it calls `*_in_tx` helpers—such as
`Principals.create_human_in_tx/1` and `Principals.lock_principal_in_tx/2`—rather
than nesting a top-level operation. Every identity lookup requires the owning
tenant in the `Ankole.Repo` process context. Site inventory operations can list
tenant-qualified records, then enter each tenant before invoking its domain
operations.

Resource actions enforce strict field boundaries: profile actions accept only
profile attributes and cannot modify identity, status, or `access_version`,
whereas Human revocation updates both `status` and `access_version` atomically
in one `Principal` action. Audit events expose neither update nor delete
actions; repeating a cleanup operation retains the original audit event, JSON
payloads use the durable JSON-object schema, and system-initiated operations
may record `nil` as the actor.

A Principal identifies the human, Agent, or system service accountable for an
action; work execution, authorization, and audit logs all share that identity.
Supported Principal types are `human`, `agent`, and `system`. For `human`
Principals, tenant collaboration depends on `membership`:

- **Members (`member`)** automatically join the computed `all_humans` group and
  receive a persistent private Drive root in their Principal creation transaction.
- **Guests (`guest`)** receive access only through explicit Pod shares and Agent
  grants; they cannot join built-in administrator groups, enter Private space,
  or access the Brain `world` scope, and `pod.allow_external_guests` gates guest
  admission and Pod access. Guest admission creates no private root. Promotion
  to member creates one; demotion retains its content while denying Guest access.

Changing a Human's `membership` increments `access_version`, whereas
identity-provider sign-ins and directory syncs preserve the stored membership.
Every Principal belongs to exactly one tenant. The same person participating in
two tenants has two distinct `principals` rows, which may share the same UID.

## What the Principal Subsystem Stores

`Ankole.Principals` owns:

- Canonical rows for humans, Agents, and system services, along with their
  `active` or `disabled` status
- Human contact profiles and verified personal site credentials
  (`principal_site_credentials`)
- Pod invitations (`pod_invitations`)
- Agent subtype, owner, and creator metadata
- Bindings to external provider subjects (`principal_external_identities`) and
  rules for linking the same human across providers

`Ankole.Principals` does *not* store:

- AuthZ groups, permission grants, or policy decisions
- Conversation Messages, external message references, Signals, or Delivery
  intents
- AI Gateway conversations, model profiles, or schedules
- AppConfigure settings or Plugin configurations
- Bootstrap environment variables, setup sessions, or browser sessions

The Elixir control plane persists all Principal state in PostgreSQL; Bun Worker
processes consume UIDs supplied by control-plane contracts without introducing a
second identity model.

## Names and Tenant Identity

The complete Principal identity is `(tenant_id, uid)`. A UID is a meaningful
name unique within its tenant. Control-plane APIs trim surrounding whitespace
and lowercase every UID; PostgreSQL enforces these value constraints and the
composite primary key. Explicit Human renames reject whitespace, control
characters and the separators or wildcard syntax reserved by API routes and
permission resources (`/`, `\`, `:`, `*`, `?`, `[]`, `{}`).

Human creation uses the normalized login email or the primary external identity
ID. An operator supplies an AI colleague's UID. A personal assistant initially
uses `<owner_uid>_assistant`, and each registered system service uses its fixed
UID (`system` or `ankole_brain`) within every tenant.
Agent UIDs match:

```text
^[a-z0-9][a-z0-9._@+-]{0,95}$
```

API routes, Worker IDs and Brain page slugs use this UID within an explicit
tenant. Agent API keys carry both `tenant_id` and `sub`. OIDC clients identify
the token's tenant; random Worker credentials identify a Worker row before the
gateway checks its UID. Display names describe a Principal without establishing
identity. Creating an occupied name returns `principal_uid_taken` and requires
the caller to choose a name or resolve the identity mapping explicitly.

## Stored Rows

### `principals`

`principals` stores the shared base identity columns:

- `uid`: text; the primary key is `(tenant_id, uid)`.
- `tenant_id`: required foreign key to the owning tenant.
- `type`: `human`, `agent`, or `system`.
- `status`: `active` or `disabled`.
- `membership`: `member` or `guest` for `human` rows; `NULL` for `agent` and
  `system` rows.
- `access_version`: positive integer generation counter bumped to revoke Human
  credentials and scheduled/background work.
- `display_name` and `avatar_url`: optional profile presentation fields.
- `inserted_at` and `updated_at`.

Disabling a Principal keeps its row intact. Disabling a Human runs through
`HumanAccess`, which commits access restrictions, an incremented
`access_version`, audit events, OIDC session revocation, and future-work cleanup
together; see [Human Offboarding](HumanOffboarding.md).

### `human_users`

`human_users` extends a `human` Principal with contact and directory fields:

- `(tenant_id, principal_uid)`: primary key and foreign key to `principals`.
- `email`, `mobile`, and `job_title`: optional profile fields.
- `inserted_at` and `updated_at`.

The Human profile action lowercases `email` and validates `mobile` as E.164 via
the native Rust kernel, with partial unique indexes guarding non-null `email`
and `mobile` values. Before E.164 validation, the DingTalk, Lark, WeCom, and
Slack adapters normalize observed phone numbers with
`Ankole.IdentityProviders.Phone.normalize_china_mobile/1`, which tests the raw
string first and then tries prepending `+86` for 11-digit numbers starting with
`1`; other providers apply their own normalization rules.

### `principal_site_credentials`

Each row in `principal_site_credentials` binds a verified `(provider,
identifier)` credential to one Human in one tenant. Account-based providers
allow at most one binding per Human, while WebAuthn allows multiple passkeys. A
composite index on `(provider, identifier)` backs Pod discovery once a user
verifies their site credential. See [Authentication](Authentication.md) for
verification ceremonies, admission, invitations, login policy, and releasing
identifiers for reuse.

### `agents`

`agents` extends an `agent` Principal with its execution profile:

- `(tenant_id, uid)`: primary key and foreign key to `principals`.
- `type`: `ai_colleague` or `personal_assistant`.
- `role`: required non-empty role description.
- `group_memory_disclosure_mode`: `strict` or `relaxed`.
- `options`: JSON object.
- `owner_principal_uid`: required same-tenant foreign key to the owning Human.
  AI colleagues can change owners. A personal assistant has one immutable owner
  relationship, with a partial unique index enforcing at most one assistant per
  owner. A personal assistant uses `strict` group memory disclosure.
- `created_by`: optional typed `ActorRef`.
- `inserted_at` and `updated_at`.

Runtime documents and settings—mission, soul, design, Brain memory, model
profiles, and token quotas—live in their respective subsystems rather than on
the `agents` or `principals` row.

### System Principals

A `system` Principal represents an internal service that needs to own durable
database rows. It has neither a `human_users` row nor an `agents` row, and it
cannot sign in, host an Agent Worker, or act as a human via an external
identity. `Ankole.Principals.SystemServices` owns the closed registry:

| UID | Responsibility |
| --- | --- |
| `system` | Pod Applet model calls and internal operations such as admission notices, document mention renames, and tenant deletion |
| `ankole_brain` | Brain model, embedding, and rerank calls |

Tenant initialization creates every registered service in its transaction;
migrations provision existing tenants. Runtime reads require the row to exist
and never create it. Each service has a fixed UID and cannot be renamed. Adding
a service requires a registry entry and a data migration. Ankole exposes no API
for creating arbitrary system Principals.

System Principals can override every fixed Pod model slot through AppConfigure
`system:<uid>` rows. They do not appear in mentions, conversation member choices,
page collaborator catalogs, Signal routing targets, or Agent readiness checks.

### `principal_external_identities`

`principal_external_identities` links one provider-scoped external subject to
one Principal, keyed uniquely on:

```text
tenant_id + provider + external_id
```

Each row contains:

- `id`: UUIDv7 binding ID (identifying only this link, whereas `principal_uid`
  identifies the accountable Principal).
- `principal_uid`: bound Principal.
- `provider`: platform-subject namespace (see `Ankole.Signals.SubjectNamespace`).
  Directory sync writes the identity provider's `provider_id`; a chat Binding
  writes the `provider_id` of its referenced identity provider—or adopts the
  sole configured provider for that adapter—so one employee resolves to the same
  Principal across login and chat, falling back to the adapter default (such as
  `lark-main`) when unlinked or explicitly standalone. The reserved `email`
  namespace stores mailbox addresses: a row there attests that the Principal
  owns that email address, and the Email channel adapter resolves senders
  exclusively through `email` rows.
- `external_id`: provider-scoped subject identifier.
- `metadata`: JSON object holding auxiliary subject attributes such as alternate
  provider IDs (for example, a Lark `open_id` alongside a `union_id`).
- `inserted_at` and `updated_at`.

Provider namespaces and `external_id` values are strictly tenant-local:
enterprise admission relies on immutable provider IDs, attested contact emails
help match pending members when verifying personal credentials, and an opaque
`uid` is never evidence that two external subjects represent the same person.
Sign-in, directory sync, Signals identity admission, and manual Console reviews
all write to this single table.

### Build-declared site sources

`IdentityProviders.SiteSources` registers the built-in email OTP source alongside
trusted build-selected site login sources. Once a user proves a site credential,
Ankole queries `principal_site_credentials` by `(provider, identifier)` to list
accessible Pods and pending memberships; tenant enterprise providers use a
separate namespace bound to a single tenant.

For every Pod session proof, BrowserSessions stamps the Human's current
`access_version`. Claiming a pending membership requires satisfying both the
current `PodLoginPolicy` and the identifier-release waterline, keeping
directory-synced contact data separate from verified personal login credentials.

### `pod_invitations`

`Ankole.Principals.Invitation` persists tenant-scoped Pod invitations in
`pod_invitations`:

- `id`: UUIDv7 primary key.
- `kind`: `link` or `email`.
- `invited_email`: optional normalized email address.
- `membership`: `member` or `guest`.
- `token_digest` and optional `code_digest`: SHA-256 digests (plaintext tokens
  and codes are never persisted).
- `max_uses` and `used_count`.
- `created_by_principal_uid`.
- `expires_at` and optional `revoked_at`.
- `inserted_at` and `updated_at`.

### `identity_mapping_requests`

When a message arrives on a Binding configured with the `manual_review` policy
and its sender matches no Principal, Ankole upserts a pending row in
`identity_mapping_requests` keyed by `tenant_id + provider + external_id`. Each
row captures any platform-supplied display name, email, and mobile number plus
observation metadata (alternate IDs and the observing Binding). Operators review
these rows in the Console: linking a request to a Principal inserts the
`principal_external_identities` row and deletes the request. Likewise, any
automatic or operator-driven identity write purges pending mapping requests for
every candidate subject in that write so mapped aliases never linger in the
review queue.

## Link First-Seen Provider Users to Existing Humans

`upsert_platform_subject_human` resolves or creates a Human for an immutable
provider subject:

1. If an immutable subject candidate is already bound, Ankole selects that
   Principal; an explicit operator-reviewed mapping may also target an existing
   Human UID in the same tenant.
2. Otherwise, on a Human's first binding to that provider, an attested contact
   email can link to an active Human in the tenant who has no existing binding
   to that provider and has not completed offboarding—matching against the
   Human's profile `email`, verified personal login email, or directory contact
   aliases tagged with `origin: "directory"` (an Email channel sender binding
   alone never qualifies as an admission contact). Linking preserves the Human's
   existing UID, roles, files, and conversations.
3. If no eligible Human matches, Ankole creates a Human Principal using the
   normalized primary external subject as its UID. An occupied name returns
   `principal_uid_taken`; an operator can map the external identity explicitly.

Inside the transaction, Ankole locks all candidate subjects, contact keys, and
the target Principal before writing stable aliases atomically; any alias
conflict rolls back the observation, and once bound, a provider subject stays
with its Human even if contact details change later.

Directory sync and upstream sign-in can also bind attested mailbox rows under
the `email` namespace (for example, Lark syncs both enterprise and personal
member emails) to support Email adapter sender matching and pending-member
discovery. If an observed email already belongs to another Principal, Ankole
leaves the current owner unchanged and logs an observation warning. While a
Human is under an active local offboarding restriction, Ankole suppresses
contact-email writes from routine healthy upstream syncs; conversely, an
upstream departure event releases that Human's contact emails so a new hire can
claim a recycled address while immutable provider IDs retain historical
attribution.

For batch directory synchronization, `IdentityProviders.Directory.sync_users/3`
drives the shared per-user loop—committing each observed user in an independent
transaction—while individual provider adapters handle pagination, filtering, and
attribute mapping.

## Match Without Creating

`match_platform_subject_human` looks up an already bound provider subject and
returns it only if the Human is `active`. Under the `email` namespace, it
matches an `email` external-identity row or the Human's recorded contact email
using the sender address as subject; under enterprise providers, it matches
immutable subject IDs. Passing an explicit UID designates a manual review target
rather than identity proof; claiming a pending membership with a verified
personal credential is owned separately by [Authentication](Authentication.md).

## Verify Upstream Login

`IdentityProviders.Login.complete_oidc_login/3` is the sole boundary that
accepts upstream OIDC login proofs:

1. The adapter exchanges the authorization code and returns the token response,
   user-endpoint claims, and normalized user attributes, declaring expected ID
   token rules via `id_token_verification/1`—issuer, client ID, and subject
   claim (`sub` for Google and Slack, `oid` for Microsoft Entra ID).
2. `IdentityProviders.OIDC.verify_login/3` verifies the ID token signature,
   issuer, audience, nonce, and `auth_time`, and confirms that the user-endpoint
   identifier matches the signed ID token claim.
3. Only after verification succeeds does the adapter persist the Human.

Lark, WeCom, and DingTalk sign-ins use OAuth 2.0 without OIDC ID tokens; their
adapters return `:none` from `id_token_verification/1`, record no `auth_time`,
and cannot satisfy fresh-authentication OIDC requests. At startup, the Plugin
Registry rejects any adapter declaring `oidc_code_exchange` without exporting
`id_token_verification/1`.

## Create and Update Humans

`create_human` inserts the `principals` and `human_users` rows in one
transaction, and `update_human` modifies only mutable profile and display
columns (attempting to convert an Agent UID into a Human always fails).

When syncing from an external identity provider, omitting a profile field
preserves the stored value whereas passing an explicit blank clears it—a
distinction that Lark, DingTalk, and WeCom maintain when contact hydration is
unavailable at login. Similarly, omitting the department list keeps existing
department memberships, while observing an explicit `[]` removes that provider's
managed department memberships and records `[]` in identity metadata. An
identifier-derived fallback name may label a newly created Human but never
overwrites an existing Human's display name.

For lookups, `resolve_platform_subject` returns only `active` Human Principals,
whereas `resolve_platform_subject_uid` also resolves `disabled` Principals to
support offboarding and cleanup workflows.

## Create and Update Agents

`create_agent` executes six steps inside one transaction:

1. Normalizes and validates the caller's requested `uid`.
2. Selects `worker_provider_id` from the request or falls back to the default
   Worker provider, failing with `worker_provider_required` if neither exists.
3. Inserts the `principals` row and creates the Agent's private Drive root,
   before Library initialization. The transaction takes the Drive tree lock
   before Principal, turn, or content locks.
4. Inserts the `agents` row.
5. Seeds initial Agent Library documents and state.
6. Inserts the `agent_workers` row in state `absent` bound permanently to the
   selected Worker provider (an Agent's Worker provider cannot change later).

Immediately after commit, `create_agent` requests Worker provisioning so the
control plane starts the Worker right away (see [Agent Workers](AgentWorkers.md)).
`update_agent` edits mutable display and colleague fields without altering `uid`
or Principal `type`.

Enabling or deleting an Agent snapshots affected Conversation IDs inside the
transaction. Deleting an `active` Agent first transitions it to `disabled`;
sending a second delete for a `disabled` Agent physically removes its durable
rows. The transaction acquires the Drive tree lock and private-root lock first,
cleans the private subtree's Pod content and physical Base tables, removes its
Drive nodes, strips Drive grants, and recomputes affected ACL anchors before
deleting the `principals` row. Disabling an Agent preserves its private root and
content. Immutable file objects become eligible for normal reference-aware GC
when their final live or historical reference disappears. After commit, `Principals.publish_agent_changes/1` broadcasts
status updates within the Agent's tenant (including Conversations removed in
that transaction), and `Principals.publish_agent_deletion/1` triggers Worker
teardown. Both domain callers and Console endpoints share these publication
helpers while keeping `Principal` and `Agent` return structs distinct.

In the Console, each Agent Library document maintains its own local draft and
content hash, backed by TanStack Query for fetching/caching and the Signal model
for completion checks. On a version conflict, reloading overwrites the local
draft only if the operator has not typed further edits, canceled, triggered a
newer reload, or navigated away; failed reload reads preserve both draft and
hash for retry.

For Human offboarding, `HumanAccess.disable/4` records the restriction and
revokes credentials while AuthZ blocks disabling the last active human
administrator.

### Personal Assistants

`ensure_personal_assistant(owner_uid)` requires an active Human member in the
current tenant. It reads the owner's existing assistant and returns its actual
UID, including after either Principal has been renamed. First use creates a
Principal, an Agent profile, default personal-assistant Library documents, a
private runtime Drive root and an AgentWorker through the same creation path.
The transaction grants the owner chat access and management of the assistant's
private root. The owner uniqueness constraint resolves concurrent creation;
an unrelated Principal occupying the default name remains a name conflict.

Human creation, login, invitations and directory import leave assistant
creation to first use. Pod's default New Chat first ensures the assistant, then
sends through the ordinary Conversation API. A failed send leaves the assistant
available for retry. Shared Lark and Slack bindings use the same creation
operation after admitting an active member.

The assistant executes, speaks, stores runtime files and incurs usage under its
own identity. `Principals.authority_uid/1` reads its owner for business AuthZ,
the owner's Pod private tree and Human work admission. Management permissions
use the assistant's own grants. Disabling or offboarding the owner, or changing
them to guest, disables the assistant; restoring an active member enables an
existing assistant. Each synchronization enqueues Worker reconciliation in the
same transaction, so the provider applies the committed lifecycle state.
Console service work and dedicated channel bindings accept
AI colleagues as targets.

Public directories and colleague-management lists contain AI colleagues.
Mention candidates include only the caller's existing personal assistant;
readable content can display other assistants without granting chat access.
`Principals.display_name/1` combines the assistant's short name with the owner's
current display name for shared attribution. The owner's private chat can use
the short name.

## Explicit Rename

`Principals.rename/2` changes a name in the current tenant. Humans and both
Agent subtypes can be renamed repeatedly. An Agent must be disabled, with its
old running or paused Worker instance removed through normal reconciliation
before the rename can commit. An outstanding drain returns
`worker_rename_pending`; the operator can retry once removal finishes.

The control-plane transaction changes the Principal key and its cascading
foreign keys. `Principals.Rename.References` owns the explicit inventory of
identity copies: tenant-local UID fields, complete ActorRefs across tenants,
registered JSON paths, pending job arguments, permission resource patterns,
Brain home slugs and audience scopes. Browser tenant authentication subjects
follow the rename, while provider subjects, login credentials and contact
fields keep their meaning. Domain owners rewrite canonical document, snapshot
and comment mentions through the XML codec, advancing live document revisions.
Brain rewrites parsed audience tags and canonical home-page wikilinks in live
bodies and stored versions, refreshes content hashes and reconciles retrieval
chunks. These structured rewrites preserve prose and code examples. Agent
configuration and environment variables are resealed under the new scope.

Inline Base references commit with the control plane. Physical Base references
are repaired after commit, and a failure returns `base_repair_error` alongside
the successful new UID. Operators can independently rerun
`Ankole.Pod.repair_principal_references(tenant_id, old_uid, new_uid)`; this
idempotent operation does not require the old Principal to exist. Worker
reconciliation deletes the old storage and creates storage under the new name
when the Agent is enabled.

Browser authentication references and OIDC refresh credentials remain usable.
Existing OIDC access tokens retain their old `sub` until their 30-minute expiry;
refreshing obtains a token with the new name. External OIDC applications own
their account-continuity policy. Agent API keys are stateless and last 30 days:
reusing an old name during that period can make an old key identify the new
Agent with that name. A rename creates no old-name alias. Renaming an owner
updates the assistant's owner reference without changing the assistant's UID.

## Console Identity and Access API

Provider configuration and directory sync reviews run through `/api/v2/identity-provider-adapters`
and `/api/v2/identity-providers` in the Site Console (and
`/api/v2/pod/admin/identity-providers` in Pod settings):

- Read responses redact stored secrets, and submitting a blank secret field
  keeps the existing stored secret.
- Approving a directory sync requires matching the current snapshot fingerprint
  and explicitly confirming user removals; reviewing a sync event checks both
  the provider ID and event ID.

`Ankole.IdentityProviders.Console` and `Ankole.Principals.Access` are stateless
Ash transport resources (`Ash.DataLayer.Simple`) that hold no rows and open no
transactions of their own, delegating every durable mutation to the owning
domain's top-level operations. Before dispatch, `AnkoleWeb.JSONAPI.Context`
canonicalizes route parameters and binds the full Actor and target data tenant,
and `Ankole.AuthZ.Authorizer` enforces each action's permission declaration.

Operators inspect and manage Human offboarding at `/api/v2/principals/:uid/access`—covering
active restrictions, permission review, audit history, affected scheduled/background
work, and cleanup outcomes. Mutating access requires a reason and an idempotent
operation ID; restoring a disabled Human requires verified identity, cleared
restrictions, and a matching permission-review fingerprint (which covers
reachable Userset grants alongside potential conditional and computed-group
permissions, while ignoring unrelated Private Page grants). Finally,
`/api/v2/work-access-reviews` records explicit Human or service reauthorization
for stopped work without automatically replaying it.

## Divide Setup from Principal Data

During initial bootstrap, `Ankole.Principals` creates the first active Human,
while AuthZ creates the built-in administrator group, membership, and grants;
root setup marks itself complete only once AuthZ confirms a valid active human
administrator. Ephemeral bootstrap artifacts—activation codes, outbound OIDC
state, setup sessions, and admin browser sessions—live outside `Ankole.Principals`.

## Let AuthZ Decide Permissions

`Ankole.Principals` supplies subject identity, `active`/`disabled` status, and
Human `access_version`, whereas AuthZ owns groups, group memberships, grants,
conditions, and policy evaluation. Authorization fails closed whenever a
Principal is missing or `disabled`, has the wrong Principal `type`, carries
invalid group conditions, or passes malformed resource/action inputs; see
[AuthZ](AuthZ.md).

## Audit Actors

In Console API responses, audit actors serialize as `{ tenant_id, uid }`. Where
ownership governs live permissions or work authorization, tables use a true
`principals` foreign key; where a column records historical attribution only—such
as `agents.created_by` or Brain `author`—it stores an `Ankole.ActorRef` string
(`ankole:<tenant_id>:principal/<uid>`), preserving the actor's home tenant when
a site administrator acts across tenants and surviving even if that Principal is
later deleted.

## Rules

- Address every accountable human, Agent, or service by `principals.uid`, stored in lowercase.
- Reserve `system` Principals strictly for internal services that own durable database state.
- Disable Humans through `HumanAccess` so restrictions, `access_version`, OIDC revocation, work cleanup, and audit history commit together.
- Keep Agent runtime documents, model profiles, memory, and quotas in their owning subsystems rather than on `principals`, and require a non-empty `role` and JSON `options` on `agents`.
- Link external provider records for the same person through `platform_subject` bindings in `principal_external_identities`, and verify any channel identity before trusting it to act as a Principal.
- Keep all group definitions and permission grants inside AuthZ.
