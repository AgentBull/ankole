# Principal

A Principal identifies the human or Agent responsible for an action. Work,
permissions, and audit records all use that same identity.

Current Principal types are `human`, `agent`, and `system`.
One UID identifies a Principal across the complete deployment instance. Ankole
does not add a second organization boundary inside the instance.

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
- SignalsGateway messages, deliveries, or outbox rows
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

An Agent UID must also match this pattern:

```text
^[a-z0-9][a-z0-9._-]{0,95}$
```

This pattern makes the UID safe to use when Ankole selects an Agent Home path.

## Stored Rows

### `principals`

The table stores these fields:

- `uid` as the text primary key.
- `type` as `human`, `agent`, or `system`.
- `status` as `active` or `disabled`.
- Optional `display_name` and `avatar_url`.
- `inserted_at` and `updated_at`.

Disabling a Principal changes its status but keeps the row.

### `human_users`

The table extends a human Principal with these fields:

- `principal_uid` as the primary and foreign key.
- Optional `email`.
- Optional `mobile`.
- Optional `job_title`.
- `inserted_at` and `updated_at`.

The changeset lowercases email addresses.
It validates mobile numbers as E.164 values through the native kernel.

Unique indexes protect non-null email and mobile values.

### `agents`

The table extends an agent Principal with these fields:

- `uid` as the primary and foreign key.
- `type` as the `ai_colleague` enum.
- Required nonempty `role`.
- `options` as a JSON object.
- Optional `created_by_principal_uid`.
- `inserted_at` and `updated_at`.

Agent mission, soul, design, memory, and model profiles belong to their own
subsystems. They do not belong in the Principal row.

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
- `provider` as the platform-subject namespace, normally an identity-provider
  `provider_id` such as `lark-main`.
- `external_id` as the provider-scoped subject id.
- A JSON `metadata` object. Alternate provider ids for the same subject, for
  example a Lark `open_id` next to a `union_id`, live here.
- Timestamps.

Its uniqueness key is:

```text
provider + external_id
```

The binding ID identifies only that external link. The Principal UID still
identifies the responsible human or Agent.

There is one identity shape. Login, directory sync, SignalsGateway admission,
and manual console mappings all write this same row.

### `identity_mapping_requests`

The table holds signal senders that resolved to no Principal while their
binding uses the `manual_review` policy. One row exists per
`provider + external_id`. It stores the sender display name, email, and
mobile when the platform reveals them, plus observation metadata such as
alternate ids and the binding that saw the sender. The operator console lists
these rows; binding one to a Principal writes the identity row and deletes the
request.

## Link First-Seen Provider Users to Existing Humans

When `upsert_platform_subject_human` sees a provider user for the first time, it
tries these identities in order:

1. Use the Principal from an existing provider binding.
2. Use the Principal that owns the normalized email.
3. Use the Principal that owns the normalized mobile number.
4. Use the caller-supplied UID.
5. Use the external subject ID as the UID.

The contact lookups include disabled Principals. This can link accounts from
different providers when they share one email or mobile number.

The transaction locks the provider identity, email, and mobile keys, so two
concurrent observations cannot create duplicate Principals.

An existing provider link stays with its current Principal. New contact data
does not move it.

If another Principal owns the supplied email or mobile number, Ankole ignores
that field and logs `principals.platform_subject.contact_conflict`. It still
stores the remaining identity data.

## Match Without Creating

`match_platform_subject_human` is the read side of the same ladder. It accepts
several candidate external ids plus optional email and mobile values, and
returns the matched active human Principal or `{:error, :not_found}`. It never
creates or re-points anything. SignalsGateway identity admission uses it to
decide whether a sender is known before the binding's unmatched-sender policy
applies.

Manual mappings bypass the ladder on purpose: `MappingRequests.bind_request`
and `MappingRequests.bind_subject` write the identity to exactly the Principal
the operator chose.

## Create and Update Humans

`create_human` inserts the Principal and human profile in one transaction.
`update_human` changes only mutable Principal and human profile fields.

An external identity can create or update a human. An omitted profile field
keeps its current value. An explicit blank clears it.

A UID that belongs to an agent cannot become a human.

`resolve_platform_subject` returns only an active human Principal.
`resolve_platform_subject_uid` also supports cleanup for a disabled Principal.

## Create and Update Agents

`create_agent` does the following in one transaction:

1. Validate that the Agent UID is safe in an Agent Home path.
2. Insert the `principals` row.
3. Insert the `agents` row.
4. Seed Agent Library state.
5. Notify the Agent Home projection runtime.

`update_agent` changes mutable display and subtype fields.
It cannot change the UID or Principal type.

`disable_principal` first asks AuthZ to protect the last active human administrator.
It then changes the status to `disabled`.

## Divide Setup from Principal Data

Principals can create the first active human. AuthZ creates the administrator
group, membership, and grants.

Activation codes, OIDC state, setup sessions, and admin sessions are not Principal records.

Root setup finishes only after AuthZ creates a valid active human administrator.

## Let AuthZ Decide Permissions

AuthZ stores groups, memberships, grants, conditions, and decisions.
`Ankole.Principals` supplies only identity and active or disabled status.

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
- Disable a Principal by changing its status. Do not delete it.
- Keep Agent runtime facts outside the common Principal row.
- Require a nonempty Agent role and a JSON options object.
- Prefer `platform_subject` when provider records refer to the same human.
- Verify a channel identity before Ankole trusts it to act for a Principal.
- Keep groups and grants inside AuthZ.
