---
title: Model catalog
description: How to use the GET /models endpoint — the OpenRouter-style catalog, the filters, and what an agent or API caller sees.
section: User guide
order: 54
---

The model catalog is what a caller sees when it asks "which models can I use?" AIGateway serves it through `GET /ai-gateway/models`, in an OpenRouter-style shape that external API clients and the Console both consume. This page is the operator-facing view of that endpoint — what it returns, how to filter it, and how it differs between an agent subject and an admin subject.

The decisive property, stated up front: the catalog is **subject-scoped**. An agent sees the models its profiles resolve to; an admin sees every provider's models. The same endpoint returns a different list depending on who is asking — because what you can call is fenced by your AuthZ grants, not by a global model list.

## The endpoint

```bash
curl https://ankole.example.com/api/v1/ai-gateway/models \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

`GET /ai-gateway/models` returns the model catalog. The response is OpenRouter-style — a list of model objects, each with an id, a name, pricing, context window, and supported capabilities.

## Filters

The endpoint accepts query parameters to narrow the catalog:

| Parameter | Purpose |
|---|---|
| `q` | free-text search on model name |
| `context` | minimum context length |
| `min_price` / `max_price` | price range |
| `sort` | OpenRouter-style sort key |
| `output_modalities` | comma-separated output modality filter |
| `input_modalities` | comma-separated input modality filter |
| `supported_parameters` | comma-separated request parameters |

These are the same filters OpenRouter's catalog accepts. An API client looking for "a cheap model with at least 128k context that supports tool use" can filter programmatically rather than scanning the whole list.

## What an agent sees vs what an admin sees

The catalog is resolved per subject:

- **An agent token** sees the models its provider bindings expose — the selectors its profiles resolve to, plus the provider's full model list for explicit `provider_id/model` selection.
- **An admin token** sees every provider's models — the full catalog across all configured providers.

This is the same AuthZ-scoped model as every other AIGateway endpoint. The catalog is not a global list; it is what the caller is authorized to call.

## How to use it

- **As an API caller** — query the catalog to find a model that fits your needs (context, price, capabilities), then send its id as the `model` field in a `/responses` request.
- **As an operator** — use it to verify that a provider's models are visible after you configure it. If a provider you just added does not appear in the catalog, the binding is incomplete or the provider is disabled.
- **As an agent's system prompt** — the catalog is not injected into the prompt. The agent sees its model profiles (primary, light, heavy), not the catalog. The catalog is for API callers and operators.

## What this guide is not

It is not a model-comparison site — the catalog's pricing and capability data comes from the providers, and Ankole does not curate it. It is not a provider-configuration guide — see [Providers and models](../providers-and-models/) for how to bind profiles. And it is not the AIGateway concept page — for the full API surface, read [AIGateway](../ai-gateway/).

## Next steps

- For binding model profiles, read [Providers and models](../providers-and-models/).
- For the AIGateway API surface, read [AIGateway](../ai-gateway/).
- For provider routing, read [Provider routing](../provider-routing/).
- For the Console routes, read the [Console API reference](../console-api/).
