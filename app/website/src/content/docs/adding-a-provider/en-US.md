---
title: Adding a provider
description: How to declare an AIGateway provider — the DSL, the compiled definition, settings, capabilities, the prepare function, and plugin-based registration.
section: Developer guide
order: 115
---

An AIGateway provider is how Ankole talks to an upstream AI service — an LLM, an embedding model, a web-search API. This page is the contributor walkthrough: the provider DSL, the compiled `ProviderDefinition` it produces, the settings and capabilities a provider declares, and the prepare function that owns request construction. It builds on the [AIGateway](../ai-gateway/) concept page; this is *how to add a provider*.

The decisive property, stated up front: the provider module owns request preparation in Elixir; the Rust `UniversalAIClient` owns the wire — transport, encoding, response normalization. The compiled definition describes only stable metadata, settings, and which prepare function owns each capability. A provider is not a full HTTP client; it is a prepare function plus a declaration.

## The provider DSL

A provider module uses `Ankole.AIGateway.ProviderDSL` and declares itself with a small block-structured DSL. The DSL records metadata and capability ownership; it deliberately does not describe request body fields — each provider's prepare function is normal Elixir code in the same module.

```elixir
defmodule Ankole.AIGateway.Providers.MyProvider do
  use Ankole.AIGateway.ProviderDSL

  provider :my_provider do
    label(%{"default" => "My Provider"})
    base_url("https://api.example.com/v1")

    setting(:api_key, encrypted: true)

    language_model do
      upstream(:sse)
      api_resolver(:openai_responses)
      prepare(:prepare_language_model)
    end
  end

  def prepare_language_model(context) do
    # normal Elixir — build the prepared request from the context
  end
end
```

The `provider` block compiles into a `ProviderDefinition` struct, consumed by the AIGateway registry at runtime.

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

The registry resolves a provider by `provider_kind`, looks up the capability for the requested kind, calls the capability's `prepare` function, and hands the result to `UniversalAIClient`.

## Settings

A `Setting` declares one operator or request option:

```elixir
setting(:api_key, encrypted: true)
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
| `encrypted?` | storage metadata — the value is encrypted at rest; provider code reads the decrypted value |
| `advanced?` | presentation metadata for Console forms; does not change validation or runtime |
| `scope` | `:connection` (per-provider) or `:request` (per-model-profile) |

`encrypted?` is storage metadata only. Provider code reads the decrypted value from the same settings map; there is no separate credential abstraction. `advanced?` is presentation only — it hides the field behind an "advanced" toggle in the Console; it does not affect validation or behavior.

## Capabilities

A `Capability` binds a user-facing model capability to the prepare function and the wire shape:

```elixir
language_model do
  upstream(:sse)
  api_resolver(:openai_responses)
  prepare(:prepare_language_model)
end
```

| Field | Meaning |
|---|---|
| `kind` | one of `:language_model`, `:embedding_model`, `:rerank_model`, `:web_search`, `:web_fetch`, `:image_generate` |
| `upstream` | the wire shape: `:sse`, `:eventstream`, `:websocket_text`, or `:json` |
| `api_resolver` | the Rust-side resolver atom (e.g. `:openai_responses`) that owns encoding and transport |
| `prepare` | the Elixir function that builds the prepared request |
| `timeout_ms` | optional per-capability timeout |

The six capability kinds map to the external names the runtime uses: `language_model` → `"llm"`, `embedding_model` → `"embedding"`, `rerank_model` → `"rerank"`, and the three web/image kinds are unchanged. A provider that serves only LLMs declares only `language_model`; a provider that serves LLMs and embeddings declares both.

## The prepare function

The prepare function is normal Elixir code in the provider module, named by the capability's `prepare` field. It receives a `PrepareContext` (the resolved settings, the model request, the agent's context) and returns a prepared request that `UniversalAIClient` sends:

```elixir
def prepare_language_model(%PrepareContext{} = context) do
  %UniversalAIRequest{}
  |> put_url(context.settings.base_url, "/responses")
  |> put_auth("Bearer", context.settings.api_key)
  |> put_body(context.request)
end
```

This is where provider differences live — URL construction, auth headers, body shaping, the quirks of a specific upstream API. The prepare function is the provider's actual work; the DSL declaration is just how that work is discovered and routed.

## Register the provider

First-party providers are compiled into the release and discovered by the registry. For a plugin-contributed provider, declare it through the `ai_gateway.provider` contract in a Control Plane Plugin's `adapter_declarations/0`, and the registry picks it up from the plugin's declaration — same model as a signal adapter, different contract id.

See [Creating a Control Plane Plugin](../creating-a-control-plane-plugin/) for the plugin registration path; the provider contract is `ai_gateway.provider`, the kind id must match `~r/\A[a-z][a-z0-9_]{0,62}\z/`.

## What this guide is not

It is not an HTTP-client tutorial — the prepare function builds a prepared request, and the Rust client does the HTTP. It is not a way to bypass the kernel's transport; the `api_resolver` and `upstream` wire shape are what the Rust `UniversalAIClient` owns, and a provider picks from the existing resolvers rather than inventing its own transport. And it is not a substitute for reading the existing providers; `lib/ankole/ai_gateway/providers/` is the canonical reference, and the simplest one (OpenAI or openai_compatible) is the right starting point.

## Next steps

- For the AIGateway concept (routing, resolution, the unified boundary), read [AIGateway](../ai-gateway/).
- For the plugin registration path, read [Creating a Control Plane Plugin](../creating-a-control-plane-plugin/).
- For the operator-facing provider configuration, read [Providers and models](../providers-and-models/).
