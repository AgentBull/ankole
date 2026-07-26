---
title: Agents
description: How to create and manage an agent — its identity, persona documents, model profiles, capabilities, and the bindings that connect it to shared work.
section: User guide
order: 13
---

An agent is the unit everything else in Ankole configures against. Provider bindings, model profiles, signal bindings, library capabilities, and background jobs all attach to one. This page is the operator's path through an agent's life: create it, give it a persona, wire up its models, enable its capabilities, and connect it to shared work.

The decisive property, stated up front: an agent is a durable Principal with a stable `uid`. Everything you configure against it — profiles, documents, bindings — points at that uid, so renaming a display name never breaks a binding.

## Create an agent

```bash
curl -X POST https://ankole.example.com/api/v1/agents \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "display_name": "Release notes bot" }'
```

The response carries the agent's `uid`, which you use in every later route. List agents with `GET /agents`, read one with `GET /agents/:agent_uid`, update its profile fields with `PATCH /agents/:agent_uid`, and remove one with `DELETE /agents/:agent_uid`. Removing an agent is destructive — its bindings, profiles, and library state go with it — so disable its signal bindings first if you only want it quiet.

## Give it a persona

An agent reads three runtime documents on every turn, and you author them through the library-documents surface:

| Document | Purpose |
|---|---|
| `mission` (`MISSION.md`) | what the agent is for, its scope and responsibilities |
| `soul` (`SOUL.md`) | how the agent speaks and behaves — tone, style, guardrails |
| `design` (`DESIGN.md`) | the working agreements and constraints the agent must honor |

Set one with:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/library-documents/mission \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "content": "You are the release-notes bot. You watch merged PRs..." }'
```

These are the agent's own writable files — they live in its `/agents/<key>/` workspace and are read by the Agent Computer on every turn. List them with `GET /agents/:agent_uid/library-documents`. Write them in plain prose; the agent treats them as authoritative context, not as instructions to obey blindly.

## Wire up its models

An agent without models cannot run. Bind at least the three required profile slots — `primary`, `light`, `heavy` — and any optional slots the agent needs (`embedding`, `web_search`, `coding`, and so on). The full slot list and the provider-configuration step are in [Providers and models](../providers-and-models/).

## Enable its capabilities

The agent's capabilities — which Agent Plugins and skills it can use — come from the Agent Library. The model is default-then-override: capabilities have installation-wide defaults, and you narrow or widen them per agent.

- See the agent's effective capabilities: `GET /agents/:agent_uid/library-capabilities`.
- Override a plugin for one agent: `PUT /agents/:agent_uid/library-capabilities/agent-plugins/:id`.
- Override a skill for one agent: `PUT /agents/:agent_uid/library-capabilities/skills/:id`.
- Customize how a skill behaves for this agent without forking it: `PUT /agents/:agent_uid/library-skill-overlays/:skill_name`.

For the default-then-override model and what "enabled" means at turn time, read the [Agent Library](../agent-library/) developer page.

## Connect it to shared work

An agent with models and capabilities but no signal binding is an agent no one can reach. A signal binding ties a provider adapter — Lark, DingTalk, Slack, Microsoft 365, Google Workspace — to the agent, so messages, webhooks, and events become actor events it wakes on. See [Signal bindings](../signal-bindings/) and the per-adapter pages under the User guide.

## Observe an agent in flight

Once an agent is wired up and receiving signals, the Console shows what it is doing:

- **Sessions** — `GET /agents/:agent_uid/sessions` lists the long-running sessions for the agent, each one an actor keyed by `{agent_uid, session_id}`.
- **Per-session schedules** — `/agents/:agent_uid/sessions/:session_id/cron-schedules` and `.../checkbacks` show the scheduled and deferred work on a session.
- **Background jobs** — `/background-agent-jobs` shows the durable jobs the agent has spawned; filter to the agent to see only its own.
- **Conversations** — `/ai-gateway/conversations` shows the model calls recent turns made, which is the fastest way to see whether the agent is resolving the models you configured.

## A note on the agent Principal

An agent is a Principal — the same accountable-subject shape a human admin is. Its authority is granted and evaluated through AuthZ like any other Principal, and disabling the agent Principal removes its authority across the installation. The operator surface for that is `/principals`; the model is in the [Principal and AuthZ](../principal-authz/) developer page.

## Next steps

- For model profile binding, read [Providers and models](../providers-and-models/).
- For connecting the agent to a chat platform, read [Signal bindings](../signal-bindings/) and the adapter pages.
- For the routes, read the [Console API reference](../console-api/).
