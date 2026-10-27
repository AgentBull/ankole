---
title: Adding a provider
description: How to declare an AIGateway provider — the DSL, the compiled definition, settings, capabilities, the prepare function, and plugin-based registration.
section: Developer guide
order: 115
---

An AIGateway provider connects Ankole to an upstream AI service such as an LLM, an embedding model, or a web-search API. Building on the [AIGateway](../ai-gateway/) architecture overview, this contributor walkthrough shows how to add a provider: writing the provider DSL, understanding the compiled `ProviderDefinition`, declaring settings and capabilities, and implementing the prepare function that constructs upstream requests.

Keep one core boundary in mind from the start: the Elixir provider module prepares the request, while the Rust `UniversalAIClient` handles wire transport, encoding, and response normalization. Because the compiled definition captures only static metadata, declared settings, and which prepare function handles each capability, a provider is not a full HTTP client—it is a declarative specification paired with an Elixir prepare function.

## The provider DSL

To define a provider, `use Ankole.AIGateway.ProviderDSL` and open a block-structured `provider` declaration. Rather than modeling request-body fields in the DSL, you declare static metadata and capabilities in the `provider` block and construct the request payload in plain Elixir inside the same module:

```elixir
defmodule Ankole.AIGateway.Providers.MyProvider do
  use Ankole.AIGateway.ProviderDSL

  provider :my_provider do
    label(%{"default" => "My Provider"})
    base_url("https://api.example.com/v1")

    setting(:api_key, encrypted: true, scope: :credential)

    language_model do
      api_resolver(:openai_responses)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end
  end

  def prepare_language_model(context) do
    # normal Elixir — build the prepared request from the context
  end
end
```

At compile time, the `provider` block produces a `ProviderDefinition` struct that the AIGateway registry consumes at runtime.

## The compiled definition

A `ProviderDefinition` carries:

| Field | Meaning |
|---|---|
| `provider_kind` | the stable id used by stored provider rows and model bindings |
| `label` | localized display name for the Console |
| `module` | the provider module itself |
| `base_url` | the default upstream URL (operator-overridable) |
| `settings` | the declared `Setting` list |
| `capabilities` | the declared `Capability` list |

At runtime, the registry looks up the provider by `provider_kind`, finds the `Capability` matching the requested kind, invokes that capability's `prepare` function, and passes the resulting request to `UniversalAIClient`.

## Settings

Each `setting` call declares one operator-configurable or per-request option:

```elixir
setting(:api_key, encrypted: true, scope: :credential)
setting(:organization, advanced: true)
setting(:reasoningEffort, type: :select, default: "high",
       options: ["minimal", "low", "medium", "high", "xhigh"], scope: :request)
```

| Field | Meaning |
|---|---|
| `key` | the option name (atom) |
| `type` | `:string`, `:select`, `:boolean`, `:map`, or nil |
| `default` | the default value |
| `options` | for `:select`, the allowed values |
| `required?` | whether the operator must supply it |
| `encrypted?` | storage metadata for a credential value that is encrypted at rest |
| `advanced?` | presentation metadata for Console forms; does not change validation or runtime |
| `scope` | `:credential` (per pool member), `:connection` (per provider row), or `:request` (per model profile) |

Every configured provider row manages a credential pool, even when the operator enters only one credential. Before calling your prepare function, the AIGateway resolver selects a healthy pool member, decrypts its `:credential` settings, and merges them with `:connection` settings (such as an endpoint override or custom headers shared across the provider row) and `:request` settings from the model profile. Because all three scopes arrive pre-merged in the resolved settings map, the prepare function never implements pool selection itself.

Setting `advanced: true` affects only Console presentation, placing the field behind an advanced toggle without altering validation or runtime behavior.

## Capabilities

Each `Capability` block links a user-facing capability kind to an Elixir prepare function and a Rust wire shape:

```elixir
language_model do
  api_resolver(:openai_responses)
  prepare(:prepare_language_model)
  supports_parallel_tool_calls()
  supports_native_image_generation()
end
```

| Field | Meaning |
|---|---|
| `kind` | one of `:language_model`, `:embedding_model`, `:rerank_model`, `:web_search`, `:web_fetch`, `:image_generate` |
| `upstream` | the wire shape, set from `kind`: `:sse` for `:language_model` and `:json` for every other kind |
| `api_resolver` | the Rust-side resolver atom (e.g. `:openai_responses`) that owns encoding and transport |
| `prepare` | the Elixir function that builds the prepared request |
| `timeout_ms` | optional per-capability timeout |
| `supports_parallel_tool_calls?` | whether the provider accepts parallel tool calls |
| `supports_native_image_generation?` | whether an LLM can execute the public image tool without a hosted `image_generate` profile |

The six capability kinds map to the external names that the runtime uses: `language_model` → `"llm"`, `embedding_model` → `"embedding"`, `rerank_model` → `"rerank"`, while `web_search`, `web_fetch`, and `image_generate` keep the same names. Declare only the capabilities that the upstream service actually offers—for instance, an LLM-only provider declares just `language_model`, whereas a provider serving both chat and embeddings declares `language_model` and `embedding_model`.

## The prepare function

The prepare function is normal Elixir code in the provider module, referenced by the capability's `prepare` field. AIGateway passes it a `PrepareContext` (containing the resolved settings, the model request, and the Agent's context) and expects back a prepared `%UniversalAIRequest{}` for `UniversalAIClient` to send:

```elixir
def prepare_language_model(%PrepareContext{} = context) do
  %UniversalAIRequest{}
  |> put_url(context.settings.base_url, "/responses")
  |> put_auth("Bearer", context.settings.api_key)
  |> put_body(context.request)
end
```

All provider-specific rules live here: URL construction, authentication headers, request-body shaping, and upstream API conventions. While the DSL makes the provider discoverable and routable, the prepare function performs the actual request translation. Credential failover also stays outside this function: if an attempt fails on a credential error, the control plane selects another pool member, calls `prepare` again to rebuild the request, and asks the Rust kernel to make one fresh transport attempt.

## Register the provider

First-party providers are compiled directly into the release and discovered automatically by the registry. To contribute a provider from a Control Plane Plugin, declare it under the `ai_gateway.provider` contract in the plugin's `adapter_declarations/0` callback; the registry loads it through the same mechanism used for signal adapters, just under a different contract ID.

See [Develop Skills and Control Plane Plugins](../writing-a-skill/) for plugin registration details. The provider contract ID is `ai_gateway.provider`, and `provider_kind` must match `~r/\A[a-z][a-z0-9_]{0,62}\z/`.

## What this guide is not

This guide is not a general HTTP-client tutorial: your Elixir prepare function builds a `%UniversalAIRequest{}`, and the Rust client executes the HTTP call. Nor is it a way to bypass kernel transport—the Rust `UniversalAIClient` owns the `upstream` wire shape and `api_resolver` implementations, so a provider selects from the existing resolvers rather than inventing custom transport code. Finally, treat `lib/ankole/ai_gateway/providers/` as the canonical reference; reading a straightforward implementation such as OpenAI or `openai_compatible` is the best starting point.

## Next steps

- For the AIGateway concept (routing, resolution, the unified boundary), read [AIGateway](../ai-gateway/).
- For Plugin registration, read [Develop Skills and Control Plane Plugins](../writing-a-skill/).
- For the first Provider setup, read [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent).
