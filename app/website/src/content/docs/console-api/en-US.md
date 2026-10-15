---
title: Console API reference
description: Reference for the /api/v1 REST API that the Console uses, including authentication, resource routes, and authorization actions.
section: Reference
order: 203
---

The Console REST API uses the browser session cookie. `RequireSiteAdminSession` checks the Console context, Human revocation state, and current site administrator membership on each request. A failed authentication check returns `401`. Requests other than GET and HEAD must send the shell's `x-csrf-token` header; missing or invalid CSRF proof returns `403`.

All paths in the tables are relative to `/api/v1`. Site administration routes use `/site/*` and the `:session_api` + `:site_admin` pipeline. Tenant data routes use the `:session_api` + `:site_admin` + `:data_context` pipeline and `PutDataContext`. For tenant routes, `x-ankole-tenant: <tenant UUID>` selects the data tenant. Without this header, the caller's tenant is used. An invalid, unavailable, or deleting tenant returns `404` with `data_tenant_unavailable`. The header does not change the caller's identity or site administration permission, and does not select a scope for site routes.

The public `/api/v1/openapi.json` document, runtime AI calls, and webhooks have separate authentication rules.

## The configuration surfaces

Configuration is organized by what is being configured, not by controller. The surfaces an operator actually drives:

### Providers and model access

A running agent needs a model behind it. The operator wires that through AIGateway's provider surface and the agent's model profiles:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/site/ai-gateway/provider-kinds` | List the provider kinds this deployment instance can configure |
| `GET` | `/site/ai-gateway/models` | List typed provider models for Console configuration |
| `GET` | `/site/ai-gateway/providers` | List configured providers |
| `GET` | `/site/ai-gateway/providers/:provider_id` | Read one provider and its credential-pool status |
| `PUT` | `/site/ai-gateway/providers/:provider_id` | Create or replace a provider |
| `DELETE` | `/site/ai-gateway/providers/:provider_id` | Remove a provider |
| `POST` | `/site/ai-gateway/providers/:provider_id/credentials` | Add a credential-pool member |
| `PUT` | `/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | Update or reauthenticate a pool member |
| `DELETE` | `/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | Remove a pool member |
| `PUT` | `/site/ai-gateway/providers/:provider_id/credential-pool/strategy` | Set the pool selection strategy |
| `POST` | `/site/ai-gateway/providers/:provider_id/chatgpt-login` | Start one ChatGPT device or browser login |
| `POST` | `/site/ai-gateway/providers/:provider_id/chatgpt-login/poll` | Poll one device login |
| `POST` | `/site/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | Complete the browser-paste fallback |
| `POST` | `/site/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | Add an Enterprise access token |
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
| `POST` | `/agents/:agent_uid/enable` | Re-enable a disabled agent |
| `DELETE` | `/agents/:agent_uid` | Disable an active agent, or permanently delete a disabled one |

### Worker providers

Each Agent selects one Worker provider at creation. The assignment cannot change. A provider stores its YAML configuration and encrypted credentials separately. See [Worker management](../worker-management/) for the lifecycle and storage contract.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/site/worker-provider-kinds` | List provider kinds, YAML examples, and credential requirements |
| `GET` | `/site/worker-providers` | List configured Worker providers |
| `POST` | `/site/worker-providers` | Create a Worker provider |
| `PATCH` | `/site/worker-providers/:provider_id` | Update configuration or credentials |
| `GET` | `/site/worker-providers/:provider_id/check` | Check connection and permissions |
| `DELETE` | `/site/worker-providers/:provider_id` | Delete an unused provider |
| `PUT` | `/agents/:agent_uid/worker-provider` | Assign a provider to a migrated Agent that has none |

### Signal routing rules

A signal routing rule (`Signal Binding` in the API schema) connects a provider adapter to an Agent so shared work can reach it:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/signal-adapters` | List adapters this deployment instance declared |
| `GET` | `/signal-bindings` | List routing rules; `?agent=` filters to one Agent |
| `PUT` | `/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | Create or replace a routing rule |
| `PATCH` | `/agents/:agent_uid/signal-bindings/:binding_name` | Update a routing rule |
| `DELETE` | `/agents/:agent_uid/signal-bindings/:binding_name` | Remove a routing rule |
| `GET` | `/conversations/:conversation_id/standing-orders` | Read one Conversation's standing orders |
| `PUT` | `/conversations/:conversation_id/standing-orders` | Replace one Conversation's standing orders |

Disabling a binding stops new signals from waking its agent without deleting the binding.

### Agent Library capabilities

Library defaults belong to the selected tenant. Agent overrides apply within that tenant.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/agent-library/capabilities` | List tenant library capabilities |
| `PUT` | `/agent-library/agent-plugins/:id` | Set a plugin's tenant default state |
| `PUT` | `/agent-library/skills/:id` | Set a skill's tenant default state |
| `GET` | `/agents/:agent_uid/library-capabilities` | List an agent's effective capabilities |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | Override a plugin for one agent |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | Override a skill for one agent |
| `GET` | `/agents/:agent_uid/library-documents` | List library documents for an agent |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | Set a library document |
| `GET` | `/agents/:agent_uid/skill-lessons` | List active and retired Skill lessons |
| `POST` | `/agents/:agent_uid/skill-lessons` | Add a human Skill lesson to an enabled Skill |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Retire a Skill lesson |

A capability is enabled for the tenant, then narrowed or widened per agent. Skill lessons give one Agent additional process guidance without changing the Skill source. The list includes evidence and retirement history. A retired lesson stops being delivered, and Dreaming keeps human-retired content on its never-relearn list. See [Skill lessons](../skill-lessons/) for the lifecycle and limits.

### Environment variables (WorkerEnv)

WorkerEnv values have site defaults, tenant overrides, and Agent attachments. The following routes return metadata; plaintext requires the separate audited decryption operation.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/site/worker-envs` | List site defaults |
| `PUT` | `/site/worker-envs/:name` | Set a site default |
| `DELETE` | `/site/worker-envs/:name` | Remove a site default |
| `POST` | `/site/worker-envs/:name/decryptions` | Decrypt a site value |
| `GET` | `/worker-envs` | List tenant values |
| `PUT` | `/worker-envs/:name` | Set a tenant value |
| `DELETE` | `/worker-envs/:name` | Remove a tenant value |
| `POST` | `/worker-envs/:name/decryptions` | Decrypt a tenant value |
| `GET` | `/agents/:agent_uid/worker-envs` | List Agent attachments |
| `PUT` | `/agents/:agent_uid/worker-envs/:name` | Attach or override a value for an Agent |
| `DELETE` | `/agents/:agent_uid/worker-envs/:name` | Remove an Agent attachment |
| `POST` | `/agents/:agent_uid/worker-envs/:name/decryptions` | Decrypt an Agent value |

An Agent attachment uses its own value or inherits the tenant value, then the site default. Environment values are resolved when Worker work starts. An existing workspace keeps its captured environment.

### Control Plane Plugins

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/site/control-plane-plugins` | List Control Plane Plugins and their state |
| `PUT` | `/site/control-plane-plugins` | Enable or disable plugins |

Control Plane Plugins are the first-party extensions that change what the control plane itself does, such as a signals adapter.

### Identity providers and AppConfiguration

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/identity-provider-adapters` | List the IdP adapters this deployment instance supports |
| `GET` | `/identity-providers` | List configured identity providers |
| `PUT` | `/identity-providers/:provider_id` | Create or replace an IdP |
| `POST` | `/identity-providers/:provider_id/sync-runs` | Sync directory groups from an IdP |
| `GET` | `/site/app-configurations` | List site configuration keys |
| `PUT` | `/site/app-configurations/:key` | Set a site value |
| `POST` | `/site/app-configurations/:key/decryptions` | Decrypt a site secret |
| `GET` | `/app-configurations` | List operator-managed configuration keys |
| `PUT` | `/app-configurations/:key` | Set a configuration value |
| `POST` | `/app-configurations/:key/decryptions` | Decrypt one secret configuration value |

`AppConfiguration` stores declared operator settings at site or tenant scope. `/site/app-configurations` manages site keys; `/app-configurations` manages tenant keys. Both support listing, reading one key, setting, deleting an override, and audited decryption. Bootstrap credentials and startup facts remain in environment variables or secret mounts.

### Tenant administration

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/site/tenants` | List tenants |
| `POST` | `/site/tenants` | Create a tenant |
| `PATCH` | `/site/tenants/:tenant_id` | Update a tenant |
| `DELETE` | `/site/tenants/:tenant_id` | Request tenant deletion |
| `PUT` | `/site/tenants/:tenant_id/suspension` | Suspend a tenant |
| `DELETE` | `/site/tenants/:tenant_id/suspension` | Resume a tenant |
| `GET` | `/site/privileged-tenant` | Read the privileged tenant |
| `PUT` | `/site/privileged-tenant` | Transfer site administration to another tenant |

## The read surfaces

Alongside configuration, the Console is the observability path for the rest of the system — each subsystem already documented has its read surface here:

- **Agents in flight**: `/agents/:agent_uid/sessions`, per-Agent cron schedule and checkback management; the list endpoints are tenant-wide with an `agent` filter.
- **Workers**: `/agent-computer-workers` lists the Worker state for each Agent.
- **Agent drives**: `/agents/:agent_uid/files` lists, uploads, and deletes files; `/agents/:agent_uid/files/content` downloads a file; `/agents/:agent_uid/file-moves` moves a file. The control plane owns these files.
- **Jobs**: `/background-agent-jobs` (list, read, cancel).
- **AI activity**: `/ai-gateway/conversations`, with messages per conversation.
- **Principals and AuthZ**: `/principals`, `/principal-groups`, `/permission-grants` — the permission model from the [Principal and AuthZ](../principal-authz/) page.

## A note on what is not here

`/webhooks/*` authenticates the provider. Runtime `/api/v1/ai-gateway/*` calls use AIGateway authentication. Console configuration routes use the session and CSRF checks described above.

## Next steps

- For the runtime surfaces the Console configures, read [AIGateway API](../ai-gateway/), [Signals](../signals/), and [Sessions](../sessions/).
- For the permission model the Console itself runs under, read [Principal and AuthZ](../principal-authz/).
- To configure a new deployment instance, read the [deployment section of Quick start](../quickstart/#deployment).
