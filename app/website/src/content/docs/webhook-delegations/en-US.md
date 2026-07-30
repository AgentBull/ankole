---
title: Webhook delegations
description: Let an Agent or deterministic script wait for a low-volume external event without polling.
section: User guide
order: 23
---

A webhook delegation lets an Agent wait for work that runs outside Ankole. The external system detects an event and calls a short-lived Ankole callback URL. By default, Ankole stores the receipt, wakes the session that created the delegation, and returns the Agent's verified result through the original chat route. An endpoint can instead name an automation job when a deterministic script must consume the receipt first.

The callback is a wake-up capability. It is not proof that the request body is true. The Agent reads the current external object before it reports a fact or makes an authorized change.

GitHub repository webhooks are the first supported scenario. EventBridge and Flink are not implemented.

## When to use it

Use a webhook delegation for a low-volume event that an external system can filter well:

- a GitHub issue, comment, pull request, or workflow run;
- a one-time event that should wake the same conversation;
- a standing watch where repeated handling is safe.

Do not use it for a high-volume stream, a polling loop, or a general event bus. Keep detection in the external system. Keep judgment, memory, and the reply in Ankole.

Describe the outcome, authority, event set, and end time in the request. For example:

> Watch pull requests in `owner/repository` until Friday. Tell me when a required check fails. Verify the current pull request and check state before you report it. Do not change code unless I ask.

The GitHub Skill owns the setup and recovery details.

## Requirements

Before the Agent creates a GitHub delegation:

1. Route a public HTTPS host to the Ankole control plane. The host must preserve `/webhooks/v1/event-callbacks/*`.
2. Enable the public **GitHub** Agent Plugin and its required Skills for the Agent. GitHub is disabled by default.
3. Add `GITHUB_TOKEN` to the Agent's WorkerEnv. The token needs read access to the target repository and write access to repository webhooks.
4. Start a new Agent turn after you change the capability or WorkerEnv settings.

The endpoint commands are available only to the Main Agent during an active turn. A Background Agent Job does not have the turn-local webhook connection.

## Lifecycle

One live GitHub delegation has one repository, one exact event set, one expiry, one Ankole endpoint, one GitHub hook, and one reconciliation checkback.

1. The Agent creates an endpoint for the current conversation.
2. It creates a durable checkback before it creates the GitHub hook. This records the cleanup and reconciliation obligation.
3. It creates the repository hook with the callback URL. GitHub sends a `ping`.
4. It reads the GitHub delivery log and confirms that the `ping` succeeded.
5. When a matching delivery arrives, Ankole commits the endpoint decision and either the `webhook.received` ActorEvent or the bound automation job run in one PostgreSQL transaction before it returns success.
6. On the direct path, the woken Agent treats the receipt as untrusted input. A bound automation job must apply the same rule before it emits an event.
7. Reconciliation checks the hook, event set, failed deliveries, current GitHub objects, expiry, and next check time.
8. Teardown removes the GitHub hook before it cancels the Ankole endpoint and checkback.

GitHub does not automatically retry a failed webhook delivery. The GitHub Skill checks recent deliveries and uses GitHub's redelivery API when the failure is still relevant.

## One-shot and standing endpoints

| Mode | Contract | Use |
|---|---|---|
| `one_shot` | One concurrent delivery claims the endpoint. Later deliveries receive a successful no-op. | One expected receipt |
| `standing` | Every accepted delivery creates one record for the selected consumer. Delivery is at least once and duplicates are visible. | Low-volume edge events |

A standing delivery can create more than one consumer record. The consumer uses the current external state as authority and keeps repeated handling idempotent.

## Use a deterministic consumer

The Agent can pass `--automation-job-id <id>` when it creates an endpoint. The accepted `webhook.received` envelope then becomes `context().event` for a durable automation job run instead of waking the conversation directly. A script can discard an irrelevant receipt silently or call `emitEvent` after it completes a deterministic check.

The receipt remains untrusted input. The script must verify consequential facts at an authoritative source and must make repeated delivery harmless. Use a direct Agent wake when the delivery needs memory, judgment, or conversation. Read [Worker CLI capabilities](../cli-capabilities/) for the SDK and failure contract.

## Console

Open **Webhooks** in the Console to inspect endpoints by Agent and session. The page shows the label, mode, state, expiry, and source route. It does not show the callback URL, plaintext token, or stored digest.

The Console can list and cancel endpoints. It cannot create one. Creation needs the current conversation route, so it belongs to an active Agent turn.

Cancel from the Console when you need emergency credential revocation. This does not delete the external GitHub hook. Remove that hook separately. For normal teardown, ask the Agent to remove the GitHub hook first.

## Security and delivery limits

- Ankole returns the full callback URL once. PostgreSQL stores only its SHA-256 digest.
- Ankole request logs replace `/webhooks/v1/event-callbacks/*` with `/webhooks/v1/event-callbacks/[REDACTED]`. Configure the ingress, proxy, and CDN to redact the same path.
- The callback body limit is 1 MiB. An oversized request returns `413` before the normal body parser runs.
- Ankole keeps only event metadata headers: `content-type`, `x-hub-signature-256`, `x-github-*`, and `ce-*`. It discards authorization and general request headers.
- The Agent sees a bounded receipt inside an untrusted-data boundary. A literal closing tag in external data is escaped.
- The callback URL authorizes only a wake-up. It does not authorize a business effect, even when a signature header is present.

## Troubleshoot

- **The Agent cannot find the GitHub Skill:** confirm that the GitHub Agent Plugin and Skills are enabled for this Agent, then start a new turn.
- **GitHub cannot reach the callback:** check the public HTTPS certificate, DNS, ingress route, and `/webhooks/v1/event-callbacks/*` forwarding.
- **The hook exists but no Agent reply appears:** inspect the GitHub delivery log, the endpoint state in Console, Worker readiness, the durable actor event, and outbound chat delivery.
- **GitHub reports `413`:** the selected event payload is larger than 1 MiB. Narrow the event shape at GitHub or use another detector.
- **The same event wakes the Agent twice:** this is valid for a standing endpoint. The Agent must re-read current GitHub state and make repeated handling safe.
- **The callback URL was lost during setup:** remove any matching GitHub hook, cancel the old endpoint and checkback, then create one replacement.

For the ingress owner and transaction boundary, read [SignalsGateway](../signals-gateway/). For capability settings, read [Agent Library](../skills/) and [Environment variables](../worker-env/).
