# BullX — Next Generation AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-48205D?logo=elixir)](https://elixir-lang.org)

[English](./README.md) | [简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

> :warning: **BullX is in early development. This branch is an infra shell after a large subtractive cleanup. Product details are expected to change through design docs.**

BullX is a general-purpose AgentOS built on Elixir/OTP and PostgreSQL for long-running digital work. It can support an enterprise team, a small operating group, or a one-person company with the same core idea: resumable DAG workflows coordinate AI Agents, integrations, explicit Action Nodes, memory, and recorded results over time.

BullX is not only a chat bot framework and not only an LLM tool runner. The long-term goal is an operating system for durable workflows where AI Agents and other Action Nodes can safely participate in real work.

## Current State

This branch intentionally keeps only the infrastructure shell:

- Elixir/OTP application boot and supervision
- PostgreSQL Repo and dynamic configuration
- UUIDv7 and native helper boundary
- i18n catalog infrastructure with empty product copy
- Phoenix, Inertia, Rsbuild, UIKit, and a placeholder setup SPA
- health endpoints and OpenAPI description plumbing
- reusable packages under `packages/`

The removed product surface should not be restored piecemeal. New product behavior should come from design docs.

## Product Direction

BullX is organized around resumable DAG workflows with streaming support. The exact table design, process topology, queue names, and provider adapters are not final yet.

- **Installation** — one BullX deployment and operating domain. BullX is general-purpose, but it does not treat SaaS multi-tenancy as the default product boundary.
- **Principal** — an internal subject that can be authorized, audited, and held responsible. Humans, Agents, services, and system actors are all Principals.
- **Workflow** — a resumable directed acyclic graph of Signal Triggers and Action Nodes. Durable workflow state records enough progress to retry, pause, resume, and recover after process restarts.
- **Signal Trigger** — a workflow start or ingress point that normalizes something that happened. Provider adapters, webhooks, schedules, and routing are modeled as Signal Triggers instead of standalone product layers.
- **Action Node** — a workflow step that performs work. Non-AI behavior such as transforms, approvals, notifications, and blackholes is an Action Node, not an Agent.
- **Sink Action Node** — an Action Node with `sink=true`. It terminates its branch, so no downstream Action Node is valid below it. A blackhole/drop branch is also a Sink Action Node.
- **Streaming Input / Streaming Output** — per-node flags. Streaming Input means the node can consume incremental upstream data; Streaming Output means the node can emit incremental downstream data.
- **Bidirectional Trigger / Reply to Trigger** — when a Signal Trigger has `bidirectional=true`, the DAG may use one special `Reply to Trigger` Action Node. It is always `sink=true`.
- **Agent** — an AI Agent, modeled as an Action Node when it executes inside a workflow. It has identity, responsibility, memory, allowed providers, permissions, outbound identity, and KPIs, but it is no longer the generic name for every executable actor.
- **Work** — a durable work responsibility that persists across Workflow runs. A Workflow run is one execution that may create, advance, pause, resume, or complete Work.
- **Brain** — the future ontology and reasoning-memory layer, built around objects, relationships, perspectives, engrams, and consolidation rather than raw vector logs.

## User Stories

### Quietly Watch a Group Conversation

A messaging Signal Trigger can start a workflow from a customer group event. A customer-success Agent Action Node can analyze risk, create or update Work, and notify the responsible human privately without speaking in the group by default.

### Start Multiple Branches from One Signal Trigger

The same external event can matter to different Agents in different ways. A message about a customer budget freeze can fan out to a CustomerSuccessAgent branch, a FinanceAgent branch, and a blackhole Sink Action Node for irrelevant branches.

### Remember Conversations and External Events Together

A research Agent can combine user conversations with external market, policy, or operational events. Future answers should retrieve context through an ontology-backed world model rather than only searching past chat text.

### Improve from Results

An Agent Action Node should learn from repeated results. If a coding Agent often fails when fixture context is missing, later Work planning should explicitly collect fixture context before writing a patch.

### Gate Risky Outbound Actions

Risky customer-facing, financial, legal, or otherwise sensitive external actions should pass through explicit approval or policy-gate Action Nodes before any side-effecting Action Node runs.

## Design Invariants

- PostgreSQL is the fact source for durable state.
- Process state is ephemeral and reconstructible.
- Processes are failure boundaries, not domain nouns.
- Workflows are resumable DAGs, not linear chat sessions.
- Provider adapters and routing are modeled as Signal Triggers.
- Action Nodes declare whether they support Streaming Input, Streaming Output, or both.
- A Sink Action Node is terminal; no downstream Action Node is valid below `sink=true`.
- `Reply to Trigger` exists only for `bidirectional=true` Signal Triggers and is always a sink.
- Reliability comes from durable checkpoints, retries, idempotent node contracts, and operator recovery rather than a blanket strict exactly-once guarantee.
- Side-effecting Action Nodes are explicit workflow nodes, not hidden raw tool calls.
- Risky external writes or messages must pass through explicit approval or policy-gate Action Nodes before execution.
- Important behavior must be auditable, explainable, and recoverable.
- Memory should evolve through reasoning and consolidation, not accumulate as an unstructured log.

## Development

**Prerequisites:** Elixir 1.19+, PostgreSQL, Bun

Make sure PostgreSQL is running and `DATABASE_URL` in `.env.dev` or `.env.local` points at it.

```sh
# Bootstrap Elixir deps, JS deps, database, and assets
bun setup

# Start Phoenix and the Rsbuild development asset server
bun dev
```

Open `http://localhost:4000`. The current app shell redirects `/` to `/setup`, which is only a placeholder on this branch.

In development, Phoenix starts Rsbuild as an endpoint watcher. The browser entry point remains `http://localhost:4000`; Rsbuild listens on `http://localhost:5173` for React/Inertia hot reload. If those ports are already in use, set `PORT` and `RSBUILD_PORT` in `.env.local`, for example `PORT=4001` and `RSBUILD_PORT=5174`.

Useful project commands:

```sh
# Install/update JS dependencies
bun install

# Run the full project check used before committing
bun precommit

# Run frontend tests and cross-language lint checks
bun run test
bun run lint
```

## Rsbuild Asset Builds

The React/Inertia app entry is `webui/src/app.jsx`, with SPA pages under `webui/src/apps/`. For deployable assets, Rsbuild writes `priv/static/assets/.rsbuild/manifest.json`, and Phoenix resolves scripts and styles from that manifest outside development.

Run Bun from the repository root; Rsbuild uses `webui/src/` for application source and `assets/css/` for the Phoenix CSS entry.

```sh
# Build Rsbuild assets and manifest
mix assets.build

# Build production assets, including digests
mix assets.deploy
```

`mix assets.deploy` runs compilation, the Rsbuild build, and `phx.digest`. Run it before building a production release.

**Production:**

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/bullx/bin/bullx start
```

## Environment Files

BullX loads dotenv files from the repository root. Later files override earlier ones; variables already present in the OS environment take precedence over dotenv values.

| Environment | Load order |
|---|---|
| Development | `.env` -> `.env.dev` -> `.env.local` |
| Test | `.env` -> `.env.test` |
| Production | `.env` -> `.env.prod` |

`.env.local` is gitignored and intended for machine-specific secrets. `.env`, `.env.dev`, and `.env.test` may be committed as shared non-secret team defaults.
