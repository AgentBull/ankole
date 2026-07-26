---
title: Codex accounts
description: How to manage ChatGPT subscription accounts for CodexRunner background jobs — create, configure, and rotate the accounts that jobs run on.
section: User guide
order: 41
---

A Codex account is a durable ChatGPT subscription account that a Background Agent Job runs on. The default account is `aigateway`, which routes through AIGateway's provider bindings. When a job needs direct CodexRunner access — a different subscription tier, a specific model, rate-limit isolation — you create and configure additional accounts. This page is the operator view of that management surface.

The decisive property, stated up front: a Codex account is **durable configuration, not a credential you type into a job**. The account lives in PostgreSQL, encrypted at rest, and a job references it by its `codex_account_id`. The worker resolves the account's credentials at turn time through a fenced RPC — it never receives the raw credentials as environment variables.

## The default account

Every job carries a `codex_account_id`, and the default is `aigateway`. This account routes through AIGateway's provider bindings — the same providers the agent's model profiles resolve to. For most installations, the default is all you need: jobs run on the same provider chain as conversational turns.

You do not need to create or configure the `aigateway` account; it is the built-in default. Create additional accounts only when a job needs something the default does not provide.

## When to create a separate account

- **Rate-limit isolation** — a long-running research job should not compete with conversational turns for the same rate-limit pool. A separate account gives the job its own.
- **A different subscription tier** — a job that needs a model or reasoning effort the default account's subscription does not cover.
- **Billing separation** — track a specific workload's usage on its own account.

If none of these apply, the default account is correct.

## Create and manage accounts

Through the Console's `/codex-accounts` routes:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/codex-accounts` | List accounts |
| `POST` | `/codex-accounts` | Create an account |
| `PUT` | `/codex-accounts/:account_id` | Update an account |
| `DELETE` | `/codex-accounts/:account_id` | Remove an account |

Creating an account stores the subscription credentials encrypted at rest. The account's auth is resolved at job-run time through `CodexAccountBroker`, which is turn-fenced — the worker receives a time-limited resolved credential, not the stored secret.

## Assign an account to a job

A job's `codex_account_id` field selects the account. The default is `aigateway`; set a different id to route the job to a specific account. This field is on the job schema, so it is set when the job is created (by the agent) and is visible through the Console's `/background-agent-jobs/:id` route.

The agent does not pick the account from a menu — the `codex_account_id` is either the default or set by configuration. The operator's job is to create the accounts; the job picks up the right one through its configuration.

## Rotate credentials

When a subscription credential changes (password rotation, token refresh), update the account through `PUT /codex-accounts/:account_id`. The old credential is overwritten; jobs running on the account pick up the new credential on their next turn. Do not decrypt the old credential to "check" — set the new one, and let the broker resolve it.

## What this guide is not

It is not a ChatGPT subscription tutorial — the subscription itself is OpenAI's product, and the account fields are their API's concern. It is not a job-creation guide — see [Background jobs](../background-jobs-ops/) for the operator view of jobs. And it is not a substitute for the Console API reference; the exact request shapes are there.

## Next steps

- For the job surface, read [Background jobs (operator view)](../background-jobs-ops/).
- For CodexRunner (the engine that uses these accounts), read [Codex integration](../codex-integration/).
- For the Console routes, read the [Console API reference](../console-api/).
