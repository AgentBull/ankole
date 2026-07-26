---
title: Providers and models
description: How to wire models into an agent — configure an AI provider, then bind model profiles to the agent's capability slots.
section: User guide
order: 12
---

An agent cannot do anything until it has a model behind it. Wiring one up is a two-step operator job: configure the AI provider the control plane will call, then bind that provider's models to the agent through named profile slots. This page walks both steps against the real Console routes.

The decisive property, stated up front: provider credentials live in the control plane, never in the agent's environment. A model profile binds an agent to a *selector* — the control plane resolves the selector to a real provider at call time, and the agent never sees the credential.

## Step 1: Add an AI provider

A provider is an upstream the control plane calls — an OpenAI-compatible endpoint, an Anthropic-style API, a local model server, or a bundled provider kind. Add or replace one with:

```bash
curl -X PUT https://ankole.example.com/api/v1/ai-gateway/providers/<provider_id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "provider_kind": "...", "options": { ... } }'
```

The `<provider_id>` is the name you will refer to this provider by. `provider_kind` selects which adapter handles the call; list the kinds this installation supports with `GET /ai-gateway/provider-kinds`. The `options` carry the endpoint and the encrypted option details — including credentials — that the provider adapter needs. These are stored encrypted by the control plane; do not put them in the agent's WorkerEnv.

The full route surface — listing, replacing, deleting providers — is in the [Console API reference](../console-api/).

## Step 2: Bind model profiles to the agent

An agent does not call a provider directly. It calls through named profile slots, and each slot maps to a capability. The supported slots:

| Profile slot | Capability |
|---|---|
| `primary` | the main LLM the agent reasons with |
| `light` | a cheaper LLM for short, high-volume tasks |
| `heavy` | a stronger LLM for hard synthesis |
| `coding` | the LLM used for code-heavy work |
| `vision_fallback` | the LLM used when the primary cannot handle an image |
| `embedding` | the embedding model |
| `rerank` | the rerank model |
| `web_search` | the web-search provider |
| `web_fetch` | the web-fetch provider |
| `image_generate` | the image-generation model |

`primary`, `light`, and `heavy` are **required** — an agent without all three is not runnable. The rest are optional; leave a slot unset if the agent does not need that capability.

Bind a profile to an agent:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/model-profiles/primary \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "selector": "...", "provider_id": "..." }'
```

The value of a profile is a selector the control plane resolves against the configured providers at call time. List an agent's current profiles with `GET /agents/:agent_uid/model-profiles`, and remove one with `DELETE /agents/:agent_uid/model-profiles/:profile`.

## Codex subscription defaults

The `primary` slot on an agent that runs Codex-backed turns carries Codex subscription fields — `model`, `model_reasoning_effort` (`minimal | low | medium | high | xhigh | max | ultra`), and `fast_mode`. When an operator does not set them, the control plane applies documented defaults so a fresh agent is still runnable. Override them on the `primary` profile when you want different behavior.

## How resolution works at call time

When a turn runs, the Agent Computer asks AIGateway for a model. AIGateway reads the agent's profile for the capability it needs, resolves the selector against the provider bindings, and routes the call. Two resolution failures are worth knowing about, because retrying without fixing them will not help:

- `422 unknown_model_selector` — the selector is not bound for this agent. Check that the profile points at a provider id you actually configured.
- `422 model_binding_not_configured` — the capability and name are bound but the provider binding is incomplete. Check the provider row's options.

Both are configuration problems, not transient ones. The deeper mechanics of routing, error envelopes, and the OpenResponses request shape are in the [AIGateway](../ai-gateway/) developer page.

## A worked example

Suppose you want an agent that reasons with a strong model, falls back to a cheaper one for short replies, and can embed and search the web:

1. Configure one provider for the LLMs (`PUT /ai-gateway/providers/acme-llm`), one for embeddings (`PUT /ai-gateway/providers/acme-embed`), and one for web search (`PUT /ai-gateway/providers/acme-web`). Put each provider's credentials in its own `options`.
2. Bind the agent's `primary`, `light`, and `heavy` to selectors on `acme-llm`. These three are required.
3. Bind `embedding` to a selector on `acme-embed`, and `web_search` to one on `acme-web`.
4. Send a real message through a signal binding and watch the turn use the resolved models.

## What to do when a turn fails

If a turn fails with an upstream error, the profile binding is usually not the first thing to check. Work outward from the model: confirm the provider's options are still valid (credentials rotate), confirm the selector on the profile matches a model the provider actually serves, and only then look at the agent's other configuration. The Console's `/ai-gateway/conversations` route shows the model calls a recent turn made, which is the fastest way to see which profile resolved to which provider.

## Next steps

- For the provider and model-profile route tables, read the [Console API reference](../console-api/).
- For the resolution and routing internals, read the [AIGateway](../ai-gateway/) developer page.
- For the agent these profiles attach to, read [Agents](../agents/).
