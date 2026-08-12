---
title: Console API reference
description: Reference for the /api/v1 REST API that the Console uses, including authentication, resource routes, and authorization actions.
section: Reference
order: 203
---

This page is the REST reference for the Console API: its authentication gate, the routes under `/api/v1`, and the permission action for each route.

The decisive property, stated up front: the Console API is stateless and bearer-authenticated, and it re-confirms the caller is still an active admin on every request. There is no session cookie doing the work for you, and a disabled admin stops working immediately, not on the next login.

Every route under `/api/v1` runs through the `:console_api` pipeline and the `RequireConsoleAccessToken` plug. The plug runs three independent checks, all required:

1. a well-formed `Authorization: Bearer` header;
2. a console JWT that verifies;
3. the principal the JWT names is still an active admin.

On success it stashes the principal and claims as conn assigns for the downstream policy checks; on any failure it halts with `401`. This is the per-request, cookie-free equivalent of what session plus CSRF do for the browser surfaces. There is no second, weaker path into these routes.

## The configuration surfaces

Configuration is organized by what is being configured, not by controller. The surfaces an operator actually drives:

### Providers and model access

A running agent needs a model behind it. The operator wires that through AIGateway's provider surface and the agent's model profiles:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/ai-gateway/provider-kinds` | List the provider kinds this deployment instance can configure |
| `GET` | `/ai-gateway/providers` | List configured providers |
| `GET` | `/ai-gateway/providers/:provider_id` | Read one provider and its credential-pool status |
| `PUT` | `/ai-gateway/providers/:provider_id` | Create or replace a provider |
| `DELETE` | `/ai-gateway/providers/:provider_id` | Remove a provider |
| `POST` | `/ai-gateway/providers/:provider_id/credentials` | Add a credential-pool member |
| `PUT` | `/ai-gateway/providers/:provider_id/credentials/:credential_id` | Update or reauthenticate a pool member |
| `DELETE` | `/ai-gateway/providers/:provider_id/credentials/:credential_id` | Remove a pool member |
| `PUT` | `/ai-gateway/providers/:provider_id/credential-pool/strategy` | Set the pool selection strategy |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login` | Start one ChatGPT device or browser login |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login/poll` | Poll one device login |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | Complete the browser-paste fallback |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | Add an Enterprise access token |
| `GET` | `/agents/:agent_uid/model-profiles` | List an agent's model profiles |
| `PUT` | `/agents/:agent_uid/model-profiles/:profile` | Create or replace a profile |
| `DELETE` | `/agents/:agent_uid/model-profiles/:profile` | Remove a profile |

Provider credentials live as encrypted pool members in the control plane, never in the agent's environment. A model profile binds an agent to a provider and model. AIGateway selects a healthy member inside that provider, and the projection returns only safe account facts, health, rate-limit data, and usage.

### Agents and their capabilities

The agent is the unit an operator configures everything else against:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/agents` | List agents |
| `POST` | `/agents` | Create an agent |
| `GET` | `/agents/:agent_uid` | Read one agent |
| `PATCH` | `/agents/:agent_uid` | Update an agent |
| `DELETE` | `/agents/:agent_uid` | Remove an agent |

### Signal routing rules

A signal routing rule (`Signal Binding` in the API schema) connects a provider adapter to an Agent so shared work can reach it:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/signal-adapters` | List adapters this deployment instance declared |
| `GET` | `/signal-bindings` | List routing rules; `?agent=` filters to one Agent |
| `PUT` | `/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | Create or replace a routing rule |
| `PATCH` | `/agents/:agent_uid/signal-bindings/:binding_name` | Update a routing rule |
| `DELETE` | `/agents/:agent_uid/signal-bindings/:binding_name` | Remove a routing rule |
| `GET` | `/signal-channels/:channel_id/standing-orders` | Read one channel's standing orders |
| `PUT` | `/signal-channels/:channel_id/standing-orders` | Replace one channel's standing orders |

Disabling a binding stops new signals from waking its agent without deleting the binding.

### Agent Library capabilities

The Agent Library is what an agent can do — its plugins and skills. The Console exposes two scopes: a global default, and per-agent overrides:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/agent-library/capabilities` | List global library capabilities |
| `PUT` | `/agent-library/agent-plugins/:id` | Set a plugin's global default state |
| `PUT` | `/agent-library/skills/:id` | Set a skill's global default state |
| `GET` | `/agents/:agent_uid/library-capabilities` | List an agent's effective capabilities |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | Override a plugin for one agent |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | Override a skill for one agent |
| `GET` | `/agents/:agent_uid/library-documents` | List library documents for an agent |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | Set a library document |
| `GET` | `/agents/:agent_uid/library-skill-overlays` | List skill overlays |
| `PUT` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | Set a skill overlay |
| `DELETE` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | Remove a skill overlay |

A capability is enabled globally, then narrowed or widened per agent. Skill overlays let an operator customize how a skill behaves for one agent without forking it.

### Environment variables (WorkerEnv)

An Agent Computer Worker can need environment variables such as API keys and tokens. The Console calls this feature **Environment variables**. The API keeps `WorkerEnv` as its resource name:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/worker-envs` | List named WorkerEnv entries |
| `GET` | `/worker-envs/:name` | Read one entry (metadata, not plaintext) |
| `PUT` | `/worker-envs/:name` | Create or update an entry |
| `DELETE` | `/worker-envs/:name` | Remove an entry |
| `GET` | `/agents/:agent_uid/worker-envs` | List entries attached to an agent |
| `PUT` | `/agents/:agent_uid/worker-envs/:name` | Attach an entry to an agent |
| `DELETE` | `/agents/:agent_uid/worker-envs/:name` | Detach an entry |
| `POST` | `/worker-envs/:name/decryptions` | Decrypt one entry (audited, privileged) |

Decryption is a separate, audited operation. Listing and reading return metadata, not the secret value. A worker receives its environment only when a turn starts; changes take effect on the next turn, not one already running.

### Control Plane Plugins

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/control-plane-plugins` | List Control Plane Plugins and their state |
| `PUT` | `/control-plane-plugins` | Enable or disable plugins |

Control Plane Plugins are the first-party extensions that change what the control plane itself does, such as a signals adapter or a Brain source connector.

### Identity providers and AppConfiguration

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/identity-provider-adapters` | List the IdP adapters this deployment instance supports |
| `GET` | `/identity-providers` | List configured identity providers |
| `PUT` | `/identity-providers/:provider_id` | Create or replace an IdP |
| `POST` | `/identity-providers/:provider_id/sync-runs` | Sync directory groups from an IdP |
| `GET` | `/app-configurations` | List operator-managed configuration keys |
| `PUT` | `/app-configurations/:key` | Set a configuration value |
| `POST` | `/app-configurations/:key/decryptions` | Decrypt one secret configuration value |

`AppConfiguration` is for operator-managed settings — the declared `Ankole.AppConfigure` keys. Bootstrap configuration (process-startup facts and credentials) stays out of it, in environment or secret mounts, as the project boundaries require.

## The read surfaces

Alongside configuration, the Console is the observability path for the rest of the system — each subsystem already documented has its read surface here:

- **Agents in flight**: `/agents/:agent_uid/sessions`, per-session cron schedules and checkbacks.
- **Workers**: `/agent-computer-workers`, with file upload, move, and listing per worker.
- **Jobs**: `/background-agent-jobs` (list, read, cancel).
- **AI activity**: `/ai-gateway/conversations`, with messages per conversation.
- **Memory**: the full `/brain/*` surface — entries, sources, audit log, dreaming runs and fitness, restorations.
- **Principals and AuthZ**: `/principals`, `/principal-groups`, `/permission-grants` — the permission model from the [Principal and AuthZ](../principal-authz/) page.

## A note on what is not here

The `/webhooks/*` and `/api/v1/ai-gateway/*` routes are deliberately not under `console_api`. Webhook ingress authenticates the provider, not an admin; the AIGateway runtime API authenticates an agent or admin token for live AI calls. The Console is the operator's configuration surface, and it is the only surface that trusts an admin bearer token to change how the deployment instance behaves.

## Next steps

- For the runtime surfaces the Console configures, read [AIGateway API](../ai-gateway/), [SignalsGateway](../signals-gateway/), and [Actor Runtime](../actor-runtime/).
- For the permission model the Console itself runs under, read [Principal and AuthZ](../principal-authz/).
- To configure a new deployment instance, read the [deployment section of Quick start](../quickstart/#deployment).
