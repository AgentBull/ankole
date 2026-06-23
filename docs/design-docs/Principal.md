# Principal

Principal is Ankole's durable accountable subject model. A Principal is the
entity that can own work, receive permissions, appear in audit trails, and be
referenced by runtime records.

Current Principal types are `human` and `agent`. Service accounts, external
actors, organization units, and richer employment/seat records are future
surfaces, not part of the current Principal contract.

Ankole is modeled as one Installation. Principal identifiers are therefore
installation-wide. There is no SaaS tenant id hidden inside the Principal key.

## Responsibility

Principals owns:

- the stable subject row for humans and agents;
- lifecycle status shared by all subjects;
- human profile rows;
- agent subtype rows and provenance;
- external identity bindings that connect provider facts to a Principal;
- deterministic subject lookup for AuthZ, External Gateway, setup, console, and
  agent runtime code.

Principals does not own:

- permission grants, groups, computed group rules, or authorization decisions;
- chat room/message projection, delivery, or outbox state;
- agent conversations, LLM turns, memory, mission, soul, or runtime profiles;
- AppConfigure values or plugin configuration;
- bootstrap environment variables;
- admin web sessions, OIDC handshakes, or one-time login code storage.

Those concerns may reference Principal UIDs, but their rows and policies belong
to their owning subsystems.

## Runtime Placement

The durable Principal domain belongs to the Elixir control plane and
PostgreSQL. Bun runtimes may execute agent work, provider calls, or AI proxy
logic, but they should not invent a parallel subject model.

When Bun code needs identity, it should receive or resolve a `principal_uid`
from the control-plane boundary. PostgreSQL remains the source of truth for
Principal rows, external identity bindings, AuthZ groups, and grants.

## Facade

The intended Elixir facade should live under `Ankole.Principals`. It should
expose domain operations rather than table-shaped helpers:

- normalize and validate Principal UIDs;
- create and update human Principals;
- create, update, list, disable, and resolve agent Principals;
- read and update Principal lifecycle status;
- create and upsert external identity bindings;
- upsert a human from a provider-scoped platform subject;
- resolve a platform subject to an active human Principal;
- resolve a verified channel actor to an active human Principal.

AuthZ-facing calls such as first-admin initialization belong to the AuthZ or
setup boundary. Principals may provide the human Principal used by that flow,
but AuthZ owns the admin group, group membership, and permission grants.

## Tables

The table names below describe the intended durable model. Ankole may implement
them through Ecto schemas, but the database contract matters more than the
module names.

### `principals`

`principals` stores the common subject row:

- `uid` as lowercase text primary key;
- `type`: `human` or `agent`;
- `status`: `active` or `disabled`;
- `display_name`;
- `avatar_url`;
- timestamps.

There is no separate internal `id` column for Principal rows. `uid` is the
subject key used by subtype tables, AuthZ memberships and grants, agent records,
external identity bindings, setup, console, and runtime references.

UIDs are case-insensitive at API edges and lowercase in storage. Callers must
normalize before writes.

### `human_users`

`human_users` stores human-only profile fields:

- `principal_uid` as primary key, referencing `principals.uid`;
- optional normalized `email`;
- optional normalized `mobile`;
- optional `job_title`;
- timestamps.

Email, mobile, and job title are optional because a human can enter Ankole
through a chat event or directory sync before web login exists. Email and
mobile should be unique when present. Mobile numbers should be stored in a
normalized external format such as E.164 rather than guessed from locale at
write time.

### `agents`

`agents` stores agent-only fields:

- `uid` as primary key, referencing `principals.uid`;
- `type` as an enum, defaulting to `ai_colleague` and presented as "AI
  Colleague";
- non-empty `role` string;
- `options` as a JSON object;
- optional `created_by_principal_uid`;
- timestamps.

The current agent type enum has one value:

- `ai_colleague`: a Principal-backed AI colleague that works through the
  AIAgent runtime.

An agent is a first-class Principal. It can hold grants, belong to groups, own
external identities, and appear in audit trails.

`role` is the concise work identity for the agent, such as "Research Analyst"
or "Customer Success Operator". `options` stores agent-subtype options that are
safe to keep with the subtype row. Agent mission, soul, model profile, memory,
conversations, schedules, and provider-visible channel bindings are not
Principal fields. They belong to AIAgent, External Gateway, AppConfigure, Work,
or future Brain surfaces. The Principal row gives those subsystems a stable
subject to reference.

### `principal_external_identities`

`principal_external_identities` stores provider identity bindings:

- opaque row `id` for the binding record;
- `principal_uid`, referencing `principals.uid`;
- `kind`: `platform_subject`, `channel_actor`, `login_subject`, or
  `outbound_actor`;
- `provider`;
- `adapter`;
- `channel_id`;
- `external_id`;
- `verified_at`;
- `metadata` as a JSON object;
- timestamps.

The binding row has its own opaque id because it is not itself the subject. The
Principal subject key remains `principal_uid`.

## External Identity Kinds

External identities are evidence that an external provider subject maps to an
Ankole Principal. They are not all login identities.

### `platform_subject`

`platform_subject` is the preferred merge point for provider-scoped human
identity. It represents a subject inside a configured provider namespace, such
as a Lark `user_id` inside `lark-main`.

Identity-provider sync, web login, inbound chat attribution, and future outbound
lookup should converge on the same `provider + external_id` binding whenever
the provider can supply a stable platform-level subject.

For Lark-style providers, `user_id` should be the canonical `external_id` when
available. `open_id`, `union_id`, tenant keys, app ids, and raw provider fields
can be stored in `metadata` or used as fallback evidence, but they should not
split the same person into separate Principals when `user_id` exists.

The uniqueness key is:

```text
kind + provider + external_id
```

### `channel_actor`

`channel_actor` is a channel-scoped fallback for integrations that cannot
produce a provider-level subject. It represents one actor observed through one
adapter and channel.

The uniqueness key is:

```text
kind + adapter + channel_id + external_id
```

Authorization-sensitive work must require a verified channel actor binding.
Unverified channel evidence can be stored as observation metadata, but it should
not silently become human authority.

### `login_subject`

`login_subject` represents a web-login subject when the login provider cannot
or should not be modeled as the same provider-level `platform_subject`.

When a login provider and directory/chat provider share a stable platform
subject, the system should prefer `platform_subject` convergence instead of
creating a separate login-only identity graph.

### `outbound_actor`

`outbound_actor` represents provider identity needed for addressing or sending
on behalf of a Principal. It should be used only when the provider's outbound
addressing identity is materially different from the inbound or platform
subject.

## Identity Providers And Chat Adapters

Identity-provider adapters and chat/External Gateway adapters are separate
contracts.

An identity-provider adapter syncs provider directory facts into Principals,
external identities, and AuthZ group bindings. A chat adapter observes and sends
provider-visible messages through External Gateway. Neither adapter type owns
the whole identity row.

When both observe the same provider subject, they should write through the same
Principal API and converge on one `platform_subject` binding. A chat ingress
path that can identify the human actor should persist or resolve that binding
before yielding the normalized event to the agent runtime, so downstream records
carry reliable attribution.

Provider ids are Ankole-local namespaces for configured external providers.
They are not plugin ids, chat channel ids, bot app ids, or agent ids.

## Human Lifecycle

A human Principal can be created by setup, console, identity-provider sync, or a
trusted external identity observation.

Creating or updating a human from external evidence should:

- normalize the target UID;
- upsert the `principals` row as `type = human`;
- upsert the `human_users` row when profile fields are available;
- upsert the relevant external identity binding;
- preserve existing profile fields when the current observation omits them;
- clear fields only when the owning provider explicitly reports absence;
- avoid changing lifecycle status unless the caller owns that policy.

A UID already used by an agent must not be silently converted to a human.

## Agent Lifecycle

An agent Principal is created as one transaction:

- insert the `principals` row with `type = agent`;
- insert the `agents` subtype row;
- write any owning subsystem defaults that must exist before the agent becomes
  observable.

Updating an agent may change display fields, avatar, runtime type, role, or
options. It must not change `uid` or Principal type.

Disabling an agent is a Principal status change, not a delete. Historical
records, grants, provenance, and external bindings should remain explainable.

## Setup And Root Administration

First-admin bootstrap is a setup/AuthZ flow layered on top of Principals. The
Principal domain supplies or creates the active human subject; AuthZ owns the
admin group and membership that close root initialization.

Bootstrap activation codes, setup sessions, OIDC state, and admin web sessions
are not Principal records. They may produce or bind a Principal, but their
storage and expiry policy belong to setup/admin-auth.

The installation is root-initialized once AuthZ has the built-in admin group
and at least one active human admin membership.

## Authorization Boundary

AuthZ owns:

- groups;
- static and computed memberships;
- built-in groups such as admin and all-humans;
- permission grants;
- resource/action matching;
- conditional grant evaluation;
- allow/deny decisions.

Principals owns only subject identity and lifecycle facts used by AuthZ.

Authorization should fail closed for missing Principals, disabled Principals,
wrong Principal type, unverified channel actors, invalid stored group
conditions, and malformed resource/action requests.

## Invariants

- A Principal is the durable accountable subject.
- `principals.uid` is the Principal primary key.
- Principal UIDs are lowercase in storage and case-insensitive at API edges.
- Human and agent are the only current Principal types.
- A Principal status change is a lifecycle transition, not deletion.
- Agent runtime details are not stored in the common Principal row.
- `agents.type` is an enum; the current default is `ai_colleague` / "AI
  Colleague".
- `agents.role` is required and must not be blank.
- `agents.options` is a JSON object.
- `platform_subject` is the preferred identity convergence point.
- `channel_actor` is a channel-scoped fallback and must be verified before
  authorization-sensitive use.
- Identity-provider sync and chat ingress must not create divergent Principals
  for the same provider-level person.
- AuthZ owns grants and groups; Principals owns identity and lifecycle.
- PostgreSQL is the durable source of truth for Principal and AuthZ facts.
