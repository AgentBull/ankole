---
title: Provider routing
description: How a model selector resolves to a provider — the two selector shapes, the resolution path, and what to check when routing fails.
section: User guide
order: 46
---

Every model call carries a selector — the `model` field that says which model the caller wants. The resolver turns that selector into a concrete provider, a model, and the runtime settings to reach it. This page is the operator-facing view of how routing works, so you can reason about what happens when you bind a profile and the call lands on the right provider — or does not.

The decisive property, stated up front: routing is **selector-to-profile-to-provider**, and the profile is the middle layer the operator controls. You do not point an agent at a provider; you bind a profile slot to a selector on a provider, and the resolver walks from selector to profile to provider at call time. A binding that is wrong shows up as a `422` at resolution time, not as a silent wrong model.

## The two selector shapes

The resolver accepts two shapes of selector, depending on the capability:

| Capability | Selector shape | How it resolves |
|---|---|---|
| LLM (`llm`) | a named alias: `primary`, `light`, `heavy`, `coding`, `vision_fallback` | resolves through the agent's model profiles |
| Non-LLM (`embedding`, `rerank`, `web_search`, `web_fetch`, `image_generate`) | `default`, `<capability>.default`, or an explicit `provider_id/model` | resolves through the profile, or directly to the provider if explicit |

The LLM aliases are the five names an operator binds through model profiles. The non-LLM capabilities accept a `default` keyword (which maps to the agent's `embedding`, `rerank`, `web_search`, `web_fetch`, or `image_generate` profile), an explicit default binding like `embedding.default`, or a fully explicit `provider_id/model` selector that bypasses the profile entirely.

## The resolution path

When a turn calls the model, the resolver walks:

1. **Read the selector** from the request's `model` field.
2. **Classify the capability** — is it an LLM alias, or a non-LLM capability?
3. **Resolve through profiles** (LLM aliases and `default` non-LLM selectors) — look up the agent's model profile for the named slot, which points at a provider and a selector.
4. **Or resolve directly** (explicit `provider_id/model` selectors) — look up the provider by id and use the named model, skipping the profile.
5. **Build the runtime map** — provider id, provider kind, upstream model name, resolved settings. This is what the provider module's prepare function receives.

The resolver is the only point that consults the agent's identity and model profiles. The provider module never sees the selector or the subject — it receives the resolved runtime map and prepares the request from it.

## What an operator controls

The operator's lever is the **model profile binding**, not the routing rule. There is no routing table to edit; there are profile slots to bind:

- **LLM slots** — `primary`, `light`, `heavy` (required), `coding`, `vision_fallback` (optional). Each slot maps to a selector on a provider row. See [Providers and models](../providers-and-models/).
- **Non-LLM slots** — `embedding`, `rerank`, `web_search`, `web_fetch`, `image_generate` (all optional). Each maps the same way.

A caller who sends `primary` gets whatever the agent's `primary` profile is bound to. A caller who sends `provider_id/model` bypasses the profile and hits the provider directly — this is how external API callers (through AIGateway's `/responses` endpoint) can target a specific model without an agent's profile.

## When routing fails

Routing fails at resolution time, before the provider is contacted:

| Error | What it means | Fix |
|---|---|---|
| `422 unknown_model_selector` | the selector is not bound for this agent | bind the profile slot, or use a selector that is bound |
| `422 model_binding_not_configured` | the profile points at a provider that is incomplete | fix the provider row's credentials or settings |
| `422 unsupported_capability` | the provider does not serve this capability | bind the slot to a provider that declares the capability |

These are configuration errors, not transient failures. Retrying without fixing the configuration produces the same error. See the [FAQ](../faq/) for the troubleshooting order.

## What this guide is not

It is not a provider-authoring guide — see [Adding a provider](../adding-a-provider/) for the DSL and the prepare function. It is not a resolver-internals deep dive — see [Provider runtime](../provider-runtime/) for the three-stage path. And it is not a load-balancing or failover guide — Ankole routes by profile binding, not by health-checking multiple providers for the same slot.

## Next steps

- For how to bind profile slots, read [Providers and models](../providers-and-models/).
- For the resolver internals, read [Provider runtime](../provider-runtime/).
- For the error envelope, read [AIGateway](../ai-gateway/).
- For the cost levers on each slot, read [Cost management](../cost-management/).
