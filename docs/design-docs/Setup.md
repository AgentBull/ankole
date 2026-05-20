# Setup wizard

The setup wizard is the one-time Web control surface for a fresh BullX
Installation. It opens before any Human Principal exists, protects `/setup` with
the bootstrap activation code, and guides the operator through plugin
enablement, LLM provider configuration, Channel Adapter source configuration,
initial AIAgent creation, AIAgent ACL grants, and default Event Routing Rule
creation.
The final step shows the operator a `/preauth <activation-code>` command to run
inside the configured message channel, which activates the first Human admin.

Setup composes existing subsystem boundaries. It does not own plugin runtime,
LLM provider semantics, Channel Adapter transport semantics, Principal AuthN,
AuthZ policy, AIAgent runtime behavior, EventBus matching, or TargetSession
execution. Setup moves a fresh Installation from "no usable entry point" to "at
least one administrator can enter through an external channel, and the base
AIAgent conversation path is live."

Feishu is the first-party source path that the first implementation must verify,
but setup must not hard-code Feishu or a fixed Agent. Telegram can appear in the
plugin list because `docs/design-docs/Plugins.md` enables Feishu and Telegram by
default, but a plugin only participates in setup when it exposes the setup
integration described in this design.

## Scope

This design covers these setup surfaces:

- `/setup` and the bootstrap-code gate.
- Setup-time locale override.
- Setup progress as Phoenix session state clamped by durable state and runtime
  readiness.
- Step-level Inertia MPA routing, Inertia forms, React Hook Form, TanStack
  React Query for request-local JSON operations, and the existing UIKit.
- Plugin enablement save and whole-application restart.
- LLM provider endpoint configuration.
- First-party Channel Adapter plugin source configuration, connectivity checks,
  generated secrets, and runtime readiness.
- Initial AIAgent Principal and `agents.profile["ai_agent"]` configuration.
- Built-in `admin` group and `all_humans` dynamic group.
- Initial AIAgent ordinary access group, privileged operation group, default
  grants, and editable ACL preview.
- Default Event Routing Rule preview, creation, and live validation that sends
  the first configured source's BullX channel Events to the initial AIAgent.
- The activation-complete page, including plaintext activation command display
  and copy action.
- `/preauth` completion and AuthZ bootstrap admin handoff.
- Implementation ownership, failure behavior, and acceptance criteria.

This design does not cover these surfaces:

- Runtime plugin install, download, compile, hot enable, hot disable, unload, or
  upgrade.
- LLM model aliases, weighted routing, failover, quota, usage accounting, or
  model catalog tables.
- A generic provider-specific adapter schema abstraction.
- EventBus fan-out, fallback routing, TargetSession queue topology, or business
  fact storage.
- A generic Event Routing Rule editor, manual CEL editor, priority editor, or
  operator-selected Target editor.
- A full AuthZ management UI, generic authorization policy editor, or global
  grant seed catalog.
- AIAgent session, message, compression, tool, memory, Brain, or long-running
  Work internals.
- Workflow, Node, SubAgent, Budget, or Capability setup UI.
- SaaS-style Tenant or multi-Installation boundaries.

## Cleanup plan

Setup implementation removes obsolete assumptions instead of wrapping them in
compatibility layers.

- **Dead code to delete:** remove obsolete message-ingress, routing, agent
  profile, and setup-owned identity matching flows if they still exist in the
  implementation path.
- **Duplicate logic to merge:** reuse `BullX.Config`, `BullX.Plugins`,
  `BullX.LLM`, `BullX.Principals`, `BullX.AuthZ`,
  `BullX.EventBus.RuleWriter`, `BullX.AIAgent.Profile`, and existing
  Phoenix/Inertia patterns.
- **New persistence:** do not add setup-owned business tables. LLM providers,
  Principals, AuthZ groups and grants, Event Routing Rules, plugin enablement,
  and plugin source config remain owned by their
  subsystems.
- **Runtime ownership:** do not change OTP failure boundaries. Plugin source
  runtime refresh calls a plugin-owned boundary; setup and EventBus core do not
  own source listeners.
- **Verification command:** run focused tests while implementing each step, then
  run `bun precommit`.

These invariants must remain true:

- PostgreSQL is durable truth. Phoenix session state and process-local state are
  ephemeral and reconstructible.
- Setup gate validation does not consume the bootstrap activation code.
  Consumption happens only through adapter-local `/preauth`.
- The `code_hash` stored in setup session after gate validation is a bearer
  secret. It may live only in the encrypted, HttpOnly Phoenix session and may be
  used only for exact setup-gate matching.
- The `all_humans` group is an AuthZ dynamic group. Every active Human
  Principal effectively belongs to it; disabled Humans, Agent Principals,
  Service Principals, and System Principals do not.
- Provider secrets, bot tokens, OAuth client secrets, activation code hashes,
  and login code hashes must not enter public projections, Inertia props, logs,
  telemetry, EventBus Events, `routing_facts`, or `reply_channel`.
- Channel Adapters do not parse Event Routing Rules, create TargetSessions,
  choose Targets, or persist business facts.
- EventBus remains first-match terminal. Setup creates ordinary positive
  priority database Event Routing Rules and does not create implicit fan-out or
  fallback behavior.
- Setup writes through public subsystem facades. It does not bypass Principal,
  AuthZ, EventBus, or AIAgent boundaries to write internal tables.
- AIAgent privileged access is not ordinary access. A privileged operation group
  must also receive the same AIAgent's `invoke` grant, otherwise the ordinary
  AIAgent access gate rejects the operation before privileged checks run.

## Existing boundaries

Setup depends on the current design documents and code boundaries in the
following table.

| Surface | Setup dependency |
| --- | --- |
| `internals/design-docs/drafts/Arch.md` and `docs/Architecture.md` | Use the current Installation, Principal, Connected Realm, EventBus, Event Routing Rule, Target, TargetSession, AIAgent, and Workflow vocabulary. |
| `docs/design-docs/Plugins.md` | Read discovered plugins, write `bullx.enabled_plugins`, and require restart before the enabled plugin registry takes effect. |
| `docs/design-docs/Configuration.md` | Use `BullX.Config` for plugin enablement, plugin config, secret config, and i18n config. |
| `docs/design-docs/LLMProvider.md` | Write `llm_providers`. Setup does not manage model aliases; concrete model configs belong in AIAgent profile. |
| `docs/design-docs/Principal.md` | Use the bootstrap activation code gate, create Agent Principals, and let `/preauth` consume the activation code to create the first Human Principal. |
| `docs/design-docs/AuthZ.md` | Use bootstrap admin handoff, the built-in `admin` group, the `all_humans` dynamic group, and visible setup seed grants. |
| `docs/design-docs/eventbus/Core.md` and `docs/design-docs/eventbus/Matcher.md` | Create ordinary Event Routing Rules and obey priority, first-match terminal behavior, Blackhole, and scope semantics. |
| `docs/design-docs/eventbus/Persistence.md` | Treat `event_routing_rules` as database-owned routing config. |
| `docs/design-docs/eventbus/ChannelAdapter.md` | Treat Channel Adapters as transport extensions; source config and routing policy do not move into EventBus core. |
| `docs/design-docs/eventbus/CommandTarget.md` and `docs/design-docs/eventbus/SystemCommands.md` | Do not create setup-owned `/command` or `/status` routes. |
| `docs/design-docs/ai-agent/Core.md` | Create an Agent Principal callable as `target_type = "ai_agent"` and store `agents.profile["ai_agent"]`. |
| `docs/design-docs/ai-agent/ACL.md` | Use `invoke` for ordinary AIAgent access and `invoke_privileged` for privileged operations. |
| `docs/design-docs/ai-agent/SlashCommands.md` | Let AIAgent-owned slash commands be recognized by the AIAgent runtime when command Events reach the setup AIAgent route; code-owned system command routes still win first. |
| `docs/design-docs/plugins/*.md` | Read first-party plugin config keys, source setup contracts, connectivity checks, source runtimes, and adapter-local `/preauth` behavior. |

Historical implementations, including the `old-backup` branch, are only
mechanics references for interaction density or UI behavior. They are not an
architecture source.

## Routing and response model

Setup uses a step-level Inertia MPA. Each reachable step has its own GET action
that renders an Inertia page. Persistent add, edit, and save operations submit
through Inertia forms. `GET /setup` is the canonical projection and clamp entry:
it computes the current allowed step and redirects to the canonical step route.

This shape keeps backend implementation simple: one controller action owns one
step, and React does not need a second workflow state machine. The frontend may
share a setup layout, UIKit components, and form helpers, but it must not add a
client router or SPA-only setup store that decides the active step.

Request-local checks, generated secrets, polling, and readiness refreshes may
return JSON. JSON results are operation feedback, not durable completion facts.

| Route | Controller action | Responsibility |
| --- | --- | --- |
| `GET /` | `PageController.home/2` | Redirect a fresh Installation with a pending bootstrap code to `/setup`; otherwise continue to the normal home or login path. |
| `GET /setup` | `SetupController.show/2` | Validate setup session, compute the current step, and redirect to that step or `/`. |
| `GET /setup/sessions/new` | `SetupSessionController.new/2` | Render the bootstrap code gate. |
| `POST /setup/sessions` | `SetupSessionController.create/2` | Verify the bootstrap code, renew the session, and store setup session keys. |
| `GET /setup/plugins` | `SetupPluginsController.show/2` | Render the Plugins step. |
| `POST /setup/plugins` | `SetupPluginsController.update/2` | Save desired `bullx.enabled_plugins` and show a pending-restart banner when runtime state has not caught up. |
| `GET /setup/llm/providers` | `SetupLLMController.show/2` | Render the LLM providers step. |
| `POST /setup/llm/providers/check` | `SetupLLMController.check/2` | Run a request-local provider connectivity check. |
| `POST /setup/llm/providers` | `SetupLLMController.save/2` | Save LLM provider endpoint config. |
| `GET /setup/channel-sources` | `SetupChannelSourcesController.show/2` | Render the Channel Adapter sources step. |
| `POST /setup/channel-sources/check` | `SetupChannelSourcesController.check/2` | Run a plugin-owned request-local source connectivity check. |
| `POST /setup/channel-sources/generated-secret` | `SetupChannelSourcesController.generated_secret/2` | Generate one value for a plugin-declared generated-secret field. |
| `POST /setup/channel-sources` | `SetupChannelSourcesController.save/2` | Check, save, and refresh plugin-owned source runtime state. |
| `GET /setup/ai-agents` | `SetupAIAgentsController.show/2` | Render the AIAgents step. |
| `POST /setup/ai-agents` | `SetupAIAgentsController.save/2` | Create or update the initial AIAgent Principal and its visible ACL grants. |
| `GET /setup/event-routing-rules` | `SetupEventRoutingController.show/2` | Render the non-editable default Event Routing Rule preview and validation state. |
| `POST /setup/event-routing-rules` | `SetupEventRoutingController.save/2` | Create or update the server-derived default channel Event Routing Rule for the initial AIAgent. |
| `GET /setup/activate-admin` | `SetupActivationController.show/2` | Render the completion page with activation command and polling state. |
| `GET /setup/activation/status` | `SetupActivationController.status/2` | Poll bootstrap activation status, clear setup session after AuthZ handoff, and return a redirect target. |

Controller splitting expresses Web ownership, not domain ownership. Controllers
call subsystem facades or a setup context module; controllers do not compose
Ecto schemas directly.

Every step GET action must pass through the same setup projection and clamp.
Direct access to a future step redirects to the earliest incomplete step.
Direct access after setup completion redirects to `/`. Missing or invalid setup
session redirects to `/setup/sessions/new`.

Persistent Inertia form actions share these response rules:

- Missing or invalid setup session clears setup session and redirects to
  `/setup/sessions/new`.
- A completed setup redirects to `/`. An existing Human Principal only ends
  setup when bootstrap admin handoff is complete, or when the current setup
  session hash does not refer to the consumed bootstrap code that is waiting for
  handoff.
- A consumed bootstrap code with pending AuthZ handoff redirects to
  `/setup/activate-admin`, even though the Human Principal already exists.
- Field validation errors rerender the current step with Inertia errors and
  props.
- A successful save redirects to `/setup` or the next canonical route, where
  the GET projection rechecks durable completion.

JSON operation endpoints share these response rules:

- Missing or invalid setup session returns `401` and
  `%{ok: false, redirect_to: "/setup/sessions/new"}`.
- A completed setup returns `409` and `%{ok: false, redirect_to: "/"}`. An
  existing Human Principal follows the same handoff rule as Inertia form
  actions.
- Field validation failure returns `422` and `%{ok: false, errors: [...]}`.
- Success returns `%{ok: true, ...}` with only safe display data.

Clients still treat `GET /setup` as the durable projection source. A JSON
operation's `redirect_to`, check success, or polling result cannot advance setup
by itself.

Controllers must share one setup projection boundary, such as
`BullX.Setup.Projection.state_for_session/1`, instead of each controller
interpreting "Human exists", "session missing", "code consumed", and "handoff
pending" independently. The projection returns missing or invalid session,
pending setup, activation handoff pending, and completed states; each controller
maps those states to the response rules in this section.

All setup routes are unauthenticated control-plane surfaces and must follow
these security rules:

- All POST routes use Phoenix CSRF protection.
- Setup HTML and JSON responses set `Cache-Control: no-store`.
- Successful setup gate validation calls `configure_session(renew: true)`.
- Access logs must not record full query strings, request bodies, Cookie
  headers, or Authorization headers.
- Generated-secret responses and the completion page must also use `no-store`.
- Activation code plaintext can exist only in the encrypted Phoenix cookie
  session and the final completion-page Inertia prop.

## Frontend implementation

Setup UI reuses the existing `webui/src/uikit` components and the current
Inertia boot path. The UI should use the `old-backup` branch only as a
non-normative reference for interaction mechanics or visual density.

The frontend library boundary is:

- Add, edit, and save operations use Inertia form semantics. The server
  projection decides the next step.
- Setup introduces `react-hook-form` for local field state, dirty state, field
  arrays, and server-error mapping.
- Non-Inertia JSON operations may use TanStack React Query, including
  activation polling, runtime-readiness refresh, connectivity checks, and
  generated-secret requests.
- Advanced JSON fields use the existing `json-edit-react` dependency.
- Setup must not introduce another form validator, client router, global state
  store, data-fetching library, or component library without explicit approval.

Setup implementation adds `react-hook-form` and `@tanstack/react-query` as
approved frontend dependencies. Those additions do not reopen the general
dependency policy; any further frontend library still requires explicit
approval.

React Hook Form owns local UX only. Server validation and server projection
remain the source of truth for saved facts and step completion. The client may
provide trimming, uppercase formatting, required-field hints, and JSON parse
preview, but client validation success is not save success.

`json-edit-react` renders advanced JSON fields such as `provider_options`,
plugin advanced config, and AIAgent profile fragments. Setup V1 does not use
RJSF or `react-jsonschema-form` for JSON editing. A future stable JSON Schema
use case can be evaluated separately, but the selected JSON editor must not
turn plugin setup into a setup-owned DSL.

Setup pages behave like an operational wizard. Inline UI in the relevant step
must carry errors, runtime readiness, pending restart, handoff pending, and
routing conflict states. Toasts may confirm saves or copies, but they must not
be the only place where an error appears.

## Secret handling

User-provided secrets, including LLM API keys, bot tokens, OAuth client secrets,
and similar values, are never readable through setup UI after save. A public
projection returns only masked status such as `******`, `present: true`, or
`last_updated_at`. When editing a saved user-provided secret, blank input means
keep the existing value, and a new non-empty value means replace it.

Clear/delete is not the default edit meaning for any saved secret. Setup shows a
clear action only when the owning subsystem or plugin setup schema explicitly
supports it.

System-generated secret values are different from user-provided secrets. They
are visible only in the current browser operation context and use the shared
secret-display component with masked/plain toggle. After save and reload, the
server projection returns only masked status; plaintext cannot be recovered from
persisted secret storage.

## Setup gate

The setup entry path has two stages. `GET /` routes a fresh Installation to
`/setup`; `/setup` validates the Phoenix session's bootstrap activation code
hash against the database.

### Home redirect

`PageController.home/2` redirects to `/setup` only when both conditions are
true:

- No Human Principal exists.
- A pending activation code exists with `metadata.bootstrap = true` and is not
  consumed, revoked, or expired.

If the bootstrap worker has not created a code yet, `GET /` does not fake setup
state. The worker creates the bootstrap code or refreshes a pending code that
has not entered setup yet, and it prints new plaintext once when generated.

### Setup projection

`SetupController.show/2` processes `/setup` in this order:

1. Read `:bootstrap_activation_code_hash` from session.
2. If the hash points to a completed bootstrap activation and AuthZ admin
   handoff is ready, delete setup session keys and redirect to `/`.
3. If the hash points to a consumed bootstrap code but handoff is pending,
   redirect to `/setup/activate-admin` without deleting setup session.
4. If the hash is missing, revoked, expired, or invalid, delete setup session
   keys and redirect to `/setup/sessions/new`.
5. If the hash is valid and unconsumed, call
   `BullX.Principals.bootstrap_activation_code_valid_for_hash?/1`, compute the
   current step, and redirect to that step route.

`bootstrap_activation_code_valid_for_hash?/1` performs exact matching against
`activation_codes.code_hash` plus predicates for unrevoked, unconsumed,
unexpired, and `metadata.bootstrap = true`. Setup gate does not rerun Argon2.

The bootstrap worker still creates pending bootstrap codes at application
startup. After setup gate verification succeeds, the Principal facade marks the
activation-code metadata with a setup-in-progress field such as
`setup_gate_verified_at`. This marker suppresses bootstrap refresh only while
the code is still unexpired and unconsumed. The bootstrap worker must not
replace `code_hash`, extend `expires_at`, or reprint plaintext during that
period, which keeps manual application restart on the Plugins step from
invalidating the encrypted setup session.

If a setup-in-progress bootstrap code expires before `/preauth` consumes it, the
Principal bootstrap worker may clear the setup-in-progress marker, refresh the
row in place with a new hash and expiration, and print the new plaintext once.
The old setup session becomes invalid and the operator returns to the gate with
a fresh bootstrap code available from logs.

### Gate form

`SetupSessionController.new/2` renders `setup/sessions/New` while no Human
Principal exists. Props include:

- `form_action`;
- `current_locale`;
- `available_locales`, from `BullX.I18n.available_locales/0` as BCP 47
  strings.

`SetupSessionController.create/2` accepts either a flat payload or a nested
`%{"setup" => ...}` payload with `bootstrap_code` and `locale`. That payload
flexibility belongs only to the Web form compatibility layer; the controller
normalizes the command before calling the domain layer.

The create flow is:

1. Trim and uppercase `bootstrap_code`, and reject an empty string.
2. Call `BullX.Principals.verify_bootstrap_activation_code_for_setup/1`.
3. Verify candidates with Argon2 inside one atomic transaction and mark the
   matched code with `metadata.setup_gate_verified_at`.
4. Do not consume the activation code, extend `expires_at`, or generate new
   plaintext.
5. On success, call `configure_session(renew: true)`.
6. On success, store the returned `code_hash` in
   `:bootstrap_activation_code_hash`.
7. On success, store the normalized plaintext code in
   `:bootstrap_activation_code_plaintext` for the completion-page Inertia prop.
8. On success, apply the setup-time locale override and initialize
   `:setup_step` to `plugins`.
9. On failure, redirect back to `/setup/sessions/new` with an error and write no
   setup session keys.

On a repeated gate submission, the controller first clears old setup session
keys, then writes keys for the current successful submission. An incorrect new
code must not leave an old plaintext code available for the completion page.

`POST /setup/sessions` must apply rate limiting or backoff before Argon2
candidate verification. The bootstrap code is high entropy, but unauthenticated
verification is still a CPU-expensive surface.

Session plaintext exists only to render the completion page. Phoenix session
must be encrypted, HttpOnly, and Secure in production. Plaintext does not enter
PostgreSQL, `app_configs`, logs, telemetry, Oban args, EventBus Events, dead
letters, or adapter receipts. The controller deletes
`:bootstrap_activation_code_plaintext` when the hash is invalid, activation
status completes, the operator submits a new bootstrap code, or setup session is
cleared.

### Gate constraints

Setup gate does not consume activation codes. Adapter-local
`/preauth <activation-code>` consumes the code through
`BullX.Principals.consume_activation_code/2`. After consumption, the stored
`:bootstrap_activation_code_hash` is no longer a gate credential, but setup can
still use it for activation status projection until AuthZ handoff completes.

`/preauth` is an adapter-local channel activation command. It does not publish
`bullx.command.invoked` and does not enter EventBus routing.

Adapters that expose `/preauth` must apply provider-appropriate rate limiting or
backoff before activation-code verification. Rate limiting protects both
brute-force attempts and CPU pressure from repeated Argon2 candidate scans.

## Setup-time locale override

The bootstrap gate offers a language selector so an operator can complete setup
without knowing how to configure `bullx.i18n_default_locale`.

- The selector options come from `BullX.I18n.available_locales/0`.
- React initializes from the server-provided `current_locale` prop.
- Changing the selector only calls `i18next.changeLanguage/1` in the browser
  until the form is submitted successfully.
- The bootstrap code input may uppercase, strip non-alphanumeric characters,
  and use fixed-length display formatting in the browser. Server normalization
  and verification remain authoritative.
- `SetupSessionController.create/2` handles `locale` only after bootstrap code
  verification succeeds.

Locale write rules are:

- `nil`, blank strings, and values not present in `available_locales` are
  rejected.
- Rejected locale values log one `Logger.warning` with the available list, but
  setup gate still completes and does not write config.
- Valid values write `BullX.Config.put("bullx.i18n_default_locale", locale)`
  and call `BullX.I18n.reload/0`.

The language selector is not a separate save action. After setup, normal console
surfaces own language changes.

## Progress projection

Setup stores progress only in Phoenix session under `:setup_step`. Allowed
values are:

- `plugins`
- `llm_providers`
- `channel_sources`
- `ai_agents`
- `event_routing`
- `activate_admin`

`GET /setup` must not trust `:setup_step` blindly. Every render computes the
earliest incomplete step from durable state and current runtime state.

| Step | Completion check |
| --- | --- |
| `plugins` | Persisted `bullx.enabled_plugins` matches the current runtime enabled plugin registry, and at least one setup-capable Channel Adapter extension is visible. |
| `llm_providers` | `BullX.LLM.Catalog.list_providers/0` returns at least one provider. |
| `channel_sources` | At least one enabled plugin-owned source is saved with required source secrets and has a ready plugin-owned source runtime. |
| `ai_agents` | At least one active Agent Principal exists; setup projection resolves a selected or marked initial AIAgent, or requires explicit selection when multiple unmarked active Agents exist; `BullX.AIAgent.Profile.cast/1` accepts `agents.profile["ai_agent"]`; required AIAgent ACL grants exist. |
| `event_routing` | A sample `RoutingContext` for the setup source first-matches the setup rule in the current runtime `RoutingTable` snapshot, with `target_type = "ai_agent"` and `target_ref = <agent_principal_id>`. A database row alone is not enough. |
| `activate_admin` | All previous steps are complete and bootstrap admin handoff is not complete. |

Session step can return the operator to a previously reached step, but it cannot
skip prerequisites. If session points to a later step and completion checks
fail, `GET /setup` sends the operator to the earliest incomplete step and
updates `:setup_step`. Back navigation only changes session state; it does not
roll back durable facts.

Channel source runtime readiness is weak runtime state. Process restart can make
it temporarily fail. When readiness fails, setup remains on the Channel source
step and shows diagnostics instead of treating source config as proof that a
listener is live.

## Step design

### Plugins

The Plugins step displays compile-time discovered plugins and lets the operator
choose the plugins required by later setup steps. Setup does not download,
compile, install, uninstall, hot load, or stop the BEAM.

When the operator saves:

1. The controller validates that all submitted plugin ids come from discovered
   plugin specs.
2. The controller writes the desired complete list to
   `BullX.Config.put("bullx.enabled_plugins", encoded_ids)` as a JSON array.
3. The controller rereads persisted enabled ids and the current runtime enabled
   plugin registry.
4. If they match, the controller stores `:setup_step = :llm_providers` and
   redirects to `/setup`.
5. If they do not match, the controller keeps the session on Plugins and
   rerenders the step with a pending-restart banner.
6. The operator restarts the application through the deployment environment.
7. The encrypted setup session remains valid because the bootstrap worker does
   not rotate setup-in-progress bootstrap codes.
8. After restart, `GET /setup` reads the runtime plugin registry and advances
   only when enabled plugin extensions are visible.

The pending-restart banner belongs to the Plugins step. There is no
`restart_required` page. As long as persisted `bullx.enabled_plugins` differs
from current runtime enabled plugin ids, `GET /setup/plugins` shows the banner.
The banner lists the plugin ids in the persisted/runtime difference and tells
the operator to restart BullX and return to `/setup`.

Setup does not provide a "restart now" button, does not call `System.stop/0`,
and does not maintain restart trigger modes. Plugin enablement takes effect only
after application restart.

### LLM providers

The LLM step configures BullX provider endpoints. It does not configure concrete
models or model aliases.

Page props include the current public providers, active `req_llm` provider
registry, provider option schema, `check_path`, and `save_path`. Saved provider
API keys appear only as redacted secret status. Plaintext API keys never appear
in props.

Each provider contains:

- `provider_id`, such as `openai_proxy`;
- `req_llm_provider`, such as `openai`, `anthropic`, or an enabled
  plugin-registered provider id;
- optional `base_url`;
- optional `api_key`;
- optional `provider_options` JSON object.

Saving calls `BullX.LLM.Writer.put_provider/1` or
`BullX.LLM.Writer.update_provider/2`. `BullX.LLM.Crypto` encrypts API keys into
`llm_providers.encrypted_api_key`. Setup must not write plaintext API keys to
`app_configs`, Phoenix session, logs, telemetry, or Inertia props.

LLM API keys follow the global setup secret-handling rules. A saved provider
projection never returns the plaintext API key.

`POST /setup/llm/providers/check` is operation feedback, not a completion
condition. It accepts a provider draft and may accept a request-local
`test_model_id` for a real LLM ping. That model id is not stored in
`llm_providers` and does not become an alias, default model, or AIAgent profile
value. The check may use an already saved encrypted API key or the new plaintext
API key in the draft. The response contains only `ok`, field errors, and a safe
ping summary.

Setup V1 supports create and update for provider endpoints. It does not use
"missing from form means delete" list synchronization, and it does not expose
delete for persisted provider rows. The UI may remove unsaved local draft rows.
A persisted provider delete action requires a later explicit design for
ownership, reference checks, and preserving at least one usable provider.

The AIAgent step stores concrete model config objects in
`agents.profile["ai_agent"]["main_llm"]`, `compression_llm`, and `heavy_llm`.
Each object points to a saved local BullX provider row and a provider model id.
Model selection does not belong to the LLM provider row.

### Channel Adapter sources

The Channel Adapter sources step configures at least one message source so the
operator can run `/preauth <activation-code>` externally and ordinary addressed
messages can reach EventBus.

The page is driven by enabled plugin registry entries and first-party plugin
source setup integrations. Setup finds
`:"bullx.event_bus.channel_adapter"` extensions in enabled plugins, then reads
the source setup module from the extension's `opts.setup_module`. This module is
a plugin-owned setup contract. It is not a
`BullX.EventBus.ChannelAdapter` callback and does not change the EventBus
transport-only boundary.

A first-party Channel Adapter extension has this shape:

```elixir
%{
  point: :"bullx.event_bus.channel_adapter",
  id: "feishu",
  module: Feishu.ChannelAdapter,
  opts: %{provider: "feishu", setup_module: Feishu.SourceSetup}
}
```

The minimum source setup module exposes these functions:

- `config_keys/0`, returning the source config key.
- `form_schema/0`, returning field descriptors, defaults, secret/generated
  markers, adapter UI metadata, and help links for the setup UI.
- `public_projection/0`, returning redacted source state and runtime
  readiness.
- `cast_source/2`, normalizing controller payloads into plugin-owned source
  config. First-party V1 source secrets live directly inside source config.
- `generated_secret_fields/0`, listing field paths that setup may generate.
- `connectivity_check/1`, checking a request-local normalized source.
- `routing_sample/1`, building a representative sample `RoutingContext` for
  the Event Routing step.
- `reconcile_sources/0` or an equivalent function, refreshing plugin-owned
  source runtime and returning runtime readiness, restart-required, or
  runtime-not-ready state.

`form_schema/0` is a restricted field descriptor contract. It is not a
setup-owned form DSL, JSON Schema, or RJSF schema. The Web UI uses it to render
fixed UIKit controls for plugin-owned source forms. Field meaning, casting,
validation, redaction, connectivity checks, and persistence remain owned by the
plugin setup module.

V1 `form_schema/0` returns shallow sections and fields:

```elixir
%{
  adapter_id: "feishu",
  label: "Feishu / Lark",
  channel_kind: "im",
  help_url: "https://...",
  default_source: %{},
  sections: [
    %{
      key: "source",
      fields: [
        %{path: ["source", "id"], kind: :text, required: true},
        %{path: ["source", "app_id"], kind: :text, required: true, ui: %{group: "credentials"}},
        %{path: ["source", "app_secret"], kind: :secret, required: true, ui: %{group: "credentials"}}
      ]
    }
  ]
}
```

`channel_kind: "im"` tells the UI that this source is an IM channel adapter.
`source.id` remains the BullX source instance id, not a provider bot username.
Setup must not prefill this field for IM adapters; the operator must choose and
submit the visible source id explicitly.
OAuth/OIDC callback URLs are display-only setup values. BullX derives them from
its own web origin and the source id, then shows them so the operator can copy
them into the provider application console. They are not user-entered fields
and setup does not persist them into source config. IM adapter setup defaults
`im_listen_mode` to `all_messages`; the UI localizes the option labels while
submitting the stable values. Setup does not expose `start_transport` as a
field. Sources saved through setup are expected to start their transport, and
plugin runtime code owns any later operator controls for pausing a source.

V1 supports these field kinds: `:text`, `:url`, `:secret`,
`:generated_secret`, `:number`, `:boolean`, `:select`, `:string_list`, and
`:json`. A field may include `label_key`, `placeholder_key`, `help_url`,
`required`, `default`, `options`, `secret`, `generated`, and `advanced`.
`path` points only into the controller payload's ordinary map path. It cannot
express arbitrary nesting, repeaters, computed fields, cross-form validation, or
business rules. Conditional display is limited to simple same-form equality,
such as `%{path: ["transport", "mode"], equals: "webhook"}`. More complex UI
requires a plugin-specific UI extension or later approved contract.

`:json` fields render through `json-edit-react` and fit plugin advanced config.
Even if a plugin later owns a stable JSON Schema, setup V1 must not switch to
RJSF without a separately approved stable-schema use case.

Setup depends only on the source setup integration. It does not hard-code
Feishu, Telegram, or Discord module paths and does not assume that Feishu is the
only adapter type. The Channel source step first selects a Channel Adapter type,
then creates or edits one configured channel instance for that adapter. If an
enabled first-party plugin does not implement the integration, setup reports
that the plugin is not configurable or runtime ready instead of guessing its
schema. The generic contract is part of V1, while Feishu is the required
first-party acceptance path.

Current first-party plugin config keys are:

| Plugin | Adapter id | Source config key | Secret |
| --- | --- | --- | --- |
| Feishu | `feishu` | `bullx.plugins.feishu.eventbus_sources` | yes |
| Telegram | `telegram` | `bullx.plugins.bullx_telegram.eventbus_sources` | yes |
| Discord | `discord` | `bullx.plugins.discord.eventbus_sources` | yes |

`eventbus_sources` is plugin-owned encrypted config. Each source entry is one
configured BullX channel instance for its adapter and directly stores the
instance secrets it needs, such as Feishu app secrets, Telegram bot tokens,
Discord bot tokens, or OAuth client secrets. Setup does not create a central
source table, a central credential table, a separate secret-profile concept,
or a central source config key.

The source entry's stable `id` is the adapter-local channel instance id:

- It becomes normalized Event `data.channel.id`.
- It becomes the Principal channel actor `channel_id`.
- If the plugin exposes a browser login provider, it is also the concrete login
  provider id.
- It is not a Feishu tenant id, Telegram chat id, Discord application id,
  separate secret-record id, or display label.

Source public projection may expose only redacted secret status. Public
projections must not include app secrets, bot tokens, OAuth client secrets, or
provider access tokens.

When a source enables a browser login provider, `/sessions/new` must show that
provider as a normal Web login method. For Feishu, setup may enable
`source.oidc.enabled` by default; the provider id exposed on `/sessions/new` is
the source id, and the label should identify the external provider such as
`Feishu · main` or `Lark · main`.

The same page also supports login-code sign-in. Its copy should tell users to
send `/webauth` to the bot in a private chat to receive a one-time login code.

Connectivity check flow is:

1. The controller normalizes the source draft for the selected adapter.
2. The controller calls the source setup module's `connectivity_check/1`.
3. The connectivity check does not start listeners, publish Events, write
   Principals, or save source config.
4. Success returns redacted operation feedback, such as adapter id, source id,
   capabilities, and safe diagnostics.
5. A standalone check request only serves UI feedback. The following save
   request cannot reuse it as proof.
6. Disabled drafts can be saved, but disabled drafts do not satisfy completion.

Saving an enabled source runs connectivity check and save in the same request.
The controller normalizes the draft, calls plugin-owned `connectivity_check/1`,
then writes source config only after a successful check. Setup does not persist
cross-request check results and does not store check results in Phoenix session.

`generated-secret` only works for plugin-declared generated fields. Current
first-party Channel Adapter setup schemas do not require generated webhook
tokens. Generated secrets cannot replace operator-provided app secrets, bot
tokens, OAuth client secrets, provider API keys, activation codes, or login
codes.

The source save flow is:

1. Normalize each enabled source draft for the selected adapter.
2. Run plugin-owned `connectivity_check/1` in the current request.
3. Let the plugin source setup module cast and serialize source config into the
   final binary persistence shape for its `BullX.Config` key.
4. Use plugin-owned persistence or `BullX.Config.put/2` to write the plugin
   source entries to the secret `eventbus_sources` key.
5. Call plugin-owned `reconcile_sources/0` or the equivalent runtime refresh
   boundary.
6. Reread plugin public source projection.
7. Advance to the AIAgent step only after at least one setup activation source
   is runtime ready.

`BullX.Config.put/2` guarantees the PostgreSQL commit for the source config key.
It accepts a binary key/value pair and does not cast plugin schemas for setup.
ETS refresh, plugin public projection refresh, and source runtime refresh are
post-commit readiness. If the commit succeeds but cache or runtime refresh
fails, setup shows stale-cache, restart-required, or runtime-not-ready state and
stays on the Channel source step.

Source runtime refresh is not EventBus core behavior. First-party plugins own
their source runtime supervisors and expose `reconcile_sources/0` or an
equivalent setup-callable boundary. If a plugin has no runtime refresh ability,
save may persist config, but the current request must return restart-required
or runtime-not-ready instead of advancing.

A plugin source runtime is ready when all of these facts are true:

- The source is enabled.
- Required source secrets are present and can decrypt.
- The adapter can establish or prepare inbound transport.
- Adapter-local `/preauth` is available on a safe surface.
- The source can hand addressed IM messages or command-shaped Events to
  `BullX.EventBus.accept/2`.
- The outbound reply path has enough safe `reply_channel` data for AIAgent
  replies or error prompts.

Feishu, Telegram, and Discord activation guidance must follow their plugin
docs. Public groups or channels must not display activation codes, login codes,
or OAuth state. When a user must enter a secret value, the adapter should prompt
the user to use DM, private chat, or provider-supported ephemeral UI.

### AIAgents

The AIAgent step ensures that at least one active Agent Principal exists. A
fresh Installation creates one ordinary Agent Principal by default. Setup does
not use hidden `setup-default-*` uids and does not make a particular Agent name
a system convention. Later ACL grants and Event Routing Rules use the Agent
Principal id.

Setup projection selects the initial AIAgent in this order:

1. Use the session-selected `agent_principal_id` when it still refers to an
   active Agent.
2. Use an active Agent whose profile has `setup.role = "initial_ai_agent"`.
3. If exactly one active Agent exists, use that Agent.
4. If multiple active Agents exist and none is marked, require explicit operator
   selection.

Repeated submit, refresh, or back navigation may update the selected Agent.
Projection selection controls form defaults only; it is not a new Principal
idempotency rule. Setup does not write `principals` or `agents` tables directly.

The AIAgent step captures these fields:

- Agent Principal selection, following the projection order for session-selected,
  setup-marked, sole active, or explicit operator-selected Agents.
- Principal `uid`, shown in setup as the AIAgent Bot Username with a visual
  `@` prefix but stored as the bare uid. The operator enters this value because
  it is the AIAgent's addressable identity, not a Channel Source id.
- Display name, bio, avatar, and other presentation fields.
- `agents.profile` JSON object.
- `agents.created_by_principal_id = nil`, because a fresh Installation has no
  Human Principal yet.

Setup-created or setup-updated profiles must use the `ai_agent` key. A
top-level non-runtime setup marker records the source of an initial Agent:

```json
{
  "ai_agent": {
    "main_llm": {
      "provider_id": "openai_proxy",
      "model": "gpt-4.1-mini",
      "reasoning_effort": "medium",
      "context_window": 1048576
    },
    "compression_llm": {
      "provider_id": "openai_proxy",
      "model": "gpt-4.1-mini",
      "reasoning_effort": "low",
      "context_window": 1048576
    },
    "heavy_llm": {
      "provider_id": "openai_proxy",
      "model": "gpt-4.1",
      "reasoning_effort": "high",
      "context_window": 1048576
    },
    "mission": "Track finance-related group discussions and answer or escalate within that work scope.",
    "soul": "<setup default soul prompt>",
    "instructions": "",
    "conversation_isolation_mode": "scene",
    "unmentioned_group_messages": "may_intervene",
    "acl": {
      "elevation_strategy": "deny"
    }
  },
  "setup": {
    "role": "initial_ai_agent"
  }
}
```

`BullX.AIAgent.Profile.cast/1` validates the `agents.profile["ai_agent"]`
object. The top-level `setup` marker is setup-owned metadata and is not consumed
by AIAgent runtime.

Setup derives each saved model config's `context_window` from model discovery
metadata when possible, then local model metadata. When no metadata is
available, setup shows the BullX runtime fallback of `80000` as placeholder
guidance rather than saving it as an explicit value. The operator may override
the value before save, which is important for local and OpenAI-compatible
providers whose practical context limit may be lower than public metadata.
`max_completion_tokens` is optional and normally omitted unless the operator
wants to force a provider output-token cap.

`main_llm` is required and must resolve through
`BullX.LLM.Catalog.resolve_model_config/1` before save. `compression_llm` and
`heavy_llm` may be omitted; `BullX.AIAgent.Profile` falls back to `main_llm`
with `low` and `high` reasoning defaults. When setup receives explicit
secondary configs, they must also resolve through the LLM catalog before save.
Setup does not write obsolete model field names.

`mission` is required and has no setup default. It is the initial AIAgent's
work function: the scope of work the digital colleague is responsible for and
the boundary within which it may observe, judge, and act proactively. `soul`
and `instructions` are optional personality and constraint-rule text. Setup
pre-fills `soul` with the built-in default prompt so the operator can edit it
in place. The default prompt is maintained by the backend harness boundary and
exposed to setup through backend props; because this value is prompt material,
not interface copy, it is not client i18n text. The setup UI labels
`instructions` as constraint rules because the field is durable guidance, not a
generic command line. These fields are not the full system-prompt schema.
AIAgent runtime owns how they become prompt material.

#### AIAgent ACL defaults

The AIAgent step first ensures that AuthZ built-in groups are available.

| Group key | UI label | Membership | Setup default use |
| --- | --- | --- | --- |
| `all_humans` | All humans | Dynamic membership for every active Human Principal. Disabled Humans and non-Human Principals are excluded. | Ordinary AIAgent access group. |
| `admin` | Admin | Static built-in group. Bootstrap `/preauth` handoff adds the first Human admin. | Privileged operation group. |

`all_humans` needs a `principal_groups` built-in row so permission grants can
reference it, but membership is not maintained through
`principal_group_memberships`. AuthZ appends `all_humans` when loading effective
groups for an active Human Principal, and `list_principal_groups/1` should also
return it as a dynamic member group. Public membership APIs cannot manually add
or remove a Principal from `all_humans`.

The AIAgent form includes:

- Ordinary access group, defaulting to `all_humans`.
- Privileged operation group, defaulting to `admin`.
- A preview of the ACL grants that setup will write.

The UI must make the derived ACL grants visible. Setup V1 does not expose
advanced CEL condition editing. All setup seed grants use condition `true`.
Setup ACL UI is not a generic AuthZ manager; it cannot create unrelated
resources, wildcard admin grants, arbitrary action grants, or bulk grants across
AIAgents.

Default grants are:

| Subject | Resource | Action | Condition | Reason |
| --- | --- | --- | --- | --- |
| group `all_humans` | `ai_agent:<agent_principal_id>` | `invoke` | `true` | Active Humans can have ordinary conversations, ordinary commands, and ordinary tool calls with the default AIAgent. |
| group `admin` | `ai_agent:<agent_principal_id>` | `invoke` | `true` | The privileged group also needs ordinary access. |
| group `admin` | `ai_agent:<agent_principal_id>` | `invoke_privileged` | `true` | Admins can perform operations that AIAgent runtime marks as privileged. |
| principal `<agent_principal_id>` | `ai_agent:<agent_principal_id>` | `invoke` | `true` | The default profile allows `may_intervene`, so the AIAgent needs self access for ambient handling. |

If ordinary and privileged groups are the same, setup writes only deduplicated
group grants. The self grant remains a separate Principal grant. All grants go
through `BullX.AuthZ.upsert_permission_grant/1`; setup does not write
`permission_grants` directly. AuthZ provides partial unique indexes for
idempotent upsert: `(principal_id, resource_pattern, action, condition)` when
`principal_id` is non-null and `(group_id, resource_pattern, action, condition)`
when `group_id` is non-null. Setup seed grants include non-secret metadata such
as `%{"created_by" => "setup", "setup_role" => "initial_ai_agent_acl"}`.
Metadata is not an authorization fact.

These grants are the minimum ACL for the first configured source's addressed DM
and group-chat path. The ACL rules are not Feishu-specific:

- `/preauth` activates the first Human Principal, AuthZ bootstrap handoff adds
  that Human to `admin`, and dynamic group lookup includes `all_humans`.
- When that Human sends an addressed private or group message through the
  configured source, the adapter resolves the channel actor binding, EventBus
  routes to the AIAgent, and AIAgent ACL checks `invoke`.
- When that Human triggers a privileged operation, AIAgent ACL checks `invoke`
  before `invoke_privileged`.
- If a source later normalizes unmentioned group messages as ambient input, the
  default AIAgent profile's `may_intervene` behavior needs the self grant.

The self grant shape is:

```text
principal_id = <agent_principal_id>
resource_pattern = "ai_agent:<agent_principal_id>"
action = "invoke"
condition = "true"
```

This grant only supports AIAgent ambient generation. It does not make
addressed-only sources produce ambient Events, and it does not grant cross
channel sending or external Capability access.

AIAgent visible replies through the current `reply_channel` do not need setup to
create generic `workspace_channel:*:write`, `channel:*:send`, or similar
grants. The base conversation reply is part of an authorized conversation
operation. Arbitrary outbound sending, cross-channel sending, high-risk external
actions, and Capability-owned side effects require later Capability or
Governance designs.

### Event Routing Rules

The Event Routing step creates one ordinary positive-priority database Event
Routing Rule so at least one source's BullX channel Events can reach the initial
AIAgent.
Defaults come from existing durable state: the setup-selected initial Agent
Principal and the first created runtime-ready Channel source. Channel source
projection must provide stable ordering. If plugin-owned source config has no
`created_at`, the source list save order defines "first."

This step is not a general Event Routing Rule editor. The UI shows the
server-derived source, Target, route name, match expression, scope fields,
priority, and validation result as a preview. The operator can save and verify
the setup-owned default route, go back to earlier setup steps, or handle a
routing conflict outside setup. The operator cannot edit CEL, priority, scope
fields, Target, fan-out behavior, or fallback behavior from this step.

Setup does not create code-owned system command routes, setup-only fallback
routes, or fan-out from one Event to many Targets.

The first default route is source-scoped and intentionally broad. It matches
BullX-normalized Events on the configured channel source rather than splitting
addressed IM, ambient IM, actions, and AIAgent-owned command Events into
separate setup routes. This lets source capabilities such as all-message
listening and card actions become reachable without adding another setup-owned
route. The route remains bounded by `channel.adapter` and `channel.id`, so it
does not become an Installation-wide catch-all.

The minimum route is a source-scoped BullX channel rule:

```elixir
%{
  name: "setup.default.<adapter_id>.<source_id>.channel",
  active: true,
  priority: 1000,
  match_expr:
    ~s(type.startsWith("bullx.") &&
       channel.adapter == "#{adapter_id}" &&
       channel.id == "#{source_id}"),
  target_type: :ai_agent,
  target_ref: agent_principal_id,
  scope_fields: ["channel.adapter", "channel.id", "scope.id", "scope.thread_id"]
}
```

`scope_fields` uses EventBus-supported `RoutingContext` field paths. The scope
keeps one DM, group, or thread on the same source in the same active
TargetSession lane, while different `scope.id` values remain separate. Idle
TargetSession close is controlled by EventBus runtime idle grace, not by setup
route configuration. The default idle grace is 30 minutes. AIAgent Conversation
and Message records carry long-term business facts; `/new` and daily reset close
Conversations, not TargetSessions.

Rule `name` is the durable idempotency key. Repeated saves use
`BullX.EventBus.RuleWriter.upsert_by_name/2` and never update by non-unique
display name.
The POST payload does not define route semantics; it only requests persistence
and live validation of the route derived from current setup state.

Setup-generated rule names use slug-safe adapter and source identifiers, or an
encoded slug when a plugin source id needs a wider character set for
`channel.id`. Adapter ids and source ids interpolated into `match_expr` must be
built through a shared CEL string-literal helper. Setup must not hand-concatenate
operator or plugin-provided values into CEL source.

Setup does not create separate AIAgent slash-command routes. AIAgent-owned text
slash commands are recognized by the AIAgent runtime after the command Event
reaches the setup AIAgent route, or after EventBus command fallback maps an
unmatched command Event onto the same channel route. This fallback is part of
the EventBus/AIAgent command contract, not a setup-owned hidden rule.
Current implicit system routes are only `/command` and `/status`: code-owned
negative-priority system command routes merged into the runtime `RoutingTable`
snapshot and not persisted in `event_routing_rules`.
`/preauth` remains adapter-local and does not enter EventBus routing.

When upgrading an older setup-generated split route, setup migrates
`setup.default.<adapter>.<source>.addressed` to the `.channel` rule and removes
setup-generated `.ambient` split routes for the same source. Re-running setup
must not leave both split routes and the broad channel route active.

`RuleWriter` owns changeset validation, name uniqueness, priority uniqueness,
CEL validation, and routing table refresh. Setup does not write
`event_routing_rules` directly or mutate the routing table in memory.

Priority selection is conservative:

- Database-owned priority is positive.
- Setup does not conflict with active or inactive database rows.
- Setup does not mix with code-owned negative system-command priority.
- A fresh Installation can start at priority `1000`.
- If rows already exist, setup chooses an unused positive priority or updates
  its own setup rule.
- V1 does not reorder non-setup rules.

Completion must prove that the route is live. The source setup module builds a
sample `RoutingContext` for the setup source. The current runtime
`RoutingTable` snapshot must first-match the setup rule and target the expected
AIAgent. A row that is active, positive priority, and points at the right Agent
is not enough, because a higher-priority wildcard, fallback, or Blackhole rule
could swallow the sample. In that case setup returns a routing conflict and lets
the operator handle existing rules. Setup does not reorder non-setup rules to
pass its own check.

### Activate admin

The completion page shows:

- A configured Channel Adapter source summary.
- The command template `/preauth <activation-code>`.
- `activation_code` plaintext, displayed by default.
- A copy button for either the complete command or the activation code.
- Polling path `/setup/activation/status`.
- A back link to the previous step.

`activation_code` comes from the current Phoenix session's
`:bootstrap_activation_code_plaintext`. `SetupActivationController.show/2`
passes it into Inertia props. React does not read plaintext from the database or
logs. Copy failure does not need extra feedback; the plaintext command remains
visible for manual copy.

The completion page cannot reissue an activation code. If session lacks
plaintext but the hash is still valid, the page tells the operator to reenter
the bootstrap code at the gate. It does not derive plaintext from the hash and
does not create a new code.

On mount, the page calls `/setup/activation/status` once, then polls every five
seconds. Temporary network errors only affect the current tick. The page keeps
the command and source summary visible so the operator can still complete
`/preauth` externally.

The operator sends this command on a safe surface of the configured source:

```text
/preauth <activation-code>
```

The adapter handles the local activation command and calls
`BullX.Principals.consume_activation_code/2`. When the consumed activation code
has `metadata.bootstrap = true`, AuthZ bootstrap handoff adds the activated
Human Principal to the built-in `admin` group. Because that Principal is an
active Human, AuthZ dynamic group lookup also includes `all_humans`.

Completion binds to `metadata.bootstrap = true`, not to "first user" order. Any
Human Principal created by consuming a bootstrap activation code is the handoff
subject.

`BullX.AuthZ.Bootstrap` also idempotently reconciles consumed bootstrap
activation codes at startup. This allows recovery from partial failures,
deployment restart, or manual repair.

After activation, the same external identity on the same source binds to the
Human Principal. The operator can continue in DM or use provider-supported
attention signals in group chat to talk to the same AIAgent. Setup completion
does not mean every group member is authorized. Only activated active Human
Principals pass the default `all_humans` ordinary access grant.

`GET /setup/activation/status` returns:

- `%{activated: false}` when the bootstrap code is not consumed.
- `%{activated: false, handoff: "pending", message: "admin membership handoff pending"}` when the code is consumed and a Human Principal exists, but AuthZ handoff is not ready.
- `%{activated: true, redirect_to: "/"}` when bootstrap admin handoff is
  complete.

The status action returns `activated: true` only when all of these checks pass:

- A consumed activation code with `metadata.bootstrap = true` exists.
- `used_by_principal_id` points to an active Human Principal.
- The built-in `admin` group exists.
- The Human Principal has static `admin` membership.
- The built-in `all_humans` dynamic group is available, and effective group
  lookup includes the active Human Principal.

When status returns `activated: true`, the controller deletes all setup session
keys, including hash, plaintext, and step.

## Failure behavior

Setup failures must preserve root-cause information for operators without
leaking secrets.

- Bootstrap code verification failure returns a gate-page error and does not
  reveal candidate count, hash, expiration time, or revocation reason.
- Invalid session hash deletes all setup session keys and redirects to
  `/setup/sessions/new`.
- Invalid plugin ids return validation errors and do not write
  `bullx.enabled_plugins`.
- Successful plugin enablement write with stale runtime registry shows the
  Plugins step pending-restart banner and does not advance.
- Missing enabled plugin extensions after restart sends setup back to Plugins
  with diagnostics.
- JSON operations return `401 + redirect_to` for invalid session and
  `409 + redirect_to` after setup completion; the client must not show those as
  ordinary field errors.
- LLM provider check failure returns field errors or a redacted provider error.
  It does not log prompt, API key, or raw provider response.
- LLM provider write failure returns changeset or tagged errors. If post-commit
  cache refresh is stale, setup shows a warning. If the runtime catalog cannot
  resolve the saved provider, the step remains incomplete.
- Channel source check failure returns plugin-owned safe errors and does not
  leak tokens, secrets, OAuth codes, raw provider payloads, or private
  interaction values.
- Enabled Channel source save must run connectivity check in the same request.
  Check failure returns current-step field or operation errors and cannot rely
  on an earlier successful check.
- Unsupported generated-secret fields return `422` and do not generate a
  fallback secret.
- Successful Channel source save with non-ready plugin source runtime cannot
  advance. It returns restart-required, runtime-not-ready, or plugin-owned
  diagnostics.
- AIAgent profile save validates with `BullX.AIAgent.Profile.cast/1` and model
  spec resolution. Failure returns field-level JSON errors.
- Missing or conflicting `admin` or `all_humans` built-in groups make the
  AIAgent step incomplete.
- Required AIAgent ACL grant seed failure may leave the Agent record in place,
  but the step remains incomplete and shows a diagnostic error.
- Event Routing Rule save failure returns `RuleWriter` changeset or routing
  table refresh errors. Refresh failure means the rule is not considered live.
- Completion page without activation code plaintext must ask the operator to
  reenter the bootstrap code. It cannot show a hash or reissue a code.
- `/preauth` success with AuthZ handoff failure preserves Principal activation
  and reports admin handoff failure. `BullX.AuthZ.Bootstrap` should reconcile
  later. Setup activation status reports handoff pending until ready.

No log, telemetry event, JSON error, dead letter, adapter receipt, or browser
projection may contain provider secrets, bot tokens, OAuth tokens, API keys,
activation code hash, login auth code hash, raw provider callback body, private
profile payload, or full Event payloads. Activation code plaintext may appear
only in the encrypted Phoenix cookie session, the completion-page Inertia prop,
and the bootstrap worker's one-time log.

## Implementation

### Goal

Implement a fresh Installation setup wizard. An operator enters the bootstrap
code, configures first-party Channel Adapter plugin/source, configures an LLM
provider, creates or selects an AIAgent, writes visible AIAgent ACL grants,
creates Event Routing Rules, and activates the first Human admin through
external `/preauth`. Feishu source is the required first-party acceptance path.
After completion, the activated Human Principal can have multi-turn
conversations with the setup-selected AIAgent through addressed DM and group
chat surfaces on the first configured source.

### Context pointers

- `AGENTS.md`
- `internals/design-docs/drafts/Arch.md`
- `docs/Architecture.md`
- `docs/design-docs/Configuration.md`
- `docs/design-docs/Plugins.md`
- `docs/design-docs/LLMProvider.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/AuthZ.md`
- `docs/design-docs/eventbus/Core.md`
- `docs/design-docs/eventbus/Matcher.md`
- `docs/design-docs/eventbus/Persistence.md`
- `docs/design-docs/eventbus/ChannelAdapter.md`
- `docs/design-docs/eventbus/CommandTarget.md`
- `docs/design-docs/eventbus/SystemCommands.md`
- `docs/design-docs/ai-agent/Core.md`
- `docs/design-docs/ai-agent/ACL.md`
- `docs/design-docs/ai-agent/SlashCommands.md`
- `docs/design-docs/plugins/FeishuAdapter.md`
- `docs/design-docs/plugins/TelegramAdapter.md`
- `docs/design-docs/plugins/DiscordAdapter.md`
- `lib/bullx_web/router.ex`
- `lib/bullx_web/controllers/setup_controller.ex`
- `webui/src/apps/setup/`
- `lib/bullx/principals.ex`
- `lib/bullx/authz.ex`
- `lib/bullx/llm/`
- `lib/bullx/plugins/`
- `lib/bullx/event_bus/rule_writer.ex`
- `lib/bullx/event_bus/event_routing_rule.ex`
- `lib/bullx/ai_agent/profile.ex`

### Constraints

- Do not add setup-owned business tables.
- Do not add a central Channel Adapter source table or central source config
  key.
- Do not bypass `BullX.Config` for plugin enablement, plugin source config, or
  i18n config.
- Do not write provider secrets, bot tokens, OAuth client secrets, or API keys
  to source public config, session, Inertia props, logs, or telemetry.
  Activation code plaintext follows only the completion-page rules in this
  design.
- Do not make plugin enablement hot reload.
- Do not make the LLM provider catalog own AIAgent model selection.
- Do not make Channel Adapters own routing, Principal ownership, AuthZ, AIAgent
  ACL, or business persistence.
- Do not write Principal, AuthZ, EventBus, or AIAgent internal tables directly.
- Do not implement `all_humans` as a setup-local allowlist.
- Do not hide setup seed AIAgent ACL grants from the UI.
- Do not move source runtime supervision out of the plugin failure boundary.
- Do not create implicit EventBus fallback, fan-out routes, or all-target
  broadcast.
- Use step-level Inertia MPA, existing UIKit, approved `react-hook-form`,
  approved `@tanstack/react-query`, and existing `json-edit-react`. Do not add
  further frontend state, form, validation, routing, request, or component
  libraries without explicit approval.
- Plugin enablement takes effect only after application restart. Setup does not
  provide automatic restart and does not call `System.stop/0`.

### Tasks

1. Implement setup gate.

   Owns: router, `SetupController`, `SetupSessionController`, session helpers,
   and controller tests.

   Acceptance: `BullX.Principals.verify_bootstrap_activation_code_for_setup/1`
   atomically verifies and marks `metadata.setup_gate_verified_at`; a valid
   bootstrap code stores hash and plaintext session keys; an invalid code writes
   no session; consumed codes enter activation-status projection; expired or
   revoked codes invalidate session; bootstrap worker does not rotate or extend
   unexpired setup-in-progress codes, but can refresh an expired
   setup-in-progress code and print the new plaintext once.

2. Implement setup progress projection.

   Owns: setup context module.

   Acceptance: `GET /setup` clamps session step to the earliest incomplete
   prerequisite and redirects to the canonical step route; back navigation only
   changes session.

3. Implement Plugins step.

   Owns: `SetupPluginsController` and Web UI step.

   Acceptance: valid plugin ids write desired `bullx.enabled_plugins` through an
   Inertia form action; when persisted ids differ from current runtime enabled
   ids, Plugins shows a persistent pending-restart banner and does not advance;
   after operator restart, enabled extensions are visible before continuing.

4. Implement LLM providers step.

   Owns: setup LLM context, controller, and Web UI.

   Acceptance: create/update provider endpoints through `BullX.LLM.Writer` via
   Inertia form; check action can ping with request-local `test_model_id`
   through JSON; saved secrets render only as masked status; no model alias or
   concrete model id is stored in provider rows; missing form rows do not delete
   providers; setup V1 has no persisted provider delete UI.

5. Implement Channel Adapter sources step.

   Owns: setup channel source context, controller, Web UI, and first-party
   plugin source setup integration.

   Acceptance: setup discovers source setup modules from enabled Channel Adapter
   extension `opts.setup_module`; Feishu, Telegram, and Discord implement the
   V1 required setup module and restricted `form_schema/0`; plugin-owned
   `eventbus_sources` are cast and serialized by the plugin setup module before
   writing binary key/value entries through `BullX.Config.put/2` or
   plugin-owned persistence via
   Inertia form; generated secrets work only for plugin-declared fields and
   display through a masked/plain toggle component; enabled sources run
   connectivity check in the same save request; source runtime refresh calls
   plugin-owned `reconcile_sources/0` or equivalent; at least one setup
   activation source is runtime ready before continuing.

6. Implement AIAgents step.

   Owns: setup AIAgent context, controller, and Web UI.

   Acceptance: create or update an active Agent Principal through the Principal
   facade without a fixed setup uid; projection reuses a session-selected or
   setup-marked active Agent, uses the sole active Agent when exactly one
   exists, and requires explicit selection when multiple unmarked active Agents
   exist; store valid `agents.profile["ai_agent"]` and optional non-runtime
   setup marker; `main_llm` stores a resolvable model config object; default
   profile uses
   `unmentioned_group_messages = "may_intervene"` and a user-entered required
   `mission`; UI shows ordinary access group, privileged operation group, and
   derived ACL grants; default ordinary
   group is `all_humans`; default privileged group is `admin`; setup V1 does not
   expose advanced CEL conditions; AuthZ writes setup metadata grants for
   `all_humans -> invoke`, `admin -> invoke`, `admin -> invoke_privileged`, and
   AIAgent self `invoke`.

7. Implement Event Routing step.

   Owns: setup EventBus routing context, controller, and Web UI.

   Acceptance: use `RuleWriter.upsert_by_name/2` to create or update at least
   one active positive-priority source-scoped BullX channel Event Routing Rule
   named `setup.default.<adapter>.<source_id>.channel`; the rule uses
   `target_type = "ai_agent"` and `target_ref = <agent principal id>` for the
   first runtime-ready setup source; the Web UI presents this route as a
   non-editable preview with save-and-verify action, not as a CEL, priority,
   scope, Target, fan-out, or fallback editor; POST ignores operator-submitted
   route semantics and derives route attrs from current setup state; setup does
   not create AIAgent slash-command routes; code-owned system command routes
   keep negative priority and win before the setup AIAgent route; rule names use
   slug-safe or encoded source identifiers, and `match_expr` is built through a
   shared CEL string-literal helper; runtime first-match preview for the setup
   source sample `RoutingContext` hits the setup rule; an existing non-setup rule
   that swallows the sample returns routing conflict instead of being reordered;
   no setup-only routing fallback exists; routing table refresh succeeds.

8. Implement Activate admin step.

   Owns: completion Inertia props, activation status route, and session cleanup.

   Acceptance: completion page receives plaintext activation code prop from the
   encrypted, signed, HttpOnly Phoenix cookie session, shows it plaintext by
   default with a copy button, polls activation status through JSON/React Query,
   reports admin handoff pending when needed, and redirects only after bootstrap
   code consumption plus AuthZ admin and `all_humans` readiness.

9. Align AuthZ built-in groups and bootstrap handoff.

   Owns: Principal activation call path only if current code/doc is stale;
   otherwise tests and docs.

   Acceptance: AuthZ creates built-in `admin` and `all_humans` groups
   idempotently; active Human Principals effectively belong to `all_humans`
   without persisted membership rows; consuming an activation code with
   `metadata.bootstrap = true` grants or reconciles built-in `admin` group
   membership for the activated Human Principal.

10. Add i18n, tests, and documentation coverage.

    Owns: locale files, controller tests, context tests, and frontend tests where
    practical.

    Acceptance: errors are localized or stable enough for UI, and
    `bun precommit` passes.

### Done when

- A fresh Installation logs one bootstrap activation code, accepts it at
  `/setup/sessions/new`, and renders setup.
- The Plugins step writes desired `bullx.enabled_plugins`; plugin-dependent
  steps run only after operator restart makes runtime enabled registry match
  persisted config.
- The LLM step stores at least one provider endpoint without model alias or
  model id.
- LLM check validates a provider draft without persisting a model id.
- The Channel source step stores at least one enabled runtime-ready plugin
  source with no inline secret, using same-request check and save.
- Channel source save calls plugin-owned source runtime refresh or returns
  restart-required/runtime-not-ready instead of pretending `/preauth` is live.
- The AIAgent step stores at least one active Agent Principal with a valid
  `ai_agent` profile.
- The built-in `all_humans` group exists as an AuthZ dynamic group for active
  Human Principals.
- Setup UI shows the AIAgent ordinary access group and privileged operation
  group, defaulting to `all_humans` and `admin`.
- Required AIAgent ACL grants exist: ordinary access group has `invoke`;
  privileged group has both `invoke` and `invoke_privileged`; the AIAgent
  Principal has self `invoke`.
- The Event Routing step upserts at least one positive-priority
  `target_type = "ai_agent"` source-scoped BullX channel rule named
  `setup.default.<adapter>.<source_id>.channel` for the first runtime-ready
  setup source, shows it as a non-editable default-route preview, and runtime
  first-match preview reaches it.
- The completion page displays `/preauth <activation-code>` using
  server-provided Inertia props.
- The completion page shows the activation command plaintext by default and
  provides a copy button without making copy failure a blocking error.
- `/preauth` consumes the bootstrap code, creates the Human Principal according
  to Principal design, and AuthZ handoff adds that Human Principal to the
  built-in `admin` group because the consumed code has `metadata.bootstrap =
  true`.
- The activated bootstrap admin can send addressed messages to the bot in the
  configured source's DM and group surfaces; both paths reach the setup-selected
  AIAgent as the same Human Principal.
- Activation status polling clears setup session and redirects to `/` only after
  AuthZ bootstrap admin handoff is complete.
- `bun precommit` passes, or the skipped command and reason are documented.

### Stop and ask

Implementation must stop and ask before any of these changes:

- Add setup-owned database tables.
- Add a central Channel Adapter source table or central source config key.
- Make EventBus own plugin source config schemas, connectivity checks, setup UI
  projections, or listener supervision.
- Change plugin enablement away from restart-after-save semantics.
- Add automatic restart, `System.stop/0`, restart trigger modes, or a separate
  restart-required page for plugin enablement.
- Store activation code plaintext outside the encrypted Phoenix cookie session,
  final Inertia prop, and bootstrap worker one-time log.
- Turn LLM provider setup into model alias or default model management.
- Add persisted provider deletion to setup V1, or implement provider deletion
  as save-list absence instead of an explicit delete action with reference
  checks.
- Create implicit routing fallback, EventBus fan-out, or all-target broadcast.
- Grant admin based on "first user" rather than a consumed activation code with
  `metadata.bootstrap = true`.
- Replace `all_humans` dynamic group with a setup-local allowlist or
  channel-specific audience rule.
- Hide AIAgent ACL grants in setup UI or write them as invisible seed data.
- Seed wildcard admin permissions, cross-AIAgent wildcard grants, or unrelated
  AuthZ grants to make the first setup path pass.
- Treat `invoke_privileged` as enough permission without also granting
  `invoke`.
- Add generic channel send grants for the AIAgent reply path instead of using
  the current Event's `reply_channel`.
- Add provider-specific persistence tables or raw provider payload retention to
  make setup easier.
- Expand plugin `form_schema/0` beyond the V1 restricted field descriptor
  contract into a broad setup-owned DSL.
- Replace `json-edit-react` with RJSF, `react-jsonschema-form`, or another JSON
  editor without a separately approved stable-schema use case.
- Add frontend libraries beyond approved `react-hook-form`, approved
  `@tanstack/react-query`, existing `json-edit-react`, existing Inertia, and
  existing UIKit.
