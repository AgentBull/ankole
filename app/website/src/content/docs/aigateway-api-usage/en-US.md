---
title: AIGateway API usage
description: How external callers use the AIGateway REST API — the OpenResponses-compatible endpoints, the Agent and OIDC Human tokens, stateless and stateful calls, and worked examples.
section: Developer guide
order: 126
---

AIGateway serves both internal Agent turns and external applications, enterprise systems, and HTTP clients over one REST and streaming surface. Complementing the [AIGateway](../ai-gateway/) architecture reference, this guide covers authentication, call modes, and practical `curl` examples.

Every AIGateway endpoint is **OpenResponses-compatible and Principal-scoped**: callers present a bearer token (Agent or OIDC Human), send an OpenResponses-shaped request, and receive either a JSON body or an event stream. Upstream provider credentials stay strictly inside the control plane and are never exposed to callers.

## Authentication

Every request under `/api/v1/ai-gateway` requires a bearer token in the `Authorization` header:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Hello" }'
```

AIGateway accepts two token kinds:

- **Agent token** — scoped to a specific Agent's model bindings; use this when an integration calls AIGateway on behalf of that Agent.
- **OIDC Human token** — issued to an active Human by an OIDC Client granted `ai_gateway.write`; requests resolve against that Client's model aliases, with `subject_type = "oidc_human"`.

To obtain an OIDC Human token, create an OIDC Client in the Console with the `ai_gateway.write` scope, configure its allowed groups and model aliases, and sign in with Authorization Code and PKCE (request `offline_access` to receive a rotating Refresh Token for long-lived sessions). The Human must belong to an allowed group and may select only from that Client's model aliases; raw `provider_id/model` selectors are rejected.

See [Principal and AuthZ](../principal-authz/) for how tokens resolve to Principals.

## Stateless responses (HTTP and SSE)

A stateless call follows a single request/response cycle—send the full input and receive the complete response body:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Summarize this thread.", "store": false }'
```

To stream tokens as they arrive, add `"stream": true` so the endpoint switches to Server-Sent Events:

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Draft a release note.", "stream": true }'
```

Calls over stateless HTTP or SSE cannot include the stateful fields `previous_response_id`, `conversation`, or `store`; connect over the `/responses` WebSocket endpoint whenever you need multi-turn continuation.

## Other endpoints

| Endpoint | Purpose |
|---|---|
| `GET /models` | List the currently available models |
| `POST /embeddings` | Create embeddings |
| `POST /rerank` | Rerank documents |
| `POST /web_search` | Search the web |
| `POST /web_fetch` | Fetch web pages |
| `POST /decisions` | Answer typed questions with probabilities |
| `POST /images` | Generate or edit an image |
| `POST /audio/speech` | Turn text into spoken audio |
| `POST /audio/transcriptions` | Turn audio into text |
| `POST /ocr` | Read a PDF or a document image as Markdown |

Each endpoint is documented in detail on the [AIGateway](../ai-gateway/) page and the corresponding User-guide feature page.

## Typed decisions

Use `POST /decisions` when an application needs probabilities rather than generated prose. The `decision.default` selector resolves the Pod/Site decision profile; an explicit `provider_id/model` selector can choose a decision model directly.

```bash
curl https://ankole.example.com/api/v1/ai-gateway/decisions \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "decision.default",
    "state": {"ticket": "I was charged twice."},
    "questions": {
      "urgent": {"type": "noul", "instructions": "Does this need a reply today?"},
      "team": {
        "type": "choice",
        "instructions": "Which team owns this ticket?",
        "criteria": {"billing": "Payments and refunds", "support": "Product questions"}
      }
    }
  }'
```

A `score` question takes 2 to 10 ordered labels in `criteria`. The response contains `model`, `answers`, and token `usage`; every answer includes probabilities. TypeSafe, Azure Foundry, OpenRouter, OpenAI, and Cloudflare decision models use the same public request shape. Upstream image support differs: SystemOne accepts PNG/JPEG, Microsoft-Decision-1 is text-only, and OpenAI also accepts WebP. An OpenAI refusal for any question returns `422 upstream_decision_refusal` without partial answers. When no decision profile is configured, the caller's `light` language model answers with uncalibrated probabilities.

## What this guide is not

This page focuses on client usage rather than protocol internals—read [AIGateway](../ai-gateway/) for the complete route table, stateful WebSocket lifecycle, and error envelope. Note also that Ankole does not ship a proprietary client SDK; callers use standard HTTP or OpenResponses-compatible clients directly against the REST API.

## Next steps

- For the full AIGateway surface, read [AIGateway](../ai-gateway/).
- For Provider resolution and request preparation, read [Provider Runtime](../provider-runtime/).
- For the Console API reference, read [Console API reference](../console-api/).
