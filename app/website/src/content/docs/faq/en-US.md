---
title: FAQ & troubleshooting
description: Common questions and the first places to look when a local Ankole setup does not behave.
section: Getting started
order: 4
---

Short answers to the questions that come up most often, and a troubleshooting order for when the local environment will not start. The repository [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) stays the deeper source of truth — this page points at it where it matters.

## Frequently asked questions

### Is Ankole a chatbot backend?

No. A chatbot optimizes the single turn. Ankole optimizes the seat: an agent that holds an ongoing job, reads shared context, and is judged by the result. The runtime is closer to a distributed operating system for long-running AI work than a request/response backend. See the [architecture overview](../architecture/) for the full model.

### Is my data sent anywhere?

Model calls go only to the LLM provider you configure. Memory, configuration, credentials, and audit live in your own infrastructure, behind your control plane. Nothing leaves the installation except the traffic you point at a provider.

### What does a self-hosted installation need?

A control plane, one or more Agent Computer workers, PostgreSQL 18 or later with `pg_search` preloaded, and persistent Agent Home storage. The two supported packages — Docker Compose for one host, Helm for Kubernetes — handle all of it. See the [installation guide](../installation/).

### Can I run agents from more than one entry point?

Yes. Three entry surfaces are first-class: shared work enters through SignalsGateway (chat, webhooks, schedules), applications and enterprise systems call AIGateway directly over an OpenResponses-compatible HTTP, SSE, and WebSocket API, and operators reach in through the Console and APIs.

### Do agents survive a worker restart?

Yes. A session is a virtual actor with a durable mailbox, checkpoints, and recovery path in PostgreSQL. A Background Agent Job survives worker loss, can resume or wait for input, and wakes its owner session when its state changes. Workers are replaceable execution substrate, not the source of truth.

### Is there a public API compatibility contract?

Not yet. The public APIs work end to end in production, but they do not carry a compatibility contract today, so expect breaking changes between releases until that changes.

## Troubleshoot from the first broken boundary

Always start with the first error in the `bun dev` terminal. Later errors are usually consequences of an earlier compile, database, port, or worker failure — chasing the second error first wastes time.

### Docker or PostgreSQL does not start

```bash
docker info
bun run services:status
docker ps --filter name=ankole
```

Start Docker Desktop, or fix Linux Docker permissions, before changing project code. Do not delete a Docker volume because a single startup failed.

### The local database is genuinely damaged and disposable

The rebuild command deletes the local `ankole_dev` database. Run it only after you have confirmed the data can be lost:

```bash
bun run kit app-db rebuild --yes
bun run control-plane:setup
```

A failed migration or an unfamiliar Ecto error is not automatic permission to rebuild the database.

### The page does not open

```bash
curl -I http://localhost:4000/
lsof -nP -iTCP:4000 -sTCP:LISTEN
lsof -nP -iTCP:3035 -sTCP:LISTEN
lsof -nP -iTCP:6010 -sTCP:LISTEN
```

Resolve the first process conflict or compile failure. Do not change the documented ports without also updating every dependent callback and worker endpoint.

### The activation code is missing

Click reprint on the page, read the `bun dev` terminal, then fall back to:

```bash
bun run kit show bootstrap-activation-code
```

Do not guess the code from browser internals or database rows.

### Feishu reports a redirect mismatch

The setup identity step shows the login callback URL of this installation before the browser goes to the provider. Register that URL in the provider developer console without changes. It is the request origin that the control plane receives plus the provider ID, which gives this local default:

```text
http://localhost:4000/sessions/oidc/lark-main/callback
```

A different Provider ID gives a different callback URL. Change it in the provider at the same time.

### DingTalk login reports that the application does not exist

The DingTalk login service cannot resolve this Client ID. The error code is `900103`. It appears at the moment of the jump, before the request reaches the callback URL, so do not start with the callback URL. Check in this order:

1. The value is the app **Client ID** from Basic information > Credentials. It is not the AgentId, not the robot code, and not the webhook token of a group custom robot.
2. The app has the permissions that Ankole calls: `Contact.User.Read` for the login profile, `Contact.User.mobile` for the phone number, `qyapi_get_member`, `qyapi_get_department_list`, `qyapi_get_department_member`, and the field permissions for phone number and email. When a permission is missing, the DingTalk server API answers with sub-code `60011` and gives the link that grants it.
3. Release a version in Application release > Version management after each permission or configuration change. An unreleased change has no effect.

Valid credentials do not exclude this error. A Client ID and Client Secret that get an app access token can still get `Application does not exist` on the login page. Setup checks the credentials before the jump, so a form that accepts the credentials and still reaches this error points at the permissions or the release state of the app, not at the values.

### DingTalk reports a wrong callback URL after the code scan

DingTalk does not check `redirect_uri` when it opens the authorization page. It checks the value after the user scans the code and accepts. Register the callback URL under Development configuration > Security settings > Redirect URL before the first login. The URL is the one that the setup identity step shows.

### Login works but the bot does not reply

Work through these boundaries in order:

1. The latest Feishu app version is published and the bot capability is enabled.
2. The test user and chat are in scope, and the bot is in the chat.
3. Message, CardKit, event, and callback permissions are active.
4. The Signal binding is enabled and points at the intended agent.
5. The agent has usable model profiles and the provider credentials are valid.
6. `local-dev-worker` is ready.

Inspect recent worker output without dumping its environment:

```bash
docker logs --tail 200 ankole-dev-agent-computer
```

If the primary model profile is unavailable, check the Console's Agents and Providers pages before blaming Feishu ingress.

### A newly saved worker secret is unavailable

Worker environment changes take effect on new turns. Send a new message after saving the value; do not judge the change from a turn that was already running.

## Next steps

- For the full environment, setup, and acceptance detail, read [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md).
- For production deployment, read the [installation guide](../installation/).
