---
title: Console API reference
description: Reference for the /api/v2 APIs that the Console uses, including authentication, resource routes, and authorization actions.
section: Reference
order: 203
---

The Console API authenticates requests using multi-account browser sessions: sealed session cookies in `Cookie` paired with `x-ankole-authentication` to select the active account. On every request, `RequireSiteAdminSession` resolves the active administrator session, verifies Human access status, and binds the `Ankole.AuthZ` actor (`console_rest`), while `Ankole.AuthZ.Authorizer` checks each Ash action against `site_console:**` and `tenant_console:**` permissions. Ankole returns `401` if authentication fails. Every request other than `GET` and `HEAD` must also carry the Console shell's `x-csrf-token` header; Ankole returns `403` whenever CSRF proof is missing or invalid, or when `Ankole.AuthZ` denies the action.

Console configuration, aggregate read views, and audited secret operations live under `/api/v2`: site-administration routes sit under `/api/v2/site`, while tenant routes operate on the selected data tenant. The tables below give every full path.

Send v2 requests with `Content-Type: application/vnd.api+json` matching each operation's OpenAPI schema. Standard resource create and update requests wrap fields in `data.type` and `data.attributes`, whereas generic actions place their arguments directly under `data` and may return a typed object rather than a JSON:API resource document—for example, `PUT /api/v2/worker-envs/EXAMPLE` accepts `{"data":{"value":"example","secret":false}}` and returns a `worker_env` object. List routes that declare keyset pagination accept `page[limit]` and `page[after]`.

On tenant-scoped routes, pass `x-ankole-tenant: <tenant UUID>` to select the target data tenant, or omit the header to use the caller's own tenant. If the requested tenant is invalid, unavailable, or being deleted, Ankole returns `404` with `data_tenant_unavailable`. Passing `x-ankole-tenant` never alters the caller's Principal identity or site-administration permissions, and site-scoped routes ignore it.

`/api/v2/openapi.json` and `/api/v2/site/openapi.json` publish the Console and site-administration schemas behind the same authentication checks. Other browser JSON:API scopes publish separate OpenAPI 3.1 documents at `/api/v2/pod/openapi.json` (Pod workspace and `/api/v2/pod/admin/*` routes for `pod_admin`) and `/api/v2/browser/openapi.json` (browser authentication and first-run setup). File uploads and downloads use the native `/api/v2` multipart and byte-stream routes listed below, while runtime AI calls, OIDC protocol flows, and inbound webhooks use their own dedicated contracts.

## The configuration surfaces

Routes are grouped by the domain resource being configured rather than by internal controller. Below are the surfaces that operators manage:

### Providers and model access

Every active Agent needs at least one model behind it, wired through AIGateway's provider endpoints and the Agent's model profiles:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/site/ai-gateway/provider-kinds` | List the provider kinds that this deployment instance can configure |
| `GET` | `/api/v2/site/ai-gateway/models` | List typed provider models for Console configuration |
| `GET` | `/api/v2/site/ai-gateway/providers` | List configured providers |
| `GET` | `/api/v2/site/ai-gateway/providers/:provider_id` | Read one provider and its credential-pool status |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id` | Create or replace a provider |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id` | Remove a provider |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials` | Add a credential-pool member |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | Update or reauthenticate a pool member |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | Remove a pool member |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credential-pool/strategy` | Set the pool selection strategy |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login` | Start one ChatGPT device or browser login |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/poll` | Poll one device login |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | Complete the browser-paste fallback |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | Add an Enterprise access token |
| `GET` | `/api/v2/agents/:agent_uid/model-profiles` | List an agent's model profiles |
| `PUT` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | Create or replace a profile |
| `DELETE` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | Remove a profile |

Provider credentials stay encrypted as pool members inside the control plane—never inside an Agent's Worker environment. Model profiles bind an Agent to a provider row and model, leaving AIGateway to pick a healthy pool member while API read projections expose only non-secret account metadata, health state, rate-limit status, and usage totals.

### Agents and their capabilities

The Agent is the central identity that capabilities, profiles, and routing rules attach to:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/agents` | List agents |
| `POST` | `/api/v2/agents` | Create an agent |
| `GET` | `/api/v2/agents/:agent_uid` | Read one agent |
| `PATCH` | `/api/v2/agents/:agent_uid` | Update an agent |
| `POST` | `/api/v2/agents/:agent_uid/enable` | Re-enable a disabled agent |
| `DELETE` | `/api/v2/agents/:agent_uid` | Disable an active agent, or permanently delete a disabled one |

### Worker providers

When creating an Agent, you assign one Worker provider permanently—the binding cannot be changed afterward. Each provider stores its YAML configuration separately from its encrypted platform credentials; see [Worker management](../worker-management/) for lifecycle and storage rules.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/site/worker-provider-kinds` | List provider kinds, YAML examples, and credential requirements |
| `GET` | `/api/v2/site/worker-providers` | List configured Worker providers |
| `POST` | `/api/v2/site/worker-providers` | Create a Worker provider |
| `PATCH` | `/api/v2/site/worker-providers/:provider_id` | Update configuration or credentials |
| `GET` | `/api/v2/site/worker-providers/:provider_id/check` | Check connection and permissions |
| `DELETE` | `/api/v2/site/worker-providers/:provider_id` | Delete an unused provider |
| `PUT` | `/api/v2/agents/:agent_uid/worker-provider` | Assign a provider to a migrated Agent that has none |

### Signal routing rules

A signal routing rule (`Signal Binding` in the API schema) connects an external channel adapter to an Agent so incoming messages and events can wake it:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/signal-adapters` | List adapters that this deployment instance declared |
| `GET` | `/api/v2/signal-bindings` | List routing rules; `?agent=` filters to one Agent |
| `PUT` | `/api/v2/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | Create or replace a routing rule |
| `PATCH` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | Update a routing rule |
| `DELETE` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | Disable a routing rule |
| `GET` | `/api/v2/conversations/:conversation_id/standing-orders` | Read one Conversation's standing orders |
| `PUT` | `/api/v2/conversations/:conversation_id/standing-orders` | Replace one Conversation's standing orders |

Disabling a binding stops new Signals from waking its Agent without deleting the stored configuration.

### Agent Library capabilities

Library defaults apply at the selected tenant level, with optional overrides per Agent within that tenant:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/agent-library/capabilities` | List tenant library capabilities |
| `PUT` | `/api/v2/agent-library/agent-plugins/:id` | Set a plugin's tenant default state |
| `PUT` | `/api/v2/agent-library/skills/:id` | Set a skill's tenant default state |
| `GET` | `/api/v2/agents/:agent_uid/library-capabilities` | List an agent's effective capabilities |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/agent-plugins/:id` | Override a plugin for one agent |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/skills/:id` | Override a skill for one agent |
| `GET` | `/api/v2/agents/:agent_uid/library-documents` | List library documents for an agent |
| `PUT` | `/api/v2/agents/:agent_uid/library-documents/:document_kind` | Set a library document |
| `GET` | `/api/v2/agents/:agent_uid/skill-lessons` | List active and retired Skill lessons |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons` | Add a human Skill lesson to an enabled Skill |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Retire a Skill lesson |

Operators set tenant defaults first and then narrow or widen capabilities per Agent. Alongside capabilities, Skill lessons supply Agent-specific procedural guidance without modifying the base Skill files, exposing supporting evidence and retirement history; retiring a lesson stops delivery immediately, and Dreaming keeps human-retired lessons on its never-relearn list. See [Skill lessons](../skill-lessons/) for lifecycle rules and limits.

### Environment variables (WorkerEnv)

WorkerEnv entries layer site defaults, tenant overrides, and per-Agent attachments. Standard list and update routes return metadata only—revealing plaintext requires calling the separate audited `decryptions` endpoint:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/site/worker-envs` | List site defaults |
| `PUT` | `/api/v2/site/worker-envs/:name` | Set a site default |
| `DELETE` | `/api/v2/site/worker-envs/:name` | Remove a site default |
| `POST` | `/api/v2/site/worker-envs/:name/decryptions` | Decrypt a site value |
| `GET` | `/api/v2/worker-envs` | List tenant values |
| `PUT` | `/api/v2/worker-envs/:name` | Set a tenant value |
| `DELETE` | `/api/v2/worker-envs/:name` | Remove a tenant value |
| `POST` | `/api/v2/worker-envs/:name/decryptions` | Decrypt a tenant value |
| `GET` | `/api/v2/agents/:agent_uid/worker-envs` | List Agent attachments |
| `PUT` | `/api/v2/agents/:agent_uid/worker-envs/:name` | Attach or override a value for an Agent |
| `DELETE` | `/api/v2/agents/:agent_uid/worker-envs/:name` | Remove an Agent attachment |
| `POST` | `/api/v2/agents/:agent_uid/worker-envs/:name/decryptions` | Decrypt an Agent value |

An Agent attachment uses its explicit Agent override when present, or inherits the tenant value and then the site default. Ankole resolves WorkerEnv values when Worker execution begins, so an already open workspace keeps the environment captured when it opened.

### Control Plane Plugins

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | List Control Plane Plugins and their state |
| `PUT` | `/api/v2/site/control-plane-plugins` | Enable or disable plugins |

Control Plane Plugins are compiled first-party extensions that register control-plane capabilities such as Signals adapters, Identity Provider adapters, AIGateway providers, and Worker providers. Plugins declared with `activation: :always` stay enabled with the build, whereas `PUT /api/v2/site/control-plane-plugins` toggles `:optional` plugins for the next control-plane restart after running subsystem `veto_disable` checks so plugins backing active resources (such as a configured Worker provider) cannot be turned off.

### Identity providers and AppConfiguration

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/identity-provider-adapters` | List the IdP adapters that this deployment instance supports |
| `GET` | `/api/v2/identity-providers` | List configured identity providers |
| `PUT` | `/api/v2/identity-providers/:provider_id` | Create or replace an IdP |
| `POST` | `/api/v2/identity-providers/:provider_id/sync-runs` | Sync directory groups from an IdP |
| `GET` | `/api/v2/site/app-configurations` | List site configuration keys |
| `PUT` | `/api/v2/site/app-configurations/:key` | Set a site value |
| `POST` | `/api/v2/site/app-configurations/:key/decryptions` | Decrypt a site secret |
| `GET` | `/api/v2/app-configurations` | List operator-managed configuration keys |
| `PUT` | `/api/v2/app-configurations/:key` | Set a configuration value |
| `POST` | `/api/v2/app-configurations/:key/decryptions` | Decrypt one secret configuration value |

`AppConfiguration` stores declared runtime settings at site scope (`/api/v2/site/app-configurations`) or tenant scope (`/api/v2/app-configurations`), supporting listing, single-key reads, updates, override resets, and audited decryption. Bootstrap credentials and pre-database startup facts live in environment variables or secret mounts instead.

### Tenant administration

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/site/tenants` | List tenants |
| `POST` | `/api/v2/site/tenants` | Create a tenant |
| `PATCH` | `/api/v2/site/tenants/:tenant_id` | Update a tenant |
| `DELETE` | `/api/v2/site/tenants/:tenant_id` | Request tenant deletion |
| `POST` | `/api/v2/site/tenants/:tenant_id/suspension` | Suspend a tenant |
| `DELETE` | `/api/v2/site/tenants/:tenant_id/suspension` | Resume a tenant |
| `GET` | `/api/v2/site/privileged-tenant` | Read the privileged tenant |
| `PATCH` | `/api/v2/site/privileged-tenant` | Transfer site administration to another tenant |

## The read surfaces

Alongside configuration, `/api/v2` provides operational read surfaces across every subsystem:

- **Agents in flight**: `/api/v2/agents/:agent_uid/sessions`, plus per-Agent cron schedule and checkback management (list routes are tenant-wide with an `?agent=` filter).
- **Workers**: `/api/v2/agent-workers` lists the current Worker state for each Agent.
- **Agent drives**: `/api/v2/agents/:agent_uid/files` lists and deletes files, `/api/v2/agents/:agent_uid/file-moves` moves or renames a file, `POST /api/v2/agents/:agent_uid/files` uploads multipart files, and `GET /api/v2/agents/:agent_uid/files/content` streams file bytes—all governed by the same browser session, CSRF check, tenant header, and AuthZ file permissions on the control-plane file store.
- **Jobs**: `/api/v2/background-agent-jobs` lists, inspects, and cancels Background Agent Jobs.
- **AI activity**: `/api/v2/ai-gateway/conversations` lists stateful model threads and their per-turn messages.
- **Principals, AuthZ, and OIDC clients**: `/api/v2/principals` (including `PATCH /api/v2/principals/:uid/membership`, `POST /api/v2/principals/:uid/access-disables`, and `POST /api/v2/principals/:uid/access-restorations`), `/api/v2/principal-groups`, `/api/v2/permission-grants`, and `/api/v2/oidc-clients`—see [Principal and AuthZ](../principal-authz/).

## A note on what is not here

Inbound `/webhooks/*` routes authenticate external webhook senders directly, and runtime `/api/v1/ai-gateway/*` routes use AIGateway bearer tokens; only `/api/v2` Console routes enforce the browser session and CSRF checks documented above.

## Next steps

- For the runtime surfaces that the Console configures, read [AIGateway API](../ai-gateway/), [Signals](../signals/), and [Sessions](../sessions/).
- For the permission model that the Console itself runs under, read [Principal and AuthZ](../principal-authz/).
- To configure a new deployment instance, read the [deployment section of Quick start](../quickstart/#deployment).
