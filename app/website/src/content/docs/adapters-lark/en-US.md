---
title: Lark (Feishu) adapter
description: Connect an agent to Lark or Feishu — the self-built app, the per-app WebSocket connection, IM group sync, CardKit replies, and the OIDC identity provider for admin sign-in.
section: User guide
order: 15
---

The Lark adapter connects an Ankole agent to Lark or Feishu. It has two faces: a chat binding (the agent reads and replies in Lark conversations) and an identity-provider face (Lark OIDC signs admins into the Console). This page is the operator setup path.

## What the adapter declares

`Ankole.Plugins.LarkAdapter` (plugin id `lark-adapter`) registers two adapter declarations:

- **`signals_gateway.adapter`** (`id: "lark"`) — the chat face. A signal binding routes Lark messages and events to an agent.
- **`principals.identity_provider`** (`id: "lark"`) — the identity face. Lark OIDC serves as the admin identity provider, with the config key pattern `principals.identity_providers.lark.<id>`.

One plugin contributes both faces because the adapter declares `consumer_kinds: [:chat, :identity_provider]`. Enabling the plugin makes both faces available.

## Prerequisites

Create a **self-built enterprise app** in the Lark or Feishu developer console. The chat config needs two fields:

| Field | Meaning |
|---|---|
| `appID` | the self-built app identifier (required) |
| `appSecret` | the self-built app secret (required, stored encrypted by the control plane) |
| `domain` | `feishu` or `lark` — the service network to call |

Subscribe the app to the events the agent should see (messages, mentions, card actions), and grant the permissions those events require.

You do not supply a bot identity by hand. When the connection comes up, the adapter calls `bot/v3/info` with the app credentials alone and resolves the bot's own `open_id`. It keeps that value only in the process-local consumer config as `runtimeBotOpenID`. Group mention events carry the mentioned bot's `open_id`, so the adapter can match them. This is a deliberate difference from adapters that ask you for a bot id — here there is nothing to paste.

## Create a chat binding

With the plugin enabled and the app configured, bind an agent to Lark:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/lark/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

The binding's `config_ref` points at the Lark app configuration. A binding needs no extra input beyond the chat config — the bot identity is resolved at connection time, not stored with the binding. See [Signal bindings](../signal-bindings/) for the filter and group-message-policy fields shared by all adapters.

## The long-connection model

The chat face runs over one Feishu/Lark WebSocket per provider app, not one per binding. A `ConnectionOwner` GenServer owns the long-connection client, registered under the domain and app id. A `ConnectionReconciler` watches the enabled bindings and starts or stops owners as the database changes; one owner serves every consumer that shares the same `domain`, `appID` (the `connection_key`), and the same secret plus consumer fingerprints.

The owner is permanent. If the WebSocket client exits, the owner is restarted; the reconciler makes the set of live owners converge on the next tick. You do not start or stop the WebSocket yourself.

## IM groups

Lark IM groups are projected as channels of kind `im_group`. A startup sync runs when the plugin starts, then `sync_im_groups` and `refresh_im_group` jobs keep membership current. A binding scoped to a group only wakes on messages in that group, and the agent in a group chat sees who is in it.

Lark remains the source of truth for group membership. You do not manage members from Ankole — changes flow in as the sync runs.

## Replies: CardKit

The agent replies through CardKit — Lark's card model. The Outbox renders model output via the CardKit pipeline (`markdown_segmenter`, `card_chain`, `renderer`, `error_policy`, `image_resolver`, `i18n`), and the `:card` outbox operation produces card message requests. Card content is built through `Card.message_content`. The adapter delivers cards as the binding's reply mode dictates (a channel post or a threaded entry reply).

Card actions round-trip. A `card.action.trigger` event comes back through the adapter as a `signal.action.invoked` event, so a button the agent sent in a card can drive a follow-up turn.

## Lark as the admin identity provider

The identity face lets admins sign into the Console with their Lark account. Configure it through the identity-provider surface:

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/lark-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "adapter_id": "lark", "oidc": { "enabled": true, "scopes": ["contact:user.employee_id:readonly"] } }'
```

The identity-provider declaration carries the `oidc_authorization` and `oidc_code_exchange` capabilities. The `oidc.enabled` flag gates whether this provider can sign admins in, and `oidc.scopes` controls the scopes requested during authorization. The redirect URL the Lark app must allow is `http://localhost:4000/sessions/oidc/lark-main/callback` for local development (the `<provider_id>` segment matches your identity-provider id). After login, a directory sync pulls Lark contacts and department groups into AuthZ groups.

## When something does not work

The common failures are config-shaped, not code-shaped:

- **The bot does not reply in a chat** — confirm the self-built app's bot capability is enabled, the test user and chat are in scope, the message/card/event/callback permissions are active, the signal binding is enabled, and the agent has usable model profiles. The [FAQ](../faq/) walks this order.
- **Login fails with a redirect mismatch** — confirm the browser origin, provider id, and Lark allowlist produce exactly the callback URL the provider expects.
- **A binding is unavailable** — the binding records an `unavailable_reason`; read it through the binding detail route.
- **The bot identity will not resolve** — the adapter calls `bot/v3/info` at connection time; if that call fails (wrong `appID`/`appSecret`, bot capability off, missing permission), the bot's `open_id` is not set and mentions will not match. Fix the app credentials and permissions, and let the reconciler restart the connection.

## Next steps

- For the binding model, read [Signal bindings](../signal-bindings/).
- For the identity-provider routes, read the [Console API reference](../console-api/).
- For the inbound pipeline that turns a Lark event into an actor event, read the [SignalsGateway](../signals-gateway/) developer page.
