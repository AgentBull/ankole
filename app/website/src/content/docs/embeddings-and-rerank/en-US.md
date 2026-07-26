---
title: Embeddings and rerank
description: How embeddings and rerank work — two optional profile slots, the providers that serve them, the AIGateway endpoints, and how Brain recall uses embeddings internally.
section: User guide
order: 40
---

Embeddings and rerank are two AI capabilities that live alongside the LLM on AIGateway's unified boundary. They are not tools the agent calls directly during a turn; they are capabilities AIGateway serves through its API endpoints, and one of them — embeddings — is used internally by Brain recall to find relevant knowledge. This page is the operator-facing view of both.

The decisive property, stated up front: embeddings and rerank are **AIGateway API capabilities, not worker tools**. They are bound through model profile slots, served through `/embeddings` and `/rerank` endpoints, and used by the system (Brain recall, hosted-tool preparation) rather than called by the model as a function.

## The profile slots

`embedding` and `rerank` are two of the ten model profile slots, and both are optional. Only `primary`, `light`, and `heavy` are required. Bind `embedding` when the installation needs vector search (Brain recall uses it); bind `rerank` when a caller needs to re-order candidate documents by relevance. Leave either unbound if the capability is not needed — the Brain recall path degrades gracefully when embeddings are absent, it simply uses keyword-only candidates.

See [Providers and models](../providers-and-models/) for how to bind the slots.

## Which providers serve them

Not every provider serves embeddings or rerank. The providers that declare these capabilities:

| Provider | Embedding | Rerank |
|---|---|---|
| Google AI Studio | yes | — |
| Jina | yes | yes |
| OpenRouter | yes | yes |

Pick the provider that serves the capability you need, and bind the slot to it. A provider that does not declare the capability will reject the request with `unsupported_capability`.

## The AIGateway endpoints

Both capabilities are served through dedicated AIGateway endpoints under `/api/v1/ai-gateway`:

- **`POST /embeddings`** — accepts text, token arrays, or input blocks. Produces vector embeddings. An invalid input shape fails with `invalid_embedding_input`.
- **`POST /rerank`** — accepts a non-empty documents array and a positive integer `top_n`. Re-orders documents by relevance to a query. Empty documents fail with `invalid_documents`; a non-positive `top_n` fails with `invalid_top_n`.

These are the same endpoints external callers use through AIGateway's API; they are not separate from the unified AI boundary.

## How Brain uses embeddings

Brain recall reads knowledge entries through two candidate paths in parallel: BM25 keyword candidates (through `pg_search`) and vector candidates (through embeddings). The embedding candidates are produced by calling the embedding model bound on the `embedding` profile slot, and matched against the query's embedding.

When the `embedding` slot is unbound, Brain recall falls back to keyword-only candidates — it does not fail, it simply loses the vector path. This is why `embedding` is optional: the system degrades gracefully, but vector recall is materially better when the slot is bound.

See [Brain](../brain/) for the full recall model.

## What the operator does

- **Bind `embedding`** when the installation uses Brain (which is the common case). Pick a provider that serves embeddings — Jina, OpenRouter, or Google AI Studio.
- **Bind `rerank`** only when a caller needs document reranking through the API. Most installations do not need it.
- **Watch the cost.** Embeddings are priced per call; Brain recall calls them on every knowledge search. A cheaper embedding model on the `embedding` slot is usually fine — recall quality is about coverage, not single-vector precision.

## What this guide is not

It is not a vector-search tutorial — the embedding and rerank endpoints are standard, and their API shapes are the providers' concern. It is not a Brain-internal guide — the recall model is documented in [Brain](../brain/). And it is not a tool reference — there are no `embedding` or `rerank` tools in the agent's per-turn tool set.

## Next steps

- For the profile slots and how to bind them, read [Providers and models](../providers-and-models/).
- For how Brain uses embeddings in recall, read [Brain](../brain/).
- For the endpoints, read the [Console API reference](../console-api/) and [AIGateway](../ai-gateway/).
