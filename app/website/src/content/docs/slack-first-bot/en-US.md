---
title: Your first Slack bot
description: A complete walkthrough — deploy Ankole, configure a provider, create an agent, bind it to a Slack app over Socket Mode, and verify the bot replies in a channel.
section: Guides
order: 303
---

This guide walks one agent all the way to a working Slack bot: an @-mention in a channel, a real model reply, a verified end-to-end path. By the end you will have an agent you can @-mention in a Slack workspace, and the confidence that every boundary along the way works.

The flow, in one line: **deploy Ankole → activate and sign in → configure a provider → create an agent → bind it to Slack → @-mention the bot → verify the reply.**

This guide mirrors [Your first Lark bot](../lark-first-bot/) — read that first if you want the shared steps in more depth. The differences are Slack-specific: the Slack app shape, Socket Mode (no public ingress needed), and the token-prefix validation the adapter enforces.

## Prerequisites

- A Linux host or Kubernetes cluster that meets [Platform support](../platform-support/).
- A Slack workspace where you can create an app in the [Slack API dashboard](https://api.slack.com/apps).
- An LLM provider API key for a real model turn.

## Step 1: Deploy Ankole

Follow [Installation](../installation/) — Docker Compose on one host, or Helm on Kubernetes. When the stack is healthy, open the HTTPS `/setup` page and read the activation code from the control-plane log. Enter the code. In the plugin step, keep the **Slack adapter enabled**.

## Step 2: Create the Slack app

In the Slack API dashboard, create a new app from scratch (or reuse an existing one). The adapter requires two tokens, and it validates their prefixes strictly:

| Field | Token type | Prefix rule |
|---|---|---|
| `botToken` | bot user token (xoxb) | must start with `xoxb-` |
| `appToken` | app-level token (xapp) | must start with `xapp-` |

A `botToken` on the wrong prefix (`xapp-…`) fails with `invalid_token_prefix`, and so does an `appToken` that does not start with `xapp-`. Both are required — a missing one fails with `missing`. Generate the `appToken` under *Basic Information → App-Level Tokens*; it is what powers Socket Mode.

Subscribe the app to the events the agent should see — at minimum `app_mention` (so the agent wakes when @-mentioned) and `message.im` (so direct messages reach it). Enable **Socket Mode** in the app settings; this is how Slack delivers events to Ankole without a public ingress endpoint.

Grant the scopes those events need: at least `app_mentions:read`, `chat:write`, and `channels:history` (or `groups:history` / `im:history` for private channels and DMs). Install the app to the workspace to mint the `botToken`.

## Step 3: Sign in through Slack (optional) and enable directory sync

Slack can also serve as the admin identity provider, with the same OIDC + directory-sync capabilities as the other adapters (`oidc_authorization`, `directory_full_sync`, `directory_realtime_sync`). If you want admins to sign into the Console with their Slack account, configure the identity provider through the setup flow or `PUT /identity-providers/<provider_id>` with `adapter_id: "slack"`.

Directory sync pulls Slack workspace membership into AuthZ groups. The adapter owns Slack directory membership projection — Slack is the source of truth, and changes propagate as the adapter syncs. Realtime sync uses the Socket Mode connection (the same `appToken`), so you do not need a second ingress for it.

If you only want the chat bot and not Slack-as-IdP, skip this step — the chat binding does not depend on it.

## Step 4: Configure a provider and bind model profiles

Follow [Providers and models](../providers-and-models/): add a provider row, then bind the agent's required model profile slots — `primary`, `light`, `heavy` — plus any optional slots the agent needs.

## Step 5: Create the agent

Follow [Agents](../agents/). Create the agent with `POST /agents`, note its `uid`, and author at least a `mission` document so the agent knows its scope. A Slack bot benefits from a mission that names the channels it lives in and the kind of help it offers.

## Step 6: Bind the agent to Slack

Create the signal binding that ties this agent to your Slack app:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/slack/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "<slack-config-key>", "unaddressed_group_message_policy": "addressed_only" }'
```

The `config_ref` points at the Slack configuration carrying `botToken` and `appToken`. `addressed_only` is the safest first policy — the agent only wakes on `app_mention`, not on every channel message. See [Signal bindings](../signal-bindings/) for the policy field, and the [Slack adapter](../adapters-slack/) page for what the binding carries.

## Step 7: Verify the bot replies

Invite the bot to a test channel (or open a DM with it). @-mention it with a simple prompt:

> @Ankole what can you do?

A working reply means the whole path is sound: Socket Mode delivered the event over the app-level connection, the signal binding accepted it, the actor woke, the model profile resolved, and the reply posted back through the bot token. If the bot does not reply, work the order:

1. Socket Mode is enabled and the app is installed to the workspace (the `botToken` exists).
2. The `appToken` starts with `xapp-` and the `botToken` starts with `xoxb-` — the adapter rejects the wrong prefixes before any event flows.
3. The bot is in the channel (Slack will not deliver events for a bot that is not a member).
4. The event subscriptions include `app_mention` (and `message.im` for DMs), and the scopes (`app_mentions:read`, `chat:write`, history scopes) are granted.
5. The signal binding is enabled and points at this agent.
6. The agent has usable model profiles and the provider credentials are valid.

Inspect recent worker output without dumping its environment:

```bash
docker logs --tail 200 ankole-dev-agent-computer   # local
kubectl -n ankole logs -l app.kubernetes.io/component=worker --tail=200  # Helm
```

## What is different from the Lark bot

The shape of the walkthrough is the same; the Slack-specific pieces are:

- **Socket Mode, not a webhook ingress.** Slack delivers events over the app-level WebSocket opened with `appToken`. You do not expose a public HTTPS endpoint to Slack, and you do not configure a redirect URL the way Lark's long-connection + OIDC setup does.
- **Two tokens with strict prefix rules.** `botToken` (`xoxb-`) and `appToken` (`xapp-`); the adapter validates both and rejects the wrong prefix.
- **Directory membership ownership.** The Slack adapter owns the membership projection, where Lark projects IM groups; in both cases the chat platform remains the source of truth.

## Where to go next

You now have one agent live in one Slack channel. From here:

- **Let it observe channel conversation** — change the binding's `unaddressed_group_message_policy`, and subscribe `message.channels` so the agent sees non-mention messages.
- **Give it a rhythm** — add a [schedule](../schedules/) for a daily post.
- **Hand off long work** — let the agent delegate to [background jobs](../background-jobs-ops/), as in the [background research job](../background-research-job/) guide.
- **Federate admin sign-in** — configure Slack as the identity provider if you skipped Step 3.

For the operator surface, read [Console operations](../console-operations/). For the adapter internals, read the [Slack adapter](../adapters-slack/) page.
