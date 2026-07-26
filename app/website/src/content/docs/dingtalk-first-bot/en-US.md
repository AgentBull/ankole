---
title: Your first DingTalk bot
description: A complete walkthrough — deploy Ankole, configure a provider, create an agent, bind it to a DingTalk robot over the Stream API, and verify the bot replies in a conversation.
section: Guides
order: 304
---

This guide walks one agent all the way to a working DingTalk bot: an @-mention in a conversation, a real model reply, a verified end-to-end path. By the end you will have an agent you can @-mention in DingTalk, and the confidence that every boundary along the way works.

The flow, in one line: **deploy Ankole → activate and sign in → configure a provider → create an agent → bind it to DingTalk → @-mention the bot → verify the reply.**

This guide mirrors [Your first Lark bot](../lark-first-bot/) — read that first for the shared steps in more depth. The differences are DingTalk-specific: the Stream API transport, the card-template model for streaming replies, and a one-binding constraint that is easy to trip on.

## Prerequisites

- A Linux host or Kubernetes cluster that meets [Platform support](../platform-support/).
- A DingTalk account that can create an enterprise-internal robot in the [DingTalk developer console](https://open-dev.dingtalk.com/).
- An LLM provider API key for a real model turn.

## Step 1: Deploy Ankole

Follow [Installation](../installation/) — Docker Compose on one host, or Helm on Kubernetes. When the stack is healthy, open the HTTPS `/setup` page and read the activation code from the control-plane log. Enter the code. In the plugin step, keep the **DingTalk adapter enabled**.

## Step 2: Create the DingTalk robot

In the DingTalk developer console, create an enterprise-internal robot. The robot gives you a credential pair that does double duty:

| Field | What it is | What it doubles as |
|---|---|---|
| `clientId` | the robot's AppKey | the Stream API `clientId` |
| `clientSecret` | the robot's AppSecret | the Stream API `clientSecret` |

One credential pair authenticates the robot *and* opens the Stream connection that delivers events. Subscribe the robot to the events it needs — DingTalk delivers only @-mention and direct messages to robots by default, so the agent wakes when addressed, not on every group message.

The robot's own id (`robotCode`) defaults to the AppKey for enterprise-internal robots; you usually do not need to set it by hand.

## Step 3: Build the AI card template (for streaming replies)

Ankole delivers streaming replies on DingTalk through a template-hosted AI card. The card layout lives on the DingTalk card platform (卡片平台); Ankole only injects a fixed variable set into card instances. Build this template once per DingTalk organization:

1. Open the card platform → new template → choose the **AI card** category (it carries the native 输入中 / 已完成 / 出错 states Ankole drives through the streaming API).
2. Add the variables documented in the adapter's `priv/card_template/README.md` with exactly those names.
3. Publish the template and copy its `cardTemplateId`.

Paste the `cardTemplateId` into the chat binding in Step 6. If you leave it empty, card streaming is disabled and replies degrade to plain Markdown — usable, but without the streaming states.

## Step 4: Sign in through DingTalk (optional) and enable directory sync

DingTalk can also serve as the admin identity provider, with OIDC and directory sync (`directory_full_sync`, `directory_realtime_sync`). Configure it through the setup flow or `PUT /identity-providers/<provider_id>` with `adapter_id: "dingtalk"`. Directory sync pulls DingTalk organization structure into AuthZ groups.

If you only want the chat bot, skip this step — the chat binding does not depend on it.

## Step 5: Configure a provider, bind profiles, create the agent

Follow [Providers and models](../providers-and-models/) to add a provider and bind the required model profile slots (`primary`, `light`, `heavy`). Follow [Agents](../agents/) to create the agent with `POST /agents` and author at least a `mission` document.

## Step 6: Bind the agent to DingTalk — and mind the one-binding rule

Create the signal binding:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/dingtalk/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "<dingtalk-config-key>", "cardTemplateId": "<template-id>" }'
```

Two DingTalk-specific constraints bite here, and the adapter enforces both:

- **One agent gets at most one enabled DingTalk binding.** A second enabled binding on the same agent fails with `dingtalk_binding_already_exists`. If you want to rebind, disable or delete the old one first.
- **One `clientId` cannot be assigned to two agents.** Reusing the same robot credentials on a second agent fails with `dingtalk_app_already_bound` (the error names the `clientId` and the agent that already holds it). Use a separate robot for each agent.

These exist because the Stream connection is one-per-credential — a robot cannot serve two agents, and an agent does not need two DingTalk bindings. Plan one robot per agent.

## Step 7: Verify the bot replies

Open a conversation with the robot (or @-mention it in a group it has joined). Send a simple prompt:

> 你能做什么？

A working reply means the whole path is sound: the Stream API delivered the event, the signal binding accepted it, the actor woke, the model profile resolved, and the card (or Markdown fallback) rendered. If the bot does not reply, work the order:

1. The latest robot version is published, and the robot is enabled for the test user.
2. `clientId` and `clientSecret` are correct — a bad pair fails the Stream handshake before any event flows.
3. The conversation is one DingTalk will deliver to a robot (an @-mention in a group, or a direct message). DingTalk does not deliver non-mention group messages to robots.
4. The signal binding is enabled and points at this agent — and no other agent holds this `clientId`.
5. The agent has usable model profiles and the provider credentials are valid.
6. If replies look wrong (not just missing), check the `cardTemplateId`: an empty or wrong id degrades to Markdown rather than failing loudly.

Inspect recent worker output without dumping its environment:

```bash
docker logs --tail 200 ankole-dev-agent-computer   # local
kubectl -n ankole logs -l app.kubernetes.io/component=worker --tail=200  # Helm
```

## What is different from the Lark bot

The shape of the walkthrough is the same; the DingTalk-specific pieces are:

- **Stream API, with credentials that double as Stream credentials.** One `clientId`/`clientSecret` pair does both auth and Stream; there is no second token to manage.
- **Template-hosted AI card.** The card layout lives on the DingTalk card platform, and the binding carries the `cardTemplateId`. Empty degrades to Markdown; Lark renders cards in-adapter without a separate template step.
- **The one-binding, one-clientId constraint.** One enabled DingTalk binding per agent, one agent per `clientId`. Lark and Slack do not impose this — plan robots accordingly.

## Where to go next

You now have one agent live in one DingTalk conversation. From here:

- **Give it a rhythm** — add a [schedule](../schedules/) for a daily post.
- **Hand off long work** — let the agent delegate to [background jobs](../background-jobs-ops/), as in the [background research job](../background-research-job/) guide.
- **Federate admin sign-in** — configure DingTalk as the identity provider if you skipped Step 4.
- **More agents** — one robot per agent; repeat Steps 2 and 5–6.

For the operator surface, read [Console operations](../console-operations/). For the adapter internals, read the [DingTalk adapter](../adapters-dingtalk/) page.
