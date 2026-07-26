---
title: Console operations
description: The operator's task index — sign in through the bearer gate, then follow the task paths for providers, agents, bindings, secrets, plugins, and live observability.
section: User guide
order: 11
---

The Console is where an operator turns a running Ankole installation into a working one. Behind the React shell is one stateless REST API, and this page is the task index for it — what the gate is, and which path to take for each operator job. The full route tables and OpenAPI shapes live in the [Console API reference](../console-api/) on the developer side; this page stays on what you do, not on each field.

The decisive property, stated up front: the Console API is stateless and bearer-authenticated, and it re-confirms the caller is still an active admin on every request. There is no session cookie doing the work for you, and a disabled admin stops working immediately, not on the next login.

## Sign in: the bearer gate

Every Console request runs through the `:console_api` pipeline and the `RequireConsoleAccessToken` plug. Three independent checks, all required, on every call:

1. a well-formed `Authorization: Bearer` header;
2. a console JWT that verifies;
3. the principal the JWT names is still an active admin.

Any failure halts with `401`. There is no second, weaker path into these routes — no session fallback, no cookie that carries over. Signing in means obtaining a console JWT and presenting it on every request.

## Task paths

The Console organizes configuration by what is being configured, not by controller. Pick the job; the topic page carries the exact fields.

### Wire up models

An agent needs a model behind it. Configure the AI provider, then bind a model profile to the agent.

- **Add or replace a provider** — `PUT /ai-gateway/providers/:provider_id`. Provider credentials stay in the control plane; never put them in the agent's environment. The full route table is in the [Console API reference](../console-api/).
- **Bind a model profile to an agent** — `PUT /agents/:agent_uid/model-profiles/:profile`. A profile binds an agent to a selector; AIGateway resolves the selector to a provider at call time.

### Create and configure agents

The agent is the unit everything else configures against.

- **Create an agent** — `POST /agents`.
- **Set its persona documents** — `PUT /agents/:agent_uid/library-documents/:document_kind`, where `document_kind` is `mission`, `soul`, or `design`. These are the runtime docs the agent reads on every turn.
- **Enable or override its capabilities** — see the [Agent Library](../agent-library/) developer page for the default-then-override model; the operator surface is `/agents/:agent_uid/library-capabilities/*`.

### Connect shared work: signal bindings

A signal binding ties a provider adapter to an agent so chats, webhooks, and events can reach it. See the per-adapter pages under the User guide for the provider-specific prerequisites (app ids, tokens, webhook URLs, event subscriptions).

- **List available adapters** — `GET /signal-adapters`.
- **Create or replace a binding** — `PUT /agents/:agent_uid/signal-bindings/:adapter_id/:binding_name`.
- **Disable without deleting** — `PATCH` the binding's `enabled` flag. Disabling stops new signals from waking the agent; it does not delete the binding.

### Manage secrets the worker needs

WorkerEnv is the encrypted shell-environment store. Secrets live here, not in plaintext config, and they reach the worker only when a turn starts.

- **Add or rotate a global secret** — `PUT /worker-envs/:name`.
- **Attach a secret to one agent** — `PUT /agents/:agent_uid/worker-envs/:name`.
- **Reveal a secret** — `POST /worker-envs/:name/decryptions`. This is a separately authorized action; browsing the list never exposes plaintext.
- For the merge model, encryption, and the "next turn, not this turn" rule, read [WorkerEnv secrets](../worker-env/).

### Enable first-party plugins

Control Plane Plugins are enabled through one global list, applied on the next process start.

- **See what is active and what is staged** — `GET /control-plane-plugins`.
- **Stage a plugin for the next start** — `PUT /control-plane-plugins`. The change does not take effect immediately; restart Ankole to apply it.
- For why activation is a boot-time concern, read [Control Plane Plugins](../control-plane-plugins/).

### Configure admin sign-in

Operators federate admin identity through an identity provider.

- **List supported IdP adapters** — `GET /identity-provider-adapters`.
- **Configure an IdP** — `PUT /identity-providers/:provider_id`.
- **Sync directory groups** — `POST /identity-providers/:provider_id/sync-runs`.

## Observe the running installation

The Console is also the read surface for the rest of the system:

- **Agents in flight** — `/agents/:agent_uid/sessions`, per-session cron schedules and checkbacks.
- **Workers** — `/agent-computer-workers`, with per-worker file upload, move, and listing.
- **Background jobs** — `/background-agent-jobs` (list, read, cancel). A job in `waiting_on_user` has released its running slot and waits for a human reply; the retry budget is bounded (at most five execution attempts). For the lifecycle internals, read [Background Agent Jobs](../background-agent-jobs/).
- **AI activity** — `/ai-gateway/conversations`, with messages per conversation.
- **Memory** — the full `/brain/*` surface: entries, sources, audit log, dreaming runs and fitness, restorations.
- **Principals and AuthZ** — `/principals`, `/principal-groups`, `/permission-grants`.

## What is not here

The `/webhooks/*` and `/api/v1/ai-gateway/*` routes are deliberately not under `console_api`. Webhook ingress authenticates the provider, not an admin; the AIGateway runtime API authenticates an agent or admin token for live AI calls. The Console is the operator's configuration surface, and it is the only surface that trusts an admin bearer token to change how the installation behaves.

## Next steps

- For the full route tables and policy actions, read the [Console API reference](../console-api/).
- For the adapter-specific setup pages, browse the User guide section.
- For the subsystems these routes configure, start at the [architecture overview](../architecture/).
