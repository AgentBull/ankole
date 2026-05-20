# LLM provider catalog

BullX uses `req_llm` for provider adapters and stores BullX-specific endpoint
configuration in PostgreSQL. `BullX.LLM` is BullX's `req_llm` catalog,
credential, runtime-settings, and provider-registration boundary. It resolves an
LLM spec string such as `"openai_proxy:gpt-4.1-mini"` into a BullX provider row
and a model id. The Workflow Node, AIAgent, or other caller design that selects
a model owns where the spec string is stored.

LLM access is a model Capability that AIAgents, Workflow Nodes, and other
authorized callers may call. `BullX.LLM` does not define AIAgent identity,
Workflow execution, TargetSession behavior, or a separate subsystem pillar. An
AIAgent implementation may use `BullX.LLM`, but the LLM provider catalog remains
the lower-level Capability support layer.

This design covers only the provider catalog, encrypted-at-rest API keys,
selected `req_llm` runtime settings, and custom provider registration. It does
not define model aliases, setup UI, or any AIAgent runtime boundary.

## Goals

- Store manageable LLM endpoint configurations in `llm_providers`.
- Encrypt API keys at rest in PostgreSQL.
- Parse and resolve LLM specs in the form `"provider_id:model_id"`.
- Provide a reconstructible runtime cache and public resolution API.
- Bridge selected `req_llm` call-time `Application` settings through
  `BullX.Config`.
- Ship BullX-owned `req_llm` provider overrides where BullX needs behavior that
  differs from upstream `req_llm`.
- Let enabled BullX plugins register custom `req_llm` provider modules.

## Non-goals

- This provider catalog does not define where Workflow definitions, Workflow
  Nodes, AIAgents, or other callers store model selections.
- This provider catalog does not define AIAgent identity, AIAgent runtime,
  Agentic Loop behavior, prompt orchestration, tool execution, memory,
  Governance, Capability execution, or Work planning.
- This provider catalog does not own model aliases, weighted routing, failover,
  usage accounting, cost limits, quotas, or model catalog tables. Those decisions
  belong to Workflow Node, AIAgent, or Budget and Governance designs.
- BullX does not add a management UI or setup wizard in this design.
- BullX does not support `BULLX_SECRET_BASE` rotation for encrypted provider
  API keys.
- BullX does not create a BEAM memory secrecy boundary. Plaintext API keys can
  exist in process memory and per-request options. The provider catalog cache
  stores encrypted provider rows through `BullX.Cache`; BullX only guarantees
  that it does not store plaintext API keys in PostgreSQL, `app_configs`, logs,
  telemetry metadata, or changeset errors.
- BullX does not hot-enable or hot-disable plugins. Plugin enablement follows
  `docs/design-docs/Plugins.md` and takes effect after restart.

## Existing system

`docs/design-docs/Configuration.md` defines runtime configuration through
`BullX.Config`, backed by PostgreSQL, ETS, OS environment, application config,
and code defaults. This design reuses that layer for selected global `req_llm`
call-time settings.

`docs/design-docs/Plugins.md` defines trusted compile-time plugins with typed
extension declarations. This design lets enabled plugins contribute custom
`req_llm` provider modules through the plugin registry.

`req_llm` initializes its provider registry during the `:req_llm` application
start and exposes `ReqLLM.Providers.register/1`. BullX uses the runtime
registration API because BullX plugin discovery runs after `:req_llm` has
already started.

## Domain model

BullX separates three concepts that are easy to confuse:

- **BullX provider:** one row in `llm_providers`. It represents an endpoint and
  its static authentication/configuration.
- **req_llm provider:** a `req_llm` adapter id such as `:openai`,
  `:anthropic`, or a plugin-provided id. A single adapter can back many BullX
  provider rows.
- **Model config:** a caller-owned object with `provider_id`, `model`,
  `reasoning_effort`, `context_window`, and an optional
  `max_completion_tokens`. The `provider_id` points to a BullX provider row. The
  `model` value is passed to `req_llm` as the provider model id.
- **LLM spec:** a lower-level string form, `"provider_id:model_id"`, kept for
  direct catalog resolution and tests. AIAgent profiles store model configs, not
  LLM spec strings.

A BullX provider row contains:

- `provider_id`, a stable human-chosen string handle. It is unique and is not
  renamed in place. Create a new provider and migrate external references
  instead.
- `req_llm_provider`, the `req_llm` adapter id as a string, such as `"openai"`
  or `"anthropic"`.
- `base_url`, an optional endpoint override.
- `api_key`, an optional secret. Non-empty values are stored only as ciphertext
  in PostgreSQL.
- `provider_options`, a JSON object for static provider-specific settings such
  as region, provider mode, OAuth file, or GCP project.

An LLM spec selects a model through a provider:

```text
openai_proxy:gpt-4.1-mini
```

The parser splits on the first colon only. `provider_id` must match the same
format used by `llm_providers.provider_id`. `model_id` must be a non-empty
string and may contain additional colons.

Resolving an LLM spec returns a `ResolvedModel`:

```elixir
%BullX.LLM.ResolvedModel{
  provider_id: "openai_proxy",
  model_id: "gpt-4.1-mini",
  req_llm_provider: :openai,
  model_input: %{
    provider: :openai,
    id: "gpt-4.1-mini",
    base_url: "https://proxy.example.com/v1"
  },
  opts: [
    api_key: "sk-...",
    provider_options: [auth_mode: :api_key]
  ]
}
```

Callers pass `model_input` and `opts` to `req_llm`. If `base_url` is nil, the
resolver omits it and lets `req_llm` use its provider metadata or default.
A model config resolves through the same provider row and returns the same
`ResolvedModel`; its generation controls are merged into call options by
`BullX.LLM`, not stored on the provider row.

Model configs use this shape:

```json
{
  "provider_id": "openai_proxy",
  "model": "gpt-4.1-mini",
  "reasoning_effort": "medium",
  "context_window": 1048576,
  "max_completion_tokens": 32768
}
```

`reasoning_effort` is normalized to one of `none`, `minimal`, `low`, `medium`,
`high`, or `xhigh`. `context_window` is the effective input context budget used
by AIAgent history budgeting and compression decisions. Setup derives it from
dynamic provider metadata when available, then local model metadata when
available, and otherwise falls back to `80000`. Operators may override this
value, especially for local or OpenAI-compatible deployments where the served
model or available memory differs from public metadata.

`max_completion_tokens` is only an optional output limit override. When it is
omitted, BullX does not pass a max-output token override and lets the provider or
adapter default apply.

## Data model

`llm_providers` is the only new table.

| Column | Type | Constraint |
| --- | --- | --- |
| `id` | `uuid` | Primary key. The writer pre-generates it with `BullX.Ext.gen_uuid_v7/0`; the schema uses `BullX.Ecto.UUIDv7`. |
| `provider_id` | `text` | Required, unique, matches `^[a-z][a-z0-9_-]{0,62}$`. |
| `req_llm_provider` | `text` | Required. Stores the adapter id without the leading `:`. |
| `base_url` | `text` | Nullable. |
| `encrypted_api_key` | `text` | Nullable. Stores `"<base64url(nonce)>.<base64url(ciphertext+tag)>".` |
| `provider_options` | `jsonb` | Required, defaults to `{}`, and must be a JSON object. |
| `inserted_at` / `updated_at` | `utc_datetime_usec` | Required. |

The database uses a unique index on `provider_id`.

The database does not use PostgreSQL enums for `req_llm_provider` or `model_id`.
Provider adapters and model ids change too quickly for closed database enums.
The write and resolution layers validate adapter availability against the
current `req_llm` registry.

The database does not store `model_id` in `llm_providers`. One endpoint can
serve many models, and storing model ids in the provider row would force one
row per endpoint/model pair.

The database does not enforce relationships from caller-owned model selections
to `llm_providers`. Runtime resolution returns `{:error, :not_found}` when an
LLM spec points to a deleted provider.

## Local model registry

BullX treats saved `llm_providers` rows as the local provider registry. Model
discovery is an enhancement of those local rows, not a separate global truth
source.

`BullX.LLM.ModelRegistry` lists model descriptors for one saved provider row:

```json
{
  "provider_id": "openrouter_default",
  "model": "openai/gpt-4.1-mini",
  "label": "GPT-4.1 Mini",
  "context_window": 1048576,
  "fallback_context_window": 80000,
  "max_completion_tokens": 32768,
  "reasoning": {
    "efforts": ["none", "minimal", "low", "medium", "high", "xhigh"]
  },
  "source": "dynamic"
}
```

Provider modules may expose `list_models/1`. OpenRouter uses `GET /models` and
maps `context_length` plus provider output-token metadata into descriptors.
OpenAI and OpenAI-compatible adapters use `/models` for dynamic ids and enrich
known models with local `LLMDB` metadata. Anthropic uses `/v1/models` and also
enriches known models with local metadata. Google Gemini uses `/models` and maps
`inputTokenLimit` and `outputTokenLimit`. If dynamic discovery fails, the
registry falls back to local metadata so setup remains usable offline. If neither
dynamic nor local metadata provides a context window, `context_window` is absent
or null and `fallback_context_window` carries the BullX runtime fallback of
`80000`. The setup UI should show that fallback as placeholder guidance, not as
a saved value, and still let the operator override the saved value.

The descriptor intentionally has no per-model tool-capability flag. BullX only
exposes chat/agent models that can satisfy the agent contract. A model that
cannot support tool-capable agent calls is outside the supported model set
rather than a selectable model with a disabled capability bit.

## API key storage

API keys are encrypted before insert or update. BullX reuses the existing AEAD
NIF helpers with a separate key namespace:

```elixir
BullX.Ext.derive_key(
  BullX.Config.Secrets.secret_base!(),
  "llm_providers/" <> row_id,
  "api_key"
)
```

`row_id` is the internal UUID primary key, not `provider_id`. This keeps the
encryption key independent from a human-facing handle. The insert write path must
pre-generate the row UUID before encrypting `api_key`; relying on Ecto
autogeneration after changeset construction would leave the encryption path
without the row-specific key input.

The ciphertext uses `BullX.Ext.aead_encrypt/2`, which produces the storage
shape already used by `BullX.Config.Crypto`: a base64url nonce and ciphertext
separated by `.`. Decryption uses `BullX.Ext.aead_decrypt/2`.

If ciphertext cannot decrypt, provider resolution returns
`{:error, {:decrypt_failed, provider_id}}`. BullX must not silently call the
provider without the API key.

## Runtime shape

`BullX.LLM.Catalog` is the public read API. It uses
`BullX.LLM.Catalog.Cache`, a process started under `BullX.Runtime.Supervisor`
that stores its reconstructible provider list through `BullX.Cache`. The design
does not introduce an AIAgent runtime supervisor or AIAgent failure boundary
because a provider catalog is not an AIAgent runtime.

The cache loads `llm_providers` at startup and can rebuild itself from
PostgreSQL after restart. It caches the sorted provider list under one
domain-prefixed key (`"llm:providers"`) instead of one key per provider because
`BullX.Cache` intentionally does not expose pattern deletion. Writer refreshes
therefore reload the full list, which keeps provider deletion semantics
identical in the Redis primary path and local ETS fallback path. If the table
does not exist yet, cache startup logs a warning and starts with an empty list,
matching the tolerance used by `BullX.Config.Cache` during pre-migration boot.

The public API owns these operations:

```elixir
BullX.LLM.Spec.parse(spec)
BullX.LLM.Spec.parse!(spec)

BullX.LLM.Catalog.list_providers()
BullX.LLM.Catalog.find_provider(provider_id)
BullX.LLM.Catalog.resolve_provider(provider_id)
BullX.LLM.Catalog.resolve_model_spec(spec)
BullX.LLM.Catalog.resolve_model_spec!(spec)
BullX.LLM.Catalog.resolve_model_config(config)

BullX.LLM.ModelRegistry.list_provider_models(provider_id)
BullX.LLM.ModelRegistry.public_models(provider_id)
BullX.LLM.ModelRegistry.public_provider_models()

BullX.LLM.Writer.put_provider(attrs)
BullX.LLM.Writer.update_provider(provider_id, attrs)
BullX.LLM.Writer.delete_provider(provider_id)
BullX.LLM.Writer.refresh_provider(provider_id)
```

`resolve_provider/1` returns the endpoint configuration without a model id.
`resolve_model_spec/1` parses a string such as
`"openai_proxy:gpt-4.1-mini"`, looks up the provider row, and returns
`ResolvedModel`. `resolve_model_config/1` resolves the canonical model config
object used by AIAgent profiles.

Writer operations commit PostgreSQL changes first and refresh the cache after
the transaction succeeds. A post-commit cache refresh failure is not reported as
a write error because PostgreSQL may already contain the committed change.
Instead, the writer returns a persisted-but-stale success:

```elixir
{:ok, provider,
 {:persisted_but_stale, {:cache_refresh_failed, provider_id, reason}}}

{:ok,
 {:persisted_but_stale, {:cache_refresh_failed, provider_id, reason}}}
```

The first shape is used for put and update; the second is used for delete.
PostgreSQL remains the source of truth, and retrying `refresh_provider/1` or
restarting the cache restores consistency. A direct `refresh_provider/1` failure
still returns `{:error, {:cache_refresh_failed, provider_id, reason}}` because no
new database write happened in that call.

## Provider options

`provider_options` stores static provider-specific options as JSON. During
resolution, BullX converts string keys to atoms only after checking the active
provider module's `provider_schema/0`. Unknown keys return
`{:error, {:invalid_provider_options, provider_id, reason}}`.

The field must not hold call-specific generation parameters. Those parameters
belong to the Workflow Node or AIAgent execution that makes the model call
because different Workflow branches, Workflow Node contracts, and AIAgent prompt
assembly may need different generation behavior against the same endpoint.

Examples of acceptable `provider_options` include provider region, project id,
or a provider-specific mode flag when the corresponding `req_llm` provider
schema accepts that option.

## req_llm application settings

`BullX.Config.ReqLLM` bridges selected `req_llm` settings that `req_llm` reads
at call time. The bridge must not write BullX defaults that accidentally change
upstream provider defaults. A nil BullX value means "leave `req_llm`
`Application` env unset."

The initial bridge covers:

| BullX accessor | Database key | req_llm key |
| --- | --- | --- |
| `receive_timeout_ms/0` | `bullx.req_llm.receive_timeout_ms` | `:receive_timeout` |
| `metadata_timeout_ms/0` | `bullx.req_llm.metadata_timeout_ms` | `:metadata_timeout` |
| `stream_completion_cleanup_after_ms/0` | `bullx.req_llm.stream_completion_cleanup_after_ms` | `:stream_completion_cleanup_after` |
| `debug/0` | `bullx.req_llm.debug` | `:debug` |
| `redact_context/0` | `bullx.req_llm.redact_context` | `:redact_context` |

`BullX.Config.ReqLLM.BootSync` runs after `BullX.Config.Cache` starts and
before `BullX.Runtime.Supervisor` starts. It syncs configured non-nil values
into `Application.put_env(:req_llm, key, value)` and deletes the `req_llm` key
when the BullX value is nil.

`BullX.Config.Writer` triggers the same bridge for writes and deletes under the
`bullx.req_llm.` key prefix. The bridge reloads the small fixed keyspec instead
of maintaining per-key incremental logic.

These `req_llm` settings are not bridged:

- `:load_dotenv`, because BullX bootstrap owns dotenv loading and configures
  `req_llm` with `load_dotenv: false` in `config/config.exs`.
- `:custom_providers`, because BullX registers plugin providers through
  `ReqLLM.Providers.register/1`.
- Provider API key settings such as `:anthropic_api_key`, because provider rows
  own API keys.
- `:finch` and other startup-time settings, because `:req_llm` starts before
  BullX runtime configuration is available.
- `:finch_request_adapter`, because it is test-only and tests can set it
  directly.

## Built-in provider overrides

BullX owns a small built-in provider registration pass that runs before plugin
provider registration. BullX-owned provider modules are registered with
`override: true` for the req_llm provider ids BullX needs to keep locally
controllable:

- `:openai`
- `:anthropic`
- `:google`
- `:google_vertex`
- `:vllm`
- `:mistral`
- `:azure`
- `:amazon_bedrock`
- `:deepseek`
- `:zai`
- `:xai`
- `:openrouter`

The BullX-owned modules are synchronized from the corresponding `req_llm`
provider modules and keep the same provider ids. They may still delegate to
`req_llm` internal helper or formatter modules; the durable contract is the
provider id, schema, and callback behavior exposed through the req_llm provider
registry.

Provider option schemas are BullX-owned declarations. They must not be produced
by importing an upstream `ReqLLM.Providers.*.provider_schema/0` result and
patching it at runtime. BullX may intentionally remove or hide req_llm options;
unknown provider options are rejected during catalog resolution and therefore
cannot be persisted as supported configuration.

The setup provider catalog is derived from these BullX declarations plus enabled
plugin declarations, not from `ReqLLM.Providers.list/0`. Raw providers registered
by `req_llm` remain implementation detail until BullX declares or enables them.
Each setup catalog entry carries an i18n label key in the form
`setup.llm.providers.<provider_id>`; the provider id remains the stable stored
value.

The OpenRouter module keeps the upstream `req_llm` provider id so existing
`req_llm_provider: "openrouter"` rows continue to resolve. It delegates the
OpenRouter-compatible request and response behavior to `req_llm` and narrows
BullX-specific behavior to the parts BullX needs to control:

- keep setup-visible provider options locally curated;
- encode call-level `reasoning_effort` as OpenRouter's unified `reasoning`
  request object;
- translate call-level `reasoning_token_budget` into `reasoning.max_tokens`;
- preserve OpenRouter app attribution headers.

The override is runtime registry state, not durable truth. Restarting BullX
rebuilds it before resolving provider rows.

## Plugin provider registration

Custom `req_llm` provider modules use the BullX plugin extension point named
`:"bullx.llm.req_llm_provider"`.

Each extension declaration contains:

- `id`, the provider id string, such as `"my_provider"`.
- `module`, a module that implements `ReqLLM.Provider`.
- `opts`, optional metadata. `override: true` is the only option with behavior
  in this design.

After `BullX.Plugins.Supervisor` starts, a runtime sync child first registers
BullX built-in provider overrides and then asks
`BullX.Plugins.Registry.enabled_extensions_for(:"bullx.llm.req_llm_provider")`
for enabled declarations. For each declaration, BullX validates that the module
implements `ReqLLM.Provider`, calls `ReqLLM.Providers.register(module)`, and
checks that the registered provider id matches the extension `id`.

Provider ids must be unique across plugin declarations because
`BullX.Plugins.Registry` rejects duplicate `{point, id}` pairs. A plugin can add
new providers by declaring ids that are not already present in
`ReqLLM.Providers.list/0`.

A plugin can intentionally replace a provider that `req_llm` already registered.
Replacement is allowed only when the extension declares
`opts: [override: true]`. Without that option, an enabled plugin declaration
whose `id` is already present in the `req_llm` registry fails startup with
`{:req_llm_provider_already_registered, id}`. With `override: true`, BullX calls
`ReqLLM.Providers.register(module)`, which replaces the registry entry for that
provider id in the current runtime. Restarting without the plugin restores the
base `req_llm` registry.

The first plugin using this hook is `chinese_llm_providers_extra`. It declares
four provider ids:

- `xiaomi_mimo`, implemented by
  `ChineseLLMProvidersExtra.Providers.XiaomiMiMo`, delegates to the Anthropic
  provider while selecting the correct Xiaomi MiMo billing-plan endpoint.
- `volcengine_ark`, implemented by
  `ChineseLLMProvidersExtra.Providers.VolcengineArk`, uses the OpenAI-compatible
  default provider behavior with Ark's default base URL.
- `alibaba_cn`, implemented by
  `ChineseLLMProvidersExtra.Providers.AlibabaCN`, mirrors req_llm's DashScope
  mainland China endpoint provider.
- `zai_coding_plan`, implemented by
  `ChineseLLMProvidersExtra.Providers.ZaiCodingPlan`, mirrors req_llm's Z.AI
  coding endpoint provider.

The same hook can still support deliberate provider replacement when a plugin
marks that declaration with `override: true`.

Only enabled plugins register providers. If a plugin is disabled and BullX
restarts, rows that reference the plugin's provider remain in PostgreSQL, but
resolution returns `{:error, {:unknown_req_llm_provider, req_llm_provider}}`
until an operator re-enables the plugin or migrates the rows.

## Error and failure behavior

- Invalid provider writes return an Ecto changeset or a tagged error and do not
  write PostgreSQL rows.
- Unknown `req_llm` providers return
  `{:error, {:unknown_req_llm_provider, value}}`.
- Missing BullX providers return `{:error, :not_found}`.
- Invalid LLM spec strings return `{:error, {:invalid_llm_spec, reason}}`.
- Decryption failures return `{:error, {:decrypt_failed, provider_id}}`.
- Invalid static provider options return
  `{:error, {:invalid_provider_options, provider_id, reason}}`.
- A plugin provider declaration that would replace an existing `req_llm`
  provider without `override: true` fails startup with
  `{:req_llm_provider_already_registered, id}`.
- Bang APIs raise with the same cause information preserved.
- Cache restart reloads from PostgreSQL. `BullX.Cache` state is not durable
  truth.

## Alternatives considered

The legacy RFC included durable model aliases. This design omits aliases:
provider rows store endpoint credentials, while AIAgent and future callers store
their own model config objects.

BullX could store one row per endpoint/model pair. This would simplify a
provider/model foreign key but would duplicate credentials and endpoint options
for every model served by the same endpoint. This design stores endpoint
configuration once and keeps model ids in caller-owned model configs.

BullX could register custom providers through `Application` env before
`:req_llm` starts. That does not fit BullX plugin startup ordering. Runtime
registration through `ReqLLM.Providers.register/1` composes with the existing
plugin host and keeps plugin enablement restart-bound.

BullX could protect plaintext API keys from all in-memory exposure. The current
BullX configuration system already treats process memory as trusted runtime
state. This design chooses storage safety only, matching the existing
configuration tradeoff.

## Implementation handoff

### Goal

Implement the core LLM provider catalog without UI, model aliases, or caller
model-selection storage. A spec like `"openai_proxy:gpt-4.1-mini"` must resolve
to the configured BullX provider and model id.

### Context pointers

- `docs/design-docs/Configuration.md`
- `docs/design-docs/Plugins.md`
- `lib/bullx/config/*`
- `lib/bullx/plugins/*`
- `lib/bullx/runtime/supervisor.ex`
- `deps/req_llm/lib/req_llm/providers.ex`
- `deps/req_llm/lib/req_llm/provider.ex`

### Constraints

- Use `BullX.Ecto.UUIDv7` for the new UUID primary key and pre-generate insert
  ids with `BullX.Ext.gen_uuid_v7/0` before encrypting API keys.
- Use `BullX.Ext.derive_key/3`, `BullX.Ext.aead_encrypt/2`, and
  `BullX.Ext.aead_decrypt/2` for API key storage.
- Keep caller-owned model-selection storage, including Workflow/Node
  definitions and AIAgent profiles, plus Agentic Loop behavior out of provider
  row storage. AIAgent profiles store model config objects.
- Keep runtime state reconstructible from PostgreSQL.
- Do not introduce an AIAgent runtime supervisor or AIAgent namespace for the
  provider catalog.
- Do not bridge `:custom_providers` through `Application` env.
- Do not add dependencies.

### Tasks

1. Add `llm_providers` migration and `BullX.LLM.Provider` schema with
   database and changeset validation for provider ids, req_llm provider ids,
   URLs, encrypted API key storage, and JSON object provider options.
2. Add `BullX.LLM.Crypto` for per-row API key encryption and decryption.
3. Add `BullX.LLM.Spec`, `ModelConfig`, `ModelDescriptor`,
   `ModelRegistry`, `ResolvedProvider`, and `ResolvedModel`.
4. Add `BullX.LLM.Catalog.Cache` under `BullX.Runtime.Supervisor`,
   backed by `BullX.Cache`, and public `BullX.LLM.Catalog` read APIs.
5. Add `BullX.LLM.Writer` for put, update, delete, and refresh
   operations that update PostgreSQL before refreshing the cache. Post-commit
   cache refresh failures must return persisted-but-stale success, not
   rollback-style errors.
6. Add `BullX.Config.ReqLLM` and `BullX.Config.ReqLLM.Bridge`, start a boot
   sync child after `BullX.Config.Cache`, and trigger the bridge from
   `BullX.Config.Writer` for `bullx.req_llm.` keys.
7. Add `BullX.LLM.PluginProviders` and start its sync child under
   `BullX.Runtime.Supervisor` after the plugin supervisor has started.
8. Add BullX-owned provider modules for `openai`, `anthropic`, `google`,
   `google_vertex`, `vllm`, `mistral`, `azure`, `amazon_bedrock`, `deepseek`,
   `zai`, `xai`, and `openrouter`, and register them as built-in provider
   overrides.
9. Add the `chinese_llm_providers_extra` plugin with `xiaomi_mimo`,
   `volcengine_ark`, `alibaba_cn`, and `zai_coding_plan` provider declarations through the
   `bullx.llm.req_llm_provider` extension point.
10. Add focused tests for spec parsing, model-config resolution, model registry
   discovery/fallback, provider writes, storage encryption, cache-backed
   resolution, invalid provider options, req_llm bridge behavior, built-in
   provider overrides, and plugin provider registration.

### Done when

- `"openai_proxy:gpt-4.1-mini"` resolves into provider id `"openai_proxy"` and
  model id `"gpt-4.1-mini"`.
- Plaintext provider API keys are not stored in PostgreSQL.
- Provider options are validated against the active `req_llm` provider schema
  before resolution returns request options.
- The built-in provider ids listed above resolve through BullX-owned modules
  after runtime startup.
- Enabling `chinese_llm_providers_extra` exposes `xiaomi_mimo`,
  `volcengine_ark`, `alibaba_cn`, and `zai_coding_plan` through the provider
  hook.
- Enabled plugin providers can add new provider ids and can replace an existing
  provider only with `override: true`.
- `bun precommit` passes.
