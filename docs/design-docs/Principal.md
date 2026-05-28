# Principal

Principal is BullX's accountable subject model. Current Principal types are
humans and agents. The implementation lives in `BullX.Principals` and
`BullX.Principals.*`.

## Responsibility

Principals owns:

- human and agent subject records;
- external identity bindings for channel actors, login subjects, and outbound
  actors;
- bootstrap activation code verification for first-admin setup;
- one-time web login auth codes;
- matching or creating humans from trusted channel or login identity evidence;
- agent Principal creation and profile storage.

Principals does not own authorization grants, MailBox delivery, AIAgent
conversation state, IM message storage, or provider source config.

## Facade

`BullX.Principals` delegates to AuthN and plugin login-provider registries.
Current public calls include:

- `get_principal/1`
- `setup_required?/0`
- `create_human/1`
- `create_agent/1`
- `update_agent/2`
- `list_active_agents/0`
- `update_principal_status/2`
- `disable_principal/1`
- `resolve_channel_actor/3`
- `match_or_create_human_from_channel/1`
- `ensure_human_from_channel_actor/1`
- `channel_identity_verified?/1`
- `match_or_create_human_from_login_subject/1`
- `create_or_refresh_bootstrap_activation_code/0`
- `verify_bootstrap_activation_code/1`
- `verify_bootstrap_activation_code_for_setup/1`
- `bootstrap_activation_code_valid_for_hash?/1`
- `root_init_with_bootstrap_code/2`
- `issue_login_auth_code/3`
- `consume_login_auth_code/1`
- `login_provider_ids/1`
- `login_provider_options/1`
- `web_login_url/0`

## Tables

`principals` stores the common subject:

- `uid`, unique and lowercase;
- `type`: `human` or `agent`;
- `status`: `active` or `disabled`;
- `display_name`;
- `bio`;
- `avatar_url`.

`human_users` stores human-only profile fields:

- `principal_id` as primary key;
- optional normalized `email`;
- optional normalized `phone`.

`agents` stores agent-only fields:

- `principal_id` as primary key;
- `profile` JSON object;
- optional `created_by_principal_id`.

`principal_external_identities` stores identity bindings:

- `kind`: `channel_actor`, `login_subject`, or `outbound_actor`;
- `provider`;
- `adapter`;
- `channel_id`;
- `external_id`;
- `verified_at`;
- `metadata`.

Channel actor rows are unique by `(adapter, channel_id, external_id)`.
Login-subject and outbound-actor rows are unique by `(provider, external_id)`
within their kind.

`principal_login_auth_codes` stores short-lived one-time web login codes:

- `code_hash`;
- `principal_id`;
- `metadata`.

Codes are consumed by deleting the row.

## Channel Actors

IMGateway calls `ensure_human_from_channel_actor/1` before writing a human
`im_messages` row.

The input includes:

- `adapter`
- `channel_id`
- `external_id`
- `trusted_realm_by_default`
- optional public profile fields
- optional metadata

If a verified binding already exists, the active Principal is reused. If no
binding exists, AuthN can create a Human Principal and channel identity. The
identity is marked verified when the source trust policy allows it.

`resolve_channel_actor/3` is stricter: it requires an existing verified binding
and an active Human Principal.

## Login Subjects

Browser OIDC login providers call
`match_or_create_human_from_login_subject/1`. The matching policy comes from
`BullX.Config.Principals`.

Current config values include:

- `principals_authn_match_rules`
- `principals_auto_create_humans`
- `principals_require_activation_code`
- `principals_activation_code_ttl_seconds`
- `principals_login_auth_code_ttl_seconds`

Login auth codes are issued by `issue_login_auth_code/3` for verified bound
channel actors. `consume_login_auth_code/1` validates the hash and TTL, deletes
the row, and returns the Principal for session login.

## Bootstrap Activation

Fresh setup uses a process-local bootstrap activation code. The plaintext code
and hash live in `:persistent_term`, not in PostgreSQL.

`create_or_refresh_bootstrap_activation_code/0` only returns a code while setup
is required. Setup pages verify the code with
`verify_bootstrap_activation_code_for_setup/1` and store the hash in the
encrypted web session.

IM adapters handle:

```text
/root_init <bootstrap_activation_code>
```

before IMGateway handoff. `root_init_with_bootstrap_code/2` verifies the
process-local code, resolves or creates a verified channel Human Principal, and
calls `BullX.AuthZ.root_init_admin/1`.

Setup is no longer required once AuthZ has built-in groups and an active human
admin membership.

## Agents

Agents are Principals with type `agent` and a row in `agents`.

The agent `profile` map is owned by AIAgent. Principals stores it but does not
interpret the full runtime semantics. AIAgent validates the `ai_agent` profile
through `BullX.AIAgent.Profile`.

Setup creates or updates agent Principals and ensures a self `invoke` grant
through AuthZ.

## Invariants

- A Principal is the durable accountable subject.
- Human and agent are the only current Principal types.
- Principal ids are UUIDv7 values generated by application code.
- Channel actor resolution for authorization-sensitive work requires
  verification.
- Bootstrap activation codes are process-local secrets, not durable records.
- AuthZ owns groups and permission grants; Principals only calls AuthZ for root
  initialization and safe status changes.
