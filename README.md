# BullX — Next Generation AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-48205D?logo=elixir)](https://elixir-lang.org)

[English](./README.md) | [简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

> :warning: **BullX is in early development. This branch is an infra shell after a large subtractive cleanup. Product details are expected to change through design docs.**

BullX is a general-purpose AgentOS built on Elixir/OTP and PostgreSQL for long-running digital work. It can support an enterprise team, a small operating group, or a one-person company with the same core idea: Agents perceive signals, take responsibility for work, act through governed capabilities, remember outcomes, and improve over time.

BullX is not only a chat bot framework and not only an LLM tool runner. The long-term goal is an operating system for durable Agents that can safely participate in real work.

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

BullX is organized around a few durable concepts. The exact table design, process topology, queue names, and provider adapters are not final yet.

- **Installation** — one BullX deployment and operating domain. BullX is general-purpose, but it does not treat SaaS multi-tenancy as the default product boundary.
- **Principal** — an internal subject that can be authorized, audited, and held responsible. Humans, Agents, services, and system actors are all Principals.
- **Agent** — a durable work subject with identity, responsibility, memory, capabilities, permissions, outbound identity, and KPIs. An Agent is not automatically an LLM process or chat bot.
- **Signal** — a normalized statement that something happened. A Signal is not a task.
- **Admission** — the decision that a Signal should enter an Agent's attention space, with a relationship such as owner, observer, reviewer, delegate, subscriber, or blocked.
- **Work / Mission** — long-running responsibility. A Mission is a durable goal; Work is a concrete commitment.
- **Capability** — a governed ability an Agent can use, backed by providers such as reasoning, browser, code, messaging, data, memory, or approval.
- **Intent / Governance / Effect** — Agents propose Intents; Governance decides whether they may become Effects; Effects produce Outcomes and audit records.
- **Brain** — the future ontology and reasoning-memory layer, built around objects, relationships, perspectives, engrams, and consolidation rather than raw vector logs.

## User Stories

### Quietly Watch a Group Conversation

A customer-success Agent can watch a customer group, process risk signals silently, create or update Work, and notify the responsible human privately without speaking in the group by default.

### Admit One Signal to Multiple Agents

The same external event can matter to different Agents in different ways. A message about a customer budget freeze might make CustomerSuccessAgent the owner, FinanceAgent an observer, and unrelated Agents blocked.

### Remember Conversations and External Events Together

A research Agent can combine user conversations with external market, policy, or operational events. Future answers should retrieve context through an ontology-backed world model rather than only searching past chat text.

### Improve from Outcomes

An Agent should learn from repeated results. If a coding Agent often fails when fixture context is missing, later Work planning should explicitly collect fixture context before writing a patch.

### Govern Risky Outbound Actions

Agents should not directly send customer-facing, financial, legal, or otherwise risky effects. They create Intents, Governance classifies risk and approval needs, and only approved Intents become external Effects.

## Design Invariants

- PostgreSQL is the fact source for durable state.
- Process state is ephemeral and reconstructible.
- Processes are failure boundaries, not domain nouns.
- A Signal says what happened; Admission decides who should see it.
- An Agent can process something without replying.
- Capabilities are governed abilities, not raw tool calls.
- Intent comes before Effect.
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
