---
title: Codex integration
description: How Ankole runs code-heavy turns through the Codex app-server — the CodexRunner execution engine, the coding model profile slot, Codex accounts managed in Console, and how background agent jobs land on a Codex account. What the operator configures and what the runner owns.
section: User guide
order: 37
---

Codex is how Ankole runs the code-heavy turns. When a turn needs to read and edit code, run tests, or drive a shell, the worker hands the work to the Codex app-server — a JSON-RPC over stdio process — instead of asking the chat model to produce code inline. The glue lives in `app/agent_computer/src/tools/codex/`, and the execution engine behind it is the `CodexRunner`. This page is the operator view: what Codex does in Ankole, where its config and accounts live, and what you tune.

The decisive property, stated up front: Codex is the execution engine for code-heavy work, and it runs on a Codex account you manage through Console. The chat model still owns the conversation; Codex owns the turn that has to touch code.

## What Codex does in Ankole

The worker reaches for Codex when the work is code-heavy: reading a file, editing across files, running a build, iterating on tests. The chat model would do this badly and expensively inline, so the turn is routed to the Codex app-server instead. The pieces, all in `app/agent_computer/src/tools/codex/`:

- **`app-server-client.ts`** — talks to the Codex app-server over JSON-RPC on stdio.
- **`config.ts`** — reads and writes the Codex config at `{codexHome}/config.toml` (line 23).
- **`protocol.ts`** — the JSON-RPC message shapes the client and server exchange.
- **`runtime-config.ts`** — derives the runtime parameters a turn needs.
- **`sandbox.ts`** — the sandbox boundary the code runs inside.

The `CodexRunner` is the execution engine that drives these. It is what a [background agent job](../background-agent-jobs/) runs on when the job has to touch code, isolated from the owning turn.

## The coding model profile slot

An Ankole profile carries named model slots, and the one that serves this code-heavy work is the `coding` slot. When a turn routes to Codex, the `coding` profile slot is what the runner consults. On the primary profile the Codex subscription fields that matter are:

- **`model`** — the model Codex runs.
- **`model_reasoning_effort`** — the reasoning effort, one of `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`.
- **`fast_mode`** — whether the fast path is on.

For the wider model landscape and how slots map to work, read [Providers and models](../providers-and-models/).

## Codex accounts

A Codex turn runs on a Codex account, and those accounts are managed through the Console, not through the worker. The routes are `GET`, `POST`, `PUT`, and `DELETE /codex-accounts`, exposed from the control-plane router. You create an account, point jobs at it, rotate or revoke it, and list what exists — all from the Console surface. For the route shapes and the rest of the Console surface, read [Console operations](../console-operations/) and the [Console API](../console-api/) reference.

## Background agent jobs and Codex

A background agent job runs on a Codex account, and the account is named on the job. The job schema carries a `codex_account_id`, with a default of `"aigateway"`. Two consequences:

1. **A job that needs code execution lands on the account named by `codex_account_id`.** If that account is missing or revoked, the job cannot run; you see the failure through the [background jobs operator surface](../background-jobs-ops/).
2. **The default account `aigateway` is the fallback.** A job that does not name an explicit account runs against it. Make sure it exists and is healthy before you rely on jobs that touch code.

For the job lifecycle, retries, and how to spot a job that failed because its Codex account was unavailable, read [Background jobs (operator view)](../background-jobs-ops/) and [Background agent jobs](../background-agent-jobs/).

## What the operator configures

You touch four things, and only four:

- **The Codex accounts** in Console — create, point jobs at, rotate, revoke.
- **The `coding` profile slot** and its `model`, `model_reasoning_effort`, and `fast_mode` fields on the primary profile.
- **The `codex_account_id` on a background job** when you want it on a specific account.
- **The worker environment** that hosts `{codexHome}` and the `config.toml` it points at.

You do not tune the JSON-RPC protocol, the sandbox boundary, or how the runner derives runtime config. Those are worker internals.

## What the operator does not touch

The app-server client, the JSON-RPC message shapes, the sandbox enforcement, and the runner's internal scheduling are not operator-tunable. If a Codex turn fails, the place to look is the account it ran on and the profile slot it consulted — both Console-side — not a flag inside the worker image. The durable fix for a broken Codex path is in the runner code under `app/agent_computer/src/tools/codex/`, not in an environment variable.

## Next steps

- For the model slots and how `coding` fits the wider profile, read [Providers and models](../providers-and-models/).
- For creating and rotating Codex accounts, read [Console operations](../console-operations/) and the [Console API](../console-api/) reference.
- For the job lifecycle and the `codex_account_id` field, read [Background agent jobs](../background-agent-jobs/) and [Background jobs (operator view)](../background-jobs-ops/).
- For the runner and its tools, read the [Agent Computer](../agent-computer/) developer page.
