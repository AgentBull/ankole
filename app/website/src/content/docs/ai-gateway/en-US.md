---
title: AIGateway API
description: The OpenResponses-compatible AI boundary — HTTP, SSE, and WebSocket endpoints, stateless and stateful calls, and provider routing.
section: Developer guide
order: 101
---

AIGateway is the unified AI boundary of an Ankole deployment instance. External applications, enterprise systems, and SDKs call it directly over an OpenResponses-compatible API, while internal Agents call the same surface for their model turns. On every call, AIGateway resolves a model selector against the provider bindings that the operator configured, keeping upstream credentials strictly inside the control plane.

This page maps the routes, request shapes, and boundary between stateless and stateful calls against the control-plane router and `Ankole.AIGateway`.

## Where it fits

AIGateway sits between callers and upstream providers. External callers and Worker-side Agent loops present a bearer token over HTTP, SSE, or WebSocket, while control-plane subsystems such as `Ankole.Brain` and `Function Runtime` invoke `Ankole.AIGateway` in-process under built-in `system` Principals (`ankole_brain` and `system`). On every call, AIGateway resolves the selector, prepares the upstream request, dispatches it to the bound provider, and returns either a single JSON body or a live event stream. LLM, embedding, rerank, web-search, and web-fetch capabilities all flow through this boundary. When a response turn uses `programmatic_tool_calling`, AIGateway executes each `programmatic_tool_call` TypeScript program inside a stateless isolate on `ankole-function-runtime` (`Ankole.FunctionRuntime.ProgramRunner`).

Callers never see upstream provider credentials: the control plane owns all credentials and routing policies, while each caller supplies only its subject identity and model selector.

## Authentication

Every HTTP and WebSocket endpoint under `/api/v1/ai-gateway` runs through the `:ai_gateway_api` pipeline and the `RequireAIGatewayAccessToken` plug. Every network request must present a bearer token in the `Authorization` header, and the plug accepts exactly two token kinds:

- **Agent token** — an AIGateway API key whose subject is an active Agent Principal; calls are scoped to that Agent's effective Model Profiles and selectors, with `subject_type = "agent"`.
- **OIDC Human token** — issued to an active Human by an OIDC Client granted `ai_gateway.write`; calls resolve against that Client's model aliases, with `subject_type = "oidc_human"`.

First-party control-plane services (such as `ankole_brain` for Company Brain workloads) invoke `Ankole.AIGateway` directly inside the BEAM without external bearer tokens, recording usage under their respective `system` Principal UIDs.

To obtain an OIDC Human token, create an OIDC Client in the Console with the `ai_gateway.write` scope, configure its allowed groups and model aliases, and sign in using Authorization Code with PKCE (request `offline_access` to receive a rotating Refresh Token for long-lived sessions). The Human must belong to an allowed group and may use only the Client's configured model aliases; raw `provider_id/model` selectors are rejected.

If a request omits the token or presents one that cannot be verified, the plug returns `401` with `code: "invalid_token"`. AIGateway has no anonymous access path.

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"primary","input":"Summarize the open incidents."}'
```

## The endpoints

All routes live under `/api/v1/ai-gateway`, and the transport that each endpoint uses is part of its contract rather than a caller preference:

| Method | Path | Transport | Purpose |
|---|---|---|---|
| `GET` | `/models` | HTTP | List model selectors visible to this subject |
| `POST` | `/responses` | HTTP or SSE | Create a response; stream when `"stream": true` |
| `GET` | `/responses` | WebSocket | Stateful streaming responses |
| `GET` | `/responses/:response_id` | HTTP | Retrieve a stored stateful response (`resp_{uuid}`) |
| `POST` | `/embeddings` | HTTP | Create embeddings |
| `POST` | `/rerank` | HTTP | Rerank documents |
| `POST` | `/web_search` | HTTP | Search the web |
| `POST` | `/web_fetch` | HTTP | Fetch web pages |
| `POST` | `/decisions` | HTTP | Answer typed questions about a state with probabilities |
| `POST` | `/images` | HTTP | Generate or edit one image |
| `POST` | `/audio/speech` | HTTP | Turn text into spoken audio |
| `POST` | `/audio/transcriptions` | HTTP | Turn audio into text |
| `POST` | `/ocr` | HTTP | Read a PDF or a document image as Markdown |
| `POST` | `/videos` | HTTP | Start a video generation; `GET /videos/:id` reads the job and `GET /videos/:id/content` the file |
| `POST` | `/audio/music` | HTTP | Start a music generation; `GET /audio/music/:id` reads the job and `GET /audio/music/:id/content` the file |
| `GET/POST/DELETE` | `/files`, `/files/:id`, `/files/:id/content` | HTTP | Upload, read, and delete files |

`POST /responses` sits at the center of the surface: it drives model turns and is the only endpoint that branches on both transport and statefulness.

## Stateless responses over HTTP and SSE

A stateless call follows a single request/response cycle: the caller sends the complete input, AIGateway resolves the selector and calls the upstream provider, and the endpoint returns the full JSON body. Pass `"stream": true` and the same endpoint switches to Server-Sent Events, opening an SSE stream that emits typed events as `event: <type>\ndata: <json>\n\n` and finishes with `data: [DONE]`.

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"primary","input":"Draft a release note.","stream":true}'
```

Stateless HTTP and SSE reject `previous_response_id`, `conversation`, and any `store` value other than `false`. You may omit `store` or set `store: false`. Use the WebSocket endpoint for multi-turn state continuation; a forbidden stateful field over HTTP or SSE returns `400` with `code: "stateful_responses_require_websocket"` and a message naming the field.

## Stateful responses over WebSocket

Stateful responses run on `GET /responses` via a WebSocket upgrade, which hands the connection to `AIGatewayResponsesSocket` with the subject's identity, a 30-minute idle timeout, compression, and a 128 MiB frame ceiling. Because the client sends no frames while waiting for a model response, that 30-minute idle timeout also bounds the maximum duration of a single turn, matching the upstream first-byte and idle budgets. Over WebSocket, callers may set `store: true` and continue an existing thread via `previous_response_id` or `conversation`.

This WebSocket path hosts the durable response lifecycle. Each stored response receives an ID formatted as `resp_{uuid}` so later turns can continue from `previous_response_id` or reference a stored `conversation`. The control plane manages continuation rules, durable history, compaction, response projection, and crash recovery—none of that burden falls on the caller.

You can retrieve any stored response later over plain stateless HTTP:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses/resp_4f3c... \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

Compaction replaces a long stored history with a compact checkpoint without losing thread continuity. Rather than exposing a separate endpoint, AIGateway accepts a `{"type": "compaction_trigger"}` item in `input` and responds with a single `compaction` output item across any transport (`POST /responses` for JSON, `"stream": true` for SSE, or WebSocket). If you send only the trigger alongside `previous_response_id` or `conversation`, AIGateway compacts the stored conversation and returns the new checkpoint ID to continue from; if you include history items alongside the trigger, AIGateway compacts the history that you sent.

## Provider routing

Before making any upstream call, AIGateway resolves the model selector through 3-tier sparse **Model Profile** inheritance (`Site -> Pod -> Agent/System`), configured in **Console → Model Profiles**:

- **Site, Pod, and `system` Principals (`ankole_brain`, `system`)** expose fifteen fixed slots: five language-model slots (`primary`, `light`, `heavy`, `coding`, and `vision_fallback`) and ten capability slots (`web_search`, `web_fetch`, `image_generate`, `rerank`, `decision`, `speech`, `transcription`, `ocr`, `video`, and `music`).
- **Agents** expose the eight built-in slots other than `rerank`, `decision`, `speech`, `transcription`, `ocr`, `video`, and `music`, plus any custom language-model aliases configured on the Agent, inheriting unset slots from Pod and Site defaults.
- **Cross-slot fallbacks** resolve `coding -> heavy -> primary` and `light -> primary`, so a Pod with `primary` configured can run Agents and Brain workflows immediately while allowing targeted per-Pod, per-Agent, or `system` Principal overrides.

Administrators and explicit internal callers can also address concrete `provider_id/model` selectors where permitted. Call `GET /models` to list every selector that the current subject can resolve, with optional OpenRouter-style query filters (`q`, `context`, `min_price`, `max_price`, `sort`, and modality filters).

Each provider row manages a credential pool whose members share the row's provider kind, base URL, headers, settings, and capability declarations. Model profiles point to the provider row as a whole rather than to a specific pool member, and AIGateway picks a healthy credential using the configured `fill_first`, `round_robin`, `least_used`, or `random` strategy (translated in the Console UI for the active locale, while the API and database always use those canonical keys). Whenever possible, AIGateway keeps a stateful thread on the same pool member across turns.

When an upstream call fails with an attributed `429`, `5xx`, or transport error, AIGateway places only that specific credential on cooldown, selects another healthy member from the pool, rebuilds the upstream request, and retries with bounded exponential backoff and jitter. The Rust kernel executes one transport attempt at a time, and AIGateway never crosses over to a different provider if the bound pool is exhausted.

`chatgpt_subscription` works like any other provider kind: its OAuth credentials remain encrypted in the control plane, where token refresh runs under a database row lock, so neither the Agent Computer nor external callers ever receive those tokens.

`agentbull_cloud` (**AgentBull Cloud**, default base URL `https://cloudapis.agentbull.com`) is a built-in aggregated upstream provider kind that serves language models, embeddings, reranking, `web_search`, `web_fetch`, and `image_generate` with a single API key. Its credentials stay inside the control plane alongside `Ankole.Connectors`, which manages shared platform connections, personal OAuth tokens, and Skill-declared remote MCP headers in PostgreSQL (`WorkerEnv` remains available for custom CLI variables inside Agent Computers).

Callers should handle two selector-resolution errors:

- `422 unknown_model_selector` — the selector is not bound for this subject.
- `422 model_binding_not_configured` — the capability and profile name are bound, but the underlying provider binding is incomplete.

Requesting a capability that the bound provider does not support returns `422 unsupported_capability`, and calling a provider that an operator disabled returns `422 provider_disabled`. All four `422` codes reflect configuration state rather than transient failures, so retrying without updating configuration will not succeed.

## Error shapes

Errors return an OpenAI-compatible JSON envelope (`{"error": {"code": "...", "message": "..."}}`) paired with an HTTP status matching the failure class:

- `400` — request validation failed (missing `model` or `input`, invalid `limit` or `top_n`, a stateful field sent over HTTP, or malformed compaction input); `code` identifies the offending field or rule.
- `401` — the bearer token is missing or cannot be verified.
- `429` — every credential in the selected provider's pool is cooling down (`code: "credential_pool_exhausted"`, with `retry_at` included whenever AIGateway knows the earliest recovery timestamp).
- `404` — the requested stored response, conversation, Agent, or file does not exist for this subject.
- `422` — the request is well-formed, but configuration prevents serving it (unknown selector, incomplete binding, unsupported capability, or disabled provider).
- `502` / `504` — the upstream provider failed: `502` covers transport and malformed-response errors (`upstream_transport_failed`, `invalid_upstream_response`, `ai_gateway_request_failed`), while `504` signals `upstream_timeout`. Upstream `4xx` client errors pass through with their original HTTP status.

When the upstream response includes an `error.message`, AIGateway forwards that message; otherwise, it reports the upstream HTTP status directly.

## Programmatic tool calling and image generation

When a `/responses` request enables the `programmatic_tool_calling` tool, AIGateway synthesizes a `program` tool from eligible tool descriptors. It executes each `programmatic_tool_call` as a deterministic TypeScript program inside a stateless isolate on `ankole-function-runtime` via `Ankole.FunctionRuntime.ProgramRunner`, suspending at nested tool boundaries while AIGateway retains ownership of history, ordering, and cancellation.

`image_generation` is a public Responses tool with two execution paths. When the main language-model provider supports native image generation on the Responses wire, AIGateway forwards the tool to it without resolving an `image_generate` profile. Otherwise, AIGateway uses the subject's `image_generate` profile; if neither path is available, request preparation fails.

Both execution paths emit identical stream events and persist generated images in the same way, attributing model usage and image usage separately to whichever credential produced each output.

## Web tools, files, and the other capabilities

The same Principal identity and bearer token authorize AIGateway's remaining endpoints. `POST /web_search` accepts a length-bounded `query` and returns provider-backed search results, while `POST /web_fetch` fetches content from one to five public HTTPS URLs; both accept `web_search.default` and `web_fetch.default` to resolve the calling Agent's configured profiles.

`POST /embeddings` accepts strings, token arrays, or structured input blocks with an explicit `provider_id/model` selector—for example, `Ankole.Brain` reads the site-level `brain.embedding_model` key from [AppConfigure](../app-configuration/) when generating embeddings. `POST /rerank` reranks a non-empty document array using a positive integer `top_n`, accepting either an explicit `provider_id/model` selector or `default` / `rerank.default` (`ankole_brain` resolves its effective `rerank` Model Profile, while Agent and Human calls resolve the Pod/Site `rerank` profile; see [Brain](../brain/) for retrieval details). Meanwhile, Pod Applet `ctx.ai` calls run statelessly through `Ankole.Pod.Applets.Gateway` as the selected execution Principal. For language-model profiles (`primary`, `light`, `heavy`, `coding`, `vision_fallback`), Human execution resolves effective Pod/Site defaults and Agent execution resolves that Agent's effective configuration. Usage is attributed to the execution Principal without consuming interactive Agent token quota.

`POST /web_search` takes a `query` of up to 1,024 characters and an optional `limit` from 1 to 100 (default 5). It returns `items`, each with `url`, `title`, and `description` plus `published_at` and `score` when the Provider reports them, and `metadata` with the `query`, the gateway's `latency_ms`, and the HTTP `request_id`. `POST /decisions` answers typed questions about a `state`. A request carries 1 to 64 `questions`, each a `noul` (yes or no), a `choice` among 2 to 255 named options, or a `score` on 2 to 10 ordered levels, and may attach up to four images of at most 4 MiB each. The response returns one answer per question with its probabilities, the `model` that answered, and token `usage`. The `default` / `decision.default` selector resolves the Pod/Site `decision` profile; when that profile is not configured, the caller's `light` language model answers instead. A language model reports its own confidence, so those probabilities are not calibrated, and it accepts at most 500 choice options and score levels in one request.

A decision profile can select TypeSafe (`typesafe`, default `https://api.typesafe.ai/v1`), Azure OpenAI (`azure_openai`) with Microsoft Foundry, OpenRouter (`openrouter`), OpenAI (`openai`), or Cloudflare (`cloudflare`). TypeSafe also accepts a compatible SystemOne `base_url`, Azure Foundry calls `<resource-root>/providers/microsoft/v1/systemone` using its configured deployment, and OpenAI calls `/decisions` with `gpt-6-luna`. TypeSafe, Azure Foundry, and OpenRouter use the SystemOne protocol, which accepts PNG and JPEG assets but not WebP; Microsoft-Decision-1 accepts no images. OpenAI Decisions accepts PNG, JPEG, and WebP. If OpenAI returns a refusal for any question, AIGateway rejects the whole request with `422 upstream_decision_refusal` instead of returning partial answers.

`POST /images` generates or edits one image outside a conversation. The request carries `model` (`image_generate.default`, `default`, or an explicit `provider_id/model`), a `prompt`, optional reference `images` and a `mask`, and the `image_generation` tool options such as `size`, `quality`, and `output_format`. The request goes straight to that image Provider, which is OpenRouter or AgentBull Cloud for the image models in their catalogs, or Cloudflare for FLUX.1 [schnell] and the Black Forest Labs models. The response returns `created`, `data` with one entry that holds the image as `b64_json` together with its `media_type`, and the Provider's `usage`. AIGateway records each generated image and each decision-model call in the usage ledger; Agent token quotas count language-model rounds only. The Console Model usage page shows those tokens and, in a separate table, the calls, the quantity, and the reported cost of every other capability.

`POST /audio/speech` turns `input` text into audio. The request carries `model` (`speech.default`, `default`, or an explicit `provider_id/model`) and may name a `voice`, a `response_format` of `mp3` (the default) or `pcm`, a `speed`, and delivery `instructions`. The response body is the audio itself. Its content type is the audio type that the provider names, or `audio/mpeg` for `mp3` and `audio/pcm` for `pcm` when the provider names none. OpenRouter serves its text-to-speech models, and Cloudflare serves the Deepgram Aura models, which return MP3 and reject `pcm`, `speed`, and `instructions`. With the `amazon-ai-providers` Plugin enabled, an Amazon Web Services provider serves Amazon Polly: the model is the Polly engine, such as `neural`, and a request that names no `voice` uses the voice of the profile. `POST /audio/transcriptions` turns audio into text. The request carries `model` (`transcription.default`, `default`, or an explicit `provider_id/model`) and `input_audio` with base64 `data` that decodes to at most 25 MiB and its `format`, and may add a `language`, a `vad_filter` flag, and a `response_format` of `json` (the default) or `verbose_json`. The response returns `model`, `text`, and `usage` with the `seconds` of audio; `verbose_json` adds the `language`, the `duration`, and timed `segments`. OpenRouter serves its speech-to-text models, and Cloudflare serves the Workers AI models that take base64 audio, such as `@cf/openai/whisper-large-v3-turbo`. Neither endpoint has a fallback: a request fails with `model_profile_not_configured` until its profile is bound. AIGateway records each speech call with its characters and each transcription call with its seconds of audio in the usage ledger.

`POST /ocr` reads a PDF or a document image as Markdown, page by page. The request carries a `document`: a PDF or one PNG, JPEG, or WebP image, as a base64 data URL or as an object with `content_type` and `base64`. AIGateway accepts a PDF of up to 50 MiB and an image of up to 20 MiB, both measured after decoding; an OCR model can accept less. For a PDF, `pages` may list 1 to 100 distinct page indexes, starting at 0; when the request omits `pages`, AIGateway sends none to the OCR model. The response returns `model`, `pages`, and `usage` with the number of `pages`. Each page holds the `index` that the provider reports and its `markdown`, which is empty for a page without text, and AIGateway sorts the pages by `index`. The `default` / `ocr.default` selector resolves the Pod/Site `ocr` profile, which the Mistral provider serves with its OCR models. With the `amazon-ai-providers` Plugin enabled, an Amazon Web Services provider serves Amazon Textract, which reads a PNG or JPEG image or a one-page PDF and takes no `pages`. When that profile is not configured, a language model that accepts images reads the document instead: the caller's `vision_fallback` profile, or `primary` when that profile is not configured. A language model reads one image only, so a PDF fails with `unsupported_value`, and the request counts as an ordinary language-model request. AIGateway records each call of an OCR model with its pages in the usage ledger.

`POST /videos` and `POST /audio/music` start a generation that the Provider finishes later, so they answer `202` with a media job: its `id`, `status`, `model`, `created_at`, and `expires_at`. The request carries `model` (`video.default` or `music.default`, `default`, or an explicit `provider_id/model`) and a `prompt`. A video request may also name `duration` in seconds, `resolution`, `aspect_ratio`, `size`, `generate_audio`, `seed`, and a `first_frame` and `last_frame`, each an `https` URL or a base64 data URL of an image of up to 10 MiB; a music request may name `lyrics`, `instrumental`, and `duration` in seconds. Read the job at `GET /videos/:id` or `GET /audio/music/:id` until its `status` is `completed` or `failed`: a completed job holds the file's `content_type` and `size`, and a failed job holds an `error`. `GET /videos/:id/content` and `GET /audio/music/:id/content` then send the file and accept a `Range` header. AIGateway keeps a job and its file for seven days. The `video` profile can select an OpenRouter (`openrouter`) video model, and the `music` profile a Cloudflare (`cloudflare`) Workers AI partner model such as `minimax/music-2.6` or `elevenlabs/music-v2`. Neither profile has a language-model fallback.

File endpoints are likewise scoped to the authenticated subject: `POST /files` uploads a file, `GET /files` lists uploaded files, `GET /files/:id` and `GET /files/:id/content` fetch metadata and raw bytes, and `DELETE /files/:id` deletes a file.

## What AIGateway is not

AIGateway is not an open, unauthenticated proxy, nor do callers pass upstream provider keys in requests—all provider credentials stay inside the control plane. Multi-step autonomous execution belongs to Sessions and Background Agent Jobs. AIGateway owns model and media calls, including asynchronous media jobs that return `202` for later polling, while resolving selectors and keeping provider credentials server-side.

## Next steps

- For where AIGateway sits in the whole system, read the [architecture overview](../architecture/).
- For running the server that hosts these routes, read the [deployment section of Quick start](../quickstart/#deployment).
- For the first Provider and model-profile setup, read [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent).
