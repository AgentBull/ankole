---
title: Webhook delegations
description: Receive external events through Connector subscriptions or Job and Agent callback endpoints.
section: User guide
order: 23
---

External events can reach Ankole through a Connector subscription or a raw callback endpoint. Both create durable deliveries before acknowledging acceptance, and a binding can route the event to an Agent or an Applet Job.

## Choose an event source

Use the Pod **Connections** page for supported platform subscriptions, such as GitHub repository or organization events and Lark approval or calendar changes. An administrator configures the application; a member supplies personal authorization when the subscription needs it. Select the resource, create the subscription, and inspect its status. The control plane creates, adopts, and removes the upstream subscription. A failed operation remains visible with an explicit retry action.

Use a raw callback when another service can POST to a URL you supply. In an Applet's Automation panel, create a webhook for a Job, choose `standing` or `one_shot`, and set its expiry. The callback URL is shown once. Copy it to the sender and send a test event. Agent-created callbacks remain available through `create-webhook-cli --help` for work that should resume a conversation.

## Delivery and ownership

A `one_shot` endpoint accepts its first matching delivery; later deliveries do not start another execution. A `standing` endpoint accepts deliveries until paused, revoked, or expired. Keep consumers safe for repeated upstream events and inspect authoritative source state before consequential actions.

Job-owned endpoints deliver to the Applet Action without requiring an Agent session or task prompt. The handler reads `ctx.signal`; the Automation panel links delivery receipts to Run status, input, result, and logs. Personal endpoints follow their Job owner's authority; team endpoints follow Page permissions. Removing a Job cleans up its owned endpoints. Removing a consumer from a shared Connector subscription does not delete the subscription needed by others.

## Operate and troubleshoot

Pause an endpoint to stop accepting work while keeping its configuration. Resume it when ready; revoke or delete it to retire the callback. Cancelling an Ankole raw endpoint does not delete a separately configured webhook at the sender. Connector-managed subscriptions use their own remote reconciliation lifecycle.

Confirm public HTTPS routing to `/webhooks/v1/event-callbacks/*` for raw callbacks and `/webhooks/connectors/*` for Connector callbacks. Protect the raw capability URL: Ankole stores its digest and masks it in control-plane logs; configure upstream proxies to mask it too. Possession of the URL permits event submission, not proof that the event's claims are true.

If a delivery fails, check the sender's log, endpoint expiry and status, subscription authorization, then the receipt and Run. An accepted event with a failed Run needs execution repair; repeatedly sending it does not repair missing consent or invalid input.

See [Automation Jobs](../automation-jobs/) and [Signals](../signals/).
