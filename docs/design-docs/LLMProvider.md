# LLM Provider

The LLM provider catalog stores endpoint credentials and provider options for
ReqLLM-backed model calls. The implementation lives in `BullX.LLM.*`.

## Responsibility

The LLM subsystem owns:

- persisted provider rows;
- encrypted API key storage;
- provider resolution and cache refresh;
- ReqLLM provider registration;
- model registry and discovery;
- `BullX.LLM.chat/3` and `BullX.LLM.stream_chat/4` call normalization.

It does not own AIAgent prompts, tool execution, MailBox delivery, workflow
state, or caller-specific model selection policy.

## Tables

`llm_providers` stores:

- `provider_id`, unique, matching `[a-z][a-z0-9_-]{0,62}`;
- `req_llm_provider`, matching `[a-z][a-z0-9_]{0,62}`;
- optional absolute HTTP(S) `base_url`;
- optional `encrypted_api_key`;
- `provider_options` JSON object.

API keys are encrypted with row-id-bound BullX crypto. The encrypted field is
never allowed to be an empty string.

## Provider Rows

`BullX.LLM.Writer.put_provider/1` inserts or updates by `provider_id`.
`update_provider/2` rejects attempts to change `provider_id`.

`req_llm_provider` must be known to `BullX.LLM.ProviderRegistry`. Known
providers are built-ins or enabled plugin-registered providers.

API key behavior:

- `api_key` missing: keep the existing encrypted key on update.
- `api_key` as a non-empty string: encrypt and store it.
- `api_key` as `nil` or empty string: clear the stored key.

After writes and deletes, the writer refreshes `BullX.LLM.Catalog.Cache`. If the
row is persisted but refresh fails, the writer returns a
`{:persisted_but_stale, ...}` diagnostic.

## Catalog Resolution

`BullX.LLM.Catalog` resolves either:

- a `BullX.LLM.ModelConfig` struct, or
- a string spec formatted as `provider_id:model`.

Resolution loads the provider row from `BullX.LLM.Catalog.Cache`, decrypts the
API key, validates provider options against provider-specific schemas when
available, and returns `ResolvedProvider` / `ResolvedModel` structs.

## Model Config

`BullX.LLM.ModelConfig` is the caller-owned model-call configuration used by
AIAgent profiles.

Fields:

- `provider_id`
- `model`
- `reasoning_effort`: `none`, `minimal`, `low`, `medium`, `high`, or `xhigh`
- optional `context_window`
- optional `max_completion_tokens`

Defaults:

- `reasoning_effort = :medium`
- effective context window falls back to `80_000`
- `max_completion_tokens`, when present, must be at least `200`

`call_opts/1` sends reasoning effort and max token settings to ReqLLM.

## Runtime Calls

`BullX.LLM.chat/3` resolves the model, normalizes prompt messages, calls the
configured client, and returns:

- text;
- provider id;
- model id;
- usage;
- finish reason;
- tool calls;
- provider metadata;
- the raw response message.

`BullX.LLM.stream_chat/4` uses the client's streaming function when available.
If the client has no stream implementation, it falls back to a normal chat call
and emits the full result through the stream callback path.

Before calling ReqLLM, BullX merges text-only content parts for system and user
messages into one text part separated by newlines. This preserves provider
compatibility for providers that do not accept multiple text parts for those
roles.

## Built-In Providers

`BullX.LLM.PluginProviders` registers built-in provider modules at runtime
start. Current built-ins include:

- Amazon Bedrock
- Anthropic
- Azure
- DeepSeek
- Google
- Google Vertex
- Mistral
- OpenAI
- OpenRouter
- vLLM
- xAI
- Z.ai

Enabled plugins can add or override ReqLLM providers through
`:"bullx.llm.req_llm_provider"` extensions.

## ReqLLM Application Settings

`BullX.Config.ReqLLM.BootSync` and `BullX.Config.ReqLLM.Bridge` synchronize
BullX config values under `bullx.req_llm.*` into the `:req_llm` application env.

BullX keeps `:req_llm, load_dotenv: false`; dotenv loading belongs to BullX
bootstrap config.

## Model Registry

`BullX.LLM.ModelRegistry` lists models for saved provider rows. It uses dynamic
provider discovery when the provider module exposes it and falls back to the
local LLMDB-backed model list when needed.

`public_provider_models/0` returns a provider-id keyed map for setup and UI
surfaces.

## Invariants

- Provider rows store endpoint credentials and provider options, not AIAgent
  prompt policy.
- API keys are encrypted before persistence.
- Provider ids are local BullX ids and can differ from ReqLLM provider ids.
- Provider cache refresh follows provider writes.
- Callers own their model selection; the catalog only resolves it.
