---
title: AIGateway API usage
description: How external callers use the AIGateway REST API — the OpenResponses-compatible endpoints, the Agent and OIDC Human tokens, stateless and stateful calls, and worked examples.
section: Developer guide
order: 126
---

AIGateway is both the worker boundary and a REST API for external applications, enterprise systems, and SDKs. This page covers its endpoints, authentication, call modes, and worked examples. It complements the [AIGateway](../ai-gateway/) concept page with hands-on usage.

The decisive property, stated up front: the AIGateway API is **OpenResponses-compatible and Principal-scoped**. A caller presents a bearer token (Agent or OIDC Human), sends an OpenResponses-shaped request, and receives a JSON response or a stream. The caller never sees a provider credential — the control plane owns those.

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
- **OIDC Human token** — issued to an active Human by an OIDC Client with `ai_gateway.write`; the request uses that Client's model aliases, with `subject_type = "oidc_human"`.

To get an OIDC Human token, create an OIDC Client in the Console with the `ai_gateway.write` scope. Configure its allowed groups and model aliases, then sign in with Authorization Code and PKCE. For long sessions, request `offline_access` and use the rotating Refresh Token. The Human must belong to an allowed group and can use only the Client's model aliases; raw `provider_id/model` selectors are not accepted.

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
| `GET /models` | List the currently available models |
| `POST /embeddings` | Create embeddings |
| `POST /rerank` | Rerank documents |
| `POST /web_search` | Search the web |
| `POST /web_fetch` | Fetch web pages |

Each is documented in the [AIGateway](../ai-gateway/) concept page and the relevant User-guide feature page.

## What this guide is not

It is not the AIGateway concept page. Read [AIGateway](../ai-gateway/) for the full route table, stateful lifecycle, and error envelope. It is also not an SDK. Ankole does not ship a client SDK; callers use standard HTTP clients against the REST API.

## Next steps

- For the full AIGateway surface, read [AIGateway](../ai-gateway/).
- For Provider resolution and request preparation, read [Provider Runtime](../provider-runtime/).
- For the Console API reference, read [Console API reference](../console-api/).
