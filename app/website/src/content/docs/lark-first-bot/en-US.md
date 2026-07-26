---
title: Your first Lark bot
description: A complete walkthrough — deploy Ankole, configure a provider, create an agent, bind it to a Lark self-built app, and verify the bot replies in a chat.
section: Guides
order: 300
---

This guide walks one agent all the way to a working Lark (or Feishu) bot: a message in a chat, a real model reply, and a verified end-to-end path. By the end you will have an agent you can @-mention in a Lark conversation, and the confidence that every boundary along the way works.

The flow, in one line: **deploy Ankole → activate and sign in → configure a provider → create an agent → bind it to Lark → @-mention the bot → verify the reply.**

## Prerequisites

- A Linux host or Kubernetes cluster that meets [Platform support](../platform-support/).
- A Lark or Feishu account that can create an enterprise custom application in the [Feishu Open Platform](https://open.feishu.cn/) (or Lark's equivalent).
- An LLM provider API key for a real model turn.

This guide reuses the operator pages for each step and links out to them rather than repeating the field tables. Open them in tabs as you go.

## Step 1: Deploy Ankole

Follow [Installation](../installation/) — Docker Compose on one host, or Helm on Kubernetes. When the stack is healthy, open the HTTPS `/setup` page. Read the activation code from the control-plane log:

```bash
# Compose
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
# Helm
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane | grep "SETUP ACTIVATION CODE"
```

Enter the code. In the plugin step, keep the **Feishu/Lark adapter enabled**. If the Feishu identity-provider option does not appear, restart the control plane once and return to setup.

## Step 2: Create the Lark self-built app

In the Feishu Open Platform, create an enterprise custom application, enable its **bot capability**, and include your test user in the app's availability scope. Use a name like `Ankole Local` so the test app is not confused with a production one.

Add the OIDC redirect URL to the app's security settings:

```text
http://localhost:4000/sessions/oidc/lark-main/callback
```

For a production host, use your real HTTPS origin instead of `localhost`. `localhost` and `127.0.0.1` are different redirect URIs — use the documented form unless you also update the allowlist entry.

Grant the baseline message scopes so the bot can read and reply: `im:message:send_as_bot`, `im:message:readonly`, `im:message:update`, `im:message.group_at_msg:readonly`, `im:message.p2p_msg:readonly`, `im:resource`. If your binding will let the agent observe group messages it was not addressed in, also grant `im:message.group_msg`. Publish an initial app version — unpublished settings do not apply to the test user.

## Step 3: Sign in through Lark and enable directory sync

Back in the Ankole setup flow, create the Feishu identity provider:

| Field | Value |
|---|---|
| Provider ID | `lark-main` |
| Domain | Feishu (or Lark, for the international domain) |
| App ID | the test application's App ID |
| App Secret | the test application's App Secret |
| OIDC | Enabled |
| Directory sync | Enabled |
| WebSocket incremental sync | Enabled |

Save the provider and complete OIDC login. The first successful user becomes this installation's root administrator, and the activation code expires. Saving the provider also opens the outbound WebSocket long-connection from the control plane — it needs internet access, but no public IP, reverse proxy, or tunnel.

In Feishu's Events and Callbacks page, choose the **long-connection** option and add the events the agent should see: `im.message.receive_v1` for messages, plus the `contact.user.*` and `contact.department.*` events if you want directory sync. Feishu may reject long-connection events before it detects the client — if so, keep the control plane running and retry.

## Step 4: Configure a provider and bind model profiles

The agent needs a model behind it. Follow [Providers and models](../providers-and-models/):

1. Add a provider row: `PUT /ai-gateway/providers/<provider_id>` with your LLM credentials.
2. Create the agent (next step), then bind at least the three required model profile slots — `primary`, `light`, `heavy` — to selectors on that provider.

## Step 5: Create the agent

Follow [Agents](../agents/). Create the agent with `POST /agents`, note its `uid`, and author at least a `mission` document so the agent knows its scope:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/library-documents/mission \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "content": "You are a helpful assistant in our Lark workspace. Answer concisely." }'
```

Bind the model profiles to this agent now (Step 4's second half).

## Step 6: Bind the agent to Lark

Create the signal binding that ties this agent to your Lark app:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/lark/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "<lark-config-key>", "unaddressed_group_message_policy": "addressed_only" }'
```

The `config_ref` points at the Lark chat configuration (the `appID`/`appSecret`/`domain` triple from Step 2). `addressed_only` is the safest first policy — the agent only wakes when directly @-mentioned, not on every group message. See [Signal bindings](../signal-bindings/) for the policy field, and the [Lark adapter](../adapters-lark/) page for what the binding carries.

## Step 7: Verify the bot replies

Add the bot to a test group or open a direct message with it. @-mention it with a simple prompt:

> @Ankole Local what can you do?

A working reply means the whole path is sound: the long-connection delivered the event, the signal binding accepted it, the actor woke, the model profile resolved, and the CardKit reply rendered. If the bot does not reply, do not chase the second error first — work the [FAQ](../faq/) order:

1. The latest app version is published and the bot capability is enabled.
2. The test user and chat are in scope, and the bot is in the chat.
3. The message scopes (`im:message:send_as_bot`, `im:message:readonly`, …) are active.
4. The signal binding is enabled and points at this agent.
5. The agent has usable model profiles and the provider credentials are valid.
6. The worker (`ankole-dev-agent-computer` locally) is ready.

Inspect recent worker output without dumping its environment:

```bash
docker logs --tail 200 ankole-dev-agent-computer   # local
kubectl -n ankole logs -l app.kubernetes.io/component=worker --tail=200  # Helm
```

## What you have, and where to go next

You now have one agent live in one Lark channel — the smallest end-to-end Ankole deployment that proves the model. From here:

- **More agents or channels** — repeat Steps 5–6 for each. One adapter per binding, one agent can hold several bindings.
- **Let it observe group conversation** — change the binding's `unaddressed_group_message_policy` off `addressed_only`, and grant `im:message.group_msg`.
- **Give it a rhythm** — add a [schedule](../schedules/) so the agent posts a daily summary.
- **Hand off long work** — let the agent delegate to [background jobs](../background-jobs-ops/).

For the operator surface you used in each step, read [Console operations](../console-operations/). For the adapter internals, read the [Lark adapter](../adapters-lark/) page.
