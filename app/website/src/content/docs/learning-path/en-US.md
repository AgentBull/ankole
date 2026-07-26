---
title: Learning path
description: Pick a path through the Ankole documentation by what you are trying to do — install and run, configure an agent, operate the installation, or understand the internals.
section: Getting started
order: 0
---

Ankole can do a lot — host shared AI colleagues, wire up chat platforms, run long-lived background work, hold durable memory. This page helps you decide where to start based on what you are trying to accomplish, not on how much you already know.

If you have not installed Ankole yet, begin with [Introduction](../introduction/), then [Quick start](../quickstart/) or [Installation](../installation/). Everything below assumes a running installation.

## How to use this page

- **Know your goal?** Jump to [By use case](#by-use-case) and find the scenario that matches.
- **Want the operator's whole path?** Read [By role](#by-role) in order.
- **Contributing or debugging the system itself?** Go to [For contributors](#for-contributors).

## By role

| Role | Goal | Reading order | Effort |
|---|---|---|---|
| **New operator** | Get one agent live in a chat channel | [Introduction](../introduction/) → [Quick start](../quickstart/) → [Installation](../installation/) → [Providers and models](../providers-and-models/) → [Agents](../agents/) → an adapter page (e.g. [Lark](../adapters-lark/)) | a few hours |
| **Running operator** | Configure, observe, and operate the installation day to day | [Console operations](../console-operations/) → [Signal bindings](../signal-bindings/) → [WorkerEnv secrets](../worker-env/) → [Schedules](../schedules/) → [Background jobs](../background-jobs-ops/) → [Platform support](../platform-support/) → [Updating](../updating/) | ongoing |
| **Security / identity owner** | Own admin sign-in, directory sync, and permissions | [Principal and AuthZ](../principal-authz/) → [Console API reference](../console-api/) → the identity-provider section of your adapter page | a few hours |
| **Contributor** | Work on Ankole itself | [Architecture](../architecture/) → the subsystem pages under Developer guide → [kit CLI reference](../kit-cli/) → [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) | days |

## By use case

Pick the scenario that matches. Each lists the docs in the order you should read them.

### "I want one agent live in a chat channel"

The most common first deployment: an agent that answers in Lark, Slack, DingTalk, Microsoft 365, or Google Workspace.

1. [Installation](../installation/) — deploy with Compose or Helm.
2. [Providers and models](../providers-and-models/) — wire a model behind the agent.
3. [Agents](../agents/) — create the agent and set its persona.
4. [Signal bindings](../signal-bindings/) — connect the agent to a provider adapter.
5. The adapter page for your platform: [Lark](../adapters-lark/), [DingTalk](../adapters-dingtalk/), [Slack](../adapters-slack/), [Microsoft 365](../adapters-microsoft-365/), [Google Workspace](../adapters-google-workspace/).
6. [FAQ](../faq/) — when the bot does not reply, troubleshoot from the first broken boundary.

### "I want admin sign-in through my identity provider"

Federate Console admin access through Lark, Entra ID, or Google Workspace.

1. [Installation](../installation/) — complete the first product setup, choosing the identity provider.
2. [Principal and AuthZ](../principal-authz/) — the permission model admin sign-in sits inside.
3. Your adapter page's "identity provider" section — [Lark](../adapters-lark/), [Microsoft 365](../adapters-microsoft-365/), [Google Workspace](../adapters-google-workspace/).
4. [Console API reference](../console-api/) — the identity-provider and sync-runs routes.

### "I want the agent to work on long tasks in the background"

Hand off work that takes too long, too many steps, or too much isolation to run inline.

1. [Agents](../agents/) — the agent that owns the jobs.
2. [Background jobs (operator view)](../background-jobs-ops/) — states, `waiting_on_user`, retry budget, cancel.
3. [Background Agent Jobs](../background-agent-jobs/) — the lifecycle and recovery model, when you need the internals.

### "I want the agent to wake on a schedule"

Give an agent a recurring rhythm, or let it defer and self-wake.

1. [Schedules](../schedules/) — cron schedules on a session, pause/resume/manual run, checkbacks.
2. [Signal bindings](../signal-bindings/) — the binding a schedule fires through.

### "I want the agent to remember across turns and channels"

Give an agent durable, reviewed memory.

1. [Brain](../brain/) — curated knowledge, recall, dreaming, oversight.
2. [Console operations](../console-operations/) — the `/brain/*` read and review surface.

### "I want to understand how Ankole works"

Read the system, not operate it.

1. [Architecture](../architecture/) — the five technical bets and the component map.
2. [SignalsGateway](../signals-gateway/) → [Actor Runtime](../actor-runtime/) → [AIGateway](../ai-gateway/) — the path a signal takes to a model turn.
3. [Brain](../brain/), [Background Agent Jobs](../background-agent-jobs/), [Agent Computer](../agent-computer/), [Kernel](../kernel/) — the subsystems.
4. [Principal and AuthZ](../principal-authz/) — the permission boundary.

## For contributors

Contributing to Ankole itself is a different goal from operating it.

1. [Quick start](../quickstart/) — run Ankole locally from source.
2. [kit CLI reference](../kit-cli/) — the devkit commands (`kit dev`, `kit app-db`, `kit analyze`).
3. [Architecture](../architecture/) and the Developer-guide subsystem pages.
4. [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) — the source of truth for setup, troubleshooting, and acceptance.
5. [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md) — the repository-wide ownership and discipline rules.

## Reference shelf

When you need a fact, not a path:

- [Environment variables](../environment-variables/) — bootstrap env, runtime tuning, AppConfigure keys.
- [kit CLI reference](../kit-cli/) — every `kit` command.
- [MCP server reference](../mcp/) — how MCP servers are declared and loaded.
- [Console API reference](../console-api/) — the REST surface.
- [Platform support](../platform-support/) — supported deployment targets and dev hosts.
