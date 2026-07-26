---
title: Microsoft 365 adapter
description: Connect an agent to Microsoft 365 — Teams chat via Bot Framework, an Entra ID identity provider, Graph subscriptions, and a directory webhook handler.
section: User guide
order: 18
---

The Microsoft 365 adapter is the broadest of the chat adapters. One plugin (`microsoft365-adapter`) contributes four contracts at once: a Teams chat face, a Graph/Bot Framework webhook handler, an Entra ID identity provider, and a second webhook handler for directory events. This page is the operator setup path.

## What the adapter declares

`Ankole.Plugins.Microsoft365Adapter` (`plugin_id: "microsoft365-adapter"`) declares four adapter contracts:

- **`signals_gateway.adapter`** (`id: "teams"`) — the Teams chat face. Lets a signal binding route Teams messages and events to an agent.
- **`signals_gateway.webhook_handler`** (`id: "teams"`, `module: TeamsWebhook`, `kinds: ["messages"]`) — the Graph/Bot Framework webhook face. Handles Bot Framework message delivery through the `/webhooks/v1/...` front door.
- **`principals.identity_provider`** (`id: "entra-id"`) — the Entra ID face. Lets admins sign into the Console with their Microsoft work account. Capabilities: `oidc_authorization`, `oidc_code_exchange`, `directory_full_sync`, `directory_realtime_sync`.
- **`signals_gateway.webhook_handler`** (`id: "entra-id"`, `module: DirectoryWebhook`, `kinds: ["directory"]`) — a second webhook handler, for directory change delivery during realtime sync.

The plugin supervises two children: `TeamsChannels.StartupSync` (projects Teams channel membership on boot) and `SubscriptionReconciler` (keeps Graph subscriptions alive). Enabling the plugin makes Teams chat, both webhook handlers, and Entra ID sign-in available together.

## Prerequisites

Register an app in Entra ID (Azure AD) and give it a Bot registration. The chat config (validated by `Config.validate_chat_config/1`) needs:

| Field | Meaning |
|---|---|
| `appID` | Microsoft App ID (client id); required, must be a GUID. |
| `appPassword` | Microsoft App client secret; required, stored encrypted by the control plane. |
| `botTenancy` | `single_tenant` (default) or `multi_tenant`. |
| `tenantID` | Entra tenant GUID; required for single-tenant apps. |

The Bot Connector token tenant follows `botTenancy`. For a single-tenant app the adapter uses your `tenantID`. For a multi-tenant app the bot token tenant is the fixed `botframework.com` segment, and `tenantID` becomes optional. Subscribe the app to the Teams channel and Graph subscription scopes it needs, and grant admin consent for those scopes.

## Create a Teams chat binding

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/teams/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

The binding's `config_ref` points at the Teams app configuration stored under the `signals_gateway.teams.bindings.<id>` AppConfigure key. See [Signal bindings](../signal-bindings/) for the filter and group-message-policy fields shared by all adapters.

## Bot Framework authentication

Inbound Teams messages arrive as Bot Framework JWT-bearing requests. The adapter (`BotFrameworkAuth`) verifies each request before anything else: the RS256 signature against the Bot Framework JWKS, the issuer `https://api.botframework.com`, the audience equal to your `appID`, the `serviceUrl` claim matching the activity's service URL, with five minutes of clock leeway. The signature itself is verified by the native kernel; only a verified request becomes an actor event.

This is why `appID` and `appPassword` must match the app registration. The adapter uses the App ID as the expected JWT audience and the App password to obtain Bot Connector tokens for outbound calls. A token whose audience is wrong, whose signature fails, or whose `serviceUrl` does not match is rejected before it reaches the agent. The Emulator path (`sts.windows.net` issuers) is not accepted — only production connector traffic.

## Graph subscriptions and the reconciler

Graph change-notification subscriptions are owned by the adapter, not by you. The subscription state lives under the machine-managed `principals.entra_id.graph_subscriptions.<id>` AppConfigure key. Each subscription carries a `clientState`; the adapter set it, and a Graph delivery that does not present the matching `clientState` is rejected.

`SubscriptionReconciler` keeps subscriptions alive. It renews each subscription before its expiry window, and re-creates a subscription that dropped. Its renewal interval sits well inside Graph's renewal window, so a few missed runs do not lose data. You do not renew subscriptions by hand.

## The two webhook handlers

The plugin declares two `signals_gateway.webhook_handler` contracts because the traffic is different and arrives on separate paths:

- **`teams`** (`TeamsWebhook`, kinds `["messages"]`) — Bot Framework message delivery for the Teams bot.
- **`entra-id`** (`DirectoryWebhook`, kinds `["directory"]`) — directory change notifications for realtime directory sync.

Both come through the `/webhooks/v1/...` front door; the kind and the handler module decide what each delivery does.

## Teams channel membership

The adapter projects Teams channel membership so an agent in a channel knows who is in it. `TeamsChannels` runs a startup sync at boot, then `sync_channels` and `refresh_channel` jobs keep membership current. Membership is read from Graph and mirrored as a projection; Teams remains the source of truth. You do not manage membership in Ankole — changes flow in at sync time.

## Entra ID as the admin identity provider

The identity face lets admins sign into the Console with their Microsoft work account through Entra ID. The declaration carries `oidc_authorization`, `oidc_code_exchange`, `directory_full_sync`, and `directory_realtime_sync`. Configure it through the identity-provider surface:

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/entra-id-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "adapter_id": "entra-id", "tenantID": "...", "clientID": "...", "clientSecret": "...", "oidc": { "enabled": true }, "sync": { "contacts": true, "realtime": true } }'
```

The config key pattern is `principals.identity_providers.entra-id.<id>`. After login, a directory sync (full and/or realtime) pulls Entra ID groups into AuthZ groups, so Console AuthZ can map to your existing Entra ID group structure.

## When something does not work

- **Bot Framework verification fails** — confirm `appID` matches the registration and the JWT's audience is your App ID. A token whose audience or `serviceUrl` is wrong is rejected before it reaches the agent.
- **`appID`/`tenantID` mismatch** — for a single-tenant app `tenantID` is required; for multi-tenant the bot token tenant is `botframework.com`, so a single-tenant tenant left in a multi-tenant config (or the reverse) will not mint the right token.
- **Webhooks stop firing** — Graph subscriptions expire; `SubscriptionReconciler` renews them, but if a subscription dropped the reconciler re-creates it. Check the reconciler diagnostics; a rotated `clientState` shows up as rejected deliveries.
- **Directory realtime sync is off** — realtime sync needs `publicBaseURL` set on the identity provider; without it the adapter falls back to full sync only.

## Next steps

- For the binding model, read [Signal bindings](../signal-bindings/).
- For the webhook front door, read the [SignalsGateway](../signals-gateway/) developer page.
- For the identity-provider routes, read the [Console API reference](../console-api/).
