---
title: Slack adapter
description: Connect an agent to Slack — the Slack app, bot and app tokens, event delivery, mention routing, directory membership, and Slack as an admin identity provider.
section: User guide
order: 17
---

The Slack adapter connects an Ankole agent to a Slack workspace. It carries a chat face for messages and replies, an identity-provider face that uses Slack for admin sign-in, and it owns Slack directory membership so an agent in a channel knows who is in it. This page is the operator setup path.

## What the adapter declares

`Ankole.Plugins.SlackAdapter` (plugin_id `"slack-adapter"`) registers two contracts, both under the id `"slack"`:

- a **chat** declaration under `signals_gateway.adapter`, and
- an **identity** declaration under `principals.identity_provider`.

Every Slack AppConfigure pattern is encrypted — every one. Tokens are secret material, and the control plane stores them encrypted. The chat binding lives under `signals_gateway.slack.bindings.<id>`; the identity provider lives under `principals.identity_providers.slack.<id>`. Slack directory membership is owned by this adapter, so the membership you see in Ankole is sourced from Slack, not invented here.

## Prerequisites

Create a Slack app in the Slack API dashboard. The app gives you the two tokens the chat config requires, and the adapter validates them strictly:

| Field | Format rule | Meaning |
|---|---|---|
| `botToken` | must start with `xoxb-` | the bot user token the agent acts through |
| `appToken` | must start with `xapp-` | the app-level token that drives Socket Mode and event delivery |

Both tokens are required. A missing `botToken` fails with `{:missing, "botToken"}`; a missing `appToken` fails with `{:missing, "appToken"}`. A token with the wrong prefix fails with `{:invalid_token_prefix, "botToken"}` or `{:invalid_token_prefix, "appToken"}` — a `botToken` that does not start with `xoxb-`, or an `appToken` that does not start with `xapp-`, is rejected on save. Turn on Socket Mode in the app, and subscribe it to the events the agent should see (messages, app mentions).

## Create a chat binding

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/slack/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

The binding's `config_ref` points at the Slack app configuration. The filter and group-message-policy fields are shared by every adapter — see [Signal bindings](../signal-bindings/).

## Socket Mode and event delivery

The `appToken` is what powers Socket Mode: the adapter opens a long-lived WebSocket to Slack over the app-level token and receives events there. This is the delivery model the Slack adapter uses — there is no public HTTP ingress to host. When the appToken changes, the adapter's `secret_fingerprint` changes too, and a fresh connection is reconciled against the new token.

## Mention routing

Slack's app-mention events drive when the agent is addressed. The adapter's mention routing splits inbound messages into `addressed` events (the agent was @-mentioned) and `may_intervene` events (the agent is allowed to speak up). The binding's `unaddressed_group_message_policy` is what you tune to fit the agent's role in a channel — quiet unless mentioned, or observant and willing to interject.

## Directory membership

This adapter owns Slack directory membership. A Slack channel's membership is the source of truth on the Slack side; the adapter projects it into Ankole so an agent in a channel can reason about who can see what it says. Membership is not a second source of truth — changes in Slack propagate as the adapter syncs, on a full sync and over Socket Mode in real time. That projection is what lets a binding scope an agent to a channel and have it know the humans there.

## Slack as the admin identity provider

The same adapter can act as an identity provider for admin sign-in over OIDC. Configure it through the identity-provider route:

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/<id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "adapter_id": "slack", "config_ref": "..." }'
```

With `adapter_id` set to `"slack"`, sign-in flows through Slack's OIDC, and the directory (Slack users and usergroups) is synced into Ankole's AuthZ. See the [Console API reference](../console-api/) for the identity-provider routes.

## When something does not work

- **Validation fails on save** — check the token prefixes (`xoxb-` for `botToken`, `xapp-` for `appToken`) and that neither token is missing. The error names the field and the rule.
- **The bot does not reply** — confirm the app is subscribed to the right events, the bot is in the channel, the binding is enabled, and the agent has usable model profiles. The [FAQ](../faq/) ordering applies.
- **Membership looks stale** — Slack directory membership is a projection from Slack; give the sync a cycle, or check that the Slack app can read the workspace roster and that Socket Mode is connected.

## Next steps

- For the binding model, read [Signal bindings](../signal-bindings/).
- For the identity-provider routes, read the [Console API reference](../console-api/).
- For the inbound pipeline, read the [SignalsGateway](../signals-gateway/) developer page.
