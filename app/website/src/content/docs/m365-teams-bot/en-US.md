---
title: Your first Microsoft Teams bot
description: A complete walkthrough — deploy Ankole with a public HTTPS ingress, register an Entra ID app, bind an agent to the Teams adapter, verify Bot Framework JWT, and confirm the bot replies in a channel.
section: Guides
order: 305
---

This guide walks one agent all the way to a working Microsoft Teams bot: an @-mention in a Teams channel, a real model reply, a verified end-to-end path. By the end you will have an agent you can @-mention in Teams, and the confidence that every boundary along the way works.

The flow, in one line: **deploy Ankole with a public HTTPS endpoint → register an Entra ID app → activate and sign in → configure a provider → create an agent → bind it to the Teams adapter → @-mention the bot → verify the reply.**

This guide mirrors [Your first Lark bot](../lark-first-bot/) — read that first for the shared steps in more depth. The differences are Teams-specific, and they are the biggest of any adapter: a public HTTPS ingress (Teams has no long-connection mode), Bot Framework JWT verification, Graph subscriptions, and the broadest contract surface of any adapter.

## Prerequisites

- A Linux host or Kubernetes cluster that meets [Platform support](../platform-support/), **with a public HTTPS endpoint**. Teams delivers messages as Bot Framework webhook calls — there is no Socket Mode or long-connection fallback, so the deployment must be reachable at a public HTTPS URL with a trusted certificate.
- An Entra ID (Azure AD) tenant where you can register an application.
- An LLM provider API key for a real model turn.

If your Ankole deployment is behind a tunnel or a private network, expose it first. The Bot Framework will not deliver to `localhost`.

## Step 1: Deploy Ankole with a public HTTPS ingress

Follow [Installation](../installation/) — Docker Compose on one host, or Helm on Kubernetes. For Teams, the HTTPS ingress is mandatory, not optional: Caddy (Compose) or your Ingress (Helm) must serve the deployment at a public DNS name with a trusted certificate. Confirm `curl -I https://<your-host>/` succeeds before continuing.

Read the activation code, enter it on `/setup`, and in the plugin step keep the **Microsoft 365 adapter enabled**.

## Step 2: Register the Entra ID app

In the Entra ID portal, register a new application. The app registration gives you the values the Teams chat config needs:

| Field | What it is |
|---|---|
| `appID` | the app's application (client) id — a GUID |
| `appPassword` | the app's client secret |
| `botTenancy` | `single_tenant` or `multi_tenant` (default `single_tenant`) |
| `tenantID` | the tenant id; for `multi_tenant` the bot token tenant is `botframework.com` |

The adapter validates `appID` as a GUID. Subscribe the app to the Teams channel scopes it needs, and grant admin consent. Configure the app's redirect URI for OIDC (if you will use Entra ID as the admin identity provider) to the Ankole Console callback.

## Step 3: Sign in through Entra ID (optional) and enable directory sync

The Microsoft 365 adapter declares the broadest identity surface: `oidc_authorization`, `oidc_code_exchange`, `directory_full_sync`, and `directory_realtime_sync`. Configure Entra ID as the identity provider through the setup flow, or `PUT /identity-providers/<provider_id>` with `adapter_id: "entra-id"`.

Realtime directory sync uses Graph subscriptions, which are kept alive by the adapter's `SubscriptionReconciler`. The reconciler renews subscriptions inside a 48-hour window and re-creates dropped ones, so a missed run does not lose sync — but Graph must be able to reach your public webhook to deliver notifications, which is another reason the ingress is mandatory.

If you only want the chat bot, skip this step — the Teams chat binding does not depend on Entra ID sign-in.

## Step 4: Configure a provider, bind profiles, create the agent

Follow [Providers and models](../providers-and-models/) to add a provider and bind the required model profile slots (`primary`, `light`, `heavy`). Follow [Agents](../agents/) to create the agent and author at least a `mission` document.

## Step 5: Bind the agent to the Teams adapter

Create the signal binding. Note the adapter id is `teams`, not `microsoft365`:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/teams/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "<teams-config-key>", "unaddressed_group_message_policy": "addressed_only" }'
```

The `config_ref` points at the Teams configuration carrying `appID`/`appPassword`/`botTenancy`/`tenantID`. `addressed_only` is the safest first policy — the agent only wakes when @-mentioned in a Teams channel.

## Step 6: Verify the bot replies

Add the bot to a Teams team or channel (or open a direct chat with it). @-mention it with a simple prompt:

> what can you do?

A working reply means the whole path is sound: Teams delivered the activity as a Bot Framework webhook call, the adapter verified the JWT (issuer `https://api.botframework.com`, audience your `appID`, service URL matching the activity), the signal binding accepted the resulting event, the actor woke, the model profile resolved, and the reply posted back through the Bot Framework. If the bot does not reply, work the order:

1. The public HTTPS endpoint is reachable and the certificate is trusted — Bot Framework will not deliver to an untrusted or private endpoint.
2. The app registration's `appID` and `appPassword` match the Teams config, and the JWT's audience equals `appID`. The adapter rejects a token whose audience is wrong before it reaches the agent.
3. The messaging endpoint in the Bot Framework portal points at your Ankole deployment's Teams webhook route.
4. The bot is installed in the team or channel (Teams will not deliver activities for a bot that is not a member).
5. The signal binding is enabled and points at this agent.
6. The agent has usable model profiles and the provider credentials are valid.

Inspect recent worker output without dumping its environment:

```bash
docker logs --tail 200 ankole-dev-agent-computer   # local
kubectl -n ankole logs -l app.kubernetes.io/component=worker --tail=200  # Helm
```

## What is different from the other first-bot guides

The shape of the walkthrough is the same; the Teams-specific pieces are the heaviest of any adapter:

- **Public HTTPS ingress is mandatory.** Lark, Slack, and DingTalk all use a long-connection or Socket Mode; Teams delivers as Bot Framework webhook calls. No public endpoint, no Teams bot.
- **Bot Framework JWT verification.** The adapter verifies issuer, audience (`appID`), and service URL; the Emulator path is deliberately rejected. A wrong `appID` fails at the boundary, not silently.
- **Graph subscriptions for directory realtime sync.** The `SubscriptionReconciler` renews inside a 48-hour window and re-creates dropped subscriptions; Graph delivers to your public webhook, authenticated by the `clientState` the adapter set.
- **The broadest contract surface.** Four declarations: the Teams chat adapter, the `teams` webhook handler (kinds `messages`), the `entra-id` identity provider, and the `entra-id` webhook handler (kinds `directory`). The adapter does more than chat.

## Where to go next

You now have one agent live in one Teams channel. From here:

- **Let it observe channel conversation** — change the binding's `unaddressed_group_message_policy`.
- **Give it a rhythm** — add a [schedule](../schedules/) for a daily post.
- **Hand off long work** — let the agent delegate to [background jobs](../background-jobs-ops/), as in the [background research job](../background-research-job/) guide.
- **Federate admin sign-in through Entra ID** — configure the identity provider if you skipped Step 3, and sync directory groups into AuthZ.

For the operator surface, read [Console operations](../console-operations/). For the adapter internals, read the [Microsoft 365 adapter](../adapters-microsoft-365/) page.
