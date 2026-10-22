# Principal

`Ankole.Principals` is the Ash domain of the typed persistence actions for
Principals, Agent and Human profiles, external identities, local credentials,
access restrictions, audit events, and pending identity mappings. These
resources use the existing PostgreSQL tables and constraints. The Principal UID
codec and tenant-qualified ActorRef codec remain the identity and attribution
contracts.

Each aggregate operation (update an Agent; update a Human; create a
local account; Human access changes; mapping reviews; work classification and
cleanup; local password writes) is a generic action of
`Ankole.Principals.Principal`, `MappingRequest`, or `LocalCredential`. The
generic action owns the transaction and the lock order, and the resource
actions run in it. Another domain does the same steps in its own transaction
through the `_in_tx` functions, for example `Principals.create_human_in_tx/2`
and `Principals.lock_principal_in_tx/3`; it cannot call the generic action
there. Human and Agent creation, Agent enablement and deletion, platform
subject upserts, forced password changes, and mapping observations still open
their own transaction, because callers of other subsystems call them in a
transaction.
They become generic actions when those callers use the `_in_tx` forms.
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

New UIDs are server-generated UUIDv7 text. Existing UIDs do not change during
upgrade. An Agent has a separate, editable `handle`, unique within its tenant,
with this pattern:

```text
^[a-z0-9][a-z0-9._-]{0,95}$
```

API paths, tokens, Worker IDs and Brain page slugs continue to use the stable
UID. The console displays the handle. New Agent requests supply `handle`, not
`uid`. Names never establish identity.

## Stored Rows

### `principals`

The table stores these fields:

- `uid` as the text primary key.
- `tenant_id` as the required tenant foreign key.
- `type` as `human`, `agent`, or `system`.
- `status` as `active` or `disabled`.
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
`Ankole.IdentityProviders.Phone.normalize_china_mobile/1` before this validation.
That helper tries the supplied number first, then a +86 candidate for an
11-digit number that starts with 1. Other providers keep their own input rules.

Unique indexes protect non-null email and mobile values.

A human user can also hold a local sign-in password in
`human_user_local_credentials`. See
[Local Password Identity Provider](LocalPasswordIdentityProvider.md).

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

Provider IDs, external subjects and contact matches are tenant-local. When no
binding exists, Ankole matches attested contact data only within that tenant.
A UID is opaque and is never evidence that two subjects are the same person.

There is one identity shape. Login, directory sync, Signals identity admission,
and manual console mappings all write this same row.

### Build-declared site sources

`IdentityProviders.SiteSources` declares trusted site credential authorities at
build time. Their opaque subject IDs reuse `principal_external_identities` with
the existing tenant, provider, external ID key. Tenant provider configuration
cannot claim those source IDs. A private account ID, its email, a Principal UID,
a Pod, and a Solid WebID remain separate identities.

A site login resolves existing links only. It cannot perform cross-tenant
contact matching or create a Human. The explicit creation or connection owner
writes the link. BrowserSessions records access only from a newly created Human
or a second verified Pod authentication, with the current Human access version.
Switching alone cannot refresh this evidence or restore a disabled member.
Pod profile changes and Email adapter identity links retain their existing owner.

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

When `upsert_platform_subject_human` sees a provider user for the first time, it
tries these identities in order:

1. Use the Principal from an existing binding for any supplied provider subject
   candidate.
2. Use the Principal that owns the normalized email.
3. Use the Principal that owns the normalized mobile number.
4. Use the caller-supplied UID only when it identifies an existing human in
   this tenant; a missing Principal is rejected. This is an explicit mapping
   by a reviewer or identity admission after a match, not a new UID assignment.
5. Create a new Principal with a server-generated UUIDv7 UID.

The contact lookups include disabled Principals. This can link accounts from
different providers when they share one email or mobile number. The contact
match is safe only for a provider whose users are members of the
organization; the Email adapter therefore reports no contact fields, and its
senders match only through an `email` binding.

The transaction locks every supplied provider subject candidate, the tenant-local email
and mobile keys, and the Principal UID it selected or generated. It then writes
every candidate as an alias for the selected Principal. Concurrent observations serialize the same identity
decisions. If one candidate already belongs to a different Principal, the
complete alias write fails and rolls back.

An existing provider link stays with its current Principal. New contact data
does not move it.

Directory sync and provider sign-in also bind the address that the provider
reports for the user as an `email` identity. The provider is the authority
for that address, so the binding lets the Email adapter admit the user
without a manual mapping. An address that is already bound elsewhere stays
there; the write logs `identity_providers.directory.email_already_bound` and
continues.

`IdentityProviders.Directory.sync_users/3` owns user-stream traversal for Slack,
Google Workspace, and Microsoft 365. Each adapter retains provider pagination,
user selection, and profile mapping. The shared loop loads the directory-group
index once, counts successful writes, and stops on the first page or write
error. Each user keeps its own transaction; a later failure does not undo prior
users. WeCom retains its department traversal and user deduplication.

If another Principal owns the supplied email or mobile number, Ankole ignores
that field and logs `principals.platform_subject.contact_conflict`. It still
stores the remaining identity data.

## Match Without Creating

`match_platform_subject_human` is the read side of the same ladder. An existing
binding for any provider-specific candidate ID wins. Otherwise, the optional
email and mobile values match. An equal Principal UID never matches. The
function returns the matched active human Principal or `{:error, :not_found}`.
It never creates or re-points anything. Signals identity admission uses
it to decide whether a sender is known before the binding's unmatched-sender
policy applies.

Manual mappings bypass the ladder on purpose: `MappingRequests.bind_request`
and `MappingRequests.bind_subject` write the identity to exactly the Principal
the operator chose. This explicit provider binding stays authoritative even
when another provider uses the same external ID.

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

`HumanAccess.disable/4` records a Human restriction and revokes its credentials.
AuthZ protects the last active human administrator.

## Divide Setup from Principal Data

Principals can create the first active human. AuthZ creates the administrator
group, membership, and grants.

Activation codes, OIDC state, setup sessions, and admin sessions are not Principal records.

Root setup finishes only after AuthZ creates a valid active human administrator.

## Let AuthZ Decide Permissions

AuthZ stores groups, memberships, grants, conditions, and decisions.
`Ankole.Principals` supplies identity, active or disabled status, and the Human
revocation generation. AuthZ continues to own permissions.

Authorization fails closed for these cases:

- A missing or disabled Principal.
- A wrong Principal type.
- Invalid group conditions.
- Malformed resource or action input.

See [AuthZ](AuthZ.md) for the decision contract.

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

## Audit Actors

The Console API projects an audit actor as an object with `tenant_id` and `uid`.

Ownership remains a real Principal foreign key when it controls permission or
work authorization. Audit-only actor fields use `Ankole.ActorRef`, stored as
`ankole:<tenant_id>:principal/<uid>`. For example, Agent `created_by` and Brain
`author` keep the original actor's tenant when a site administrator works in
another tenant. Removing the actor does not remove the historical reference.
