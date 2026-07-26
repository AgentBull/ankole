---
title: AIGateway API usage
description: How external callers use the AIGateway REST API — the OpenResponses-compatible endpoints, the agent vs admin token, stateless and stateful calls, and worked examples.
section: User guide
order: 59
---

AIGateway is not just an internal boundary that workers call; it is a REST API external applications, enterprise systems, and SDKs can call directly. This page is the caller's practical guide to using it — the endpoints, the authentication, the two call modes, and worked examples. It complements the [AIGateway](../ai-gateway/) concept page with hands-on usage.

The decisive property, stated up front: the AIGateway API is **OpenResponses-compatible and Principal-scoped**. A caller presents a bearer token (agent or admin), sends an OpenResponses-shaped request, and receives a JSON response or a stream. The caller never sees a provider credential — the control plane owns those.

## Authentication

Every call under `/api/v1/ai-gateway` requires a bearer token:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Hello" }'
```

Two token kinds are accepted:

- **Agent token** — scoped to one agent's model bindings. Use this when an integration acts on behalf of a specific agent.
- **Admin token** — scoped to all providers. Use this for operator-side scripts and the Console.

See [Principal and AuthZ](../principal-authz/) for how tokens resolve to Principals.

## Stateless responses (HTTP and SSE)

A stateless call is one request, one response. Send the full input; get the complete body back:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Summarize this thread.", "store": false }'
```

For streaming, add `"stream": true` and the same endpoint switches to Server-Sent Events:

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Draft a release note.", "stream": true }'
```

Stateless HTTP and SSE reject the stateful fields (`previous_response_id`, `conversation`, `store`). Use the WebSocket path for continuation.

## Other endpoints

| Endpoint | Purpose |
|---|---|
| `GET /models` | List available models (see [Model catalog](../model-catalog/)) |
| `POST /embeddings` | Create embeddings |
| `POST /rerank` | Rerank documents |
| `POST /web_search` | Search the web |
| `POST /web_fetch` | Fetch web pages |
| `GET /web_tools` | List available web tools |

Each is documented in the [AIGateway](../ai-gateway/) concept page and the relevant User-guide feature page.

## What this guide is not

It is not the AIGateway concept page — for the full route table, the stateful lifecycle, and the error envelope, read [AIGateway](../ai-gateway/). It is not a provider-configuration guide — for binding models, read [Providers and models](../providers-and-models/). And it is not an SDK — Ankole does not ship a client SDK; callers use standard HTTP clients against the REST API.

## Next steps

- For the full AIGateway surface, read [AIGateway](../ai-gateway/).
- For the model catalog, read [Model catalog](../model-catalog/).
- For provider routing, read [Provider routing](../provider-routing/).
- For the Console API reference, read [Console API reference](../console-api/).
