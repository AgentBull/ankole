---
title: Webhook delegations
description: Let an Agent or deterministic script wait for a low-volume external event without polling.
section: User guide
order: 23
---

A webhook delegation lets an Agent wait on external work without polling: when the upstream system detects a matching event, it sends an HTTP `POST` to a short-lived Ankole callback URL. By default, Ankole persists the receipt, wakes the Session that registered the delegation, and delivers the Agent's verified reply back to the originating chat channel. Alternatively, an endpoint can target an Automation Job so a deterministic TypeScript script inspects the receipt first.

Treat the callback URL strictly as a wake-up capability rather than proof that its payload is authentic—before reporting facts or performing authorized mutations, the Agent always re-reads current state directly from the upstream API.

GitHub repository webhooks are the supported built-in workflow.

## When to use it

Use a webhook delegation for low-volume external events that the upstream platform can filter narrowly:

- a GitHub issue, comment, pull request, or Actions workflow run;
- a one-off state change that should resume the originating conversation; or
- a bounded standing watch where handling duplicate deliveries is safe.

Avoid webhook delegations for high-volume firehoses, polling loops, or general enterprise event buses—keep event filtering in the external platform, and keep reasoning, memory, and replies in Ankole.

In chat, specify the desired outcome, allowed actions, target events, and expiration window—for example:

> Watch pull requests in `owner/repository` until Friday. Tell me when a required check fails. Verify the current pull request and check state before you report it. Do not change code unless I ask.

The GitHub Skill handles endpoint creation, webhook registration, reconciliation, and cleanup.

## Requirements

Before an Agent can register a GitHub webhook delegation:

1. Expose a public HTTPS hostname routed to the Ankole control plane that forwards `/webhooks/v1/event-callbacks/*` intact.
2. Enable the **GitHub** Agent Plugin and its member Skills for the Agent (disabled by default).
3. Configure `GITHUB_TOKEN` in the Agent's WorkerEnv with repository read access and repository webhook write access.
4. Start a fresh Agent turn after saving any Agent Library or WorkerEnv changes.

Webhook endpoint CLI commands are available only to the Main Agent during an active turn; Background Agent Jobs do not receive that turn-scoped webhook channel.

## Lifecycle

Each active GitHub delegation pairs a single repository, exact event list, and expiration time with one Ankole callback endpoint, one GitHub repository webhook, and one reconciliation Checkback:

1. The Agent creates a callback endpoint bound to the current conversation.
2. Before touching GitHub, the Agent schedules a durable Checkback so cleanup and reconciliation are guaranteed even if setup is interrupted.
3. The Agent registers the repository webhook on GitHub using the callback URL, triggering GitHub's initial `ping` delivery.
4. The Agent queries GitHub's webhook delivery log to confirm that the `ping` succeeded.
5. Whenever a matching delivery arrives, Ankole commits the endpoint state transition together with either a `webhook.received` Signal or the bound Automation Job run in a single PostgreSQL transaction before returning `2xx`.
6. On the direct Agent path, the woken Agent treats the webhook payload as untrusted input; a bound Automation Job must follow the same rule before calling `emitEvent`.
7. At each scheduled Checkback, the Agent reconciles the GitHub hook, subscribed events, failed deliveries, live GitHub state, expiration time, and next Checkback window.
8. During teardown, the Agent deletes the upstream GitHub webhook first before cancelling the Ankole endpoint and Checkback.

Because GitHub does not automatically retry failed webhook deliveries, the GitHub Skill inspects recent delivery attempts during reconciliation and triggers GitHub's redelivery API whenever a missed event is still relevant.

## One-shot and standing endpoints

| Mode | Contract | Use |
|---|---|---|
| `one_shot` | The first matching delivery claims the endpoint; concurrent or subsequent deliveries return a clean no-op. | Waiting for a single expected event |
| `standing` | Every accepted delivery creates a consumer record (`at-least-once`, with duplicate deliveries visible). | Watching low-volume state transitions over a window |

Because a `standing` endpoint can deliver more than once for the same upstream change, consumers must verify current upstream state and keep their handling idempotent.

## Use a deterministic consumer

When creating an endpoint, the Agent can pass `--automation-job-id <id>` so each accepted `webhook.received` envelope populates `context().event` on a durable Automation Job run instead of waking the conversation model directly. Inside `main.ts`, the script can ignore noisy deliveries silently or call `emitEvent` once a deterministic check passes.

Even inside a script, the webhook body remains untrusted input: verify consequential facts against the authoritative upstream API and keep repeated runs idempotent. Prefer a direct Agent wake-up whenever every delivery requires conversational context, memory, or open-ended judgment. Read [Automation Jobs](../automation-jobs/) for lifecycle details and [Worker CLI capabilities](../cli-capabilities/) for the SDK contract.

## Console

Open **Webhooks** in the Console to view active and expired callback endpoints by Agent and Session—showing each endpoint's label, mode, status, expiration timestamp, and originating chat route while omitting the raw callback URL, plaintext token, and SHA-256 digest.

The **Webhooks** page manages only Agent-created raw callback endpoints bound to a turn's reply route; to manage CloudEvents sources and Signal Routing Rules instead, use the **Signals** page in the Console (see [Signals](../signals/)).

Use **Cancel** in the Console for immediate emergency revocation. Because cancelling the Ankole endpoint does not delete the webhook configured on GitHub, remove the upstream GitHub hook separately—or, during normal teardown, ask the Agent to delete the GitHub hook first.

## Security and delivery limits

- Ankole returns the full `/webhooks/v1/event-callbacks/wh_<token>` URL only once at creation time and stores only its SHA-256 digest in PostgreSQL.
- Control-plane HTTP logs automatically mask `/webhooks/v1/event-callbacks/*` as `/webhooks/v1/event-callbacks/[REDACTED]`; configure your ingress controller, reverse proxy, and CDN to redact that path as well.
- Ankole enforces a `1 MiB` maximum payload size, rejecting larger bodies with HTTP `413` before invoking the body parser.
- Ankole retains only event-metadata headers (`content-type`, `x-hub-signature-256`, `x-github-*`, and `ce-*`), discarding `Authorization` and general HTTP headers.
- Webhook receipts are wrapped inside an explicit untrusted-data boundary before entering model context, with any literal closing delimiter tags escaped.
- Possessing the callback URL authorizes only waking the endpoint—never performing a business mutation, even when a valid `x-hub-signature-256` header is present.

## Troubleshoot

- **The Agent cannot find the GitHub Skill:** Verify that the **GitHub** Agent Plugin and its member Skills are enabled for that Agent, then start a new turn.
- **GitHub deliveries fail to connect:** Check your public TLS certificate, DNS records, ingress rules, and `/webhooks/v1/event-callbacks/*` path forwarding.
- **The GitHub hook is active, but no reply appears in chat:** Check GitHub's webhook delivery log first, then inspect the endpoint status in **Console → Webhooks**, Worker health, Signal admission, and outbound chat delivery.
- **GitHub receives HTTP `413`:** The webhook payload exceeded `1 MiB`; subscribe to narrower GitHub event types or switch to a lighter detection path.
- **The Agent wakes twice for the same GitHub event:** Expected under `standing` mode (`at-least-once` delivery); ensure the Agent checks live GitHub state idempotently.
- **Setup was interrupted after creating the endpoint:** Delete any orphaned webhook on GitHub, cancel the old Ankole endpoint and Checkback, and create a clean replacement.

For the underlying webhook ingress and transaction model, see [Signals](../signals/). For enabling plugins and storing tokens, see [Agent Library](../skills/) and [Environment variables](../worker-env/).
