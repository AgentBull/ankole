# Principal

BullX represents every durable internal actor as a `Principal`. Human accounts
and Agents share the same identity, lifecycle, authorization subject, and audit
subject, while type-specific facts live in extension tables. The first
implementation uses `principals` as the base table, `human_users` and `agents`
as one-to-one extension tables, and Principal-centered AuthN tables for external
identity bindings, activation codes, and built-in channel login codes.

## Scope

This design covers the Principal identity model and the AuthN surfaces that
create or resolve Human Principals:

- Principal identity, status, and globally unique `uid`.
- Human account extension data.
- Agent extension data.
- External identity mappings from providers, channel actors, and outbound
  actors.
- Activation codes for new Human Principal activation.
- Bootstrap activation-code creation and consumption metadata.
- Built-in channel-auth login codes as one login-provider mechanism.
- Runtime configuration, public API shape, persistence, failure behavior, and
  implementation handoff.

This design intentionally does not cover AuthZ groups, roles, permission grants,
Cedar policy evaluation, audit-log storage, Signal admission, Work ownership,
Mission planning, Capability execution, Governance, Effect production, Brain
memory, external transport implementation, or full Web login route wiring.
Those subsystems consume `principals.id` as their durable subject id after
their own design docs define their tables and runtime behavior.

## Goals

- Make `Principal` the stable BullX subject for authorization, audit, ownership,
  and responsibility.
- Avoid a user-centered model that treats Agents as second-class accounts.
- Preserve a boring relational shape: a base `principals` table plus one-to-one
  extension tables instead of pure single-table inheritance.
- Let Human Principals authenticate from external providers and channel actors
  without making transport code own BullX identity.
- Let Agent Principals carry type-specific runtime profile data without adding a
  new table for every Agent implementation shape.
- Keep bootstrap setup possible on a fresh Installation before an administrator
  exists.
- Store all durable identity facts in PostgreSQL, with process-local state
  reconstructible after restart.

## Non-goals

- Service accounts, external actors as Principals, and system actors are future
  Principal types. The initial enum contains only `human` and `agent`.
- Activation codes do not attach a new channel actor to an existing Human
  Principal. Manual binding management belongs to a later operator surface.
- Activation codes do not create or bind Agent Principals.
- The built-in channel-auth login provider defines code generation and
  verification only. Transport command handling and Web session route wiring
  can use those APIs after the relevant surfaces are rebuilt.
- This design does not define Agent runtime profile schemas.
- This design does not write administrator group membership. Bootstrap metadata
  marks the activation-code path that created the bootstrap Human Principal; the
  AuthZ design decides how that Principal becomes an administrator.

## Cleanup plan

- **Dead code to delete:** none. The repository is currently an infra shell and
  has no live Principal implementation to remove.
- **Duplicate logic to merge:** do not recreate the old `BullXAccounts`
  namespace. Move the useful AuthN semantics into `BullX.Principals`.
- **Existing utilities and patterns to reuse:** use `BullX.Repo`, Ecto schemas,
  `BullX.Ecto.UUIDv7`, `BullX.Config`, `BullX.Ext.argon2_hash/1`,
  `BullX.Ext.argon2_verify/2`, and Phoenix cookie sessions.
- **Code paths and contracts changing:** add a new `BullX.Principals` domain,
  migrations for Principal/AuthN tables, runtime config declarations, and
  public facade functions for resolving, creating, activating, and verifying
  Principals.
- **Invariants that must remain true:** process-local state is reconstructible;
  disabled Principals cannot authenticate or resolve as active subjects;
  plaintext activation and login codes are never stored; channel actors remain
  channel-local unless a subsystem explicitly resolves them.
- **Verification command:** run focused Principal tests and `bun precommit`.

## Existing system

BullX currently has core infrastructure, Web shell, runtime configuration,
plugin discovery, UUIDv7 generation, and a Rust NIF boundary. It does not have a
live Accounts or Principal subsystem. Historical `BullXAccounts` drafts are
input only; they do not define an implementation that must be kept compatible.

The existing design docs define two constraints that this design relies on:

- `docs/design-docs/Configuration.md` defines runtime configuration through
  `BullX.Config` with PostgreSQL overrides, OS environment, application config,
  and code defaults.
- `docs/design-docs/Plugins.md` defines trusted compile-time plugins and typed
  extension declarations.

## Domain model

`Principal` is the durable internal subject. A Principal can be authorized,
disabled, audited, held responsible, and referenced by future subsystem records.
Human users and Agents are not separate identity systems; they are Principal
types with extension data.

### Principals

`principals.uid` is the globally unique, case-insensitive handle for a Principal.
Humans can use it as a username. Agents can use it as a stable handle in control
surfaces, logs, and future routing rules without implying that an Agent is a
human account.

The implementation stores `uid` in canonical lowercase form. `display_name`
stores presentation text. `bio` stores a short operator-facing description or
profile. `avatar_url` stores an optional image for any Principal type. `type`
selects the extension table and starts with `human` and `agent`. `status`
starts with `active` and `disabled`.

Only `active` Principals can resolve from external identities, log in, or run as
business subjects. `disabled` is the uniform lock state for Humans and Agents.

### Human Principals

`human_users` is the Human account extension table. A Human Principal represents
a real person who can log in to BullX control surfaces and act as an accountable
subject.

Human-specific fields include nullable `email` and nullable `phone`. `email`
and `phone` are globally unique when present. `email` is trimmed and lowercased.
`phone` is normalized to E.164 before storage.

The table name is deliberately `human_users`, not `users`, because `Principal`
is the broader identity concept. Code may still use `User` in Web session
contexts when it means a logged-in human, but durable schemas should keep the
Human extension boundary explicit.

### Agent Principals

An Agent Principal is a durable work subject with identity, responsibility,
memory, capabilities, permissions, outbound identity, and KPIs. It is not
automatically an LLM process, a chat bot, or a long-lived BEAM process.

`agents.type` is a required text identifier. It is intentionally open while
Agent runtime designs are being rebuilt.

`agents.profile` is a required JSONB object. This design only guarantees the
storage mechanism; runtime-specific profile validation belongs to the design
that introduces that runtime. If a profile field becomes query-critical, a later
migration can promote that field to a dedicated column.

`agents.created_by_principal_id` is nullable. It records creation provenance
when a Human or system Principal created the Agent, without defining ownership,
delegation, Mission responsibility, or authorization policy.

## External identities

External identities map provider-side subjects to BullX Principals. External
transport and provider code provide identity claims; `BullX.Principals` decides
whether a claim can resolve to an active Principal or create a Human Principal.

The first implementation supports three identity kinds:

| Kind | Meaning | Required keys |
| --- | --- | --- |
| `channel_actor` | An inbound or duplex channel actor. | `adapter`, `channel_id`, `external_id` |
| `login_subject` | A subject returned by an external Web login provider. | `provider`, `external_id` |
| `outbound_actor` | A Principal's external acting identity, such as an Agent's bot app reference. | `provider`, `external_id` |

`metadata` stores provider context and non-secret troubleshooting data. It must
not store app secrets, access tokens, refresh tokens, private keys, or other
credentials. Plugin configuration, transport configuration, Capability design,
or a future credential store owns those secrets.

Channel actor identity remains channel-local. A normalized channel actor
supplies:

```elixir
%{
  adapter: :chat,
  channel_id: "workplace-main",
  external_id: "user_xxx",
  profile: %{
    "email" => "person@example.com",
    "phone" => "+8613800000000",
    "display_name" => "Alice"
  },
  metadata: %{
    "tenant_key" => "tenant_xxx"
  }
}
```

Only trusted adapter-normalized fields can enter matching rules. User-editable
display names are presentation data, not identity proof.

## AuthN and matching

`BullX.Principals` owns Human Principal AuthN decisions. Transport adapters,
login providers, Web controllers, and future setup screens call the facade
rather than composing schema modules directly.

### Existing binding resolution

Resolving a channel actor first checks
`principal_external_identities(kind: :channel_actor, adapter, channel_id,
external_id)`. If the binding exists and its Principal is active, resolution
returns that Principal. If the Principal is disabled, resolution fails with
`:principal_disabled`. If no binding exists, resolution fails with
`:not_bound`.

Login providers use the same idea with
`principal_external_identities(kind: :login_subject, provider, external_id)`.
Provider login returns an active Human Principal or fails. It must not log in an
Agent Principal.

### Short-circuit matching rules

An unbound channel actor or login subject may carry trusted profile fields. The
matching engine evaluates configured rules in order. The first successful rule
wins, and later rules are not evaluated. If different fields would match
different Human Principals, configured priority decides the result. The first
implementation does not add conflict review.

Rules are JSON-compatible data stored through `BullX.Config`, not module/function
strings parsed from config.

Initial rule operations are:

| Operation | Result | Behavior |
| --- | --- | --- |
| `equals_human_field` | `bind_existing_human` | Compare a trusted source path to a unique Human field such as `email` or `phone`. |
| `email_domain_in` | `allow_create_human` | Allow creation when a trusted email domain is in a configured allowlist. |
| `equals_any` | `allow_create_human` | Allow creation when a trusted source path equals one of a configured set of values. |

Example:

```json
[
  {
    "result": "bind_existing_human",
    "op": "equals_human_field",
    "source_path": "profile.email",
    "human_field": "email"
  },
  {
    "result": "allow_create_human",
    "op": "email_domain_in",
    "source_path": "profile.email",
    "domains": ["example.com"]
  },
  {
    "result": "allow_create_human",
    "op": "equals_any",
    "source_path": "metadata.tenant_key",
    "values": ["tenant_xxx"],
    "managed_by": "setup.external_org_members"
  }
]
```

`managed_by` is optional metadata for operator or setup-owned rules. It must not
affect rule evaluation.

### Human creation policy

For an unbound channel actor or login subject, `BullX.Principals` first follows
the rule-driven path:

1. If a `bind_existing_human` rule matches an active Human Principal, create the
   external identity binding for that Human Principal.
2. If a `bind_existing_human` rule matches a disabled Principal, reject with
   `:principal_disabled` and stop.
3. If an `allow_create_human` rule matches and automatic Human creation is
   enabled, create a new Human Principal and its first external identity.
4. If an `allow_create_human` rule matches but automatic Human creation is
   disabled, continue to the unmatched policy.
5. If no rule matches, continue to the unmatched policy.

Automatic binding to an existing active Human Principal is not blocked by the
automatic creation switch because binding is not creation.

The unmatched policy depends on caller type:

- For duplex channel actors, `principals_authn_auto_create_humans = true` and
  `principals_authn_require_activation_code = false` creates a new Human
  Principal and first channel binding from trusted profile data.
- For duplex channel actors, `principals_authn_auto_create_humans = true` and
  `principals_authn_require_activation_code = true` returns
  `:activation_required`.
- For duplex channel actors, `principals_authn_auto_create_humans = false`
  returns `:activation_required`; activation-code consumption still works.
- For Web login providers, unmatched identities never create a Human Principal.
  The login fails without creating a session and should direct the user to an
  activation-capable channel.

## Activation codes

Activation codes are short-lived, single-use preauth credentials for creating a
new Human Principal from a channel actor. They are closer to Tailscale preauth
keys than recipient-bound invitations.

An activation code:

- is not tied to a target Principal;
- is not tied to a target email, phone number, or channel actor;
- creates a new Human Principal and that Human's first `channel_actor` external
  identity when consumed;
- never attaches a channel actor to an existing Principal;
- never creates or binds Agent Principals;
- stores only `code_hash`, never plaintext;
- is retained after use for audit context.

When a channel actor cannot be matched and activation is required, the adapter
can send a message equivalent to:

```text
The current account cannot be linked to BullX automatically. Contact an administrator for an activation code, then send /preauth <code> to activate.
```

`/preauth <code>` calls `BullX.Principals.consume_activation_code/2` with the
current normalized channel actor. The operation runs in one database
transaction:

1. Check whether the channel actor is already bound. If bound, return
   `:already_bound` and do not consume the code.
2. Run automatic matching. If matching binds to an existing active Human
   Principal, return that binding and do not consume the code.
3. Verify the plaintext code against currently valid activation-code hashes.
4. Atomically mark the matching code used.
5. Create a new `principals` row with `type = human`.
6. Create the matching `human_users` extension row.
7. Create the first `principal_external_identities(kind = channel_actor)` row.
8. Store `used_by_principal_id` and the consumed channel actor context on the
   activation-code row.

Concurrent attempts to consume the same activation code must produce exactly
one success. Argon2 hashes are salted, so the implementation must not recompute
a deterministic hash and query by equality on `code_hash`. It should load the
bounded set of currently valid candidate rows, verify each candidate with
`BullX.Ext.argon2_verify/2`, and consume only the matched row inside the
transaction. If candidate volume becomes an operational problem, a later design
can add a non-secret selector.

## Bootstrap activation

Bootstrap activation uses the same `activation_codes` table with
`metadata.bootstrap = true`. The metadata flag marks the one setup escape hatch
for a fresh Installation. It does not itself grant AuthZ permissions.

On application startup, a one-shot transient worker runs after `BullX.Repo` and
`BullX.Config.Supervisor`:

1. If Principal tables do not exist, the worker logs a warning and exits
   normally.
2. If any Human Principal exists, the worker does nothing.
3. If a consumed activation code with `metadata.bootstrap = true` exists, the
   worker does nothing.
4. If an unused, unrevoked bootstrap activation code exists, the worker refreshes
   that row in place with a new hash and expiration.
5. If no pending bootstrap row exists, the worker inserts one.
6. When the worker creates or refreshes a bootstrap row, it logs the plaintext
   code exactly once.

The create/refresh operation runs in a transaction protected by a PostgreSQL
advisory transaction lock. The worker rechecks Human Principal emptiness and
consumed bootstrap state after acquiring the lock, so concurrent node startups
cannot fork bootstrap credentials.

When a bootstrap code is consumed through `/preauth`, normal activation creates
the new Human Principal and stamps `activation_codes.used_by_principal_id`.
Future AuthZ implementation can use that durable fact to grant initial
administrator membership. This design does not create group or permission rows.

The setup gate may verify a bootstrap activation code before the code is
consumed. Verification returns the matched `code_hash` for a still-valid
bootstrap row so a Phoenix session can store the hash rather than the plaintext.
The gate check must not consume the activation code; consumption happens only
through the channel activation path.

## Built-in channel-auth login provider

The built-in channel-auth login provider is a Web login mechanism for already
bound active Human Principals on duplex channels. It is Device Code Flow-like but
internal to BullX.

The provider has two core operations:

1. Issue a short-lived code when an active Human Principal controls the current
   channel actor.
2. Consume the code from the Web login surface and return the active Human
   Principal.

Issuance starts from a channel actor. The system resolves
`{adapter, channel_id, external_id}` to an active Human Principal. If the actor
is unbound, resolves to an Agent, or resolves to a disabled Principal, issuance
fails. Successful issuance stores only an Argon2 hash in
`principal_login_auth_codes` and returns the plaintext once to the caller.

Consumption verifies the submitted plaintext against valid candidate hashes,
loads the Human Principal, rejects disabled or non-Human Principals, deletes the
row on success, and returns the Principal for session establishment. This design
does not require the Web route, controller, or IM command path to be complete in
the first implementation; those surfaces should call the provider APIs when they
exist.

JWTs are not a browser session mechanism in this design. Web control surfaces
should use Phoenix cookie sessions and reload the durable Human Principal on
authenticated requests.

## Runtime configuration

Principal runtime configuration lives under `BullX.Config.Principals` and uses
the existing `BullX.Config` resolution model.

Initial declarations are:

| Accessor | DB key | OS env | Default |
| --- | --- | --- | --- |
| `principals_authn_match_rules!/0` | `bullx.principals.authn_match_rules` | `BULLX_PRINCIPALS_AUTHN_MATCH_RULES` | `[]` |
| `principals_authn_auto_create_humans!/0` | `bullx.principals.authn_auto_create_humans` | `BULLX_PRINCIPALS_AUTHN_AUTO_CREATE_HUMANS` | `true` |
| `principals_authn_require_activation_code!/0` | `bullx.principals.authn_require_activation_code` | `BULLX_PRINCIPALS_AUTHN_REQUIRE_ACTIVATION_CODE` | `true` |
| `principals_activation_code_ttl_seconds!/0` | `bullx.principals.activation_code_ttl_seconds` | `BULLX_PRINCIPALS_ACTIVATION_CODE_TTL_SECONDS` | `86400` |
| `principals_login_auth_code_ttl_seconds!/0` | `bullx.principals.login_auth_code_ttl_seconds` | `BULLX_PRINCIPALS_LOGIN_AUTH_CODE_TTL_SECONDS` | `300` |

Invalid higher-priority values fall through to lower-priority sources according
to `BullX.Config` semantics. `principals_authn_match_rules` must validate as
JSON-compatible data. Invalid rules make the config source invalid; they do not
partially apply.

With the defaults, trusted allow-create rules can create Human Principals, while
unmatched channel actors still require activation. Setting
`principals_authn_auto_create_humans` to `false` disables automatic Human
creation but does not disable activation-code consumption.

## Data model

All UUID primary keys use:

```elixir
@primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
```

Migrations must not add PostgreSQL-side UUID defaults such as
`gen_random_uuid()`.

### `principals`

Columns:

- `id`: UUIDv7 primary key.
- `uid`: required globally unique lowercase handle.
- `type`: required native PostgreSQL enum `principal_type` with values `human` and
  `agent`.
- `status`: required native PostgreSQL enum `principal_status` with values
  `active` and `disabled`.
- `display_name`: nullable display name.
- `bio`: nullable text.
- `avatar_url`: nullable avatar URL.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Indexes and constraints:

- unique index on `uid`;
- not-null constraints on `uid`, `type`, and `status`;
- check constraint that `uid = lower(uid)`;
- enum-backed legal values for `type` and `status`.

### `human_users`

Columns:

- `principal_id`: primary key and foreign key to `principals.id`.
- `email`: globally unique email, nullable. Stored lowercased and trimmed.
- `phone`: globally unique phone number, nullable. Stored in E.164 format.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Indexes and constraints:

- unique index on `email` where `email IS NOT NULL`;
- unique index on `phone` where `phone IS NOT NULL`;
- foreign key to `principals.id` with type invariant enforced by changesets and
  transactional creation.

### `agents`

Columns:

- `principal_id`: primary key and foreign key to `principals.id`.
- `type`: required text Agent type identifier.
- `profile`: required JSONB Agent profile object.
- `created_by_principal_id`: nullable foreign key to `principals.id`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Indexes and constraints:

- not-null constraints on `type` and `profile`;
- check constraint that `type` matches `^[a-z][a-z0-9_:-]*$`;
- check constraint that `jsonb_typeof(profile) = 'object'`;
- index on `created_by_principal_id`;
- foreign key to `principals.id` with type invariant enforced by changesets and
  transactional creation.

### `principal_external_identities`

Columns:

- `id`: UUIDv7 primary key.
- `principal_id`: required foreign key to `principals.id`.
- `kind`: required native PostgreSQL enum `principal_external_identity_kind`
  with values `channel_actor`, `login_subject`, and `outbound_actor`.
- `provider`: nullable provider id for login and outbound identities.
- `adapter`: nullable adapter type for channel actors.
- `channel_id`: nullable concrete adapter channel instance id.
- `external_id`: provider-side or channel-side subject id.
- `metadata`: required JSONB context object.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Indexes and constraints:

- unique index on `{adapter, channel_id, external_id}` where
  `kind = 'channel_actor'`;
- unique index on `{provider, external_id}` where `kind = 'login_subject'`;
- unique index on `{provider, external_id}` where `kind = 'outbound_actor'`;
- not-null constraints on `principal_id`, `kind`, and `metadata`;
- check constraint requiring `adapter`, `channel_id`, and `external_id` for
  `channel_actor`;
- check constraint requiring `provider` and `external_id` for `login_subject`
  and `outbound_actor`;
- check constraint that `metadata` is a JSON object.

### `activation_codes`

Columns:

- `id`: UUIDv7 primary key.
- `code_hash`: required PHC-formatted Argon2id activation-code hash, unique.
- `expires_at`: required expiration timestamp.
- `created_by_principal_id`: nullable foreign key to `principals.id`.
- `revoked_at`: nullable revocation timestamp.
- `used_at`: nullable consumption timestamp.
- `used_by_principal_id`: nullable foreign key to `principals.id`.
- `used_by_adapter`: nullable adapter type.
- `used_by_channel_id`: nullable channel id.
- `used_by_external_id`: nullable channel actor external id.
- `metadata`: required JSONB context object.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

A code is valid when:

```sql
revoked_at IS NULL AND used_at IS NULL AND expires_at > now()
```

The implementation should enforce single-use consumption with an atomic update
scoped to the matched row and the validity predicate.

### `principal_login_auth_codes`

Columns:

- `id`: UUIDv7 primary key.
- `code_hash`: required PHC-formatted Argon2id login-code hash, unique.
- `principal_id`: required foreign key to `principals.id`.
- `metadata`: required JSONB context object.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Validity is computed from `inserted_at` and
`principals_login_auth_code_ttl_seconds`. A successfully consumed login auth
code is deleted immediately.

## Public API shape

The public facade is `BullX.Principals`. Internal helper modules may live under
`BullX.Principals.AuthN` and `BullX.Principals.Code`, but callers should not
compose schemas directly.

Expected facade functions:

```elixir
@spec get_principal(Ecto.UUID.t()) ::
        {:ok, BullX.Principals.Principal.t()} | {:error, :not_found}

@spec create_human(map()) ::
        {:ok, %{principal: BullX.Principals.Principal.t(), human_user: BullX.Principals.HumanUser.t()}}
        | {:error, Ecto.Changeset.t()}

@spec create_agent(map()) ::
        {:ok, %{principal: BullX.Principals.Principal.t(), agent: BullX.Principals.Agent.t()}}
        | {:error, Ecto.Changeset.t()}

@spec resolve_channel_actor(atom() | String.t(), String.t(), String.t()) ::
        {:ok, BullX.Principals.Principal.t()}
        | {:error, :not_bound}
        | {:error, :principal_disabled}

@spec match_or_create_human_from_channel(map()) ::
        {:ok, BullX.Principals.Principal.t(), BullX.Principals.ExternalIdentity.t()}
        | {:error, :activation_required}
        | {:error, :principal_disabled}
        | {:error, term()}

@spec create_activation_code(BullX.Principals.Principal.t() | nil, map()) ::
        {:ok, %{code: String.t(), activation_code: BullX.Principals.ActivationCode.t()}}
        | {:error, Ecto.Changeset.t()}

@spec consume_activation_code(String.t(), map()) ::
        {:ok, BullX.Principals.Principal.t(), BullX.Principals.ExternalIdentity.t()}
        | {:error, :invalid_or_expired_code}
        | {:error, :already_bound}
        | {:error, term()}

@spec create_or_refresh_bootstrap_activation_code() ::
        {:ok, %{code: String.t(), activation_code: BullX.Principals.ActivationCode.t(), action: :created | :refreshed}}
        | {:error, term()}

@spec bootstrap_activation_code_pending?() :: boolean()

@spec verify_bootstrap_activation_code(String.t()) ::
        {:ok, String.t()} | {:error, :invalid_or_expired_code}

@spec bootstrap_activation_code_valid_for_hash?(String.t() | nil) :: boolean()

@spec issue_login_auth_code(atom() | String.t(), String.t(), String.t()) ::
        {:ok, String.t()}
        | {:error, :not_bound}
        | {:error, :principal_disabled}
        | {:error, :not_human}
        | {:error, term()}

@spec consume_login_auth_code(String.t()) ::
        {:ok, BullX.Principals.Principal.t()}
        | {:error, :invalid_or_expired_code}
        | {:error, :principal_disabled}
        | {:error, :not_human}
```

Schema modules:

- `BullX.Principals.Principal`
- `BullX.Principals.HumanUser`
- `BullX.Principals.Agent`
- `BullX.Principals.ExternalIdentity`
- `BullX.Principals.ActivationCode`
- `BullX.Principals.PrincipalLoginAuthCode`

Supporting modules:

- `BullX.Principals.AuthN`
- `BullX.Principals.Code`
- `BullX.Principals.Bootstrap`
- `BullX.Config.Principals`

## Runtime and operations

The first implementation does not need a long-lived
`BullX.Principals.Supervisor`. Most behavior is Ecto schemas, transactional
command functions, pure matching, and code hashing.

The only new runtime child is the one-shot transient bootstrap worker. Place it
after `BullX.Repo` and `BullX.Config.Supervisor` in `BullX.Application`. If a
later design adds cleanup workers, provider refresh workers, async audit
delivery, or cache processes, that design must state the new failure boundary.

No process-local Principal state is durable truth. Caches, if introduced later,
must be reconstructible from PostgreSQL.

## Error and failure behavior

Validation failures return changesets from create/update APIs. Public AuthN
functions return tagged errors that preserve the behavior-changing cause:
`:not_bound`, `:activation_required`, `:principal_disabled`, `:not_human`,
`:invalid_or_expired_code`, and `:already_bound`.

Code hashing and verification use `BullX.Ext.argon2_hash/1` and
`BullX.Ext.argon2_verify/2`. Any `{:error, reason}` from those functions fails
closed. Callers may log the reason at debug or warning level according to
context, but logs must not include plaintext codes.

Bootstrap worker failures behave as follows:

- Missing tables during early setup log a warning and exit normally.
- Database errors after tables exist surface as worker failures so startup
  diagnostics point at the broken dependency.
- Concurrent bootstrap attempts serialize through the advisory transaction lock.

Provider failures outside `BullX.Principals` are not Principal contract errors.
Transport and provider implementations own their provider-specific retries,
timeouts, and user-facing messages.

## Security, privacy, and governance

`principals.id` is the future AuthZ, audit, ownership, and responsibility
subject id. This design deliberately does not define groups, roles, grants, or
policy evaluation.

Activation codes and login auth codes are secrets. BullX logs plaintext
activation codes only for bootstrap create/refresh, exactly once per successful
create or refresh. BullX never stores plaintext code values.

External identity metadata may contain provider ids, tenant keys, profile
snapshots, and troubleshooting context. It must not contain credentials or
private tokens. Human profile fields such as email and phone are personally
identifiable information and should appear in logs only when needed for operator
diagnosis and never alongside secrets.

Agents can eventually propose Intents and produce Effects, but this design does
not authorize outbound actions. Governance remains a separate boundary.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Keep the old `BullXAccounts` user-centered design | Rejected. BullX needs Humans and Agents to share one accountable subject model. |
| Use only `users` and add Agent rows elsewhere | Rejected. That makes Agents second-class for AuthZ, audit, and responsibility. |
| Use pure single-table inheritance in `principals` | Rejected. Human and Agent fields have different validation and lifecycle pressure; extension tables keep the base identity small. |
| Add one table per Agent subtype | Rejected for the first implementation. `agents.type` plus validated `profile` handles the single known subtype with less schema churn. |
| Let activation codes bind existing Principals | Rejected. The first activation-code contract stays a preauth path for creating a new Human Principal and first channel binding. |
| Store provider credentials in external identity metadata | Rejected. Metadata is not a credential store and does not create a secret-handling boundary. |
| Implement AuthZ bootstrap membership in this design | Rejected. The bootstrap activation metadata is persisted now; groups and administrator grants belong to the AuthZ design. |

## Implementation handoff

### Goal

Implement `BullX.Principals` as the Principal identity and AuthN boundary using
the schema and behavior in this design.

### Context pointers

- `AGENTS.md`
- `docs/design-docs/Configuration.md`
- `docs/design-docs/Plugins.md`
- `internals/design-docs/drafts/Principal.md`
- `internals/design-docs/deprecated/USER.md`
- `lib/bullx/application.ex`
- `lib/bullx/config.ex`
- `lib/bullx/ecto/uuid_v7.ex`
- `lib/bullx/ext.ex`
- `priv/repo/migrations/`
- `test/support/data_case.ex`
- `test/support/conn_case.ex`

### Constraints

- Use `BullX.Principals`, not `BullXAccounts`.
- Use `principals` plus `human_users` and `agents` extension tables.
- Generate UUID primary keys through `BullX.Ecto.UUIDv7`; do not use
  database-side UUID defaults.
- Use PostgreSQL native enum types for closed value sets.
- Store `uid` lowercase and globally unique.
- Store code hashes only; never store plaintext activation or login codes.
- Do not add AuthZ tables, group membership, Cedar policy, Signal admission,
  Work, Capability, or Governance behavior in this implementation.
- Do not add a long-lived Principal supervisor unless a new design states the
  failure boundary.

### Tasks

1. Add Principal schemas and migrations.
   Owns: migrations, `BullX.Principals.Principal`,
   `BullX.Principals.HumanUser`, `BullX.Principals.Agent`,
   `BullX.Principals.ExternalIdentity`.
   Depends on: None.
   Acceptance: database tables, enum types, constraints, and schema changesets
   match this design.
   Verify: focused schema tests.

2. Add Agent extension validation.
   Owns: `BullX.Principals.Agent`.
   Depends on: Task 1.
   Acceptance: Agent type is present and format-constrained; `profile` is a
   JSON object.
   Verify: Agent schema tests.

3. Add Principal runtime configuration.
   Owns: `BullX.Config.Principals` and config type helpers if needed.
   Depends on: None.
   Acceptance: all declared config values resolve through `BullX.Config`, and
   invalid match-rule data falls through to lower-priority sources.
   Verify: config tests.

4. Add code generation and hashing helpers.
   Owns: `BullX.Principals.Code`, `BullX.Ext` phone normalization if missing.
   Depends on: Task 1 for schema integration.
   Acceptance: activation and login auth code helpers return plaintext once and
   store Argon2 hashes.
   Verify: code hashing tests.

5. Implement matching and Human creation.
   Owns: `BullX.Principals.AuthN`, `BullX.Principals` facade.
   Depends on: Tasks 1 and 3.
   Acceptance: channel actors and login subjects resolve existing bindings,
   short-circuit rules bind existing Human Principals, disabled Principals fail,
   and allowed creation creates a Principal, Human extension, and external
   identity in one transaction.
   Verify: AuthN matching tests.

6. Implement activation codes.
   Owns: `BullX.Principals.ActivationCode`,
   `BullX.Principals.AuthN`.
   Depends on: Tasks 1, 4, and 5.
   Acceptance: activation consumption creates only new Human Principals, never
   binds existing Principals, is single-use under concurrency, and records
   `used_by_principal_id` plus channel context.
   Verify: activation-code tests, including concurrent consumption.

7. Implement bootstrap activation.
   Owns: `BullX.Principals.Bootstrap`, `BullX.Application`.
   Depends on: Task 6.
   Acceptance: fresh Installation startup creates or refreshes one
   `metadata.bootstrap = true` activation code, logs plaintext only on create or
   refresh, and stops touching bootstrap after a Human Principal exists or a
   bootstrap code has been consumed.
   Verify: bootstrap worker tests.

8. Implement built-in channel-auth login codes.
   Owns: `BullX.Principals.PrincipalLoginAuthCode`,
   `BullX.Principals.AuthN`, facade functions.
   Depends on: Tasks 1 and 4.
   Acceptance: issue succeeds only for active Human Principals resolved from a
   channel actor; consume verifies TTL, deletes the row, rejects disabled or
   non-Human Principals, and returns the Principal.
   Verify: login-auth-code tests.

9. Add minimal Web/session integration only where existing shell needs it.
   Owns: Phoenix controllers/plugs/routes only if required by the current
   implementation slice.
   Depends on: Tasks 5, 7, and 8.
   Acceptance: Web code calls `BullX.Principals` facade functions and stores
   only Principal ids or bootstrap code hashes in the Phoenix session.
   Verify: focused controller tests if Web routes are added.

### Done when

- Migrations and schemas match the data model.
- Public facade functions return the tagged results in this design.
- Tests cover schema constraints, Agent profile validation, matching order,
  disabled Principal behavior, activation-code single use, bootstrap
  create/refresh/stop conditions, and login-auth-code issue/consume behavior.
- `bun precommit` passes.

Implementation should stop and ask if a change would introduce AuthZ tables,
Agent runtime processes, a credential store, non-Human login, activation-code
binding to existing Principals, or a new Principal type.

## Acceptance criteria

- `BullX.Principals` exists as the Principal identity and AuthN namespace.
- `principals`, `human_users`, `agents`, `principal_external_identities`,
  `activation_codes`, and `principal_login_auth_codes` persist the described
  state.
- All UUID primary keys are generated by BullX as UUIDv7 values.
- `uid` is globally unique, lowercase, and usable as the Human username without
  implying that Agents are users.
- Human profile fields validate email and normalize phone values before storage.
- Agent profile data is JSONB with runtime-specific validation deferred to the
  runtime design that owns that profile.
- Channel actor identity remains external and channel-local until resolved by
  `BullX.Principals`.
- Disabled Principals cannot resolve, log in, receive login auth codes, or run
  as active business subjects.
- Activation-code plaintext is never stored, and consumption is transactional
  and single-use.
- Activation-code consumption creates a new Human Principal and first channel
  binding only. It never attaches a channel actor to an existing Principal.
- Bootstrap activation uses `metadata.bootstrap = true`, refreshes pending
  bootstrap rows in place, records `used_by_principal_id` on consumption, and
  does not write AuthZ group membership.
- Built-in channel-auth login code issuance and consumption work for active
  Human Principals and delete consumed codes.
- AuthZ permission policy remains outside this design.
- `bun precommit` passes.
