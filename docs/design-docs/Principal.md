# Principal

`Ankole.Principals` is the Ash domain of the typed persistence actions for
Principals, Agent and Human profiles, external identities, site credentials, invitations,
access restrictions, audit events, and pending identity mappings. These
resources use the PostgreSQL tables and constraints. The Principal UID
codec and tenant-qualified ActorRef codec are the identity and attribution
contracts.

Each aggregate operation (create, enable, delete, or update an Agent; create
or update a Human; bind a site credential; platform subject upserts; Human
access changes; mapping observations and reviews; work classification and
cleanup; invitation acceptance) runs in `Repo.transact_top_level/2`, which owns
the transaction and the lock order while the resource actions run inside it.
Console `/api/v2` routes use generic actions on `Principal` and
`MappingRequest`. Another domain runs the same steps in its own transaction
through the `_in_tx` functions, for example `Principals.create_human_in_tx/1`
and `Principals.lock_principal_in_tx/2`; it cannot call a top-level operation
there.
A read of a Principal in any tenant uses the `allow_global` read action through
`Principals.get_principal_across_tenants/1` in a `Repo.across_tenants` block.
Profile actions accept only profile fields;
they cannot change identity, status, or access versions. Human revocation
changes status and the access version in one Principal action. Audit events
have no update or delete action. The cleanup audit action keeps the first
event on a repeated operation. Its JSON fields use the durable JSON object
contract, and a system operation can have no actor.

A Principal identifies the human or Agent responsible for an action. Work,
permissions, and audit records all use that same identity.

Current Principal types are `human`, `agent`, and `system`.
Human membership controls tenant collaboration. Members receive the computed
`all_humans` group. Guests require explicit Pod shares and Agent grants. Guests
cannot join built-in administrator groups or use Private space. They do not
receive the Brain `world` scope. `pod.allow_external_guests` controls guest admission and Pod
access. A membership change increments `access_version`. Identity-provider
sign-in and directory synchronization preserve the stored membership.

One opaque UID identifies a Principal across the site. Every Principal belongs
to exactly one tenant. The same person in two tenants has two Principal rows.

## What the Principal Subsystem Stores

`Ankole.Principals` stores:

- stable rows for humans, Agents, and system services
- whether each Principal is active or disabled
- human profiles
- Agent subtype and creator information
- links to identities from external providers
- rules that link the same human across providers

It does not store:

- AuthZ groups, grants, or decisions
- Conversation Messages, external references, Signals, or Delivery intents
- conversations, model profiles, or schedules
- AppConfigure values or Plugin settings
- startup variables, setup sessions, or web sessions

The Elixir control plane stores Principals in PostgreSQL. Bun code receives UIDs
from control-plane APIs and does not create another identity model.

## Use One UID throughout the Deployment Instance

`principals.uid` is the primary key. The table has no second internal Principal
ID.

APIs remove surrounding spaces and lowercase every UID. PostgreSQL requires the
stored value to be lowercase.

Principal UIDs are server-generated UUIDv7 text. An Agent has a separate,
editable `handle`, unique within its tenant, with this pattern:

```text
^[a-z0-9][a-z0-9._-]{0,95}$
```

API paths, tokens, Worker IDs and Brain page slugs use the stable
UID. The console displays the handle. New Agent requests supply `handle`, not
`uid`. Names never establish identity.

## Stored Rows

### `principals`

The table stores these fields:

- `uid` as the text primary key.
- `tenant_id` as the required tenant foreign key.
- `type` as `human`, `agent`, or `system`.
- `status` as `active` or `disabled`.
- Human `membership` as `member` or `guest`. Agents and System Principals use null.
- `access_version`, a positive generation for Human credential and work revocation.
- Optional `display_name` and `avatar_url`.
- `inserted_at` and `updated_at`.

Disabling a Principal keeps the row. Human disablement uses `HumanAccess` to
commit restrictions, a new access version, audit history, OIDC revocation, and
future-work cleanup together. See [Human Offboarding](HumanOffboarding.md).

### `human_users`

The table extends a human Principal with these fields:

- `principal_uid` as the primary and foreign key.
- Optional `email`.
- Optional `mobile`.
- Optional `job_title`.
- `inserted_at` and `updated_at`.

The Human profile action lowercases email addresses.
It validates mobile numbers as E.164 values through the native kernel.

DingTalk, Lark, WeCom, and Slack normalize observed phone numbers through
`Ankole.IdentityProviders.Phone.normalize_china_mobile/1` before E.164
validation. That helper tries the supplied number first, then a +86 candidate
for an 11-digit number that starts with 1. Other providers use their own input
rules.

Unique indexes protect non-null email and mobile values.

### `principal_site_credentials`

A verified site credential binds one identifier and provider to one Human in
one tenant. Account providers permit one binding per Human; WebAuthn permits
multiple keys. The provider/identifier index supports a proved site's Pod list.
See [Authentication](Authentication.md) for ceremonies, admission, invitations,
login policy, and recyclable identifier release.

### `agents`

The table extends an agent Principal with these fields:

- `uid` as the primary and foreign key.
- `type` as the `ai_colleague` enum.
- Required nonempty `role`.
- `options` as a JSON object.
- Optional `created_by_principal_uid`.
- `inserted_at` and `updated_at`.

Agent mission, soul, design, memory, model profiles, and token quota belong to
their own subsystems. They do not belong in the Principal row.

### System Principals

A system Principal identifies a system service that must own durable
state. It has no `human_users` or `agents` row. It cannot sign in, own an Agent
runtime, or act as a human through an external identity.

The owning subsystem creates and manages each system Principal. The Principal
subsystem does not provide a general public creation API for this type.

### `principal_external_identities`

The table binds one provider-scoped external subject to one Principal.
It stores these fields:

- A UUIDv7 binding `id`.
- `principal_uid`.
- `provider` as the platform-subject namespace. Directory sync writes the
  identity-provider `provider_id`; a chat binding writes the `provider_id` of
  the identity provider it references, or adopts the single configured
  provider of its adapter, so one person resolves to one Principal from both
  paths (see `Ankole.Signals.SubjectNamespace`). A binding without a
  provider, or one that chose the standalone value, writes the adapter
  default, such as `lark-main`. The `email` namespace holds mailbox
  addresses: a row there says that the Principal owns that address, and the
  Email adapter identifies a sender only through such a row.
- `external_id` as the provider-scoped subject id.
- A JSON `metadata` object. Alternate provider ids for the same subject, for
  example a Lark `open_id` next to a `union_id`, live here.
- Timestamps.

Its uniqueness key is:

```text
tenant_id + provider + external_id
```

The binding ID identifies only that external link. The Principal UID still
identifies the responsible human or Agent.

Provider IDs and external subjects are tenant-local. Enterprise admission uses
immutable provider IDs. Contact data can discover a pending member for a
separately verified personal credential.
A UID is opaque and is never evidence that two subjects are the same person.

There is one identity shape. Login, directory sync, Signals identity admission,
and manual console mappings all write this same row.

### Build-declared site sources

`IdentityProviders.SiteSources` declares the built-in email OTP source and
trusted build-selected sources. A verified site source addresses
`principal_site_credentials` by provider and identifier. It discovers available
Pods and pending memberships. Tenant enterprise configuration uses a separate
provider namespace and a fixed target tenant.

BrowserSessions records the current Human access version for each Pod proof.
Pending claims require the current Pod login policy and identifier release
waterline. Directory contacts and personal login credentials have separate
owners.

### `identity_mapping_requests`

The table holds signal senders that resolved to no Principal while their
binding uses the `manual_review` policy. One row exists per
`tenant_id + provider + external_id`. It stores the sender display name, email, and
mobile when the platform reveals them, plus observation metadata such as
alternate ids and the binding that saw the sender. The operator console lists
these rows; binding one to a Principal writes the identity row and deletes the
request. Any automatic or proactive identity write deletes requests for all
provider subject candidates in that write, so a mapped alias cannot remain
pending.

## Link First-Seen Provider Users to Existing Humans

`upsert_platform_subject_human` selects an existing binding for an immutable
provider subject candidate. An explicit reviewed mapping can select an existing
Human UID in the same tenant. For a first binding to a provider, an attested
contact email can select an active Human who has no binding to that provider.
The match includes the Human profile email, a verified personal login email, and
directory contact aliases whose metadata has `origin: "directory"`. An Email
channel sender binding alone does not register a contact email for admission.
The Human keeps their UID, roles, files, and conversations. A provider binding
or a completed offboarding prevents email-based reassignment to that Human.
If no eligible Human matches, the server creates a new opaque UID.

The transaction locks subject candidates, contact keys, and the selected
Principal. It writes the supplied stable aliases atomically. A conflicting alias
rolls back the observation. A binding stays with its Human when contact data
changes.

Directory sync and provider login can bind attested contact email addresses in
the `email` namespace. Lark supplies both enterprise and member email. These
contacts support Email adapter identity and pending member discovery. A contact
conflict preserves the current owner and emits an observation warning.

A current local offboarding cycle suppresses contact writes from healthy
upstream observations. A departure observation releases contacts before another
employee can claim them. Immutable provider IDs keep historical attribution.

`IdentityProviders.Directory.sync_users/3` traverses users for the adapters that
use its shared loop. Adapters own pagination, selection, and profile mapping.
Each observed user has its own transaction.

## Match Without Creating

`match_platform_subject_human` matches a bound provider subject and returns
an active Human. The `email` provider matches its email identity row or the
Human's recorded contact address, using the sender address as its subject.
Enterprise providers match stable subjects. A supplied UID is a reviewed mapping
target, not identity evidence. [Authentication](Authentication.md) owns the
separate verified personal-credential pending claim.

## Verify Upstream Login

`IdentityProviders.Login.complete_oidc_login/3` is the only place that accepts
the proof of an identity-provider login. The adapter exchanges the code and
returns the token, the claims of the provider's user endpoint, and the
normalized user. The adapter declares the expected ID token with
`id_token_verification/1`: the issuer, the client ID, and the claim that names
the user (`sub` for Google and Slack, `oid` for Entra ID). The login boundary
verifies the signature, issuer, audience, nonce, and authentication time with
`IdentityProviders.OIDC.verify_login/3`. The user endpoint claim must equal the
signed claim. Then the adapter writes the user.

Lark, WeCom, and DingTalk login use OAuth 2.0 without an ID token. Their
adapters declare `:none`, so their logins have no authentication time and
cannot serve a fresh-authentication request. The plugin registry rejects an
adapter with the `oidc_code_exchange` capability that does not export
`id_token_verification/1`.

## Create and Update Humans

`create_human` inserts the Principal and human profile in one transaction.
`update_human` changes only mutable Principal and human profile fields.

An external identity can create or update a human. An omitted profile field
keeps its current value. An explicit blank clears it. Lark, DingTalk, and
WeCom preserve this distinction when contact hydration is unavailable during
login. An absent department list preserves memberships; an observed empty list
clears this provider's managed department memberships. The identity metadata
records the same observed list, including an empty list. An identifier-only
name can label a new account but does not replace an existing human name.

A UID that belongs to an agent cannot become a human.

`resolve_platform_subject` returns only an active human Principal.
`resolve_platform_subject_uid` also supports cleanup for a disabled Principal.

## Create and Update Agents

`create_agent` does the following in one transaction:

1. Require the Agent handle and generate its opaque UUIDv7 UID.
2. Select the Worker provider: the `worker_provider_id` of the request, or the
   default provider. Without either, creation fails with
   `worker_provider_required`.
3. Insert the `principals` row.
4. Insert the `agents` row.
5. Seed Agent Library state.
6. Insert the Agent's `agent_workers` row in state `absent`, with the selected
   provider. New Agents do not reuse deleted UIDs.

After the commit, it requests the Agent's Worker, so the control plane creates
the Worker at once (see [Agent Workers](AgentWorkers.md)). The provider of an
Agent cannot change.

`update_agent` changes mutable display and subtype fields.
It cannot change the UID or Principal type.

Enable and delete transactions capture the affected Conversation IDs. The first
delete request disables an active Agent; a delete request for a disabled Agent
removes its durable rows. Physical deletion holds the Pod tree lock and removes
Page grants through Pod access maintenance before it removes the Principal.
This updates affected anchors and pass-through descendants.
`Principals.publish_agent_changes/1` publishes status
notifications in the Agent's tenant after commit, including for Conversations
removed by that transaction. `Principals.publish_agent_deletion/1` then requests
Worker reconciliation. Domain operations and the Console use these same
publication functions. Their Principal and Agent return values stay distinct.

The Console keeps an independent draft and content hash for each Agent Library
document. A conflict reload replaces the draft only if the operator has not
edited it, canceled it, started another reload, or left that source. A failed
read keeps the draft and its hash, and permits another reload. The Signal model
checks completion; TanStack Query owns the request and cache.

`HumanAccess.disable/4` records a Human restriction and revokes its credentials.
AuthZ protects the last active human administrator.

## Console Identity and Access API

The tenant Console uses `/api/v2/identity-provider-adapters` and
`/api/v2/identity-providers` for provider configuration and directory review.
Configuration responses redact stored secrets. A blank secret input keeps the
stored value. Directory approval requires the current snapshot fingerprint and
explicit removal approval. Event review checks both the provider and event ID.

`Ankole.IdentityProviders.Console` and `Ankole.Principals.Access` are typed,
stateless Ash transport resources. Their actions call the owning domain's
public operations. They keep no rows and open no transaction. Each durable
write belongs to its domain action and PostgreSQL adapter.
`AnkoleWeb.JSONAPI.Context` resolves decoded route targets to canonical identifiers
and passes the full Actor and selected data tenant to the Ash action.
`Ankole.AuthZ.Authorizer` enforces the resource action declaration.

The Human access view at `/api/v2/principals/:uid/access` includes restrictions,
permission review, history, affected work, and cleanup results. Access changes
require a reason and an operation ID. Restoration requires verified identity,
the current permission fingerprint, and cleared restrictions. The work review
routes at `/api/v2/work-access-reviews` record explicit Human or service
authority without replaying stopped work.

## Divide Setup from Principal Data

Principals can create the first active human. AuthZ creates the administrator
group, membership, and grants.

Activation codes, OIDC state, setup sessions, and admin sessions are not Principal records.

Root setup finishes only after AuthZ creates a valid active human administrator.

## Let AuthZ Decide Permissions

AuthZ stores groups, memberships, grants, conditions, and decisions.
`Ankole.Principals` supplies identity, active or disabled status, and the Human
revocation generation. AuthZ owns permissions.

Authorization fails closed for these cases:

- A missing or disabled Principal.
- A wrong Principal type.
- Invalid group conditions.
- Malformed resource or action input.

See [AuthZ](AuthZ.md) for the decision contract.

## Audit Actors

The Console API projects an audit actor as an object with `tenant_id` and `uid`.

Ownership is a real Principal foreign key when it controls permission or
work authorization. Audit-only actor fields use `Ankole.ActorRef`, stored as
`ankole:<tenant_id>:principal/<uid>`. For example, Agent `created_by` and Brain
`author` keep the original actor's tenant when a site administrator works in
another tenant. Removing the actor does not remove the historical reference.

## Rules

- Use `principals.uid` to identify the responsible subject.
- Store Principal UIDs in lowercase.
- Use `system` only for a system service that owns durable state.
- Disable a Human through `HumanAccess`; keep its identity and audit history.
- Keep Agent runtime facts outside the common Principal row.
- Require a nonempty Agent role and a JSON options object.
- Prefer `platform_subject` when provider records refer to the same human.
- Verify a channel identity before Ankole trusts it to act for a Principal.
- Keep groups and grants inside AuthZ.
